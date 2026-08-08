# his_part_ALM.jl — S2 of task 2026-08-09-reference-implementation-bakeoff.
#
# HIS part, HIS grid, HIS boundary conditions, run through GridapTopOpt.jl's
# augmented-Lagrangian level-set optimiser. Nothing about the physics is
# re-derived here: every voxel tag, every clamped node and the load resultant
# come out of core's own `build_production_loadcase` via
# `portable_problem_export`, and are read below as raw arrays.
#
# The structure of the optimisation — the interpolation, the evolver, the
# reinitialiser, the velocity extension, the ALM loop — is
# scripts/Examples/BoundarySmoothing/MPI/3d_elastic_compliance_ALM.jl with only
# the domain, the boundary conditions and two mask factors changed.
#
# ★ NO ANALYTIC SHAPE DERIVATIVE IS SUPPLIED. The masks below change the weak
# forms; a hand-written dJ would then have to be re-derived to match them, and a
# wrong re-derivation is exactly the failure mode this task exists to rule out.
# GridapTopOpt differentiates the forms as written — PDEConstrainedFunctionals:
# "By default we use automatic differentiation for the objective and all
# constraints." Every sensitivity below is therefore theirs.
#
# usage:
#   julia --project=env his_part_ALM.jl <problem_dir> <out_dir> <vf> <max_iter> [coarsen]

using Gridap, Gridap.Geometry, Gridap.CellData, Gridap.TensorValues
using GridapTopOpt
using GridapPETSc, GridapSolvers, SparseMatricesCSR
using LinearAlgebra, Printf, JSON
include(joinpath(@__DIR__, "edt.jl")); using .EDT

const PROBLEM_DIR = ARGS[1]
const OUT_DIR     = ARGS[2]
const VF          = parse(Float64, ARGS[3])
const MAX_ITER    = parse(Int, ARGS[4])
const COARSEN     = length(ARGS) > 4 ? parse(Int, ARGS[5]) : 1
# ★ WARM START, because HIS LADDER IS WARM-STARTED. core seeds rung k+1 from
# rung k's converged design (`warm_start_inherit`, on in his run_info), and PR
# 302 measured that at -48%/-39% iterations. Handing rung k+1 a cold hole-seeded
# level set would be a different ladder as well as a slower one. ARGS[6], when
# given, is a previous rung's `phi_nodes.f64` on the SAME lattice.
const WARM_FROM   = length(ARGS) > 5 ? ARGS[6] : ""

# ★ THE SEQUENTIAL ARM (§S2.6 / §S4c). With SEED_DENSITY set to one of his own
# converged rung densities (`design_rung_dump`'s `rung_*.f64`), the initial level
# set is the EXACT SIGNED DISTANCE to that rung's 0.5 level set, and the hole
# seeding is not used at all. The optimiser then starts from HIS topology at HIS
# volume fraction and refines only the boundary — which is both the cheaper
# measurement and the thing §S4c asks whether GridapTopOpt can do.
const SEED_DENSITY = get(ENV, "SEED_DENSITY", "")
const ARM = MAX_ITER < 0 ? "EDT-NOREINIT" :
            MAX_ITER == 0 ? "GTO-SDF" :
            (isempty(SEED_DENSITY) ? "GTO-ALM" : "GTO-SEQ")

mkpath(OUT_DIR)

# ── 1. core's problem, read verbatim ────────────────────────────────────────
const P = JSON.parsefile(joinpath(PROBLEM_DIR, "problem.json"))
const NX0, NY0, NZ0 = P["nx"], P["ny"], P["nz"]
const H0 = P["spacing_mm"]
const OX, OY, OZ = P["origin_mm"]
const EMOD = P["material"]["youngs_modulus_mpa"]
const NU   = P["material"]["poisson"]

nvox0 = NX0 * NY0 * NZ0
solid0 = read!(joinpath(PROBLEM_DIR, "solid.u8"), Vector{UInt8}(undef, nvox0))
mask0  = read!(joinpath(PROBLEM_DIR, "mask.u8"),  Vector{UInt8}(undef, nvox0))

# core's voxel index, x-fastest (problem.json states the order)
vidx0(i, j, k) = (k * NY0 + j) * NX0 + i + 1          # 1-based

# core's node index, x-fastest over (NX0+1, NY0+1, NZ0+1)
const NNX0, NNY0, NNZ0 = NX0 + 1, NY0 + 1, NZ0 + 1
anchor_node0 = falses(NNX0 * NNY0 * NNZ0)
let raw = read!(joinpath(PROBLEM_DIR, "dirichlet.i32"),
                Vector{Int32}(undef, 2 * P["dirichlet_dofs"]))
  # NOTE `2*e - 1`, not `2e-1`: Julia reads the latter as the float 0.2.
  for e in 1:P["dirichlet_dofs"]
    anchor_node0[raw[2*e - 1] + 1] = true
  end
