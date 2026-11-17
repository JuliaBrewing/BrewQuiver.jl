# BrewQuiver

The engine of the BrewQuiver brewing software, in pure Julia: the brewing process as a
**quiver**, a directed acyclic graph whose nodes are processes (mash, boil, fermentation,
packaging, blending, ...) and whose edges are transfers of liquors between them. Unlike a
linear recipe, a quiver can split and merge streams, as in parti-gyle brewing, double
mashes, or blending.

This package is still **under development** and not yet registered. It builds on
[UnitfulBrewing.jl](https://github.com/JuliaBrewing/UnitfulBrewing.jl) for the units and on
BrewingFormulas.jl for the formulas.

## Design

- **`Liquor`**, the state of a stream, holds *conserved* quantities only: the masses of
  water, extract, alcohol, iso-alpha acids and CO₂, color units (lb·°L) and the temperature.
  Mixing is `+` and splitting is scaling by a fraction, so both are exact. The total volume
  (at 20 °C), gravity, original gravity, ABV, IBU, color and carbonation are derived from
  them with BrewingFormulas. A wort's volume thus follows from its water and the extract
  dissolved from the grains, and a blend's original gravity from Balling's relations.
- **Processes** are subtypes of `AbstractProcess`, implementing
  `process(p, inputs, models)` and, when needed, `inports(p)` and `outports(p)`. Behavior
  is selected by dispatch, not by inheritance: `Source`, `MashTun` (single infusion with
  batch sparges, one output port per running), `Boil`, `Ferment`, `Package`, `Mix`.
- **`Quiver`** is a `MetaGraphsNext` graph labelled by symbols. Its edges carry
  `Transfer`s from an output port to an input port, each taking a volume, a fraction, or
  what is left. `connect!` refuses transfers that would create cycles.
- **`brew(q)`** computes the processes in topological order and returns a `BrewResult`.
  Whatever is not transferred is kept as a leftover, so extract, water and color are
  conserved over the whole quiver. `rebrew!(res, q, label)` recomputes only what is
  downstream of a changed process.
- **Models** (hop utilization, color, ABV, gravity conversion) come from BrewingFormulas and
  are chosen per brew: `brew(q; models = (bitterness = Rager(),))`.

## References

The formulas are those of BrewingFormulas, whose `REFERENCES.md` lists their sources. The
mass balance of fermentation and the original extract of fermented liquors follow Balling's
relations (J. De Clerck, *A Textbook of Brewing*, 1958; M. L. Hall, "Brew By the Numbers",
*Zymurgy*, Summer 1995; J. Šavel et al., *Kvasny prumysl* 66 (2020) 239–244).

## Example

```julia
using Unitful, UnitfulBrewing, BrewingFormulas, BrewQuiver

pale    = Fermentable("Pale ale malt"; yield = 80u"percent", color = 3u"°L")
crystal = Fermentable("Crystal 60"; yield = 74u"percent", color = 60u"°L")
cascade = Hop("Cascade"; alpha = 6u"percent")
us05    = Culture("US-05"; attenuation = 78u"percent")

q = Quiver()
add!(q, :strike, Source(water(16u"L")))
add!(q, :mashtun, MashTun(grains = [pale => 4.5u"kg", crystal => 0.3u"kg"], sparge = [14u"L"]))
add!(q, :boil, Boil(time = 60u"minute", loss = 1u"L",
                    hops = [cascade => 25u"g" => 60u"minute", cascade => 20u"g" => 10u"minute"]))
add!(q, :fermentor, Ferment(culture = us05, loss = 1u"L"))
add!(q, :bottles, Package(carbonation = 2.4u"vols"))
connect!(q, :strike => :mashtun)
connect!(q, (:mashtun, :running1) => :boil)
connect!(q, (:mashtun, :running2) => :boil)
connect!(q, :boil => :fermentor)
connect!(q, :fermentor => :bottles)

res = brew(q)
res[:bottles, :out]   # 21.5 L, OG 1.055, 5.96% ABV, 21 IBU, 7.5 SRM, 2.4 vols
```

See [`examples/fullers_partigyle.jl`](examples/fullers_partigyle.jl) for the parti-gyle of
Fuller's Barley Wine, ESB, Pale Ale and Bitter: two mashes, three boils and fermentors, and
four blended beers.
