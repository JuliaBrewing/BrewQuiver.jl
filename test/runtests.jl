using Test
using Unitful
using UnitfulBrewing
using BrewingFormulas
using BrewQuiver
using BeerJSON: BeerJSON
using Logging: NullLogger, with_logger

const pale = Fermentable("Pale ale malt"; yield = 80u"percent", color = 3u"°L")
const crystal = Fermentable("Crystal 60"; yield = 74u"percent", color = 60u"°L")
const invert = Fermentable("Invert sugar"; kind = :sugar, yield = 100u"percent",
                           color = 1u"SRM", moisture = 0)
const dextrose = Fermentable("Corn sugar"; kind = :sugar, yield = 100u"percent",
                             color = 0u"SRM", moisture = 0)
const goldings = Hop("East Kent Goldings"; alpha = 5u"percent")
const ale = Culture("English ale"; attenuation = 75u"percent")

# extract equivalent: conserved by fermentation (2.0665 g of extract per g of ethanol)
extract_equivalent(l::Liquor) = l.extract + 2.0665 * l.alcohol
extract_equivalent(c::Contents) = extract_equivalent(liquor(c))
# the extract a fermentable gives with the given conversion
extract_of(f::Fermentable, m, conversion = 1.0) =
    conversion * potential_extract(m, f.yield; moisture = f.moisture)

# conservation over the whole quiver: the initial contents are all left over somewhere
# (the products included), except what the arrows released
function conserved(res, q)
    initial = [q[n].initial for n in nodes(q)]
    left = collect(values(leftovers(res)))
    r = released(res)
    return sum(total_mass, initial) ≈ sum(total_mass, left) + r.water + r.co2
end

# an arrow unknown to the files of quivers
struct Whirlpool <: BrewQuiver.AbstractTransformation end

@testset "BrewQuiver" begin

@testset "Liquor" begin
    w = water(20u"L")
    @test volume(w) ≈ 20u"L"
    @test gravity(w) ≈ 1.0u"sg"
    @test iszero(zero(Liquor))
    @test volume(zero(Liquor)) == 0u"L"

    a = wort(20u"L", 1.050u"sg")
    @test volume(a) ≈ 20u"L"
    @test gravity(a) ≈ 1.050u"sg"
    @test original_gravity(a) ≈ 1.050u"sg"
    @test a.extract ≈ extract_mass(20u"L", 1.050u"sg")
    @test abv(a) == 0u"percent"

    # splitting and mixing
    @test volume(0.25a) ≈ 5u"L"
    @test gravity(0.25a) ≈ 1.050u"sg"
    @test 0.25a + 0.75a ≈ a
    @test_throws DomainError (-1) * a

    # mixing conserves masses; the gravity follows from the total extract
    b = wort(10u"L", 1.080u"sg"; temperature = 80u"°C")
    m = a + b
    @test m.extract ≈ a.extract + b.extract
    @test gravity(m) ≈ specific_gravity(gravity_from_extract(m.extract, volume(m)))
    @test 1.050u"sg" < gravity(m) < 1.080u"sg"
    @test volume(m) ≈ 30u"L" rtol = 1e-3       # volumes are nearly additive
    @test 20u"°C" < m.temperature < 80u"°C"

    # water and extract → volume, as in BrewingFormulas
    l = Liquor(; water = 20u"L", extract = 2.5u"kg")
    @test volume(l) ≈ solution_volume(20u"L", 2.5u"kg")
end

@testset "Ingredients" begin
    @test pale.yield == 0.8
    @test pale.color ≈ uconvert(u"SRM", 3.0u"°L")
    @test Fermentable("x"; potential = 1.037u"sg").yield ≈ 0.8 rtol = 1e-3
    @test_throws ArgumentError Fermentable("x"; yield = 0.8, potential = 1.037u"sg")
    @test Portion(goldings, 30u"g").amount ≈ 0.03u"kg"
    @test Portion(ale, 2).amount == 2.0
    @test_throws DomainError Portion(ale, -1)
    @test_throws ArgumentError Portion(goldings, 1u"L")
end

@testset "Contents" begin
    w = Contents(water(10u"L"))
    malt = Contents(pale => 4u"kg")
    hops = Contents(goldings => 30u"g")
    @test iszero(zero(Contents))
    @test liquor(w) == water(10u"L")
    @test isempty(solids(w))
    @test solids(malt) == [Portion(pale, 4u"kg")]

    # mixing merges equal portions; scaling scales everything
    c = w + malt + Contents(pale => 1u"kg") + hops
    @test length(solids(c)) == 2
    @test solids(c)[1].amount ≈ 5u"kg"
    @test 0.4c + 0.6c ≈ c
    @test volume(0.5c) ≈ 5u"L"
    @test total_mass(c) ≈ total_mass(water(10u"L")) + 5u"kg" + 30u"g"
    @test grist(c) ≈ 5u"kg"
    @test grist(Contents(invert => 1u"kg")) == 0u"kg"          # sugars are not grain
    @test iszero(0 * c)

    # timings: portions arriving at different times are kept apart
    late = BrewQuiver.with_timing(hops, Remaining(10u"minute"))
    @test solids(late)[1].timing == Remaining(10u"minute")
    @test length(solids(hops + late)) == 2
    @test !(hops ≈ late)
    @test BrewQuiver.duration_in(nothing, 60u"minute") == 60u"minute"
    @test BrewQuiver.duration_in(Remaining(10u"minute"), 60u"minute") == 10u"minute"
    @test BrewQuiver.duration_in(Remaining(90u"minute"), 60u"minute") == 60u"minute"
    @test BrewQuiver.duration_in(At(15u"minute"), 60u"minute") == 45u"minute"
    @test BrewQuiver.duration_in(At(90u"minute"), 60u"minute") == 0u"minute"

    # derived quantities of the liquor
    x = Contents(wort(20u"L", 1.050u"sg"), [Portion(goldings, 10u"g")])
    @test gravity(x) ≈ 1.050u"sg"
    @test srm(x) == srm(liquor(x))
    @test abv(Balling(), x) == abv(Balling(), liquor(x))
end

@testset "Arrows" begin
    models = DEFAULT_MODELS
    @test Transfer().amount === nothing
    @test Transfer(25u"percent").amount == 0.25
    @test Transfer(2u"L").amount == 2u"L"
    @test Transfer(30u"g"; at = 5u"minute").timing == At(5u"minute")
    @test_throws ArgumentError Transfer(30u"g"; at = 5u"minute", remaining = 5u"minute")
    @test_throws DomainError Transfer(1.5)
    @test_throws ArgumentError Transfer("all")

    # a mash rest: the grain gives its extract, moisture and color, leaving spent grain
    mash = Contents(water(15u"L")) + Contents(pale => 4u"kg") + Contents(invert => 1u"kg")
    rested, rel = transform(MashRest(conversion = 90u"percent"), mash, models)
    @test liquor(rested).extract ≈ extract_of(pale, 4u"kg", 0.9) + 1u"kg"
    @test liquor(rested).water ≈ liquor(mash).water + 4u"kg" * pale.moisture
    @test liquor(rested).color ≈ ustrip(u"lb", 4u"kg") * ustrip(u"°L", pale.color) +
                                 ustrip(u"lb", 1u"kg") * ustrip(u"°L", invert.color)
    @test grist(rested) ≈ 4u"kg"
    @test total_mass(rested) ≈ total_mass(mash)
    @test rel == (water = 0u"kg", co2 = 0u"kg")
    @test liquor(rested).temperature == 67u"°C"

    # draining leaves the grain and what it absorbs, and what the vessel retains
    drained, left = BrewQuiver._drain(Drain(absorption = 1u"L/kg", retain = 1u"L"), rested,
                                      models.gravity)
    @test volume(left) ≈ 5u"L"
    @test isempty(solids(drained)) && solids(left) == solids(rested)
    @test drained + left ≈ rested
    @test_throws ArgumentError BrewQuiver._drain(Drain(absorption = 5u"L/kg"), rested,
                                                 models.gravity)

    # a boil: evaporation, and each hop isomerizing for its own time
    w = Contents(wort(25u"L", 1.045u"sg"))
    early = BrewQuiver.with_timing(Contents(goldings => 30u"g"), Remaining(60u"minute"))
    late = BrewQuiver.with_timing(Contents(goldings => 30u"g"), At(50u"minute"))
    after(c) = transform(Boil(time = 60u"minute", evaporation = 4u"L/hr"), w + c, models)
    (b1, r1), (b2, r2), (b3, _) = after(early), after(late), after(early + late)
    @test r1.water ≈ 4u"L" * BrewingFormulas.WATER_DENSITY_20C
    @test volume(b1) ≈ 21u"L" rtol = 2e-3
    @test liquor(b3).isoalpha ≈ liquor(b1).isoalpha + liquor(b2).isoalpha
    @test liquor(b1).isoalpha > liquor(b2).isoalpha > 0u"mg"
    @test total_mass(b3) + r1.water ≈ total_mass(w + early + late)

    # chilling changes the temperature only
    hot = Contents(wort(20u"L", 1.050u"sg"; temperature = 100u"°C"), [Portion(goldings, 10u"g")])
    cold, rc = transform(Chill(temperature = 18u"°C"), hot, models)
    @test liquor(cold).temperature ≈ 18u"°C"
    @test cold ≈ with_temperature(hot, 18u"°C")
    @test rc == (water = 0u"kg", co2 = 0u"kg")

    # a fermentation needs a culture or an attenuation
    @test_throws ArgumentError transform(Ferment(), w, models)
    f, rf = transform(Ferment(attenuation = 80u"percent"), w, models)
    @test apparent_attenuation(f) ≈ 80u"percent"
    @test total_mass(f) + rf.co2 ≈ total_mass(w)
    @test only(solids(f)) isa YeastCake

    # priming and forced carbonation
    beer = Contents(liquor(f))
    s = priming_mass(beer, 2.5u"vols")
    primed, _ = transform(Prime(), beer + Contents(dextrose => s), models)
    @test carbonation(primed) ≈ 2.5u"vols"
    @test total_mass(primed) ≈ total_mass(beer) + s
    @test s ≈ priming_sugar(CornSugar(), volume(beer), 2.5u"vols", 20u"°C") rtol = 2e-2
    forced, rk = transform(Carbonate(2.5u"vols"), beer, models)
    @test carbonation(forced) ≈ 2.5u"vols"
    @test total_mass(forced) ≈ total_mass(beer) - rk.co2
