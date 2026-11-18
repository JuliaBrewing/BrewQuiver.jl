# Files of quivers: a quiver as a JSON Graph Format (JGF) document, with its ingredients as
# BeerJSON catalogue records, read and written with `readjson` and `writejson` (the
# functions of BeerJSON.jl, with methods for quivers, brew results and libraries).
#
# The document:
#
#     {"graph": {
#         "type": "brewquiver", "directed": true,
#         "metadata": {"format": "BrewQuiver", "format_version": 1, "brewquiver_version": ...,
#                      "ingredients": {"fermentables": [...], "hop_varieties": [...], "cultures": [...]},
#                      "equipment": {"<vessel>": {...}},
#                      "computed": {"models": {...}, "brewquiver_version": ...}},   (optional)
#         "nodes": {"<label>": {"label": ..., "metadata": {"rank": ..., "vessel": ...,
#                   "initial": {...}, "view": {...}, "computed": {...}}}},   (no "initial": empty)
#         "edges": [{"source": ..., "target": ..., "relation": "<arrow type>",
#                    "metadata": {"arrow": {...}}}]}}
#
# Quantities are {"unit": ..., "value": ...}, as in BeerJSON; the other structs are objects
# of their fields, with their "type". The lots refer to their ingredients by name.

const FORMAT_VERSION = 1

# the units written, by name (a quantity is written in the unit of its type)
const _UNITS = ["kg" => u"kg", "g" => u"g", "mg" => u"mg", "l" => u"L", "ml" => u"mL",
    "min" => u"minute", "hr" => u"hr", "day" => u"d", "C" => u"°C", "l/kg" => u"L/kg",
    "l/hr" => u"L/hr", "1/hr" => u"hr^-1", "l/min" => u"L/minute", "vols" => u"vols",
    "SRM" => u"SRM", "mg/l" => u"mg/L", "g/ml" => u"g/mL", "sg" => u"sg", "IBU" => u"IBU",
    "%" => u"percent"]

function _jsunit(q::Unitful.Quantity)
    u = unit(q)
    for (name, v) in _UNITS
        v == u && return name
    end
    throw(ArgumentError("a quantity in $u cannot be written to a file of quivers"))
end
function _unit(name::AbstractString)
    for (n, v) in _UNITS
        n == name && return v
    end
    throw(ArgumentError("the unit $(repr(name)) is not known in files of quivers"))
end

# the types written as objects with their "type", by name: arrows, timings, solids, liquors,
# vessels, priming sugars; a new arrow type is added with `register_json_type`
const _JSON_TYPES = Dict{String, Any}()

"""
    BrewQuiver.register_json_type(T)

Lets the files of quivers (see `writejson`) write and read the values of the type `T`, e.g.
a new [`AbstractArrow`](@ref): as an object of its fields, with its `"type"`, rebuilt with
its constructor of all its fields in order.
"""
register_json_type(T) = (_JSON_TYPES[string(nameof(T))] = T; T)

for T in (Transfer, Drain, MashRest, Boil, Chill, Ferment, Prime, Carbonate, Remaining, At,
          Residue, HopMatter, YeastCake, Liquor, Minerals, Contents, Vessel,
          Sucrose, Glucose, CornSugar, PrimingSugar)
    register_json_type(T)
end

# Julia values to JSON values
_tojs(::Nothing) = nothing
_tojs(x::Union{Bool, Real, AbstractString}) = x
_tojs(x::Symbol) = String(x)
_tojs(x::Unitful.Quantity) = Dict{String, Any}("unit" => _jsunit(x), "value" => ustrip(x))
_tojs(x::AbstractVector) = Any[_tojs(v) for v in x]
_tojs(x::AbstractDict) = Dict{String, Any}(String(k) => v for (k, v) in x)
function _tojs(x::T) where {T}
    name = string(nameof(T))
    haskey(_JSON_TYPES, name) || throw(ArgumentError(
        "$(nameof(T)) cannot be written to a file of quivers: register it with " *
        "`BrewQuiver.register_json_type`"))
    d = Dict{String, Any}("type" => name)
    for f in fieldnames(T)
        v = getfield(x, f)
        v === nothing || (d[String(f)] = _tojs(v))
    end
    return d
end
# the portions refer to their ingredient by name
_tojs(p::Portion) = Dict{String, Any}("type" => "Portion", "ingredient" => p.ingredient.name,
                                      "amount" => _tojs(p.amount), "timing" => _tojs(p.timing))

