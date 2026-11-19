# The quiver: a directed acyclic multigraph whose nodes are the contents of vessels at the
# stages of the brewing, and whose arrows are the processes between them.

"""
    Node

A node of a [`Quiver`](@ref): its `initial` contents (the lots on the shelf, the water;
empty for the stages filled by arrows), the `vessel` it is in, if given, and `view`, free
data for interfaces (a position, a color, ...; see [`nodeview`](@ref)), kept by the files of
quivers.
"""
struct Node
    initial::Contents
    vessel::Union{Nothing, Symbol}
    # free data for interfaces (a position, a color, ...), kept by the files of quivers
    view::Dict{String, Any}
end
Node(initial::Contents, vessel) = Node(initial, vessel, Dict{String, Any}())

"""
    Quiver()

An empty quiver: the brewing process as a directed acyclic graph whose nodes, labelled by
symbols, are the [`Contents`](@ref) of vessels at the stages of the brewing, and whose
arrows ([`AbstractArrow`](@ref)) are the processes between them: transfers, drains and
transformations. Several arrows may join the same two nodes.

Build it with [`add!`](@ref) and [`connect!`](@ref), and compute it with [`brew`](@ref).
"""
struct Quiver{G}
    graph::G
    # the rank of each node in the order of construction, for a stable topological order
    # (the codes of the vertices change when a vertex is removed, so they can't be used)
    rank::Dict{Symbol, Int}
    added::Base.RefValue{Int}
    # the equipment of the vessels, by name
    equipment::Dict{Symbol, Vessel}
end

Quiver() = Quiver(MetaGraph(DiGraph(); label_type = Symbol, vertex_data_type = Node,
                            edge_data_type = Vector{AbstractArrow}, graph_data = nothing),
                  Dict{Symbol, Int}(), Ref(0), Dict{Symbol, Vessel}())

Base.haskey(q::Quiver, label::Symbol) = haskey(q.graph, label)
Base.getindex(q::Quiver, label::Symbol) = q.graph[label]
Base.getindex(q::Quiver, e::Pair{Symbol, Symbol}) = q.graph[e.first, e.second]

"""
    vessel(q::Quiver, label)

The vessel of the node `label`, or `nothing`.
"""
vessel(q::Quiver, label::Symbol) = q[label].vessel

"""
    equip!(q::Quiver, vessel::Symbol, equipment::Vessel)

Attaches the `equipment` to the `vessel` of `q`: the arrows leaving the nodes in that
vessel take from it what they do not give themselves (a [`Drain`](@ref) its absorption,
dead space and drain rate, a [`Boil`](@ref) its evaporation rate), and its capacity is
checked by [`overfilled`](@ref). After a change of equipment, brew again.

```julia
equip!(q, :kettle, Vessel(capacity = 40u"L", dead_space = 1.5u"L", evaporation = 4u"L/hr",
                          drain_rate = 1u"L/minute"))
```
"""
function equip!(q::Quiver, name::Symbol, v::Vessel)
    q.equipment[name] = v
    return q
end

"""
    equipment(q::Quiver, vessel::Symbol)

The [`Vessel`](@ref) attached to `vessel` with [`equip!`](@ref), or `nothing`.
"""
equipment(q::Quiver, name::Symbol) = get(q.equipment, name, nothing)

# the equipment of the vessel of the node `label`, or `nothing`
_equipment_of(q::Quiver, label::Symbol) =
    (v = vessel(q, label); v === nothing ? nothing : equipment(q, v))

_set!(q::Quiver, label::Symbol, n::Node) =
    (haskey(q, label) || (q.rank[label] = (q.added[] += 1)); q.graph[label] = n; q)

_contents(x::Contents) = x
_contents(x::Liquor) = Contents(x)
_contents(x::Pair{<:AbstractIngredient}) = Contents(x)
_contents(x) = throw(ArgumentError("the initial contents of a node are `Contents`, a liquor " *
                                   "or `ingredient => amount`, not $x"))

"""
    add!(q::Quiver, label, initial; vessel = nothing)
    add!(q::Quiver, labels::Symbol...; vessel = nothing)

Adds to `q` a node with `initial` contents (a lot: a liquor such as `water(16u"L")`, or
`ingredient => amount`), or empty nodes, to be filled by arrows, with the given `labels`.
They are in `vessel`, if given.
"""
function add!(q::Quiver, label::Symbol, initial; vessel::Union{Nothing, Symbol} = nothing)
    haskey(q, label) && throw(ArgumentError("there is already a node labelled :$label"))
    return _set!(q, label, Node(_contents(initial), vessel))
end
function add!(q::Quiver, labels::Symbol...; vessel::Union{Nothing, Symbol} = nothing)
    for l in labels
        add!(q, l, Contents(); vessel)
    end
    return q
