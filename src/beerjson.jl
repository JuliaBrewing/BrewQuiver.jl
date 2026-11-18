# BeerJSON interoperability: the ingredients and recipes of BeerJSON (through BeerJSON.jl)
# as the working types and quivers of BrewQuiver.

const BJ = BeerJSON

_q(x) = BJ.quantity(x)
_q(::Nothing) = nothing

const FERMENTABLE_KINDS = Dict("grain" => :grain, "dry extract" => :dry_extract,
    "extract" => :extract, "sugar" => :sugar, "fruit" => :fruit, "juice" => :juice,
    "honey" => :honey, "other" => :other)

const HOP_FORMS = Dict("extract" => :extract, "leaf" => :leaf, "leaf (wet)" => :wet_leaf,
    "pellet" => :pellet, "powder" => :powder, "plug" => :plug)

# Some documents give potentials such as 1038 sg, meaning 1.038 sg
function _potential(g)
    p = _q(g)
    if unit(p) == u"sg" && p > 2u"sg"
        fixed = (1 + (ustrip(p) - 1000) / 1000) * u"sg"
        @warn "reading the potential $p as $fixed"
        return fixed
    end
    return p
end

_moisture(x::BJ.FermentableType) = _q(x.moisture)
_moisture(::BJ.FermentableAdditionType) = nothing

"""
    Fermentable(x::FermentableAdditionType; moisture = nothing)
    Fermentable(x::FermentableType; moisture = nothing)

The fermentable of a BeerJSON fermentable or fermentable addition. Its yield is the fine
grind yield, or else the one given by its potential, both read on a dry basis. Without a
`moisture` (in the record or as a keyword), grains are taken with 4% and the other
fermentables with none, so that their yield applies to their mass as is.
"""
function Fermentable(x::Union{BJ.FermentableAdditionType, BJ.FermentableType}; moisture = nothing)
    kind = FERMENTABLE_KINDS[x.type.value]
    y = x.yield
    yield, potential = if y.fine_grind !== nothing
        _q(y.fine_grind), nothing
    elseif y.potential !== nothing
        nothing, _potential(y.potential)
    else
        throw(ArgumentError("the fermentable $(repr(x.name)) has no fine grind yield nor potential"))
    end
    m = something(moisture, _moisture(x), kind === :grain ? 4u"percent" : 0u"percent")
    return Fermentable(x.name; kind, yield, potential, color = _q(x.color), moisture = m)
end

"""
    Hop(x::HopAdditionType; form = nothing)
    Hop(x::VarietyInformation; form = nothing)

The hop of a BeerJSON hop or hop addition, as pellets when the record has no form.
"""
Hop(x::Union{BJ.HopAdditionType, BJ.VarietyInformation}; form = nothing) =
    Hop(x.name; alpha = _q(x.alpha_acid),
        form = something(form, x.form === nothing ? :pellet : HOP_FORMS[x.form.value]))

"""
    Culture(x::CultureAdditionType; attenuation = nothing)
    Culture(x::CultureInformation; attenuation = nothing)

The culture of a BeerJSON culture or culture addition, with its attenuation (the mean of its
attenuation range), or else the given `attenuation`.
"""
function Culture(x::Union{BJ.CultureAdditionType, BJ.CultureInformation}; attenuation = nothing)
    a = something(_attenuation(x), attenuation, Some(nothing))
    a === nothing && throw(ArgumentError(
        "the culture $(repr(x.name)) has no attenuation; give it with the keyword `attenuation`"))
    return Culture(x.name; attenuation = a, kind = Symbol(x.type.value), form = Symbol(x.form.value))
end
_attenuation(x::BJ.CultureAdditionType) = _q(x.attenuation)
_attenuation(x::BJ.CultureInformation) = x.attenuation_range === nothing ? nothing :
    (_q(x.attenuation_range.minimum) + _q(x.attenuation_range.maximum)) / 2

# Building quivers from recipes

"""
    AbstractCalibration

How [`Quiver`](@ref) adjusts a recipe to its stated efficiency: [`NoCalibration`](@ref) or
[`BrewhouseEfficiency`](@ref).
"""
abstract type AbstractCalibration end