end

# The load resultant, summed from core's own nodal entries rather than restated.
load_total_z = 0.0
let n = P["load_entries"], buf = Vector{UInt8}(undef, 16n)
  read!(joinpath(PROBLEM_DIR, "loads.bin"), buf)
  io = IOBuffer(buf)
  for _ in 1:n
    read(io, Int32); read(io, Int32)
    global load_total_z += read(io, Float64)
  end
end

# ── 2. optional coarsening, for the smoke run only ──────────────────────────
# A coarsened arm is NEVER reported in the table — it exists so the script can be
# debugged in seconds instead of hours. `coarsen` is written into the meta file
# so a coarse row can never be mistaken for a measurement on his grid.
const C = COARSEN
const NX, NY, NZ = cld(NX0, C), cld(NY0, C), cld(NZ0, C)
const H = H0 * C

solid = Vector{UInt8}(undef, NX * NY * NZ)
mask  = Vector{UInt8}(undef, NX * NY * NZ)
vidx(i, j, k) = (k * NY + j) * NX + i + 1
if C == 1
  solid .= solid0; mask .= mask0
else
  # majority-ish coarsening: solid if any child solid; frozen if any child frozen
  for k in 0:NZ-1, j in 0:NY-1, i in 0:NX-1
    s = UInt8(0); m = UInt8(2)
    for dk in 0:C-1, dj in 0:C-1, di in 0:C-1
      ii, jj, kk = i*C+di, j*C+dj, k*C+dk
      (ii >= NX0 || jj >= NY0 || kk >= NZ0) && continue
      v = vidx0(ii, jj, kk)
      solid0[v] != 0 && (s = max(s, solid0[v]))
      mask0[v] == 1 && (m = UInt8(1))
      mask0[v] == 0 && m != 1 && (m = UInt8(0))
    end
    solid[vidx(i,j,k)] = s
    mask[vidx(i,j,k)]  = s == 0 ? UInt8(2) : m
  end
end

const NNX, NNY, NNZ = NX + 1, NY + 1, NZ + 1
nidx(i, j, k) = (k * NNY + j) * NNX + i + 1
anchor_node = falses(NNX * NNY * NNZ)
if C == 1
  anchor_node .= anchor_node0
else
  for k in 0:NNZ-1, j in 0:NNY-1, i in 0:NNX-1
    ii, jj, kk = min(i*C, NNX0-1), min(j*C, NNY0-1), min(k*C, NNZ0-1)
    anchor_node[nidx(i,j,k)] = anchor_node0[(kk*NNY0 + jj)*NNX0 + ii + 1]
  end
end

# A node may MOVE only if it touches an Active cell. Everywhere else the
# extension velocity is pinned to zero, which is how a level-set method holds a
# region fixed — the same device the reference script uses on Gamma_N.
movable_node = falses(NNX * NNY * NNZ)
for k in 0:NZ-1, j in 0:NY-1, i in 0:NX-1
  mask[vidx(i,j,k)] == 0 || continue
  for dk in 0:1, dj in 0:1, di in 0:1
    movable_node[nidx(i+di, j+dj, k+dk)] = true
  end
end

n_part   = count(!=(0), solid)
n_active = count(==(0), mask)
n_frozen = count(==(1), mask)
n_load_c = count(==(4), solid)
@printf("grid %d x %d x %d (coarsen %d), h = %.9f mm\n", NX, NY, NZ, C, H)
@printf("part cells %d, active %d, frozen-solid %d, load-tagged %d\n",
        n_part, n_active, n_frozen, n_load_c)
@printf("anchor nodes %d, movable nodes %d of %d\n",
        count(anchor_node), count(movable_node), length(movable_node))
@printf("load resultant z = %.8f N\n", load_total_z)

# ── 3. the FE model on HIS bounding box ─────────────────────────────────────
const DOM = (OX, OX + NX*H, OY, OY + NY*H, OZ, OZ + NZ*H)
model = CartesianDiscreteModel(DOM, (NX, NY, NZ))
el_Δ = get_el_Δ(model)

# Coordinate -> lattice index. Rounding is safe: every query is either a node
# coordinate or a cell centroid of THIS grid, so it lands within 1e-9 of a
# lattice point. A query that does not is a bug, and it is caught rather than
# silently clamped.
function node_ijk(x)
  i = round(Int, (x[1] - OX) / H); j = round(Int, (x[2] - OY) / H)
  k = round(Int, (x[3] - OZ) / H)
  (clamp(i,0,NX), clamp(j,0,NY), clamp(k,0,NZ))
end
at_anchor(x) = (ijk = node_ijk(x); anchor_node[nidx(ijk...)])
at_pinned(x) = (ijk = node_ijk(x); !movable_node[nidx(ijk...)])

