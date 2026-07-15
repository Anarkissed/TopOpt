#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "topopt/mesh.hpp"

namespace topopt {

// Per-voxel classification stored in the grid.
//   Empty      - outside the solid.
//   Interior   - solid, all six face-neighbours are also solid.
//   Surface    - solid, on the boundary of the solid (at least one face-
//                neighbour is Empty or lies outside the grid).
//   UserTagged - solid, claimed by a later stage. The voxelizer never emits
//                this; it exists so the grid can store a generic user tag per
//                voxel (ROADMAP M1.5: "interior / surface / user-tagged").
//   Load       - solid, on a face the user tagged as a load-application face
//                (ROADMAP M1.6). The voxelizer never emits this.
//   Fixture    - solid, on a face the user tagged as a mounting/fixture face
//                (ROADMAP M1.6). The voxelizer never emits this.
enum class VoxelTag : std::uint8_t {
  Empty = 0,
  Interior = 1,
  Surface = 2,
  UserTagged = 3,
  Load = 4,
  Fixture = 5,
};

// Per-voxel design mask for passive regions (ROADMAP M3.7). This is a SEPARATE
// classification from VoxelTag, stored in its own grid-indexed array, so a
// masked voxel keeps its Interior/Surface/Load/Fixture tag: a frozen voxel may
// also be Load or Fixture.
//   Active      - a free design variable: density is updated by the OC step.
//   FrozenSolid - "keep-in": density pinned to 1 and excluded from the OC update
//                 (the voxel is always full material).
//   FrozenVoid  - "keep-out": density pinned to 0, excluded from the design AND
//                 from the FEA stiffness (the voxel contributes no element).
// Empty voxels are never design variables, so their mask entry is ignored.
enum class MaskValue : std::uint8_t {
  Active = 0,
  FrozenSolid = 1,
  FrozenVoid = 2,
};

// A design mask: one MaskValue per grid voxel (grid-indexed, size voxel_count()).
using DesignMask = std::vector<MaskValue>;

// A dense, axis-aligned voxel grid with cubic voxels (one hex FEA element per
// voxel, ARCHITECTURE.md §4). Voxel (i,j,k) occupies the box
// [origin + (i,j,k)*spacing, origin + (i+1,j+1,k+1)*spacing]; its centre is
// origin + (i+0.5, j+0.5, k+0.5)*spacing. Tags are one byte per voxel in
// x-fastest, then y, then z order.
struct VoxelGrid {
  int nx = 0;
  int ny = 0;
  int nz = 0;
  double spacing = 0.0;  // cubic voxel edge length (model units, mm)
  Vec3 origin;           // grid minimum corner (= mesh bounding-box min)
  std::vector<VoxelTag> tags;

  std::size_t index(int i, int j, int k) const {
    return (static_cast<std::size_t>(k) * static_cast<std::size_t>(ny) +
            static_cast<std::size_t>(j)) *
               static_cast<std::size_t>(nx) +
           static_cast<std::size_t>(i);
  }

  VoxelTag tag(int i, int j, int k) const { return tags[index(i, j, k)]; }
  void set_tag(int i, int j, int k, VoxelTag t) { tags[index(i, j, k)] = t; }

  // A voxel is solid iff it is not Empty (Interior, Surface, or UserTagged).
  bool solid(int i, int j, int k) const {
    return tag(i, j, k) != VoxelTag::Empty;
  }

  std::size_t voxel_count() const { return tags.size(); }
  std::size_t solid_count() const;  // number of non-Empty voxels

  double voxel_volume() const { return spacing * spacing * spacing; }
  double solid_volume() const {
    return static_cast<double>(solid_count()) * voxel_volume();
  }

