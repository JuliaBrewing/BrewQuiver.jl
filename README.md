# BrewQuiver

[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaBrewing.github.io/BrewQuiver.jl/dev/) [![CI](https://github.com/JuliaBrewing/BrewQuiver.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/JuliaBrewing/BrewQuiver.jl/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) ![GitHub repo size](https://img.shields.io/github/repo-size/JuliaBrewing/BrewQuiver.jl)

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

The [documentation](https://juliabrewing.github.io/BrewQuiver.jl/dev/) has the concepts,
tutorials (a single batch, a parti-gyle, a BeerJSON recipe), a guide to each feature and
the API reference.

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
- The arrows between two nodes are kept in order: `q[source => destination, i]` reads the
  `i`-th one, `q[source => destination, i] = arrow` replaces it, and
  `disconnect!(q, source => destination, i)` removes it; `rename!(q, old, new)` renames a
  node in place, keeping its place in the quiver.
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

## Water chemistry

Liquors carry their dissolved `Minerals` (calcium, magnesium, sodium, chloride, sulfate and
alkalinity), conserved like everything else: they mix, drain, and concentrate in the boil.
Water has a `WaterProfile`; salts and acids are lots that dissolve where they are added; and
`mash_ph` estimates the pH of the mash of a node before its mash rest, from the distilled
water pH and buffering of its grains and Kolbach's residual alkalinity of its water (the
formulas are in BrewingFormulas).

```julia
tap = WaterProfile(calcium = 30u"mg/L", magnesium = 8u"mg/L", sodium = 12u"mg/L",
                   chloride = 25u"mg/L", sulfate = 30u"mg/L", bicarbonate = 120u"mg/L")
add!(q, :strike_water, water(16u"L"; temperature = 75u"°C", profile = tap))
add!(q, :gypsum, Salt(Gypsum()) => 4u"g")
add!(q, :lactic, Acid(LacticAcid()) => 1u"mL")
connect!(q, [:strike_water, :pale, :crystal, :gypsum, :lactic] => :mash)

res = brew(q)
profile(res[:wort])                 # the ions of the wort
residual_alkalinity(res[:mash])     # mg/L as CaCO₃
mash_ph(res[:mash])
```

Pale base malt is taken with a distilled water pH of 5.7 and a buffering of 40 mEq/(kg pH);
crystal and roasted malts need their own distilled water pH (`Fermentable(...; di_ph =
4.7)`), or the estimate warns. The BeerJSON importer reads the water additions of a recipe
as the profile of its water, its "water agent" additions (gypsum, calcium chloride, lactic
acid, ...) as salts and acids, and the distilled water pH of fermentable records.

## Ingredient library and inventory

A `Library` holds ingredients by name, with what is in stock, loaded from the fermentable,
hop and culture records of BeerJSON files (with their inventory) or built with `push!`.

```julia
lib = Library("my_ingredients.json")
add!(q, :pale, lib["Pale Ale Malt"] => 4.5u"kg")
lookup(lib, "crystal")              # the names containing "crystal"

res = brew(q)
requirements(res, q)                # what the brew uses of each ingredient
shortages(lib, res, q)              # what the stock lacks for it
consume!(lib, res, q)               # takes it from the stock
writejson("my_ingredients.json", lib)
```

`Quiver(recipe; library = lib)` completes the additions of a recipe with the records of the
library of the same name: the moisture of fermentables, and the attenuation of cultures.

## Provenance and export

`shares(res, q, product)` gives the share of each lot (ingredient or water) used for a
product, and `attribution(res, q, product)` the share of every node: the fraction of its
contents that goes into making the product, following the liquor, with what is left behind
(spent grain, trub, yeast cake) allocated to the products it serves. In a parti-gyle, the
shares of each lot among the beers add up to what was used of it.

BeerJSON recipes are linear, so a quiver is exported as one recipe per product, holding the
shares of its lots: `recipe(res, q, product)`, `recipes(res, q)`, and
`writejson(path, res, q)` for a BeerJSON document. A recipe exported from a quiver and
imported back (with the equipment of its kettle) brews to the same wort and beer.

## Files of quivers

A quiver is saved and loaded with `writejson` and `readjson` (extending those of
BeerJSON.jl), as a [JSON Graph Format](https://jsongraphformat.info) (JGF) document: its
nodes, with their initial contents and vessel, its arrows as edges in order, its
equipment, and its ingredients as BeerJSON catalogue records.

```julia
writejson("bitter.quiver.json", q; results = brew(q))
q = readjson(Quiver, "bitter.quiver.json")
```

With `results`, each node also gets the values computed by the brew (volume, gravities,
alcohol, bitterness, color, carbonation, temperature, and the mash pH of mashes), so that
other readers of JGF can show them; `readjson` ignores them, and `brew` computes them again.
`nodeview(q, label)` is a dictionary of free data for interfaces (a position, a color, ...),
which BrewQuiver does not use but keeps in the files. New arrow types are written once
registered with `BrewQuiver.register_json_type`. (`write_beerjson` is deprecated in favor of
`writejson`.)

## Step mashes, decoctions, hop stands and dry hops

- **Step mashes** are chains of `MashRest`s in the mash tun, with infusions of water before
  them; the first rest converts the grain.
- **Decoctions** take a part of the mash (`Transfer(fraction)`) to the kettle, boil it
  (`Boil`) and return it before the next rest, which it brings to temperature by the
  mixing of the quiver.
- **Hop stands** (whirlpools) follow the boil: `Boil(time = 60u"minute", stand = 20u"minute",
  stand_temperature = 80u"°C")`. The hops keep isomerizing during the stand at the rate of
  its temperature relative to boiling (`isomerization_factor` of BrewingFormulas), and a
  hop added `At(70u"minute")` stands for the last 10 minutes.
- **Dry hops** are additions to the fermentor with a timing (`Remaining(3u"d")` or
  `At(2u"d")`); they add no bitterness, and keep the beer they absorb when racked, with
  `hop_absorption` on the drain or the vessel.

The BeerJSON importer builds them from the mash steps (infusions without amounts get the
water that reaches their temperature, decoctions their boil and return) and the boil steps
(a whirlpool, the chilling), and the export writes them back.

## Equipment

A `Vessel` describes the equipment of a vessel: its capacity, its dead space (the liquid
left behind when drained: under a false bottom, the trub in a kettle, the yeast cake), the
grain absorption of a mash tun, the evaporation rate of a kettle and the drain rate.
`equip!(q, :kettle, Vessel(...))` attaches it to the stages tagged with that vessel, and
the arrows leaving them take from it what they do not give themselves: a plain `Drain()`
leaves the grain absorption and the dead space behind and takes the time of the drain
rate, and a `Boil(time = 60u"minute")` evaporates at the rate of the kettle.
`unequip!(q, :kettle)` removes it, and `vessel!(q, label, vessel)` moves a node to another
vessel (or to none, with `nothing`). `overfilled(res, q)` lists the stages whose contents (with the grain displaced in a mash)
exceed the capacity of their vessel. The equipment of a BeerJSON document becomes the
vessels of the quiver of a recipe.

```julia
equip!(q, :kettle, Vessel(name = "Kettle", capacity = 36u"L", evaporation = 4u"L/hr",
                          dead_space = 1u"L", drain_rate = 1.5u"L/minute"))
```

## Targets and solving

`solve!(q, targets...; vary)` changes parameters of a quiver so that its brew meets
targets, by Newton's method on its brews. A target is `node => f => goal`, for any function
`f` of the contents of the node (`gravity`, `volume`, `ibu`, `srm`, `abv`, `carbonation`,
...), with the goal in any of its units (a gravity in °P is converted with the gravity
model). What varies is the amount of lots, `Amount(:pale, :crystal)` scaling them together
(with the transfers of masses and volumes leaving them), or a numeric field of an arrow,
`Setting(:kettle => :wort, :stand)`; there are as many as targets.

```julia
sol = solve!(q, :fermentor => gravity => 1.052u"sg", :wort => ibu => 35u"IBU",
             :kettle => volume => 28u"L", :bottles => carbonation => 2.4u"vols";
             vary = [Amount(:pale, :crystal), Amount(:goldings), Amount(:sparge_water),
                     Amount(:priming_sugar)])
```

```
Solution in 3 iterations
  amount of :pale, :crystal: :crystal Contents(302.0 g Crystal 60), :pale Contents(4.531 kg Pale ale malt)
  amount of :goldings: Contents(87.5 g East Kent Goldings)
  amount of :sparge_water: Contents(14.98 L, 1.0 sg, 80.0 °C)
  amount of :priming_sugar: Contents(151.0 g Corn sugar)
  ...
```

The blend fractions of a parti-gyle are solved the same way, e.g. for the gravities of two
of its beers, with `Setting(:bright1 => :barley_wine, :amount)`.

## Timeline

Every arrow has a `duration`: the `time` of a transformation (the mash rest, the boil, the
fermentation, the conditioning) and the `duration` of a transfer or a drain. `timeline(q)`
places them as early as the quiver allows: a node is ready when all the streams reaching it
have arrived, the lots without timing arrive then (the yeast is pitched when the wort is
in), the timed additions arrive during the transformation that follows (a hop with 10
minutes of boil left), and the transfers of the rest follow the drains (the grain bed is
sparged after the first runnings). It gives when each node is filled, ready and emptied,
grouped by vessel, `vesselchart(s)` draws it as a chart, and `overlaps(s)` flags a vessel
booked for two contents at once.

```julia
s = timeline(q; start = 8u"hr")
s[:kettle]             # when the kettle is filled, ready and emptied
vesselchart(s; to = 13u"hr")
```

```
            8:00                                                   13:00
  mashtun   ████████████▒▒▒▒▒
  kettle                ▒▒▒▒▒█████████████████▒▒▒
  fermentor                                   ▒▒▒███████████████████████
```

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
