"""
    BrewQuiver

The engine of the BrewQuiver brewing software: the brewing process as a *quiver*, a
directed acyclic multigraph whose nodes are the [`Contents`](@ref) of vessels at the stages
of the brewing (the lots of ingredients, the water, the mash, the wort in the kettle, the
beer in the fermentor, ...) and whose arrows are the processes between them: transfers,
drains and transformations (mash rests, boils, fermentations, ...). Streams can be split
and merged, as in parti-gyle brewing or blending.

The state of each node holds conserved quantities (a [`Liquor`](@ref) and solids), so that
mixing and splitting are exact; gravity, alcohol, bitterness and color are computed with
[BrewingFormulas.jl](https://github.com/JuliaBrewing/BrewingFormulas.jl).

```julia
using Unitful, UnitfulBrewing, BrewingFormulas, BrewQuiver

pale = Fermentable("Pale ale malt"; yield = 80u"percent", color = 3u"°L")
q = Quiver()
add!(q, :pale, pale => 5u"kg")
add!(q, :strike_water, water(16u"L"; temperature = 75u"°C"))
add!(q, :mash, :rested; vessel = :mashtun)
connect!(q, [:strike_water, :pale] => :mash)
connect!(q, :mash => :rested, MashRest(temperature = 67u"°C"))
...
res = brew(q)
```
"""
module BrewQuiver

using Unitful
using Unitful: @u_str, dimension, unit
using UnitfulBrewing: DensityConcentration
using UnitfulBrewing
using BrewingFormulas
using BrewingFormulas: ABVModel, ColorModel, AbstractPrimingSugar, co2_yield, Tinseth, Rager
using Graphs: Graphs, DiGraph, has_path, rem_edge!, rem_vertex!
import BeerJSON
import BeerJSON: readjson, writejson
import JSON
using MetaGraphsNext: MetaGraph, code_for, label_for, edge_labels, inneighbor_labels,
    outneighbor_labels

include("liquor.jl")
include("ingredients.jl")
include("contents.jl")
include("arrows.jl")
include("vessels.jl")
include("quiver.jl")
include("brew.jl")
include("water.jl")
include("provenance.jl")
include("beerjson.jl")
include("export.jl")
include("library.jl")
include("files.jl")
include("timeline.jl")
include("solve.jl")
include("show.jl")

# liquors
export Liquor, water, wort, mass, volume, gravity, original_gravity, carbonation
export Minerals, WaterProfile, profile
export with_temperature

# ingredients
export AbstractIngredient, Fermentable, Hop, Culture, Salt, Acid, HOP_FORM_FACTORS

# contents
export Contents, liquor, solids, total_mass, grist
export AbstractSolid, Portion, Residue, HopMatter, YeastCake
export AbstractTiming, Remaining, At

# arrows
export AbstractArrow, AbstractTransformation, transform
export Transfer, Drain, MashRest, Boil, Chill, Ferment, Prime, Carbonate, priming_mass

# quiver
export Quiver, Node, add!, connect!, disconnect!, remove!, nodes, arrows, vessel, vessels
export Vessel, equip!, equipment, overfilled
export predecessors, successors, descendants, nodeview

# brewing
export brew, rebrew!, BrewResult, NodeResult, ArrowResult, leftover, leftovers, released
export products

# BeerJSON
export AbstractCalibration, NoCalibration, BrewhouseEfficiency, brewhouse_efficiency
export recipe, recipes, readjson, writejson, write_beerjson

# ingredient library and inventory
export Library, stock, stock!, lookup, requirements, shortages, consume!

# provenance
export attribution, shares

# timeline
export duration, timeline, Timeline, Interval, makespan, overlaps, vesselchart

# targets and solving
export AbstractParameter, Amount, Setting, Target, Solution, solve!

end # module
