# BeerJSON interoperability, with the sample documents of BeerJSON.jl

using BeerJSON: BeerJSON, readjson, BeerJSONParser, CultureInformation, quantity
using Logging: NullLogger, with_logger

const SAMPLES = joinpath(pkgdir(BeerJSON), "test", "samples")
document(path...) = readjson(BeerJSONParser, joinpath(SAMPLES, path...)).beerjson
recipe(path...) = only(document(path...).recipes)
quietly(f) = with_logger(f, NullLogger())

@testset "BeerJSON" begin

@testset "Ingredients" begin
    kolsh = recipe("converted", "Kolsh.json")
    f = Fermentable(kolsh.ingredients.fermentable_additions[1])
    @test f.name == "Pilsner (2 Row) Ger" && f.kind === :grain
    potential = quantity(kolsh.ingredients.fermentable_additions[1].yield.potential)
    @test f.yield ≈ ustrip(u"percent", yield_from_potential(potential)) / 100
    @test f.color ≈ uconvert(u"SRM", 2.0u"°L")
    @test f.moisture == 0.04
    @test Fermentable(kolsh.ingredients.fermentable_additions[1]; moisture = 0).moisture == 0

    generic = recipe("generic", "recipes.json")
    @test Fermentable(generic.ingredients.fermentable_additions[1]).yield ≈ 0.78   # fine grind

    # potentials such as 1038 sg are read as 1.038 sg
    saison = recipe("real", "BrettDosedKegsSaison.json")
    @test_logs (:warn, r"reading the potential 1038.0 sg as 1.038 sg") Fermentable(
        saison.ingredients.fermentable_additions[1])

    honey = quietly(() -> Fermentable(recipe("real", "MedievalAle.json").ingredients.fermentable_additions[1]))
    @test honey.kind === :honey && honey.moisture == 0

    h = Hop(kolsh.ingredients.hop_additions[1])
    @test h.name == "Hallertauer" && h.alpha ≈ 0.048 && h.form === :pellet
    @test Hop(saison.ingredients.hop_additions[1]).form === :pellet           # no form given
    @test Hop(kolsh.ingredients.hop_additions[1]; form = :leaf).form === :leaf

    @test Culture(kolsh.ingredients.culture_additions[1]).attenuation ≈ 0.75
    nameless = generic.ingredients.culture_additions[1]                       # no attenuation
    @test_throws ArgumentError Culture(nameless)
    @test Culture(nameless; attenuation = 70u"percent").attenuation ≈ 0.7
    info = CultureInformation{Int64, Float64}(name = "US-05", type = "ale", form = "dry",
        attenuation_range = (minimum = (unit = "%", value = 78), maximum = (unit = "%", value = 82)))
    @test Culture(info).attenuation ≈ 0.8
end

