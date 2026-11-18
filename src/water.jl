# Water chemistry of liquors and mashes: the profile of the water of a liquor, its residual
# alkalinity, and an estimate of the pH of a mash (with BrewingFormulas).

"""
    profile(liquor), profile(contents)

The [`WaterProfile`](@ref) of the liquor: the concentrations of its minerals in its volume,
with the alkalinity as bicarbonate (negative if acids took more than the alkalinity).
"""
function profile(l::Liquor)
    v = uconvert(u"L", volume(l))
    iszero(v) && return WaterProfile()
    m = l.minerals
    return WaterProfile(m.calcium / v, m.magnesium / v, m.sodium / v, m.chloride / v,
                        m.sulfate / v, m.alkalinity * _HCO3_PER_ALK / v)
end
profile(c::Contents) = profile(c.liquor)

"""
    residual_alkalinity(liquor), residual_alkalinity(contents)

Kolbach's residual alkalinity of the water of the liquor, in mg/L as CaCO₃ (see
BrewingFormulas' `residual_alkalinity`), from its minerals and volume.
"""
function BrewingFormulas.residual_alkalinity(l::Liquor)
    v = uconvert(u"L", volume(l))
    iszero(v) && return 0.0u"mg/L"
    p = profile(l)
    return residual_alkalinity(l.minerals.alkalinity / v, p.calcium, p.magnesium)
end
BrewingFormulas.residual_alkalinity(c::Contents) = residual_alkalinity(c.liquor)

# grains darker than this need their distilled water pH for a meaningful estimate
const _DARK = 8.0u"SRM"

"""
    mash_ph(contents)

An estimate of the pH of a mash with the `contents` of a node before its mash rest (the
grain and the water, with the salts and acids added to it), by the balance of charges of
BrewingFormulas' `mash_ph`: the distilled water pH and buffering of each grain (see
[`Fermentable`](@ref); pale base malt by default), and the residual alkalinity and volume of
the liquor. Grains darker than 8 SRM without a distilled water pH are taken as base malt,
with a warning, since crystal and roasted malts lower the pH much more.

```julia
res = brew(q)
mash_ph(res[:mash])
```
"""
function BrewingFormulas.mash_ph(c::Contents)
    grains = [s for s in c.solids if s isa Portion{Fermentable, KgQ} && !soluble(s.ingredient)]
    isempty(grains) && throw(ArgumentError(
        "there is no grain to mash in these contents: take a node before its mash rest"))
    unknown = unique(s.ingredient.name for s in grains
                     if s.ingredient.di_ph === nothing && s.ingredient.color > _DARK)
    isempty(unknown) || @warn "the distilled water pH of $(join(repr.(unknown), ", ")) is not " *
                              "known: taken as pale base malt, which overestimates the mash pH"
    grist = [(mass = s.amount, di_ph = s.ingredient.di_ph, buffering = s.ingredient.buffering)
             for s in grains]
    return mash_ph(grist, uconvert(u"L", volume(c)), residual_alkalinity(c))
end