# ★ THREE DISJOINT ENTITIES, NOT TWO OVERLAPPING TAGS. `update_labels!` writes
# ONE entity per vertex (`labels.d_to_dface_to_entity[1][vtxs] .= entity`), so
# two overlapping calls do not union — the second silently ERASES the first.
# Every anchor node on his part is inside the frozen anchor pad and therefore
# also pinned, so tagging anchor-then-pinned left "Gamma_D" with zero DOFs and
# the run went ahead unclamped. Disjoint entities, recomposed with
# `add_tag_from_tags!`, is the fix; the printed clamped-DOF count is the check
# that it took.
# ★ AND `update_labels!` ITSELF CANNOT BE USED AT THIS SIZE. Its 3-D branch
# promotes the marked vertices to edges/faces/cells with
#   [findall(x -> any(x .∈ vtx_edge_connectivity[1:end .!= j]), ...) for j in 1:n]
# (Utilities.jl:130-140) — O(n²) in the number of MARKED VERTICES, allocating a
# copy of the whole connectivity array once per vertex. Their examples tag one
# face of a cube, where n is small. Here "PinOnly" marks ~480,000 of his 491,232
# nodes and the call does not return: a full-resolution run sat at 100% of one
# core for 20 minutes without reaching iteration 0.
#
# `tag_vertices!` below does the VERTEX half of the same job and skips the
# edge/face/cell promotion. That promotion is not needed here and its absence is
# not an approximation: at order 1 every Lagrangian dof sits on a vertex, so the
# Dirichlet dof set a space builds from these tags is decided by the vertex
# entities alone. `verify_labelling.jl` runs BOTH this and their
# `update_labels!` on his problem at coarsen 4 — where theirs is affordable — and
# checks the resulting free/Dirichlet dof counts agree exactly.
function tag_vertices!(model, e::Integer, mask::AbstractVector{Bool}, name::String)
  labels = get_face_labeling(model)
  entity = maximum(labels.d_to_dface_to_entity[end]) + e
  vtx = findall(mask)
  labels.d_to_dface_to_entity[1][vtx] .= entity
  add_tag!(labels, name, [entity])
  return length(vtx)
end

vtx_coords = Gridap.Geometry.get_vertex_coordinates(get_grid_topology(model))
m_anchor = Bool[at_anchor(x) for x in vtx_coords]
m_pinned = Bool[at_pinned(x) for x in vtx_coords]
n_ao = tag_vertices!(model, 1, m_anchor .& .!m_pinned, "AnchorOnly")
n_po = tag_vertices!(model, 2, m_pinned .& .!m_anchor, "PinOnly")
n_ap = tag_vertices!(model, 3, m_anchor .&   m_pinned, "AnchorPin")
let labels = get_face_labeling(model)
  add_tag_from_tags!(labels, "Gamma_D",   ["AnchorOnly", "AnchorPin"])
  add_tag_from_tags!(labels, "Gamma_Pin", ["PinOnly",    "AnchorPin"])
end
@printf("tagged vertices: AnchorOnly %d, PinOnly %d, AnchorPin %d\n", n_ao, n_po, n_ap)

Ω  = Triangulation(model)
order = 1
dΩ = Measure(Ω, 2*order)

# Per-cell mask values, indexed by GRIDAP's own cell numbering — derived from
# each cell's centroid rather than assumed to match core's, so a difference in
# cell ordering between the two libraries cannot silently mis-tag the part.
cellcoords = get_cell_coordinates(Ω)
ncells = num_cells(Ω)
χ_part_v   = zeros(Float64, ncells)
χ_frozen_v = zeros(Float64, ncells)
χ_load_v   = zeros(Float64, ncells)
for c in 1:ncells
  pts = cellcoords[c]
  cx = sum(p -> p[1], pts) / length(pts)
  cy = sum(p -> p[2], pts) / length(pts)
  cz = sum(p -> p[3], pts) / length(pts)
  i = clamp(floor(Int, (cx - OX) / H), 0, NX-1)
  j = clamp(floor(Int, (cy - OY) / H), 0, NY-1)
  k = clamp(floor(Int, (cz - OZ) / H), 0, NZ-1)
  v = vidx(i, j, k)
  χ_part_v[c]   = solid[v] != 0 ? 1.0 : 0.0
  χ_frozen_v[c] = mask[v]  == 1 ? 1.0 : 0.0
  χ_load_v[c]   = solid[v] == 4 ? 1.0 : 0.0
end
@assert sum(χ_part_v) == n_part "cell-centroid mapping lost part cells"
@assert sum(χ_load_v) == n_load_c "cell-centroid mapping lost load cells"

χ_part   = CellField(χ_part_v, Ω)
χ_frozen = CellField(χ_frozen_v, Ω)
χ_load   = CellField(χ_load_v, Ω)

