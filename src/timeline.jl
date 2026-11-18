# The timeline of a quiver: when each node is filled, ready and emptied, and when each arrow
# runs, from the durations of the arrows (see `duration`), for a time × vessel view.

"""
    Interval(start, stop)

A time interval, in minutes from the start of the timeline.
"""
struct Interval
    start::MinQ
    stop::MinQ
end

"""
    Timeline

The result of [`timeline`](@ref): `s[label]` gives the times of a node, a NamedTuple
`(arrive, ready, leave)` (when its contents start arriving, when they are all in, and when
they are all gone, `nothing` for the nodes nothing leaves), and `s[source => destination]`
the [`Interval`](@ref)s of the arrows between two nodes, in their order. See also
[`makespan`](@ref), [`overlaps`](@ref) and [`vesselchart`](@ref).
"""
struct Timeline
    nodes::Dict{Symbol, @NamedTuple{arrive::MinQ, ready::MinQ, leave::Union{Nothing, MinQ}}}
    arrows::Dict{Tuple{Symbol, Symbol}, Vector{Interval}}
    order::Vector{Symbol}
    vessels::Dict{Symbol, Union{Nothing, Symbol}}
    sources::Set{Symbol}
end

Base.getindex(s::Timeline, label::Symbol) = s.nodes[label]
Base.getindex(s::Timeline, e::Pair{Symbol, Symbol}) = s.arrows[(e.first, e.second)]
Base.keys(s::Timeline) = s.order

_timed(a) = a isa Transfer && a.timing !== nothing
_rest(a) = a isa Transfer && a.amount === nothing

"""
    timeline(q::Quiver; start = 0u"minute", models = (;)) -> Timeline
    timeline(res::BrewResult, q::Quiver; start = 0u"minute") -> Timeline

The timeline of `q`: when the contents of each node arrive, are all in, and leave, and when
each arrow runs, from the [`duration`](@ref)s of the arrows, as early as the arrows allow
(the longest paths through the quiver).

- The lots (nodes without predecessors) are ready at `start`.
- A node is ready when all the streams reaching it (the arrows from other nodes) have
  arrived. The lots transferred to it without a timing arrive then, e.g. the yeast pitched
  when the wort is in the fermentor; with a timing ([`Remaining`](@ref), [`At`](@ref)), they
  arrive during the transformation that follows, e.g. a hop with 10 minutes of boil left.
- A transformation starts when its node is ready; the transfers of amounts and the drain
  too, and the transfers of the rest when those end, e.g. the grain bed is sparged after
  the first runnings are drained.

A drain without a `duration` from a vessel with a drain rate (see [`Vessel`](@ref)) takes
the time to drain the volume it moves, from the brew `res` of `q` (brewed with `models`
when not given). Vessels are not checked for being free: see [`overlaps`](@ref).
"""
function timeline(q::Quiver; start = 0u"minute", models::NamedTuple = (;))
    rated = any(a isa Drain && a.duration === nothing &&
                (v = _equipment_of(q, s); v !== nothing && v.drain_rate !== nothing)
                for (s, _, a) in arrows(q))
    return _timeline(q, rated ? brew(q; models) : nothing, start)
end
timeline(res::BrewResult, q::Quiver; start = 0u"minute") = _timeline(q, res, start)

