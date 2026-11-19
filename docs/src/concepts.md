# Concepts

```@meta
CurrentModule = BrewQuiver
```

## Why a quiver

A recipe is a list: ingredients, a mash schedule, a boil schedule, a fermentation. It
describes one wort that becomes one beer. Many brews do not fit a list: a parti-gyle takes
several worts of decreasing strength from the same mash; a double mash runs the wort of one
mash through another; a brewery blends the beers of several fermentors into products of
its own. In all of them, *streams split and merge*.

BrewQuiver describes a brew as a **quiver**, the mathematicians' name for a directed
multigraph: a set of nodes, and arrows between them, with possibly several arrows joining
the same two nodes. Here the graph is acyclic, since brewing goes forward in time.

- A **node** is the contents of a vessel at a stage of the brew: the pale malt on the shelf,
  the strike water, the mash before and after its rest, the wort in the kettle before and
  after the boil, the beer in the fermentor.
- An **arrow** is a process taking contents from a node to another: a transfer, a drain,
  or a transformation (a mash rest, a boil, a fermentation, ...).

## Contents: conserved quantities

The state of a node is a [`Contents`](@ref): a [`Liquor`](@ref) and a list of solids. Both
hold **conserved quantities only**:

| Liquor field  | What it is                                    | Unit        |
|:--------------|:----------------------------------------------|:------------|
| `water`       | mass of water                                 | kg          |
| `extract`     | mass of dissolved extract (sugars, dextrins)  | kg          |
| `alcohol`     | mass of ethanol                               | kg          |
| `isoalpha`    | mass of iso-alpha acids                       | mg          |
| `color`       | color units                                   | lb·°L       |
| `co2`         | mass of dissolved CO₂                         | g           |
| `temperature` | temperature                                   | °C          |
| `minerals`    | dissolved ions ([`Minerals`](@ref))           | mg          |

Solids are ingredients as added ([`Portion`](@ref), with an amount and a timing), spent
grain ([`Residue`](@ref)), hop matter ([`HopMatter`](@ref)) and yeast ([`YeastCake`](@ref)).

Because every field is an amount, **mixing is addition** (`a + b`, with the temperature
of the mixture) and **splitting is scaling** (`0.3 * c`), and both are exact. Everything a
brewer usually reads off a wort, its volume at 20 °C, gravity, original gravity, ABV, IBU,
color, carbonation, is *derived* from these amounts with BrewingFormulas:

```@example concepts
using Unitful, UnitfulBrewing, BrewingFormulas, BrewQuiver

w = wort(20u"L", 1.050u"sg")
(volume(w), gravity(w), w.extract)
```

```@example concepts
half = 0.5 * w
(volume(half), gravity(half))
```

```@example concepts
diluted = w + water(5u"L")
gravity(diluted)
```

## Nodes

Nodes are labelled by symbols and added with [`add!`](@ref):

- **lots** have initial contents: an ingredient and an amount (`pale => 4.5u"kg"`,
  `us05 => 1` for a count), or a liquor such as `water(16u"L"; temperature = 75u"°C")`;
- **stages** start empty and are filled by arrows: `add!(q, :mash, :rested; vessel =
  :mashtun)`. The `vessel` tags the stages that live in the same vessel, for its
  [equipment](guide/equipment.md) and the [timeline](guide/timeline.md).

Whatever arrives at a node is mixed, so blending needs no special process.

## Arrows

Arrows are added with [`connect!`](@ref) and come in three kinds:

- [`Transfer`](@ref) moves a uniform part of the contents: a volume, a mass, a fraction, or
  what is left (`Transfer()`, the default). The ingredients it brings may have a timing:
  `Transfer(25u"g"; remaining = 10u"minute")` for a hop with 10 minutes of boil left.
- [`Drain`](@ref) moves the liquid only, leaving behind the solids, the liquid the grain
  absorbs and the liquid the vessel retains.
- **Transformations** ([`MashRest`](@ref), [`Boil`](@ref), [`Chill`](@ref),
  [`Ferment`](@ref), [`Prime`](@ref), [`Carbonate`](@ref)) turn all the contents of a node
  into the next stage of the vessel. They act on what is in the node: the grain mashed in,
  each hop for its own time, the culture pitched, the priming sugar. A transformation is
  the only arrow leaving its node.

Several arrows may join the same nodes, e.g. two additions from the same lot of hops.
Arrows that would create a cycle are refused.

## Brewing

[`brew`](@ref) computes all the nodes in topological order and returns a
[`BrewResult`](@ref): `res[label]` is the contents of a node, and `res[source =>
destination]` what its arrows did ([`ArrowResult`](@ref)s). What no arrow takes from a node is
its [`leftover`](@ref), and what the arrows release from the quiver (evaporated water, CO₂)
is [`released`](@ref). Over the whole quiver,

```math
\sum \text{initial contents} = \sum \text{leftovers} + \text{released},
```

which the tests check for every brew. The [`products`](@ref) are the nodes nothing leaves.

After a change of a node or an arrow, [`rebrew!`](@ref) recomputes only what is downstream
of it.

## Models

The derived quantities depend on models of BrewingFormulas: the conversion between gravity
and extract, hop utilization, color, ABV. The defaults are `DEFAULT_MODELS`; a brew can
choose others:

```julia
res = brew(q; models = (bitterness = Rager(), color = Daniels()))
```

The results then compute with the same models (`res.models`).

## Calibration

Real brewhouses do not convert all the potential extract. A [`MashRest`](@ref) has a
`conversion` (0.95 by default), and the losses of the quiver (absorption, dead spaces,
trub) follow from its arrows. A BeerJSON recipe can be calibrated to its stated brewhouse
efficiency with [`BrewhouseEfficiency`](@ref); see [A BeerJSON recipe](@ref).
