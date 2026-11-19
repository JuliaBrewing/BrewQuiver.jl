# A single batch

This tutorial builds the quiver of an all-grain English bitter, step by step: a mash with a
batch sparge, a boil with two hop additions, a fermentation and bottle conditioning. It then
brews it, reads the results, and checks where every gram went.

## The ingredients

Ingredients are working types built from their brewing parameters, with units:

```@example single
using Unitful, UnitfulBrewing, BrewingFormulas, BrewQuiver

pale     = Fermentable("Pale ale malt"; yield = 80u"percent", color = 3u"°L")
crystal  = Fermentable("Crystal 60"; yield = 74u"percent", color = 60u"°L")
goldings = Hop("East Kent Goldings"; alpha = 5u"percent")
ale      = Culture("English ale"; attenuation = 75u"percent")
dextrose = Fermentable("Corn sugar"; kind = :sugar, yield = 100u"percent", color = 0u"SRM",
                       moisture = 0)
nothing # hide
```

A [`Fermentable`](@ref) has a `kind` (`:grain` by default, `:sugar`, `:extract`, ...), a
yield (fine grind, as is), a color and a moisture (4% for grains by default). A
[`Hop`](@ref) has its alpha acids and form (pellets by default); a [`Culture`](@ref) its
apparent attenuation.

## The lots

The **lots** are the sources of the quiver: an ingredient with its amount, or a liquor.

```@example single
q = Quiver()
add!(q, :pale, pale => 4.5u"kg")
add!(q, :crystal, crystal => 0.3u"kg")
add!(q, :goldings, goldings => 50u"g")
add!(q, :yeast, ale => 1)                                   # one pack
add!(q, :strike_water, water(16u"L"; temperature = 75u"°C"))
add!(q, :sparge_water, water(14u"L"; temperature = 80u"°C"))
add!(q, :priming_sugar, dextrose => 110u"g")
nothing # hide
```

## The stages

Each vessel goes through **stages**, empty nodes filled by the arrows. The mash tun holds
the mash (grain and water), the rested mash (converted), then the grain bed being sparged;
the kettle holds the wort before and after the boil, then chilled:

```@example single
add!(q, :mash, :rested, :grain_bed; vessel = :mashtun)
add!(q, :kettle, :wort, :chilled; vessel = :kettle)
add!(q, :fermentor, :beer; vessel = :fermentor)
add!(q, :bottling, :bottles; vessel = :bottles)
nothing # hide
```

## The equipment

The [`Vessel`](@ref)s give what the arrows leaving their stages do not say: the grain
absorption and dead space of the mash tun, the evaporation rate of the kettle, the drain
rates (see [Equipment](../guide/equipment.md)).

```@example single
equip!(q, :mashtun, Vessel(name = "Cooler", capacity = 36u"L", absorption = 1.0u"L/kg",
                           dead_space = 0.5u"L", drain_rate = 1u"L/minute"))
equip!(q, :kettle, Vessel(name = "Kettle", capacity = 36u"L", evaporation = 4u"L/hr",
                          dead_space = 1u"L", drain_rate = 1.5u"L/minute"))
equip!(q, :fermentor, Vessel(name = "Bucket", capacity = 30u"L", dead_space = 1u"L"))
nothing # hide
```

## The arrows

The mash: the strike water and the grain go to the mash tun, which rests at 67 °C. The
first runnings are drained to the kettle; the grain, with the wort it absorbed, stays as
the grain bed, which gets the sparge water and is drained again (a batch sparge).

```@example single
connect!(q, [:strike_water, :pale, :crystal] => :mash)
connect!(q, :mash => :rested, MashRest(temperature = 67u"°C", time = 60u"minute"))
connect!(q, :rested => :kettle, Drain())                    # first runnings
connect!(q, :rested => :grain_bed)                          # the rest: grain and absorbed wort
connect!(q, :sparge_water => :grain_bed)
connect!(q, :grain_bed => :kettle, Drain())                 # second runnings
nothing # hide
```

The boil: two additions from the same lot of hops, with 60 and 10 minutes of boil left.
They are two arrows between the same nodes, which is why the graph is a *multi*graph.

```@example single
connect!(q, :goldings => :kettle, Transfer(30u"g"; remaining = 60u"minute"))
connect!(q, :goldings => :kettle, Transfer(20u"g"; remaining = 10u"minute"))
connect!(q, :kettle => :wort, Boil(time = 60u"minute"))
connect!(q, :wort => :chilled, Chill(temperature = 20u"°C", time = 25u"minute"))
nothing # hide
```

The fermentation and the bottling: the chilled wort is drained off the trub and hops,
the yeast is pitched, and the beer is drained off its yeast cake onto the priming sugar.

```@example single
connect!(q, :chilled => :fermentor, Drain())
connect!(q, :yeast => :fermentor)
connect!(q, :fermentor => :beer, Ferment(temperature = 20u"°C", time = 14u"d"))
connect!(q, :priming_sugar => :bottling)
connect!(q, :beer => :bottling, Drain())
connect!(q, :bottling => :bottles, Prime(sugar = CornSugar()))
q
```

## Brewing

[`brew`](@ref) computes every node, in topological order:

```@example single
res = brew(q)
```

Each node is a [`Contents`](@ref), and the usual quantities derive from it:

```@example single
res[:kettle]
```

```@example single
beer = res[:bottles]
(volume = volume(beer), og = original_gravity(beer), fg = gravity(beer),
 abv = abv(beer), ibu = ibu(beer), color = srm(beer), co2 = carbonation(beer))
```

What happened along an arrow is in the [`ArrowResult`](@ref)s, e.g. the first runnings and
the water evaporated by the boil:

```@example single
only(res[:rested => :kettle]).moved
```

```@example single
only(res[:kettle => :wort]).released
```

## Where everything went

What no arrow takes from a node is its leftover: the spent grain with the wort it holds,
the trub and the hops, the yeast cake, and the products themselves.

```@example single
leftovers(res)
```

With what the arrows released, evaporated water and CO₂, the masses add up exactly to the
lots:

```@example single
initial = sum(total_mass(q[n].initial) for n in nodes(q))
left = sum(total_mass, values(leftovers(res)))
r = released(res)
initial ≈ left + r.water + r.co2
```

## Changing the brew

Arrows and lots can be replaced, and [`rebrew!`](@ref) recomputes only what is downstream:

```@example single
q[:kettle => :wort] = Boil(time = 90u"minute")
rebrew!(res, q, :kettle)
(volume(res[:bottles]), original_gravity(res[:bottles]), ibu(res[:bottles]))
```

## Next

- The [timeline](../guide/timeline.md) of this brew, and its [targets](../guide/solving.md).
- Its [water chemistry](../guide/water.md) and mash pH.
- Saving it: [Files of quivers](@ref).
