# Figure 1 of the BrewQuiver notes: the joint production of Fuller's Barley Wine, ESB,
# Pale Ale and Bitter by parti-gyle. The runnings of two mashes are split among three
# boils of decreasing gravity, and the three fermented beers are blended into four.
#
# Run with `julia --project=. examples/fullers_partigyle.jl` from the package folder.
# (The amounts are illustrative, not Fuller's actual recipes.)

using Unitful, UnitfulBrewing, BrewingFormulas, BrewQuiver

pale     = Fermentable("Pale ale malt"; yield = 80u"percent", color = 3u"°L")
crystal  = Fermentable("Crystal 60"; yield = 74u"percent", color = 60u"°L")
sugar    = Fermentable("Invert sugar"; kind = :sugar, yield = 100u"percent", color = 1u"SRM",
                       moisture = 0)
goldings = Hop("East Kent Goldings"; alpha = 5u"percent")
ale      = Culture("English ale"; attenuation = 75u"percent")

q = Quiver()

# two mashes, each with a strike and two batch sparges: three runnings each
add!(q, :strike1, Source(water(160u"L"; temperature = 75u"°C")))
add!(q, :strike2, Source(water(160u"L"; temperature = 75u"°C")))
add!(q, :mash1, MashTun(grains = [pale => 70u"kg", crystal => 4u"kg"], sparge = [55u"L", 50u"L"]))
add!(q, :mash2, MashTun(grains = [pale => 60u"kg", crystal => 2u"kg"], sparge = [55u"L", 50u"L"]))
connect!(q, :strike1 => :mash1)
connect!(q, :strike2 => :mash2)

# the i-th runnings of both mashes go to the i-th boil, which goes to the i-th fermentor
for i in 1:3
    boil, fermentor = Symbol(:boil, i), Symbol(:fermentor, i)
    add!(q, boil, Boil(time = 90u"minute", evaporation = 8u"L/hr",
                       hops = [goldings => (1000 - 250i) * u"g" => 90u"minute"],
                       fermentables = i == 1 ? [sugar => 4u"kg"] : []))
    add!(q, fermentor, Ferment(culture = ale))
    connect!(q, (:mash1, Symbol(:running, i)) => boil)
    connect!(q, (:mash2, Symbol(:running, i)) => boil)
    connect!(q, boil => fermentor)
end

# blending the three beers into four
for beer in (:barley_wine, :esb, :pale_ale, :bitter)
    add!(q, beer, Mix())
end
connect!(q, :fermentor1 => :barley_wine; amount = 0.75)  # 75% of fermentor 1
connect!(q, :fermentor1 => :esb)                         # the rest of it
connect!(q, :fermentor2 => :esb; amount = 0.7)
connect!(q, :fermentor2 => :pale_ale)
connect!(q, :fermentor3 => :pale_ale; amount = 0.5)
connect!(q, :fermentor3 => :bitter)

display(q); println("\n")
res = brew(q)
display(res); println("\n")

# change the attenuation of the second fermentation and update only what depends on it
q[:fermentor2] = Ferment(culture = ale, attenuation = 80u"percent")
rebrew!(res, q, :fermentor2)
println("With 80% attenuation in fermentor 2:")
for beer in (:barley_wine, :esb, :pale_ale, :bitter)
    println("  ", rpad(":$beer", 14), res[beer, :out])
end