@testset "Quiver of a recipe" begin
    r = recipe("converted", "Kolsh.json")
    q = quietly(() -> Quiver(r))
    res = brew(q)

    # one lot per ingredient, with a transfer per addition
    @test haskey(q, :pilsner_2_row_ger) && haskey(q, :vienna_malt) && haskey(q, :hallertauer)
    @test length(q[:hallertauer => :kettle]) == 2
    @test [a.timing for a in q[:hallertauer => :kettle]] ==
          [Remaining(60u"minute"), Remaining(20u"minute")]
    @test only(solids(q[:hallertauer].initial)).amount ≈ (33.2677 + 16.6339) * u"g" rtol = 1e-4

    # the mash steps: the saccharification and the mash out, then a batch sparge
    @test vessels(q)[:mashtun] == [:mash, :mash_1, :mash_2, :grain_bed_1]
    @test q[:mash => :mash_1][1].temperature ≈ uconvert(u"°C", 150u"°F") rtol = 1e-3
    @test q[:mash_1 => :mash_2][1].temperature ≈ uconvert(u"°C", 168u"°F") rtol = 1e-3
    @test volume(q[:strike_water].initial) ≈ 33.0188u"L" rtol = 1e-4
    @test vessels(q)[:kettle] == [:kettle, :wort, :chilled]
    @test conserved(res, q)

    # the batch size reaches the fermentor
    @test volume(res[:fermentor]) ≈ quantity(r.batch_size) rtol = 1e-6
    @test apparent_attenuation(res[:beer]) ≈ 75u"percent"

    # a recipe without sparge water: a batch sparge for the pre-boil volume, an evaporation
    # rate and a kettle loss for the batch size
    for file in (("converted", "Londonpride.json"), ("converted", "RRSummerBitter.json"),
                 ("real", "CheaterHops.json"), ("generic", "recipes.json"))
        r = recipe(file...)
        q = quietly(() -> Quiver(r))
        res = brew(q)
        @test volume(res[:kettle]) ≈ quantity(r.boil.pre_boil_size) rtol = 1e-6
        @test volume(res[:fermentor]) ≈ quantity(r.batch_size) rtol = 1e-6
        @test conserved(res, q)

        # with the brewhouse efficiency of the recipe
        q = quietly(() -> Quiver(r; calibration = BrewhouseEfficiency()))
        res = brew(q)
        @test brewhouse_efficiency(res, q) ≈ ustrip(quantity(r.efficiency.brewhouse)) / 100 rtol = 1e-6
        @test volume(res[:fermentor]) ≈ quantity(r.batch_size) rtol = 1e-6
        @test conserved(res, q)
    end

    # the gravities of the recipes that give them
    for (file, og) in ((("real", "BrettDosedKegsSaison.json"), 1.046u"sg"),
                       (("real", "MedievalAle.json"), 1.059u"sg"))
        r = recipe(file...)
        res = brew(quietly(() -> Quiver(r; calibration = BrewhouseEfficiency())))
        @test gravity(res[:fermentor]) ≈ og atol = 6e-3u"sg"
    end

    # the cultures take the attenuation of the original and final gravities of the recipe
    saison = recipe("real", "BrettDosedKegsSaison.json")
    res = brew(quietly(() -> Quiver(saison)))
    @test apparent_attenuation(res[:beer]) ≈ apparent_attenuation(1.046u"sg", 1.010u"sg")

    # dry hops given as boil additions longer than the boil
    punk = recipe("converted", "punk-ipa-2010-current.json")
    q = @test_logs (:warn, r"cultures without attenuation") (:warn, r"Chinook.*dry hop") match_mode = :any Quiver(punk)
    res = brew(q)
    dry = [s for s in solids(res[:fermentor]) if s isa Portion{Hop}]
    @test length(dry) == 6 && all(s -> s.timing == Remaining(10080u"minute"), dry)
    @test any(s -> s isa Portion{Hop} && s.timing == Remaining(0u"minute"), solids(res[:kettle]))
end

@testset "Equipment" begin
    r = recipe("converted", "RRSummerBitter.json")
    large, small = document("real", "EquipmentSet.json").equipments
    q = quietly(() -> Quiver(r; equipment = large))
    res = brew(q)
    @test volume(leftover(res, :chilled)) ≈ 7.57u"L" rtol = 1e-3     # the kettle loss
    @test volume(res[:kettle]) ≈ quantity(r.boil.pre_boil_size) rtol = 1e-6
    q = quietly(() -> Quiver(r; equipment = small))
    @test q[:kettle => :wort][1].evaporation ≈ 2.04u"L/hr" rtol = 1e-3
    @test q[:mash_2 => :kettle][1].retain ≈ 0.95u"L" rtol = 1e-3     # the dead space
    @test conserved(brew(q), q)
end

@testset "Unsupported" begin
    @test_throws ArgumentError quietly(() -> Quiver(recipe("real", "SourMash.json")))
    @test_throws ArgumentError quietly(() -> Quiver(recipe("real", "IrishMoss.json")))
    @test_logs (:warn, r"in the kettle, for a pre-boil volume") match_mode = :any Quiver(
        recipe("real", "SpargeAcidification.json"))
end

end
