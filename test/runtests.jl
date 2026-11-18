using Test
using Unitful
using UnitfulBrewing
using BrewingFormulas
using BrewQuiver

const pale = Fermentable("Pale ale malt"; yield = 80u"percent", color = 3u"°L")
const crystal = Fermentable("Crystal 60"; yield = 74u"percent", color = 60u"°L")
const sugar = Fermentable("Invert sugar"; kind = :sugar, yield = 100u"percent",
                          color = 1u"SRM", moisture = 0)
const goldings = Hop("East Kent Goldings"; alpha = 5u"percent")
const ale = Culture("English ale"; attenuation = 75u"percent")

# extract equivalent: conserved by fermentation (2.0665 g of extract per g of ethanol)
extract_equivalent(l::Liquor) = l.extract + 2.0665 * l.alcohol

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
    @test Addition(goldings, 30u"g"; time = 60u"minute").time == 60u"minute"
    @test_throws ArgumentError Boil(hops = [goldings => 30u"g"])   # no boil time
    @test_throws ArgumentError MashTun(grains = [pale])
end

function single_batch(; models = (;))
    q = Quiver()
    add!(q, :strike, Source(water(16u"L")))
    add!(q, :mashtun, MashTun(grains = [pale => 4.5u"kg", crystal => 0.3u"kg"],
                              sparge = [14u"L"]))
    add!(q, :boil, Boil(time = 60u"minute", loss = 1u"L",
                        hops = [goldings => 30u"g" => 60u"minute",
                                goldings => 20u"g" => 10u"minute"]))
    add!(q, :fermentor, Ferment(culture = ale, loss = 1u"L"))
    add!(q, :bottles, Package(carbonation = 2.4u"vols"))
    connect!(q, :strike => :mashtun)
    connect!(q, (:mashtun, :running1) => :boil)
    connect!(q, (:mashtun, :running2) => :boil)
    connect!(q, :boil => :fermentor)
    connect!(q, :fermentor => :bottles)
    return q
end

@testset "Single batch" begin
    q = single_batch()
    @test nodes(q) == [:strike, :mashtun, :boil, :fermentor, :bottles]
    res = brew(q)
    mt, bo, fe, bt = q[:mashtun], res[:boil, :out], res[:fermentor, :out], res[:bottles, :out]

    # mash: the grain retains its absorption at each step
    @test volume(res[:mashtun, :spent_grain]) ≈ grain_mass(mt) * mt.absorption
    @test gravity(res[:mashtun, :running1]) > gravity(res[:mashtun, :running2])
    dissolved = sum(mt.conversion * potential_extract(a.amount, a.ingredient.yield;
                    moisture = a.ingredient.moisture) for a in mt.grains)
    @test sum(res[:mashtun, p].extract for p in outports(mt)) ≈ dissolved

    # boil: evaporation of 4 L in one hour, then the loss
    pre = res[:boil].inputs[:in]
    @test volume(pre) ≈ volume(res[:mashtun, :running1]) + volume(res[:mashtun, :running2]) rtol = 1e-3
    @test volume(bo) + volume(res[:boil, :loss]) ≈ volume(pre) - 4u"L" rtol = 1e-3
    @test 1.045u"sg" < gravity(bo) < 1.060u"sg"
    @test 15u"IBU" < ibu(bo) < 30u"IBU"

    # fermentation: the apparent attenuation of the culture, with Balling's relations
    @test original_gravity(fe) ≈ gravity(bo)
    @test apparent_attenuation(fe) ≈ 75u"percent"
    @test abv(fe) ≈ abv(Balling(), gravity(bo), gravity(fe)) rtol = 1e-6
    @test extract_equivalent(fe + res[:fermentor, :loss]) ≈ extract_equivalent(bo)
    @test carbonation(fe) ≈ residual_co2(20u"°C") rtol = 1e-6

    # packaging
    @test carbonation(bt) ≈ 2.4u"vols" rtol = 1e-6
    @test abv(bt) > abv(fe)
    # BrewingFormulas ignores the small change of volume due to the priming alcohol
    @test priming_mass(q[:bottles], fe) ≈
          priming_sugar(CornSugar(), volume(fe), 2.4u"vols", 20u"°C") rtol = 1e-2
    forced = Package(carbonation = 2.4u"vols", sugar = nothing)
    @test priming_mass(forced, fe) == 0u"g"
    q[:bottles] = forced
    @test abv(brew(q)[:bottles, :out]) ≈ abv(fe)

    @test products(res, q) == Dict(:bottles => bt)

    # other models
    @test ibu(brew(single_batch(); models = (bitterness = Rager(),))[:boil, :out]) != ibu(bo)
