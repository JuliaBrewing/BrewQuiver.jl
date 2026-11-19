# Equipment

```@setup eq
using BrewQuiver; include(joinpath(pkgdir(BrewQuiver), "docs", "quivers.jl"))
```

A [`Vessel`](@ref) describes the equipment of a vessel:

| Field            | What it is                                                         |
|:-----------------|:-------------------------------------------------------------------|
| `capacity`       | the volume it holds, checked by [`overfilled`](@ref)               |
| `dead_space`     | the liquid left behind when drained (under a false bottom, the trub in a kettle, the yeast cake) |
| `absorption`     | the liquid absorbed by the grain, per mass of grain (a mash tun)   |
| `hop_absorption` | the liquid absorbed by hops, per mass of hops (a kettle, a fermentor with dry hops) |
| `evaporation`    | the evaporation rate of a boil: a volume per hour, or a fraction per hour |
| `drain_rate`     | the volume drained per unit of time                                |

[`equip!`](@ref) attaches it to the stages tagged with that vessel (`add!(...; vessel =
:kettle)`). The arrows leaving them **take from it what they do not give themselves**:

- a plain `Drain()` leaves the grain absorption and the dead space behind, and takes the
  time of the drain rate;
- `Boil(time = 60u"minute")` evaporates at the rate of the kettle.

An arrow that gives its own value overrides the vessel: `Drain(retain = 2u"L")`,
`Boil(evaporation = 5u"L/hr")`.

```@example eq
q = single_batch()
equipment(q, :kettle)
```

```@example eq
res = brew(q)
volume(res[:kettle]) - volume(res[:wort])     # 4 L/hr for an hour, and the cooling shrinkage
```

## Capacity

[`overfilled`](@ref) lists the stages whose contents exceed the capacity of their vessel
(with the volume the grain displaces in a mash):

```@example eq
equip!(q, :fermentor, Vessel(name = "Small bucket", capacity = 20u"L"))
foreach(println, overfilled(brew(q), q))
```

## From BeerJSON

The equipment items of a BeerJSON document (mash tun, kettle, fermentor, ...) become the
vessels of the quiver of a recipe; see [A BeerJSON recipe](@ref).
