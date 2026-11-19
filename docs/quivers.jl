# Quivers for the examples of the documentation (included by the `@setup` blocks of the pages)

using Unitful, UnitfulBrewing, BrewingFormulas, BrewQuiver

const pale     = Fermentable("Pale ale malt"; yield = 80u"percent", color = 3u"°L")
const crystal  = Fermentable("Crystal 60"; yield = 74u"percent", color = 60u"°L", di_ph = 4.7)
const goldings = Hop("East Kent Goldings"; alpha = 5u"percent")
const ale      = Culture("English ale"; attenuation = 75u"percent")
const dextrose = Fermentable("Corn sugar"; kind = :sugar, yield = 100u"percent",
                             color = 0u"SRM", moisture = 0)

# the single batch of the tutorial: batch sparge, boil, fermentation, bottle conditioning
function single_batch()
    q = Quiver()
    add!(q, :pale, pale => 4.5u"kg")
    add!(q, :crystal, crystal => 0.3u"kg")
    add!(q, :goldings, goldings => 50u"g")
    add!(q, :yeast, ale => 1)
    add!(q, :strike_water, water(16u"L"; temperature = 75u"°C"))
    add!(q, :sparge_water, water(14u"L"; temperature = 80u"°C"))
    add!(q, :priming_sugar, dextrose => 110u"g")
    add!(q, :mash, :rested, :grain_bed; vessel = :mashtun)
    add!(q, :kettle, :wort, :chilled; vessel = :kettle)
    add!(q, :fermentor, :beer; vessel = :fermentor)
    add!(q, :bottling, :bottles; vessel = :bottles)
    equip!(q, :mashtun, Vessel(name = "Cooler", capacity = 36u"L", absorption = 1.0u"L/kg",
                               dead_space = 0.5u"L", drain_rate = 1u"L/minute"))
    equip!(q, :kettle, Vessel(name = "Kettle", capacity = 36u"L", evaporation = 4u"L/hr",
                              dead_space = 1u"L", drain_rate = 1.5u"L/minute"))
    equip!(q, :fermentor, Vessel(name = "Bucket", capacity = 30u"L", dead_space = 1u"L"))
    connect!(q, [:strike_water, :pale, :crystal] => :mash)
    connect!(q, :mash => :rested, MashRest(temperature = 67u"°C", time = 60u"minute"))
    connect!(q, :rested => :kettle, Drain())
    connect!(q, :rested => :grain_bed)
    connect!(q, :sparge_water => :grain_bed)
    connect!(q, :grain_bed => :kettle, Drain())
    connect!(q, :goldings => :kettle, Transfer(30u"g"; remaining = 60u"minute"))
    connect!(q, :goldings => :kettle, Transfer(20u"g"; remaining = 10u"minute"))
    connect!(q, :kettle => :wort, Boil(time = 60u"minute"))
    connect!(q, :wort => :chilled, Chill(temperature = 20u"°C", time = 25u"minute"))
    connect!(q, :chilled => :fermentor, Drain())
    connect!(q, :yeast => :fermentor)
    connect!(q, :fermentor => :beer, Ferment(temperature = 20u"°C", time = 14u"d"))
    connect!(q, :priming_sugar => :bottling)
    connect!(q, :beer => :bottling, Drain())
    connect!(q, :bottling => :bottles, Prime(sugar = CornSugar()))
    return q
end
