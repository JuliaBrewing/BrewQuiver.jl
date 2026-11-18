# Display in the REPL

_r(x, d = 1) = round(ustrip(x); digits = d)

function _summary(io::IO, l::Liquor; eq = DEFAULT_MODELS.gravity, color = DEFAULT_MODELS.color)
    if iszero(mass(l))
        print(io, "empty")
        return
    end
    print(io, _r(volume(l; eq), 2), " L, ", round(ustrip(gravity(l; eq)); digits = 4), " sg")
    if l.alcohol > 0u"kg"
        print(io, " (OG ", round(ustrip(original_gravity(l; eq)); digits = 4), "), ",
              _r(abv(l; eq), 2), "% ABV")
    end
    l.isoalpha > 0u"mg" && print(io, ", ", _r(ibu(l; eq)), " IBU")
    l.color > 0 && print(io, ", ", _r(srm(color, l; eq)), " SRM")
    l.co2 > 0u"g" && print(io, ", ", _r(carbonation(l; eq), 2), " vols")
    print(io, ", ", _r(l.temperature), " °C")
end

Base.show(io::IO, l::Liquor) = (print(io, "Liquor("); _summary(io, l); print(io, ")"))

function Base.show(io::IO, ::MIME"text/plain", l::Liquor)
    println(io, "Liquor: ", _r(volume(l), 2), " L at ", _r(l.temperature), " °C")
    println(io, "  gravity:     ", round(ustrip(gravity(l)); digits = 4), " sg (",
            _r(_extracts(l)[3] * u"°P", 2), " °P apparent, ", _r(real_extract(l), 2), " °P real)")
    println(io, "  original:    ", round(ustrip(original_gravity(l)); digits = 4), " sg")
    println(io, "  alcohol:     ", _r(abv(l), 2), "% ABV, ", _r(abw(l), 2), "% ABW")
    println(io, "  bitterness:  ", _r(ibu(l)), " IBU")
    println(io, "  color:       ", _r(srm(l)), " SRM")
    println(io, "  carbonation: ", _r(carbonation(l), 2), " vols")
    print(io, "  masses:      ", _r(l.water, 3), " kg water, ", _r(l.extract, 3), " kg extract, ",
          _r(l.alcohol, 3), " kg alcohol")
end

# solids

_mass(m) = ustrip(u"kg", m) < 0.9995 ? string(_r(uconvert(u"g", m), 1), " g") : string(_r(m, 3), " kg")
_timing(::Nothing) = ""
_timing(t::Remaining) = string(" (", _r(t.time, 1), " min remaining)")
_timing(t::At) = string(" (at ", _r(t.time, 1), " min)")
_amount(a::KgQ) = _mass(a)
_amount(a::Float64) = string(isinteger(a) ? Int(a) : round(a; digits = 3), " ×")

Base.show(io::IO, p::Portion) =
    print(io, _amount(p.amount), " ", p.ingredient.name, _timing(p.timing))
Base.show(io::IO, r::Residue) = print(io, _mass(r.mass), iszero(r.grist) ? " residue" :
                                      string(" spent grain (from ", _mass(r.grist), " grain)"))
Base.show(io::IO, h::HopMatter) = print(io, _mass(h.mass), " hop matter")
Base.show(io::IO, y::YeastCake) = print(io, _mass(y.mass), " yeast")
Base.show(io::IO, f::Fermentable) = print(io, "Fermentable(", repr(f.name), ")")
Base.show(io::IO, h::Hop) = print(io, "Hop(", repr(h.name), ")")
Base.show(io::IO, c::Culture) = print(io, "Culture(", repr(c.name), ")")

# contents

function _summary(io::IO, c::Contents; kwargs...)
    if iszero(c)
        print(io, "empty")
        return
    end
    hasliquor = !iszero(mass(c.liquor))
    hasliquor && _summary(io, c.liquor; kwargs...)
    for (k, s) in enumerate(c.solids)
        print(io, k == 1 && !hasliquor ? "" : (k == 1 ? "; " : ", "), s)
    end
end

Base.show(io::IO, c::Contents) = (print(io, "Contents("); _summary(io, c); print(io, ")"))

function Base.show(io::IO, m::MIME"text/plain", c::Contents)
    if !iszero(mass(c.liquor))
        show(io, m, c.liquor)
        isempty(c.solids) || println(io)
    elseif isempty(c.solids)
        print(io, "Contents: empty")
    end
    isempty(c.solids) || print(io, "Solids: ", join(string.(c.solids), ", "))
end

# arrows

function _amount_string(a)
    a === nothing && return "rest"
    a isa Float64 && return string(_r(100a), "%")
    a isa LQ && return string(_r(a, 2), " L")
    return _mass(a)
end

# (inside an arrow, the timing reads as a further argument)
_timing_arg(::Nothing) = ""
_timing_arg(t::Remaining) = string(", ", _r(t.time, 1), " min remaining")
_timing_arg(t::At) = string(", at ", _r(t.time, 1), " min")

_taking(d) = iszero(d) ? "" : string(", taking ", _clock(d))

Base.show(io::IO, t::Transfer) =
    print(io, "Transfer(", _amount_string(t.amount), _timing_arg(t.timing), _taking(t.duration), ")")

