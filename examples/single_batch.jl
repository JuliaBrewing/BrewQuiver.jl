# A single batch: mash with a batch sparge, boil, fermentation and bottle conditioning.
#
# Run with `julia --project=. examples/single_batch.jl` from the package folder.

using Unitful, UnitfulBrewing, BrewingFormulas, BrewQuiver

pale     = Fermentable("Pale ale malt"; yield = 80u"percent", color = 3u"°L")
crystal  = Fermentable("Crystal 60"; yield = 74u"percent", color = 60u"°L")
goldings = Hop("East Kent Goldings"; alpha = 5u"percent")
ale      = Culture("English ale"; attenuation = 75u"percent")
dextrose = Fermentable("Corn sugar"; kind = :sugar, yield = 100u"percent", color = 0u"SRM",
                       moisture = 0)

q = Quiver()

# lots on the shelf: the sources of the quiver
add!(q, :pale, pale => 4.5u"kg")
add!(q, :crystal, crystal => 0.3u"kg")
add!(q, :goldings, goldings => 50u"g")
add!(q, :yeast, ale => 1)                                   # one pack
add!(q, :strike_water, water(16u"L"; temperature = 75u"°C"))
add!(q, :sparge_water, water(14u"L"; temperature = 80u"°C"))
add!(q, :priming_sugar, dextrose => 110u"g")

# the successive stages in each vessel
add!(q, :mash, :rested, :grain_bed; vessel = :mashtun)
add!(q, :kettle, :wort, :chilled; vessel = :kettle)
add!(q, :fermentor, :beer; vessel = :fermentor)
add!(q, :bottling, :bottles; vessel = :bottles)

# mash and batch sparge
connect!(q, [:strike_water, :pale, :crystal] => :mash)
connect!(q, :mash => :rested, MashRest(temperature = 67u"°C", time = 60u"minute"))
connect!(q, :rested => :kettle, Drain(absorption = 1.0u"L/kg", duration = 15u"minute"))   # first runnings
connect!(q, :rested => :grain_bed)                                 # grain and absorbed wort
connect!(q, :sparge_water => :grain_bed)
connect!(q, :grain_bed => :kettle, Drain(absorption = 1.0u"L/kg", duration = 20u"minute")) # second runnings

# boil, with the hops arriving during it
connect!(q, :goldings => :kettle, Transfer(30u"g"; remaining = 60u"minute"))
connect!(q, :goldings => :kettle, Transfer(20u"g"; remaining = 10u"minute"))
connect!(q, :kettle => :wort, Boil(time = 60u"minute", evaporation = 4u"L/hr"))
connect!(q, :wort => :chilled, Chill(temperature = 20u"°C", time = 25u"minute"))

# knock-out, fermentation, bottling
connect!(q, :chilled => :fermentor, Drain(retain = 1u"L", duration = 15u"minute"))   # trub and hops stay
connect!(q, :yeast => :fermentor)
connect!(q, :fermentor => :beer, Ferment(temperature = 20u"°C", time = 14u"d"))
connect!(q, [:priming_sugar] => :bottling)
connect!(q, :beer => :bottling, Drain(retain = 1u"L"))
connect!(q, :bottling => :bottles, Prime(sugar = CornSugar()))

display(q); println("\n")
res = brew(q)
display(res); println("\n")

println("The bottles:")
display(res[:bottles]); println("\n")
println("Left in the vessels:")
for (n, l) in leftovers(res)
    n === :bottles || println("  :", rpad(n, 12), l)
end
println("Released: ", map(x -> round(u"kg", x; digits = 2), released(res)))
println("Priming sugar for 2.4 vols: ", round(u"g", priming_mass(res[:beer => :bottling][1].moved, 2.4u"vols"); digits = 1))

# the schedule of the brew, starting at 8:00: the stages of each vessel, and a chart of the
# brew day
println()
sched = schedule(q; start = 8u"hr")
display(sched); println("\n")
gantt(sched; to = 13u"hr")
