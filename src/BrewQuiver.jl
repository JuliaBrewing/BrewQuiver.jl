"""
    BrewQuiver

The engine of the BrewQuiver brewing software: the brewing process as a *quiver*, a
directed acyclic graph whose nodes are processes (mash, boil, fermentation, ...) and whose
edges are transfers of liquors (water, wort, beer) between them. Unlike a linear recipe,
a quiver can split and merge streams, as in parti-gyle brewing or blending.

The state of each stream is a [`Liquor`](@ref), holding conserved quantities, so that
mixing and splitting are exact; its gravity, alcohol, bitterness and color are computed
with [BrewingFormulas.jl](https://github.com/JuliaBrewing/BrewingFormulas.jl).

```julia
using Unitful, UnitfulBrewing, BrewingFormulas, BrewQuiver

pale = Fermentable("Pale ale malt"; yield = 80u"percent", color = 3u"°L")
q = Quiver()
add!(q, :water, Source(water(40u"L")))
add!(q, :mash, MashTun(grains = [pale => 5u"kg"], sparge = [12u"L"]))
...
res = brew(q)
```
"""
module BrewQuiver

using Unitful
using Unitful: @u_str
using UnitfulBrewing
using BrewingFormulas
using BrewingFormulas: ABVModel, ColorModel, AbstractPrimingSugar
using Graphs: Graphs, DiGraph, has_path, rem_edge!, rem_vertex!
using MetaGraphsNext: MetaGraph, code_for, label_for, edge_labels, inneighbor_labels,
    outneighbor_labels

include("liquor.jl")
include("ingredients.jl")
include("processes.jl")
include("quiver.jl")
include("brew.jl")
include("show.jl")

# liquors
export Liquor, water, wort, mass, volume, gravity, original_gravity, carbonation
export with_temperature

# ingredients
export AbstractIngredient, Fermentable, Hop, Culture, Addition, HOP_FORM_FACTORS

# processes
export AbstractProcess, inports, outports, process
export Source, Mix, MashTun, Boil, Ferment, Package, runnings, grain_mass, priming_mass

# quiver
export Quiver, Transfer, add!, connect!, disconnect!, remove!, nodes, transfers
export predecessors, successors, descendants

# brewing
export brew, rebrew!, BrewResult, NodeResult, products

end # module