end

function single_batch(; priming = 110u"g")
    q = Quiver()
    add!(q, :pale, pale => 4.5u"kg")
    add!(q, :crystal, crystal => 0.3u"kg")
    add!(q, :goldings, goldings => 50u"g")
    add!(q, :yeast, ale => 1)
    add!(q, :strike_water, water(16u"L"; temperature = 75u"°C"))
    add!(q, :sparge_water, water(14u"L"; temperature = 80u"°C"))
    add!(q, :priming_sugar, dextrose => priming)
    add!(q, :mash, :rested, :grain_bed; vessel = :mashtun)
    add!(q, :kettle, :wort, :chilled; vessel = :kettle)
    add!(q, :fermentor, :beer; vessel = :fermentor)
    add!(q, :bottling, :bottles; vessel = :bottles)
    connect!(q, [:strike_water, :pale, :crystal] => :mash)
    connect!(q, :mash => :rested, MashRest(temperature = 67u"°C"))
    connect!(q, :rested => :kettle, Drain())
    connect!(q, :rested => :grain_bed)
    connect!(q, :sparge_water => :grain_bed)
    connect!(q, :grain_bed => :kettle, Drain())
    connect!(q, :goldings => :kettle, Transfer(30u"g"; remaining = 60u"minute"))
    connect!(q, :goldings => :kettle, Transfer(20u"g"; remaining = 10u"minute"))
    connect!(q, :kettle => :wort, Boil(time = 60u"minute", evaporation = 4u"L/hr"))
    connect!(q, :wort => :chilled, Chill(temperature = 18u"°C"))
    connect!(q, :chilled => :fermentor, Drain(retain = 1u"L"))
    connect!(q, :yeast => :fermentor)
    connect!(q, :fermentor => :beer, Ferment(temperature = 20u"°C"))
    connect!(q, :priming_sugar => :bottling)
    connect!(q, :beer => :bottling, Drain(retain = 1u"L"))
    connect!(q, :bottling => :bottles, Prime())
    return q
end

@testset "Single batch" begin
    q = single_batch()
    @test nodes(q) == [:pale, :crystal, :goldings, :yeast, :strike_water, :sparge_water,
                       :priming_sugar, :mash, :rested, :grain_bed, :kettle, :wort, :chilled,
                       :fermentor, :beer, :bottling, :bottles]
    @test vessels(q)[:mashtun] == [:mash, :rested, :grain_bed]
    res = brew(q)

    # mash: the grain retains its absorption at each drain
    grain = 4.8u"kg"
    @test grist(res[:rested]) ≈ grain
    @test volume(leftover(res, :grain_bed)) ≈ grain * 1u"L/kg"
    @test only(solids(leftover(res, :grain_bed))) isa Residue
    runnings = [only(res[n => :kettle]).moved for n in (:rested, :grain_bed)]
    @test gravity(runnings[1]) > gravity(runnings[2])
    dissolved = extract_of(pale, 4.5u"kg", 0.95) + extract_of(crystal, 0.3u"kg", 0.95)
    @test liquor(res[:kettle]).extract + liquor(leftover(res, :grain_bed)).extract ≈ dissolved

    # boil: 4 L evaporated in one hour, the hops become hop matter
    @test volume(res[:kettle]) - volume(res[:wort]) ≈ 4u"L" rtol = 1e-2
    @test only(res[:kettle => :wort]).released.water ≈ 4u"L" * BrewingFormulas.WATER_DENSITY_20C
    @test 1.045u"sg" < gravity(res[:wort]) < 1.060u"sg"
    @test 15u"IBU" < ibu(res[:wort]) < 30u"IBU"
    @test only(solids(leftover(res, :chilled))) isa HopMatter
    @test volume(leftover(res, :chilled)) ≈ 1u"L"
    @test liquor(res[:wort]).temperature ≈ 100u"°C"
    @test liquor(res[:fermentor]).temperature ≈ 18u"°C"                 # chilled
    @test res[:chilled] ≈ with_temperature(res[:wort], 18u"°C")

    # fermentation: the attenuation of the culture, with Balling's relations
    wort_in = res[:fermentor]
    beer = res[:beer]
    @test original_gravity(beer) ≈ gravity(wort_in)
    @test apparent_attenuation(beer) ≈ 75u"percent"
    @test abv(beer) ≈ abv(Balling(), gravity(wort_in), gravity(beer)) rtol = 1e-6
    @test extract_equivalent(beer) ≈ extract_equivalent(wort_in)
    @test carbonation(beer) ≈ residual_co2(20u"°C") rtol = 1e-6
    @test any(s -> s isa YeastCake, solids(leftover(res, :beer)))

    # bottle conditioning with the sugar lot, and the sugar for a given level
    @test abv(res[:bottles]) > abv(beer)
    @test isempty(solids(res[:bottles]))
    racked = only(res[:beer => :bottling]).moved
    s = priming_mass(racked, 2.4u"vols")
    q2 = single_batch(priming = s)
    @test carbonation(brew(q2)[:bottles]) ≈ 2.4u"vols"
    @test products(res, q) == Dict(:bottles => res[:bottles])

    # conservation of everything, and of the extract equivalent and the color
    @test conserved(res, q)
    left = collect(values(leftovers(res)))
    # (up to the bottling: the priming sugar is fermented by molar ratios, not by Balling)
    @test sum(extract_equivalent(c) for (n, c) in leftovers(res) if n != :bottles) +
          extract_equivalent(racked) ≈ dissolved
    @test sum(c -> liquor(c).color, left) ≈
          (ustrip(u"lb", 4.5u"kg") * 3 + ustrip(u"lb", 0.3u"kg") * 60) rtol = 1e-12

    # other models
    @test ibu(brew(q; models = (bitterness = Rager(),))[:wort]) != ibu(res[:wort])

    # the display groups the nodes: the lots, then the stages of each vessel
    shown = sprint(show, MIME"text/plain"(), q)
    @test occursin("Quiver with 17 nodes and 18 arrows", shown)
    @test occursin("Transfer(all) → :mash", shown)                      # the only arrow
    @test occursin("Transfer(rest) → :grain_bed", shown)                # beside a drain
    @test occursin("Transfer(30.0 g, 60.0 min remaining) → :kettle", shown)
    @test occursin("Chill(18.0 °C) → :chilled", shown)
    heads = ["\n  lots\n", "\n  [mashtun]\n", "\n  [kettle]\n", "\n  [fermentor]\n", "\n  [bottles]\n"]
    at = [first(findfirst(h, shown)) for h in heads]
    @test issorted(at)
    shown = sprint(show, MIME"text/plain"(), res)
    @test all(h -> occursin(h, shown), heads)
    @test occursin("left: 4.8 L", shown)
