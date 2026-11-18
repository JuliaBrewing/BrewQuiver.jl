# Targets and solving: the parameters of a quiver (amounts of lots, settings of arrows) that
# give chosen values at its nodes (a gravity, a volume, a bitterness, ...), by Newton's
# method on the brews of the quiver.

"""
    AbstractParameter

Supertype of what [`solve!`](@ref) varies: [`Amount`](@ref) and [`Setting`](@ref).
"""
abstract type AbstractParameter end

"""
    Amount(labels::Symbol...)

The amount of the lots `labels`, scaled together by one factor (e.g. a grain bill, keeping
its proportions), with the transfers of masses or volumes leaving them.
"""
struct Amount <: AbstractParameter
    labels::Vector{Symbol}
end
Amount(labels::Symbol...) = Amount(collect(labels))

"""
    Setting(source => destination, field; index = 1)

The numeric `field` of the `index`-th arrow from `source` to `destination`, e.g.
`Setting(:kettle => :wort, :stand)` for the length of a hop stand, or
`Setting(:bright1 => :esb, :amount)` for the fraction of a blend.
"""
struct Setting <: AbstractParameter
    edge::Pair{Symbol, Symbol}
    field::Symbol
    index::Int
end
Setting(edge::Pair{Symbol, Symbol}, field::Symbol; index::Integer = 1) = Setting(edge, field, index)

"""
    Target(node, f, goal)
    node => f => goal

The goal of [`solve!`](@ref) that `f(contents)` of the `node` (e.g. `gravity`, `volume`,
`ibu`, `carbonation`, or any function of [`Contents`](@ref)) equals `goal`.
"""
struct Target{F}
    node::Symbol
    f::F
    goal::Any
end
Target(p::Pair{Symbol, <:Pair}) = Target(p.first, p.second.first, p.second.second)
Target(t::Target) = t

# the value of the target, in the unit of its goal
function _measure(t::Target, res::BrewResult)
    v = t.f(res[t.node])
    t.goal isa Unitful.Quantity || return float(v)
    v isa Unitful.Quantity || throw(ArgumentError("the target of :$(t.node) gives $v, not a quantity like $(t.goal)"))
    u = unit(t.goal)
    return dimension(v) == dimension(t.goal) ? uconvert(u, v) : uconvert(u, v, res.models.gravity)
end
_number(x::Unitful.Quantity) = float(ustrip(x))
_number(x::Real) = float(x)
_number(::Any) = throw(ArgumentError("a target needs a number or a quantity"))

# Handles on the parameters: their current value (a plain number) and how to set one.
# An amount is a factor on the lots as they were when solving started.
function _handle(p::Amount, q::Quiver)
    for l in p.labels
        haskey(q, l) || throw(ArgumentError("there is no node labelled :$l"))
        _issource(q, l) || throw(ArgumentError(":$l is not a lot: an `Amount` scales lots"))
    end
    initial = Dict(l => q[l].initial for l in p.labels)
    arrows = Dict(l => [(d, copy(q[l => d])) for d in successors(q, l)] for l in p.labels)
    function set!(k)
        for l in p.labels
            q[l] = k * initial[l]
            for (d, as) in arrows[l]
                q.graph[l, d] = AbstractArrow[a isa Transfer && a.amount isa Union{LQ, KgQ} ?
                    Transfer(k * a.amount, a.timing, a.duration) : a for a in as]
            end
        end
    end
    return (value = 1.0, set! = set!, positive = true, fraction = false)
end

function _handle(p::Setting, q::Quiver)
    s, d = p.edge
    haskey(q.graph, s, d) || throw(ArgumentError("there is no arrow from :$s to :$d"))
    as = q[s => d]
    1 ≤ p.index ≤ length(as) || throw(ArgumentError("there is no arrow $(p.index) from :$s to :$d"))
    a = as[p.index]
    hasfield(typeof(a), p.field) || throw(ArgumentError("$(nameof(typeof(a))) has no field $(p.field)"))
    v = getfield(a, p.field)
    v isa Union{Real, Unitful.Quantity} || throw(ArgumentError(
        "the field $(p.field) of $(nameof(typeof(a))) is $v, not a number to vary"))
    u = v isa Unitful.Quantity ? unit(v) : NoUnits
    names = fieldnames(typeof(a))
    function set!(x)
        old = q[s => d][p.index]
        vals = [f == p.field ? (u == NoUnits ? x : x * u) : getfield(old, f) for f in names]
        q.graph[s, d][p.index] = typeof(old)(vals...)
    end
    return (value = _number(v), set! = set!, positive = _number(v) > 0,
            fraction = a isa Transfer && p.field == :amount && v isa Real)
end

