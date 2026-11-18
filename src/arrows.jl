# Arrows: the processes of the quiver, from the contents of a node to another.
#
# - a `Transfer` moves a uniform part of the contents (or the rest);
# - a `Drain` moves the liquid only, leaving behind the solids and what they retain;
# - a transformation (`MashRest`, `Boil`, `Chill`, `Ferment`, `Prime`, `Carbonate`) turns all the
#   contents of a node into the next state of the same vessel. A new transformation `T`
#   implements `transform(t::T, contents, models) -> (contents, released)`.

"""
    AbstractArrow

Supertype of the arrows of a [`Quiver`](@ref): [`Transfer`](@ref), [`Drain`](@ref) and the
transformations ([`AbstractTransformation`](@ref)).
"""
abstract type AbstractArrow end

"""
    AbstractTransformation <: AbstractArrow

Supertype of the arrows that turn all the contents of a node into the next state of the
same vessel: [`MashRest`](@ref), [`Boil`](@ref), [`Chill`](@ref), [`Ferment`](@ref),
[`Prime`](@ref), [`Carbonate`](@ref). A transformation must be the only arrow leaving its node. A new one
implements [`transform`](@ref).
"""
abstract type AbstractTransformation <: AbstractArrow end

"""
    transform(t::AbstractTransformation, contents::Contents, models) -> (contents, released)

The contents after the transformation `t`, and what it released from the quiver, as a
NamedTuple `(water, co2)` of masses (negative for what it took in).
"""
function transform end

_minutes(t) = uconvert(u"minute", float(t))

"""
    duration(arrow::AbstractArrow)

How long the `arrow` takes: the `duration` of a transfer or a drain, the `time` of a
transformation. A new arrow type with a duration implements this method; the default is
no time.
"""
duration(::AbstractArrow) = 0.0u"minute"
duration(t::AbstractTransformation) = hasfield(typeof(t), :time) ? _minutes(t.time) : 0.0u"minute"

const Released = @NamedTuple{water::KgQ, co2::KgQ}
_released(water, co2) = (water = uconvert(u"kg", water), co2 = uconvert(u"kg", co2))
released_nothing() = _released(0.0u"kg", 0.0u"kg")

"""
    Transfer(amount = nothing; remaining = nothing, at = nothing, duration = 0u"minute")

Moves a uniform part of the contents of a node: a volume (of the liquor), a mass, a fraction
(a percentage or a plain number from 0 to 1), or `nothing` for what is left by the other
arrows (shared equally among the transfers of the rest).

The ingredients moved arrive with the timing `remaining` or `at` (see [`Remaining`](@ref),
[`At`](@ref)), e.g. `Transfer(20u"g"; remaining = 10u"minute")` for a hop with 10 minutes
of boil left. The transfer takes the time `duration` (see [`schedule`](@ref)).
"""
struct Transfer <: AbstractArrow
    amount::Union{Nothing, Float64, LQ, KgQ}
    timing::Union{Nothing, AbstractTiming}
    duration::MinQ
end

_transfer_amount(::Nothing) = nothing
_transfer_amount(x::Real) = (0 ≤ x ≤ 1 ? float(x) :
                             throw(DomainError(x, "a fraction must be between 0 and 1")))
_transfer_amount(x::Unitful.DimensionlessQuantity) = _transfer_amount(float(uconvert(NoUnits, x)))
_transfer_amount(x::Unitful.Volume) = uconvert(u"L", float(x))
_transfer_amount(x::Unitful.Mass) = uconvert(u"kg", float(x))
_transfer_amount(x) = throw(ArgumentError("a transfer takes a volume, a mass, a fraction or " *
                                          "`nothing` (the rest), not $x"))

function Transfer(amount = nothing; remaining = nothing, at = nothing, duration = 0u"minute")
    remaining === nothing || at === nothing ||
        throw(ArgumentError("give either `remaining` or `at`, not both"))
    timing = remaining !== nothing ? Remaining(remaining) : at !== nothing ? At(at) : nothing
    return Transfer(_transfer_amount(amount), timing, _minutes(duration))
end

# the fraction of the contents `c` taken by the transfer
_fraction_of(::Nothing, c, eq) = nothing
_fraction_of(f::Float64, c, eq) = f
function _fraction_of(v::LQ, c, eq)
    total = volume(c; eq)
    return iszero(total) ? 0.0 : float(uconvert(NoUnits, v / total))