end

@testset "Quiver construction" begin
    q = single_batch()
    @test_throws ArgumentError add!(q, :kettle)                         # already there
    @test_throws ArgumentError add!(q, :x, 3u"kg")                       # not contents
    @test_throws ArgumentError connect!(q, :bottles => :strike_water)    # a cycle
    @test_throws ArgumentError connect!(q, :kettle => :kettle)
    @test_throws ArgumentError connect!(q, :nowhere => :kettle)
    @test_throws ArgumentError connect!(q, :kettle => :fermentor)       # beside a boil
    @test_throws ArgumentError connect!(q, :rested => :wort, Boil())     # beside transfers
    @test_throws ArgumentError connect!(q, :rested => :wort, Drain())    # a second drain
    @test_throws ArgumentError q[:nowhere] = water(1u"L")
    @test_throws ArgumentError q[:wort => :beer] = Transfer()
    @test successors(q, :rested) == [:kettle, :grain_bed] ||
          successors(q, :rested) == [:grain_bed, :kettle]
    @test Set(predecessors(q, :kettle)) == Set([:rested, :grain_bed, :goldings])
    @test descendants(q, :beer) == [:beer, :bottling, :bottles]
    @test length(arrows(q)) == 18
    @test length(q[:goldings => :kettle]) == 2
    @test vessel(q, :wort) == :kettle && vessel(q, :pale) === nothing

    disconnect!(q, :bottling => :bottles)
    @test isempty(successors(q, :bottling))
    remove!(q, :bottles)
    @test !haskey(q, :bottles)

    # taking more than available
    q2 = Quiver()
    add!(q2, :w, water(10u"L"))
    add!(q2, :a, :b)
    connect!(q2, :w => :a, Transfer(6u"L"))
    connect!(q2, :w => :b, Transfer(6u"L"))
    @test_throws ArgumentError brew(q2)

    # amounts, the rest, and leftovers
    q3 = Quiver()
    add!(q3, :w, water(10u"L"))
    add!(q3, :a, :b, :c)
    connect!(q3, :w => :a, Transfer(4u"L"))
    connect!(q3, :w => :b, Transfer(0.1))
    connect!(q3, :w => :c)
    r3 = brew(q3)
    @test volume(r3[:a]) ≈ 4u"L"
    @test volume(r3[:b]) ≈ 1u"L"
    @test volume(r3[:c]) ≈ 5u"L"
    @test iszero(leftover(r3, :w))
    disconnect!(q3, :w => :c)
    @test volume(leftover(brew(q3), :w)) ≈ 5u"L"

    # transfers by mass, from a lot
    q4 = Quiver()
    add!(q4, :hops, goldings => 100u"g")
    add!(q4, :a, :b)
    connect!(q4, :hops => :a, Transfer(30u"g"))
    connect!(q4, :hops => :b, Transfer(50u"percent"))
    r4 = brew(q4)
    @test only(solids(r4[:a])).amount ≈ 30u"g"
    @test only(solids(r4[:b])).amount ≈ 50u"g"
    @test only(solids(leftover(r4, :hops))).amount ≈ 20u"g"

    # transfers of volumes from an empty node take nothing
    q5 = Quiver()
    add!(q5, :w, :a, :b)
    connect!(q5, :w => :a, Transfer(1u"L"))
    connect!(q5, :w => :b, Transfer(1u"L"))
    r5 = brew(q5)
    @test iszero(r5[:a]) && iszero(r5[:b])

    # the order of construction is kept after removing a node
    q6 = Quiver()
    add!(q6, :w, water(10u"L"))
    for n in (:b, :c, :d, :e)
        add!(q6, n)
        connect!(q6, :w => n, Transfer(0.25))
    end
    remove!(q6, :b)
    @test nodes(q6) == [:w, :c, :d, :e]
    add!(q6, :b)
    @test nodes(q6) == [:w, :c, :d, :e, :b]
    q6[:w] = water(20u"L")                          # replacing keeps the place
    @test nodes(q6) == [:w, :c, :d, :e, :b]
end

@testset "Rebrew" begin
    q = single_batch()
    res = brew(q)
    q[:fermentor => :beer] = Ferment(attenuation = 80u"percent")
    rebrew!(res, q, :fermentor)
    fresh = brew(q)
    for n in nodes(q)
        @test res[n] ≈ fresh[n]
    end
    @test apparent_attenuation(res[:beer]) ≈ 80u"percent"

    # changes of the structure: a rebrew must match a fresh brew
    function same(res, q)
        fresh = brew(q)
        Set(keys(res.nodes)) == Set(keys(fresh.nodes)) || return false
        Set(keys(res.arrows)) == Set(keys(fresh.arrows)) || return false
        res.order == fresh.order || return false
        return all(res[n] ≈ fresh[n] && leftover(res, n) ≈ leftover(fresh, n) for n in nodes(q))
    end
    q = Quiver()
    add!(q, :w, water(10u"L"))
    add!(q, :a, :b, :c, :blend)
    connect!(q, :w => :a, Transfer(2u"L"))
    connect!(q, :w => :b, Transfer(3u"L"))
    connect!(q, :w => :c)
    connect!(q, [:a, :c] => :blend)
    res = brew(q)
    @test volume(res[:c]) ≈ 5u"L"

    # disconnecting: the destination is emptied, the source keeps a leftover
    disconnect!(q, :w => :c)
    rebrew!(res, q, :blend)                         # the change is found from the arrows
    @test iszero(res[:c])
    @test volume(res[:blend]) ≈ 2u"L"
    @test !haskey(res.arrows, (:w, :c))
    @test same(res, q)

    # connecting from a node that did not change
    connect!(q, :b => :blend)
    rebrew!(res, q, :blend)
    @test volume(res[:blend]) ≈ 5u"L"
    @test same(res, q)

    # a new arrow between nodes already joined
    connect!(q, :w => :c, Transfer(1u"L"))
    connect!(q, :w => :c)
    rebrew!(res, q, :c)
    @test volume(res[:c]) ≈ 5u"L"
    @test same(res, q)

    # adding and removing nodes
    add!(q, :d)
    connect!(q, :blend => :d, Transfer(0.5))
    remove!(q, :a)
    rebrew!(res, q, :d)
    @test !haskey(res.nodes, :a)
    @test volume(res[:d]) ≈ 5u"L"                 # half of 3 L from :b and 7 L from :c
    @test same(res, q)
    @test_throws ArgumentError rebrew!(res, q, :a)
end

# Figure 1 of the BrewQuiver notes: the joint production of Fuller's Barley Wine, ESB,
# Pale Ale and Bitter, by parti-gyle from two mashes into three boils and fermentors.
function fullers()
    q = Quiver()
    add!(q, :goldings, goldings => 1.5u"kg")
    add!(q, :invert, invert => 4u"kg")
    for i in 1:3
        add!(q, Symbol(:yeast, i), ale => 1)
        add!(q, Symbol(:kettle, i), Symbol(:wort, i); vessel = Symbol(:copper, i))
        add!(q, Symbol(:fermentor, i), Symbol(:beer, i); vessel = Symbol(:fv, i))
        add!(q, Symbol(:bright, i); vessel = Symbol(:tank, i))
    end
    for (m, grist) in enumerate(([pale => 40u"kg", crystal => 3u"kg"], [pale => 35u"kg"]))
        mash = Symbol(:mash, m)
        beds = [Symbol(:bed, m, :_, i) for i in 1:3]
        lots = [Symbol(:grist, m, :_, j) for j in eachindex(grist)]
        foreach((l, g) -> add!(q, l, g), lots, grist)
        add!(q, Symbol(:strike, m), water(110u"L"; temperature = 75u"°C"))
        add!(q, mash, beds...; vessel = Symbol(:mashtun, m))
        connect!(q, [Symbol(:strike, m); lots] => mash)
        connect!(q, mash => beds[1], MashRest(temperature = 66u"°C"))
        for i in 1:3
            if i > 1                                         # sparge the grain bed
                add!(q, Symbol(:sparge, m, :_, i), water(80u"L"; temperature = 80u"°C"))
                connect!(q, beds[i - 1] => beds[i])
                connect!(q, Symbol(:sparge, m, :_, i) => beds[i])
            end
            connect!(q, beds[i] => Symbol(:kettle, i), Drain())
        end
    end
    for i in 1:3
        kettle, wort, fv, beer, bright =
            (Symbol(x, i) for x in (:kettle, :wort, :fermentor, :beer, :bright))
        connect!(q, :goldings => kettle, Transfer((750 - 250(i - 1)) * u"g"; remaining = 90u"minute"))
        i == 1 && connect!(q, :invert => kettle)
        connect!(q, kettle => wort, Boil(time = 90u"minute", evaporation = 8u"L/hr"))
        connect!(q, wort => fv, Drain(retain = 2u"L"))
        connect!(q, Symbol(:yeast, i) => fv)
        connect!(q, fv => beer, Ferment(temperature = 19u"°C", time = 7u"d"))
        connect!(q, beer => bright, Drain(retain = 2u"L"))
    end
    add!(q, :barley_wine, :esb, :pale_ale, :bitter)
    connect!(q, :bright1 => :barley_wine, Transfer(50u"percent"))
    connect!(q, :bright1 => :esb)
    connect!(q, :bright2 => :esb, Transfer(40u"percent"))
    connect!(q, :bright2 => :pale_ale)
    connect!(q, :bright3 => :pale_ale, Transfer(30u"percent"))
    connect!(q, :bright3 => :bitter)
    return q