"""
    Solution

The result of [`solve!`](@ref): whether it `converged`, the `iterations`, the values of the
`parameters` and of the `targets` reached, and the brew `result` of the solved quiver.
"""
struct Solution
    converged::Bool
    iterations::Int
    parameters::Vector{Pair{AbstractParameter, Any}}
    targets::Vector{Pair{Target, Any}}
    result::BrewResult
end

"""
    solve!(q::Quiver, targets...; vary, models = (;), rtol = 1e-8, maxiter = 50) -> Solution

Changes the parameters `vary` (an [`AbstractParameter`](@ref) or a vector of them, as many as
the targets) of `q` so that its brew meets the `targets` (each a [`Target`](@ref), or
`node => f => goal`), by Newton's method with a Jacobian by finite differences, damped to
keep amounts positive and fractions between 0 and 1. E.g. the grain bill for an original
gravity and the sparge water for a pre-boil volume:

```julia
solve!(q, :fermentor => gravity => 1.052u"sg", :kettle => volume => 28u"L";
       vary = [Amount(:pale, :crystal), Amount(:sparge_water)])
```

`q` is left with the solution, also when the solver does not converge (see the field
`converged` of the [`Solution`](@ref)).
"""
function solve!(q::Quiver, targets...; vary, models::NamedTuple = (;), rtol::Real = 1e-8,
                maxiter::Integer = 50)
    ts = Target[Target(t) for t in targets]
    ps = AbstractParameter[p for p in (vary isa AbstractParameter ? [vary] : vary)]
    isempty(ts) && throw(ArgumentError("give the targets to solve for"))
    length(ps) == length(ts) || throw(ArgumentError(
        "give as many parameters to vary ($(length(ps))) as targets ($(length(ts)))"))
    hs = [_handle(p, q) for p in ps]
    goals = [_number(t.goal) for t in ts]
    scale = [max(abs(g), 1e-12) for g in goals]
    function residuals(x)
        for (h, xi) in zip(hs, x)
            h.set!(xi)
        end
        res = brew(q; models)
        return [(_number(_measure(t, res)) - g) / s for (t, g, s) in zip(ts, goals, scale)], res
    end
    admissible(x) = all(!h.positive || xi > 0 for (h, xi) in zip(hs, x)) &&
                    all(!h.fraction || 0 ≤ xi ≤ 1 for (h, xi) in zip(hs, x))
    x = [h.value for h in hs]
    r, res = residuals(x)
    iterations, converged = 0, maximum(abs, r) ≤ rtol
    while !converged && iterations < maxiter
        iterations += 1
        # the Jacobian, by forward differences
        J = zeros(length(r), length(x))
        for j in eachindex(x)
            h = 1e-6 * max(abs(x[j]), 1e-3)
            xh = copy(x)
            xh[j] = hs[j].fraction && x[j] + h > 1 ? x[j] - h : x[j] + h
            rh, _ = residuals(xh)
            J[:, j] = (rh - r) / (xh[j] - x[j])
        end
        step = try
            -(J \ r)
        catch
            break
        end
        # damped: halve the step until it is admissible, brews and reduces the residuals
        λ, accepted = 1.0, false
        for _ in 1:30
            xn = x + λ * step
            if admissible(xn)
                trial = try
                    residuals(xn)
                catch e
                    e isa ArgumentError || rethrow()
                    nothing
                end
                if trial !== nothing && sum(abs2, trial[1]) < sum(abs2, r)
                    x, (r, res), accepted = xn, trial, true
                    break
                end
            end
            λ /= 2
        end
        accepted || break
        converged = maximum(abs, r) ≤ rtol
    end
    r, res = residuals(x)                         # (q left at the last accepted point)
    values = [p => _value(p, q) for p in ps]
    reached = [t => _measure(t, res) for t in ts]
    return Solution(converged, iterations, values, reached, res)
end

# the value of a parameter in the quiver: the contents of its lots, or the field
_value(p::Amount, q) = length(p.labels) == 1 ? q[only(p.labels)].initial :
                       Dict(l => q[l].initial for l in p.labels)
_value(p::Setting, q) = getfield(q[p.edge][p.index], p.field)

function Base.show(io::IO, ::MIME"text/plain", s::Solution)
    print(io, s.converged ? "Solution" : "Solution (not converged)", " in ", s.iterations,
          s.iterations == 1 ? " iteration" : " iterations")
    for (p, v) in s.parameters
        print(io, "\n  ", p isa Amount ? string("amount of ", join((":$l" for l in p.labels), ", ")) :
                  string(":", p.edge.first, " → :", p.edge.second, " ", p.field), ": ")
        v isa Dict ? join(io, (string(":", l, " ", c) for (l, c) in sort!(collect(v); by = first)), ", ") :
                     print(io, v)
    end
    for (t, v) in s.targets
        print(io, "\n  ", nameof(t.f), "(:", t.node, ") = ", v, " (goal ", t.goal, ")")
    end
end