const VOL_CELL = H^3
const V_PART   = n_part * VOL_CELL

# ── 4. spaces ───────────────────────────────────────────────────────────────
reffe        = ReferenceFE(lagrangian, VectorValue{3,Float64}, order)
reffe_scalar = ReferenceFE(lagrangian, Float64, order)
V = TestFESpace(model, reffe; dirichlet_tags=["Gamma_D"])
U = TrialFESpace(V, VectorValue(0.0, 0.0, 0.0))
V_φ   = TestFESpace(model, reffe_scalar)
V_reg = TestFESpace(model, reffe_scalar; dirichlet_tags=["Gamma_Pin"])
U_reg = TrialFESpace(V_reg, 0.0)
@printf("displacement DOFs (free) %d, clamped %d\n",
        num_free_dofs(V), num_dirichlet_dofs(V))

# ── 5. the initial level set ────────────────────────────────────────────────
# Solid in the part, void outside it, and the reference script's own hole
# seeding inside the ACTIVE region. A level-set method cannot nucleate holes, so
# a run started from the full part could only shrink inward from the surface;
# `initial_lsf` is GridapTopOpt's own seeder and is used unmodified.
# ★ THEIR SEEDING, SCALED TO HIS UNITS. `initial_lsf(ξ,a)` is
# -1/4*prod(cos(ξ*π*xᵢ)) - a/4, so its holes repeat with period 2/ξ IN MODEL
# UNITS. Their examples run on a 2x1x1 domain, where ξ=4 puts four holes across
# it. His part is 218 mm across: ξ=4 there is a 0.5 mm period, ALIASED four times
# finer than his 1.705 mm voxel, and the reinitialiser collapses it to an
# all-solid field (max φ exactly 0.000; see `diag_scale.jl`). ξ = 2/(8H) puts a
# hole every 8 voxels — 13.6 mm, comfortably above his 2.5 mm minimum feature.
const HOLE_CELLS = 8
seed = let f = initial_lsf(2 / (HOLE_CELLS * H), 0.2); x -> H * f(x) end

# ★ AND IT IS STARTED AS A SIGNED DISTANCE, not as a step. The first attempt
# initialised phi to +/- one voxel; the reinitialiser then had no interior to
# distance from and the run lost 20% of the frozen pad and put 5.5% of the
# part's volume OUTSIDE the part within three iterations. A level-set method
# assumes a distance-like phi; handing it a step is an implementation defect of
# OURS, and mistaking it for the method's verdict is precisely what this task
# exists to prevent. The classification below is the target set; the distance is
# a plain 6-neighbour BFS in cell units, used ONLY to initialise.
inside0 = falses(NX * NY * NZ)
if !isempty(SEED_DENSITY)
  ρ_simp = read!(SEED_DENSITY, Vector{Float64}(undef, NX * NY * NZ))
  for v in eachindex(inside0)
    inside0[v] = ρ_simp[v] > 0.5
  end
  @printf("SEQUENTIAL arm: φ0 from %s — %d of %d cells above iso 0.5 (%.4f of the part)\n",
          SEED_DENSITY, count(inside0), NX*NY*NZ, count(inside0) / n_part)
else
let
  cx0(i) = OX + (i + 0.5) * H
  cy0(j) = OY + (j + 0.5) * H
  cz0(k) = OZ + (k + 0.5) * H
  for k in 0:NZ-1, j in 0:NY-1, i in 0:NX-1
    v = vidx(i, j, k)
    inside0[v] = if solid[v] == 0
      false                                  # outside the part: void
    elseif mask[v] == 1
      true                                   # anchor/load pad, face protection
    else
      seed(VectorValue(cx0(i), cy0(j), cz0(k))) < 0   # their hole seeding
    end
  end
end
end

# unsigned BFS distance, in cells, from the interface — one pass per side
function bfs_distance(target::BitVector)
  D = fill(typemax(Int32), NX * NY * NZ)
  q = Int[]
  for k in 0:NZ-1, j in 0:NY-1, i in 0:NX-1
    v = vidx(i, j, k)
    target[v] || continue
    D[v] = 0; push!(q, v)
  end
  head = 1
  while head <= length(q)
    v = q[head]; head += 1
    kk, r = divrem(v - 1, NX * NY)
    jj, ii = divrem(r, NX)
    for (di, dj, dk) in ((1,0,0),(-1,0,0),(0,1,0),(0,-1,0),(0,0,1),(0,0,-1))
      a, b, c = ii+di, jj+dj, kk+dk
      (a < 0 || b < 0 || c < 0 || a >= NX || b >= NY || c >= NZ) && continue
      w = vidx(a, b, c)
      if D[w] > D[v] + 1
        D[w] = D[v] + 1; push!(q, w)
      end
    end
  end
  return D
