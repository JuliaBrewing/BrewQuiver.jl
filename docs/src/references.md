# References

The formulas of BrewQuiver are those of
[BrewingFormulas.jl](https://github.com/JuliaBrewing/BrewingFormulas.jl), whose
[`REFERENCES.md`](https://github.com/JuliaBrewing/BrewingFormulas.jl/blob/main/REFERENCES.md)
lists their sources: the conversions between gravity and extract, hop utilization
(Tinseth, Rager) and isomerization during hop stands, color (Morey, Daniels, Mosher),
alcohol (Balling), priming and carbonation, water chemistry and mash pH (Kolbach, and the
charge balance of the mash).

The mass balance of fermentation and the original extract of fermented liquors follow
Balling's relations:

- J. De Clerck, *A Textbook of Brewing*, Chapman & Hall, 1958.
- M. L. Hall, "Brew By the Numbers: Add Up What's in Your Beer", *Zymurgy*, Summer 1995.
- J. Šavel et al., *Kvasny prumysl* 66 (2020) 239–244.

Data formats:

- [BeerJSON](https://beerjson.github.io/beerjson/), the JSON format for brewing recipes.
- [JSON Graph Format](https://jsongraphformat.info), for the files of quivers.

The design of BrewQuiver, brewing as a quiver of contents and processes, is described in
the BrewQuiver notes.
