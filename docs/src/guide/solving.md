# Targets and solving

```@setup solve
using BrewQuiver; include(joinpath(pkgdir(BrewQuiver), "docs", "quivers.jl"))
q = single_batch()
```

[`solve!`](@ref) changes parameters of a quiver so that its brew meets targets, by
Newton's method on its brews.

## Targets

A target is `node => f => goal`, for any function `f` of the contents of the node
(`gravity`, `original_gravity`, `volume`, `ibu`, `srm`, `abv`, `carbonation`, ...), with
the goal in any of its units: a gravity in °P is converted with the gravity model.

## What varies

- [`Amount`](@ref)`(lots...)` scales the amounts of lots together, keeping their
  proportions (a grain bill), with the transfers of masses and volumes leaving them.
- [`Setting`](@ref)`(source => destination, field)` varies a numeric field of an arrow:
  the `amount` of a transfer (a blend fraction), the `time` of a boil, the `stand` of a
  hop stand, the `temperature` of a mash rest, ...

There are as many parameters as targets.

## Example

The grain bill, hops, sparge water and priming sugar for an original gravity, a bitterness,
a pre-boil volume and a carbonation:

```@example solve
sol = solve!(q, :fermentor => gravity => 1.052u"sg", :wort => ibu => 35u"IBU",
             :kettle => volume => 28u"L", :bottles => carbonation => 2.4u"vols";
             vary = [Amount(:pale, :crystal), Amount(:goldings), Amount(:sparge_water),
                     Amount(:priming_sugar)])
```

The quiver is changed in place:

```@example solve
q[:pale].initial
```

A goal in other units:

```@example solve
solve!(q, :fermentor => gravity => 13u"°P"; vary = [Amount(:pale, :crystal)])
q[:pale].initial
```

The [`Solution`](@ref) holds the iterations, the parameters and the values reached. If the
targets cannot be met (e.g. a gravity that would need a negative amount), `solve!` throws
an error, leaving the quiver as it was.

The blend fractions of a parti-gyle are solved the same way; see [A parti-gyle](@ref).
