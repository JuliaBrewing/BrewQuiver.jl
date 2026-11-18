# Liquor: the state of a liquid stream (water, wort, beer, ...) flowing through the quiver.
#
# A liquor stores *extensive* quantities only, which are conserved: mixing two liquors is
# adding them, and splitting a liquor is scaling it. The intensive quantities (volume,
# gravity, ABV, IBU, color, ...) are derived from them with BrewingFormulas.
#
# Masses are used instead of volumes, since masses are additive and volumes are not
# (dissolving extract or mixing alcohol changes the volume). The total volume, at 20 °C, is
# always available with `volume`, computed from the masses and the gravity.

const KgQ = typeof(1.0u"kg")
const GQ = typeof(1.0u"g")
const MgQ = typeof(1.0u"mg")
const LQ = typeof(1.0u"L")
const CQ = typeof(1.0u"°C")
const MinQ = typeof(1.0u"minute")

const ETHANOL_DENSITY_20C = 0.78924u"kg/L"   # CRC Handbook of Chemistry and Physics
const CO2_PER_VOLS = 1.977u"g/L"         # density of CO₂ at 0 °C and 1 atm (as in UnitfulBrewing)
const ETHANOL_PER_CO2 = 46.068 / 44.0095 # equimolar ethanol and CO₂ in alcoholic fermentation

"""
    Minerals(; calcium = 0u"mg", magnesium = 0u"mg", sodium = 0u"mg", chloride = 0u"mg",
               sulfate = 0u"mg", alkalinity = 0u"mg", other = 0u"mg")

The minerals dissolved in a liquor, as conserved quantities: the masses of calcium,
magnesium, sodium, chloride and sulfate, the alkalinity as a mass of CaCO₃ (the equivalents
of bicarbonate, carbonate and hydroxide, less those of the acids added; it can be negative),
and the mass of the other species dissolved (bicarbonate, carbonate, hydroxide, acids, water
of crystallization), so that the mass of the salts and acids added is conserved. They are
mixed with `+` and split with `*` by a fraction, with the liquor. See [`WaterProfile`](@ref).
"""
struct Minerals
    calcium::MgQ
    magnesium::MgQ
    sodium::MgQ
    chloride::MgQ
    sulfate::MgQ
    alkalinity::MgQ
    other::MgQ
end
_mg(x) = uconvert(u"mg", float(x))
Minerals(; calcium = 0u"mg", magnesium = 0u"mg", sodium = 0u"mg", chloride = 0u"mg",
         sulfate = 0u"mg", alkalinity = 0u"mg", other = 0u"mg") =
    Minerals(_mg(calcium), _mg(magnesium), _mg(sodium), _mg(chloride), _mg(sulfate),
             _mg(alkalinity), _mg(other))
Base.zero(::Type{Minerals}) = Minerals()
Base.iszero(m::Minerals) = all(iszero(getfield(m, f)) for f in fieldnames(Minerals))
Base.:+(a::Minerals, b::Minerals) = Minerals((getfield(a, f) + getfield(b, f) for f in fieldnames(Minerals))...)
Base.:*(x::Real, m::Minerals) = Minerals((x * getfield(m, f) for f in fieldnames(Minerals))...)
Base.isapprox(a::Minerals, b::Minerals; rtol = 1e-8, atol = 1e-10) =
    all(isapprox(ustrip(u"mg", getfield(a, f)), ustrip(u"mg", getfield(b, f)); rtol, atol)
        for f in fieldnames(Minerals))

# the mass of the dissolved species (the alkalinity is counted in `other`)
mineral_mass(m::Minerals) = m.calcium + m.magnesium + m.sodium + m.chloride + m.sulfate + m.other