end

@testset "Parti-gyle (Fuller's)" begin
    q = fullers()
    res = brew(q)
    og(n) = original_gravity(res[n])

    # the runnings get weaker, and so do the boils
    @test gravity(res[:wort1]) > gravity(res[:wort2]) > gravity(res[:wort3])
    @test og(:barley_wine) > og(:esb) > og(:pale_ale) > og(:bitter)
    @test og(:barley_wine) ≈ gravity(res[:wort1])
    @test og(:bitter) ≈ gravity(res[:wort3])
    @test abv(res[:barley_wine]) > abv(res[:esb]) > abv(res[:bitter])
    @test all(isempty(solids(res[b])) for b in (:barley_wine, :esb, :pale_ale, :bitter))

    # a blend is the exact mixture of its parts
    @test res[:esb] ≈ 0.5 * res[:bright1] + 0.4 * res[:bright2]
    @test volume(res[:barley_wine]) ≈ 0.5 * volume(res[:bright1])
    @test Set(keys(products(res, q))) == Set([:barley_wine, :esb, :pale_ale, :bitter])

    # conservation of everything, and of the extract equivalent and the color
    @test conserved(res, q)
    left = collect(values(leftovers(res)))
    dissolved = extract_of(pale, 75u"kg", 0.95) + extract_of(crystal, 3u"kg", 0.95) + 4u"kg"
    @test sum(extract_equivalent, left) ≈ dissolved
    @test sum(c -> liquor(c).color, left) ≈
          ustrip(u"lb", 75u"kg") * 3 + ustrip(u"lb", 3u"kg") * 60 +
          ustrip(u"lb", 4u"kg") * ustrip(u"°L", invert.color)
    @test all(iszero(leftover(res, n)) for n in (:goldings, :invert))
    @test released(res).water ≈ 3 * 8u"L/hr" * 90u"minute" * BrewingFormulas.WATER_DENSITY_20C
end

@testset "Provenance" begin
    # a single batch: every lot serves its only product, and the waste is allocated to it
    q = single_batch()
    res = brew(q)
    a = attribution(res, q, :bottles)
    @test all(≈(1), values(a))
    @test shares(res, q, :bottles) == Dict(l => 1.0 for l in (:pale, :crystal, :goldings, :yeast,
                                          :strike_water, :sparge_water, :priming_sugar))
    @test_throws ArgumentError attribution(res, q, :nowhere)

    # what remains on the shelf is not used
    q2 = Quiver()
    add!(q2, :w, water(10u"L"))
    add!(q2, :hops, goldings => 100u"g")
    add!(q2, :a)
    connect!(q2, :w => :a, Transfer(4u"L"))
    connect!(q2, :hops => :a, Transfer(30u"g"))
    r2 = brew(q2)
    s2 = shares(r2, q2, :a)
    @test keys(s2) == Set([:w, :hops]) && s2[:w] ≈ 0.4 && s2[:hops] ≈ 0.3

    # the parti-gyle: each lot is shared among the four beers
    q = fullers()
    res = brew(q)
    beers = (:barley_wine, :esb, :pale_ale, :bitter)
    s = Dict(b => shares(res, q, b) for b in beers)
    for l in nodes(q)
        isempty(predecessors(q, l)) || continue
        @test sum(get(s[b], l, 0.0) for b in beers) ≈ 1
    end
    @test !haskey(s[:barley_wine], :yeast3) && !haskey(s[:bitter], :yeast1)
    @test s[:esb][:yeast2] ≈ 0.4                   # 40% of the second beer goes to the ESB
    @test s[:barley_wine][:goldings] ≈ 0.5 * 750 / 1500   # half of the first copper's hops
    # the first runnings of the first mash go to the first copper, and so on
    a = attribution(res, q, :barley_wine)
    @test a[:wort1] ≈ 0.5 && a[:fermentor1] ≈ 0.5 && a[:wort2] == 0
    @test 0 < a[:mash1] < 0.5
end

@testset "Export to BeerJSON" begin
    q = single_batch()
    res = brew(q)
    r = recipe(res, q, :bottles; name = "Bitter", author = "BrewQuiver")
    @test isempty(BeerJSON.violations(r))
    @test r.name == "Bitter" && r.type.value == "all grain"
    @test BeerJSON.quantity(r.batch_size) ≈ volume(res[:fermentor])
    @test BeerJSON.quantity(r.boil.pre_boil_size) ≈ volume(res[:kettle])
    @test ustrip(BeerJSON.quantity(r.efficiency.brewhouse)) / 100 ≈ brewhouse_efficiency(res, q)
    @test BeerJSON.quantity(r.original_gravity) ≈ original_gravity(res[:beer])   # before priming
    @test BeerJSON.quantity(r.alcohol_by_volume) ≈ abv(res[:beer])
    @test r.carbonation ≈ ustrip(carbonation(res[:bottles]))
    f = r.ingredients.fermentable_additions
    @test [x.name for x in f] == ["Pale ale malt", "Crystal 60", "Corn sugar"]
    @test BeerJSON.quantity(f[1].amount) ≈ 4.5u"kg"
    @test [x.timing.use.value for x in f] == ["add_to_mash", "add_to_mash", "add_to_package"]
    h = r.ingredients.hop_additions
    @test [BeerJSON.quantity(x.timing.time) for x in h] == [60u"minute", 10u"minute"]
    @test [BeerJSON.quantity(x.amount) for x in h] ≈ [30u"g", 20u"g"]
    steps = r.mash.mash_steps
    @test [x.type.value for x in steps] == ["infusion", "sparge"]
    @test [BeerJSON.quantity(x.amount) for x in steps] ≈ [16u"L", 14u"L"]
    @test BeerJSON.quantity(steps[1].infuse_temperature) ≈ 75u"°C"
    @test BeerJSON.quantity(r.fermentation.fermentation_steps[1].step_time) == 14u"d"

    # back into a quiver: the same wort and beer, given the kettle of the quiver
    kettle = BeerJSON.EquipmentType{Int64, Float64}(name = "Kit", equipment_items = [
        (name = "Kettle", form = "Brew Kettle", maximum_volume = (unit = "l", value = 40),
         loss = (unit = "l", value = 1), boil_rate_per_hour = (unit = "l", value = 4))])
    q2 = Quiver(r; equipment = kettle)
    r2 = brew(q2)
    @test volume(r2[:kettle]) ≈ volume(res[:kettle]) rtol = 1e-6
    @test volume(r2[:fermentor]) ≈ volume(res[:fermentor]) rtol = 1e-6
    @test gravity(r2[:fermentor]) ≈ gravity(res[:fermentor]) rtol = 1e-6
    @test ibu(r2[:beer]) ≈ ibu(res[:beer]) rtol = 1e-6
    @test abv(r2[:beer]) ≈ abv(res[:beer]) rtol = 1e-6
    @test apparent_attenuation(r2[:beer]) ≈ apparent_attenuation(res[:beer])

    # the parti-gyle: four recipes, which add up to the brew
    q = fullers()
    res = brew(q)
    rs = recipes(res, q)
    @test [x.name for x in rs] == ["barley_wine", "esb", "pale_ale", "bitter"]
    @test all(x -> isempty(BeerJSON.violations(x)), rs)
    amount(x, name) = sum((BeerJSON.quantity(f.amount) for f in x.ingredients.fermentable_additions
                           if f.name == name); init = 0.0u"kg")
    @test sum(amount(x, "Pale ale malt") for x in rs) ≈ 75u"kg"
    @test sum(amount(x, "Invert sugar") for x in rs) ≈ 4u"kg"
    @test amount(rs[4], "Invert sugar") == 0u"kg"            # only in the first copper
    @test sum(BeerJSON.quantity(h.amount) for x in rs for h in x.ingredients.hop_additions) ≈ 1.5u"kg"
    @test sum(BeerJSON.quantity(x.batch_size) for x in rs) ≈
          sum(volume(res[Symbol(:fermentor, i)]) for i in 1:3)
    @test sum(BeerJSON.quantity(x.mash.mash_steps[1].amount) for x in rs) ≈ 220u"L"
    @test BeerJSON.quantity(rs[1].original_gravity) ≈ original_gravity(res[:barley_wine])

    # written to a BeerJSON document and read back
    path = writejson(tempname() * ".json", res, q; author = "BrewQuiver")
    doc = BeerJSON.readjson(BeerJSON.BeerJSONParser, path)
    @test length(doc.beerjson.recipes) == 4
    @test doc.beerjson.recipes[2].author == "BrewQuiver"