end

@testset "Quiver construction" begin
    q = single_batch()
    @test_throws ArgumentError add!(q, :boil, Boil())
    @test_throws ArgumentError connect!(q, :bottles => :strike)          # into a Source
    @test_throws ArgumentError connect!(q, :bottles => :mashtun)         # a cycle
    @test_throws ArgumentError connect!(q, :boil => :boil)
    @test_throws ArgumentError connect!(q, :mashtun => :boil)            # no :out port
    @test_throws ArgumentError connect!(q, (:mashtun, :running3) => :boil)
    @test_throws ArgumentError connect!(q, :nowhere => :boil)
    # replacing the mash tun by one without a second running breaks a transfer
    @test_throws ArgumentError q[:mashtun] = MashTun(grains = [pale => 4u"kg"])
    @test successors(q, :mashtun) == [:boil]
    @test predecessors(q, :boil) == [:mashtun]
    @test descendants(q, :boil) == [:boil, :fermentor, :bottles]
    @test length(transfers(q)) == 5

    disconnect!(q, :fermentor => :bottles)
    @test isempty(successors(q, :fermentor))
    remove!(q, :bottles)
    @test !haskey(q, :bottles)

    # taking more than available
    q2 = Quiver()
    add!(q2, :w, Source(water(10u"L")))
    add!(q2, :a, Mix()); add!(q2, :b, Mix())
    connect!(q2, :w => :a; amount = 6u"L")
    connect!(q2, :w => :b; amount = 6u"L")
    @test_throws ArgumentError brew(q2)

    # explicit amounts, the rest, and leftovers
    q3 = Quiver()
    add!(q3, :w, Source(water(10u"L")))
    add!(q3, :a, Mix()); add!(q3, :b, Mix()); add!(q3, :c, Mix())
    connect!(q3, :w => :a; amount = 4u"L")
    connect!(q3, :w => :b; amount = 0.1)
    connect!(q3, :w => :c)
    r3 = brew(q3)
    @test volume(r3[:a, :out]) ≈ 4u"L"
    @test volume(r3[:b, :out]) ≈ 1u"L"
    @test volume(r3[:c, :out]) ≈ 5u"L"
    @test isempty(r3[:w].leftovers)
    disconnect!(q3, :w => :c)
    @test volume(brew(q3)[:w].leftovers[:out]) ≈ 5u"L"

    # transfers of volumes from an empty port take empty liquors
    q4 = Quiver()
    add!(q4, :w, Source(zero(Liquor)))
    add!(q4, :a, Mix()); add!(q4, :b, Mix())
    connect!(q4, :w => :a; amount = 1u"L")
    connect!(q4, :w => :b; amount = 1u"L")
    r4 = brew(q4)
    @test iszero(r4[:a, :out]) && iszero(r4[:b, :out])

    # the order of construction is kept after removing a process
    q5 = Quiver()
    add!(q5, :w, Source(water(10u"L")))
    for n in (:b, :c, :d, :e)
        add!(q5, n, Mix())
        connect!(q5, :w => n; amount = 0.25)
    end
    remove!(q5, :b)
    @test nodes(q5) == [:w, :c, :d, :e]
    add!(q5, :b, Mix())
    @test nodes(q5) == [:w, :c, :d, :e, :b]
    q5[:c] = Mix()                                  # replacing keeps the place
    @test nodes(q5) == [:w, :c, :d, :e, :b]