"""
    Liquor(; water = 0u"kg", extract = 0u"kg", alcohol = 0u"kg", isoalpha = 0u"mg",
             color = 0.0, co2 = 0u"g", temperature = 20u"°C", minerals = Minerals())

The state of a liquid (water, wort, beer, ...), given by its conserved quantities:

- `water`: mass of water (a volume is taken at 20 °C);
- `extract`: mass of dissolved (real) extract;
- `alcohol`: mass of ethanol;
- `isoalpha`: mass of iso-alpha acids;
- `color`: color units, as `lb × °L` (malt color units times volume in gal);
- `co2`: mass of dissolved CO₂;
- `temperature`;
- `minerals`: the [`Minerals`](@ref) dissolved.

Liquors are mixed with `+` and split with `*` by a fraction. Derived quantities:
[`volume`](@ref), [`gravity`](@ref), [`original_gravity`](@ref), `real_extract`,
`abw`, `abv`, `ibu`, `srm`, [`carbonation`](@ref). See also [`water`](@ref) and
[`wort`](@ref).
"""
struct Liquor
    water::KgQ
    extract::KgQ
    alcohol::KgQ
    isoalpha::MgQ
    color::Float64
    co2::GQ
    temperature::CQ
    minerals::Minerals
end

_kg(x::Unitful.Mass) = uconvert(u"kg", float(x))
_kg(x::Unitful.Volume) = uconvert(u"kg", float(x) * BrewingFormulas.WATER_DENSITY_20C)

function Liquor(; water = 0u"kg", extract = 0u"kg", alcohol = 0u"kg", isoalpha = 0u"mg",
                color::Real = 0.0, co2 = 0u"g", temperature = 20u"°C",
                minerals::Minerals = Minerals())
    return Liquor(_kg(water), _kg(extract), _kg(alcohol), uconvert(u"mg", float(isoalpha)),
                  float(color), uconvert(u"g", float(co2)), uconvert(u"°C", float(temperature)),
                  minerals)
end

"""
    WaterProfile(; calcium = 0u"mg/L", magnesium = 0u"mg/L", sodium = 0u"mg/L",
                   chloride = 0u"mg/L", sulfate = 0u"mg/L", bicarbonate = 0u"mg/L")

The concentrations of the main ions of a water (in mg/L or ppm), e.g. a water report or a
classic brewing water. See [`water`](@ref) and [`profile`](@ref).
"""
struct WaterProfile
    calcium::typeof(1.0u"mg/L")
    magnesium::typeof(1.0u"mg/L")
    sodium::typeof(1.0u"mg/L")
    chloride::typeof(1.0u"mg/L")
    sulfate::typeof(1.0u"mg/L")
    bicarbonate::typeof(1.0u"mg/L")
end
_mgL(x::Unitful.Quantity) = dimension(x) == dimension(u"mg/L") ? uconvert(u"mg/L", float(x)) :
                            uconvert(u"mg/L", float(x), DensityConcentration())
_mgL(x::Real) = iszero(x) ? 0.0u"mg/L" :
    throw(ArgumentError("give the concentration $x with its unit, e.g. mg/L or ppm"))
WaterProfile(; calcium = 0u"mg/L", magnesium = 0u"mg/L", sodium = 0u"mg/L", chloride = 0u"mg/L",
             sulfate = 0u"mg/L", bicarbonate = 0u"mg/L") =
    WaterProfile(_mgL(calcium), _mgL(magnesium), _mgL(sodium), _mgL(chloride), _mgL(sulfate),
                 _mgL(bicarbonate))

# the mg of CaCO₃ per mEq, and the bicarbonate per alkalinity as CaCO₃ (both from
# BrewingFormulas, so that the conversions are exact inverses)
const _EQ_CACO3 = 1 / milliequivalents(1.0u"mg/L")
const _HCO3_PER_ALK = 1 / ustrip(u"mg/L", alkalinity(1.0u"mg/L"))

# the minerals of a `volume` of water of the profile `p`
function Minerals(p::WaterProfile, volume::Unitful.Volume)
    v = uconvert(u"L", float(volume))
    return Minerals(; calcium = p.calcium * v, magnesium = p.magnesium * v, sodium = p.sodium * v,
                    chloride = p.chloride * v, sulfate = p.sulfate * v,
                    alkalinity = alkalinity(p.bicarbonate) * v, other = p.bicarbonate * v)
