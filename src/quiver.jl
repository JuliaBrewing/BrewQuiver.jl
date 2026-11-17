# The quiver: a directed acyclic graph whose nodes are processes and whose edges carry
# transfers of liquors from an output port of a process to an input port of another.

"""
    Transfer(from, to; amount = nothing, out_time = nothing, in_time = nothing)

A transfer of liquor from the output port `from` of a process to the input port `to` of
another. The `amount` is a volume (at 20 °C), a fraction of the liquor at the port, or
`nothing` for all that is left at the port after the other transfers (shared equally among
the transfers with `nothing`). The times `out_time` and `in_time` at which the liquor leaves
and arrives are relative to the processes (not yet used in the calculations).
"""
struct Transfer
    from::Symbol
    to::Symbol
    amount::Union{Nothing, Float64, LQ}
    out_time::Union{Nothing, MinQ}
    in_time::Union{Nothing, MinQ}
end

_amount(::Nothing) = nothing
_amount(x::Real) = (0 ≤ x ≤ 1 ? float(x) :
                    throw(DomainError(x, "a fraction must be between 0 and 1")))
_amount(x::Unitful.DimensionlessQuantity) = _amount(float(uconvert(NoUnits, x)))
_amount(x::Unitful.Volume) = uconvert(u"L", float(x))
_time(::Nothing) = nothing
_time(x::Unitful.Time) = uconvert(u"minute", float(x))

Transfer(from::Symbol, to::Symbol; amount = nothing, out_time = nothing, in_time = nothing) =
    Transfer(from, to, _amount(amount), _time(out_time), _time(in_time))

"""
    Quiver()

An empty quiver, the brewing process as a directed acyclic graph: its nodes, labelled by
symbols, are processes ([`AbstractProcess`](@ref)), and its edges carry the
[`Transfer`](@ref)s of liquors between them.

Build it with [`add!`](@ref) and [`connect!`](@ref), replace a process with
`q[label] = process`, and compute it with [`brew`](@ref).
"""
struct Quiver{G}
    graph::G
end

Quiver() = Quiver(MetaGraph(DiGraph(); label_type = Symbol, vertex_data_type = AbstractProcess,
                            edge_data_type = Vector{Transfer}, graph_data = nothing))

Base.haskey(q::Quiver, label::Symbol) = haskey(q.graph, label)
Base.getindex(q::Quiver, label::Symbol) = q.graph[label]

function Base.setindex!(q::Quiver, p::AbstractProcess, label::Symbol)
    if haskey(q, label)
        _check_ports(q, label, p)
    end
    q.graph[label] = p
    return q
end

"""
    nodes(q::Quiver)

The labels of the processes of `q`, in topological order.
"""
function nodes(q::Quiver)
    # Kahn's algorithm, taking the earliest added process among the ready ones, so that the
    # order is stable and follows the order of construction where the graph allows
    g = q.graph.graph
    indeg = [length(Graphs.inneighbors(g, v)) for v in Graphs.vertices(g)]
    ready = [v for v in Graphs.vertices(g) if indeg[v] == 0]
    order = Int[]
    while !isempty(ready)
        v = popfirst!(sort!(ready))
        push!(order, v)
        for w in Graphs.outneighbors(g, v)
            indeg[w] -= 1
            indeg[w] == 0 && push!(ready, w)
        end
    end
    return [label_for(q.graph, c) for c in order]
end

"""
    transfers(q::Quiver)

All the transfers of `q`, as a vector of `(source, destination, transfer)`.
"""
transfers(q::Quiver) = [(s, d, t) for (s, d) in edge_labels(q.graph) for t in q.graph[s, d]]

"""
    add!(q::Quiver, label::Symbol, p::AbstractProcess)

Adds the process `p` to `q` with the given `label`.
"""
function add!(q::Quiver, label::Symbol, p::AbstractProcess)
    haskey(q, label) && throw(ArgumentError("there is already a process labelled :$label"))
    q.graph[label] = p
    return q
end

_endpoint(x::Symbol, default) = (x, default)
_endpoint(x::Tuple{Symbol, Symbol}, default) = x

function _check_outport(q, node, port)
    port in outports(q[node]) || throw(ArgumentError(
        ":$node ($(nameof(typeof(q[node])))) has no output port :$port; " *
        "its output ports are $(outports(q[node]))"))
end

function _check_inport(q, node, port)
    port in inports(q[node]) || throw(ArgumentError(
        ":$node ($(nameof(typeof(q[node])))) has no input port :$port; " *
        "its input ports are $(inports(q[node]))"))
end

# when replacing the process of a node, its ports in use must remain
function _check_ports(q, label, p)
    for (s, d, t) in transfers(q)
        s == label && t.from ∉ outports(p) && throw(ArgumentError(
            "the new process for :$label has no output port :$(t.from), used by a transfer to :$d"))
        d == label && t.to ∉ inports(p) && throw(ArgumentError(
            "the new process for :$label has no input port :$(t.to), used by a transfer from :$s"))
    end
end

"""
    connect!(q::Quiver, source => destination; amount = nothing, out_time = nothing, in_time = nothing)

Adds a [`Transfer`](@ref) from `source` to `destination`, each either a label, for the
default ports `:out` and `:in`, or a tuple `(label, port)`. E.g.

```julia
connect!(q, :boil => :fermentor)
connect!(q, (:mashtun, :running2) => :boil2; amount = 20u"L")
```

Transfers that would create a cycle are refused, keeping `q` acyclic.
"""
function connect!(q::Quiver, p::Pair; amount = nothing, out_time = nothing, in_time = nothing)
    (s, from) = _endpoint(p.first, :out)
    (d, to) = _endpoint(p.second, :in)
    for n in (s, d)
        haskey(q, n) || throw(ArgumentError("there is no process labelled :$n"))
    end
    s == d && throw(ArgumentError("a process cannot transfer to itself"))
    _check_outport(q, s, from)
    _check_inport(q, d, to)
    t = Transfer(from, to; amount, out_time, in_time)
    if haskey(q.graph, s, d)
        push!(q.graph[s, d], t)
    else
        has_path(q.graph.graph, code_for(q.graph, d), code_for(q.graph, s)) &&
            throw(ArgumentError("a transfer from :$s to :$d would create a cycle"))
        q.graph[s, d] = [t]
    end
    return q
end

"""
    disconnect!(q::Quiver, source => destination)

Removes all the transfers from `source` to `destination`.
"""
function disconnect!(q::Quiver, p::Pair{Symbol, Symbol})
    haskey(q.graph, p.first, p.second) && rem_edge!(q.graph, code_for(q.graph, p.first),
                                                    code_for(q.graph, p.second))
    return q
end

"""
    remove!(q::Quiver, label)

Removes the process `label` and its transfers.
"""
function remove!(q::Quiver, label::Symbol)
    haskey(q, label) && rem_vertex!(q.graph, code_for(q.graph, label))
    return q
end

"""
    predecessors(q::Quiver, label), successors(q::Quiver, label)

The labels of the processes transferring to, or receiving from, the process `label`.
"""
predecessors(q::Quiver, label::Symbol) = collect(inneighbor_labels(q.graph, label))
successors(q::Quiver, label::Symbol) = collect(outneighbor_labels(q.graph, label))

"""
    descendants(q::Quiver, label)

The labels of all the processes downstream of `label`, including itself, in topological
order: those to recompute when `label` changes.
"""
function descendants(q::Quiver, label::Symbol)
    c = code_for(q.graph, label)
    return [n for n in nodes(q) if n == label || has_path(q.graph.graph, c, code_for(q.graph, n))]
end
