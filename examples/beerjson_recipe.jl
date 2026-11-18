# A BeerJSON recipe as a quiver: the RR Summer Bitter from the samples of BeerJSON.jl, built
# with the water it does not give (a batch sparge for its pre-boil volume) and calibrated to
# its brewhouse efficiency, then brewed with and without that calibration.
#
# Run with `julia --project=. examples/beerjson_recipe.jl` from the package folder.

using Unitful, UnitfulBrewing, BrewingFormulas, BeerJSON, BrewQuiver

file = joinpath(pkgdir(BeerJSON), "test", "samples", "converted", "RRSummerBitter.json")
recipe = only(readjson(BeerJSONParser, file).beerjson.recipes)

q = Quiver(recipe; calibration = BrewhouseEfficiency())
display(q); println("\n")
res = brew(q)
display(res); println("\n")

println("Sparge water: ", round(u"L", volume(q[:sparge_water_1].initial); digits = 2))
println("Brewhouse efficiency: ", round(100brewhouse_efficiency(res, q); digits = 1), "% (",
        quantity(recipe.efficiency.brewhouse), " in the recipe)")
println("The beer: ", res[:beer])

# the same recipe, with the efficiency that follows from the processes
res2 = brew(Quiver(recipe))
println("\nWithout calibration: ", round(100brewhouse_efficiency(res2, Quiver(recipe)); digits = 1),
        "% efficiency")
println("The beer: ", res2[:beer])
