# Figure 1 of the BrewQuiver notes: the joint production of Fuller's Barley Wine, ESB,
# Pale Ale and Bitter by parti-gyle. Two mashes are drained three times each, and the i-th
# runnings of both go to the i-th copper; the three fermented beers are racked and blended
# into four, aiming at the published strengths of Golden Pride (OG about 1.088), ESB (1.059),
# London Pride (1.047) and Chiswick Bitter (1.035).
#
# Run with `julia --project=. examples/fullers_partigyle.jl` from the package folder.
# (The amounts are illustrative, not Fuller's actual recipes.)

using Unitful, UnitfulBrewing, BrewingFormulas, BrewQuiver

pale     = Fermentable("Pale ale malt"; yield = 80u"percent", color = 3u"°L")
crystal  = Fermentable("Crystal 60"; yield = 74u"percent", color = 60u"°L")
invert   = Fermentable("Invert sugar"; kind = :sugar, yield = 100u"percent", color = 1u"SRM",
                       moisture = 0)
goldings = Hop("East Kent Goldings"; alpha = 5u"percent")
ale      = Culture("English ale"; attenuation = 72u"percent")

q = Quiver()
add!(q, :goldings, goldings => 1.5u"kg")
add!(q, :invert, invert => 4u"kg")

# three coppers, three fermenting vessels and three racking tanks
for i in 1:3
    add!(q, Symbol(:yeast, i), ale => 1)
    add!(q, Symbol(:kettle, i), Symbol(:wort, i), Symbol(:chilled, i); vessel = Symbol(:copper, i))
    add!(q, Symbol(:fermentor, i), Symbol(:beer, i); vessel = Symbol(:fv, i))
    add!(q, Symbol(:bright, i); vessel = Symbol(:tank, i))
end

# two mashes, each drained three times: the i-th runnings go to the i-th copper
for (m, grist) in enumerate(([pale => 70u"kg", crystal => 4u"kg"],
                             [pale => 60u"kg", crystal => 2u"kg"]))
    mash = Symbol(:mash, m)
    beds = [Symbol(:bed, m, :_, i) for i in 1:3]
    lots = [Symbol(:grist, m, :_, j) for j in eachindex(grist)]
    foreach((l, g) -> add!(q, l, g), lots, grist)
    add!(q, Symbol(:strike, m), water(190u"L"; temperature = 75u"°C"))
    add!(q, mash, beds...; vessel = Symbol(:mashtun, m))
    connect!(q, [Symbol(:strike, m); lots] => mash)
    connect!(q, mash => beds[1], MashRest(temperature = 66u"°C", time = 60u"minute"))
    for (i, v) in enumerate((nothing, 60u"L", 40u"L"))
        if v !== nothing                                    # sparge the grain bed
            add!(q, Symbol(:sparge, m, :_, i), water(v; temperature = 80u"°C"))
            connect!(q, beds[i - 1] => beds[i])              # the grain and what it holds
            connect!(q, Symbol(:sparge, m, :_, i) => beds[i])
        end
        connect!(q, beds[i] => Symbol(:kettle, i), Drain(absorption = 1.0u"L/kg"))
    end
end

# boils of decreasing gravity, fermentations, racking
for (i, hops) in enumerate((1100u"g", 270u"g", 130u"g"))
    kettle, wort, chilled, fv, beer, bright =
        (Symbol(x, i) for x in (:kettle, :wort, :chilled, :fermentor, :beer, :bright))
    connect!(q, :goldings => kettle, Transfer(hops; remaining = 90u"minute"))
    i == 1 && connect!(q, :invert => kettle)
    connect!(q, kettle => wort, Boil(time = 90u"minute", evaporation = 8u"L/hr"))
    connect!(q, wort => chilled, Chill(temperature = 18u"°C"))
    connect!(q, chilled => fv, Drain(retain = 2u"L"))
    connect!(q, Symbol(:yeast, i) => fv)
    connect!(q, fv => beer, Ferment(temperature = 19u"°C", time = 7u"d"))
    connect!(q, beer => bright, Drain(retain = 2u"L"))
end

# blending: four beers from three, merged at the nodes
add!(q, :barley_wine, :esb, :pale_ale, :bitter)
connect!(q, :bright1 => :esb, Transfer(6u"percent"))
connect!(q, :bright1 => :barley_wine)                       # the rest
connect!(q, :bright2 => :esb, Transfer(60u"percent"))
connect!(q, :bright2 => :pale_ale)
connect!(q, :bright3 => :pale_ale, Transfer(16u"percent"))
connect!(q, :bright3 => :bitter)

res = brew(q)
println("The beers:")
for beer in (:barley_wine, :esb, :pale_ale, :bitter)
    println("  ", rpad(":$beer", 14), res[beer])
end

# a more attenuative fermentation of the second gyle: only what depends on it is updated
q[:fermentor2 => :beer2] = Ferment(temperature = 19u"°C", time = 7u"d", attenuation = 80u"percent")
rebrew!(res, q, :fermentor2)
println("\nWith 80% attenuation in the second fermentor:")
for beer in (:barley_wine, :esb, :pale_ale, :bitter)
    println("  ", rpad(":$beer", 14), res[beer])
end

println("\nThe stages of each vessel:")
for (v, ns) in sort!(collect(vessels(q)))
    println("  ", rpad(v, 10), join(ns, " → "))
end
