# Computing a quiver: the processes are evaluated in topological order, each mixing the
# liquors arriving at its input ports and distributing its outputs along its transfers.

"""
    NodeResult

The result of a process in a brew: the liquors at its input ports (`inputs`), at its output
ports (`outputs`), and what was left at each output port after the transfers (`leftovers`).
"""
struct NodeResult
    inputs::Dict{Symbol, Liquor}
    outputs::Dict{Symbol, Liquor}
    leftovers::Dict{Symbol, Liquor}
end

"""
    BrewResult

The result of [`brew`](@ref): `res[label]` is the [`NodeResult`](@ref) of a process,
`res[label, port]` the liquor at one of its output ports, and `res[source => destination]`
the liquors transferred along an edge, in the order of the transfers.
"""
struct BrewResult{M <: NamedTuple}
    nodes::Dict{Symbol, NodeResult}
    flows::Dict{Tuple{Symbol, Symbol}, Vector{Liquor}}
    order::Vector{Symbol}
    models::M
end

Base.getindex(r::BrewResult, label::Symbol) = r.nodes[label]
Base.getindex(r::BrewResult, label::Symbol, port::Symbol) = r.nodes[label].outputs[port]
Base.getindex(r::BrewResult, e::Pair{Symbol, Symbol}) = r.flows[(e.first, e.second)]
Base.keys(r::BrewResult) = r.order

"""
    brew(q::Quiver; models = (;))

Computes all the processes of `q`, in topological order, with the models of
BrewingFormulas in `models` (a NamedTuple overriding [`DEFAULT_MODELS`](@ref), e.g.
`(bitterness = Rager(), color = Daniels())`). Returns a [`BrewResult`](@ref).
"""
function brew(q::Quiver; models::NamedTuple = (;))
    ms = merge(DEFAULT_MODELS, models)
    order = nodes(q)
    res = BrewResult(Dict{Symbol, NodeResult}(), Dict{Tuple{Symbol, Symbol}, Vector{Liquor}}(),
                     order, ms)
    for label in order
        _brew_node!(res, q, label)
    end
    return res
end

"""
    rebrew!(res::BrewResult, q::Quiver, label)

Updates `res` after a change of the process `label` of `q` or of the transfers leaving it,
recomputing only `label` and the processes downstream of it.
"""
function rebrew!(res::BrewResult, q::Quiver, label::Symbol)
    order = nodes(q)
    Set(order) == Set(res.order) || throw(ArgumentError(
        "the processes of the quiver changed since the brew; brew it again"))
    copyto!(res.order, order)
    for n in descendants(q, label)
        _brew_node!(res, q, n)
    end
    return res
end

function _brew_node!(res::BrewResult, q::Quiver, label::Symbol)
    p = q[label]
    g = q.graph
    inputs = Dict{Symbol, Liquor}()
    for s in inneighbor_labels(g, label)
        flows = get(res.flows, (s, label), nothing)
        flows === nothing && error("missing the transfers from :$s to :$label")
        for (t, l) in zip(g[s, label], flows)
            _check_inport(q, label, t.to)
            inputs[t.to] = get(inputs, t.to, zero(Liquor)) + l
        end
    end
    outputs = process(p, inputs, res.models)
    leftovers = _distribute!(res, q, label, outputs)
    res.nodes[label] = NodeResult(inputs, outputs, leftovers)
    return res
end

# split the outputs of `label` along its transfers; returns the leftovers
function _distribute!(res, q, label, outputs)
    g = q.graph
    eq = res.models.gravity
    outs = [(d, i, t) for d in outneighbor_labels(g, label) for (i, t) in enumerate(g[label, d])]
    fractions = Dict{Tuple{Symbol, Int}, Float64}()
    leftovers = Dict{Symbol, Liquor}()
    for (port, l) in outputs
        mine = [(d, i, t) for (d, i, t) in outs if t.from == port]
        v = volume(l; eq)
        explicit = 0.0
        for (d, i, t) in mine
            t.amount === nothing && continue
            f = t.amount isa Real ? t.amount :
                (iszero(v) ? 1.0 : float(uconvert(NoUnits, t.amount / v)))
            fractions[(d, i)] = f
            explicit += f
        end
        explicit ≤ 1 + 1e-9 || throw(ArgumentError(
            "the transfers from :$label at port :$port take " *
            "$(round(100explicit; digits = 1))% of the $(round(u"L", v; digits = 2)) available"))
        explicit = min(explicit, 1.0)
        rest = [(d, i) for (d, i, t) in mine if t.amount === nothing]
        for (d, i) in rest
            fractions[(d, i)] = (1 - explicit) / length(rest)
        end
        if isempty(rest) && explicit < 1 - 1e-12
            leftovers[port] = (1 - explicit) * l
        end
    end
    for d in outneighbor_labels(g, label)
        ts = g[label, d]
        res.flows[(label, d)] = [begin
            haskey(outputs, t.from) || throw(ArgumentError(
                ":$label produced nothing at port :$(t.from), used by a transfer to :$d"))
            fractions[(d, i)] * outputs[t.from]
        end for (i, t) in enumerate(ts)]
    end
    return leftovers
end

"""
    products(res::BrewResult, q::Quiver)

The liquors at the end of the quiver: the outputs of the processes with no successors,
as a `Dict` from label to liquor (the main output port `:out`, when it exists).
"""
function products(res::BrewResult, q::Quiver)
    d = Dict{Symbol, Liquor}()
    for n in res.order
        isempty(successors(q, n)) || continue
        outs = res[n].outputs
        haskey(outs, :out) && (d[n] = outs[:out])
    end
    return d
end