end

"""
    water(volume; temperature = 20u"°C", profile = nothing)

A liquor of water with the given `volume` at 20 °C, pure or with the ions of a
[`WaterProfile`](@ref).
"""
water(volume::Unitful.Volume; temperature = 20u"°C", profile::Union{Nothing, WaterProfile} = nothing) =
    Liquor(; water = volume, temperature,
           minerals = profile === nothing ? Minerals() : Minerals(profile, volume))

"""
    wort(volume, gravity; temperature = 20u"°C", eq = SugarGravityQuad())

A liquor of unfermented wort with the given `volume`, at 20 °C, and `gravity`.
"""
function wort(volume::Unitful.Volume, gravity; temperature = 20u"°C",
              eq = DEFAULT_MODELS.gravity)
    e = extract_mass(volume, gravity; eq)
    total = volume * specific_gravity(gravity; eq) * BrewingFormulas.WATER_DENSITY_20C
    return Liquor(; water = uconvert(u"kg", total) - e, extract = e, temperature)
end

Base.zero(::Type{Liquor}) = Liquor()
Base.iszero(l::Liquor) = iszero(mass(l)) && iszero(l.isoalpha) && iszero(l.co2) && iszero(l.color) &&
                        iszero(l.minerals)

"""
    mass(liquor)

The total mass of the `liquor`: water, extract and alcohol.
"""
mass(l::Liquor) = l.water + l.extract + l.alcohol

function Base.:+(a::Liquor, b::Liquor)
    ma, mb = mass(a), mass(b)
    t = if iszero(ma + mb)
        iszero(ma) ? b.temperature : a.temperature
    else
        # mass-weighted temperature, as if all had the heat capacity of water
        (ustrip(u"°C", a.temperature) * ma + ustrip(u"°C", b.temperature) * mb) / (ma + mb) * u"°C"
    end
    return Liquor(a.water + b.water, a.extract + b.extract, a.alcohol + b.alcohol,
                  a.isoalpha + b.isoalpha, a.color + b.color, a.co2 + b.co2, t,
                  a.minerals + b.minerals)
end

function Base.:*(f::Real, l::Liquor)
    f ≥ 0 || throw(DomainError(f, "a liquor can only be scaled by a nonnegative fraction"))
    return Liquor(f * l.water, f * l.extract, f * l.alcohol, f * l.isoalpha, f * l.color,
                  f * l.co2, l.temperature, f * l.minerals)
end
Base.:*(l::Liquor, f::Real) = f * l

"""
    with_temperature(liquor, temperature)

The `liquor` at another `temperature`.
"""
with_temperature(l::Liquor, t::Unitful.Temperature) =
    Liquor(l.water, l.extract, l.alcohol, l.isoalpha, l.color, l.co2, uconvert(u"°C", float(t)),
           l.minerals)

function Base.isapprox(a::Liquor, b::Liquor; rtol = 1e-8, atol = 1e-10)
    m(x, y, u) = isapprox(ustrip(u, x), ustrip(u, y); rtol, atol)
    return m(a.water, b.water, u"kg") && m(a.extract, b.extract, u"kg") &&
           m(a.alcohol, b.alcohol, u"kg") && m(a.isoalpha, b.isoalpha, u"mg") &&
           isapprox(a.color, b.color; rtol, atol) && m(a.co2, b.co2, u"g") &&
           m(a.temperature, b.temperature, u"°C") &&
           isapprox(a.minerals, b.minerals; rtol, atol)
end

