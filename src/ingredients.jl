# Ingredients, as working types with Unitful quantities.

"""
    AbstractIngredient

Supertype of the ingredients: [`Fermentable`](@ref), [`Hop`](@ref), [`Culture`](@ref).
"""
abstract type AbstractIngredient end

_fraction(x::Real) = float(x)
_fraction(x::Unitful.DimensionlessQuantity) = float(uconvert(NoUnits, x))

"""
    Fermentable(name; kind = :grain, yield = 80u"percent", color = 2u"SRM", moisture = 4u"percent")
    Fermentable(name; potential = 1.037u"sg", ...)

A fermentable ingredient. `kind` is one of the BeerJSON types (`:grain`, `:extract`,
`:dry_extract`, `:sugar`, `:fruit`, `:juice`, `:honey`, `:other`); `yield` is the extract
yield relative to sucrose, on dry basis, or it is given by the `potential` (the specific
gravity of 1 lb in 1 US gallon); `color` is in any color unit.
"""
struct Fermentable <: AbstractIngredient
    name::String
    kind::Symbol
    yield::Float64
    color::typeof(1.0u"SRM")
    moisture::Float64
end

function Fermentable(name::AbstractString; kind::Symbol = :grain, yield = nothing,
                     potential = nothing, color = 2u"SRM", moisture = 4u"percent")
    y = if potential !== nothing
        yield === nothing || throw(ArgumentError("give either yield or potential, not both"))
        _fraction(yield_from_potential(potential))
    else
        _fraction(something(yield, 0.8))
    end
    return Fermentable(name, kind, y, uconvert(u"SRM", float(color)), _fraction(moisture))
end

# grains need a mash to give their extract; the other fermentables dissolve
soluble(f::Fermentable) = f.kind !== :grain

"""
    Hop(name; alpha, form = :pellet)

A hop with alpha acid content `alpha` (a percentage or fraction) and `form` (`:pellet`,
`:leaf`, `:wet_leaf`, `:plug`, `:powder`, `:extract`).
"""
struct Hop <: AbstractIngredient
    name::String
    alpha::Float64
    form::Symbol
end
Hop(name::AbstractString; alpha, form::Symbol = :pellet) = Hop(name, _fraction(alpha), form)

"""
    HOP_FORM_FACTORS

Utilization factors of the hop forms, relative to leaf hops: pellets and powders are taken
to give 10% more bitterness. It can be modified to change the defaults.

The 10% for pellets is a homebrewing convention, not part of Tinseth's or Rager's models.
The Python BrewQuiver divided Tinseth's utilization by 0.9 and used the factors 1 for
pellets and 0.9 for leaf hops, i.e. pellets about 11% above leaf hops.
"""
const HOP_FORM_FACTORS = Dict{Symbol, Float64}(
    :leaf => 1.0, :wet_leaf => 1.0, :plug => 1.0, :pellet => 1.1, :powder => 1.1,
    :extract => 1.1)

hop_form_factor(h::Hop) = get(HOP_FORM_FACTORS, h.form, 1.0)

"""
    Culture(name; attenuation = 75u"percent", kind = :ale, form = :liquid)

A yeast or other culture with the given apparent `attenuation` (a percentage or fraction),
of the `kind` and `form` of BeerJSON (`kind` one of `:ale`, `:lager`, `:brett`, `:lacto`,
`:kveik`, ...; `form` one of `:liquid`, `:dry`, `:slant`, `:culture`, `:dregs`).
"""
struct Culture <: AbstractIngredient
    name::String
    attenuation::Float64
    kind::Symbol
    form::Symbol
end
Culture(name::AbstractString; attenuation = 75u"percent", kind::Symbol = :ale,
        form::Symbol = :liquid) = Culture(name, _fraction(attenuation), kind, form)
