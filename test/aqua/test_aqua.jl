# Aqua — the package-level checks no unit test covers, because they are about the PACKAGE rather
# than about any one function: an exported name with no binding, a method ambiguity, a declared
# dependency nothing uses, an extra with no compat bound.
#
# `undefined_exports` is the one that earns its place here: every feature lands by adding a name to
# the `export` list, and a typo there is invisible until a caller reaches for it.

using DataVault, Test
using Aqua

@testset "Aqua" begin
    Aqua.test_all(DataVault)
end