# JSON values to Julia values of the type `T`, with the ingredients by name
function _fromjs(T, v, ingredients)
    v === nothing && return nothing
    if v isa AbstractDict && haskey(v, "unit")
        return _fit(T, v["value"] * _unit(v["unit"]))
    elseif v isa AbstractDict && get(v, "type", nothing) == "Portion"
        i = get(ingredients, v["ingredient"], nothing)
        i === nothing && throw(ArgumentError("the ingredient $(repr(v["ingredient"])) is not in the file"))
        amount = _fromjs(Union{KgQ, Float64}, v["amount"], ingredients)
        return Portion(i, amount, _fromjs(Union{Nothing, AbstractTiming}, get(v, "timing", nothing), ingredients))
    elseif v isa AbstractDict && haskey(v, "type")
        S = get(_JSON_TYPES, v["type"], nothing)
        S === nothing && throw(ArgumentError("the type $(repr(v["type"])) is not known in files " *
                                             "of quivers: register it with `BrewQuiver.register_json_type`"))
        vals = [_fromjs(fieldtype(S, f), get(v, String(f), nothing), ingredients) for f in fieldnames(S)]
        return S(vals...)
    elseif v isa AbstractVector
        E = T isa Type && T <: AbstractVector ? eltype(T) : Any
        return E[_fromjs(E, x, ingredients) for x in v]
    elseif T isa Type && Symbol <: T && v isa AbstractString
        return Symbol(v)
    elseif v isa Real && !(v isa Bool) && T isa Type && Float64 <: T
        return float(v)
    end
    return v
end
# a quantity in the unit of the quantity type `T` (or of the member of a union of its dimension)
function _fit(T, q)
    T isa Type || return q
    for U in Base.uniontypes(T)
        U <: Unitful.Quantity && isconcretetype(U) && dimension(U) == dimension(q) &&
            return convert(U, uconvert(unit(U), q))
    end
    return q
end

# Ingredients: as BeerJSON catalogue records, by name
function _ingredients(q::Quiver)
    byname = Dict{String, AbstractIngredient}()
    for n in nodes(q), s in solids(q[n].initial)
        s isa Portion || continue
        i = s.ingredient
        haskey(byname, i.name) && byname[i.name] != i && throw(ArgumentError(
            "two different ingredients are named $(repr(i.name)): rename one to write the quiver"))
        byname[i.name] = i
    end
    records(T) = [let r = _record(i, nothing)
                      i isa Fermentable && i.buffering !== nothing && (r._extra["buffering"] = i.buffering)
                      BJ.todict(r)
                  end for i in sort!([i for i in values(byname) if i isa T]; by = i -> i.name)]
    return Dict{String, Any}("fermentables" => records(Fermentable),
                             "hop_varieties" => records(Hop), "cultures" => records(Culture))
end

function _read_ingredients(d)
    out = Dict{String, AbstractIngredient}()
    d === nothing && return out
    for x in get(d, "fermentables", [])
        r = BJ.fromdict(BJ.FermentableType{_BJI, _BJT}, x)
        f = Fermentable(r)
        b = get(r._extra, "buffering", nothing)
        b === nothing || (f = Fermentable(f.name, f.kind, f.yield, f.color, f.moisture, f.di_ph, float(b)))
        out[f.name] = f
    end
    for x in get(d, "hop_varieties", [])
        h = Hop(BJ.fromdict(BJ.VarietyInformation{_BJI, _BJT}, x))
        out[h.name] = h
    end
    for x in get(d, "cultures", [])
        c = Culture(BJ.fromdict(BJ.CultureInformation{_BJI, _BJT}, x))
        out[c.name] = c
    end
    return out
end

# the values computed by a brew, for the readers of the file
function _computed(res::BrewResult, n::Symbol)
    c = res[n]
    iszero(mass(c.liquor)) && return nothing
    eq, color = res.models.gravity, res.models.color
    d = Dict{String, Any}(
        "volume" => _tojs(uconvert(u"L", volume(c; eq))),
        "gravity" => _tojs(gravity(c; eq)), "original_gravity" => _tojs(original_gravity(c; eq)),
        "abv" => _tojs(uconvert(u"percent", abv(res.models.abv, c; eq))), "ibu" => _tojs(ibu(c; eq)),
        "color" => _tojs(srm(color, c; eq)), "carbonation" => _tojs(carbonation(c; eq)),
        "temperature" => _tojs(liquor(c).temperature))
    if any(s -> s isa Portion{Fermentable, KgQ} && !soluble(s.ingredient), c.solids)
        d["mash_ph"] = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            mash_ph(c)
        end
    end
    return d
end