end
function _fraction_of(m::KgQ, c, eq)
    total = total_mass(c)
    return iszero(total) ? 0.0 : float(uconvert(NoUnits, m / total))
end

"""
    Drain(; absorption = 1.0u"L/kg", retain = 0u"L", duration = 0u"minute")

Moves the liquid of a node, leaving behind its solids, the liquid absorbed by the grain
(`absorption` per mass of grain, see [`grist`](@ref)) and the volume `retain` (dead space,
trub, yeast cake). It acts on what the transfers of amounts leave, before the transfers of
the rest; a node has at most one drain. Draining takes the time `duration` (see
[`schedule`](@ref)).
"""
struct Drain <: AbstractArrow
    absorption::typeof(1.0u"L/kg")
    retain::LQ
    duration::MinQ
end
Drain(; absorption = 1.0u"L/kg", retain = 0u"L", duration = 0u"minute") =
    Drain(uconvert(u"L/kg", float(absorption)), uconvert(u"L", float(retain)), _minutes(duration))

duration(a::Union{Transfer, Drain}) = a.duration

# split `c` into the liquid drained and what stays
function _drain(d::Drain, c::Contents, eq)
    v = volume(c; eq)
    kept = grist(c) * d.absorption + d.retain
    # (all of it retained, up to rounding errors: nothing is drained)
    kept > v && isapprox(kept, v; rtol = 1e-9) && (kept = v)
    kept ≤ v || throw(ArgumentError(
        "not enough liquid to drain: $(round(u"L", v; digits = 2)) available, " *
        "$(round(u"L", kept; digits = 2)) retained by the grain and the vessel"))
    f = iszero(v) ? 0.0 : 1 - float(uconvert(NoUnits, kept / v))
    return Contents(f * c.liquor), Contents((1 - f) * c.liquor, c.solids)
end

# Dissolution of fermentables: their moisture joins the water, the fraction `conversion`
# of their potential extract dissolves, with their color (lb × °L), and the rest is residue.
function _dissolve(p::Portion{Fermentable, KgQ}, conversion)
    f, m = p.ingredient, p.amount
    e = conversion * potential_extract(m, f.yield; moisture = f.moisture)
    w = m * f.moisture
    l = Liquor(; water = w, extract = e, color = ustrip(u"lb", m) * ustrip(u"°L", f.color))
    return l, Residue(m - w - e, grist(p))
end

# dissolve the solids for which `which(portion)` holds; returns the new contents
function _dissolve(c::Contents, conversion, which)
    l = c.liquor
    rest = AbstractSolid[]
    for s in c.solids
        if s isa Portion{Fermentable, KgQ} && which(s.ingredient)
            dl, r = _dissolve(s, conversion)
            l += dl
            push!(rest, r)
        else
            push!(rest, s)
        end
    end
    return Contents(l, rest)
end
_dissolve_soluble(c::Contents) = _dissolve(c, 1.0, soluble)

_temperature(t) = uconvert(u"°C", float(t))

"""
    MashRest(; temperature = 67u"°C", time = 60u"minute", conversion = 95u"percent")

A mash rest: the grain in the node gives the fraction `conversion` of its potential extract
(and its moisture and color) to the liquor, at `temperature`, leaving its [`Residue`](@ref),
the spent grain. Soluble fermentables dissolve completely.
"""
struct MashRest <: AbstractTransformation
    temperature::CQ
    time::MinQ
    conversion::Float64
end
MashRest(; temperature = 67u"°C", time = 60u"minute", conversion = 95u"percent") =
    MashRest(_temperature(temperature), _minutes(time), _fraction(conversion))

function transform(m::MashRest, c::Contents, models)
    c = _dissolve(_dissolve_soluble(c), m.conversion, f -> !soluble(f))
    return with_temperature(c, m.temperature), released_nothing()
end

"""
    Boil(; time = 60u"minute", evaporation = 4u"L/hr")

Boils the contents of a node for `time`, evaporating water at the rate `evaporation` (a
volume, or a fraction of the volume, per time) and driving off the CO₂. Soluble fermentables
dissolve; each hop isomerizes during its own time in the boil (see [`AbstractTiming`](@ref)),
with the utilization model `models.bitterness` at the mean of the gravities before and
after the boil and the factor [`HOP_FORM_FACTORS`](@ref) of its form, leaving its
[`HopMatter`](@ref).
"""
struct Boil <: AbstractTransformation
    time::MinQ
    evaporation::Union{typeof(1.0u"L/hr"), typeof(1.0u"hr^-1")}
