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

"""
    Vessel(item::EquipmentItemType)

The vessel of a BeerJSON equipment item: its maximum volume as capacity, its loss as dead
space, its grain absorption rate, its boil rate per hour as evaporation, and its drain rate.
"""
Vessel(it::BJ.EquipmentItemType) = Vessel(
    name = strip(it.name), capacity = _q(it.maximum_volume), dead_space = _q(it.loss),
    absorption = _q(it.grain_absorption_rate),
    evaporation = it.boil_rate_per_hour === nothing ? nothing : _q(it.boil_rate_per_hour) / u"hr",
    drain_rate = it.drain_rate_per_minute === nothing ? nothing : _q(it.drain_rate_per_minute) / u"minute")

# the vessels of an equipment used by `Quiver`, by the names of its vessels
function _equipment(e::Union{Nothing, BJ.EquipmentType})
    vs = Dict{Symbol, Vessel}()
    e === nothing && return vs
    for it in e.equipment_items
        form = it.form.value
        name = form in ("Mash Tun", "Lauter Tun") ? :mashtun : form == "Brew Kettle" ? :kettle :
               form == "Fermenter" ? :fermentor : nothing
        name === nothing || (vs[name] = Vessel(it))
    end
    return vs
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
# a boil addition steeping for `time` after the boil, placed once the stand is known
struct _Steep
    time::MinQ
end

function _timing(t, stage)
    t === nothing && return nothing
    time = t.time === nothing ? nothing : _q(t.time)
    duration = t.duration === nothing ? nothing : _q(t.duration)
    if stage === :boil
        # (an addition at the end of the boil with a duration steeps in the stand)
        time !== nothing && !(iszero(time) && duration !== nothing) && return Remaining(time)
        duration !== nothing && return _Steep(uconvert(u"minute", float(duration)))
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

# The mash: the rests, as NamedTuples (kind, temperature, time, water, water_temperature,
# decoction, decoction_time) with the water added before them (or `nothing`), and for a
# decoction the volume of mash to decoct (or `nothing`, for the step temperature) and the
# time to boil it; and the sparges (volume or nothing, temperature)
function _mash_steps(r, grist, mash_ratio, decoction_time)
    rests, sparges = [], []
    steps = r.mash === nothing ? [] : r.mash.mash_steps
    water = 0.0u"L"
    for s in steps
        kind = s.type.value
        T, t = _q(s.step_temperature), _q(s.step_time)
        amount = s.amount === nothing ? nothing : _q(s.amount)
        amount !== nothing && iszero(amount) && (amount = nothing)
        Tw = s.infuse_temperature === nothing ? nothing : _q(s.infuse_temperature)
        if kind in ("infusion", "temperature")
            if isempty(rests) && amount === nothing
                ratio = s.water_grain_ratio === nothing ? mash_ratio : _q(s.water_grain_ratio)
                amount = uconvert(u"L", ratio * grist)
            elseif kind == "infusion" && amount === nothing
                # the water at the infusion temperature that raises the mash to this step
                amount = uconvert(u"L", infusion_volume(rests[end].temperature, T, water, grist;
                                                        infusion_temperature = something(Tw, 100u"°C")))
            end
            amount === nothing || (water += amount)
            push!(rests, (kind = Symbol(kind), temperature = T, time = t, water = amount,
                          water_temperature = something(Tw, isempty(rests) ? T : 100u"°C"),
                          decoction = nothing, decoction_time = nothing))
        elseif kind == "decoction"
            isempty(rests) && throw(ArgumentError(
                "a decoction needs a mash to decoct: it cannot be the first step (in $(repr(r.name)))"))
            dt = s.ramp_time === nothing ? decoction_time : _q(s.ramp_time)
            push!(rests, (kind = :decoction, temperature = T, time = t, water = nothing,
                          water_temperature = T, decoction = amount,
                          decoction_time = uconvert(u"minute", float(dt))))
        elseif kind == "sparge"
            push!(sparges, (amount, T))
        elseif kind == "drain mash tun"
            continue
        else
            throw(ArgumentError("mash steps of type $(repr(kind)) are not supported yet " *
                                "(in $(repr(r.name)))"))
        end
    end
    isempty(rests) && push!(rests, (kind = :infusion, temperature = 67u"°C", time = 60u"minute",
                                    water = uconvert(u"L", mash_ratio * grist),
                                    water_temperature = 67u"°C", decoction = nothing,
                                    decoction_time = nothing))
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

# the evaporation of a boiling decoction, relative to its volume
const DECOCTION_EVAPORATION = 10.0u"percent/hr"

