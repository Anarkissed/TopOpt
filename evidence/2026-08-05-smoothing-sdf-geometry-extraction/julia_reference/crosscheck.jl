# crosscheck.jl — drive the PAPER'S OWN reference implementation, rho2sdf.jl
# v0.1.0 (MIT, https://github.com/kopacja/rho2sdf.jl), on a case small enough for
# it to finish, and dump the intermediates the C++ port has to reproduce.
#
# WHY THIS EXISTS. Task 2026-08-05-smoothing-sdf-geometry-extraction says to use
# rho2sdf.jl offline to answer S1. It cannot be driven from the maintainer's
# density field directly — `Sign_Detection_HEX8` scans every element for every
# grid point (SignDetection.jl:29), which on his run is 468,224 x 487,620 AABB
# tests — so S1 is measured by a port, and this script is what proves the port is
# the same method rather than a lookalike.
#
# THE CASE: a regular 12x12x12 grid of unit hex elements with a grayscale radial
# density ramp — small (1,728 elements, 2,197 nodes), REGULAR (so it exercises
# exactly the specialisation the port claims), and GRAYSCALE (so the nodal
# least-squares fit has something to fit).
#
#   julia --project=<rho2sdf.jl clone> crosscheck.jl <out.txt>
#
# JULIA IS NOT A DEPENDENCY of this repo. Nothing in core/, app/ or CI runs it;
# this file records how the reference was invoked so the comparison can be redone.

using Pkg
using Printf
using Rho2sdf
using Rho2sdf.MeshGrid
using Rho2sdf.SignedDistances
using Rho2sdf.ShapeFunctions
using Rho2sdf.ElementTypes

const NE = 12                # elements per axis
const H = 1.0                # element size
const R = 4.0                # radius of the density ramp
const W = 2.0                # ramp width

outpath = length(ARGS) >= 1 ? ARGS[1] : "crosscheck_reference.txt"

# ── the mesh: nodes, HEX8 connectivity, element densities ────────────────────
nn = NE + 1
nodeid(i, j, k) = i + 1 + j * nn + k * nn * nn      # i,j,k are 0-based
X = Vector{Vector{Float64}}(undef, nn^3)
for k in 0:NE, j in 0:NE, i in 0:NE
  X[nodeid(i, j, k)] = [i * H, j * H, k * H]
end

IEN = Vector{Vector{Int64}}(undef, NE^3)
rho = Vector{Float64}(undef, NE^3)
centre = [NE * H / 2, NE * H / 2, NE * H / 2]
elid(i, j, k) = i + 1 + j * NE + k * NE * NE
for k in 0:NE-1, j in 0:NE-1, i in 0:NE-1
  # standard HEX8 ordering: (-,-,-) (+,-,-) (+,+,-) (-,+,-) then the same at +z
  IEN[elid(i, j, k)] = [
    nodeid(i,     j,     k),
    nodeid(i + 1, j,     k),
    nodeid(i + 1, j + 1, k),
    nodeid(i,     j + 1, k),
    nodeid(i,     j,     k + 1),
    nodeid(i + 1, j,     k + 1),
    nodeid(i + 1, j + 1, k + 1),
    nodeid(i,     j + 1, k + 1),
  ]
  c = [(i + 0.5) * H, (j + 0.5) * H, (k + 0.5) * H]
  d = sqrt(sum((c .- centre) .^ 2))
  rho[elid(i, j, k)] = clamp((R - d) / W + 0.5, 0.0, 1.0)
end

# ── the reference's own stages ───────────────────────────────────────────────
shape_func = coords -> shape_functions(HEX8, coords)
mesh = Mesh(X, IEN, rho, shape_func; element_type = HEX8)

ρₙ = DenseInNodes(mesh, rho)                     # §4.1, the least-squares fit
ρₜ = find_threshold_for_volume(mesh, ρₙ)         # §4.1, volume-matched threshold

# SDF grid at spacing == element size, the paper's own recommendation (§5.2.2).
X_min, X_max = MeshGrid.getMesh_AABB(mesh.X)
N_new = floor(Int, maximum(X_max .- X_min) / H)
sdf_grid = MeshGrid.Grid(X_min, X_max, N_new, 3)
points = generateGridPoints(sdf_grid)

(dists, xp) = evalDistances(mesh, sdf_grid, points, ρₙ, ρₜ)   # §4.2.1
signs = Sign_Detection(mesh, sdf_grid, points, ρₙ, ρₜ)        # §4.2.2
sdf = dists .* signs

open(outpath, "w") do io
  println(io, "# rho2sdf.jl v0.1.0 reference run — regular $(NE)^3 hex grid, h=$(H)")
  println(io, "# columns after each header are printed to 12 significant digits")
  @printf(io, "V_domain %.12g\n", mesh.V_domain)
  @printf(io, "V_frac %.12g\n", mesh.V_frac)
  @printf(io, "target_volume %.12g\n", mesh.V_domain * mesh.V_frac)
  @printf(io, "rho_t %.12g\n", ρₜ)
  @printf(io, "grid_N %d %d %d\n", sdf_grid.N[1], sdf_grid.N[2], sdf_grid.N[3])
  @printf(io, "grid_cell_size %.12g\n", sdf_grid.cell_size)
  @printf(io, "grid_min %.12g %.12g %.12g\n", sdf_grid.AABB_min...)
  println(io, "nodal_densities $(length(ρₙ))")
  for v in ρₙ
    @printf(io, "%.12g\n", v)
  end
  println(io, "sdf $(length(sdf))")
  for i in 1:length(sdf)
    @printf(io, "%.12g %.12g %.12g %.12g\n", points[1, i], points[2, i],
            points[3, i], sdf[i])
  end
end
println("wrote ", outpath)
