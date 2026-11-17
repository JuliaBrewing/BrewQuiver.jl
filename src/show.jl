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

Base.show(io::IO, p::AbstractProcess) = print(io, nameof(typeof(p)), "(…)")
Base.show(io::IO, s::Source) = (print(io, "Source("); _summary(io, s.liquor); print(io, ")"))

function Base.show(io::IO, ::MIME"text/plain", q::Quiver)
    ns = nodes(q)
    ts = transfers(q)
    println(io, "Quiver with ", length(ns), " processes and ", length(ts), " transfers:")
    for n in ns
        print(io, "  :", n, " ", nameof(typeof(q[n])))
        outs = [(d, t) for (s, d, t) in ts if s == n]
        for (d, t) in outs
            print(io, "\n      ", t.from === :out ? "" : string(":", t.from, " "), "→ :", d,
                  t.to === :in ? "" : string(" :", t.to))
            t.amount === nothing || print(io, " (", t.amount isa Real ?
                                          string(round(100t.amount; digits = 1), "%") :
                                          string(_r(t.amount, 2), " L"), ")")
        end
        n === last(ns) || println(io)
    end
end

function Base.show(io::IO, ::MIME"text/plain", r::BrewResult)
    eq, color = r.models.gravity, r.models.color
    println(io, "BrewResult:")
    for n in r.order
        nr = r.nodes[n]
        terminal = !any(k -> k[1] === n, keys(r.flows))   # its outputs are products
        print(io, "  :", n)
        for port in sort!(collect(keys(nr.outputs)))
            l = nr.outputs[port]
            iszero(mass(l)) && continue
            print(io, "\n      ", port, ": ")
            _summary(io, l; eq, color)
            !terminal && haskey(nr.leftovers, port) && !iszero(mass(nr.leftovers[port])) &&
                print(io, "  [left over: ", _r(volume(nr.leftovers[port]; eq), 2), " L]")
        end
        n === last(r.order) || println(io)
    end
end