"""
    NoCalibration()

The efficiency of a quiver built from a recipe follows from its processes: the conversion
of the mash (the recipe's, or 95%), the grain absorption, the dead spaces and losses.
"""
struct NoCalibration <: AbstractCalibration end

"""
    BrewhouseEfficiency()

The conversion of the mash is adjusted so that the brewhouse efficiency of the quiver (the
extract reaching the fermentor over the potential extract of the fermentables of the mash
and the boil) is the recipe's.
"""
struct BrewhouseEfficiency <: AbstractCalibration end

# equipment: the parameters of the vessels used by `Quiver`, or `nothing`
function _equipment(e::Union{Nothing, BJ.EquipmentType})
    p = Dict{Symbol, Any}(:absorption => nothing, :dead_space => nothing,
                          :kettle_loss => nothing, :boil_rate => nothing,
                          :fermenter_loss => nothing)
    e === nothing && return p
    for it in e.equipment_items
        form = it.form.value
        if form in ("Mash Tun", "Lauter Tun")
            it.grain_absorption_rate === nothing ||
                (p[:absorption] = uconvert(u"L/kg", _q(it.grain_absorption_rate)))
            p[:dead_space] = _q(it.loss)
        elseif form == "Brew Kettle"
            p[:kettle_loss] = _q(it.loss)
            it.boil_rate_per_hour === nothing ||
                (p[:boil_rate] = uconvert(u"L/hr", _q(it.boil_rate_per_hour) / u"hr"))
        elseif form == "Fermenter"
            p[:fermenter_loss] = _q(it.loss)
        end
    end
    return p
end

# a label for an ingredient lot, from its name
function _label(name, taken)
    s = replace(lowercase(name), r"[^a-z0-9]+" => "_")
    s = strip(s, '_')
    s = isempty(s) ? "lot" : (isdigit(s[1]) ? "lot_" * s : s)
    l, k = Symbol(s), 1
    while l in taken
        k += 1
        l = Symbol(s, "_", k)
    end
    push!(taken, l)
    return l
end

# The timing of an addition, by its stage, as defined by BeerJSON (format 3.0, where
# beerjson/beerjson#220 settled the reference of `time`): in the boil, `time` counts back
# from the end of the boil, and a `duration` without `time` is a steep after the boil (a hop
# stand, not modelled yet: no boiling); in the mash, the fermentation and the packaging,
# `time` counts forward from the start of the step, and a `duration` without `time` is taken
# as staying until the end of the step.
function _timing(t, stage)
    t === nothing && return nothing
    time = t.time === nothing ? nothing : _q(t.time)
    duration = t.duration === nothing ? nothing : _q(t.duration)
    if stage === :boil
        time !== nothing && return Remaining(time)
        duration !== nothing && return Remaining(0u"minute")
    else
        time !== nothing && return At(time)
        duration !== nothing && return Remaining(duration)
    end
    return nothing
end