end

@testset "Timeline" begin
    minute, hr, d = u"minute", u"hr", u"d"
    q = single_batch()
    s = timeline(q)
    @test s[:pale] == (arrive = 0.0minute, ready = 0.0minute, leave = 0.0minute)
    @test s[:mash].ready == 0minute && s[:mash].leave == 60minute         # the mash rest
    @test s[:rested].arrive == 60minute                                   # when the rest ends
    @test s[:kettle].ready == 60minute && s[:wort].ready == 120minute     # the boil
    @test [x.start for x in s[:goldings => :kettle]] == [60minute, 110minute]
    @test only(s[:yeast => :fermentor]).start == 120minute               # pitched with the wort
    @test s[:beer].ready == 120minute + 14d
    @test only(s[:priming_sugar => :bottling]).start == s[:beer].ready
    @test s[:bottles].ready == 120minute + 28d && s[:bottles].leave === nothing
    @test makespan(s) == 120minute + 28d
    @test isempty(overlaps(s))
    @test timeline(q; start = 8hr)[:wort].ready == 10hr                  # a later start

    # draining and chilling take time: the sparge waits for the first runnings
    q[:rested => :kettle] = Drain(duration = 15minute)
    q[:grain_bed => :kettle] = Drain(duration = 20minute)
    q[:wort => :chilled] = Chill(temperature = 18u"°C", time = 25minute)
    q[:chilled => :fermentor] = Drain(retain = 1u"L", duration = 20minute)
    s = timeline(q)
    @test only(s[:rested => :grain_bed]).start == 75minute
    @test only(s[:sparge_water => :grain_bed]).start == 75minute
    @test s[:kettle].arrive == 60minute && s[:kettle].ready == 95minute
    @test [x.start for x in s[:goldings => :kettle]] == [95minute, 145minute]
    @test s[:fermentor].arrive == 180minute && s[:fermentor].ready == 200minute
    @test isempty(overlaps(s))
    @test duration(Drain(duration = 15minute)) == 15minute && duration(Ferment()) == 14d

    # dry hops during the fermentation: with 3 days left, or 2 days in
    q = single_batch()
    add!(q, :cascade, Hop("Cascade"; alpha = 6u"percent") => 60u"g")
    connect!(q, :cascade => :fermentor, Transfer(30u"g"; remaining = 3d))
    connect!(q, :cascade => :fermentor, Transfer(30u"g"; at = 2d))
    s = timeline(q)
    @test [x.start for x in s[:cascade => :fermentor]] == [120minute + 11d, 120minute + 2d]
    @test s[:fermentor].ready == 120minute                     # timed additions do not wait

    # the parti-gyle: each copper waits for the runnings of both mashes
    q = fullers()
    for m in 1:2, i in 1:3
        q[Symbol(:bed, m, :_, i) => Symbol(:kettle, i)] = Drain(duration = (10 + 5m) * minute)
    end
    s = timeline(q)
    @test s[:kettle1].ready == 60minute + 20minute            # the slower drain of mash 2
    @test s[:kettle2].ready == 80minute + 20minute
    @test s[:wort1].ready == s[:kettle1].ready + 90minute
    @test s[:esb].ready == max(s[:bright1].ready, s[:bright2].ready)
    @test isempty(overlaps(s))

    # one kettle for two boils not joined by arrows: they overlap
    q = Quiver()
    add!(q, :w1, wort(20u"L", 1.050u"sg")); add!(q, :w2, wort(20u"L", 1.050u"sg"))
    add!(q, :k1, :b1; vessel = :kettle); add!(q, :k2, :b2; vessel = :kettle)
    connect!(q, :w1 => :k1); connect!(q, :w2 => :k2)
    connect!(q, :k1 => :b1, Boil()); connect!(q, :k2 => :b2, Boil())
    s = timeline(q)
    @test (:kettle, :k1, :k2) in overlaps(s)
    @test occursin("overlapping in a vessel", sprint(show, MIME"text/plain"(), s))

    # the display and the chart
    s = timeline(single_batch())
    shown = sprint(show, MIME"text/plain"(), s)
    @test occursin("Timeline over 28d 2:00", shown) && occursin("[kettle]", shown)
    chart = sprint(io -> vesselchart(io, s; to = 3hr, width = 36))
    @test occursin("mashtun", chart) && occursin('█', chart)
    @test count('\n', chart) == 5
    @test_throws ArgumentError vesselchart(devnull, s; from = 2hr, to = 1hr)
end

@testset "Equipment" begin
    v = Vessel(name = "Kettle", capacity = 30u"L", dead_space = 1.5u"L", evaporation = 5u"L/hr",
               drain_rate = 1.5u"L/minute")
    @test v.capacity == 30u"L" && v.drain_rate == 1.5u"L/minute" && v.absorption === nothing
    @test sprint(show, v) == "Vessel(\"Kettle\"; 30.0 L, 1.5 L dead space, evaporating 5.0 L/h, draining 1.5 L/min)"
    @test Drain().absorption === nothing && Boil().evaporation === nothing

    # the arrows take from the vessel what they do not give
    q = single_batch()
    for (s, d) in ((:rested, :kettle), (:grain_bed, :kettle), (:chilled, :fermentor))
        q[s => d] = Drain()
    end
    q[:kettle => :wort] = Boil(time = 60u"minute")
    equip!(q, :mashtun, Vessel(capacity = 25u"L", dead_space = 0.5u"L", absorption = 0.9u"L/kg",
                               drain_rate = 1u"L/minute"))
    equip!(q, :kettle, v)
    @test equipment(q, :kettle) === v && equipment(q, :fermentor) === nothing
    res = brew(q)
    @test volume(leftover(res, :grain_bed)) ≈ 4.8u"kg" * 0.9u"L/kg" + 0.5u"L"
    @test volume(res[:kettle]) - volume(res[:wort]) ≈ 5u"L" rtol = 1e-2       # evaporation
    @test volume(leftover(res, :chilled)) ≈ 1.5u"L"                            # dead space
    @test conserved(res, q)
    @test isempty(overfilled(res, q))

    # what the arrows give wins
    q[:chilled => :fermentor] = Drain(retain = 0.5u"L")
    @test volume(leftover(brew(q), :chilled)) ≈ 0.5u"L"

    # the capacity, with the grain displaced in the mash
    equip!(q, :mashtun, Vessel(capacity = 18u"L"))
    o = overfilled(brew(q), q)
    @test [x.node for x in o] == [:mash, :rested, :grain_bed]
    @test o[1].volume ≈ mash_volume(16u"L", 4.8u"kg") && o[1].capacity == 18u"L"

    # the drains take the time of the drain rates
    equip!(q, :mashtun, Vessel(drain_rate = 1u"L/minute"))
    res = brew(q)
    t = timeline(q)
    first = volume(only(res[:rested => :kettle]).moved)
    @test only(t[:rested => :kettle]).stop - 60u"minute" ≈ uconvert(u"minute", first / 1u"L/minute")
    drained = sum(volume(only(res[n => :kettle]).moved) for n in (:rested, :grain_bed))
    @test t[:kettle].ready ≈ 60u"minute" + drained / 1u"L/minute"
    knockout = volume(only(res[:chilled => :fermentor]).moved)
    @test only(t[:chilled => :fermentor]).stop - only(t[:chilled => :fermentor]).start ≈
          knockout / 1.5u"L/minute"
    @test timeline(res, q)[:fermentor] == t[:fermentor]
    q[:rested => :kettle] = Drain(duration = 5u"minute")            # what the arrow gives wins
    @test only(timeline(q)[:rested => :kettle]).stop == 65u"minute"
