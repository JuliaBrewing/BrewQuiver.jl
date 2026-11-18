# Computing a quiver: the nodes are evaluated in topological order, each gathering its
# initial contents and what its incoming arrows bring, and passing them along its arrows.

"""
    NodeResult

The result of a node in a brew: its `contents` (the initial contents and all that arrived)
and the `leftover`, what no arrow took (spent grain, trub, yeast cake, the products).
"""
struct NodeResult
    contents::Contents
    leftover::Contents
end

"""
    ArrowResult

The result of an arrow in a brew: the contents it `moved` to its destination and what it
`released` from the quiver, a NamedTuple `(water, co2)` of masses.
"""
struct ArrowResult
    moved::Contents
    released::Released
end
ArrowResult(moved::Contents) = ArrowResult(moved, released_nothing())

"""
    BrewResult

The result of [`brew`](@ref): `res[label]` is the [`Contents`](@ref) of a node,
`res[source => destination]` the [`ArrowResult`](@ref)s of the arrows between two nodes, in
their order. See also [`leftover`](@ref), [`leftovers`](@ref), [`released`](@ref) and
[`products`](@ref).
"""
struct BrewResult{M <: NamedTuple}
    nodes::Dict{Symbol, NodeResult}
    arrows::Dict{Tuple{Symbol, Symbol}, Vector{ArrowResult}}
    order::Vector{Symbol}
    vessels::Dict{Symbol, Union{Nothing, Symbol}}
    models::M
end

Base.getindex(r::BrewResult, label::Symbol) = r.nodes[label].contents
Base.getindex(r::BrewResult, e::Pair{Symbol, Symbol}) = r.arrows[(e.first, e.second)]
Base.keys(r::BrewResult) = r.order

"""
    leftover(res::BrewResult, label)

What was left in the node `label`, taken by no arrow.
"""
leftover(r::BrewResult, label::Symbol) = r.nodes[label].leftover

"""
    leftovers(res::BrewResult)

The nonempty leftovers of all the nodes, as a `Dict` from label to contents: with what the
arrows released (see [`released`](@ref)), they account for all the initial contents.
"""
leftovers(r::BrewResult) =
    Dict(n => r.nodes[n].leftover for n in r.order if !iszero(r.nodes[n].leftover))

"""
    released(res::BrewResult)

The total released from the quiver by its arrows, as a NamedTuple `(water, co2)` of masses:
the water evaporated and the CO₂ escaped (net of the CO₂ taken in by forced carbonation).
"""
function released(r::BrewResult)
    w, c = 0.0u"kg", 0.0u"kg"
    for v in values(r.arrows), a in v
        w += a.released.water
        c += a.released.co2
    end
    return (water = w, co2 = c)
end

"""
    products(res::BrewResult, q::Quiver)

The contents of the nodes with no arrows leaving them, as a `Dict` from label to contents.
"""
products(r::BrewResult, q::Quiver) =
    Dict(n => r[n] for n in r.order if isempty(successors(q, n)))

"""
    brew(q::Quiver; models = (;))

Computes all the nodes and arrows of `q`, in topological order, with the models of
BrewingFormulas in `models` (a NamedTuple overriding [`DEFAULT_MODELS`](@ref), e.g.
`(bitterness = Rager(), color = Daniels())`). Returns a [`BrewResult`](@ref).
"""
function brew(q::Quiver; models::NamedTuple = (;))
    ms = merge(DEFAULT_MODELS, models)
    order = nodes(q)
    res = BrewResult(Dict{Symbol, NodeResult}(), Dict{Tuple{Symbol, Symbol}, Vector{ArrowResult}}(),
                     order, Dict{Symbol, Union{Nothing, Symbol}}(n => vessel(q, n) for n in order),
                     ms)
    for label in order
        _brew_node!(res, q, label)
    end
    return res
end