end
d_to_void  = isempty(SEED_DENSITY) ? bfs_distance(.!inside0) : Int[]
d_to_solid = isempty(SEED_DENSITY) ? bfs_distance(inside0)  : Int[]
# ★ THE BFS DISTANCE IS USED FOR THE PART ENVELOPE AND THE PAD ONLY. Inside the
# ACTIVE region the initial level set stays GridapTopOpt's own smooth `initial_lsf`
# seeding. A fully-BFS initial field — piecewise constant, with isolated one-cell
# islands where the seeding is thresholded — makes their first-order upwind
# reinitialiser return NaN at a handful of nodes, and `H_η` then falls straight
# through (its branches are t<-η, |t|<=η, t>η; NaN matches none, so it returns
# `nothing` and the run dies in `-(::Int64, ::Nothing)`). Measured on his own
# problem at coarsen 4: pure BFS 9 NaN nodes at both band 2 and band 5, this
# hybrid 0. See `diag_init.jl` and the handoff's R5.
const BAND = 5.0

# ★ THE SEQUENTIAL ARM GETS AN EXACT EUCLIDEAN SIGNED DISTANCE, not the
# 6-neighbour BFS. The BFS distance is an L1 distance: its gradient is wrong by
# up to 73% on diagonals and is DISCONTINUOUS, and their first-order upwind
# reinitialiser assumes |∇φ| ≈ 1. Measured on his part at full resolution
# (`diag_edt.jl`): BFS over the whole part → 6767 NaN nodes out of 491,232;
# exact EDT over the same set → 0. See R5.
φ_seq = isempty(SEED_DENSITY) ? Float64[] :
        edt_signed(BitVector(inside0), NX, NY, NZ, H, BAND)

function φ0_fun(x)
  isempty(φ_seq) || return begin
    i = clamp(floor(Int, (x[1] - OX) / H), 0, NX-1)
    j = clamp(floor(Int, (x[2] - OY) / H), 0, NY-1)
    k = clamp(floor(Int, (x[3] - OZ) / H), 0, NZ-1)
    φ_seq[vidx(i, j, k)]
  end
  i = clamp(floor(Int, (x[1] - OX) / H), 0, NX-1)
  j = clamp(floor(Int, (x[2] - OY) / H), 0, NY-1)
  k = clamp(floor(Int, (x[3] - OZ) / H), 0, NZ-1)
  v = vidx(i, j, k)
  if solid[v] == 0
    return  clamp((d_to_solid[v] - 0.5) * H, 0.0, BAND * H)   # void, outward SDF
  elseif mask[v] == 1
    return -clamp((d_to_void[v]  - 0.5) * H, 0.0, BAND * H)   # pad, inward SDF
  else
    return seed(x)                                            # their seeding
  end
end
φ_cell0 = [φ0_fun(VectorValue(OX + (i + 0.5) * H, OY + (j + 0.5) * H,
                              OZ + (k + 0.5) * H))
           for k in 0:NZ-1 for j in 0:NY-1 for i in 0:NX-1]
φh = interpolate(φ0_fun, V_φ)
if !isempty(WARM_FROM)
  warm = read!(WARM_FROM, Vector{Float64}(undef, NNX * NNY * NNZ))
  vals = get_free_dof_values(φh)
  vtx  = Gridap.Geometry.get_vertex_coordinates(get_grid_topology(model))
  for n in eachindex(vtx)
    vals[n] = warm[nidx(node_ijk(vtx[n])...)]
  end
  @printf("WARM START from %s — range [%.3f, %.3f] mm\n",
          WARM_FROM, minimum(vals), maximum(vals))
end
@printf("initial LSF: inside %d cells (%.4f of the part), range [%.3f, %.3f] mm\n",
        count(inside0), count(inside0) / n_part, minimum(φ_cell0), maximum(φ_cell0))

# ── 6. the reference script's operators, unchanged in structure ─────────────
const Cmat = isotropic_elast_tensor(3, EMOD, NU)
γ        = 0.1
γ_reinit = 0.5
max_steps = floor(Int, order * minimum((NX, NY, NZ)) / 5)
tol       = 1 / (5order^2) / minimum((NX, NY, NZ))
# ★ η IS THE CONTROL THIS WHOLE COMPARISON TURNS ON, so it is a knob rather than
# a constant. `SmoothErsatzMaterialInterpolation(η = η_coeff*max(el_Δ))` sets how
# wide the relaxed Heaviside ramps across the boundary, and ρ = 1 - H(φ) is what
# this arm exports as its occupancy. At their default η_coeff = 2 that ramp is
# +/- 2 voxels — a FOUR-VOXEL-WIDE smoothing kernel — and a surface extracted
# from it would be smoother for the same reason a blur is smoother, which is a
# thing PR 299 already refused. Sweeping η_coeff is what separates "a level-set
# REPRESENTATION places the boundary better" from "their default ersatz
# bandwidth is a two-voxel blur".
η_coeff   = parse(Float64, get(ENV, "ETA_COEFF", "2"))
α_coeff   = 4 * max_steps * γ

