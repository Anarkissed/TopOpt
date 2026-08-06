#pragma once

// THE ENCLOSED-VOID RULE FOR LATTICE (task 2026-08-05-lattice-void-reaches-
// exterior).
//
// THE RULE, in one line: THE VOID SPACE INSIDE ANY LATTICE MUST CONNECT TO THE
// EXTERIOR. No sealed lattice-filled cavities.
//
// This is the standard additive-manufacturing "enclosed void" constraint. A
// lattice is a POROUS material: what makes it worth printing is the space
// between the struts, and on every process that leaves something behind in that
// space — powder, resin, support — a pocket of lattice with no path to the
// outside is a pocket that can never be emptied. The differentiable form of the
// same constraint (the Virtual Temperature Method: fill the void with a virtual
// high-conductivity material and bound the maximum temperature) belongs in the
// OPTIMIZER, where a gradient is needed. Here, at the lattice stage, the
// occupancy is already decided and DISCRETE, so a flood fill is not an
// approximation of the constraint — it IS the constraint, evaluated exactly on
// the voxel classification the export and the certificate are both built from.
//
// ── THE THREE-WAY CLASSIFICATION ────────────────────────────────────────────
// Every voxel of the design grid is exactly one of:
//
//   LATTICED  `lattice_mask[e] != 0` — the certification mask
//             (lattice_certification_mask). This voxel's material is the strut
//             lattice, so it carries pore space and CONDUCTS.
//   SOLID     printed (density >= iso) but not latticed. Fully dense material:
//             it BLOCKS.
//   VOID      not printed. Empty space: it CONDUCTS.
//
// The ESCAPE NETWORK is LATTICED u VOID. The exterior is everything outside the
// design grid, so every escape-network voxel lying on one of the grid's six
// boundary planes is a seed. A latticed voxel the fill reaches is OPEN; one it
// does not reach is SEALED, and the cell that owns it is a sealed lattice cell.
//
// A latticed voxel CONDUCTS because the octet cell's pore space is connected
// within the cell and opens on all six cell faces — that is what "open-cell
// lattice" means, and it is the same periodic-octet assumption the homogenized
// certificate already rests on. It is stated here rather than assumed silently:
// if a topology whose pore space does NOT open on every face is ever added to
// lattice_gen.hpp, this classification must be revisited with it.
//
// ── ★ CONNECTIVITY IS 6, AND THAT IS NOT THE SAME CHOICE THE LOAD PATH MADE ─
// The belt's own walk over the SOLID set (voxel.hpp, walk_load_path) is
// 26-connected, and it says why: two hex8 elements touching at a single corner
// share that node and really do pass force through it, so restricting the SOLID
// walk to faces would reject designs the FEA considers connected.
//
// The VOID walk is the opposite polarity and takes the opposite answer. Two
// voxels that meet only along an edge or only at a corner share ZERO AREA. There
// is no aperture there; nothing flows through a measure-zero contact. A
// "diagonal escape path" is a staircase of corner touches through a wall that is
// solid everywhere a fluid could actually pass — physically, a sealed cavity
// that a 26-connected fill would call open.
//
// The two choices also have to be opposite for the pair to be topologically
// coherent. In 3-D digital topology the complementary sets must take
// complementary adjacencies — (26, 6) or (6, 26) — or both a solid path and a
// void path can cross the SAME diagonal, i.e. the void "escapes" straight
// through a wall the load path is simultaneously walking along. Solid is 26 here,
// so void is 6. This is the conservative direction as well as the correct one:
// 6-connectivity reaches a subset of what 18- or 26-connectivity would reach, so
// this check can only ever refuse MORE, never less.
//
// ── WHAT THIS CHECK IS NOT ──────────────────────────────────────────────────
// It is NOT the isolated-fragment check (cell-size-adaptation handoff §M8a),
// which is about SOLID pieces attached to nothing. Same machinery, opposite
// polarity: that one walks the printed set and asks which components carry no
// anchor; this one walks the complement and asks which components reach no
// exterior. Neither is implemented in terms of the other, and this header does
// not implement that one.
//
// It is NOT a claim about the EXPORTED MESH. This is a statement about the
// design field the certificate and the file are both derived from. The exported
// solid shell (`outer_finish: "shell"`) is the marching-cubes surface of the
// printed set; whether that surface is a physical barrier over a boundary
// lattice cell is a mesh-level question that the freeform-skin outer finish
// (`"skin"` / `"shell+skin"`) exists to answer, and it is not decided here.
//
// Deterministic (a reachable-set membership test: no traversal order affects the
// answer) and READ-ONLY on every input. O(voxel_count).

#include <cstddef>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"   // Vec3
#include "topopt/voxel.hpp"  // VoxelGrid