# the additions of a recipe, each as (ingredient, amount, stage, timing)
function _additions(r, boil_time, attenuation)
    adds = Tuple{AbstractIngredient, Union{KgQ, Float64}, Symbol, Any}[]
    stages = Dict("add_to_mash" => :mash, "add_to_boil" => :boil,
                  "add_to_fermentation" => :fermentation, "add_to_package" => :package)
    use(t) = t === nothing || t.use === nothing ? nothing : stages[t.use.value]
    for a in r.ingredients.fermentable_additions
        f = Fermentable(a)
        a.amount isa BJ.MassType || throw(ArgumentError(
            "the fermentable $(repr(a.name)) is given by volume; give its mass"))
        stage = something(use(a.timing), soluble(f) ? :boil : :mash)
        stage === :boil && !soluble(f) &&
            @warn "the grain $(repr(a.name)) is added to the boil, where it gives no extract"
        push!(adds, (f, _portion_amount(_q(a.amount)), stage, _timing(a.timing, stage)))
    end
    for a in something(r.ingredients.hop_additions, [])
        if !(a.amount isa BJ.MassType)
            @warn "the hop $(repr(a.name)) is given by volume; it is left out"
            continue
        end
        h, m, t = Hop(a), _portion_amount(_q(a.amount)), a.timing
        stage = something(use(t), :boil)
        time = t.time === nothing ? nothing : _q(t.time)
        if stage === :mash                       # mash hops: taken as first wort hops
            stage, timing = :boil, nothing
        elseif stage === :boil && time !== nothing && time > boil_time
            # (as in documents converted from BeerXML before beerjson/beerjson#268)
            @warn "the hop $(repr(a.name)) is added $time before the end of a $boil_time " *
                  "boil: it is taken as a dry hop"
            stage, timing = :fermentation, Remaining(time)
        else
            timing = _timing(t, stage)
        end
        push!(adds, (h, m, stage, timing))
    end
    for a in something(r.ingredients.culture_additions, [])
        c = Culture(a; attenuation)
        n = a.amount isa BJ.MassType ? _portion_amount(_q(a.amount)) :
            a.amount isa BJ.UnitType ? float(_q(a.amount)) : 1.0     # a volume: one unit
        stage = something(use(a.timing), :fermentation)
        push!(adds, (c, n, stage, _timing(a.timing, stage)))
    end
    ignored = [string(length(x), " ", what) for (x, what) in
               ((r.ingredients.miscellaneous_additions, "miscellaneous additions"),
                (r.ingredients.water_additions, "water additions")) if x !== nothing && !isempty(x)]
    isempty(ignored) || @info "$(repr(r.name)): ignoring $(join(ignored, " and "))"
    return adds
end

# the mash: the rests (temperature, time, water, water temperature) and the sparges (volume
# or nothing, temperature)
function _mash_steps(r, grist, mash_ratio)
    rests, sparges = [], []
    steps = r.mash === nothing ? [] : r.mash.mash_steps
    for s in steps
        kind = s.type.value
        T, t = _q(s.step_temperature), _q(s.step_time)
        amount = s.amount === nothing ? nothing : _q(s.amount)
        amount !== nothing && iszero(amount) && (amount = nothing)
        if kind in ("infusion", "temperature")
            if isempty(rests) && amount === nothing
                ratio = s.water_grain_ratio === nothing ? mash_ratio : _q(s.water_grain_ratio)
                amount = uconvert(u"L", ratio * grist)
            end
            Tw = s.infuse_temperature === nothing ? T : _q(s.infuse_temperature)
            push!(rests, (T, t, amount, Tw))
        elseif kind == "sparge"
            push!(sparges, (amount, T))
        elseif kind == "drain mash tun"
            continue
        else
            throw(ArgumentError("mash steps of type $(repr(kind)) are not supported yet " *
                                "(in $(repr(r.name)))"))
        end
    end
    isempty(rests) && push!(rests, (67u"°C", 60u"minute", uconvert(u"L", mash_ratio * grist), 67u"°C"))
    return rests, sparges
end

# the fermentation: the temperature of its first step and the total time
function _fermentation(r)
    steps = r.fermentation === nothing ? [] : r.fermentation.fermentation_steps
    isempty(steps) && return (20u"°C", 14u"d")
    T = something(_q(steps[1].start_temperature), 20u"°C")
    t = sum((uconvert(u"d", _q(s.step_time)) for s in steps if s.step_time !== nothing);
            init = 0.0u"d")
    return (T, iszero(t) ? 14u"d" : t)
end

