# Contents: what is in a vessel at a stage of the brewing, the nodes of the quiver.
#
# The contents are a liquor (the dissolved, conserved quantities) plus solids: ingredients
# as they were added (`Portion`), and what remains of them after a transformation (spent
# grain, hop matter, yeast). Like liquors, contents are mixed with `+` and split with `*`.

"""
    AbstractTiming

When an ingredient arrives in a node, relative to the transformation that follows it:
[`Remaining`](@ref) or [`At`](@ref). Without a timing, it is there from the start.
"""
abstract type AbstractTiming end

"""
    Remaining(time)

Arrival with `time` remaining in the next transformation, e.g. a hop added with 10 minutes
of boil left, or a dry hop with 3 days of fermentation left.
"""
struct Remaining <: AbstractTiming
    time::MinQ
end
Remaining(t::Unitful.Time) = Remaining(uconvert(u"minute", float(t)))

"""
    At(time)

Arrival `time` after the start of the next transformation.
"""
struct At <: AbstractTiming
    time::MinQ
end
At(t::Unitful.Time) = At(uconvert(u"minute", float(t)))

"""
    duration_in(timing, total)

How long an ingredient arriving with `timing` takes part in a transformation lasting `total`.
"""
duration_in(::Nothing, total) = total
duration_in(t::Remaining, total) = clamp(t.time, zero(total), total)
duration_in(t::At, total) = clamp(total - t.time, zero(total), total)

"""
    AbstractSolid

Supertype of the solids in [`Contents`](@ref): [`Portion`](@ref), [`Residue`](@ref),
[`HopMatter`](@ref), [`YeastCake`](@ref).
"""
abstract type AbstractSolid end

"""
    Portion(ingredient, amount; timing = nothing)

An `amount` of an `ingredient` as it was added: a mass, or a count (e.g. packs of yeast),
with its [`AbstractTiming`](@ref).
"""
struct Portion{I <: AbstractIngredient, A <: Union{KgQ, Float64}} <: AbstractSolid
    ingredient::I
    amount::A
    timing::Union{Nothing, AbstractTiming}
end
_portion_amount(x::Unitful.Mass) = uconvert(u"kg", float(x))
_portion_amount(x::Real) = (x ≥ 0 ? float(x) : throw(DomainError(x, "a count must be nonnegative")))
_portion_amount(x) = throw(ArgumentError("the amount of an ingredient is a mass or a count, not $x"))
Portion(i::AbstractIngredient, amount; timing = nothing) = Portion(i, _portion_amount(amount), timing)

"""
    Residue(mass, grist)

The insoluble residue of fermentables after their extract was dissolved: spent grain, with
the mass `grist` of the grain it came from, which sets the liquid it absorbs.
"""
struct Residue <: AbstractSolid
    mass::KgQ
    grist::KgQ
end

"""
    HopMatter(mass)

What remains of hops after a boil.
"""
struct HopMatter <: AbstractSolid
    mass::KgQ
end

"""
    YeastCake(mass)

The yeast after a fermentation: what was pitched (when given as a mass) and what grew.
"""
struct YeastCake <: AbstractSolid
    mass::KgQ
end

solid_mass(p::Portion{<:AbstractIngredient, KgQ}) = p.amount
solid_mass(::Portion) = 0.0u"kg"                         # counts
solid_mass(s::Union{Residue, HopMatter, YeastCake}) = s.mass

grist(::AbstractSolid) = 0.0u"kg"
grist(p::Portion{Fermentable, KgQ}) = soluble(p.ingredient) ? 0.0u"kg" : p.amount
grist(r::Residue) = r.grist

_scale(f, p::Portion) = Portion(p.ingredient, f * p.amount, p.timing)
_scale(f, r::Residue) = Residue(f * r.mass, f * r.grist)
_scale(f, s::S) where {S <: Union{HopMatter, YeastCake}} = S(f * s.mass)

_isnull(p::Portion) = iszero(p.amount)
_isnull(r::Residue) = iszero(r.mass) && iszero(r.grist)
_isnull(s::Union{HopMatter, YeastCake}) = iszero(s.mass)

# solids with the same key are merged
_key(p::Portion) = (typeof(p), p.ingredient, p.timing)
_key(s::AbstractSolid) = typeof(s)
_combine(a::Portion, b::Portion) = Portion(a.ingredient, a.amount + b.amount, a.timing)
_combine(a::Residue, b::Residue) = Residue(a.mass + b.mass, a.grist + b.grist)
_combine(a::S, b::S) where {S <: Union{HopMatter, YeastCake}} = S(a.mass + b.mass)
_amounts(p::Portion) = (ustrip(p.amount),)
_amounts(r::Residue) = (ustrip(u"kg", r.mass), ustrip(u"kg", r.grist))
_amounts(s::Union{HopMatter, YeastCake}) = (ustrip(u"kg", s.mass),)

function _merge(solids)
    out = AbstractSolid[]
    at = Dict{Any, Int}()
    for s in solids
        _isnull(s) && continue
        k = _key(s)
        if haskey(at, k)
            out[at[k]] = _combine(out[at[k]], s)
        else
            push!(out, s)
            at[k] = length(out)
        end
    end
    return out
end

