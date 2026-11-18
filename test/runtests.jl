using Test
using Unitful
using UnitfulBrewing
using BrewingFormulas
using BrewQuiver
using BeerJSON: BeerJSON

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
    path = write_beerjson(tempname() * ".json", res, q; author = "BrewQuiver")
    doc = BeerJSON.readjson(BeerJSON.BeerJSONParser, path)
    @test length(doc.beerjson.recipes) == 4
    @test doc.beerjson.recipes[2].author == "BrewQuiver"
end

include("beerjson.jl")

end