end

_rate(r::Unitful.VolumeFlow) = uconvert(u"L/hr", float(r))
_rate(r::Unitful.Frequency) = uconvert(u"hr^-1", float(r))

Boil(; time = 60u"minute", evaporation = 4u"L/hr") = Boil(_minutes(time), _rate(evaporation))

function transform(b::Boil, c::Contents, models)
    eq = models.gravity
    c = _dissolve_soluble(c)
    before = c.liquor
    evaporated = _kg(evaporated_volume(volume(before; eq), b.evaporation, b.time))
    after = Liquor(before.water - evaporated, before.extract, before.alcohol, before.isoalpha,
                   before.color, 0.0u"g", 100.0u"°C")
    gavg = (gravity(before; eq) + gravity(after; eq)) / 2
    isoalpha = 0.0u"mg"
    rest = AbstractSolid[]
    for s in c.solids
        if s isa Portion{Hop, KgQ}
            h = s.ingredient
            iso = isomerized_alpha_acids(models.bitterness, s.amount, h.alpha, gavg,
                                         duration_in(s.timing, b.time);
                                         factor = hop_form_factor(h), eq)
            isoalpha += iso
            push!(rest, HopMatter(s.amount - uconvert(u"kg", iso)))
        else
            push!(rest, s)
        end
    end
    after += Liquor(; isoalpha, temperature = 100u"°C")
    return Contents(after, rest), _released(evaporated, before.co2)
end

"""
    Chill(; temperature = 20u"°C", time = 0u"minute")

Brings the contents of a node to `temperature`, e.g. the wort after the boil, before it is
transferred to the fermentor. Nothing else changes (the volumes of the quiver are at 20 °C).
"""
struct Chill <: AbstractTransformation
    temperature::CQ
    time::MinQ
end
Chill(; temperature = 20u"°C", time = 0u"minute") = Chill(_temperature(temperature), _minutes(time))

transform(k::Chill, c::Contents, models) = with_temperature(c, k.temperature), released_nothing()

"""
    Ferment(; temperature = 20u"°C", time = 14u"d", attenuation = nothing)

Ferments the contents of a node with the cultures in it, down to the apparent `attenuation`
of its original extract: by default, the largest attenuation of the cultures present.
Soluble fermentables dissolve first.

By Balling, each 2.0665 g of extract give 1 g of ethanol, 0.9565 g of CO₂ and 0.11 g of
yeast, which joins the [`YeastCake`](@ref). The CO₂ escapes except for the residual CO₂ at
`temperature` (see `residual_co2`).
"""
struct Ferment <: AbstractTransformation
    temperature::CQ
    time::typeof(1.0u"d")
    attenuation::Union{Nothing, Float64}
end
Ferment(; temperature = 20u"°C", time = 14u"d", attenuation = nothing) =
    Ferment(_temperature(temperature), uconvert(u"d", float(time)),
            attenuation === nothing ? nothing : _fraction(attenuation))

# References: J. De Clerck, A Textbook of Brewing, Chapman & Hall, 1958, after C. J. N.
# Balling; J. Šavel et al., "Interpolation formulas for Balling's alcohol factors", Kvasny
# prumysl 66 (2020) 239–244, doi:10.18832/kp2019.66.239.
function transform(f::Ferment, c::Contents, models)
    eq = models.gravity
    c = _dissolve_soluble(c)
    cultures = [s for s in c.solids if s isa Portion{Culture}]
    attenuation = if f.attenuation !== nothing
        f.attenuation
    elseif !isempty(cultures)
        maximum(s.ingredient.attenuation for s in cultures)
    else
        throw(ArgumentError("there is no culture to ferment; transfer one or give the " *
                            "`attenuation`"))
    end
    l = c.liquor
    oe, _, _ = _extracts(l)
    ae = (1 - attenuation) * oe
    r = (0.1808oe + 0.8192ae) / 100              # target real extract, as a mass fraction
    e, m = ustrip(u"kg", l.extract), ustrip(u"kg", mass(l))
    Δe = max(0.0, (e - r * m) / (1 - r * 1.0665 / 2.0665)) * u"kg"
    produced = uconvert(u"g", 0.9565 / 2.0665 * Δe)
    grown = 0.11 / 2.0665 * Δe
    fermented = Liquor(l.water, l.extract - Δe, l.alcohol + Δe / 2.0665, l.isoalpha, l.color,
                       0.0u"g", f.temperature)
    residual = uconvert(u"g", ustrip(u"vols", residual_co2(f.temperature)) * CO2_PER_VOLS *
                              volume(fermented; eq))
    co2 = min(residual, l.co2 + produced)
    fermented = Liquor(fermented.water, fermented.extract, fermented.alcohol, fermented.isoalpha,
                       fermented.color, co2, f.temperature)
    rest = AbstractSolid[s isa Portion{Culture} ? YeastCake(solid_mass(s)) : s for s in c.solids]
    push!(rest, YeastCake(grown))
    return Contents(fermented, rest), _released(0.0u"kg", l.co2 + produced - co2)
