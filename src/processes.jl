# Processes: the nodes of the quiver.
#
# A process is a subtype of `AbstractProcess` implementing
#
#     inports(p)  -> tuple of the names of its input ports    (default `(:in,)`)
#     outports(p) -> tuple of the names of its output ports   (default `(:out,)`)
#     process(p, inputs::Dict{Symbol, Liquor}, models) -> Dict{Symbol, Liquor}
#
# where `inputs` has the liquor delivered to each input port (all the transfers arriving at
# a port are mixed) and `models` is a NamedTuple with the models of BrewingFormulas, as in
# `DEFAULT_MODELS`. Whatever is not transferred from an output port is reported as left over.

"""
    AbstractProcess

Supertype of the processes, the nodes of a [`Quiver`](@ref). A new process `P` implements
[`process`](@ref)`(p::P, inputs, models)` and, if needed, [`inports`](@ref) and
[`outports`](@ref).
"""
abstract type AbstractProcess end

"""
    inports(p::AbstractProcess)

The names of the input ports of the process `p`; `(:in,)` by default.
"""
inports(::AbstractProcess) = (:in,)

"""
    outports(p::AbstractProcess)

The names of the output ports of the process `p`; `(:out,)` by default.
"""
outports(::AbstractProcess) = (:out,)

"""
    process(p::AbstractProcess, inputs::Dict{Symbol, Liquor}, models) -> Dict{Symbol, Liquor}

The liquors at the output ports of the process `p`, given the liquors at its input ports.
"""
function process end

_input(inputs, port = :in) = get(inputs, port, zero(Liquor))

# split a liquor so that the volume `v` stays behind: returns (out, retained)
function _retain(l::Liquor, v::Unitful.Volume, eq; what = "liquid")
    total = volume(l; eq)
    iszero(v) && return (l, zero(Liquor))
    v ≤ total || throw(ArgumentError(
        "not enough $what: $(round(u"L", total; digits = 2)) available, " *
        "$(round(u"L", v; digits = 2)) retained"))
    f = float(uconvert(NoUnits, v / total))
    return ((1 - f) * l, f * l)
end

"""
    Source(liquor)

A source of the given `liquor`, e.g. `Source(water(40u"L"))`, with no inputs and the output
port `:out`.
"""
struct Source <: AbstractProcess
    liquor::Liquor
end
inports(::Source) = ()
process(s::Source, inputs, models) = Dict(:out => s.liquor)

"""
    Mix()

Mixes everything arriving at its input port `:in` into its output port `:out`, e.g. to
blend beers.
"""
struct Mix <: AbstractProcess end
process(::Mix, inputs, models) = Dict(:out => _input(inputs))

"""
    MashTun(; grains, temperature = 67u"°C", time = 60u"minute", sparge = [],
              sparge_temperature = 76u"°C", conversion = 95u"percent",
              absorption = 1.0u"L/kg", dead_space = 0u"L")

A single infusion mash followed by batch sparges, in the same vessel.

The `grains` (a vector of `fermentable => mass`) are mashed with whatever arrives at the
input port `:in` (the strike water, or a wort for a double mash), dissolving the fraction
`conversion` of their potential extract, and their moisture. The mash is drained into the
output port `:running1`; then, for each volume in `sparge`, that volume of water is added
and drained into `:running2`, `:running3`, ... Each time, the grain retains `absorption`
per mass of grain, plus the `dead_space` of the vessel, which is left in the port
`:spent_grain`. The lauter efficiency is thus a result, not a parameter.
"""
struct MashTun <: AbstractProcess
    grains::Vector{Addition{Fermentable}}
    temperature::CQ
    time::MinQ
    sparge::Vector{LQ}
    sparge_temperature::CQ
    conversion::Float64
    absorption::typeof(1.0u"L/kg")
    dead_space::LQ
end

function MashTun(; grains, temperature = 67u"°C", time = 60u"minute", sparge = LQ[],
                 sparge_temperature = 76u"°C", conversion = 95u"percent",
                 absorption = 1.0u"L/kg", dead_space = 0u"L")
    return MashTun(_additions(Fermentable, grains), uconvert(u"°C", float(temperature)),
                   uconvert(u"minute", float(time)), LQ[uconvert(u"L", float(v)) for v in sparge],
                   uconvert(u"°C", float(sparge_temperature)), _fraction(conversion),
                   uconvert(u"L/kg", float(absorption)), uconvert(u"L", float(dead_space)))
