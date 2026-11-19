# Files of quivers

```@setup files
using BrewQuiver; include(joinpath(pkgdir(BrewQuiver), "docs", "quivers.jl"))
```

A quiver is saved with [`writejson`](@ref) and loaded with [`readjson`](@ref) (the
functions of BeerJSON.jl, extended), as a [JSON Graph Format](https://jsongraphformat.info)
(JGF) document, with its ingredients as BeerJSON catalogue records:

```julia
writejson("bitter.quiver.json", q; results = brew(q))
q = readjson(Quiver, "bitter.quiver.json")
```

Both also take an `IO` instead of a path. The file keeps the whole quiver, the order of
construction of its nodes, its equipment and the [`nodeview`](@ref)s, so that a quiver read
back brews exactly as the original.

## Values for other readers

With `results = brew(q)`, each node also gets the values **computed** by the brew (volume,
gravity, original gravity, ABV, IBU, color, carbonation, temperature, and the mash pH of
mashes), and the graph the names of the models used. Other readers of JGF can show them
without a brewing engine. `readjson` **ignores them**: they are computed again by
[`brew`](@ref).

## Node views

[`nodeview`](@ref)`(q, label)` is a `Dict{String, Any}` of free data for interfaces (a
position, a color, a collapsed state, ...), which BrewQuiver does not use but keeps in the
files, and keeps when the contents of the node are replaced:

```@example files
q = single_batch()
nodeview(q, :mash)["position"] = [0, 1]
path = writejson(tempname() * ".json", q)
nodeview(readjson(Quiver, path), :mash)
```

## The format

A small quiver, a kettle of wort with its hops boiled:

```@example files
q = Quiver()
add!(q, :wort_in, wort(20u"L", 1.045u"sg"; temperature = 100u"°C"))
add!(q, :goldings, goldings => 30u"g")
add!(q, :kettle, :hopped; vessel = :kettle)
connect!(q, :wort_in => :kettle)
connect!(q, :goldings => :kettle, Transfer(; remaining = 60u"minute"))
connect!(q, :kettle => :hopped, Boil(time = 60u"minute", evaporation = 3u"L/hr"))
nodeview(q, :kettle)["position"] = [1, 0]
io = IOBuffer()
writejson(io, q; results = brew(q))
print(String(take!(io)))
```

The document is a JGF graph:

- `"graph"`: `"type": "brewquiver"`, `"directed": true`, and
  - `"metadata"`:
    - `"format": "BrewQuiver"`, `"format_version"` (1; a newer version is refused by older
      readers), `"brewquiver_version"`;
    - `"ingredients"`: `"fermentables"`, `"hop_varieties"` and `"cultures"`, as BeerJSON
      catalogue records (`FermentableType`, `VarietyInformation`, `CultureInformation`),
      by name. The buffering of a fermentable is an extra property, `"buffering"`. Two
      different ingredients cannot have the same name in a file.
    - `"equipment"`: the vessels by name;
    - `"computed"` (optional): the `"models"` of the brew.
  - `"nodes"`: by label, each with a `"label"` and a `"metadata"` holding
    - `"rank"`: the order of construction;
    - `"vessel"`, if any;
    - `"initial"`: the initial contents, omitted for the stages that start empty;
    - `"view"`: the node view, if not empty;
    - `"computed"` (optional): the values of the brew.
  - `"edges"`: one per arrow, in order, with `"source"`, `"target"`, `"relation"` (the
    type of the arrow) and `"metadata": {"arrow": ...}`.

Quantities are written as in BeerJSON, `{"unit": ..., "value": ...}`, in the units `kg`,
`g`, `mg`, `l`, `ml`, `min`, `hr`, `day`, `C`, `l/kg`, `l/hr`, `1/hr`, `l/min`, `vols`,
`SRM`, `mg/l`, `g/ml`, `sg`, `IBU` and `%`. The other values (arrows, timings, liquors,
minerals, solids, vessels, priming sugars) are objects of their fields with their
`"type"`; a [`Portion`](@ref) refers to its ingredient by name. New arrow types are
written once registered; see [Extending BrewQuiver](@ref).

A JSON Schema of the format is planned.