end

"""
    Prime(; sugar = CornSugar(), time = 14u"d")

Bottle or keg conditioning: the soluble fermentables in the node (the priming sugar) are
fully fermented, and their CO₂ stays dissolved. The CO₂ yield is that of `sugar`, an
`AbstractPrimingSugar` of BrewingFormulas; equal numbers of moles of ethanol and CO₂ are
produced, and the water balances the masses (the water of a monohydrate is released, the
water of the hydrolysis of sucrose is taken). See [`priming_mass`](@ref) for the mass of
sugar giving a carbonation level. The conditioning takes the given `time`.
"""
struct Prime{S <: AbstractPrimingSugar} <: AbstractTransformation
    sugar::S
    time::typeof(1.0u"d")
end
Prime(; sugar::AbstractPrimingSugar = CornSugar(), time = 14u"d") =
    Prime(sugar, uconvert(u"d", float(time)))

function _prime(l::Liquor, s::KgQ, sugar)
    co2 = uconvert(u"g", co2_yield(sugar) * s)
    alcohol = uconvert(u"kg", ETHANOL_PER_CO2 * co2)
    water = s - alcohol - uconvert(u"kg", co2)
    return Liquor(l.water + water, l.extract, l.alcohol + alcohol, l.isoalpha, l.color,
                  l.co2 + co2, l.temperature)
end

function transform(p::Prime, c::Contents, models)
    sugars = [s for s in c.solids if s isa Portion{Fermentable, KgQ} && soluble(s.ingredient)]
    s = sum(solid_mass, sugars; init = 0.0u"kg")
    rest = AbstractSolid[x for x in c.solids if !any(y -> y === x, sugars)]
    return Contents(_prime(c.liquor, s, p.sugar), rest), released_nothing()
end

"""
    priming_mass(contents, carbonation; sugar = CornSugar(), eq = SugarGravityQuad())

The mass of priming `sugar` that [`Prime`](@ref) needs to bring `contents` to the
`carbonation` level, accounting for the CO₂ already dissolved and for the change of volume
due to the ethanol and water produced.
"""
function priming_mass(c::Contents, carbonation; sugar::AbstractPrimingSugar = CornSugar(),
                      eq = DEFAULT_MODELS.gravity)
    target = ustrip(u"vols", carbonation) * CO2_PER_VOLS
    l, s = c.liquor, 0.0u"kg"
    for _ in 1:50
        needed = uconvert(u"g", target * volume(_prime(l, s, sugar); eq)) - l.co2
        new = max(0.0u"kg", uconvert(u"kg", needed / co2_yield(sugar)))
        converged = abs(new - s) ≤ 1e-12u"kg"
        s = new
        converged && break
    end
    return uconvert(u"g", s)
end

"""
    Carbonate(carbonation; time = 2u"d")

Forced carbonation of the contents of a node to the `carbonation` level, with CO₂ from
outside the quiver (released as a negative mass), taking the given `time`.
"""
struct Carbonate <: AbstractTransformation
    carbonation::typeof(1.0u"vols")
    time::typeof(1.0u"d")
end
Carbonate(level::Unitful.Quantity; time = 2u"d") =
    Carbonate(uconvert(u"vols", float(level)), uconvert(u"d", float(time)))

function transform(k::Carbonate, c::Contents, models)
    l = c.liquor
    target = uconvert(u"g", ustrip(u"vols", k.carbonation) * CO2_PER_VOLS *
                            volume(l; eq = models.gravity))
    added = max(0.0u"g", target - l.co2)
    l = Liquor(l.water, l.extract, l.alcohol, l.isoalpha, l.color, l.co2 + added, l.temperature)
    return Contents(l, c.solids), _released(0.0u"kg", -added)
end
