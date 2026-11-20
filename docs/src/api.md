# API reference

```@meta
CurrentModule = BrewQuiver
```

```@docs
BrewQuiver
```

```@contents
Pages = ["api.md"]
Depth = 2:2
```

## Liquors

```@docs
Liquor
water
wort
mass
volume
gravity
original_gravity
carbonation
with_temperature
```

## Water chemistry

```@docs
Minerals
WaterProfile
profile
residual_alkalinity(::Liquor)
mash_ph(::Contents)
```

## Ingredients

```@docs
AbstractIngredient
Fermentable
Hop
Culture
Salt
Acid
HOP_FORM_FACTORS
```

## Contents and solids

```@docs
Contents
liquor
total_mass
grist
AbstractSolid
Portion
Residue
HopMatter
YeastCake
AbstractTiming
Remaining
At
```

## Arrows

```@docs
AbstractArrow
AbstractTransformation
transform
Transfer
Drain
MashRest
Boil
Chill
Ferment
Prime
Carbonate
priming_mass
```

## Quivers

```@docs
Quiver
Node
add!
connect!
disconnect!
remove!
rename!
Base.setindex!(::Quiver, ::Any, ::Symbol)
Base.setindex!(::Quiver, ::AbstractArrow, ::Pair{Symbol, Symbol})
Base.getindex(::Quiver, ::Pair{Symbol, Symbol}, ::Integer)
Base.setindex!(::Quiver, ::AbstractArrow, ::Pair{Symbol, Symbol}, ::Integer)
nodes
arrows
vessel
vessel!
vessels
predecessors
descendants
nodeview
```

## Equipment

```@docs
Vessel
equip!
unequip!
equipment
overfilled
```

## Brewing

```@docs
brew
rebrew!
BrewResult
NodeResult
ArrowResult
leftover
leftovers
released
products
```

## Timeline

```@docs
duration
timeline
Timeline
Interval
makespan
overlaps
vesselchart
```

## Targets and solving

```@docs
solve!
AbstractParameter
Amount
Setting
Target
Solution
```

## Provenance

```@docs
attribution
shares
```

## BeerJSON

```@docs
AbstractCalibration
NoCalibration
BrewhouseEfficiency
brewhouse_efficiency
recipe
recipes
```

## Files

```@docs
writejson
readjson
register_json_type
write_beerjson
```

## Ingredient library

```@docs
Library
stock
lookup
requirements
shortages
consume!
```

## Index

```@index
Pages = ["api.md"]
```