"""
    rebrew!(res::BrewResult, q::Quiver, label)

Updates `res` after a change of the node `label` of `q` (its initial contents) or of the
arrows leaving it, recomputing only `label` and the nodes downstream of it.

Other changes of the structure of `q` since `res` was computed are detected and recomputed
too: the nodes added, the sources and destinations of the arrows removed (by
[`disconnect!`](@ref) or [`remove!`](@ref)), and the sources of new arrows. Changes of
existing arrows are not detected, so give the label of their source.
"""
function rebrew!(res::BrewResult, q::Quiver, label::Symbol)
    haskey(q, label) || throw(ArgumentError("there is no node labelled :$label"))
    changed = Set([label])
    # nodes removed from the quiver
    for n in collect(keys(res.nodes))
        haskey(q, n) || delete!(res.nodes, n)
    end
    # arrows removed: drop their results, and recompute their sources (what is left in a
    # node changes) and destinations
    for (s, d) in collect(keys(res.arrows))
        if !(haskey(q, s) && haskey(q, d) && haskey(q.graph, s, d))
            delete!(res.arrows, (s, d))
            haskey(q, s) && push!(changed, s)
            haskey(q, d) && push!(changed, d)
        end
    end
    order = nodes(q)
    for n in order
        # nodes added
        haskey(res.nodes, n) || push!(changed, n)
        # arrows added: recompute their sources
        for d in outneighbor_labels(q.graph, n)
            a = get(res.arrows, (n, d), nothing)
            (a === nothing || length(a) != length(q[n => d])) && push!(changed, n)
        end
    end
    resize!(res.order, length(order))
    copyto!(res.order, order)
    empty!(res.vessels)
    for n in order
        res.vessels[n] = vessel(q, n)
    end
    stale = union((Set(descendants(q, n)) for n in changed)...)
    for n in order
        n in stale && _brew_node!(res, q, n)
    end
    return res
end

function _brew_node!(res::BrewResult, q::Quiver, label::Symbol)
    contents = q[label].initial
    for s in inneighbor_labels(q.graph, label)
        rs = get(res.arrows, (s, label), nothing)
        rs === nothing && error("missing the arrows from :$s to :$label")
        for r in rs
            contents += r.moved
        end
    end
    results, left = _pass(q, label, contents, res.models)
    for d in outneighbor_labels(q.graph, label)
        res.arrows[(label, d)] = [results[(d, i)] for i in eachindex(q[label => d])]
    end
    res.nodes[label] = NodeResult(contents, left)
    return res
end

# pass the contents of a node along its arrows; returns the results of the arrows, by
# (destination, index), and the leftover
function _pass(q, label, c::Contents, models)
    eq = models.gravity
    ves = _equipment_of(q, label)
    outs = [(d, i, _resolve(a, ves)) for (d, i, a) in _outgoing(q, label)]
    results = Dict{Tuple{Symbol, Int}, ArrowResult}()
    # a transformation takes everything
    if length(outs) == 1 && outs[1][3] isa AbstractTransformation
        d, i, t = outs[1]
        new, rel = transform(t, c, models)
        results[(d, i)] = ArrowResult(new, rel)
        return results, zero(Contents)
    end
    # transfers of amounts: uniform parts of the contents
    taken = 0.0
    for (d, i, a) in outs
        a isa Transfer || continue
        f = _fraction_of(a.amount, c, eq)
        f === nothing && continue
        results[(d, i)] = ArrowResult(with_timing(f * c, a.timing))
        taken += f
    end
    taken ≤ 1 + 1e-9 || throw(ArgumentError(
        "the transfers from :$label take $(round(100taken; digits = 1))% of its contents"))
    # (all taken, up to rounding errors: nothing is left)
    rest = taken ≥ 1 - 1e-12 ? zero(Contents) : (1 - taken) * c
    # the drain
    for (d, i, a) in outs
        a isa Drain || continue
        drained, rest = _drain(a, rest, eq)
        results[(d, i)] = ArrowResult(drained)
    end
    # transfers of the rest
    others = [(d, i, a) for (d, i, a) in outs if a isa Transfer && a.amount === nothing]
    isempty(others) && return results, rest
    for (d, i, a) in others
        results[(d, i)] = ArrowResult(with_timing((1 / length(others)) * rest, a.timing))
    end
    return results, zero(Contents)
end

"""
    overfilled(res::BrewResult, q::Quiver)

The nodes whose contents exceed the capacity of their [`Vessel`](@ref), as a vector of
NamedTuples `(node, vessel, volume, capacity)`. The volume of a mash includes the grain it
displaces (see `mash_volume`); volumes are at 20 °C.
"""
function overfilled(res::BrewResult, q::Quiver)
    out = @NamedTuple{node::Symbol, vessel::Symbol, volume::LQ, capacity::LQ}[]
    for n in res.order
        v = _equipment_of(q, n)
        (v === nothing || v.capacity === nothing) && continue
        c = res[n]
        vol = uconvert(u"L", mash_volume(volume(c; eq = res.models.gravity), grist(c)))
        vol > v.capacity && push!(out, (node = n, vessel = vessel(q, n), volume = vol,
                                        capacity = v.capacity))
    end
    return out
end