end

@testset "Hop stands, decoctions and dry hops" begin
    minute = u"minute"
    models = DEFAULT_MODELS
    w = Contents(wort(25u"L", 1.050u"sg"))
    citra = Hop("Citra"; alpha = 12u"percent")
    lot(t) = BrewQuiver.with_timing(Contents(citra => 50u"g"), t)
    after(b, t) = first(transform(b, w + lot(t), models))

    # a hop stand: the hops keep isomerizing, at the relative rate of its temperature
    stand = Boil(stand = 20minute, stand_temperature = 80u"°C")
    @test duration(stand) == 80minute && duration(Boil()) == 60minute
    @test ibu(after(Boil(), Remaining(0minute))) == 0u"IBU"
    flameout = after(stand, Remaining(0minute))
    @test ibu(flameout) > 0u"IBU"
    @test liquor(flameout).temperature ≈ 80u"°C"
    @test ibu(after(Boil(stand = 20minute, stand_temperature = 95u"°C"), Remaining(0minute))) > ibu(flameout)
    @test ibu(after(stand, Remaining(60minute))) > ibu(after(Boil(), Remaining(60minute)))
    # boiled for f × 20 minutes: as a hop boiled that long
    f = isomerization_factor(80u"°C")
    @test ibu(flameout) ≈ ibu(after(Boil(), Remaining(f * 20minute))) rtol = 1e-6
    # added 10 minutes into the stand: 10 minutes of stand
    @test ibu(after(stand, At(70minute))) ≈ ibu(after(Boil(stand = 10minute), Remaining(0minute))) rtol = 1e-6
    @test sprint(show, stand) == "Boil(60.0 min, stand 20.0 min at 80.0 °C)"

    # in the timeline, the timings count within the boil, not the stand
    q = single_batch()
    add!(q, :whirlpool_hops, citra => 40u"g")
    connect!(q, :whirlpool_hops => :kettle, Transfer(20u"g"; remaining = 0minute))
    connect!(q, :whirlpool_hops => :kettle, Transfer(20u"g"; at = 70minute))
    q[:kettle => :wort] = Boil(evaporation = 4u"L/hr", stand = 20minute)
    t = timeline(q)
    @test [x.start for x in t[:goldings => :kettle]] == [60minute, 110minute]
    @test [x.start for x in t[:whirlpool_hops => :kettle]] == [120minute, 130minute]
    @test t[:wort].ready == 140minute
    res = brew(q)
    @test ibu(res[:wort]) > ibu(brew(single_batch())[:wort])
    @test conserved(res, q)

    # a decoction: a part of the mash is boiled and returned, raising it to the next rest
    q = Quiver()
    add!(q, :malt, pale => 5u"kg")
    add!(q, :strike, water(15u"L"; temperature = 55u"°C"))
    add!(q, :mash, :mash_1, :mash_2_in, :mash_2; vessel = :mashtun)
    add!(q, :decoction, :decoction_boiled; vessel = :kettle)
    connect!(q, [:strike, :malt] => :mash)
    connect!(q, :mash => :mash_1, MashRest(temperature = 50u"°C", time = 20minute))
    fraction = BrewQuiver._decoction_fraction(50u"°C", 65u"°C")
    @test fraction ≈ 15 / 50
    connect!(q, :mash_1 => :decoction, Transfer(fraction))
    connect!(q, :mash_1 => :mash_2_in)
    connect!(q, :decoction => :decoction_boiled, Boil(time = 15minute, evaporation = 0u"L/hr"))
    connect!(q, :decoction_boiled => :mash_2_in)
    connect!(q, :mash_2_in => :mash_2, MashRest(temperature = 65u"°C", time = 60minute))
    res = brew(q)
    @test liquor(res[:mash_2_in]).temperature ≈ 65u"°C"                # back at the next rest
    @test grist(res[:decoction]) ≈ fraction * 5u"kg"
    @test conserved(res, q)
    t = timeline(q)
    @test t[:mash_2].ready == 20minute + 15minute + 60minute
    @test isempty(overlaps(t))

    # dry hops: their timing in the fermentation, and the beer they keep when racked
    q = single_batch()
    add!(q, :dry_hops, citra => 100u"g")
    connect!(q, :dry_hops => :fermentor, Transfer(; remaining = 3u"d"))
    q[:beer => :bottling] = Drain(retain = 1u"L", hop_absorption = 5u"L/kg")
    res = brew(q)
    @test volume(leftover(res, :beer)) ≈ 1u"L" + 0.1u"kg" * 5u"L/kg"
    @test any(s -> s isa Portion{Hop}, solids(leftover(res, :beer)))
    @test ibu(res[:beer]) ≈ ibu(brew(single_batch())[:beer])       # no bitterness from dry hops
    @test only(timeline(q)[:dry_hops => :fermentor]).start == 120minute + 11u"d"
    @test conserved(res, q)
    equip!(q, :fermentor, Vessel(hop_absorption = 4u"L/kg"))
    q[:beer => :bottling] = Drain(retain = 1u"L")
    @test volume(leftover(brew(q), :beer)) ≈ 1u"L" + 0.1u"kg" * 4u"L/kg"
end

@testset "Targets and solving" begin
    # the grain bill for an original gravity, keeping its proportions
    q = single_batch()
    s = solve!(q, :fermentor => gravity => 1.060u"sg"; vary = Amount(:pale, :crystal))
    @test s.converged
    @test gravity(brew(q)[:fermentor]) ≈ 1.060u"sg" rtol = 1e-8
    pale_kg = only(solids(q[:pale].initial)).amount
    crystal_kg = only(solids(q[:crystal].initial)).amount
    @test pale_kg > 4.5u"kg" && pale_kg / crystal_kg ≈ 4.5 / 0.3
    @test s.result[:fermentor] ≈ brew(q)[:fermentor]
    @test s.targets[1].second ≈ 1.060u"sg" rtol = 1e-8

    # several targets at once: gravity, bitterness, pre-boil volume and carbonation
    q = single_batch()
    s = solve!(q, :fermentor => gravity => 1.052u"sg", :wort => ibu => 35u"IBU",
               :kettle => volume => 28u"L", :bottles => carbonation => 2.4u"vols";
               vary = [Amount(:pale, :crystal), Amount(:goldings), Amount(:sparge_water),
                       Amount(:priming_sugar)])
    @test s.converged
    res = brew(q)
    @test gravity(res[:fermentor]) ≈ 1.052u"sg" rtol = 1e-8
    @test ibu(res[:wort]) ≈ 35u"IBU" rtol = 1e-8
    @test volume(res[:kettle]) ≈ 28u"L" rtol = 1e-8
    @test carbonation(res[:bottles]) ≈ 2.4u"vols" rtol = 1e-8
    # the transfers of masses from the hops scale with them
    @test [a.amount for a in q[:goldings => :kettle]] ≈
          [30u"g", 20u"g"] .* (only(solids(q[:goldings].initial)).amount / 50u"g")
    @test isempty(leftovers(res)) || !haskey(leftovers(res), :goldings)
    @test conserved(res, q)

    # a goal in other units, through the gravity model; a setting of an arrow
    q = single_batch()
    @test solve!(q, :fermentor => gravity => 12.5u"°P"; vary = Amount(:pale, :crystal)).converged
    @test uconvert(u"°P", gravity(brew(q)[:fermentor]), SugarGravityQuad()) ≈ 12.5u"°P" rtol = 1e-6
    s = solve!(q, :wort => ibu => 30u"IBU"; vary = Setting(:kettle => :wort, :time))
    @test s.converged
    @test ibu(brew(q)[:wort]) ≈ 30u"IBU" rtol = 1e-8
    @test s.parameters[1].second == only(q[:kettle => :wort]).time
    # the stand that gives the bitterness of a stand of 25 minutes
    q[:kettle => :wort] = Boil(time = 60u"minute", evaporation = 4u"L/hr", stand = 25u"minute")
    goal = ibu(brew(q)[:wort])
    q[:kettle => :wort] = Boil(time = 60u"minute", evaporation = 4u"L/hr", stand = 10u"minute")
    @test solve!(q, :wort => ibu => goal; vary = Setting(:kettle => :wort, :stand)).converged
    @test only(q[:kettle => :wort]).stand ≈ 25u"minute" rtol = 1e-6

    # the blend fractions of the parti-gyle, for the gravities of two beers
    q = fullers()
    s = solve!(q, :esb => original_gravity => 1.065u"sg", :pale_ale => original_gravity => 1.020u"sg";
               vary = [Setting(:bright1 => :barley_wine, :amount), Setting(:bright3 => :pale_ale, :amount)])
    @test s.converged
    res = brew(q)
    @test original_gravity(res[:esb]) ≈ 1.065u"sg" rtol = 1e-8
    @test original_gravity(res[:pale_ale]) ≈ 1.020u"sg" rtol = 1e-8
    @test 0.5 < only(q[:bright1 => :barley_wine]).amount < 1
    @test 0.3 < only(q[:bright3 => :pale_ale]).amount < 1
    @test conserved(res, q)

    # a target out of reach: the solver stops, and says so
    q = single_batch()
    s = solve!(q, :wort => ibu => 40u"IBU"; vary = Setting(:kettle => :wort, :stand))
    @test !s.converged
    @test occursin("not converged", sprint(show, MIME"text/plain"(), s))

    # the errors
    q = single_batch()
    @test_throws ArgumentError solve!(q, :fermentor => gravity => 1.05u"sg"; vary = Amount(:mash))
    @test_throws ArgumentError solve!(q, :fermentor => gravity => 1.05u"sg"; vary = Amount(:nowhere))
    @test_throws ArgumentError solve!(q, :fermentor => gravity => 1.05u"sg";
                                      vary = [Amount(:pale), Amount(:goldings)])
    @test_throws ArgumentError solve!(q, :fermentor => gravity => 1.05u"sg";
                                      vary = Setting(:goldings => :kettle, :timing))
    @test_throws ArgumentError solve!(q, :fermentor => gravity => 1.05u"sg";
                                      vary = Setting(:kettle => :fermentor, :time))
    shown = sprint(show, MIME"text/plain"(), solve!(single_batch(), :fermentor => gravity => 1.05u"sg";
                                                    vary = Amount(:pale)))
    @test occursin("amount of :pale", shown) && occursin("gravity(:fermentor)", shown)