function _timeline(q::Quiver, res, start)
    t0 = _minutes(start)
    # the duration of the arrow `a`, the `i`-th from `n` to `d`
    function dur(a, n, d, i)
        v = _equipment_of(q, n)
        a isa Drain && a.duration === nothing || return duration(_resolve(a, v))
        (v === nothing || v.drain_rate === nothing || res === nothing) && return 0.0u"minute"
        return uconvert(u"minute", volume(res[n => d][i].moved) / v.drain_rate)
    end
    iv = Dict{Tuple{Symbol, Symbol}, Vector{Union{Nothing, Interval}}}()
    for (s, d) in edge_labels(q.graph)
        iv[(s, d)] = fill(nothing, length(q[s => d]))
    end
    arrive = Dict{Symbol, MinQ}()
    ready = Dict{Symbol, MinQ}()
    order = nodes(q)
    sources = Set(n for n in order if _issource(q, n))
    for n in order
        # the arrival of the contents
        if n in sources
            arrive[n] = ready[n] = t0
        else
            # (what a transformation brings is there when it ends)
            streams = [a isa AbstractTransformation ? Interval(iv[(p, n)][i].stop, iv[(p, n)][i].stop) :
                       iv[(p, n)][i] for p in predecessors(q, n) if !(p in sources)
                       for (i, a) in enumerate(q[p => n]) if !_timed(a)]
            sready = isempty(streams) ? t0 : maximum(x.stop for x in streams)
            lots = Interval[]
            for p in predecessors(q, n), (i, a) in enumerate(q[p => n])
                p in sources && !_timed(a) || continue
                b = max(ready[p], sready)
                iv[(p, n)][i] = Interval(b, b + dur(a, p, n, i))
                push!(lots, iv[(p, n)][i])
            end
            ins = isempty(streams) ? lots : streams
            arrive[n] = isempty(ins) ? sready : minimum(x.start for x in ins)
            ready[n] = maximum((x.stop for x in lots); init = sready)
        end
        # the arrows leaving it (those from lots are set by their destinations)
        outs = _outgoing(q, n)
        transformation = nothing
        if !(n in sources)
            if length(outs) == 1 && outs[1][3] isa AbstractTransformation
                d, i, t = outs[1]
                transformation = Interval(ready[n], ready[n] + dur(t, n, d, i))
                iv[(n, d)][i] = transformation
            else
                first = [(d, i, a) for (d, i, a) in outs if !_rest(a) && !_timed(a)]
                for (d, i, a) in first
                    iv[(n, d)][i] = Interval(ready[n], ready[n] + dur(a, n, d, i))
                end
                b = maximum((iv[(n, d)][i].stop for (d, i, _) in first); init = ready[n])
                for (d, i, a) in outs
                    _rest(a) && !_timed(a) && (iv[(n, d)][i] = Interval(b, b + dur(a, n, d, i)))
                end
            end
        end
        # the timed arrivals, during the transformation that follows
        if transformation === nothing && length(outs) == 1 && outs[1][3] isa AbstractTransformation
            transformation = iv[(n, outs[1][1])][outs[1][2]]
        end
        for p in predecessors(q, n), (i, a) in enumerate(q[p => n])
            _timed(a) || continue
            if transformation === nothing
                b = ready[n]
            else
                total = transformation.stop - transformation.start
                b = transformation.start + total - duration_in(a.timing, total)
            end
            b = max(b, ready[p])
            iv[(p, n)][i] = Interval(b, b + dur(a, p, n, i))
        end
    end
    # when the contents leave
    times = Dict{Symbol, @NamedTuple{arrive::MinQ, ready::MinQ, leave::Union{Nothing, MinQ}}}()
    for n in order
        stops = [x.stop for d in successors(q, n) for x in iv[(n, d)] if x !== nothing]
        times[n] = (arrive = arrive[n], ready = ready[n],
                    leave = isempty(stops) ? nothing : maximum(stops))
    end
    arrows = Dict(k => Interval[something(x, Interval(ready[k[1]], ready[k[1]])) for x in v]
                  for (k, v) in iv)
    return Timeline(times, arrows, order, Dict(n => vessel(q, n) for n in order), sources)
end

"""
    makespan(s::Timeline)

The time from the start of the timeline to the end of its last arrow, or to the arrival of
its last contents.
"""
function makespan(s::Timeline)
    t0 = minimum(x.arrive for x in values(s.nodes))
    ends = [something(x.leave, x.ready) for x in values(s.nodes)]
    return maximum(ends) - t0
end

