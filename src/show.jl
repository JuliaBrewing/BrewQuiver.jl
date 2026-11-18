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

_mass(m) = m < 1u"kg" ? string(_r(uconvert(u"g", m), 1), " g") : string(_r(m, 3), " kg")
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

Base.show(io::IO, t::Transfer) =
    print(io, "Transfer(", _amount_string(t.amount), _timing(t.timing), ")")
function Base.show(io::IO, d::Drain)
    print(io, "Drain(")
    parts = String[]
    d.absorption == Drain().absorption ||
        push!(parts, string(_r(d.absorption, 2), " L/kg absorbed"))
    iszero(d.retain) || push!(parts, string(_r(d.retain, 2), " L retained"))
    print(io, join(parts, ", "), ")")
end
Base.show(io::IO, m::MashRest) =
    print(io, "MashRest(", _r(m.temperature), " °C, ", _r(m.time), " min)")
_rate_string(r::typeof(1.0u"L/hr")) = string(_r(r, 2), " L/h")
_rate_string(r::typeof(1.0u"hr^-1")) = string(_r(100r, 1), "%/h")
Base.show(io::IO, b::Boil) = print(io, "Boil(", _r(b.time), " min, ", _rate_string(b.evaporation), ")")
Base.show(io::IO, f::Ferment) = print(io, "Ferment(", _r(f.temperature), " °C, ", _r(f.time), " d",
    f.attenuation === nothing ? "" : string(", ", _r(100f.attenuation), "%"), ")")
Base.show(io::IO, p::Prime) = print(io, "Prime(", nameof(typeof(p.sugar)), ")")
Base.show(io::IO, k::Carbonate) = print(io, "Carbonate(", _r(k.carbonation, 2), " vols)")

# quivers and results

function Base.show(io::IO, ::MIME"text/plain", q::Quiver)
    ns = nodes(q)
    as = arrows(q)
    println(io, "Quiver with ", length(ns), " nodes and ", length(as), " arrows:")
    for n in ns
        node = q[n]
        print(io, "  :", n)
        node.vessel === nothing || print(io, " [", node.vessel, "]")
        iszero(node.initial) || (print(io, " "); _summary(io, node.initial))
        for (s, d, a) in as
            s == n && print(io, "\n      ", a, " → :", d)
        end
        n === last(ns) || println(io)
    end
end

function Base.show(io::IO, ::MIME"text/plain", r::BrewResult)
    eq, color = r.models.gravity, r.models.color
    println(io, "BrewResult:")
    for n in r.order
        nr = r.nodes[n]
        print(io, "  :", n, "  ")
        _summary(io, nr.contents; eq, color)
        if !iszero(nr.leftover) && any(k -> k[1] === n, keys(r.arrows))
            print(io, "\n      left: ")
            _summary(io, nr.leftover; eq, color)
        end
        n === last(r.order) || println(io)
    end
end
