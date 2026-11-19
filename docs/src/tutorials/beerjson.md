# A BeerJSON recipe

[BeerJSON](https://beerjson.github.io/beerjson/) is the JSON format for brewing recipes,
read and written in Julia by [BeerJSON.jl](https://github.com/JuliaBrewing/BeerJSON.jl).
A BeerJSON recipe builds its quiver: its ingredients as lots, the water, and the stages of
the mash tun, the kettle, the fermentor and the packaging.

## Reading a recipe

We take the RR Summer Bitter from the samples of BeerJSON.jl:

```@example bj
using Unitful, UnitfulBrewing, BrewingFormulas, BeerJSON, BrewQuiver

file = joinpath(pkgdir(BeerJSON), "test", "samples", "converted", "RRSummerBitter.json")
recipe = only(readjson(BeerJSONParser, file).beerjson.recipes)
recipe.name
```

## Its quiver

```@example bj
q = Quiver(recipe; calibration = BrewhouseEfficiency())
```

Each ingredient became a lot, with an arrow per addition, timed as in the recipe; the mash
steps became mash rests (and infusions, decoctions), the boil a [`Boil`](@ref), the
fermentation steps [`Ferment`](@ref)s. The ingredient records convert to the working types
with `Fermentable(addition)`, `Hop(addition)` and `Culture(addition)`.

The volumes a recipe does not give are solved for its own targets: the **sparge water**
for its pre-boil volume, the **evaporation rate** and the **kettle loss** for its batch size:

```@example bj
volume(q[:sparge_water_1].initial)
```

An `equipment` (a BeerJSON `EquipmentType`, given as `Quiver(recipe; equipment = ...)` or
taken from the document) gives the grain absorption, the dead spaces, the losses and the
boil rate, as [`Vessel`](@ref)s of the quiver.

## Calibration

A recipe states the brewhouse efficiency of the brewery it was written for. With
[`BrewhouseEfficiency`](@ref), the conversion of the mash is adjusted so that the quiver
reproduces it; with [`NoCalibration`](@ref) (the default), the efficiency follows from the
processes of the quiver:

```@example bj
res = brew(q)
(brewhouse_efficiency(res, q), quantity(recipe.efficiency.brewhouse))
```

```@example bj
q0 = Quiver(recipe)
brewhouse_efficiency(brew(q0), q0)
```

## The beer

```@example bj
beer = res[:beer]
(og = original_gravity(beer), fg = gravity(beer), abv = abv(beer), ibu = ibu(beer), color = srm(beer))
```

When a recipe states its own estimates (`original_gravity`, `ibu_estimate`,
`color_estimate`), they may differ from these: the recipe's software may use other
formulas for the hop utilization or the color, and its losses are not always stated.
Choose the models with `brew(q; models = ...)`.

## What the importer reads

- Fermentable, hop, culture and miscellaneous additions, with their timing (mash, boil,
  first wort, whirlpool, dry hop, priming).
- The water additions, as the [`WaterProfile`](@ref) of the water, and the "water agent"
  additions (gypsum, calcium chloride, lactic acid, ...) as [`Salt`](@ref)s and
  [`Acid`](@ref)s; the distilled water pH of fermentable records.
- The mash steps: infusions (the water that reaches their temperature, when they give no
  amount), temperature steps and decoctions (their boil and return).
- The boil steps, a whirlpool as a hop stand, the chilling.
- The fermentation steps, and priming as a priming sugar.

Where a recipe is incomplete (a culture without attenuation, a dry hop without time), the
importer warns and takes a default. A [`Library`](@ref) can complete it: `Quiver(recipe;
library = lib)` (see [Ingredient library](../guide/library.md)).

## And back

A quiver exports as BeerJSON recipes, one per product (see [Provenance and
export](@ref)). A recipe exported from a quiver and imported back, with the equipment of
its kettle, brews to the same wort and beer.
