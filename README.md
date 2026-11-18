# BrewQuiver

[![CI](https://github.com/JuliaBrewing/BrewQuiver.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/JuliaBrewing/BrewQuiver.jl/actions/workflows/ci.yml)

The engine of the BrewQuiver brewing software, in pure Julia: the brewing process as a
**quiver**, a directed acyclic multigraph whose **nodes are the contents of vessels** at the
stages of the brewing (the lots of malt and hops, the water, the mash, the wort in the
kettle, the beer in the fermentor, ...) and whose **arrows are the processes** between them:
transfers, drains, mash rests, boils, fermentations, conditioning. Unlike a linear recipe, a
quiver can split and merge streams, as in parti-gyle brewing, double mashes, or blending.

This package is still **under development** and not yet registered. It builds on
[UnitfulBrewing.jl](https://github.com/JuliaBrewing/UnitfulBrewing.jl) for the units and on
[BrewingFormulas.jl](https://github.com/JuliaBrewing/BrewingFormulas.jl) for the formulas,
both taken from GitHub through the `[sources]` of `Project.toml` (Julia 1.11 or later):

```julia
using Pkg
Pkg.add(url = "https://github.com/JuliaBrewing/BrewQuiver.jl")
```

## Design

- **`Contents`**, the state of a node, holds *conserved* quantities only: a `Liquor` (the
  masses of water, extract, alcohol, iso-alpha acids and CO₂, color units in lb·°L, and the
  temperature) and solids (ingredients as added, spent grain, hop matter, yeast). Mixing is
  `+` and splitting is scaling by a fraction, so both are exact. The volume (at 20 °C),
  gravity, original gravity, ABV, IBU, color and carbonation are derived with
  BrewingFormulas.
- **Nodes** are added with `add!`: lots with initial contents (`pale => 4.5u"kg"`,
  `water(16u"L")`), and the empty stages of each vessel, filled by arrows. Whatever arrives
  at a node is mixed, so blending needs no special process.
- **Arrows** are added with `connect!`. A quiver may have several arrows between the same
  nodes (two hop additions from the same lot):
  - `Transfer(amount)` moves a uniform part of the contents (a volume, a mass, a fraction,
    or the rest), with the timing of the ingredients it brings (`remaining = 10u"minute"`
    or `at = 50u"minute"`, relative to the transformation that follows);
  - `Drain` moves the liquid only, leaving the solids, what the grain absorbs and what the
    vessel retains;
  - transformations (`MashRest`, `Boil`, `Chill`, `Ferment`, `Prime`, `Carbonate`) turn all the
    contents of a node into the next stage of the vessel. They act on what is in the node:
    the grain that was mashed in, the hops in the kettle, each for its own time, the culture
    that was pitched, the priming sugar in the bottling bucket.
- **`brew(q)`** computes the nodes in topological order and returns a `BrewResult`:
  `res[label]` is the contents of a node and `res[source => destination]` what its arrows
  did. What no arrow takes is kept as a leftover (spent grain, trub, yeast cake), so with
  what the arrows release (evaporated water, CO₂) every mass is conserved over the whole
  quiver. `rebrew!(res, q, label)` recomputes only what is downstream of a change.
- **Models** (hop utilization, color, ABV, gravity conversion) come from BrewingFormulas and
  are chosen per brew: `brew(q; models = (bitterness = Rager(),))`.

## BeerJSON recipes

With [BeerJSON.jl](https://github.com/JuliaBrewing/BeerJSON.jl), the ingredients of BeerJSON
convert to the working types (`Fermentable(addition)`, `Hop(addition)`, `Culture(addition)`),
and a recipe builds its quiver: its ingredients as lots, the water, and the stages of the mash
tun, the kettle, the fermentor and the packaging.

```julia
using BeerJSON

recipe = only(readjson(BeerJSONParser, "RRSummerBitter.json").beerjson.recipes)
q = Quiver(recipe; calibration = BrewhouseEfficiency())
res = brew(q)
brewhouse_efficiency(res, q)    # 0.75, as in the recipe
```

The volumes the recipe does not give are solved for its own targets: the sparge water for
its pre-boil volume, the evaporation rate and the kettle loss for its batch size. An
`equipment` (a BeerJSON `EquipmentType`) gives the grain absorption, dead spaces, losses and
boil rate. With `BrewhouseEfficiency()`, the conversion of the mash is adjusted to the
efficiency of the recipe; with `NoCalibration()` (the default), the efficiency follows from
the processes. See [`examples/beerjson_recipe.jl`](examples/beerjson_recipe.jl).

## References

The formulas are those of BrewingFormulas, whose `REFERENCES.md` lists their sources. The
mass balance of fermentation and the original extract of fermented liquors follow Balling's
relations (J. De Clerck, *A Textbook of Brewing*, 1958; M. L. Hall, "Brew By the Numbers",
*Zymurgy*, Summer 1995; J. Šavel et al., *Kvasny prumysl* 66 (2020) 239–244).

## Example

```julia
using Unitful, UnitfulBrewing, BrewingFormulas, BrewQuiver

pale     = Fermentable("Pale ale malt"; yield = 80u"percent", color = 3u"°L")
crystal  = Fermentable("Crystal 60"; yield = 74u"percent", color = 60u"°L")
cascade  = Hop("Cascade"; alpha = 6u"percent")
us05     = Culture("US-05"; attenuation = 78u"percent")
dextrose = Fermentable("Corn sugar"; kind = :sugar, yield = 100u"percent", moisture = 0)

q = Quiver()

# the lots on the shelf
add!(q, :pale, pale => 4.5u"kg")
add!(q, :crystal, crystal => 0.3u"kg")
add!(q, :cascade, cascade => 50u"g")
add!(q, :yeast, us05 => 1)
add!(q, :strike_water, water(16u"L"; temperature = 75u"°C"))
add!(q, :sparge_water, water(14u"L"; temperature = 80u"°C"))
add!(q, :priming_sugar, dextrose => 130u"g")

# the stages of each vessel
add!(q, :mash, :rested, :grain_bed; vessel = :mashtun)
add!(q, :kettle, :wort, :chilled; vessel = :kettle)
add!(q, :fermentor, :beer; vessel = :fermentor)
add!(q, :bottling, :bottles; vessel = :bottles)

# mash and batch sparge
connect!(q, [:strike_water, :pale, :crystal] => :mash)
connect!(q, :mash => :rested, MashRest(temperature = 67u"°C", time = 60u"minute"))
connect!(q, :rested => :kettle, Drain(absorption = 1.0u"L/kg"))   # first runnings
connect!(q, :rested => :grain_bed)                                 # grain and absorbed wort
connect!(q, :sparge_water => :grain_bed)
connect!(q, :grain_bed => :kettle, Drain(absorption = 1.0u"L/kg")) # second runnings

# boil, fermentation, bottle conditioning
connect!(q, :cascade => :kettle, Transfer(25u"g"; remaining = 60u"minute"))
connect!(q, :cascade => :kettle, Transfer(25u"g"; remaining = 10u"minute"))
connect!(q, :kettle => :wort, Boil(time = 60u"minute", evaporation = 4u"L/hr"))
connect!(q, :wort => :chilled, Chill(temperature = 19u"°C"))
connect!(q, :chilled => :fermentor, Drain(retain = 1u"L"))        # trub and hops stay
connect!(q, :yeast => :fermentor)
connect!(q, :fermentor => :beer, Ferment(temperature = 19u"°C", time = 14u"d"))
connect!(q, :priming_sugar => :bottling)
connect!(q, :beer => :bottling, Drain(retain = 1u"L"))            # the yeast cake stays
connect!(q, :bottling => :bottles, Prime(sugar = CornSugar()))

res = brew(q)
res[:bottles]      # the beer in the bottles
leftovers(res)     # spent grain, trub, yeast cake, ... and the bottles
```

See [`examples/single_batch.jl`](examples/single_batch.jl), and
[`examples/fullers_partigyle.jl`](examples/fullers_partigyle.jl) for the parti-gyle of
Fuller's Barley Wine, ESB, Pale Ale and Bitter: two mashes, three boils and fermentors, and
four blended beers.

The previous design, with processes as nodes and transfers as edges, is in version 0.0.1.
