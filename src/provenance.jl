# Provenance: which part of each node, and of each lot, serves a product of the quiver.
#
# The share of a node in a product is the fraction of its contents that goes into making the
# product. It follows the liquor: an arrow carries the fraction of the liquor of its node
# that it moves (all of it, for a transformation), and since the liquor of a node is
# uniform, that fraction is the same for its water, its extract or its bitterness. What a
# node leaves behind (spent grain, trub, yeast cake) is waste, allocated to the products
# its other arrows serve, so the share of a node is the mean of the shares of its
# destinations weighted by those fractions. The share of a lot is not normalized: what
# remains on the shelf is not used.

# the fraction of the contents `c` of a node moved by an arrow (`moved`): of its liquor, or
# else of its mass, or else of its counts
function _moved_fraction(moved::Contents, c::Contents)
    l = total_mass(c.liquor)
    l > 0u"kg" && return float(uconvert(NoUnits, total_mass(moved.liquor) / l))
    m = total_mass(c)
    m > 0u"kg" && return float(uconvert(NoUnits, total_mass(moved) / m))
    counts(x) = sum((s.amount for s in x.solids if s isa Portion && s.amount isa Float64); init = 0.0)
    n = counts(c)
    return n > 0 ? counts(moved) / n : 0.0
end

_issource(q, n) = isempty(predecessors(q, n))

"""
    attribution(res::BrewResult, q::Quiver, product) -> Dict{Symbol, Float64}

The share of each node of `q` in the `product` (a node): the fraction of its contents that
goes into making the product, following the liquor along the arrows. What a node leaves
behind (spent grain, trub, yeast cake, the beer left in a tank) is allocated to the
products its other arrows serve. For a lot (a node without predecessors), the share is the
fraction of the lot used for the product: what remains on the shelf is not allocated.

The shares of a lot in all the products of `q` add up to the fraction of the lot used,
unless some of it only reaches nodes whose contents are all left behind.
"""
function attribution(res::BrewResult, q::Quiver, product::Symbol)
    haskey(q, product) || throw(ArgumentError("there is no node labelled :$product"))
    a = Dict{Symbol, Float64}()
    for n in Iterators.reverse(res.order)
        if n === product
            a[n] = 1.0
            continue
        end
        num, den = 0.0, 0.0
        c = res[n]
        for d in successors(q, n), r in res[n => d]
            f = r.moved
            # (a transformation takes all the contents)
            w = length(_outgoing(q, n)) == 1 && only(_outgoing(q, n))[3] isa AbstractTransformation ?
                1.0 : _moved_fraction(f, c)
            num += w * get(a, d, 0.0)
            den += w
        end
        a[n] = _issource(q, n) ? num : (den > 0 ? num / den : 0.0)
    end
    return a
end

"""
    shares(res::BrewResult, q::Quiver, product) -> Dict{Symbol, Float64}

The share of each lot (a node without predecessors: an ingredient, the water) used for the
`product`, for the lots with a positive share. See [`attribution`](@ref).
"""
shares(res::BrewResult, q::Quiver, product::Symbol) =
    Dict(n => s for (n, s) in attribution(res, q, product) if _issource(q, n) && s > 0)