# Balling: original, real and apparent extracts in °P, as plain numbers.
# With E and A the mass percentages of extract and alcohol,
# OE = 100 (E + 2.0665 A) / (100 + 1.0665 A), which in masses reads as below; it is
# equivalent to `abw` in BrewingFormulas, ABW = (OE - RE) / (2.0665 - 0.010665 OE), and the
# apparent extract follows from RE = 0.1808 OE + 0.8192 AE.
# References: J. De Clerck, A Textbook of Brewing, Chapman & Hall, 1958, after C. J. N.
# Balling; M. L. Hall, "Brew By the Numbers", Zymurgy, Summer 1995, pp. 54–61 (Eqs. 11, 16).
function _extracts(l::Liquor)
    m = ustrip(u"kg", mass(l))
    m == 0 && return (0.0, 0.0, 0.0)
    e, a = ustrip(u"kg", l.extract), ustrip(u"kg", l.alcohol)
    oe = 100 * (e + 2.0665a) / (m + 1.0665a)
    re = 100 * e / m
    ae = (re - 0.1808oe) / 0.8192
    return (oe, re, ae)
end

"""
    gravity(liquor; eq = SugarGravityQuad())

The (apparent) specific gravity of the `liquor`, in `sg`.
"""
gravity(l::Liquor; eq = DEFAULT_MODELS.gravity) = specific_gravity(_extracts(l)[3] * u"°P"; eq)

"""
    original_gravity(liquor; eq = SugarGravityQuad())

The original gravity of the `liquor`, in `sg`: the gravity it had before any fermentation,
by Balling's relations. For a blend, the original gravity of the blend.
"""
original_gravity(l::Liquor; eq = DEFAULT_MODELS.gravity) =
    specific_gravity(_extracts(l)[1] * u"°P"; eq)

BrewingFormulas.real_extract(l::Liquor) = _extracts(l)[2] * u"°P"

BrewingFormulas.apparent_attenuation(l::Liquor) =
    apparent_attenuation(_extracts(l)[1] * u"°P", _extracts(l)[3] * u"°P")

"""
    volume(liquor; eq = SugarGravityQuad())

The total volume of the `liquor` at 20 °C: its mass divided by its density.
"""
function volume(l::Liquor; eq = DEFAULT_MODELS.gravity)
    m = mass(l)
    iszero(m) && return 0.0u"L"
    s = ustrip(u"sg", gravity(l; eq))
    return uconvert(u"L", m / (s * BrewingFormulas.WATER_DENSITY_20C))
end

BrewingFormulas.abw(l::Liquor) =
    iszero(mass(l)) ? 0.0u"percent" : uconvert(u"percent", l.alcohol / mass(l))

BrewingFormulas.abv(l::Liquor; eq = DEFAULT_MODELS.gravity) = abv(DEFAULT_MODELS.abv, l; eq)
function BrewingFormulas.abv(::Balling, l::Liquor; eq = DEFAULT_MODELS.gravity)
    v = volume(l; eq)
    iszero(v) && return 0.0u"percent"
    return uconvert(u"percent", l.alcohol / ETHANOL_DENSITY_20C / v)
end
BrewingFormulas.abv(m::ABVModel, l::Liquor; eq = DEFAULT_MODELS.gravity) =
    abv(m, original_gravity(l; eq), gravity(l; eq); eq)

function BrewingFormulas.ibu(l::Liquor; eq = DEFAULT_MODELS.gravity)
    v = volume(l; eq)
    return iszero(v) ? 0.0u"IBU" : ibu(l.isoalpha, v)
end

BrewingFormulas.mcu(l::Liquor; eq = DEFAULT_MODELS.gravity) =
    (v = ustrip(u"gal", volume(l; eq)); v == 0 ? 0.0 : l.color / v)

BrewingFormulas.srm(l::Liquor; eq = DEFAULT_MODELS.gravity) = srm(DEFAULT_MODELS.color, l; eq)
BrewingFormulas.srm(m::ColorModel, l::Liquor; eq = DEFAULT_MODELS.gravity) = srm(m, mcu(l; eq))

"""
    carbonation(liquor; eq = SugarGravityQuad())

The dissolved CO₂ of the `liquor`, in `vols`.
"""
function carbonation(l::Liquor; eq = DEFAULT_MODELS.gravity)
    v = volume(l; eq)
    return iszero(v) ? 0.0u"vols" : ustrip(u"g/L", l.co2 / v) / ustrip(u"g/L", CO2_PER_VOLS) * u"vols"
end
