# Extending BrewQuiver

```@setup ext
using BrewQuiver; include(joinpath(pkgdir(BrewQuiver), "docs", "quivers.jl"))
```

## A new transformation

A transformation is a subtype of [`AbstractTransformation`](@ref) that implements
[`transform`](@ref)`(t, contents, models) -> (contents, released)`: the contents after it,
and what it released from the quiver, as a NamedTuple `(water, co2)` of masses (negative
for what it took in). With a `time` field, its [`duration`](@ref) is that time; otherwise
it implements `duration`.

A cold crash, which only cools the beer:

```@example ext
struct ColdCrash <: BrewQuiver.AbstractTransformation
    temperature::typeof(1.0u"°C")
    time::typeof(1.0u"d")
end
ColdCrash(; temperature = 2u"°C", time = 2u"d") = ColdCrash(temperature, time)

BrewQuiver.transform(t::ColdCrash, c::Contents, models) =
    (with_temperature(c, t.temperature), (water = 0.0u"kg", co2 = 0.0u"kg"))

q = single_batch()
add!(q, :crashed; vessel = :fermentor)
disconnect!(q, :beer => :bottling)
connect!(q, :beer => :crashed, ColdCrash())
connect!(q, :crashed => :bottling, Drain())
liquor(brew(q)[:crashed]).temperature
```

The transformation should conserve mass: what it changes in the contents is either
released (`water`, `co2`) or moved within them (extract to alcohol, ...). The tests of
BrewQuiver check the balance of the whole quiver with `leftovers` and `released`; do the
same for a new arrow.

The formulas a transformation needs belong in
[BrewingFormulas.jl](https://github.com/JuliaBrewing/BrewingFormulas.jl), with their
references.

## Saving it

The files of quivers write the arrows they know. A new type is registered with
[`BrewQuiver.register_json_type`](@ref): its values are then written as objects of their
fields, and rebuilt with its constructor of all the fields, in order.

```@example ext
BrewQuiver.register_json_type(ColdCrash)
path = writejson(tempname() * ".json", q)
readjson(Quiver, path)[:crashed => :bottling]
```

## Models

The models of a brew are those of BrewingFormulas (`brew(q; models = (bitterness =
Rager(),))`). A new model is a new subtype there, with its methods; the quiver uses it as
soon as it is passed to `brew`.

## Timings and solids

New timings ([`AbstractTiming`](@ref)) and solids ([`AbstractSolid`](@ref)) are possible,
but touch the internals of the arrows (how they mix, split and dissolve); open an issue
first.
