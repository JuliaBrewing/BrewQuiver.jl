# An ingredient library and inventory: the ingredients known by name, with what is in
# stock, loaded from and written to BeerJSON documents, and checked against brews.

"""
    Library()
    Library(sources...)

A library of ingredients ([`Fermentable`](@ref), [`Hop`](@ref), [`Culture`](@ref)) by name,
with their stock: a mass, a volume or a count, or `nothing` when not known. The `sources`
are BeerJSON documents (`BeerJSONParser`) or the paths of BeerJSON files, whose fermentable,
hop and culture records (with their inventory) are loaded in order.

`lib[name]` is an ingredient, to be used in lots (`add!(q, :pale, lib["Pale ale malt"] =>
4u"kg")`); see also [`stock`](@ref), [`lookup`](@ref), [`shortages`](@ref) and
[`consume!`](@ref).
"""
struct Library
    ingredients::Dict{String, AbstractIngredient}
    stock::Dict{String, Any}
end
Library() = Library(Dict{String, AbstractIngredient}(), Dict{String, Any}())

function Library(sources...)
    lib = Library()
    for s in sources
        merge!(lib, s isa AbstractString ? BJ.readjson(BJ.BeerJSONParser, s) : s)
    end
    return lib
end

Base.getindex(lib::Library, name::AbstractString) = get(lib.ingredients, name) do
    throw(KeyError(name))
end
Base.haskey(lib::Library, name::AbstractString) = haskey(lib.ingredients, name)
Base.keys(lib::Library) = sort!(collect(keys(lib.ingredients)))
Base.length(lib::Library) = length(lib.ingredients)

"""
    push!(lib::Library, ingredient; stock = nothing)

Adds the `ingredient` to `lib`, by its name, with the amount in `stock` (a mass, a volume,
a count, or `nothing` when not known), replacing an ingredient of the same name.
"""
function Base.push!(lib::Library, i::AbstractIngredient; stock = nothing)
    lib.ingredients[i.name] = i
    lib.stock[i.name] = _stock_amount(stock)
    return lib
end

_stock_amount(::Nothing) = nothing
_stock_amount(x::Unitful.Mass) = uconvert(u"kg", float(x))
_stock_amount(x::Unitful.Volume) = uconvert(u"L", float(x))
_stock_amount(x::Real) = float(x)
_stock_amount(x) = throw(ArgumentError("a stock is a mass, a volume or a count, not $x"))

"""
    stock(lib::Library, name)
    stock!(lib::Library, name, amount)

The amount of the ingredient `name` in stock (`nothing` when not known), and setting it.
"""
stock(lib::Library, name::AbstractString) = (lib[name]; lib.stock[name])
stock!(lib::Library, name::AbstractString, amount) = (lib[name]; lib.stock[name] = _stock_amount(amount); lib)

"""
    lookup(lib::Library, text)

The names of the ingredients of `lib` containing `text`, ignoring case.
"""
lookup(lib::Library, text::AbstractString) =
    [n for n in keys(lib) if occursin(lowercase(text), lowercase(n))]

# the stock in a BeerJSON inventory
_inventory(::Nothing) = nothing
_inventory(x::Union{BJ.FermentableInventoryType, BJ.HopInventoryType}) = _q(x.amount)
_inventory(x::BJ.CultureInventoryType) =
    something(_q(x.dry), _q(x.liquid), _q(x.slant), _q(x.culture), Some(nothing))

function _load!(lib, records, make)
    for x in something(records, [])
        i = try
            make(x)
        catch e
            e isa ArgumentError || rethrow()
            @warn "$(repr(x.name)) is left out of the library: $(e.msg)"
            continue
        end
        push!(lib, i; stock = _inventory(x.inventory))
    end
    return lib
end

"""
    merge!(lib::Library, doc::BeerJSONParser)
    merge!(lib::Library, other::Library)

Adds to `lib` the fermentables, hop varieties and cultures of a BeerJSON document, with
their inventory, or the ingredients of another library, replacing those of the same name.
Cultures without attenuation are taken with 75%, with a warning.
"""
function Base.merge!(lib::Library, doc::BJ.BeerJSONParser)
    c = doc.beerjson
    _load!(lib, c.fermentables, Fermentable)
    _load!(lib, c.hop_varieties, Hop)
    _load!(lib, c.cultures, x -> begin
        x.attenuation_range === nothing &&
            @warn "the culture $(repr(x.name)) has no attenuation: taken with 75%"
        Culture(x; attenuation = 75u"percent")
    end)
    return lib
end
function Base.merge!(lib::Library, other::Library)
    merge!(lib.ingredients, other.ingredients)
    merge!(lib.stock, other.stock)
    return lib
end

"""
    requirements(res::BrewResult, q::Quiver)

What the brew `res` of `q` uses of each ingredient, by name: the amounts of the lots taken
by their arrows (what is left on the shelf is not used), as masses or counts.
"""
function requirements(res::BrewResult, q::Quiver)
    used = Dict{String, Any}()
    for n in res.order
        _issource(q, n) || continue
        for s in solids(q[n].initial)
            s isa Portion || continue
            left = sum((x.amount for x in solids(leftover(res, n))
                        if x isa Portion && x.ingredient == s.ingredient); init = 0 * s.amount)
            amount = s.amount - left
            iszero(amount) && continue
            name = s.ingredient.name
            used[name] = haskey(used, name) ? used[name] + amount : amount
        end
    end
    return used