interp = SmoothErsatzMaterialInterpolation(η = η_coeff * maximum(el_Δ))
I, H_f, DH, ρ = interp.I, interp.H, interp.DH, interp.ρ

# The two mask factors. `mult` is 1 in the frozen-solid pad and the ersatz
# interpolation everywhere else; `ρ_eff` is the matching volume density.
# ★ THE PART MASK IS ON THE STIFFNESS, and it has to be. Without it the level set
# may grow OUTSIDE the imported part and collect FULL modulus for doing so:
# measured on his own problem, 8.4% of the part's volume had moved outside the
# part by iteration 20 and was still climbing. His part is the ENVELOPE — the
# reduction ladder removes material from it and never adds any — so outside it
# the stiffness is pinned at the ersatz floor whatever φ does there.
#
# It is pinned at `ϵ` and not at zero because an ersatz level-set formulation
# needs a non-singular operator on the WHOLE box. That is the floor `I` itself
# bottoms out at, so the exterior is exactly as stiff as void and no stiffer.
# ★ THIS PARTICULAR FIDELITY LOSS IS STRUCTURAL: core drops Empty voxels from the
# FEA altogether, and a level-set method on a Cartesian background cannot. See
# the handoff §S1.2.
#
# `ρ_eff` is NOT part-masked, deliberately. Material that drifts outside the part
# then still costs volume budget while gaining no stiffness, so the optimiser has
# a reason to pull it back rather than merely no reason to grow it. The "solid
# outside the part" control below is what says whether it did.
const ϵ_ersatz = first(interp.ϵ)
mult(φ)  = χ_part * (χ_frozen + (1.0 - χ_frozen) * (I ∘ φ)) +
           (1.0 - χ_part) * ϵ_ersatz
ρ_eff(φ) = χ_frozen + (1.0 - χ_frozen) * (ρ ∘ φ)

# The load as a body force over core's own 5165 Load-tagged voxels, scaled to
# core's own resultant. ★ THIS IS A STATED FIDELITY LOSS: core applies a
# consistent nodal traction over the exposed faces of those voxels
# (topopt::traction_loads, 7382 nodes); this is the statically equivalent body
# force over the same voxels. Same total, same support, different distribution
# within it.
const GZ = load_total_z / (n_load_c * VOL_CELL)
gvec = VectorValue(0.0, 0.0, GZ)

a(u, v, φ) = ∫( mult(φ) * (Cmat ⊙ ε(u) ⊙ ε(v)) )dΩ
l(v, φ)    = ∫( χ_load * (v ⋅ gvec) )dΩ
J(u, φ)    = ∫( mult(φ) * (Cmat ⊙ ε(u) ⊙ ε(u)) )dΩ
Vol(u, φ)  = ∫( (ρ_eff(φ) - VF * χ_part) / V_PART )dΩ

evo    = FiniteDifferenceEvolver(FirstOrderStencil(3, Float64), model, V_φ; max_steps)
reinit = FiniteDifferenceReinitialiser(FirstOrderStencil(3, Float64), model, V_φ; tol, γ_reinit)
ls_evo = LevelSetEvolution(evo, reinit)

# ── PETSc, and everything that needs it ─────────────────────────────────────
# The reference script wraps its whole `main` in `GridapPETSc.with(...)`; the
# solver objects below are PETSc handles and cannot be constructed outside it.
# The options string is the reference script's, verbatim.
const PETSC_OPTS = "-pc_type gamg -ksp_type cg -ksp_error_if_not_converged true
  -ksp_converged_reason -ksp_rtol 1.0e-12"