end

"""
    q[label] = initial

Replaces the initial contents of the node `label`, keeping its vessel.
"""
function Base.setindex!(q::Quiver, initial, label::Symbol)
    haskey(q, label) || throw(ArgumentError("there is no node labelled :$label; use `add!`"))
    return _set!(q, label, Node(_contents(initial), vessel(q, label), q[label].view))
end

"""
    q[source => destination] = arrow

Replaces the arrows from `source` to `destination` by `arrow`.
"""
function Base.setindex!(q::Quiver, a::AbstractArrow, e::Pair{Symbol, Symbol})
    haskey(q.graph, e.first, e.second) ||
        throw(ArgumentError("there is no arrow from :$(e.first) to :$(e.second); use `connect!`"))
    _check_arrows(q, e.first, [a; [b for d in successors(q, e.first) if d != e.second
                                   for b in q[e.first => d]]])
    q.graph[e.first, e.second] = AbstractArrow[a]
    return q
end

# the `i`-th arrow from `s` to `d`, checked
function _arrow_index(q::Quiver, e::Pair{Symbol, Symbol}, i::Integer)
    haskey(q.graph, e.first, e.second) ||
        throw(ArgumentError("there is no arrow from :$(e.first) to :$(e.second)"))
    n = length(q.graph[e.first, e.second])
    1 ≤ i ≤ n || throw(ArgumentError("there are $n arrows from :$(e.first) to :$(e.second), not $i"))
    return i
end

"""
    q[source => destination, i]

The `i`-th of the arrows from `source` to `destination`, in the order they were connected.
"""
Base.getindex(q::Quiver, e::Pair{Symbol, Symbol}, i::Integer) = (_arrow_index(q, e, i); q[e][i])

"""
    q[source => destination, i] = arrow

Replaces the `i`-th of the arrows from `source` to `destination` by `arrow`, keeping the
others in order (e.g. the second of two hop additions from the same lot).
"""
function Base.setindex!(q::Quiver, a::AbstractArrow, e::Pair{Symbol, Symbol}, i::Integer)
    _arrow_index(q, e, i)
    as = q.graph[e.first, e.second]
    _check_arrows(q, e.first, [a; [b for (j, b) in enumerate(as) if j != i];
                               [b for d in successors(q, e.first) if d != e.second for b in q[e.first => d]]])
    as[i] = a
    return q
end

"""
    nodes(q::Quiver)

The labels of the nodes of `q`, in topological order.
"""
function nodes(q::Quiver)
    # Kahn's algorithm, taking the earliest added node among the ready ones, so that the
    # order is stable and follows the order of construction where the graph allows
    g = q.graph.graph
    rank(v) = q.rank[label_for(q.graph, v)]
    indeg = [length(Graphs.inneighbors(g, v)) for v in Graphs.vertices(g)]
    ready = [v for v in Graphs.vertices(g) if indeg[v] == 0]
    order = Int[]
    while !isempty(ready)
        v = popfirst!(sort!(ready; by = rank))
        push!(order, v)
        for w in Graphs.outneighbors(g, v)
            indeg[w] -= 1
            indeg[w] == 0 && push!(ready, w)
        end
    end
    return [label_for(q.graph, c) for c in order]
end

"""
    arrows(q::Quiver)

All the arrows of `q`, as a vector of `(source, destination, arrow)`.
"""
arrows(q::Quiver) = [(s, d, a) for (s, d) in edge_labels(q.graph) for a in q.graph[s, d]]

"""
    vessels(q::Quiver)

The nodes of each vessel, in topological order: the stages the vessel goes through.
"""
function vessels(q::Quiver)
    v = Dict{Symbol, Vector{Symbol}}()
    for n in nodes(q)
        x = vessel(q, n)
        x === nothing || push!(get!(v, x, Symbol[]), n)
    end
    return v
end

# the arrows leaving a node: a transformation must be alone, and there is at most one drain
function _check_arrows(q, label, as)
    if any(a -> a isa AbstractTransformation, as) && length(as) > 1
        throw(ArgumentError("a transformation must be the only arrow leaving :$label: it " *
                            "turns all its contents into the next stage; transfer them first"))
    end
    count(a -> a isa Drain, as) ≤ 1 || throw(ArgumentError(
        ":$label can have only one drain; drain into a node and transfer from it"))
end