# the fraction of a mash at `T1` to decoct (taken to boiling, 100 °C) to bring the mash to
# `T2` when returned, by the mixing of the quiver (by mass, as water)
_decoction_fraction(T1, T2) =
    clamp(float(uconvert(NoUnits, (_temperature(T2) - _temperature(T1)) /
                                  (100.0u"°C" - _temperature(T1)))), 0.0, 1.0)

# The stand and the chilling after the boil, from the boil steps: after the step of the
# boil (the first one at 99 °C or more), the steps ending at 60 °C or more are a stand, at
# the temperature they end at, and the others chill the wort. Returns (stand, stand
# temperature or `nothing`, chilling time).
function _boil_steps(r)
    stand, T, chill = 0.0u"minute", nothing, 0.0u"minute"
    (r.boil === nothing || r.boil.boil_steps === nothing) && return (stand, T, chill)
    steps = r.boil.boil_steps
    hot(x) = x !== nothing && _q(x) ≥ 99u"°C"
    k = findfirst(s -> hot(s.start_temperature) && (s.end_temperature === nothing || hot(s.end_temperature)), steps)
    k === nothing && return (stand, T, chill)
    for s in steps[k + 1:end]
        t = s.step_time === nothing ? 0.0u"minute" : uconvert(u"minute", float(_q(s.step_time)))
        e = s.end_temperature === nothing ? nothing : uconvert(u"°C", float(_q(s.end_temperature)))
        if e !== nothing && e ≥ 60u"°C"
            stand += t
            T = e
        else
            chill += t
        end
    end
    return (stand, T, chill)
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

The `equipment` (a BeerJSON `EquipmentType`) is attached to the vessels `:mashtun`,
`:kettle` and `:fermentor` (see [`Vessel`](@ref) and [`equip!`](@ref)), giving the grain
absorption, dead spaces and losses, the boil rate, the capacities and the drain rates; the
evaporation rate and kettle loss solved for the recipe are attached to the kettle. The `calibration` ([`NoCalibration`](@ref)
or [`BrewhouseEfficiency`](@ref)) sets the conversion of the mash. Cultures without
attenuation get the apparent attenuation of the recipe's original and final gravities, or
else `attenuation`, with a warning.