end

runnings(m::MashTun) = ntuple(i -> Symbol(:running, i), length(m.sparge) + 1)
outports(m::MashTun) = (runnings(m)..., :spent_grain)

grain_mass(m::MashTun) = sum((a.amount for a in m.grains); init = 0.0u"kg")

# extract, water and color brought by the additions of fermentables
function _dissolve(additions, conversion)
    l = zero(Liquor)
    for a in additions
        f = a.ingredient
        l += Liquor(; water = a.amount * f.moisture,
                    extract = conversion * potential_extract(a.amount, f.yield; moisture = f.moisture),
                    color = ustrip(u"lb", a.amount) * ustrip(u"°L", f.color))
    end
    return l
end

function process(m::MashTun, inputs, models)
    eq = models.gravity
    mash = with_temperature(_input(inputs) + _dissolve(m.grains, m.conversion), m.temperature)
    retained = grain_mass(m) * m.absorption + m.dead_space
    out = Dict{Symbol, Liquor}()
    ports = runnings(m)
    running, left = _retain(mash, retained, eq; what = "strike water to wet the grain")
    out[ports[1]] = running
    for (i, v) in enumerate(m.sparge)
        mixed = left + water(v; temperature = m.sparge_temperature)
        running, left = _retain(mixed, retained, eq)
        out[ports[i + 1]] = running
    end
    out[:spent_grain] = left
    return out
end

"""
    Boil(; time = 60u"minute", hops = [], fermentables = [], evaporation = 4u"L/hr", loss = 0u"L")

Boils whatever arrives at `:in` for `time`, evaporating at the rate `evaporation` (a volume
or a fraction of the volume per time), with additions of `hops` (a vector of
`hop => mass => boil time`) and `fermentables` (sugars, extracts, ...: a vector of
`fermentable => mass`). The volume `loss` (trub, kettle dead space) goes to the port
`:loss`, the rest to `:out`.

The utilization of the hops is computed with `models.bitterness`, with the average of the
gravities before and after the boil, and the factor [`HOP_FORM_FACTORS`](@ref) of their form.
"""
struct Boil <: AbstractProcess
    time::MinQ
    hops::Vector{Addition{Hop}}
    fermentables::Vector{Addition{Fermentable}}
    evaporation::Union{typeof(1.0u"L/hr"), typeof(1.0u"hr^-1")}
    loss::LQ
end

_rate(r::Unitful.VolumeFlow) = uconvert(u"L/hr", float(r))
_rate(r::Unitful.Frequency) = uconvert(u"hr^-1", float(r))

function Boil(; time = 60u"minute", hops = [], fermentables = [], evaporation = 4u"L/hr",
              loss = 0u"L")
    hs = _additions(Hop, hops)
    for h in hs
        h.time === nothing && throw(ArgumentError("give the boil time of $(h.ingredient.name), " *
                                                  "as `hop => mass => time`"))
    end
    return Boil(uconvert(u"minute", float(time)), hs, _additions(Fermentable, fermentables),
                _rate(evaporation), uconvert(u"L", float(loss)))
end

outports(::Boil) = (:out, :loss)

function process(b::Boil, inputs, models)
    eq = models.gravity
    before = _input(inputs) + _dissolve(b.fermentables, 1.0)
    evaporated = evaporated_volume(volume(before; eq), b.evaporation, b.time)
    after = Liquor(before.water - _kg(evaporated), before.extract, before.alcohol,
                   before.isoalpha, before.color, before.co2, before.temperature)
    gavg = (gravity(before; eq) + gravity(after; eq)) / 2
    isoalpha = 0.0u"mg"
    for h in b.hops
        t = min(h.time, b.time)
        isoalpha += isomerized_alpha_acids(models.bitterness, h.amount, h.ingredient.alpha,
                                           gavg, t; factor = hop_form_factor(h.ingredient), eq)
    end
    after = with_temperature(after + Liquor(; isoalpha), 100u"°C")
    out, loss = _retain(after, b.loss, eq; what = "wort for the boil loss")
    return Dict(:out => out, :loss => loss)
end