end

@testset "Water chemistry" begin
    p = WaterProfile(calcium = 50u"mg/L", magnesium = 10u"mg/L", sodium = 15u"mg/L",
                     chloride = 40u"mg/L", sulfate = 60u"mg/L", bicarbonate = 150u"ppm")
    @test p.bicarbonate ≈ 150u"mg/L"
    @test_throws ArgumentError WaterProfile(calcium = 50)
    w = water(16u"L"; profile = p)
    @test profile(w).calcium ≈ 50u"mg/L" && profile(w).bicarbonate ≈ 150u"mg/L"
    @test residual_alkalinity(w) ≈ residual_alkalinity(alkalinity(150u"mg/L"), 50u"mg/L", 10u"mg/L")
    @test profile(water(10u"L")) == WaterProfile()
    @test 0.25 * w + 0.75 * w ≈ w
    @test profile(w + water(16u"L")).calcium ≈ 25u"mg/L" rtol = 1e-3      # diluted by half

    # salts and acids are held dissolved, conserving their mass
    gypsum = Contents(Salt(Gypsum()) => 5u"g")
    @test total_mass(gypsum) ≈ 5u"g"
    @test isempty(solids(gypsum))
    @test profile(Contents(w) + gypsum).calcium ≈ 50u"mg/L" + ions(Gypsum(), 5u"g", 16u"L").calcium rtol = 1e-3
    lactic = Contents(Acid(LacticAcid()) => 2u"mL")
    @test total_mass(lactic) ≈ 2u"mL" * 1.21u"g/mL"
    @test liquor(lactic).minerals.alkalinity ≈ -acid_milliequivalents(LacticAcid(), 2u"mL") * 50.043u"mg" rtol = 1e-4
    @test residual_alkalinity(Contents(w) + lactic) < residual_alkalinity(w)
    @test Salt(Gypsum()).name == "Gypsum" && Acid(LacticAcid()).name == "Lactic acid 88.0%"
    @test sprint(show, gypsum) == "Contents(1.2 g Ca, 2.8 g SO₄)"

    # the minerals go with the liquor: drained, concentrated by the boil, conserved
    q = single_batch()
    q[:strike_water] = water(16u"L"; temperature = 75u"°C", profile = p)
    q[:sparge_water] = water(14u"L"; temperature = 80u"°C", profile = p)
    add!(q, :gypsum, Salt(Gypsum()) => 5u"g")
    add!(q, :lactic, Acid(LacticAcid()) => 1u"mL")
    connect!(q, [:gypsum, :lactic] => :mash)
    res = brew(q)
    @test conserved(res, q)
    @test profile(res[:wort]).calcium > profile(res[:kettle]).calcium            # evaporation
    m(c) = liquor(c).minerals
    total(f) = sum(f(m(c)) for c in values(leftovers(res)))
    @test total(x -> x.calcium) ≈ 30u"L" * 50u"mg/L" + ions(Gypsum(), 5u"g", 1u"L").calcium * 1u"L"
    @test total(x -> x.sulfate) ≈ 30u"L" * 60u"mg/L" + ions(Gypsum(), 5u"g", 1u"L").sulfate * 1u"L"

    # the mash pH, before the mash rest
    ph = @test_logs (:warn, r"Crystal 60") mash_ph(res[:mash])
    grist = [(mass = 4.5u"kg", di_ph = nothing, buffering = nothing),
             (mass = 0.3u"kg", di_ph = nothing, buffering = nothing)]
    @test ph ≈ mash_ph(grist, volume(res[:mash]), residual_alkalinity(res[:mash]))
    @test_throws ArgumentError mash_ph(res[:rested])                  # no grain left to mash
    dark = Fermentable("Crystal 60"; yield = 74u"percent", color = 60u"°L", di_ph = 4.7, buffering = 60)
    q[:crystal] = dark => 0.3u"kg"
    res = brew(q)
    ph2 = @test_logs mash_ph(res[:mash])                               # no warning
    @test ph2 < ph
    @test ph2 ≈ mash_ph([grist[1], (mass = 0.3u"kg", di_ph = 4.7, buffering = 60)],
                        volume(res[:mash]), residual_alkalinity(res[:mash]))
    # more acid lowers it, baking soda raises it
    q[:lactic] = Acid(LacticAcid()) => 3u"mL"
    @test mash_ph(brew(q)[:mash]) < ph2
    q[:lactic] = Salt(BakingSoda()) => 3u"g"
    @test mash_ph(brew(q)[:mash]) > ph2
end

