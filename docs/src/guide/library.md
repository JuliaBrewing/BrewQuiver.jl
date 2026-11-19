# Ingredient library

```@setup lib
using BrewQuiver; include(joinpath(pkgdir(BrewQuiver), "docs", "quivers.jl"))
q = single_batch()
```

A [`Library`](@ref) holds ingredients by name, with what is in stock. It is loaded from the
fermentable, hop and culture records of BeerJSON files (with their inventory), or built
with `push!`:

```@example lib
lib = Library()
push!(lib, pale; stock = 10u"kg")
push!(lib, crystal; stock = 0.2u"kg")
push!(lib, goldings; stock = 100u"g")
push!(lib, ale; stock = 2)
push!(lib, dextrose; stock = 1u"kg")
```

Ingredients are found by name, or by part of it:

```@example lib
(lib["Pale ale malt"], lookup(lib, "crystal"))
```

## Inventory

```@example lib
res = brew(q)
requirements(res, q)          # what the brew uses of each ingredient
```

```@example lib
shortages(lib, res, q)        # what the stock lacks for it
```

[`consume!`](@ref) takes what the brew uses from the stock (warning about what is short),
and [`stock!`](@ref stock) sets it:

```@example lib
stock!(lib, "Crystal 60", 1u"kg")
consume!(lib, res, q)
stock(lib, "Pale ale malt")
```

## Files

```julia
lib = Library("my_ingredients.json", "more.json")   # BeerJSON documents
lib = readjson(Library, "my_ingredients.json")
merge!(lib, other)
writejson("my_ingredients.json", lib)
```

`Quiver(recipe; library = lib)` completes the additions of a recipe with the records of the
library of the same name: the moisture of fermentables, and the attenuation of cultures.