"""
    Ferment(; culture, attenuation = culture.attenuation, temperature = 20u"°C",
              time = 14u"d", loss = 0u"L")

Ferments whatever arrives at `:in` with the `culture`, down to the given apparent
`attenuation` of its original extract, at `temperature`. By Balling, each 2.0665 g of
extract give 1 g of ethanol, 0.9565 g of CO₂ and 0.11 g of yeast; the CO₂ escapes except
for the residual CO₂ at `temperature`. The volume `loss` (yeast cake, trub) goes to the
port `:loss`, the rest to `:out`.
"""
struct Ferment <: AbstractProcess
    culture::Culture
    attenuation::Float64
    temperature::CQ
    time::typeof(1.0u"d")
    loss::LQ
end

function Ferment(; culture::Culture, attenuation = culture.attenuation, temperature = 20u"°C",
                 time = 14u"d", loss = 0u"L")
    return Ferment(culture, _fraction(attenuation), uconvert(u"°C", float(temperature)),
                   uconvert(u"d", float(time)), uconvert(u"L", float(loss)))
end

outports(::Ferment) = (:out, :loss)

function process(f::Ferment, inputs, models)
    eq = models.gravity
    l = _input(inputs)
    oe, _, _ = _extracts(l)
    ae = (1 - f.attenuation) * oe
    r = (0.1808oe + 0.8192ae) / 100              # target real extract, as a mass fraction
    e, m = ustrip(u"kg", l.extract), ustrip(u"kg", mass(l))
    Δe = max(0.0, (e - r * m) / (1 - r * 1.0665 / 2.0665)) * u"kg"
    Δa = Δe / 2.0665
    fermented = Liquor(l.water, l.extract - Δe, l.alcohol + Δa, l.isoalpha, l.color, 0.0u"g",
                       f.temperature)
    co2 = ustrip(u"vols", residual_co2(f.temperature)) * CO2_PER_VOLS * volume(fermented; eq)
    fermented = Liquor(fermented.water, fermented.extract, fermented.alcohol, fermented.isoalpha,
                       fermented.color, uconvert(u"g", co2), f.temperature)
    out, loss = _retain(fermented, f.loss, eq; what = "beer for the fermentation loss")
    return Dict(:out => out, :loss => loss)
end

"""
    Package(; carbonation = 2.5u"vols", sugar = CornSugar())

Carbonates whatever arrives at `:in` to `carbonation`: by priming with `sugar` (an
`AbstractPrimingSugar` of BrewingFormulas), which also adds a little alcohol, or by forced
carbonation when `sugar = nothing`.
"""
struct Package{S <: Union{Nothing, AbstractPrimingSugar}} <: AbstractProcess
    carbonation::typeof(1.0u"vols")
    sugar::S
end
Package(; carbonation = 2.5u"vols", sugar = CornSugar()) =
    Package(uconvert(u"vols", float(carbonation)), sugar)

"""
    priming_mass(p::Package, liquor; eq)

The mass of priming sugar used by `p` for the `liquor`, zero for forced carbonation.
"""
priming_mass(::Package{Nothing}, l::Liquor; eq = DEFAULT_MODELS.gravity) = 0.0u"g"
priming_mass(p::Package, l::Liquor; eq = DEFAULT_MODELS.gravity) =
    uconvert(u"g", _carbonate(p, l, eq)[2] / co2_yield(p.sugar))

# the carbonated liquor and the CO₂ added; with priming, the alcohol produced changes the
# volume and hence the CO₂ needed, so this is solved by a (fast) fixed-point iteration
function _carbonate(p::Package, l::Liquor, eq)
    out, Δco2 = l, 0.0u"g"
    for _ in 1:20
        target = uconvert(u"g", ustrip(u"vols", p.carbonation) * CO2_PER_VOLS * volume(out; eq))
        new = max(0.0u"g", target - l.co2)
        converged = abs(new - Δco2) ≤ 1e-9u"g"
        Δco2 = new
        alcohol = p.sugar === nothing ? 0.0u"kg" : uconvert(u"kg", ETHANOL_PER_CO2 * Δco2)
        out = Liquor(l.water, l.extract, l.alcohol + alcohol, l.isoalpha, l.color,
                     l.co2 + Δco2, l.temperature)
        converged && break
    end
    return out, Δco2
end

process(p::Package, inputs, models) =
    Dict(:out => _carbonate(p, _input(inputs), models.gravity)[1])
