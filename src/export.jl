# Export to BeerJSON: a recipe for each product of a quiver. BeerJSON recipes are linear, so
# each holds the shares of the lots used for its product (see `attribution`), with the
# procedures of the mash tuns, kettles and fermentors that serve it.

const _BJI, _BJT = Int64, Float64

# the stage of the node `n`, from the transformation that follows it, and that
# transformation (or `nothing`)
function _stage(q::Quiver, n::Symbol)
    seen = Set{Symbol}()
    while !(n in seen)
        push!(seen, n)
        outs = _outgoing(q, n)
        isempty(outs) && return :package, nothing
        for (_, _, a) in outs
            a isa MashRest && return :mash, a
            a isa Union{Boil, Chill} && return :boil, a
            a isa Ferment && return :fermentation, a
            a isa Union{Prime, Carbonate} && return :package, a
        end
        n = first(outs)[1]
    end
    return :package, nothing
end

const _USES = Dict(:mash => "add_to_mash", :boil => "add_to_boil",
                   :fermentation => "add_to_fermentation", :package => "add_to_package")

# (in whole minutes, or whole days when it is a number of days)
function _timetype(t)
    m = round(Int, ustrip(u"minute", t))
    m ≥ 1440 && m % 1440 == 0 && return BJ.TimeType{_BJI, _BJT}((m ÷ 1440) * u"d")
    return BJ.TimeType{_BJI, _BJT}(m * u"minute")
end

# the BeerJSON timing of an addition to a stage (see `_timing` for the import)
function _bj_timing(stage, timing, t)
    kw = Dict{Symbol, Any}(:use => _USES[stage])
    if stage === :boil
        total = t isa Boil ? t.time : 0.0u"minute"        # (a Chill: at the end of the boil)
        # (counting back from the end of the boil)
        kw[:time] = _timetype(duration_in(timing, total))
    elseif timing isa At
        kw[:time] = _timetype(timing.time)
    elseif timing isa Remaining
        kw[:duration] = _timetype(timing.time)
    end
    return BJ.TimingType{_BJI, _BJT}(; kw...)
end

_bj_amount(a::KgQ) = BJ.MassType{_BJI, _BJT}(a)
_bj_amount(n::Float64) = BJ.UnitType{_BJI, _BJT}(n; unit = "pkg")

const _KINDS = Dict(v => k for (k, v) in FERMENTABLE_KINDS)
const _FORMS = Dict(v => k for (k, v) in HOP_FORMS)

_addition(f::Fermentable, amount, timing) = BJ.FermentableAdditionType{_BJI, _BJT}(
    name = f.name, type = _KINDS[f.kind],
    yield = (fine_grind = BJ.PercentType{_BJI, _BJT}(100f.yield * u"percent"),),
    color = BJ.ColorType{_BJI, _BJT}(f.color), amount = _bj_amount(amount), timing = timing)
_addition(h::Hop, amount, timing) = BJ.HopAdditionType{_BJI, _BJT}(
    name = h.name, form = get(_FORMS, h.form, "pellet"),
    alpha_acid = BJ.PercentType{_BJI, _BJT}(100h.alpha * u"percent"),
    amount = _bj_amount(amount), timing = timing)
_addition(c::Culture, amount, timing) = BJ.CultureAdditionType{_BJI, _BJT}(
    name = c.name, type = string(c.kind), form = string(c.form),
    attenuation = BJ.PercentType{_BJI, _BJT}(100c.attenuation * u"percent"),
    amount = _bj_amount(amount), timing = timing)

# the beer of a product, before any priming or carbonation
function _beer(res, q, product)
    n = product
    while length(predecessors(q, n)) ≥ 1
        ps = [p for p in predecessors(q, n) if any(a -> a isa Union{Prime, Carbonate}, q[p => n])]
        isempty(ps) && break
        n = only(ps)
    end
    return liquor(res[n])
end

# the transformations of type `T` serving the product, as (source, transformation, share)
_serving(::Type{T}, q, a) where {T} =
    [(s, t, a[s]) for (s, d, t) in arrows(q) if t isa T && get(a, s, 0.0) > 0]

_dominant(xs, weight) = isempty(xs) ? nothing : xs[argmax([weight(x) for x in xs])]