"""
    connect!(q::Quiver, source => destination, arrow = Transfer())
    connect!(q::Quiver, [sources...] => destination, arrow = Transfer())

Adds an `arrow` (a [`Transfer`](@ref), [`Drain`](@ref) or transformation) from the node
`source` to the node `destination`, e.g.

```julia
connect!(q, [:strike_water, :pale] => :mash)                  # transfer everything
connect!(q, :goldings => :kettle, Transfer(20u"g"; remaining = 10u"minute"))
connect!(q, :kettle => :wort, Boil(time = 60u"minute"))
```

Arrows that would create a cycle are refused, keeping `q` acyclic.
"""
function connect!(q::Quiver, e::Pair{Symbol, Symbol}, a::AbstractArrow = Transfer())
    s, d = e
    for n in (s, d)
        haskey(q, n) || throw(ArgumentError("there is no node labelled :$n"))
    end
    s == d && throw(ArgumentError("an arrow from :$s to itself would be a cycle; " *
                                  "transformations go to the next stage, a new node"))
    _check_arrows(q, s, [a; [b for (_, _, b) in _outgoing(q, s)]])
    if haskey(q.graph, s, d)
        push!(q.graph[s, d], a)
    else
        has_path(q.graph.graph, code_for(q.graph, d), code_for(q.graph, s)) &&
            throw(ArgumentError("an arrow from :$s to :$d would create a cycle"))
        q.graph[s, d] = AbstractArrow[a]
    end
    return q
end
function connect!(q::Quiver, e::Pair{<:AbstractVector{Symbol}, Symbol}, a::AbstractArrow = Transfer())
    for s in e.first
        connect!(q, s => e.second, a)
    end
    return q
end

_outgoing(q::Quiver, label::Symbol) =
    [(d, i, a) for d in outneighbor_labels(q.graph, label) for (i, a) in enumerate(q.graph[label, d])]

"""
    disconnect!(q::Quiver, source => destination)
    disconnect!(q::Quiver, source => destination, i)

Removes all the arrows from `source` to `destination`, or only the `i`-th of them, keeping
the others in order.
"""
function disconnect!(q::Quiver, e::Pair{Symbol, Symbol})
    haskey(q.graph, e.first, e.second) &&
        rem_edge!(q.graph, code_for(q.graph, e.first), code_for(q.graph, e.second))
    return q
end
function disconnect!(q::Quiver, e::Pair{Symbol, Symbol}, i::Integer)
    _arrow_index(q, e, i)
    as = q.graph[e.first, e.second]
    length(as) == 1 ? disconnect!(q, e) : deleteat!(as, i)
    return q
end

"""
    rename!(q::Quiver, old, new)

Renames the node `old` to `new`, keeping its contents, vessel, view and arrows, and its
place in the order of the nodes and of the arrows (so that renaming it back gives the same
quiver, and the same file). Brew again afterwards (`rebrew!(res, q, new)` will do).
"""
function rename!(q::Quiver, old::Symbol, new::Symbol)
    haskey(q, old) || throw(ArgumentError("there is no node labelled :$old"))
    old == new && return q
    haskey(q, new) && throw(ArgumentError("there is already a node labelled :$new"))
    # in place on the fields of the MetaGraph (MetaGraphsNext 0.8), keeping the codes of the
    # vertices: removing and adding the vertex would renumber them, and reorder the arrows
    g = q.graph
    code, data = pop!(g.vertex_properties, old)
    g.vertex_properties[new] = (code, data)
    g.vertex_labels[code] = new
    for (s, d) in collect(keys(g.edge_data))
        (s == old || d == old) || continue
        g.edge_data[(s == old ? new : s, d == old ? new : d)] = pop!(g.edge_data, (s, d))
    end
    q.rank[new] = pop!(q.rank, old)
    return q
end

"""
    remove!(q::Quiver, label)

Removes the node `label` and its arrows.
"""
function remove!(q::Quiver, label::Symbol)
    if haskey(q, label)
        rem_vertex!(q.graph, code_for(q.graph, label))
        delete!(q.rank, label)
    end
    return q
end

"""
    predecessors(q::Quiver, label), successors(q::Quiver, label)

The labels of the nodes with arrows to, or from, the node `label`.
"""
predecessors(q::Quiver, label::Symbol) = collect(inneighbor_labels(q.graph, label))
successors(q::Quiver, label::Symbol) = collect(outneighbor_labels(q.graph, label))

"""
    descendants(q::Quiver, label)

The labels of all the nodes downstream of `label`, including itself, in topological order:
those to recompute when `label` changes.
"""
function descendants(q::Quiver, label::Symbol)
    c = code_for(q.graph, label)
    return [n for n in nodes(q) if n == label || has_path(q.graph.graph, c, code_for(q.graph, n))]
end

"""
    nodeview(q::Quiver, label) -> Dict{String, Any}

The free data of the node `label` for interfaces (a position, a color, ...), which BrewQuiver
does not use but keeps in the files of quivers (see `writejson`). It can be changed in place.
"""
nodeview(q::Quiver, label::Symbol) = q[label].view