"""
    overlaps(s::Timeline)

The pairs of nodes in the same vessel whose times overlap, as a vector of
`(vessel, node, node)`: a vessel booked for two contents at once, e.g. one kettle for two
boils that are not connected by arrows.
"""
function overlaps(s::Timeline)
    out = Tuple{Symbol, Symbol, Symbol}[]
    by = Dict{Symbol, Vector{Symbol}}()
    for n in s.order
        v = s.vessels[n]
        v === nothing || push!(get!(by, v, Symbol[]), n)
    end
    for (v, ns) in by, (k, a) in enumerate(ns), b in ns[k + 1:end]
        ta, tb = s[a], s[b]
        ea, eb = something(ta.leave, ta.ready), something(tb.leave, tb.ready)
        # (stages that follow each other touch: one ends when the next is filled)
        ta.arrive < eb && tb.arrive < ea && push!(out, (v, a, b))
    end
    return out
end

# times as clock readings: "2:05", or "3d 14:20"
function _clock(t)
    m = round(Int, ustrip(u"minute", t))
    sign = m < 0 ? "-" : ""
    m = abs(m)
    d, r = divrem(m, 1440)
    h, mm = divrem(r, 60)
    return string(sign, d > 0 ? "$(d)d " : "", h, ":", lpad(mm, 2, '0'))
end

"""
    vesselchart([io], s::Timeline; from = start, to = end, width = 60)

Prints the timeline as a chart, a row per vessel, between the times `from` and `to`: `█`
where a transformation runs in the vessel, `▒` where it holds contents otherwise.
"""
vesselchart(s::Timeline; kwargs...) = vesselchart(stdout, s; kwargs...)
function vesselchart(io::IO, s::Timeline; from = nothing, to = nothing, width::Integer = 60)
    t0 = from === nothing ? minimum(x.arrive for x in values(s.nodes)) : _minutes(from)
    t1 = to === nothing ? t0 + makespan(s) : _minutes(to)
    t1 > t0 || throw(ArgumentError("the chart needs `to` after `from`"))
    step = (t1 - t0) / width
    cell(t) = clamp(floor(Int, (t - t0) / step) + 1, 1, width)
    vs = Symbol[]
    for n in s.order
        v = s.vessels[n]
        v === nothing || v in vs || push!(vs, v)
    end
    pad = maximum((length(string(v)) for v in vs); init = 6) + 1
    println(io, rpad("", pad + 2), rpad(_clock(t0), width ÷ 2), lpad(_clock(t1), width - width ÷ 2))
    for v in vs
        row = fill(' ', width)
        for n in s.order
            s.vessels[n] == v || continue
            x = s[n]
            a, b = x.arrive, something(x.leave, t1)
            (b < t0 || a > t1) && continue
            for k in cell(max(a, t0)):cell(min(b, t1) - step / 2)
                row[k] == '█' || (row[k] = '▒')
            end
            # the transformations leaving it
            for (key, ivs) in s.arrows
                key[1] == n || continue
                for iv in ivs
                    iv.stop > iv.start || continue
                    (iv.stop < t0 || iv.start > t1) && continue
                    s.vessels[key[2]] == v || continue
                    for k in cell(max(iv.start, t0)):cell(min(iv.stop, t1) - step / 2)
                        row[k] = '█'
                    end
                end
            end
        end
        println(io, "  ", rpad(string(v), pad), String(row))
    end
end

function Base.show(io::IO, ::MIME"text/plain", s::Timeline)
    print(io, "Timeline over ", _clock(makespan(s)), "\n    ", rpad("", 15),
          lpad("filled", 9), "   ", rpad("ready", 9), "   emptied")
    issource(n) = n in s.sources
    for (title, members) in _groups(s.order, n -> s.vessels[n], issource)
        title == "lots" && continue
        print(io, "\n  ", title)
        for n in members
            x = s[n]
            print(io, "\n    :", rpad(string(n), 14), lpad(_clock(x.arrive), 9), " → ",
                  rpad(_clock(x.ready), 9), " → ", x.leave === nothing ? "" : _clock(x.leave))
        end
    end
    o = overlaps(s)
    isempty(o) || print(io, "\n  overlapping in a vessel: ",
                        join(("$v (:$a, :$b)" for (v, a, b) in o), ", "))
end