# an arrow in the listing of a quiver: a transfer of the rest that is the only arrow leaving
# its node takes all of it
_arrow_string(a, alone) = sprint(show, a)
_arrow_string(t::Transfer, alone) = alone && t.amount === nothing ?
    string("Transfer(all", _timing_arg(t.timing), _taking(t.duration), ")") : sprint(show, t)

function Base.show(io::IO, d::Drain)
    print(io, "Drain(")
    parts = String[]
    d.absorption === nothing || push!(parts, string(_r(d.absorption, 2), " L/kg absorbed"))
    d.retain === nothing || iszero(_r(d.retain, 2)) ||
        push!(parts, string(_r(d.retain, 2), " L retained"))
    d.duration === nothing || iszero(d.duration) ||
        push!(parts, string("taking ", _clock(d.duration)))
    print(io, join(parts, ", "), ")")
end
Base.show(io::IO, m::MashRest) =
    print(io, "MashRest(", _r(m.temperature), " °C, ", _r(m.time), " min)")
_rate_string(r::typeof(1.0u"L/hr")) = string(_r(r, 2), " L/h")
_rate_string(r::typeof(1.0u"hr^-1")) = string(_r(100r, 1), "%/h")
Base.show(io::IO, b::Boil) = print(io, "Boil(", _r(b.time), " min",
    b.evaporation === nothing ? "" : string(", ", _rate_string(b.evaporation)), ")")

function _vessel_parts(v::Vessel)
    parts = String[]
    v.capacity === nothing || push!(parts, string(_r(v.capacity, 2), " L"))
    v.dead_space === nothing || push!(parts, string(_r(v.dead_space, 2), " L dead space"))
    v.absorption === nothing || push!(parts, string(_r(v.absorption, 2), " L/kg absorbed"))
    v.evaporation === nothing || push!(parts, string("evaporating ", _rate_string(v.evaporation)))
    v.drain_rate === nothing || push!(parts, string("draining ", _r(v.drain_rate, 2), " L/min"))
    return parts
end
Base.show(io::IO, v::Vessel) = print(io, "Vessel(", isempty(v.name) ? "" : string(repr(v.name),
    isempty(_vessel_parts(v)) ? "" : "; "), join(_vessel_parts(v), ", "), ")")
Base.show(io::IO, k::Chill) = print(io, "Chill(", _r(k.temperature), " °C",
    iszero(k.time) ? "" : string(", ", _r(k.time), " min"), ")")
Base.show(io::IO, f::Ferment) = print(io, "Ferment(", _r(f.temperature), " °C, ", _r(f.time), " d",
    f.attenuation === nothing ? "" : string(", ", _r(100f.attenuation), "%"), ")")
Base.show(io::IO, p::Prime) = print(io, "Prime(", nameof(typeof(p.sugar)), ", ", _r(p.time), " d)")
Base.show(io::IO, k::Carbonate) =
    print(io, "Carbonate(", _r(k.carbonation, 2), " vols, ", _r(k.time), " d)")

# quivers and results

# The nodes in groups, for display: the lots (sources outside any vessel), then the stages of
# each vessel, then the other nodes (blends, ...), each group in topological order.
function _groups(order, vesselof, issource)
    vs = Symbol[]
    members = Dict{Symbol, Vector{Symbol}}()
    lots, others = Symbol[], Symbol[]
    for n in order
        v = vesselof(n)
        if v !== nothing
            haskey(members, v) || (push!(vs, v); members[v] = Symbol[])
            push!(members[v], n)
        else
            push!(issource(n) ? lots : others, n)
        end
    end
    groups = Pair{String, Vector{Symbol}}[]
    isempty(lots) || push!(groups, "lots" => lots)
    for v in vs
        push!(groups, string("[", v, "]") => members[v])
    end
    isempty(others) || push!(groups, "other nodes" => others)
    return groups
end

function Base.show(io::IO, ::MIME"text/plain", q::Quiver)
    ns = nodes(q)
    as = arrows(q)
    print(io, "Quiver with ", length(ns), " nodes and ", length(as), " arrows")
    for (title, members) in _groups(ns, n -> vessel(q, n), n -> isempty(predecessors(q, n)))
        print(io, "\n  ", title)
        v = startswith(title, "[") ? equipment(q, Symbol(title[2:end-1])) : nothing
        v === nothing || print(io, "  ", v)
        for n in members
            print(io, "\n    :", n)
            node = q[n]
            iszero(node.initial) || (print(io, "  "); _summary(io, node.initial))
            outs = [(d, a) for (s, d, a) in as if s == n]
            for (d, a) in outs
                print(io, "\n        ", _arrow_string(a, length(outs) == 1), " → :", d)
            end
        end
    end
end

function Base.show(io::IO, ::MIME"text/plain", r::BrewResult)
    eq, color = r.models.gravity, r.models.color
    print(io, "BrewResult")
    issource(n) = !any(k -> k[2] === n, keys(r.arrows))
    for (title, members) in _groups(r.order, n -> get(r.vessels, n, nothing), issource)
        print(io, "\n  ", title)
        for n in members
            nr = r.nodes[n]
            print(io, "\n    :", n, "  ")
            _summary(io, nr.contents; eq, color)
            if !iszero(nr.leftover) && any(k -> k[1] === n, keys(r.arrows))
                print(io, "\n        left: ")
                _summary(io, nr.leftover; eq, color)
            end
        end
    end
end