end

@testset "Rebrew" begin
    q = single_batch()
    res = brew(q)
    q[:fermentor] = Ferment(culture = ale, attenuation = 80u"percent", loss = 1u"L")
    rebrew!(res, q, :fermentor)
    fresh = brew(q)
    for n in nodes(q), (p, l) in fresh[n].outputs
        @test res[n, p] ≈ l
    end
    @test apparent_attenuation(res[:fermentor, :out]) ≈ 80u"percent"

    # changes of the structure: a rebrew must match a fresh brew
    function same(res, q)
        fresh = brew(q)
        Set(keys(res.nodes)) == Set(keys(fresh.nodes)) || return false
        Set(keys(res.flows)) == Set(keys(fresh.flows)) || return false
        res.order == fresh.order || return false
        all(res[n, p] ≈ l for n in nodes(q) for (p, l) in fresh[n].outputs) &&
            all(res[n].leftovers == fresh[n].leftovers || keys(res[n].leftovers) ==
                keys(fresh[n].leftovers) && all(res[n].leftovers[k] ≈ fresh[n].leftovers[k]
                                                for k in keys(fresh[n].leftovers))
                for n in nodes(q))
    end
    q = Quiver()
    add!(q, :w, Source(water(10u"L")))
    for n in (:a, :b, :c)
        add!(q, n, Mix())
    end
    connect!(q, :w => :a; amount = 2u"L")
    connect!(q, :w => :b; amount = 3u"L")
    connect!(q, :w => :c)
    add!(q, :blend, Mix())
    connect!(q, :a => :blend); connect!(q, :c => :blend)
    res = brew(q)
    @test volume(res[:c, :out]) ≈ 5u"L"

    # disconnecting: the destination is emptied, the source keeps a leftover
    disconnect!(q, :w => :c)
    rebrew!(res, q, :blend)                         # the change is found from the flows
    @test iszero(res[:c, :out])
    @test volume(res[:blend, :out]) ≈ 2u"L"
    @test !haskey(res.flows, (:w, :c))
    @test same(res, q)

    # connecting from a process that did not change
    connect!(q, :b => :blend)
    rebrew!(res, q, :blend)
    @test volume(res[:blend, :out]) ≈ 5u"L"
    @test same(res, q)

    # a new transfer along an existing edge
    connect!(q, :w => :c; amount = 1u"L")
    connect!(q, :w => :c)
    rebrew!(res, q, :c)
    @test volume(res[:c, :out]) ≈ 5u"L"
    @test same(res, q)

    # adding and removing processes
    add!(q, :d, Mix())
    connect!(q, :blend => :d; amount = 0.5)
    remove!(q, :a)
    rebrew!(res, q, :d)
    @test !haskey(res.nodes, :a)
    @test volume(res[:d, :out]) ≈ 5u"L"            # half of 3 L from :b and 7 L from :c
    @test same(res, q)
    @test_throws ArgumentError rebrew!(res, q, :a)
end

