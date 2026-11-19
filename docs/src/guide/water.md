# Water chemistry

```@setup water
using BrewQuiver; include(joinpath(pkgdir(BrewQuiver), "docs", "quivers.jl"))
```

Liquors carry their dissolved [`Minerals`](@ref): calcium, magnesium, sodium, chloride,
sulfate and alkalinity (as CaCO₃, negative once acids took more than it), conserved like
everything else. They mix, drain with the liquor, and concentrate in the boil.

## Water profiles

A water is given by its [`WaterProfile`](@ref), the concentrations of its ions, as in a
water report:

```@example water
tap = WaterProfile(calcium = 30u"mg/L", magnesium = 8u"mg/L", sodium = 12u"mg/L",
                   chloride = 25u"mg/L", sulfate = 30u"mg/L", bicarbonate = 120u"mg/L")
w = water(16u"L"; temperature = 75u"°C", profile = tap)
w.minerals
```

[`profile`](@ref) gives the profile of any liquor or contents, and
[`residual_alkalinity`](@ref) Kolbach's residual alkalinity:

```@example water
(profile(w), residual_alkalinity(w))
```

## Salts and acids

[`Salt`](@ref)s and [`Acid`](@ref)s are lots that **dissolve where they are added**:
their ions go to the liquor, and an acid takes alkalinity. The salts and acids are those of
BrewingFormulas (`Gypsum`, `CalciumChloride`, `EpsomSalt`, `MagnesiumChloride`,
`TableSalt`, `BakingSoda`, `Chalk`, `SlakedLime`, `LacticAcid`, `PhosphoricAcid`).

```@example water
q = single_batch()
q[:strike_water] = water(16u"L"; temperature = 75u"°C", profile = tap)
add!(q, :gypsum, Salt(Gypsum()) => 4u"g")
add!(q, :lactic, Acid(LacticAcid()) => 1u"mL")
connect!(q, [:gypsum, :lactic] => :mash)
res = brew(q)
profile(res[:wort])
```

## Mash pH

[`mash_ph`](@ref) estimates the pH of the mash of a node *before its mash rest*, by the
balance of charges of BrewingFormulas' `mash_ph`: the distilled water pH and buffering of
each grain, and the residual alkalinity and volume of the water.

```@example water
mash_ph(res[:mash])
```

Pale base malt is taken with a distilled water pH of 5.7 and a buffering of 40 mEq/(kg·pH).
Crystal and roasted malts lower the pH much more, so they need their own distilled water
pH (`Fermentable(...; di_ph = 4.7)`, with an optional `buffering`); a grain darker than
8 SRM without one is taken as base malt, with a warning.

## From BeerJSON

The importer reads the water additions of a recipe as the profile of its water, its "water
agent" additions as salts and acids, and the distilled water pH of fermentable records.
