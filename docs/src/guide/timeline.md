# Timeline

```@setup tl
using BrewQuiver; include(joinpath(pkgdir(BrewQuiver), "docs", "quivers.jl"))
q = single_batch()
```

Every arrow has a [`duration`](@ref): the `time` of a transformation (the mash rest, the
boil, the fermentation, the conditioning), and the `duration` of a transfer or a drain
(given, or from the drain rate of the vessel).

[`timeline`](@ref) places them **as early as the quiver allows**:

- a node is ready when all the streams reaching it have arrived;
- the lots without timing arrive then (the yeast is pitched when the wort is in);
- the timed additions arrive during the transformation that follows (a hop with 10 minutes
  of boil left);
- the transfers of the rest follow the drains (the grain bed is sparged after the first
  runnings).

It gives when each node is filled, ready and emptied:

```@example tl
s = timeline(q; start = 8u"hr")
```

```@example tl
s[:kettle].arrive, s[:kettle].ready, s[:kettle].leave      # in minutes from midnight
```

[`vesselchart`](@ref) draws the occupation of each vessel (filling `▒`, busy `█`):

```@example tl
vesselchart(s; to = 13u"hr")
```

[`makespan`](@ref) is the total time, and [`overlaps`](@ref) flags a vessel booked for two
contents at once, as when a parti-gyle sends two worts to the same copper:

```@example tl
(uconvert(u"d", makespan(s)), overlaps(s))
```

The timeline does not yet take shared resources into account (one brewer, one burner);
it is the earliest schedule the processes allow.