namespace topopt {

// The six boundary planes of the design grid, in a fixed order — the "which way
// out" a passing check reports.
enum class GridFace : int { NegX = 0, PosX = 1, NegY = 2, PosY = 3, NegZ = 4, PosZ = 5 };
// "-x", "+x", "-y", "+y", "-z", "+z". Throws std::logic_error on an unnamed
// value (never a silent fallback).
const char* grid_face_name(GridFace f);

// One connected component of the escape network that reaches NO exterior — a
// sealed cavity. Reported whether or not it holds lattice; `latticed_voxels`
// and `cells` are what makes it a REFUSAL rather than an observation.
struct SealedVoidPocket {
  long long voxels = 0;           // escape-network voxels in the pocket
  long long latticed_voxels = 0;  // ... that are LATTICED (0 => not a refusal)
  long long void_voxels = 0;      // ... that are plain VOID
  long long cells = 0;            // distinct lattice cells holding sealed lattice
  double volume_mm3 = 0.0;        // voxels * spacing^3 — the trapped volume
  double latticed_volume_mm3 = 0.0;
  // Inclusive voxel bounding box, and the same box in model mm (outer corners
  // of the extreme voxels, so the box CONTAINS the pocket).
  int lo[3] = {0, 0, 0};
  int hi[3] = {0, 0, 0};
  Vec3 bbox_min{0.0, 0.0, 0.0};
  Vec3 bbox_max{0.0, 0.0, 0.0};
  // The DECLARED include regions this pocket's latticed voxels belong to,
  // 1-based in the job's own declaration order (see `voxel_region_id` below).
  // Empty when no region ids were supplied or the pocket holds no lattice.
  std::vector<int> region_ids;
};

struct LatticeVoidEscapeReport {
  // False when there is NOTHING TO DECIDE — the mask lattices no voxel at all.
  // `sealed()` is then false (the check never invents a verdict it cannot
  // measure) and every count below is a plain fact about the grid.
  bool decidable = false;

  // ── the classification ────────────────────────────────────────────────────
  long long latticed_voxels = 0;
  long long solid_voxels = 0;   // printed, not latticed — the blocking set
  long long void_voxels = 0;    // not printed
  long long escape_voxels = 0;  // latticed + void — the network walked
  long long seed_voxels = 0;    // escape voxels on the grid's boundary planes
  long long latticed_cells = 0; // distinct cells holding >= 1 latticed voxel

  // ── the verdict ───────────────────────────────────────────────────────────
  long long escape_reached = 0;     // escape voxels reached from the exterior
  long long latticed_reached = 0;   // ... that are latticed (the OPEN lattice)
  long long latticed_sealed = 0;    // latticed voxels the fill did NOT reach
  long long sealed_cells = 0;       // distinct cells holding sealed lattice
  double sealed_volume_mm3 = 0.0;   // trapped volume in LATTICE-BEARING pockets
  double reachable_escape_volume_mm3 = 0.0;  // what CAN drain
  // Sealed pockets that hold NO lattice: pre-existing enclosed voids in the
  // design itself. REPORTED, never a refusal — this rule is about lattice, and
  // refusing on them would be this check quietly becoming a different one.
  long long sealed_pockets_without_lattice = 0;
  double sealed_volume_without_lattice_mm3 = 0.0;

  // ── which way out it found (a passing check must be distinguishable from a
  //    check that did not run) ─────────────────────────────────────────────
  // The BFS distance, in 6-connected escape-network steps, from the grid's
  // boundary planes to the NEAREST reached latticed voxel: how far in from the
  // outside the drain path runs. -1 when no latticed voxel was reached.
  int lattice_escape_depth = -1;
  // Per grid face: does the OPEN lattice's own component touch that face? A
  // component may touch several. All false iff `latticed_reached` is 0.
  bool face_escapes[6] = {false, false, false, false, false, false};
  // How many distinct escape components carry the open lattice, and how many
  // exist in total.
  long long components = 0;
  long long open_components = 0;

  // ── cost (bar R5): the check's OWN work, separately from any wall clock ──
  // Voxels pushed onto a frontier across every pass (the flood fill's
  // "iterations"). Wall time is measured by the CALLER — this function reads no
  // clock, so it stays deterministic and testable.
  long long bfs_visits = 0;

  // Sealed pockets, largest trapped volume first. Capped at
  // `kMaxReportedSealedPockets`; `sealed_pockets_total` is the uncapped count,
  // so a truncated list never reads as a complete one.
  std::vector<SealedVoidPocket> pockets;
  long long sealed_pockets_total = 0;
  long long sealed_pockets_with_lattice = 0;

  // THE VERDICT. True => at least one latticed voxel's pore space cannot reach
  // the exterior.
  bool sealed() const { return latticed_sealed > 0; }
};

// At most this many pockets are listed individually; the counts above are never
// truncated.
inline constexpr std::size_t kMaxReportedSealedPockets = 16;

// Walk the escape network and report it.
//
// `lattice_mask` is THE certification mask (lattice_certification_mask over the
// same grid, density and iso) — the one object the exported file and the
// certified posture are both derived from, so this check decides on the same
// set they do rather than on a reconstruction of it.
// `region_origin` / `cell_mm` are the lattice cell grid, keyed exactly as
// lattice_certification_mask keys it (floor over region_origin), so "the cell
// that certifies this voxel" and "the cell this check reports as sealed" are the
// same integer triple.
// `voxel_region_id`, when non-null, is one 1-based declared-include-region id
// per voxel (0 = none) and is echoed per pocket so a refusal can name the region
// the user drew. Null => `SealedVoidPocket::region_ids` stays empty.
//
// Throws std::invalid_argument on a size mismatch or a non-positive cell_mm.
LatticeVoidEscapeReport lattice_void_escape(
    const VoxelGrid& grid, const std::vector<double>& density, double iso,
    const std::vector<char>& lattice_mask, const Vec3& region_origin,
    double cell_mm, const std::vector<int>* voxel_region_id = nullptr);

// The REFUSAL text: what is sealed, where, and how much. One builder, so the
// CLI's stderr line, the per-variant receipt and the thrown JobError can never
// describe the failure differently. Returns an empty string when nothing is
// sealed.
std::string lattice_void_refusal(const LatticeVoidEscapeReport& r);

}  // namespace topopt