# Figure 1 of the BrewQuiver notes: the joint production of Fuller's Barley Wine, ESB,
# Pale Ale and Bitter, by parti-gyle from two mashes into three boils and fermentors.
function fullers()
    q = Quiver()
    for (i, grains) in enumerate(([pale => 40u"kg", crystal => 3u"kg"],
                                  [pale => 35u"kg", sugar => 0u"kg"]))
        add!(q, Symbol(:strike, i), Source(water(110u"L"; temperature = 75u"°C")))
        add!(q, Symbol(:mash, i), MashTun(grains = filter(p -> p.second > 0u"kg", grains),
                                          sparge = [80u"L", 80u"L"]))
        connect!(q, Symbol(:strike, i) => Symbol(:mash, i))
    end
    for i in 1:3
        add!(q, Symbol(:boil, i), Boil(time = 90u"minute", evaporation = 8u"L/hr",
                                       hops = [goldings => (500 - 120i) * u"g" => 90u"minute"],
                                       fermentables = i == 1 ? [sugar => 4u"kg"] : []))
        add!(q, Symbol(:fermentor, i), Ferment(culture = ale))
        connect!(q, Symbol(:boil, i) => Symbol(:fermentor, i))
        # the i-th runnings of both mashes go to the i-th boil
        connect!(q, (:mash1, Symbol(:running, i)) => Symbol(:boil, i))
        connect!(q, (:mash2, Symbol(:running, i)) => Symbol(:boil, i))
    end
    for beer in (:barley_wine, :esb, :pale_ale, :bitter)
        add!(q, beer, Mix())
    end
    connect!(q, :fermentor1 => :barley_wine; amount = 0.5)
    connect!(q, :fermentor1 => :esb)
    connect!(q, :fermentor2 => :esb; amount = 0.4)
    connect!(q, :fermentor2 => :pale_ale)
    connect!(q, :fermentor3 => :pale_ale; amount = 0.3)
    connect!(q, :fermentor3 => :bitter)
    return q
end

@testset "Parti-gyle (Fuller's)" begin
    q = fullers()
    res = brew(q)
    og(n) = original_gravity(res[n, :out])

    # the runnings get weaker, and so do the boils
    @test gravity(res[:boil1, :out]) > gravity(res[:boil2, :out]) > gravity(res[:boil3, :out])
    @test og(:barley_wine) > og(:esb) > og(:pale_ale) > og(:bitter)
    @test og(:barley_wine) ≈ gravity(res[:boil1, :out])
    @test og(:bitter) ≈ gravity(res[:boil3, :out])
    @test abv(res[:barley_wine, :out]) > abv(res[:esb, :out]) > abv(res[:bitter, :out])

    # a blend is the exact mixture of its parts
    esb = res[:esb, :out]
    @test esb ≈ 0.5 * res[:fermentor1, :out] + 0.4 * res[:fermentor2, :out]
    @test volume(res[:barley_wine, :out]) ≈ 0.5 * volume(res[:fermentor1, :out])

    @test Set(keys(products(res, q))) == Set([:barley_wine, :esb, :pale_ale, :bitter])

    # conservation over the whole quiver: whatever is not transferred is left over at some
    # port (the products included), so the leftovers account for everything
    ends = [l for n in nodes(q) for l in values(res[n].leftovers)]
    @test all(l -> any(e -> e === l, ends), values(products(res, q)))
    total(f) = sum(f, ends)

    # water: strike and sparge water, plus the moisture of the grains, minus evaporation
    moisture = sum(a.amount * a.ingredient.moisture for m in (:mash1, :mash2) for a in q[m].grains)
    boiled_off = sum(res[b].inputs[:in].water - res[b, :out].water - res[b, :loss].water
                     for b in (:boil1, :boil2, :boil3))
    @test total(l -> l.water) ≈ 2 * (110 + 80 + 80) * 0.998203u"kg" + moisture - boiled_off
    dissolved = sum(sum(q[m].conversion * potential_extract(a.amount, a.ingredient.yield;
                        moisture = a.ingredient.moisture) for a in q[m].grains)
                    for m in (:mash1, :mash2)) + 4u"kg"            # plus the boil sugar
    @test total(extract_equivalent) ≈ dissolved
    @test total(l -> l.color) ≈ sum(res[m, p].color for m in (:mash1, :mash2)
                                    for p in outports(q[m])) +
                                ustrip(u"lb", 4u"kg") * ustrip(u"°L", sugar.color)
    evaporated = sum(volume(res[b].inputs[:in] + BrewQuiver._dissolve(q[b].fermentables, 1.0)) -
                     volume(res[b, :out]) for b in (:boil1, :boil2, :boil3))
    @test evaporated ≈ 3 * 8u"L/hr" * 90u"minute" rtol = 1e-2
end

end