"""
    Contents(liquor = zero(Liquor), solids = [])
    Contents(ingredient => amount)

What is in a vessel at a stage of the brewing: a [`Liquor`](@ref) and solids
([`AbstractSolid`](@ref)). Contents are the nodes of a [`Quiver`](@ref); they are mixed
with `+` and split with `*` by a fraction.

The derived quantities of the liquor (`volume`, `gravity`, `abv`, `ibu`, `srm`, ...) are
also available for the contents. See also [`total_mass`](@ref) and [`grist`](@ref).
"""
struct Contents
    liquor::Liquor
    solids::Vector{AbstractSolid}
    Contents(l::Liquor, solids) = new(l, _merge(solids))
end
Contents(l::Liquor = zero(Liquor)) = Contents(l, AbstractSolid[])
Contents(p::Pair{<:AbstractIngredient}) = Contents(zero(Liquor), AbstractSolid[Portion(p.first, p.second)])

# salts and acids are held dissolved: their ions, the alkalinity they add or take, and the
# mass of everything else (other species, water of crystallization, the acid)
function Contents(p::Pair{<:Salt, <:Unitful.Mass})
    m = uconvert(u"mg", float(p.second))
    i = ions(p.first.salt, m, 1u"L")
    c(x) = x * 1u"L"
    known = c(i.calcium) + c(i.magnesium) + c(i.sodium) + c(i.chloride) + c(i.sulfate)
    return Contents(Liquor(; minerals = Minerals(; calcium = c(i.calcium), magnesium = c(i.magnesium),
        sodium = c(i.sodium), chloride = c(i.chloride), sulfate = c(i.sulfate),
        alkalinity = c(i.alkalinity), other = m - known)))
end
function Contents(p::Pair{<:Acid, <:Union{Unitful.Mass, Unitful.Volume}})
    a = p.first.acid
    m = p.second isa Unitful.Mass ? uconvert(u"mg", float(p.second)) : uconvert(u"mg", float(p.second) * a.density)
    meq = acid_milliequivalents(a, m / a.density)
    return Contents(Liquor(; water = (1 - a.strength) * m,
        minerals = Minerals(; alkalinity = -meq * _EQ_CACO3 * u"mg", other = a.strength * m)))
end
Contents(c::Contents) = c

"""
    liquor(contents), solids(contents)

The liquor and the solids of `contents`.
"""
liquor(c::Contents) = c.liquor
solids(c::Contents) = c.solids

Base.zero(::Type{Contents}) = Contents()
Base.iszero(c::Contents) = iszero(c.liquor) && isempty(c.solids)
Base.:+(a::Contents, b::Contents) = Contents(a.liquor + b.liquor, vcat(a.solids, b.solids))
Base.:*(f::Real, c::Contents) = Contents(f * c.liquor, AbstractSolid[_scale(f, s) for s in c.solids])
Base.:*(c::Contents, f::Real) = f * c

"""
    total_mass(contents)

The mass of everything in `contents`: the liquor (with its iso-alpha acids and CO₂) and the
solids, except those given as counts. It is conserved by the quiver, up to what the
transformations release (evaporated water, CO₂).
"""
total_mass(l::Liquor) = mass(l) + uconvert(u"kg", l.isoalpha) + uconvert(u"kg", l.co2) +
                       uconvert(u"kg", mineral_mass(l.minerals))
total_mass(c::Contents) = total_mass(c.liquor) + sum(solid_mass, c.solids; init = 0.0u"kg")

"""
    grist(contents)

The mass of grain in `contents`, fresh or spent, which sets the liquid it absorbs.
"""
grist(c::Contents) = sum(grist, c.solids; init = 0.0u"kg")

# the same contents with the timing of their portions set
with_timing(c::Contents, ::Nothing) = c
with_timing(c::Contents, t::AbstractTiming) =
    Contents(c.liquor, AbstractSolid[s isa Portion ? Portion(s.ingredient, s.amount, t) : s
                                     for s in c.solids])

with_temperature(c::Contents, t::Unitful.Temperature) = Contents(with_temperature(c.liquor, t), c.solids)

function Base.isapprox(a::Contents, b::Contents; rtol = 1e-8, atol = 1e-10)
    isapprox(a.liquor, b.liquor; rtol, atol) || return false
    da = Dict(_key(s) => s for s in a.solids)
    db = Dict(_key(s) => s for s in b.solids)
    keys(da) == keys(db) || return false
    return all(all(isapprox.(_amounts(da[k]), _amounts(db[k]); rtol, atol)) for k in keys(da))
end

# the derived quantities of the liquor
for f in (:volume, :gravity, :original_gravity, :carbonation)
    @eval $f(c::Contents; kwargs...) = $f(c.liquor; kwargs...)
end
for f in (:abv, :abw, :ibu, :srm, :mcu, :real_extract, :apparent_attenuation)
    @eval BrewingFormulas.$f(c::Contents; kwargs...) = $f(c.liquor; kwargs...)
end
BrewingFormulas.abv(m::ABVModel, c::Contents; kwargs...) = abv(m, c.liquor; kwargs...)
BrewingFormulas.srm(m::ColorModel, c::Contents; kwargs...) = srm(m, c.liquor; kwargs...)