"""
    Quiver(recipe::RecipeType; equipment = nothing, calibration = NoCalibration(),
           mash_ratio = 3u"L/kg", attenuation = 75u"percent")

The quiver of a BeerJSON recipe: its ingredients as lots, the water, and the stages of the
mash tun (`:mash`, the rests `:mash_1`, `:mash_2`, ..., the grain beds of the sparges
`:grain_bed_1`, ...), the kettle (`:kettle`, `:wort`, `:chilled`), the fermentor
(`:fermentor`, `:beer`) and the packaging (`:packaging`, and `:packaged` when the recipe
gives a carbonation, by forced carbonation).

The mash steps of type infusion and temperature are rests ([`MashRest`](@ref)), the first
one converting the grain, with the water of their amounts; the sparge steps are batch
sparges. The volumes the recipe does not give are solved for its targets:

- the strike water, from the water to grain ratio of the first step, or else `mash_ratio`;
- the sparge water (one batch sparge when the recipe has no sparge step), for the pre-boil
  volume of the recipe (or else its batch size plus the evaporation and the kettle loss);
- the evaporation rate, from the `equipment`, or else from the pre-boil volume and the
  batch size;
- the kettle loss, from the `equipment`, or else so that the batch size reaches the
  fermentor.

The `equipment` (a BeerJSON `EquipmentType`) also gives the grain absorption and dead space
of the mash tun and the loss of the fermenter. The `calibration` ([`NoCalibration`](@ref)
or [`BrewhouseEfficiency`](@ref)) sets the conversion of the mash. Cultures without
attenuation get the apparent attenuation of the recipe's original and final gravities, or
else `attenuation`, with a warning.

The timings of the additions follow BeerJSON (format 3.0): in the boil, `time` counts back
from the end of the boil ([`Remaining`](@ref)), and an addition with only a `duration`
steeps after the boil (not modelled yet, so it does not boil); in the mash, the
fermentation and the packaging, `time` counts forward from the start of the step
([`At`](@ref)), and an addition with only a `duration` stays until the end of the step.
Hops added to the mash are taken as first wort hops, boiling for the whole boil; hops
added to the boil earlier than the boil starts (as in documents converted from BeerXML
before the importer of BeerJSON was fixed) are taken as dry hops, with a warning.
Miscellaneous and water additions are not used yet. Decoction and souring steps are not
supported yet.
"""
function Quiver(r::BJ.RecipeType; equipment::Union{Nothing, BJ.EquipmentType} = nothing,
                calibration::AbstractCalibration = NoCalibration(),
                mash_ratio = 3u"L/kg", attenuation = 75u"percent")
    eqp = _equipment(equipment)
    batch = uconvert(u"L", _q(r.batch_size))
    boil_time = r.boil === nothing ? (@warn("$(repr(r.name)) has no boil: boiling 60 minutes");
                                      60u"minute") : uconvert(u"minute", _q(r.boil.boil_time))
    og, fg = _q(r.original_gravity), _q(r.final_gravity)
    att = if og !== nothing && fg !== nothing
        apparent_attenuation(og, fg)
    else
        nothing
    end
    cultures_without = r.ingredients.culture_additions === nothing ? false :
        any(a -> a.attenuation === nothing, r.ingredients.culture_additions)
    if cultures_without && att === nothing
        @warn "$(repr(r.name)): cultures without attenuation are taken with $attenuation"
    end
    adds = _additions(r, boil_time, something(att, attenuation))
    isempty(adds) && throw(ArgumentError("the recipe $(repr(r.name)) has no ingredients"))

    # volumes and rates
    kettle_loss = eqp[:kettle_loss]
    pre_boil = r.boil === nothing || r.boil.pre_boil_size === nothing ? nothing :
               uconvert(u"L", _q(r.boil.pre_boil_size))
    rate = something(eqp[:boil_rate],
        pre_boil === nothing ? 4.0u"L/hr" :
        max(0.0u"L/hr", uconvert(u"L/hr", (pre_boil - batch - something(kettle_loss, 0u"L")) / boil_time)))
    pre_boil = something(pre_boil, batch + something(kettle_loss, 0u"L") + rate * boil_time)
    Tferm, tferm = _fermentation(r)
    conversion = r.efficiency.conversion === nothing ? 0.95 : _fraction(_q(r.efficiency.conversion))

    q = Quiver()
    taken = Set{Symbol}()

    # the lots: one per ingredient, with a transfer per addition
    lots = Dict{Any, Symbol}()
    order = []
    for (i, m, stage, timing) in adds
        if !haskey(lots, i)
            lots[i] = _label(i.name, taken)
            push!(order, i)
        end
    end
    total = Dict(i => sum(a[2] for a in adds if a[1] == i) for i in order)
    for i in order
        add!(q, lots[i], i => total[i])
    end
    mashed = [a for a in adds if a[3] === :mash]
    grist = sum((a[2] for a in mashed if a[1] isa Fermentable && !soluble(a[1])); init = 0.0u"kg")

    # the stages
    stage_node = Dict(:boil => :kettle, :fermentation => :fermentor, :package => :packaging)
    rests, sparges = Any[], Any[]
    if !isempty(mashed)
        rests, sparges = _mash_steps(r, grist, mash_ratio)
        stage_node[:mash] = :mash
        add!(q, :strike_water, water(rests[1][3]; temperature = rests[1][4]))
        for (k, rest) in enumerate(rests)
            k > 1 && rest[3] !== nothing &&
                add!(q, Symbol(:infusion_, k), water(rest[3]; temperature = rest[4]))
        end
        isempty(sparges) && push!(sparges, (nothing, 76u"°C"))
        for (k, s) in enumerate(sparges)
            add!(q, Symbol(:sparge_water_, k), water(something(s[1], 0u"L"); temperature = s[2]))
        end
        add!(q, :mash, (Symbol(:mash_, k) for k in eachindex(rests))...; vessel = :mashtun)
        add!(q, (Symbol(:grain_bed_, k) for k in eachindex(sparges))...; vessel = :mashtun)
    else
        add!(q, :boil_water, water(pre_boil))
    end
    add!(q, :kettle, :wort, :chilled; vessel = :kettle)
    add!(q, :fermentor, :beer; vessel = :fermentor)
    add!(q, :packaging; vessel = :package)
    r.carbonation === nothing || add!(q, :packaged; vessel = :package)

    # the additions
    for i in order
        as = [a for a in adds if a[1] == i]
        for (_, m, stage, timing) in as
            # all of the lot for its only addition, else the amount of each
            amount = length(as) == 1 ? nothing : m isa KgQ ? m : m / total[i]
            remaining = timing isa Remaining ? timing.time : nothing
            at = timing isa At ? timing.time : nothing
            connect!(q, lots[i] => stage_node[stage], Transfer(amount; remaining, at))
        end
    end

    # the mash and the sparges
    absorption = something(eqp[:absorption], Drain().absorption)
    dead_space = something(eqp[:dead_space], 0u"L")
    mashrest(rest, c) = MashRest(temperature = rest[1], time = rest[2], conversion = c)
    if !isempty(mashed)
        connect!(q, :strike_water => :mash)
        prev = :mash
        for (k, rest) in enumerate(rests)
            k > 1 && rest[3] !== nothing && connect!(q, Symbol(:infusion_, k) => prev)
            connect!(q, prev => Symbol(:mash_, k), mashrest(rest, conversion))
            prev = Symbol(:mash_, k)
        end
        drain = Drain(; absorption, retain = dead_space)
        connect!(q, prev => :kettle, drain)
        for k in eachindex(sparges)
            bed = Symbol(:grain_bed_, k)
            connect!(q, prev => bed)
            connect!(q, Symbol(:sparge_water_, k) => bed)
            connect!(q, bed => :kettle, drain)
            prev = bed
        end
    else
        connect!(q, :boil_water => :kettle)
    end

    # the boil, the fermentation and the packaging
    connect!(q, :kettle => :wort, Boil(time = boil_time, evaporation = rate))
    connect!(q, :wort => :chilled, Chill(temperature = Tferm))
    connect!(q, :chilled => :fermentor, Drain(retain = something(kettle_loss, 0u"L")))
    has_culture = any(a -> a[1] isa Culture && a[3] === :fermentation, adds)
    connect!(q, :fermentor => :beer,
             Ferment(temperature = Tferm, time = tferm,
                     attenuation = has_culture ? nothing : something(att, attenuation)))
    connect!(q, :beer => :packaging, Drain(retain = something(eqp[:fermenter_loss], 0u"L")))
    r.carbonation === nothing ||
        connect!(q, :packaging => :packaged, Carbonate(r.carbonation * u"vols"))

    # solving for the volumes not given, and the calibration
    solve_sparge = !isempty(mashed) && any(s -> s[1] === nothing, sparges)
    fixed = sum((s[1] for s in sparges if s[1] !== nothing); init = 0.0u"L")
    free = count(s -> s[1] === nothing, sparges)
    solve_loss = kettle_loss === nothing
    target = _fraction(_q(r.efficiency.brewhouse))
    sparge, loss = 0.0u"L", 0.0u"L"
    for _ in 1:50
        res = brew(q)
        moved = false
        if solve_sparge
            δ = pre_boil - volume(res[:kettle])
            new = max(0.0u"L", sparge + δ)
            moved |= abs(new - sparge) > 1e-6u"L"
            sparge = new
            for (k, s) in enumerate(sparges)
                s[1] === nothing && (q[Symbol(:sparge_water_, k)] = water(sparge / free; temperature = s[2]))
            end
        end
        if solve_loss
            new = max(0.0u"L", volume(res[:chilled]) - batch)
            moved |= abs(new - loss) > 1e-6u"L"
            loss = new
            q[:chilled => :fermentor] = Drain(retain = loss)
        end
        if calibration isa BrewhouseEfficiency && !isempty(mashed)
            e = _brewhouse_efficiency(res, q)
            new = clamp(conversion * target / e, 0.0, 1.0)
            moved |= abs(new - conversion) > 1e-9
            conversion = new
            prev = :mash
            for (k, rest) in enumerate(rests)
                q[prev => Symbol(:mash_, k)] = mashrest(rest, conversion)
                prev = Symbol(:mash_, k)
            end
        end
        moved || break
    end
    res = brew(q)
    if solve_sparge && iszero(sparge)
        @warn "$(repr(r.name)): the runnings without sparge exceed the pre-boil volume of " *
              "$(round(u"L", pre_boil; digits = 2))"
    elseif !solve_sparge && !isapprox(volume(res[:kettle]), pre_boil; rtol = 0.02)
        @warn "$(repr(r.name)): the water of the recipe gives " *
              "$(round(u"L", volume(res[:kettle]); digits = 2)) in the kettle, for a pre-boil " *
              "volume of $(round(u"L", pre_boil; digits = 2))"
    end
    if !isapprox(volume(res[:fermentor]), batch; rtol = 0.02)
        @warn "$(repr(r.name)): $(round(u"L", volume(res[:fermentor]); digits = 2)) reach the " *
              "fermentor, for a batch size of $(round(u"L", batch; digits = 2))"
    end
    if calibration isa BrewhouseEfficiency && conversion ≥ 1.0
        @warn "$(repr(r.name)): the brewhouse efficiency of $(round(100target; digits = 1))% " *
              "is not reached even with full conversion"
    end
    return q
