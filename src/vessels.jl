# Equipment: the vessels of a quiver, whose properties the arrows leaving their nodes take
# when they do not give their own (see `equip!`).

const RateQ = Union{typeof(1.0u"L/hr"), typeof(1.0u"hr^-1")}

"""
    Vessel(; name = "", capacity = nothing, dead_space = nothing, absorption = nothing,
           evaporation = nothing, drain_rate = nothing)

The equipment of a vessel: its `capacity`, its `dead_space` (the liquid left behind when it
is drained: the dead space under a false bottom, the trub of a kettle, the yeast cake of a
fermentor), the grain `absorption` per mass of grain (a mash or lauter tun), the
`evaporation` rate of a boil (a volume, or a fraction of the volume, per time) and the
`drain_rate` (a volume per time). Attach it to the nodes of a vessel with
[`equip!`](@ref); what is not given is left to the arrows or their defaults.
"""
struct Vessel
    name::String
    capacity::Union{Nothing, LQ}
    dead_space::Union{Nothing, LQ}
    absorption::Union{Nothing, typeof(1.0u"L/kg")}
    evaporation::Union{Nothing, RateQ}
    drain_rate::Union{Nothing, typeof(1.0u"L/minute")}
end

Vessel(; name::AbstractString = "", capacity = nothing, dead_space = nothing,
       absorption = nothing, evaporation = nothing, drain_rate = nothing) =
    Vessel(name, _maybe(x -> uconvert(u"L", float(x)), capacity),
           _maybe(x -> uconvert(u"L", float(x)), dead_space),
           _maybe(x -> uconvert(u"L/kg", float(x)), absorption), _maybe(_rate, evaporation),
           _maybe(x -> uconvert(u"L/minute", float(x)), drain_rate))

# a copy of `v` with some of its properties changed
function _with(v::Vessel; kwargs...)
    p = Dict{Symbol, Any}(f => getfield(v, f) for f in fieldnames(Vessel))
    merge!(p, Dict(kwargs))
    return Vessel(; p...)
end

# the arrow `a` leaving a node of the vessel `v`, with what it does not give taken from `v`
_resolve(a::AbstractArrow, v) = a
_resolve(d::Drain, v::Vessel) = Drain(something(d.absorption, v.absorption, Some(nothing)),
                                      something(d.retain, v.dead_space, Some(nothing)),
                                      d.duration)
_resolve(b::Boil, v::Vessel) = Boil(b.time, something(b.evaporation, v.evaporation, Some(nothing)))
