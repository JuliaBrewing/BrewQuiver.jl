# Mashes, decoctions, stands and dry hops

```@setup tech
using Unitful, UnitfulBrewing, BrewingFormulas, BrewQuiver
pale = Fermentable("Pilsner malt"; yield = 81u"percent", color = 1.6u"°L")
saaz = Hop("Saaz"; alpha = 3.5u"percent")
citra = Hop("Citra"; alpha = 12u"percent")
```

All the techniques below are built from the same few arrows; no special process is needed.

## Step mashes

A step mash is a chain of [`MashRest`](@ref)s in the mash tun, with infusions of water
before them. The **first** rest converts the grain; the next ones bring the mash to their
temperature (the temperature of a node is the temperature of the mixture that reached it).

```@example tech
q = Quiver()
add!(q, :pilsner, pale => 5u"kg")
add!(q, :dough_in, water(12u"L"; temperature = 57u"°C"))
add!(q, :infusion, water(6u"L"; temperature = 98u"°C"))
add!(q, :mash, :protein_rest, :sacch, :mashout; vessel = :mashtun)
connect!(q, [:dough_in, :pilsner] => :mash)
connect!(q, :mash => :protein_rest, MashRest(temperature = 52u"°C", time = 15u"minute"))
connect!(q, [:protein_rest, :infusion] => :sacch)
connect!(q, :sacch => :mashout, MashRest(temperature = 66u"°C", time = 60u"minute"))
res = brew(q)
(res[:sacch].liquor.temperature, res[:mashout].liquor.temperature, gravity(res[:mashout]))
```

The infusion brings the mash to the temperature of the mixture; the rest then holds it at
its own temperature, heating as needed.

## Decoctions

A decoction takes a part of the mash (a `Transfer` of a fraction) to the kettle, boils it,
and returns it before the next rest, which it brings to temperature by mixing:

```@example tech
q = Quiver()
add!(q, :pilsner, pale => 5u"kg")
add!(q, :strike, water(15u"L"; temperature = 55u"°C"))
add!(q, :mash, :rested, :remaining, :sacch, :done; vessel = :mashtun)
add!(q, :decoction, :boiled; vessel = :kettle)
connect!(q, [:strike, :pilsner] => :mash)
connect!(q, :mash => :rested, MashRest(temperature = 52u"°C", time = 20u"minute"))
connect!(q, :rested => :decoction, Transfer(35u"percent"))   # the thick part
connect!(q, :rested => :remaining)
connect!(q, :decoction => :boiled, Boil(time = 15u"minute"))
connect!(q, [:remaining, :boiled] => :sacch)
connect!(q, :sacch => :done, MashRest(temperature = 66u"°C", time = 45u"minute"))
brew(q)[:sacch].liquor.temperature
```

The boil of a decoction evaporates little (10%/hr, `BrewQuiver.DECOCTION_EVAPORATION`, when
the vessel gives no rate).

## Hop stands

A hop stand (whirlpool) follows the boil, as part of the [`Boil`](@ref):

```julia
Boil(time = 60u"minute", stand = 20u"minute", stand_temperature = 80u"°C")
```

The hops keep isomerizing during the stand at the rate of its temperature relative to
boiling (`isomerization_factor` of BrewingFormulas). A hop added `At(70u"minute")` stands
for the last 10 minutes; one added with `remaining = 0u"minute"` (at flameout) for all of
the stand.

```@example tech
q = Quiver()
add!(q, :wort_in, wort(25u"L", 1.050u"sg"; temperature = 100u"°C"))
add!(q, :saaz, saaz => 60u"g")
add!(q, :kettle, :hopped; vessel = :kettle)
connect!(q, :wort_in => :kettle)
connect!(q, :saaz => :kettle, Transfer(30u"g"; remaining = 60u"minute"))
connect!(q, :saaz => :kettle, Transfer(30u"g"; remaining = 0u"minute"))      # flameout
connect!(q, :kettle => :hopped, Boil(time = 60u"minute", stand = 20u"minute", stand_temperature = 80u"°C"))
ibu(brew(q)[:hopped])
```

## First wort hops and additions by time

Timings are relative to the transformation that follows the node the ingredient arrives
at: [`Remaining`](@ref)`(t)` with `t` left of it, [`At`](@ref)`(t)` after it starts.
An ingredient arriving without timing is in for the whole transformation (first wort
hops, the grain in the mash).

## Dry hops

Dry hops are additions to the fermentor with a timing (`Remaining(3u"d")` or
`At(2u"d")`); they add no bitterness, and keep the beer they absorb when racked, with
`hop_absorption` on the drain or the vessel:

```@example tech
q = Quiver()
add!(q, :wort_in, wort(20u"L", 1.060u"sg"; temperature = 19u"°C"))
add!(q, :citra, citra => 100u"g")
add!(q, :yeast, Culture("US-05"; attenuation = 78u"percent") => 1)
add!(q, :fermentor, :beer; vessel = :fermentor)
add!(q, :keg)
connect!(q, [:wort_in, :yeast] => :fermentor)
connect!(q, :citra => :fermentor, Transfer(; remaining = 4u"d"))
connect!(q, :fermentor => :beer, Ferment(temperature = 19u"°C", time = 14u"d"))
connect!(q, :beer => :keg, Drain(hop_absorption = 5u"L/kg"))
res = brew(q)
(ibu(res[:keg]), volume(res[:keg]), volume(leftover(res, :beer)))
```

## Fly sparging and double mashes

- **Fly sparging** is a sparge with drains in between, or a single drain of the grain bed
  that receives the sparge water: the quiver does not model the gradient, only the
  balance of what goes in and out.
- A **double mash** drains the wort of a mash into another mash, as its strike liquor.

## Carbonation

Bottle conditioning is a [`Prime`](@ref) (the priming sugar in the node is fermented,
with its CO₂ dissolved); forced carbonation a [`Carbonate`](@ref) to a level in volumes.
[`priming_mass`](@ref) gives the sugar for a carbonation.