GridapPETSc.with(args=split(PETSC_OPTS)) do
  Tm = SparseMatrixCSR{0,PetscScalar,PetscInt}
  Tv = Vector{PetscScalar}
  solver = ElasticitySolver(V)

  state_map = AffineFEStateMap(
    a, l, U, V, V_φ;
    assem_U       = SparseMatrixAssembler(Tm, Tv, U, V),
    assem_adjoint = SparseMatrixAssembler(Tm, Tv, V, U),
    assem_deriv   = SparseMatrixAssembler(Tm, Tv, V_φ, V_φ),
    ls = solver, adjoint_ls = solver
  )
  pcfs = PDEConstrainedFunctionals(J, [Vol], state_map)   # AD — see the header

  α = α_coeff * maximum(el_Δ)
  a_hilb(p, q) = ∫( α^2 * ∇(p) ⋅ ∇(q) + p*q )dΩ
  vel_ext = VelocityExtension(a_hilb, U_reg, V_reg;
    assem = SparseMatrixAssembler(Tm, Tv, U_reg, V_reg), ls = PETScLinearSolver())

  optimiser = AugmentedLagrangian(pcfs, ls_evo, vel_ext, φh;
    γ, verbose=true, constraint_names=[:Vol], maxiter=MAX_ITER)

  # ── 7. run ──────────────────────────────────────────────────────────────────
  # ★ MAX_ITER == 0 IS THE REPRESENTATION-ONLY ARM (GTO-SDF). It runs THEIR
  # reinitialiser on φ0 and stops: no state solve, no optimisation. It answers
  # the question underneath the whole comparison — is a LEVEL-SET REPRESENTATION
  # of the very same design smoother than the density threshold his pipeline
  # extracts? If it is not, no amount of level-set optimisation on top of it can
  # be, and that is worth knowing before spending hours per rung finding out.
  if MAX_ITER == 0
    t0 = time()
    GridapTopOpt.reinit!(ls_evo, φh)
    wall0 = time() - t0
    @printf("\nREPRESENTATION-ONLY ARM: reinitialised in %.3f s, no optimisation\n", wall0)
  elseif MAX_ITER < 0
    # ★ THE OTHER HALF OF THE CONTROL: no reinitialisation either. φ is left as
    # the exact EDT this task computed, so whatever this row shows is OURS and
    # not GridapTopOpt's. The difference between this row and the MAX_ITER == 0
    # row is exactly what their reinitialiser contributed.
    @printf("\nNO-REINIT CONTROL: φ0 exported as computed, nothing from GridapTopOpt ran on it\n")
  end

  t0 = time()
  it_count = 0
  # The reference script's own loop. `φ_final` / `u_final` are captured from the
  # iterate rather than fetched afterwards, which is how the reference script
  # gets them; there is no public accessor for the converged level set.
  # `φ_final`, not `φh` — `φh` is the INITIAL level set, bound outside this
  # closure, and rebinding it here would make it a read before assignment.
  φ_final = φh
  u_final = nothing
  if MAX_ITER > 0
    for (it, uh_it, φh_it) in optimiser
      it_count = it
      φ_final = φh_it
      u_final = uh_it
      write_history(joinpath(OUT_DIR, "history.txt"), optimiser.history)
    end
  end
  wall = time() - t0
  # No state solve happened in the representation-only arm, so there is no
  # displacement and no compliance. Reported as NaN rather than as 0.
  uh = u_final

  # ── 8. what comes out, in the two readings the probe asks for ───────────────
  #
  #  (B) `cells` — ρ(φ) at CELL CENTRES on his design lattice. This is what his
  #      pipeline would see: it goes through the SAME shipped extraction SIMP's
  #      density goes through (tricubic x2, MC at 0.5).
  #  (A) `nodes` — ρ(φ) at the NODES, the lattice the level set actually lives on,
  #      extracted at factor 1. This is the level-set method's OWN surface.
  #
  # ρ, not φ: ρ is GridapTopOpt's own relaxed Heaviside, the function its volume
  # constraint integrates, with ρ(0) = 0.5. Exporting it rather than φ keeps the
  # iso, the bandwidth and the void convention on their side of the line.
  ρh = interpolate(ρ ∘ φ_final, V_φ)

  # nodal values, placed on the lattice by coordinate so no DOF-ordering
  # assumption is made
  # `get_vertex_coordinates(topology)` is the SAME accessor GridapTopOpt's own
  # `mark_nodes` uses, so the ordering here is the ordering its labelling used.
  # The assert is the check that V_φ's free dofs are those vertices one-for-one;
  # if a future Gridap changed that, this would stop rather than write a
  # silently permuted field.
  node_coords = Gridap.Geometry.get_vertex_coordinates(get_grid_topology(model))
  ρ_nodal = get_free_dof_values(ρh)
  @assert length(ρ_nodal) == length(node_coords) == NNX*NNY*NNZ
  ρ_nodes = zeros(Float64, NNX * NNY * NNZ)
  for n in eachindex(node_coords)
    ijk = node_ijk(node_coords[n])
    ρ_nodes[nidx(ijk...)] = ρ_nodal[n]
  end
  ρ_cells = zeros(Float64, NX * NY * NZ)
  for k in 0:NZ-1, j in 0:NY-1, i in 0:NX-1
    s = 0.0
    for dk in 0:1, dj in 0:1, di in 0:1
      s += ρ_nodes[nidx(i+di, j+dj, k+dk)]
    end
    ρ_cells[vidx(i,j,k)] = s / 8
  end

  # ── the controls this run owes ──────────────────────────────────────────────
  achieved_vf   = sum(ρ_cells) * VOL_CELL / V_PART
  solid_outside = sum(c -> ρ_cells[c] > 0.5 && solid[c] == 0 ? 1 : 0, 1:NX*NY*NZ)
  frozen_kept   = sum(c -> mask[c] == 1 ? (ρ_cells[c] > 0.5 ? 1 : 0) : 0, 1:NX*NY*NZ)
  # The INTERIOR of the pad — a pad cell all six of whose neighbours are also pad.
  # A pad cell on the pad's own boundary shares nodes with the active region, so
  # its cell-average legitimately dips below 0.5 and the loose count above
  # understates how well the pad was held. This one has no such excuse.
  frozen_interior = 0; frozen_interior_kept = 0
  for k in 1:NZ-2, j in 1:NY-2, i in 1:NX-2
    c = vidx(i,j,k)
    mask[c] == 1 || continue
    all(mask[vidx(i+di,j+dj,k+dk)] == 1 for (di,dj,dk) in
        ((1,0,0),(-1,0,0),(0,1,0),(0,-1,0),(0,0,1),(0,0,-1))) || continue
    frozen_interior += 1
    ρ_cells[c] > 0.5 && (frozen_interior_kept += 1)
  end
  compliance    = uh === nothing ? NaN : sum(J(uh, φ_final))

  @printf("\nITERATIONS %d   WALL %.3f s\n", it_count, wall)
  @printf("compliance %.10g\n", compliance)
  @printf("achieved vf (part-relative) %.6f  target %.6f\n", achieved_vf, VF)
  @printf("★ solid OUTSIDE the part: %d cells (%.4f%% of the part)\n",
          solid_outside, 100 * solid_outside / n_part)
  @printf("★ frozen-solid cells still solid: %d of %d (%.2f%%)\n",
          frozen_kept, n_frozen, 100 * frozen_kept / n_frozen)
  @printf("★ pad INTERIOR still solid: %d of %d (%.2f%%)\n",
          frozen_interior_kept, frozen_interior,
          frozen_interior == 0 ? 0.0 : 100 * frozen_interior_kept / frozen_interior)

  # φ itself, on the node lattice, so the next rung can warm-start from it.
  let φ_nodal = get_free_dof_values(φ_final), φ_nodes = zeros(Float64, NNX*NNY*NNZ)
    for n in eachindex(node_coords)
      φ_nodes[nidx(node_ijk(node_coords[n])...)] = φ_nodal[n]
    end
    write(joinpath(OUT_DIR, "phi_nodes.f64"), φ_nodes)
  end
  write(joinpath(OUT_DIR, "rho_cells.f64"), ρ_cells)
  write(joinpath(OUT_DIR, "rho_nodes.f64"), ρ_nodes)

  function meta(path, nx, ny, nz, h, ox, oy, oz, lattice, factor, interp_name)
    open(path, "w") do f
      println(f, "rung $(@sprintf("%.2f", VF))")
    println(f, "arm $ARM")
      println(f, "requested_vf $VF")
      println(f, "achieved_vf $achieved_vf")
      println(f, "iterations $it_count")
      println(f, "wall_s $wall")
      println(f, "compliance $compliance")
      println(f, "nx $nx"); println(f, "ny $ny"); println(f, "nz $nz")
      println(f, "spacing $h")
      println(f, "ox $ox"); println(f, "oy $oy"); println(f, "oz $oz")
      println(f, "iso 0.5")
      println(f, "factor $factor")
      println(f, "interp $interp_name")
      println(f, "lattice $lattice")
      println(f, "coarsen $C")
    println(f, "eta_coeff $η_coeff")
      println(f, "solid_outside_part $solid_outside")
      println(f, "frozen_kept $frozen_kept of $n_frozen")
      println(f, "frozen_interior_kept $frozen_interior_kept of $frozen_interior")
    end
  end
  meta(joinpath(OUT_DIR, "rho_cells.meta"), NX, NY, NZ, H, OX, OY, OZ,
       "design", 2, "tricubic")
  meta(joinpath(OUT_DIR, "rho_nodes.meta"), NNX, NNY, NNZ, H,
       OX - H/2, OY - H/2, OZ - H/2, "node", 1, "none")

  open(joinpath(OUT_DIR, "summary.json"), "w") do f
    JSON.print(f, Dict(
      "vf" => VF, "coarsen" => C, "iterations" => it_count, "wall_s" => wall,
      "compliance" => (isnan(compliance) ? "NA" : compliance), "achieved_vf" => achieved_vf,
      "solid_outside_part" => solid_outside, "frozen_kept" => frozen_kept,
      "frozen_interior_kept" => frozen_interior_kept,
      "frozen_interior" => frozen_interior,
      "n_frozen" => n_frozen, "n_part" => n_part,
      "free_dofs" => num_free_dofs(V), "load_resultant_z" => load_total_z,
      "arm" => ARM), 2)
  end
  println("wrote ", OUT_DIR)

end  # GridapPETSc.with