function _document(q::Quiver, res)
    order = nodes(q)
    rank = Dict(n => k for (k, n) in enumerate(sort(order; by = n -> q.rank[n])))
    meta = Dict{String, Any}("format" => "BrewQuiver", "format_version" => FORMAT_VERSION,
        "brewquiver_version" => string(pkgversion(@__MODULE__)),
        "ingredients" => _ingredients(q),
        "equipment" => Dict{String, Any}(String(k) => _tojs(v) for (k, v) in q.equipment))
    if res !== nothing
        meta["computed"] = Dict{String, Any}(
            "models" => Dict{String, Any}(String(k) => string(nameof(typeof(v))) for (k, v) in pairs(res.models)),
            "brewquiver_version" => string(pkgversion(@__MODULE__)))
    end
    nodes_ = Dict{String, Any}()
    for n in order
        node = q[n]
        m = Dict{String, Any}("rank" => rank[n])
        # the stages filled by arrows start empty
        node.initial ≈ Contents() || (m["initial"] = _tojs(node.initial))
        node.vessel === nothing || (m["vessel"] = String(node.vessel))
        isempty(node.view) || (m["view"] = node.view)
        if res !== nothing && haskey(res.nodes, n)
            c = _computed(res, n)
            c === nothing || (m["computed"] = c)
        end
        nodes_[String(n)] = Dict{String, Any}("label" => String(n), "metadata" => m)
    end
    edges = [Dict{String, Any}("source" => String(s), "target" => String(d),
                               "relation" => string(nameof(typeof(a))),
                               "metadata" => Dict{String, Any}("arrow" => _tojs(a)))
             for n in order for (s, d, a) in arrows(q) if s == n]
    return Dict{String, Any}("graph" => Dict{String, Any}("type" => "brewquiver", "directed" => true,
        "metadata" => meta, "nodes" => nodes_, "edges" => edges))
end

"""
    writejson(path_or_io, q::Quiver; results = nothing)

Writes the quiver `q` as a JSON Graph Format (JGF) document: its nodes (with their initial
contents, vessel, and the free data of [`nodeview`](@ref)), its arrows as edges, in order,
its equipment, and its ingredients as BeerJSON catalogue records. With the brew `results` of
`q`, each node also gets the values `computed` by it (volume, gravities, alcohol,
bitterness, color, carbonation, temperature, and the mash pH of mashes), for other readers
of the file; [`readjson`](@ref) ignores them, and they are computed again by [`brew`](@ref).

```julia
writejson("bitter.quiver.json", q; results = brew(q))
q = readjson(Quiver, "bitter.quiver.json")
```
"""
function BJ.writejson(io::IO, q::Quiver; results::Union{Nothing, BrewResult} = nothing)
    JSON.json(io, _document(q, results); pretty = true)
    return nothing
end
function BJ.writejson(path::AbstractString, q::Quiver; kwargs...)
    open(io -> BJ.writejson(io, q; kwargs...), path, "w")
    return path
end

"""
    readjson(Quiver, path_or_io)

The quiver of a file written by [`writejson`](@ref) (see there for the format). The values
computed by a brew, if any, are ignored.
"""
BJ.readjson(::Type{Quiver}, path::AbstractString) = open(io -> BJ.readjson(Quiver, io), path)
function BJ.readjson(::Type{Quiver}, io::IO)
    doc = JSON.parse(read(io, String))
    g = get(doc, "graph", nothing)
    g === nothing && throw(ArgumentError("this is not a file of a quiver: it has no \"graph\""))
    meta = get(g, "metadata", Dict{String, Any}())
    v = get(meta, "format_version", nothing)
    v isa Integer && v ≤ FORMAT_VERSION || throw(ArgumentError(
        "the file of the quiver has the format version $(repr(v)); this BrewQuiver reads up to $FORMAT_VERSION"))
    ingredients = _read_ingredients(get(meta, "ingredients", nothing))
    q = Quiver()
    for (name, e) in get(meta, "equipment", Dict())
        equip!(q, Symbol(name), _fromjs(Vessel, e, ingredients))
    end
    ns = sort!(collect(get(g, "nodes", Dict())); by = p -> p.second["metadata"]["rank"])
    for (label, node) in ns
        m = node["metadata"]
        vessel = get(m, "vessel", nothing)
        initial = haskey(m, "initial") ? _fromjs(Contents, m["initial"], ingredients) : Contents()
        add!(q, Symbol(label), initial;
             vessel = vessel === nothing ? nothing : Symbol(vessel))
        haskey(m, "view") && merge!(nodeview(q, Symbol(label)), Dict{String, Any}(m["view"]))
    end
    for e in get(g, "edges", [])
        a = _fromjs(AbstractArrow, e["metadata"]["arrow"], ingredients)
        connect!(q, Symbol(e["source"]) => Symbol(e["target"]), a)
    end
    return q
end

function write_beerjson(args...; kwargs...)
    Base.depwarn("`write_beerjson` is deprecated, use `writejson`", :write_beerjson)
    return BJ.writejson(args...; kwargs...)
end

"""
    readjson(Library, path)

The [`Library`](@ref) of a BeerJSON document, as `Library(path)`.
"""
BJ.readjson(::Type{Library}, path::AbstractString) = Library(path)
