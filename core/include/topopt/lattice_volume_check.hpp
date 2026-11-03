#pragma once
// ── ★ THE LATTICE VOLUME CHECK (Finding 7, ruling 2026-11-02) ──────────────────────
// The certificate reads every latticed voxel at its certified density over the WHOLE
// voxel. Finding 7 showed a run where the file held about a fifth of that: cells finer
// than the solve voxel were laid one per voxel. The cover rule (cell_plan.hpp) fixes the
// activation; this is the tripwire that proves it on every run, for every type, octet
// included: "the certificate must never count material the file doesn't have."
//
// WHAT IS MEASURED. Per latticed POCKET -- a face-connected set of latticed voxels --
//     certified = sum over its voxels of rho_certified(e) * voxel volume
//     exported  = the volume of the EMITTED lattice solid inside those voxels
// and gap = exported / certified - 1. The run refuses when the file holds more than 10 %
// LESS lattice than the certificate counts (gap < -10 %) in any pocket at least ONE CELL in
// volume (ruling 2026-11-02 (a)). The HIGH side is measured and stated in every receipt
// ("file +N % over certified") and never refuses: material the certificate does not count
// is not material it credits. A smaller pocket is measured and reported but not judged: the
// certified density is a CELL average, and a pocket under a cell holds whatever part of a
// cell falls in it (an octahedral void, or a node), so its own gap says nothing about the
// lattice. A cell-scale defect is what this exists to catch, and it is judged.
//
// THE EMITTED SOLID, EXACTLY. A strut lattice is a union of the generator's own convex
// pieces: each fragment a->b is the n-gon prism lattice_emit_strut writes, each ball the
// icosahedron lattice_emit_node writes. The probe rebuilds every piece from those public
// emitters (never from a round capsule: the prism holds 0.900 of the circle, Finding 2)
// and tests a point against the half-spaces of its faces. A sheet lattice is the zero
// set of tpms_clipped_field, the function its mesh is contoured from (within -0.4 %).
// The file's own solid companion is not lattice and is not counted.
//
// HOW. Each voxel is sampled at a DETERMINISTIC low-discrepancy set (Halton 2/3/5 with a
// per-voxel Cranley-Patterson shift from the voxel index), so the same run always gives
// the same number and an axis-aligned strut cannot alias with a regular subgrid. A
// pocket of N voxels takes clamp(2^16 / N, 256, 4096) points per voxel, so a one-voxel
// pocket is read to ~1-3 % and a large part's cost stays bounded.

#include <array>
#include <cmath>
#include <cstddef>
#include <functional>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// The refusal limit: exported / certified - 1 below MINUS this in any judged pocket.
constexpr double kLatticeVolumeGapLimit = 0.10;

// The emitted lattice as a solid you can ask "is this point inside?".
class LatticeSolidProbe {
 public:
  // A strut fragment a->b of circumradius r as lattice_emit_strut emits it with `nseg`
  // sides, or (a == b) a ball as lattice_emit_node emits it.
  void add_strut(const Vec3& a, const Vec3& b, double r, int nseg);
  void add_ball(const Vec3& c, double r);
  // The finishes (skin and rim edges) keep the raw prism: `circumradius` as written.
  void add_prism(const Vec3& a, const Vec3& b, double circumradius, int nseg);
  // A lattice with no pieces (the sheets): its own inside test.
  void set_inside(std::function<bool(const Vec3&)> f) { inside_fn_ = std::move(f); }

  bool has_geometry() const { return !pieces_.empty() || static_cast<bool>(inside_fn_); }
  std::size_t pieces() const { return pieces_.size(); }

  struct Piece {
    Vec3 lo, hi;                                // bounding box
    std::vector<std::array<double, 4>> planes;  // outward n.x, n.y, n.z, d: inside n.p <= d
  };
  const std::vector<Piece>& piece_list() const { return pieces_; }
  bool inside_piece(std::size_t i, const Vec3& p) const;
  const std::function<bool(const Vec3&)>& inside_fn() const { return inside_fn_; }

 private:
  void add_triangles(const std::vector<std::array<Vec3, 3>>& tris);
  std::vector<Piece> pieces_;
  std::function<bool(const Vec3&)> inside_fn_;
};

struct LatticePocketVolume {
  long long voxels = 0;
  double certified_mm3 = 0.0;
  double exported_mm3 = 0.0;
  double gap = 0.0;  // exported / certified - 1 (0 when nothing is certified)
  Vec3 lo{0, 0, 0}, hi{0, 0, 0};  // the pocket's box (mm), to find it in the part
  int points_per_voxel = 0;
  bool judged = true;  // at least one cell in volume
};

struct LatticeVolumeCheck {
  bool ran = false;
  std::vector<LatticePocketVolume> pockets;  // ordered by their lowest voxel index
  double certified_mm3 = 0.0;
  double exported_mm3 = 0.0;
  long long points = 0;
  int worst = -1;          // the JUDGED pocket with the lowest gap (the file lightest)
  double worst_gap = 0.0;  // its gap (signed)
  int highest = -1;        // the JUDGED pocket with the highest gap (the file heaviest)
  double highest_gap = 0.0;
  double judge_min_mm3 = 0.0;  // pockets smaller than this are not judged (one cell)
  long long small_pockets = 0;  // measured, not judged
  double small_certified_mm3 = 0.0, small_exported_mm3 = 0.0;
  double seconds = 0.0;
  bool refused() const { return worst >= 0 && worst_gap < -kLatticeVolumeGapLimit; }
};

// Measure every pocket of `mask` (grid-indexed, nonzero = latticed). `certified_rho(e)` is
// the density the certificate reads at voxel e; `judge_min_mm3` the smallest pocket volume
// judged (the volume of the largest cell the run lays; 0 = every pocket).
LatticeVolumeCheck lattice_volume_check(const VoxelGrid& grid, const std::vector<char>& mask,
                                        const std::function<double(std::size_t)>& certified_rho,
                                        const LatticeSolidProbe& probe,
                                        double judge_min_mm3 = 0.0);

// One plain sentence for a refusal: which pocket, how far off, and why it matters.
std::string lattice_volume_refusal(const LatticeVolumeCheck& c);

}  // namespace topopt
