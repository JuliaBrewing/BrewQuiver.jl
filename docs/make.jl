using Documenter
using BrewQuiver, Unitful, UnitfulBrewing, BrewingFormulas, BeerJSON

DocMeta.setdocmeta!(BrewQuiver, :DocTestSetup,
                    :(using BrewQuiver, Unitful, UnitfulBrewing, BrewingFormulas); recursive = true)

makedocs(;
    modules = [BrewQuiver],
    sitename = "BrewQuiver.jl",
    authors = "JuliaBrewing contributors",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://juliabrewing.github.io/BrewQuiver.jl",
        edit_link = "main",
        size_threshold = 400 * 1024,
        size_threshold_warn = 200 * 1024,
    ),
    pages = [
        "Home" => "index.md",
        "Concepts" => "concepts.md",
        "Tutorials" => [
            "A single batch" => "tutorials/single_batch.md",
            "A parti-gyle" => "tutorials/partigyle.md",
            "A BeerJSON recipe" => "tutorials/beerjson.md",
        ],
        "Guide" => [
            "Equipment" => "guide/equipment.md",
            "Mashes, decoctions, stands and dry hops" => "guide/techniques.md",
            "Water chemistry" => "guide/water.md",
            "Timeline" => "guide/timeline.md",
            "Targets and solving" => "guide/solving.md",
            "Provenance and export" => "guide/provenance.md",
            "Ingredient library" => "guide/library.md",
            "Files of quivers" => "guide/files.md",
            "Extending BrewQuiver" => "guide/extending.md",
        ],
        "API reference" => "api.md",
        "References" => "references.md",
    ],
    checkdocs = :exports,
)

deploydocs(;
    repo = "github.com/JuliaBrewing/BrewQuiver.jl.git",
    devbranch = "main",
    push_preview = true,
)
