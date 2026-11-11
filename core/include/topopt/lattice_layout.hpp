#pragma once
// ── THE LATTICE LAYOUT (rebuild, docs/design/lattice-rebuild) ──────────────────
//
// One implementation of "where does lattice go, and what is there", run on the device
// for the preview and on the worker for the file. Rule numbers (D1, C11 ...) are those
// of docs/design/lattice-rebuild/01-rules.md; the tests that pin them are 02-tests.md.
//
// STAGE B (this file so far): MEASURE and DOMAIN.
//   * PartMeasure  -- the part's real surface. Depth below the surface and the width of
//                     a wall are measured on the MESH (rule D9, C11). No voxels.
//   * Domain       -- for any point: lattice (and whose), or solid (and why). One
//                     function for Start from, roles, depths, Expand, overlaps and
//                     Protect skin (rules D1-D15).
//
// REUSED, NOT RE-DERIVED (reviewer's condition, 2026-11-10 20:45Z): the exact mesh
// distance is `MeshDistance`; a prism is a `ClearanceGeometry` and its containment at
// Expand 0 is `point_in_clearance_region`; the plane tie is `include_wins_plane_tie`.
//
// Nothing here is called by the shipped path. The old path is untouched.

#include <cstdint>
#include <memory>
#include <vector>

#include "topopt/clearance.hpp"
#include "topopt/mesh.hpp"
#include "topopt/mesh_distance.hpp"

namespace topopt::lattice_layout {

// Merge vertices that coincide (a tessellated STEP model repeats them per face), so the
// mesh is closed and the sign of the distance means inside/outside. `open_edges`, when
// given, receives the number of edges not shared by exactly two triangles: 0 for a part
// that can be measured.
TriangleMesh weld_mesh(const TriangleMesh& mesh, double tol_mm = 1e-5,
                       std::size_t* open_edges = nullptr);

// ── MEASURE ───────────────────────────────────────────────────────────────────
// Built once per part and kept; a slider never rebuilds it (rule P2).
class PartMeasure {
 public:
  // `mesh` must be closed and welded (see weld_mesh). It is copied and owned.
  explicit PartMeasure(TriangleMesh mesh);

  const TriangleMesh& mesh() const { return *mesh_; }
  Vec3 lo() const { return lo_; }
  Vec3 hi() const { return hi_; }
  double diagonal_mm() const { return diag_; }

  // A probe answers questions for ONE thread (MeshDistance keeps per-instance scratch).
  // Making one costs about a millisecond.
  class Probe {
   public:
    // Depth below the surface, mm. Positive inside the part, negative outside.
    double depth(const Vec3& p) const { return md_.signed_distance(p); }
    // From a point inside the part, the distance to the surface along `unit_dir`.
    // 0 when `p` is not inside.
    double reach(const Vec3& p, const Vec3& unit_dir) const;
    // The wall's width at `p` along `unit_dir`: the material through `p` in that
    // direction, surface to surface (rule C11). 0 when `p` is not inside.
    double wall_width(const Vec3& p, const Vec3& unit_dir) const {
      const double a = reach(p, unit_dir);
      if (a <= 0.0 && depth(p) <= 0.0) return 0.0;
      return a + reach(p, Vec3{-unit_dir.x, -unit_dir.y, -unit_dir.z});
    }

   private:
    friend class PartMeasure;
    Probe(const TriangleMesh& m, double max_mm) : md_(m), max_mm_(max_mm) {}
    MeshDistance md_;
    double max_mm_;
  };
  Probe probe() const { return Probe(*mesh_, diag_); }

 private:
  std::shared_ptr<const TriangleMesh> mesh_;
  Vec3 lo_{}, hi_{};
  double diag_ = 0.0;
};

// ── DOMAIN ────────────────────────────────────────────────────────────────────
enum class Start : std::uint8_t {
  AllSolid,    // lattice only where a Lattice region asks (rule D12)
  AllLattice,  // one layout for the whole part; regions carve it (rule D4)
};

enum class Role : std::uint8_t { Lattice, NoLattice };

// A prism under a face. `prism` is resolved by the caller exactly as today
// (resolve_clearance_from_face / _manual): origin on the face, `normal` pointing INTO
// the material, `depth` along it, the face's own outline (rule D10).
struct Region {
  int id = 0;              // > 0, the caller's own number; returned as the owner
  Role role = Role::Lattice;
  ClearanceGeometry prism;
  // Rule D11: grow (+) or shrink (-) the outline in the face's plane only. 0 is exactly
  // the face, and is answered by the old predicate itself. Never changes the depth.
  double expand_mm = 0.0;
};

// Rule D5: a solid face at exactly the stated depth, the lattice right behind it.
// `face` is the face's own triangles (need not be closed). 0 mm means the thinnest face
// that prints: two line widths.
struct ProtectSkin {
  int id = 0;
  TriangleMesh face;
  double depth_mm = 0.0;
};

struct DomainSpec {
  Start start = Start::AllSolid;
  double bead_mm = 0.45;
  std::vector<Region> regions;
  std::vector<ProtectSkin> protect;
};

enum class Why : std::uint8_t {
  Lattice,      // lattice goes here; `id` is the owning region, 0 = the whole part
  Outside,      // not inside the part (rule D2)
  NotAsked,     // solid: Start from All solid and no Lattice region covers it (D12)
  NoLattice,    // solid: a No lattice region; `id` is that region (D6)
  ProtectSkin,  // solid: within a Protect skin's depth; `id` is that skin (D5)
};

struct Where {
  Why why = Why::Outside;
  int id = 0;
  bool lattice() const { return why == Why::Lattice; }
  bool operator==(const Where& o) const { return why == o.why && id == o.id; }
};

class Domain {
 public:
  // `measure` must outlive the domain. The spec is copied; regions are kept sorted by id
  // so the order the caller listed them in can never change an answer (rule D13).
  Domain(const PartMeasure& measure, DomainSpec spec);

  class Probe {
   public:
    // Rule D1: the answer depends on geometry and settings only. No stress input exists.
    Where where(const Vec3& p) const;
    const PartMeasure::Probe& part() const { return part_; }

   private:
    friend class Domain;
    Probe(const Domain& d);
    const Domain* d_;
    PartMeasure::Probe part_;
    std::vector<MeshDistance> skins_;
  };
  Probe probe() const { return Probe(*this); }

  const DomainSpec& spec() const { return spec_; }
  // The depth a Protect skin is solid to: its own, or two line widths at 0 (rule D5).
  double protect_depth_mm(const ProtectSkin& s) const {
    return s.depth_mm > 0.0 ? s.depth_mm : 2.0 * spec_.bead_mm;
  }

 private:
  const PartMeasure* measure_;
  DomainSpec spec_;
};

// Is `p` in the region's prism, with its Expand? At Expand 0 this IS
// point_in_clearance_region(prism, p, 0). Exposed for tests.
bool region_contains(const Region& r, const Vec3& p);

}  // namespace topopt::lattice_layout
