# BrewQuiver.jl

*The brewing process as a quiver.*

BrewQuiver is the engine of the BrewQuiver brewing software, in pure Julia. It describes the
brewing process as a **quiver**: a directed acyclic multigraph whose **nodes are the contents
of vessels** at the stages of the brewing (the lots of malt and hops, the water, the mash,
the wort in the kettle, the beer in the fermentor, ...) and whose **arrows are the
processes** between them: transfers, drains, mash rests, boils, fermentations, conditioning.

Unlike a linear recipe, a quiver can split and merge streams, as in parti-gyle brewing,
double mashes or blending. And since the state of every node holds conserved quantities
only, mixing and splitting are exact, and every gram of water, extract and hop is accounted
for over the whole brew.

```@raw html
<pre style="line-height:1.25">
  pale ─┐                    goldings ─┐
crystal ─┼─▶ mash ─MashRest─▶ rested ─Drain─▶ kettle ─Boil─▶ wort ─Chill─▶ chilled ─Drain─▶ fermentor ─Ferment─▶ beer
 water ─┘                       │               ▲                                         ▲
                                └─▶ grain_bed ─Drain┘                                    yeast
                    sparge water ──▶┘
</pre>
```

## Features

- **Exact mass balance.** Water, extract, alcohol, iso-alpha acids, CO₂, color units and
  dissolved minerals are conserved: what no arrow takes is kept as a leftover (spent grain,
  trub, yeast cake), and what the arrows release (evaporated water, CO₂) is counted.
- **Derived quantities** with [BrewingFormulas.jl](https://github.com/JuliaBrewing/BrewingFormulas.jl):
  volume, gravity, original gravity, ABV, IBU, color, carbonation, mash pH, with models
  chosen per brew (Tinseth or Rager, Morey, ...).
- **Units everywhere** with [Unitful.jl](https://github.com/PainterQubits/Unitful.jl) and
  [UnitfulBrewing.jl](https://github.com/JuliaBrewing/UnitfulBrewing.jl): `4.5u"kg"`,
  `1.052u"sg"`, `12u"°P"`, `35u"IBU"`, `2.4u"vols"`.
- **Brewing techniques**: batch and fly sparging, step mashes, decoctions, hop stands, dry
  hops, bottle priming and forced carbonation, parti-gyles and blends.
- **Equipment**: capacities, dead spaces, grain absorption, evaporation and drain rates.
- **Water chemistry**: mineral profiles, salts and acids, residual alkalinity, mash pH.
- **Timeline** of the brew day and the fermentation, per vessel.
- **Targets**: solve the amounts and settings that give a gravity, a bitterness, a volume.
- **Provenance**: the share of every lot in every product.
- **BeerJSON**: import recipes as quivers, export quivers as recipes, ingredient libraries
  with inventory, with [BeerJSON.jl](https://github.com/JuliaBrewing/BeerJSON.jl).
- **Files of quivers** in the JSON Graph Format, with the ingredients as BeerJSON records.

## Installation

BrewQuiver is under development and not yet registered. It needs Julia 1.11 or later, and
takes its sibling packages from GitHub through the `[sources]` of its `Project.toml`:

```julia
using Pkg
Pkg.add(url = "https://github.com/JuliaBrewing/BrewQuiver.jl")
```

For the examples you will also want the units and the formulas:

```julia
Pkg.add(url = "https://github.com/JuliaBrewing/UnitfulBrewing.jl")
Pkg.add(url = "https://github.com/JuliaBrewing/BrewingFormulas.jl")
Pkg.add("Unitful")
```

## A first quiver

```@example index
using Unitful, UnitfulBrewing, BrewingFormulas, BrewQuiver

pale    = Fermentable("Pale ale malt"; yield = 80u"percent", color = 3u"°L")
cascade = Hop("Cascade"; alpha = 6u"percent")
us05    = Culture("US-05"; attenuation = 78u"percent")

q = Quiver()
add!(q, :pale, pale => 4.5u"kg")
add!(q, :cascade, cascade => 30u"g")
add!(q, :yeast, us05 => 1)
add!(q, :water, water(26u"L"; temperature = 72u"°C"))
add!(q, :mash, :wort; vessel = :mashtun)
add!(q, :kettle, :hopped; vessel = :kettle)
add!(q, :fermentor, :beer; vessel = :fermentor)

connect!(q, [:water, :pale] => :mash)
connect!(q, :mash => :wort, MashRest(temperature = 66u"°C"))
connect!(q, :wort => :kettle, Drain(absorption = 1u"L/kg"))
connect!(q, :cascade => :kettle, Transfer(; remaining = 60u"minute"))
connect!(q, :kettle => :hopped, Boil(time = 60u"minute", evaporation = 4u"L/hr"))
connect!(q, :hopped => :fermentor, Drain(retain = 1u"L"))
connect!(q, :yeast => :fermentor)
connect!(q, :fermentor => :beer, Ferment(temperature = 19u"°C", time = 14u"d"))

res = brew(q)
res[:beer]
```

```@example index
(original_gravity(res[:beer]), gravity(res[:beer]), abv(res[:beer]), ibu(res[:beer]), srm(res[:beer]))
```

Continue with the [Concepts](@ref), then the [tutorials](@ref "A single batch").

## Related packages

- [UnitfulBrewing.jl](https://github.com/JuliaBrewing/UnitfulBrewing.jl): brewing units.
- [BrewingFormulas.jl](https://github.com/JuliaBrewing/BrewingFormulas.jl): the formulas
  and models, with their references.
- [BeerJSON.jl](https://github.com/JuliaBrewing/BeerJSON.jl): reading and writing BeerJSON.
