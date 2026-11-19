# A parti-gyle

In a **parti-gyle**, the successive runnings of the same mash make worts of decreasing
strength, which are boiled, fermented and often blended into several beers. It is a quiver
that no linear recipe can describe: streams split at every drain and merge at every copper
and every blend.

This tutorial follows the joint production of Fuller's Barley Wine, ESB, Pale Ale and
Bitter (figure 1 of the BrewQuiver notes): two mashes are drained three times each, the
i-th runnings of both go to the i-th copper, and the three fermented beers are racked and
blended into four, aiming at the strengths of Golden Pride (OG about 1.088), ESB (1.059),
London Pride (1.047) and Chiswick Bitter (1.035). *The amounts are illustrative, not
Fuller's actual recipes.*

## Ingredients and vessels

```@example partigyle
using Unitful, UnitfulBrewing, BrewingFormulas, BrewQuiver
using BeerJSON: quantity

pale     = Fermentable("Pale ale malt"; yield = 80u"percent", color = 3u"°L")
crystal  = Fermentable("Crystal 60"; yield = 74u"percent", color = 60u"°L")
invert   = Fermentable("Invert sugar"; kind = :sugar, yield = 100u"percent", color = 1u"SRM",
                       moisture = 0)
goldings = Hop("East Kent Goldings"; alpha = 5u"percent")
ale      = Culture("English ale"; attenuation = 72u"percent")

q = Quiver()
add!(q, :goldings, goldings => 1.5u"kg")
add!(q, :invert, invert => 4u"kg")

# three coppers, three fermenting vessels and three racking tanks
for i in 1:3
    add!(q, Symbol(:yeast, i), ale => 1)
    add!(q, Symbol(:kettle, i), Symbol(:wort, i), Symbol(:chilled, i); vessel = Symbol(:copper, i))
    add!(q, Symbol(:fermentor, i), Symbol(:beer, i); vessel = Symbol(:fv, i))
    add!(q, Symbol(:bright, i); vessel = Symbol(:tank, i))
end
nothing # hide
```

## Two mashes, three runnings each

Each mash is drained three times: the first runnings from the mash itself, the second and
third after sparging the grain bed. The i-th runnings go to the i-th copper, so each copper
gets the runnings of both mashes.

```@example partigyle
for (m, grist) in enumerate(([pale => 70u"kg", crystal => 4u"kg"],
                             [pale => 60u"kg", crystal => 2u"kg"]))
    mash = Symbol(:mash, m)
    beds = [Symbol(:bed, m, :_, i) for i in 1:3]
    lots = [Symbol(:grist, m, :_, j) for j in eachindex(grist)]
    foreach((l, g) -> add!(q, l, g), lots, grist)
    add!(q, Symbol(:strike, m), water(190u"L"; temperature = 75u"°C"))
    add!(q, mash, beds...; vessel = Symbol(:mashtun, m))
    connect!(q, [Symbol(:strike, m); lots] => mash)
    connect!(q, mash => beds[1], MashRest(temperature = 66u"°C", time = 60u"minute"))
    for (i, v) in enumerate((nothing, 60u"L", 40u"L"))
        if v !== nothing                                     # sparge the grain bed
            add!(q, Symbol(:sparge, m, :_, i), water(v; temperature = 80u"°C"))
            connect!(q, beds[i - 1] => beds[i])               # the grain and what it holds
            connect!(q, Symbol(:sparge, m, :_, i) => beds[i])
        end
        connect!(q, beds[i] => Symbol(:kettle, i), Drain(absorption = 1.0u"L/kg"))
    end
end
```

## Boils, fermentations and racking

The strongest wort gets the invert sugar and most of the hops:

```@example partigyle
for (i, hops) in enumerate((1100u"g", 270u"g", 130u"g"))
    kettle, wort, chilled, fv, beer, bright =
        (Symbol(x, i) for x in (:kettle, :wort, :chilled, :fermentor, :beer, :bright))
    connect!(q, :goldings => kettle, Transfer(hops; remaining = 90u"minute"))
    i == 1 && connect!(q, :invert => kettle)
    connect!(q, kettle => wort, Boil(time = 90u"minute", evaporation = 8u"L/hr"))
    connect!(q, wort => chilled, Chill(temperature = 18u"°C"))
    connect!(q, chilled => fv, Drain(retain = 2u"L"))
    connect!(q, Symbol(:yeast, i) => fv)
    connect!(q, fv => beer, Ferment(temperature = 19u"°C", time = 7u"d"))
    connect!(q, beer => bright, Drain(retain = 2u"L"))
end
```

## Blending

Four beers from three: the blends are just nodes where transfers merge. A `Transfer` of a
percentage takes that fraction; a plain `Transfer()` takes the rest.

```@example partigyle
add!(q, :barley_wine, :esb, :pale_ale, :bitter)
connect!(q, :bright1 => :esb, Transfer(6u"percent"))
connect!(q, :bright1 => :barley_wine)
connect!(q, :bright2 => :esb, Transfer(60u"percent"))
connect!(q, :bright2 => :pale_ale)
connect!(q, :bright3 => :pale_ale, Transfer(16u"percent"))
connect!(q, :bright3 => :bitter)
nothing # hide
```

## The beers

```@example partigyle
res = brew(q)
beers = (:barley_wine, :esb, :pale_ale, :bitter)
for b in beers
    println(rpad(b, 12), round(u"L", volume(res[b])), "  OG ", round(u"sg", original_gravity(res[b]); digits = 3),
            "  ", round(u"percent", abv(res[b]); digits = 1), " ABV  ", round(u"IBU", ibu(res[b])))
end
```

The stages each vessel goes through:

```@example partigyle
sort!(collect(vessels(q)))
```

## A change upstream

A more attenuative fermentation of the second gyle changes the ESB and the Pale Ale, which
contain it, but not the Barley Wine or the Bitter. [`rebrew!`](@ref) recomputes only the
nodes downstream:

```@example partigyle
q[:fermentor2 => :beer2] = Ferment(temperature = 19u"°C", time = 7u"d", attenuation = 80u"percent")
rebrew!(res, q, :fermentor2)
for b in beers
    println(rpad(b, 12), round(u"percent", abv(res[b]); digits = 2), " ABV")
end
```

## Which lots made the ESB

[`shares`](@ref) follows the liquor back to the lots: the fraction of each lot used for a
product. The shares of each lot among the four beers add up to what was used of it.

```@example partigyle
sort!([l => round(s; digits = 3) for (l, s) in shares(res, q, :esb)]; by = first)
```

## Blending to a target

The blend fractions can be solved for targets, e.g. the original gravities of the ESB and
the Pale Ale (see [Targets and solving](../guide/solving.md)):

```@example partigyle
sol = solve!(q, :esb => original_gravity => 1.059u"sg", :pale_ale => original_gravity => 1.047u"sg";
             vary = [Setting(:bright2 => :esb, :amount), Setting(:bright3 => :pale_ale, :amount)])
```

## As BeerJSON recipes

BeerJSON recipes are linear, so the quiver exports as one recipe per beer, each with its
shares of the lots (see [Provenance and export](@ref)):

```@example partigyle
[r.name => quantity(r.batch_size) for r in recipes(brew(q), q; products = collect(beers))]
```