end

_comparable(a, b) = (a isa Number && b isa Number && !(a isa Unitful.Quantity) && !(b isa Unitful.Quantity)) ||
                    (a isa Unitful.Quantity && b isa Unitful.Quantity && dimension(a) == dimension(b))

"""
    shortages(lib::Library, res::BrewResult, q::Quiver)

The ingredients that the brew `res` of `q` needs (see [`requirements`](@ref)) beyond the
stock of `lib`, as a vector of NamedTuples `(name, needed, available)`: those not in the
library or without a known stock (`available = nothing`), and those with less in stock.
Amounts that cannot be compared (a count of yeast packs and a volume in stock) are not
reported.
"""
function shortages(lib::Library, res::BrewResult, q::Quiver)
    out = @NamedTuple{name::String, needed::Any, available::Any}[]
    for (name, needed) in sort!(collect(requirements(res, q)); by = first)
        available = haskey(lib, name) ? lib.stock[name] : nothing
        if available === nothing
            push!(out, (; name, needed, available))
        elseif _comparable(needed, available) && needed > available
            push!(out, (; name, needed, available))
        end
    end
    return out
end

"""
    consume!(lib::Library, res::BrewResult, q::Quiver)

Takes from the stock of `lib` what the brew `res` of `q` uses (see
[`requirements`](@ref)), down to zero, with a warning for what was short. The ingredients
not in the library, or without a known or comparable stock, are left as they are.
"""
function consume!(lib::Library, res::BrewResult, q::Quiver)
    for (name, needed) in requirements(res, q)
        haskey(lib, name) || continue
        available = lib.stock[name]
        (available === nothing || !_comparable(needed, available)) && continue
        needed > available && @warn "using $needed of $(repr(name)), with $available in stock"
        lib.stock[name] = max(zero(available), available - _stock_amount(needed))
    end
    return lib
end

# Writing the library: the catalogue records of BeerJSON, with their inventory
_bj_inventory(::Nothing) = nothing
_bj_inventory(x::KgQ) = BJ.MassType{_BJI, _BJT}(x)
_bj_inventory(x::LQ) = BJ.VolumeType{_BJI, _BJT}(x)

function _record(f::Fermentable, s)
    inv = s isa Union{KgQ, LQ} ? (amount = _bj_inventory(s),) : nothing
    return BJ.FermentableType{_BJI, _BJT}(name = f.name, type = _KINDS[f.kind],
        yield = (fine_grind = BJ.PercentType{_BJI, _BJT}(100f.yield * u"percent"),),
        color = BJ.ColorType{_BJI, _BJT}(f.color),
        moisture = BJ.PercentType{_BJI, _BJT}(100f.moisture * u"percent"), inventory = inv,
        di_ph = f.di_ph === nothing ? nothing : (unit = "pH", value = f.di_ph))
end
function _record(h::Hop, s)
    inv = s isa Union{KgQ, LQ} ? (amount = _bj_inventory(s),) : nothing
    return BJ.VarietyInformation{_BJI, _BJT}(name = h.name, form = get(_FORMS, h.form, "pellet"),
        alpha_acid = BJ.PercentType{_BJI, _BJT}(100h.alpha * u"percent"), inventory = inv)
end
function _record(c::Culture, s)
    a = BJ.PercentType{_BJI, _BJT}(100c.attenuation * u"percent")
    inv = s isa KgQ ? (dry = _bj_inventory(s),) : s isa LQ ? (liquid = _bj_inventory(s),) : nothing
    return BJ.CultureInformation{_BJI, _BJT}(name = c.name, type = string(c.kind),
        form = string(c.form), attenuation_range = (minimum = a, maximum = a), inventory = inv)
end

"""
    write_beerjson(path, lib::Library)

Writes the ingredients of `lib` to a BeerJSON document at `path`, as fermentables, hop
varieties and cultures, with their stock as inventory (counts of cultures are not written:
BeerJSON's inventory of cultures holds volumes and masses).
"""
function write_beerjson(path::AbstractString, lib::Library)
    records(T) = [_record(lib[n], lib.stock[n]) for n in keys(lib) if lib[n] isa T]
    content = Dict{Symbol, Any}(:version => 1.0)
    for (key, T) in ((:fermentables, Fermentable), (:hop_varieties, Hop), (:cultures, Culture))
        rs = records(T)
        isempty(rs) || (content[key] = rs)
    end
    BJ.writejson(path, BJ.BeerJSONParser{_BJI, _BJT}(beerjson = (; content...)))
    return path
end

function Base.show(io::IO, ::MIME"text/plain", lib::Library)
    print(io, "Library with ", length(lib), length(lib) == 1 ? " ingredient" : " ingredients")
    for n in keys(lib)
        s = lib.stock[n]
        print(io, "\n  ", lib[n], s === nothing ? "" : string(", in stock ",
              s isa Unitful.Quantity ? _amount(s) : string(isinteger(s) ? Int(s) : s, " ×")))
    end
end