@testset "Library and inventory" begin
    samples = joinpath(pkgdir(BeerJSON), "test", "samples")
    lib = Library((joinpath(samples, f) for f in ("real/FermentableRecord.json",
        "real/HopRecordWithAllFields.json", "real/YeastWithMorePopularFields.json",
        "real/CrystalMaltSpecialtyGrain.json"))...)
    @test keys(lib) == ["Crystal 40 L", "German Ale", "Lex Luthor Hops", "Pale 2-row Malt", "Super Hops"]
    @test lib["Crystal 40 L"] isa Fermentable && lib["Crystal 40 L"].moisture == 0.04
    @test lib["German Ale"].attenuation ≈ 0.75 && lib["German Ale"].form === :liquid
    @test lib["Super Hops"].form === :leaf
    @test stock(lib, "Super Hops") ≈ uconvert(u"kg", 2u"oz")
    @test stock(lib, "Lex Luthor Hops") ≈ uconvert(u"L", 2u"floz")
    @test stock(lib, "Crystal 40 L") === nothing
    @test lookup(lib, "hops") == ["Lex Luthor Hops", "Super Hops"]
    @test_throws KeyError lib["Nothing"]
    @test_logs (:warn, r"no attenuation") Library(joinpath(samples, "real/YeastWithRequiredFieldsOnly.json"))

    # a library by hand, with the stock of the single batch
    lib = Library()
    for (i, s) in ((pale, 10u"kg"), (crystal, 0.5u"kg"), (goldings, 100u"g"), (ale, 2),
                   (dextrose, 1u"kg"))
        push!(lib, i; stock = s)
    end
    @test_throws ArgumentError stock!(lib, "Crystal 60", "plenty")
    q = single_batch()
    res = brew(q)
    need = requirements(res, q)
    @test need["Pale ale malt"] ≈ 4.5u"kg" && need["Crystal 60"] ≈ 0.3u"kg"
    @test need["East Kent Goldings"] ≈ 50u"g" && need["English ale"] == 1.0
    @test need["Corn sugar"] ≈ 110u"g"
    @test isempty(shortages(lib, res, q))
    stock!(lib, "Pale ale malt", 4u"kg")
    short = only(shortages(lib, res, q))
    @test short.name == "Pale ale malt" && short.needed ≈ 4.5u"kg" && short.available ≈ 4u"kg"
    # what remains on the shelf is not used
    q2 = single_batch()
    q2[:goldings] = goldings => 80u"g"
    @test requirements(brew(q2), q2)["East Kent Goldings"] ≈ 50u"g"
    # ingredients not in the library, or without stock; counts and volumes are not compared
    lib2 = Library()
    push!(lib2, pale; stock = 10u"kg")
    push!(lib2, ale; stock = 0.1u"L")
    @test Set(x.name for x in shortages(lib2, res, q)) == Set(["Crystal 60", "East Kent Goldings", "Corn sugar"])

    # brewing takes from the stock
    stock!(lib, "Pale ale malt", 10u"kg")
    consume!(lib, res, q)
    @test stock(lib, "Pale ale malt") ≈ 5.5u"kg" && stock(lib, "English ale") == 1.0
    @test stock(lib, "East Kent Goldings") ≈ 50u"g"
    stock!(lib, "Crystal 60", 0.1u"kg")
    @test_logs (:warn, r"Crystal 60") consume!(lib, res, q)
    @test iszero(stock(lib, "Crystal 60"))

    # written to BeerJSON and read back
    path = writejson(tempname() * ".json", lib)
    back = Library(path)
    @test keys(back) == keys(lib)
    @test back["Pale ale malt"] == pale && back["East Kent Goldings"] == goldings
    push!(lib, Fermentable("Roast barley"; color = 500u"°L", di_ph = 4.6); stock = 1u"kg")
    @test readjson(Library, writejson(tempname() * ".json", lib))["Roast barley"].di_ph ≈ 4.6
    @test back["English ale"].attenuation ≈ ale.attenuation
    @test stock(back, "Pale ale malt") ≈ stock(lib, "Pale ale malt")
    @test stock(back, "English ale") === nothing                  # (a count: not written)
    @test occursin("in stock 1.0 kg", sprint(show, MIME"text/plain"(), back))

    # a recipe completed by the library: moisture, and attenuation where the recipe has none
    generic = only(BeerJSON.readjson(BeerJSON.BeerJSONParser, joinpath(samples, "generic/recipes.json")).beerjson.recipes)
    lib = Library()
    push!(lib, Fermentable("pale ale"; yield = 78u"percent", color = 3u"°L", moisture = 6u"percent"))
    push!(lib, Culture("US-05"; attenuation = 81u"percent", form = :dry))
    q = with_logger(NullLogger()) do
        Quiver(generic; library = lib)
    end
    @test only(solids(q[:pale_ale].initial)).ingredient.moisture == 0.06
    @test only(solids(q[:us_05].initial)).ingredient.attenuation ≈ 0.81
    @test only(solids(q[:burlington_ale].initial)).ingredient.attenuation ≈ 0.75   # the default
end

include("beerjson.jl")
# Files of quivers: JGF documents with BeerJSON ingredients, read back to the same brew

roundtrip(q; kwargs...) = readjson(Quiver, writejson(tempname() * ".json", q; kwargs...))

function samebrew(q, q2)
    res, r2 = brew(q), brew(q2)
    return nodes(q2) == nodes(q) && all(r2[n] ≈ res[n] for n in nodes(q))
end

@testset "Files of quivers" begin
    # a single batch with equipment, salts and acids, a hop stand, timings and priming
    roast = Fermentable("Roast barley"; color = 500u"°L", di_ph = 4.6, buffering = 60)
    q = single_batch()
    add!(q, :roast, roast => 0.1u"kg")
    add!(q, :gypsum, Salt(Gypsum()) => 4u"g")
    add!(q, :lactic, Acid(LacticAcid(); name = "Lactic") => 2u"mL")
    connect!(q, [:roast, :gypsum, :lactic] => :mash)
    q[:kettle => :wort] = Boil(time = 60u"minute", stand = 20u"minute", stand_temperature = 80u"°C")
    q[:goldings] = goldings => 55u"g"
    connect!(q, :goldings => :kettle, Transfer(5u"g"; at = 5u"minute"))
    equip!(q, :mashtun, Vessel(capacity = 25u"L", dead_space = 0.5u"L", absorption = 0.9u"L/kg"))
    equip!(q, :kettle, Vessel(capacity = 40u"L", evaporation = 10u"percent/hr", drain_rate = 1u"L/minute"))
    nodeview(q, :mash)["position"] = [120, 40]
    nodeview(q, :mash)["color"] = "#c08040"
    res = brew(q)

    path = writejson(tempname() * ".json", q; results = res)
    q2 = readjson(Quiver, path)
    @test samebrew(q, q2)
    @test q2.equipment == q.equipment
    @test [vessel(q2, n) for n in nodes(q2)] == [vessel(q, n) for n in nodes(q)]
    @test sort(arrows(q2); by = string) == sort(arrows(q); by = string)
    @test nodeview(q2, :mash) == Dict("position" => [120, 40], "color" => "#c08040")
    @test isempty(nodeview(q2, :kettle))
    @test only(solids(q2[:roast].initial)).ingredient == roast        # with di_ph and buffering
    @test only(solids(q2[:yeast].initial)).ingredient == ale
    ph = quietly(() -> mash_ph(res[:mash]))     # (Crystal 60 has no distilled water pH)
    @test quietly(() -> mash_ph(brew(q2)[:mash])) ≈ ph

    # a JGF document, with BeerJSON records of the ingredients and the values of the brew
    doc = BrewQuiver.JSON.parsefile(path)
    g = doc["graph"]
    @test g["directed"] && g["metadata"]["format_version"] == 1
    @test length(g["nodes"]) == length(nodes(q)) && length(g["edges"]) == length(arrows(q))
    @test Set(x["name"] for x in g["metadata"]["ingredients"]["fermentables"]) ==
          Set(["Pale ale malt", "Crystal 60", "Corn sugar", "Roast barley"])
    @test g["metadata"]["ingredients"]["hop_varieties"][1]["alpha_acid"] == Dict("unit" => "%", "value" => 5)
    beer = g["nodes"]["beer"]["metadata"]["computed"]
    @test beer["ibu"]["value"] ≈ ustrip(u"IBU", ibu(res[:beer]))
    @test beer["abv"]["unit"] == "%" && beer["abv"]["value"] ≈ ustrip(u"percent", abv(res[:beer]))
    @test g["nodes"]["mash"]["metadata"]["computed"]["mash_ph"] ≈ ph
    @test !haskey(g["nodes"]["kettle"]["metadata"], "initial")              # an empty stage
    @test g["metadata"]["computed"]["models"]["bitterness"] == "Tinseth"
    # the values of the brew are not read: changing them changes nothing
    g["nodes"]["beer"]["metadata"]["computed"]["ibu"]["value"] = 1000
    io = IOBuffer()
    BrewQuiver.JSON.json(io, doc)
    @test samebrew(q, readjson(Quiver, IOBuffer(take!(io))))

    # without results, nothing computed; to and from streams
    io = IOBuffer()
    writejson(io, q)
    s = String(take!(io))
    @test !occursin("computed", s)
    @test samebrew(q, readjson(Quiver, IOBuffer(s)))

    # the parti-gyle and a quiver of a BeerJSON recipe
    @test samebrew(fullers(), roundtrip(fullers()))
    k = quietly(() -> Quiver(sample_recipe("converted", "Kolsh.json")))
    @test samebrew(k, roundtrip(k; results = brew(k)))

    # errors
    bad = single_batch()
    add!(bad, :other_pale, Fermentable("Pale ale malt"; color = 4u"°L") => 1u"kg")
    @test_throws ArgumentError writejson(IOBuffer(), bad)                 # two "Pale ale malt"
    odd = single_batch()
    add!(odd, :whirled)
    connect!(odd, :bottles => :whirled, Whirlpool())
    @test_throws ArgumentError writejson(IOBuffer(), odd)                 # not registered
    newer = replace(s, r"\"format_version\": *1" => "\"format_version\": 99")
    @test_throws ArgumentError readjson(Quiver, IOBuffer(newer))
    @test_throws ArgumentError readjson(Quiver, IOBuffer("{\"nodes\": {}}"))

    # the deprecated writer
    @test isfile(quietly(() -> write_beerjson(tempname() * ".json", res, q)))
end


end
