# Provenance and export

```@setup prov
using BeerJSON
using BrewQuiver; include(joinpath(pkgdir(BrewQuiver), "docs", "quivers.jl"))
q = single_batch()
res = brew(q)
```

## Shares and attribution

[`shares`](@ref)`(res, q, product)` gives the share of each lot (ingredient or water) used
for a product:

```@example prov
shares(res, q, :bottles)
```

In a single batch everything goes to the one product, so all the shares are 1; in a
parti-gyle they split (see [A parti-gyle](@ref)).

[`attribution`](@ref)`(res, q, product)` gives the share of every node: the fraction of
its contents that goes into making the product, following the liquor, with what is left
behind (spent grain, trub, yeast cake) allocated to the products it serves.

```@example prov
attribution(res, q, :bottles)
```

In a parti-gyle, the shares of each lot among the beers add up to what was used of it,
which is how a quiver turns into one recipe per beer.

## BeerJSON recipes

BeerJSON recipes are linear, so a quiver is exported as **one recipe per product**,
holding the shares of its lots: [`recipe`](@ref)`(res, q, product)`, [`recipes`](@ref)`(res,
q)` for all the products, and `writejson(path, res, q)` for a BeerJSON document.

```@example prov
r = recipe(res, q, :bottles; name = "Bitter", author = "BrewQuiver")
(r.name, quantity(r.batch_size), quantity(r.original_gravity))
```

```@example prov
path = writejson(tempname() * ".json", res, q; author = "BrewQuiver")
length(readjson(BeerJSONParser, path).beerjson.recipes)
```

The recipe has the mash steps, the boil (with its hop stand), the fermentation steps, the
additions with their timing, the water and the efficiency of the brew
([`brewhouse_efficiency`](@ref)). A recipe exported from a quiver and imported back (with
the equipment of its kettle) brews to the same wort and beer.