  Vec3 voxel_center(int i, int j, int k) const {
    return Vec3{origin.x + (static_cast<double>(i) + 0.5) * spacing,
               origin.y + (static_cast<double>(j) + 0.5) * spacing,
               origin.z + (static_cast<double>(k) + 0.5) * spacing};
  }
};

// Voxelize a closed triangle mesh into a solid-filled grid. `resolution` is the
// number of voxels along the mesh's longest bounding-box axis; the other axes
// receive enough cubic voxels of the same edge length to cover the bounding
// box, so voxels are cubic (required by the hex-element FEA, §4). Solid voxels
// are tagged Interior or Surface; voxels outside the solid are Empty.
//
// Inside/outside is decided by a vertical (+Z) signed-crossing (winding) scan
// through each voxel centre, which is robust to a ray grazing an edge shared by
// two same-facing triangles. The mesh is expected to be watertight (the §5
// pipeline voxelizes only after the watertight check); an open mesh yields an
// undefined fill. Throws std::invalid_argument if resolution < 1 or the mesh is
// empty / degenerate (zero-volume bounding box).
VoxelGrid voxelize(const TriangleMesh& mesh, int resolution);

// An all-Active design mask sized to `grid` (size grid.voxel_count()): every
// voxel is a free design variable, so the mask-aware SIMP path reproduces the
// unconstrained optimizer. This is the neutral base a caller fills in with
// mask_step_face selections (ROADMAP M3.7).
DesignMask make_active_mask(const VoxelGrid& grid);

// ---------------------------------------------------------------------------
// Design-domain expansion — "add material" beyond the imported part (M7.dom-core).
//
// The M3.7 mask lets the optimizer keep (FrozenSolid) / exclude (FrozenVoid) /
// choose (Active) each voxel, but the Active region has always been a SUBSET of
// the imported part: the optimizer could only REMOVE material from the import.
// This expansion lets it ADD material BEYOND the import — grow ribs, gussets and
// buttresses into empty space along the load path — by voxelizing a larger
// user-defined DESIGN VOLUME and making the space around the part Active.
//
// A DESIGN VOLUME is an axis-aligned box in model space (mm), typically larger
// than the imported part's bounding region. Expanding a part grid over it yields
// a LARGER grid (same voxel lattice/spacing as the part) whose effective mask is:
//   * imported-part voxels          -> FrozenSolid (the guaranteed-kept core: the
//                                      original part is NEVER removed),
//   * caller keep-out box voxels    -> FrozenVoid (the optimizer may not fill
//                                      these; they contribute no FEA element),
//   * the remaining design-volume   -> Active (the NEW material the optimizer can
//     voxels                          grow into),
//   * everything else               -> Empty (outside the design volume and not
//                                      part of the import).
// Running the existing mask-aware SIMP/MMA optimizer over that grid+mask adds
// material in the Active region wherever the load path needs it, on top of the
// frozen imported part.

// An axis-aligned box in model space (mm). `min` must be <= `max` componentwise.
struct DesignBox {
  Vec3 min;
  Vec3 max;
};

// The expanded design domain built from a part grid and a design box: the larger
// grid, its effective mask, and the integer voxel offset at which the original
// part sits inside the expanded grid (part voxel (i,j,k) is expanded voxel
// (i+offset_i, j+offset_j, k+offset_k); part corner-node (a,b,c) is expanded
// corner-node (a+offset_i, b+offset_j, c+offset_k)).
struct DesignDomain {
  VoxelGrid grid;   // expanded grid (same spacing + lattice as the part)
  DesignMask mask;  // FrozenSolid part / FrozenVoid keep-out / Active new region
  int offset_i = 0;
  int offset_j = 0;
  int offset_k = 0;
};

// Expand `part`'s grid so it also covers `design_box`, and build the effective
// mask (rules above). The expanded grid shares the part's `spacing` and lies on
// the part's voxel lattice (the part's corners map to integer offsets), so its
// origin is `part.origin` shifted DOWN by whole voxels and it spans the union of
// the part's bounding box and `design_box`. A design_box smaller than or inside
// the part still works: the offsets are then 0 and the grid equals the part on
// the axes where no padding is needed. Membership in `design_box` / `keep_out`
// is decided by the VOXEL CENTRE (matching the voxelizer's centre-sampling).
//
// `freeze_part` selects what the imported part becomes in the effective mask:
//   * true  (default, the M7.dom-core "add material" feature): part solid voxels
//     become FrozenSolid — the import is never removed and the optimizer may only
//     GROW new material into the Active design volume.
//   * false (handoff 080, Option 2 "whole-domain optimize"): part solid voxels
//     become Active — the optimizer may REMOVE part material as well as grow into
//     the box, so "minimize plastic + a design box" can genuinely reduce plastic
//     against the part. Their original tags (incl. any Load/Fixture face tag) are
//     preserved either way, so the mask-aware simp path still pins the Load/Fixture
//     BC skin FrozenSolid — only the part's INTERIOR becomes a design variable.
// Keep-out voxels that are not part are tagged Empty (mask FrozenVoid) so they
// carry no FEA element and no self-weight; a keep-out box never carves into the
// part regardless of `freeze_part`. New Active voxels are tagged Interior (solid
// design variables at the caller's volume fraction). With a design_box that
// exactly matches the part's bounding box, no keep-out and freeze_part=true, every
// part voxel is FrozenSolid and every in-box empty voxel is Active — offsets 0.
//
// COARSENING ALIGNMENT (design-box on-device fix): `coarsen_align` rounds each
// expanded element dimension (new_nx/ny/nz) UP to the next multiple of that value
// by APPENDING voxels on the HIGH side of each axis (never the low side). The
// appended voxels lie beyond `design_box` (the pre-alignment grid already reached
// design_box.max), so they are classified Empty exactly like any other
// out-of-box voxel: no FEA element, no self-weight, no design variable — the
// void-DOF gate removes their DOFs, so they add NO physics and do NOT change the
// solved result. Because only the high side grows, `offset_i/j/k` and `origin`
// are UNCHANGED, so remap_node_to_domain stays correct with no adjustment.
//
// The purpose is the geometric-multigrid solver: its hierarchy can only coarsen
// (halve) axes whose element count is even, and bails entirely if any axis is
// odd, falling back to an effectively-hung Jacobi-CG on the ~1e-9-contrast
// design-box system. Aligning to a power of two (the driver passes 8) guarantees
// the expanded grid coarsens deep enough for a real hierarchy (>= 3 levels).
// `coarsen_align <= 1` is the exact pre-existing behaviour (no rounding,
// byte-for-byte identical grid); the default is 1 so every existing caller and
// test is unaffected. Throws std::invalid_argument if `coarsen_align < 1`.
DesignDomain expand_design_domain(const VoxelGrid& part,
                                  const DesignBox& design_box,
                                  const std::vector<DesignBox>& keep_out = {},
                                  bool freeze_part = true, int coarsen_align = 1);

// Map a corner-node id of `part`'s node grid to the corresponding corner-node id
// of `domain.grid` (shifted by the domain's voxel offset). Use it to remap
// DirichletBC / NodalLoad node indices from the imported part onto the expanded
// grid. Throws std::invalid_argument if `node` is out of range for `part`.
int remap_node_to_domain(const VoxelGrid& part, const DesignDomain& domain,
                         int node);

// ---------------------------------------------------------------------------
// Marching cubes on a density field + Gate V3 property suite (ROADMAP M3.5).
//
// After the SIMP loop (M3.4) produces a physical density field, M3.5 extracts a
// printable surface (marching cubes at threshold 0.5) and runs the ARCHITECTURE
// §7 V3 property checks on the result. This is the "property checks" pipeline
// stage (§5) that every optimizer output must pass before export.

// Marching cubes over a grid-indexed density field (size grid.voxel_count()),
// samples at voxel centres, background-padded so the surface closes at the grid
// boundary. Thin wrapper over the mesh/ marching_cubes with the grid's geometry.
// Throws std::invalid_argument if density.size() != grid.voxel_count().
TriangleMesh marching_cubes(const VoxelGrid& grid,
                            const std::vector<double>& density, double iso = 0.5);

// Result of the Gate V3 property suite. `passes` is the conjunction of the four
// ARCHITECTURE §7 V3 gates; the individual fields expose why.
struct V3Report {
  TriangleMesh mesh;         // cleaned isosurface (largest component)
  WatertightReport watertight;  // gate 1: closed + 2-manifold
  int mesh_components_raw = 0;   // components of the raw MC output (pre-cleanup)
  int mesh_components = 0;       // gate 2: components of the cleaned mesh (== 1)
  bool load_fixture_retained = false;  // gate 3: all Load/Fixture voxels rho>=0.9
  double min_load_fixture_density = 1.0;  // min rho over Load/Fixture voxels
  int load_fixture_voxels = 0;            // number of Load/Fixture voxels checked
  // M7.anchor-integrity (FIX 3): the number of NON-largest mesh components that
  // genuinely bound frozen Load/Fixture material — a pinned anchor/hole region
  // the surrounding bulk was stripped away from, which keep_largest_component
  // would otherwise DROP from `mesh` silently. 0 in the healthy case (the frozen
  // region is part of the single main body — the FIX 1 pad keeps it there). When
  // > 0, the cleanup dropped a disconnected frozen region: `mesh` is still the
  // single largest body (so the §7 V3 single-component gate is unchanged), but
  // this count SURFACES the drop so a caller can warn instead of shipping a
  // silently-broken result (diagnosis 064). Not a §7 V3 gate; a diagnostic signal.
  int load_fixture_islands = 0;
  int min_feature_violations = 0;  // gate 4: solid voxels not in any 2x2x2 block
  bool passes = false;