The timings of the additions follow BeerJSON (format 3.0): in the boil, `time` counts back
from the end of the boil ([`Remaining`](@ref)), and an addition with only a `duration`
steeps after the boil, in a stand (see [`Boil`](@ref)); in the mash, the
fermentation and the packaging, `time` counts forward from the start of the step
([`At`](@ref)), and an addition with only a `duration` stays until the end of the step.
Hops added to the mash are taken as first wort hops, boiling for the whole boil; hops
added to the boil earlier than the boil starts (as in documents converted from BeerXML
before the importer of BeerJSON was fixed) are taken as dry hops, with a warning.
Infusion steps without an amount get the water that raises the mash to their temperature
(`infusion_volume`); decoction steps boil the volume of mash they give (or the fraction
that reaches their temperature) for their ramp time, or else `decoction_time`, in the
kettle, evaporating 10% of their volume per hour, and return it to the mash tun (`:decoction_k`, `:decoction_k_boiled`,
`:mash_k_in`). The boil steps after the boil give a stand (at the temperature they end at,
or else `stand_temperature`) and the time of the chilling; additions steeping after the
boil set the length of the stand. Miscellaneous and water additions are not used yet.
Souring steps are not supported yet.
"""
function Quiver(r::BJ.RecipeType; equipment::Union{Nothing, BJ.EquipmentType} = nothing,
                calibration::AbstractCalibration = NoCalibration(),
                mash_ratio = 3u"L/kg", attenuation = 75u"percent",
                decoction_time = 15u"minute", stand_temperature = 80u"°C")
    vessels = _equipment(equipment)
    kv = get(vessels, :kettle, Vessel(name = "Kettle"))
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

    # the stand after the boil: from the boil steps, or the longest steep of the additions;
    # an addition steeping less than the stand is added during it
    stand, stand_T, chill_time = _boil_steps(r)
    steeps = [a[4].time for a in adds if a[4] isa _Steep]
    stand = max(stand, maximum(steeps; init = 0.0u"minute"))
    adds = [a[4] isa _Steep ? (a[1], a[2], a[3], a[4].time ≥ stand ? Remaining(0u"minute") :
                                                  At(boil_time + stand - a[4].time)) : a
            for a in adds]

    # volumes and rates
    kettle_loss = kv.dead_space
    pre_boil = r.boil === nothing || r.boil.pre_boil_size === nothing ? nothing :
               uconvert(u"L", _q(r.boil.pre_boil_size))
    rate = something(kv.evaporation,
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
        rests, sparges = _mash_steps(r, grist, mash_ratio, decoction_time)
        stage_node[:mash] = :mash
        add!(q, :strike_water, water(rests[1].water; temperature = rests[1].water_temperature))
        for (k, rest) in enumerate(rests)
            k > 1 && rest.water !== nothing &&
                add!(q, Symbol(:infusion_, k), water(rest.water; temperature = rest.water_temperature))
        end
        isempty(sparges) && push!(sparges, (nothing, 76u"°C"))
        for (k, s) in enumerate(sparges)
            add!(q, Symbol(:sparge_water_, k), water(something(s[1], 0u"L"); temperature = s[2]))
        end
        add!(q, :mash; vessel = :mashtun)
        for (k, rest) in enumerate(rests)
            rest.kind === :decoction && add!(q, Symbol(:mash_, k, :_in); vessel = :mashtun)
            add!(q, Symbol(:mash_, k); vessel = :mashtun)
            rest.kind === :decoction &&
                add!(q, Symbol(:decoction_, k), Symbol(:decoction_, k, :_boiled); vessel = :kettle)
        end
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
    # the equipment: what the arrows leaving the stages of each vessel take
    haskey(vessels, :mashtun) && equip!(q, :mashtun, vessels[:mashtun])
    kv = _with(kv; evaporation = rate)
    equip!(q, :kettle, kv)
    haskey(vessels, :fermentor) && equip!(q, :fermentor, vessels[:fermentor])
    mashrest(rest, c) = MashRest(temperature = rest.temperature, time = rest.time, conversion = c)
    # the node each rest starts from: the mash before it, or the mash with the decoction back
    rest_source(k) = k == 1 ? :mash : rests[k].kind === :decoction ? Symbol(:mash_, k, :_in) :
                     Symbol(:mash_, k - 1)
    if !isempty(mashed)
        connect!(q, :strike_water => :mash)
        water_before = 0.0u"L"
        for (k, rest) in enumerate(rests)
            if rest.kind === :decoction
                # a part of the mash is boiled and returned, to raise it to the next rest
                prev, pot, boiled = Symbol(:mash_, k - 1), Symbol(:decoction_, k), Symbol(:decoction_, k, :_boiled)
                f = rest.decoction === nothing ? _decoction_fraction(rests[k - 1].temperature, rest.temperature) :
                    clamp(float(uconvert(NoUnits, rest.decoction / mash_volume(water_before, grist))), 0.0, 1.0)
                connect!(q, prev => pot, Transfer(f))
                connect!(q, prev => rest_source(k))
                # (a pot of thick mash evaporates little: a rate relative to its volume)
                connect!(q, pot => boiled, Boil(time = rest.decoction_time,
                                                evaporation = DECOCTION_EVAPORATION))
                connect!(q, boiled => rest_source(k))
            end
            if k > 1 && rest.water !== nothing
                connect!(q, Symbol(:infusion_, k) => rest_source(k))
            end
            rest.water === nothing || (water_before += rest.water)
            connect!(q, rest_source(k) => Symbol(:mash_, k), mashrest(rest, conversion))
        end
        prev = Symbol(:mash_, length(rests))
        drain = Drain()
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
    connect!(q, :kettle => :wort, Boil(time = boil_time, stand = stand,
                                        stand_temperature = something(stand_T, stand_temperature)))
    connect!(q, :wort => :chilled, Chill(temperature = Tferm, time = chill_time))
    connect!(q, :chilled => :fermentor, Drain())
    has_culture = any(a -> a[1] isa Culture && a[3] === :fermentation, adds)
    connect!(q, :fermentor => :beer,
             Ferment(temperature = Tferm, time = tferm,
                     attenuation = has_culture ? nothing : something(att, attenuation)))
    connect!(q, :beer => :packaging, Drain())
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
            equip!(q, :kettle, _with(kv; dead_space = loss))
        end
        if calibration isa BrewhouseEfficiency && !isempty(mashed)
            e = _brewhouse_efficiency(res, q)
            new = clamp(conversion * target / e, 0.0, 1.0)
            moved |= abs(new - conversion) > 1e-9
            conversion = new
            for (k, rest) in enumerate(rests)
                q[rest_source(k) => Symbol(:mash_, k)] = mashrest(rest, conversion)
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