"""
    recipe(res::BrewResult, q::Quiver, product; name = string(product), author = "",
           notes = nothing) -> BeerJSON.RecipeType

The BeerJSON recipe of a `product` (a node) of the brew `res` of `q`. BeerJSON recipes are
linear, so the recipe holds the shares of the lots used for the product (see
[`attribution`](@ref)): its ingredient additions, by their stage and timing, and the water
of its mash steps and sparges, gathered over the mash tuns that serve it, with the
procedures of the mash tun, kettle and fermentor that serve it most. Its batch size is the
volume reaching the fermentors for the product, its pre-boil size the volume in the
kettles, its efficiency the brewhouse efficiency of those fermentors, and its gravities,
alcohol, color and carbonation those of the product, before any priming.
"""
function recipe(res::BrewResult, q::Quiver, product::Symbol; name::AbstractString = string(product),
                author::AbstractString = "", notes = nothing)
    a = attribution(res, q, product)

    # the ingredient additions, merged by ingredient, stage and timing
    adds = Dict{Any, Any}()
    order = []
    potential = 0.0u"kg"
    for l in res.order
        _issource(q, l) && a[l] > 0 || continue
        for d in successors(q, l), r in res[l => d]
            w = get(a, d, 0.0)
            w > 0 || continue
            stage, t = _stage(q, d)
            for s in solids(w * r.moved)
                s isa Portion || continue
                k = (s.ingredient, stage, s.timing)
                haskey(adds, k) || (push!(order, k); adds[k] = (0 * s.amount, t))
                adds[k] = (adds[k][1] + s.amount, t)
                if s.ingredient isa Fermentable && stage in (:mash, :boil)
                    potential += potential_extract(s.amount, s.ingredient.yield;
                                                   moisture = s.ingredient.moisture)
                end
            end
        end
    end
    fermentables = [_addition(k[1], adds[k][1], _bj_timing(k[2], k[3], adds[k][2]))
                    for k in order if k[1] isa Fermentable]
    hops = [_addition(k[1], adds[k][1], _bj_timing(k[2], k[3], adds[k][2]))
            for k in order if k[1] isa Hop]
    cultures = [_addition(k[1], adds[k][1], _bj_timing(k[2], k[3], adds[k][2]))
                for k in order if k[1] isa Culture]

    # the mash: the rests of the main mash tun, with the water gathered over the mash tuns
    rests = _serving(MashRest, q, a)
    main = _dominant(rests, x -> x[3] * ustrip(u"kg", grist(res[x[1]])))
    mash = nothing
    if main !== nothing
        tun = vessel(q, main[1])
        chain = [x for x in rests if vessel(q, x[1]) == tun]
        waters(n) = [r.moved for l in predecessors(q, n) if _issource(q, l)
                     for r in res[l => n] if isempty(solids(r.moved)) && !iszero(r.moved)]
        water_into(n) = sum((a[n] * volume(w) for w in waters(n)); init = 0.0u"L")
        water_temperature(n) = (ws = waters(n); isempty(ws) ? nothing : liquor(sum(ws)).temperature)
        # the water of each rest, and of the sparges, of all the mash tuns, by their order
        rest_water = zeros(typeof(1.0u"L"), length(chain))
        infuse = Union{Nothing, typeof(1.0u"°C")}[water_temperature(x[1]) for x in chain]
        sparges = typeof(1.0u"L")[]
        temps = typeof(1.0u"°C")[]
        for v in unique(vessel(q, x[1]) for x in rests)
            vs = [x for x in rests if vessel(q, x[1]) == v]
            for (k, x) in enumerate(vs)
                k ≤ length(rest_water) && (rest_water[k] += water_into(x[1]))
            end
            beds = [n for n in res.order if vessel(q, n) == v && get(a, n, 0.0) > 0 &&
                    !any(x -> x[1] == n, vs) && any(x -> x isa Drain, (b for (_, _, b) in _outgoing(q, n)))]
            k = 0
            for bed in beds
                w = water_into(bed)
                iszero(w) && continue
                k += 1
                k > length(sparges) && (push!(sparges, 0.0u"L"); push!(temps, 20.0u"°C"))
                sparges[k] += w
                temps[k] = something(water_temperature(bed), temps[k])
            end
        end
        steps = [BJ.MashStepType{_BJI, _BJT}(
                     name = k == 1 ? "Mash in" : "Rest $k", type = k == 1 ? "infusion" : "temperature",
                     amount = iszero(rest_water[k]) ? nothing : BJ.VolumeType{_BJI, _BJT}(rest_water[k]),
                     infuse_temperature = infuse[k] === nothing ? nothing :
                                          BJ.TemperatureType{_BJI, _BJT}(infuse[k]),
                     step_temperature = BJ.TemperatureType{_BJI, _BJT}(x[2].temperature),
                     step_time = _timetype(x[2].time)) for (k, x) in enumerate(chain)]
        for (k, v) in enumerate(sparges)
            push!(steps, BJ.MashStepType{_BJI, _BJT}(
                name = "Sparge $k", type = "sparge", amount = BJ.VolumeType{_BJI, _BJT}(v),
                step_temperature = BJ.TemperatureType{_BJI, _BJT}(temps[k]),
                step_time = _timetype(0u"minute")))
        end
        mash = BJ.MashProcedureType{_BJI, _BJT}(
            name = "Mash", grain_temperature = BJ.TemperatureType{_BJI, _BJT}(20u"°C"),
            mash_steps = steps)
    end

    # the boil
    boils = _serving(Boil, q, a)
    b = _dominant(boils, x -> x[3] * ustrip(u"L", volume(res[x[1]])))
    boil = b === nothing ? nothing : BJ.BoilProcedureType{_BJI, _BJT}(
        name = "Boil",
        pre_boil_size = BJ.VolumeType{_BJI, _BJT}(sum(x[3] * volume(res[x[1]]) for x in boils)),
        boil_time = _timetype(b[2].time))

    # the fermentation, the batch size and the efficiency
    ferments = _serving(Ferment, q, a)
    f = _dominant(ferments, x -> x[3] * ustrip(u"L", volume(res[x[1]])))
    fermentation = f === nothing ? nothing : BJ.FermentationProcedureType{_BJI, _BJT}(
        name = "Fermentation",
        fermentation_steps = [BJ.FermentationStepType{_BJI, _BJT}(
            name = "Primary", start_temperature = BJ.TemperatureType{_BJI, _BJT}(f[2].temperature),
            step_time = _timetype(f[2].time))])
    batch = isempty(ferments) ? volume(res[product]) : sum(x[3] * volume(res[x[1]]) for x in ferments)
    got = isempty(ferments) ? (l = liquor(res[product]); l.extract + 2.0665 * l.alcohol) :
          sum(x[3] * (liquor(res[x[1]]).extract + 2.0665 * liquor(res[x[1]]).alcohol) for x in ferments)
    efficiency = iszero(potential) ? 0.0 : float(uconvert(NoUnits, got / potential))

    # the beer
    beer = _beer(res, q, product)
    kinds = Set(k[1].kind for k in order if k[1] isa Fermentable)
    type = :grain in kinds ? (isempty(intersect(kinds, (:extract, :dry_extract))) ? "all grain" : "partial mash") :
           isempty(intersect(kinds, (:extract, :dry_extract))) ? "other" : "extract"
    method = Dict(Tinseth => "Tinseth", Rager => "Rager")
    carbonated = any(t isa Union{Prime, Carbonate} for (s, d, t) in arrows(q) if get(a, s, 0.0) > 0)
    P(x) = BJ.PercentType{_BJI, _BJT}(uconvert(u"percent", x))
    return BJ.RecipeType{_BJI, _BJT}(
        name = name, type = type, author = author,
        batch_size = BJ.VolumeType{_BJI, _BJT}(batch),
        efficiency = (brewhouse = P(efficiency),),
        ingredients = (fermentable_additions = fermentables,
                       hop_additions = isempty(hops) ? nothing : hops,
                       culture_additions = isempty(cultures) ? nothing : cultures),
        mash = mash, boil = boil, fermentation = fermentation,
        notes = something(notes, "Exported by BrewQuiver from the node :$product of a quiver; " *
                          "the amounts are the shares of its lots used for it."),
        original_gravity = BJ.GravityType{_BJI, _BJT}(original_gravity(beer; eq = res.models.gravity)),
        final_gravity = BJ.GravityType{_BJI, _BJT}(gravity(beer; eq = res.models.gravity)),
        alcohol_by_volume = P(abv(beer; eq = res.models.gravity)),
        apparent_attenuation = P(apparent_attenuation(beer)),
        ibu_estimate = (method = get(method, typeof(res.models.bitterness), "Other"),),
        color_estimate = BJ.ColorType{_BJI, _BJT}(srm(res.models.color, beer; eq = res.models.gravity)),
        carbonation = carbonated ? ustrip(u"vols", carbonation(res[product]; eq = res.models.gravity)) : nothing)
end

"""
    recipes(res::BrewResult, q::Quiver; products = keys of products(res, q), author = "")

The BeerJSON recipes of the `products` of the brew `res` of `q` (see [`recipe`](@ref)), in
the order of the quiver.
"""
recipes(res::BrewResult, q::Quiver; products = [n for n in res.order if isempty(successors(q, n))],
        author::AbstractString = "") =
    [recipe(res, q, p; author) for p in res.order if p in products]

"""
    write_beerjson(path, res::BrewResult, q::Quiver; products = ..., author = "")

Writes the BeerJSON recipes of the `products` of the brew `res` of `q` (see
[`recipes`](@ref)) to a BeerJSON document at `path`.
"""
function write_beerjson(path::AbstractString, res::BrewResult, q::Quiver; kwargs...)
    doc = BJ.BeerJSONParser{_BJI, _BJT}(beerjson = (version = 1.0, recipes = recipes(res, q; kwargs...)))
    BJ.writejson(path, doc)
    return path
end