  // Gate accessors (each true iff that §7 V3 gate holds).
  bool gate_watertight() const { return watertight.watertight; }
  bool gate_single_component() const {
    return !mesh.triangles.empty() && mesh_components == 1;
  }
  bool gate_load_fixture_retained() const { return load_fixture_retained; }
  bool gate_min_feature() const { return min_feature_violations == 0; }
};

// The minimum retained-density threshold for Load/Fixture voxels (§7 V3: ">=
// 0.9"). A voxel counts as a feature-support voxel when its tag is Load or
// Fixture (M1.6). With no such voxels the retention gate is vacuously satisfied.
constexpr double kV3RetentionThreshold = 0.9;

// Number of solid voxels (density > iso) that are NOT covered by any fully-solid
// 2x2x2 block of voxels — i.e. features thinner than 2 voxels in some direction
// (§7 V3: "Minimum feature size >= 2 voxels"). 0 means every solid voxel sits in
// at least one solid 2x2x2 block. Throws std::invalid_argument on size mismatch.
int min_feature_violations(const VoxelGrid& grid,
                           const std::vector<double>& density, double iso = 0.5);

// Run the full Gate V3 property suite on an optimizer output: extract + clean
// the marching-cubes surface and evaluate all four §7 V3 gates. `iso` is the
// density threshold (0.5 for M3.5). Throws std::invalid_argument if
// density.size() != grid.voxel_count().
V3Report check_v3(const VoxelGrid& grid, const std::vector<double>& density,
                  double iso = 0.5);

}  // namespace topopt