end

"""
    brewhouse_efficiency(res::BrewResult, q::Quiver; into = :fermentor)

The extract reaching the node `into` (dissolved, plus the extract equivalent of its alcohol)
over the potential extract of the fermentables of the lots of `q` that reach it through the
mash or the boil, i.e. all the fermentables of the lots except those transferred straight
into `into` or after it.
"""
brewhouse_efficiency(res::BrewResult, q::Quiver; into::Symbol = :fermentor) =
    _brewhouse_efficiency(res, q; into)

function _brewhouse_efficiency(res, q; into = :fermentor)
    l = liquor(res[into])
    got = l.extract + 2.0665 * l.alcohol
    later = Set(descendants(q, into))
    potential = 0.0u"kg"
    for n in nodes(q)
        isempty(predecessors(q, n)) || continue
        for s in solids(q[n].initial)
            s isa Portion{Fermentable, KgQ} || continue
            # the share of the lot sent to the mash or the boil, not straight to `into`
            # or after it
            direct = 0.0u"kg"
            for d in successors(q, n)
                d in later || continue
                for a in res[n => d], x in solids(a.moved)
                    x isa Portion{Fermentable, KgQ} && x.ingredient == s.ingredient &&
                        (direct += x.amount)
                end
            end
            f = 1 - float(uconvert(NoUnits, direct / s.amount))
            f > 0 || continue
            potential += f * potential_extract(s.amount, s.ingredient.yield;
                                               moisture = s.ingredient.moisture)
        end
    end
    return iszero(potential) ? 0.0 : float(uconvert(NoUnits, got / potential))
end
