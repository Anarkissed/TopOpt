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

#include <array>
#include <cstdint>
#include <memory>
#include <vector>

#include "topopt/clearance.hpp"
#include "topopt/lattice.hpp"
#include "topopt/mesh.hpp"
#include "topopt/mesh_distance.hpp"
#include "topopt/step.hpp"

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
    // The direction toward the nearest surface at `p`.
    Vec3 through(const Vec3& p) const;
    // The material's thickness at `p` where no region names a direction (All lattice, a
    // curved face): the narrowest width through `p` that is square to one of the two
    // surfaces it joins and does not graze the other, over the direction of the nearest surface and 13 fixed directions. The
    // nearest surface alone is not enough: at the END of a thin wall the nearest surface
    // is the end, and the width that way is the wall's length. The narrowest of all is
    // not it either: a line clipping across a corner is shorter than any wall. A wall
    // tilted off all 13 directions can read up to 15% wide.
    double thickness(const Vec3& p) const;

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
  // Rule D20: a CURVED face, or several faces that are not one flat face, has no flat
  // prism. When `shell` holds the faces' own triangles the region is instead every point
  // whose NEAREST point of that surface is within `shell_depth_mm` and lies inside the
  // surface's own outline (`shell_edge`, the edges on its border): the surface carried
  // inward along its own normals, stopping at its outline. `prism` is then unread.
  // Expand below 0 pulls the region in from the outline; above 0 is not possible on a
  // curved surface yet and is ignored, with `expand_ignored` set so the caller can say so.
  TriangleMesh shell;
  std::vector<std::array<Vec3, 2>> shell_edge;
  double shell_depth_mm = 0.0;
  bool expand_ignored = false;
  bool is_shell() const { return !shell.triangles.empty(); }
};

// The region under one or more faces of the model, from the faces themselves (rule D10:
// the true outline, read off their own triangles, never the rectangle around it; rule
// D20: several faces are ONE region with one depth and one outline, no seam between
// them). Faces that together are one flat face give a prism of `depth_mm` into the
// material; anything else (a curved face, faces at an angle) gives a shell of that depth.
// `ok` is false, and the region empty, when no listed face has triangles.
Region region_from_faces(const StepModel& model, const std::vector<int>& face_ids, int id,
                         Role role, double depth_mm, double expand_mm = 0.0,
                         bool* ok = nullptr);
inline Region region_from_face(const StepModel& model, int face_id, int id, Role role,
                               double depth_mm, double expand_mm = 0.0, bool* ok = nullptr) {
  return region_from_faces(model, {face_id}, id, role, depth_mm, expand_mm, ok);
}

// The triangles of the given faces, as one open mesh (for ProtectSkin::face).
TriangleMesh faces_mesh(const StepModel& model, const std::vector<int>& face_ids);

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
  // Rule D8: a wall narrower than this cannot hold lattice and is solid. The cell rules
  // (C3-C5) set it; 0 switches the check off. Measured through the wall along the owning
  // prism's direction, or as the narrowest width at the spot where there is no prism (C11).
  double min_wall_mm = 0.0;
  std::vector<Region> regions;
  std::vector<ProtectSkin> protect;
};

enum class Why : std::uint8_t {
  Lattice,      // lattice goes here; `id` is the owning region, 0 = the whole part
  Outside,      // not inside the part (rule D2)
  NotAsked,     // solid: Start from All solid and no Lattice region covers it (D12)
  NoLattice,    // solid: a No lattice region; `id` is that region (D6)
  ProtectSkin,  // solid: within a Protect skin's depth; `id` is that skin (D5)
  WallTooThin,  // solid: lattice was asked for but the wall cannot hold it (D8);
                // `id` is the region that asked, 0 = the whole part
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
    // `wall_mm`, when given and the answer is Lattice or WallTooThin, receives the wall's
    // width at `p` as rule D8 reads it (along the owning prism, or the thickness there).
    Where where(const Vec3& p, double* wall_mm = nullptr) const;
    const PartMeasure::Probe& part() const { return part_; }

   private:
    friend class Domain;
    Probe(const Domain& d);
    const Domain* d_;
    PartMeasure::Probe part_;
    std::vector<MeshDistance> skins_;
    std::vector<MeshDistance> shells_;   // one per region, empty mesh for a prism
  };
  Probe probe() const { return Probe(*this); }

  const DomainSpec& spec() const { return spec_; }
  const PartMeasure& measure() const { return *measure_; }
  // The depth a Protect skin is solid to: its own, or two line widths at 0 (rule D5).
  double protect_depth_mm(const ProtectSkin& s) const {
    return s.depth_mm > 0.0 ? s.depth_mm : 2.0 * spec_.bead_mm;
  }

 private:
  const PartMeasure* measure_;
  DomainSpec spec_;
};

// ── CELLS (stage C) ───────────────────────────────────────────────────────────
// Where the cells are and how big. One call lays every region; the preview draws the
// result and the run builds from it.
enum class Algorithm : std::uint8_t {
  Uniform,       // one cell size per region; a wall it does not fit is solid (C16)
  DefaultGrade,  // halves: S, S/2, S/4 ... down to the printable floor (C7)
  // Any whole fraction of the base cell, from ONE shared unit per base cell: k x (S/n),
  // n = 2..6 (C6-C6c, C13; his ruling 2026-11-10 22:54: shared-unit splits only).
  Stepped,
};

struct CellSpec {
  Algorithm algorithm = Algorithm::DefaultGrade;
  LatticeTopology topology = LatticeTopology::Octet;
  // Manual cell size, mm. 0 = Auto: the largest cell that fits, up to `cell_max_mm` (C1).
  double cell_mm = 0.0;
  double cell_max_mm = 8.0;
  // No cell smaller than this. 0 = the printable floor alone (C14).
  double cell_min_mm = 0.0;
  // Cells a wall must hold across: 1 with single-cell walls, which is how Aesthetic
  // starts (C4, his ruling 2026-11-11); 2 with that switch off (C3); 5 Structural (C5).
  int min_cells_across = 1;
  // Grade to shape (G1-G7, G10): cells shrink toward the outline of a flat Lattice region,
  // down to the smallest allowed cell, over `band_mm` measured in the plane of its face.
  // The rule is the preview's centre rule (the run's law of 2026-11-06 states the same at
  // a cell's nearest voxel): a cell of size S may stand where its centre is at least
  // band (S - f) / (S_base - f) inside the outline, f the finest cell and S_base the
  // region's own; the finest always may. Only the finest cell may be cut by the outline;
  // a larger one must lie whole inside it. One size (Uniform) keeps its cells and grades
  // struts only (C16). Off, or band 0: cells are cut where the region ends (G7).
  bool grade_to_shape = false;
  double band_mm = 0.0;
  // G11 (awaiting his pick): inside the band, cells may go below the open look's floor,
  // down to the smallest cell one line draws without closing it (line / kQuiltStrutPerCell).
  bool band_fine_cells = false;
};

// Cells are cubes on a frame: world position = origin + ax[0]*a + ax[1]*b + ax[2]*c.
// A flat region's frame is its face's own (in-plane, in-plane, inward), so the face is
// a cell boundary (C15). The whole part, and a curved region, use the part's axes.
struct Frame {
  Vec3 origin{};
  Vec3 ax[3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
  Vec3 at(double a, double b, double c) const {
    return {origin.x + ax[0].x * a + ax[1].x * b + ax[2].x * c,
            origin.y + ax[0].y * a + ax[1].y * b + ax[2].y * c,
            origin.z + ax[0].z * a + ax[1].z * b + ax[2].z * c};
  }
};

struct Cell {
  int region = 0;       // the owning region; 0 = the whole part
  int frame = 0;        // index into Layout::frames
  double lo[3] = {0, 0, 0};   // the cube's low corner, in frame coordinates, mm
  double size = 0.0;    // mm
  bool cut = false;     // the region's edge or the part's surface passes through it (D3)
  double strut = 0.0;   // strut width, mm (R1). 0 until set_struts has run.
  double own = 0.0;     // the region's (or wall's) own cell at this spot, mm
  // Grade to shape: 0 at the region's outline, 1 at the band's inner edge and beyond.
  // 1 when no band applies.
  double band = 1.0;
  bool finest = false;  // the smallest cell this spot's ladder allows
  bool operator==(const Cell& o) const {
    return region == o.region && frame == o.frame && lo[0] == o.lo[0] && lo[1] == o.lo[1] &&
           lo[2] == o.lo[2] && size == o.size && cut == o.cut && strut == o.strut &&
           own == o.own && band == o.band && finest == o.finest;
  }
};

struct RegionCells {
  int region = 0;
  int frame = 0;
  double base_cell_mm = 0.0;   // the size the region starts from
  std::size_t cells = 0;
  std::size_t solid = 0;       // places lattice was asked for and no allowed cell fits
};

struct Layout {
  double floor_cell_mm = 0.0;        // the smallest cell that prints open (C14)
  double bead_mm = 0.0;              // the line width it was laid for
  LatticeTopology topology = LatticeTopology::Octet;
  std::vector<Frame> frames;
  std::vector<Cell> cells;           // in a fixed order: same input, same bytes (D18)
  // D14: space inside a region no cell covers. Solid, and drawn solid. Same shape as a
  // cell: the cube that was tried and did not fit.
  std::vector<Cell> solid;
  std::vector<RegionCells> regions;
};

Layout lay_cells(const Domain& domain, const CellSpec& spec);

// ── STRUT WIDTH ───────────────────────────────────────────────────────────────
// What a lattice looks like is one number, strut width over cell size (R9). Octet's
// neighbouring struts touch at 1/(2*sqrt 2): the quilt, the top of every range.
inline constexpr double kQuiltStrutPerCell = 0.35355339059327373;

enum class Density : std::uint8_t {
  Uniform,    // one density for the whole part (R6)
  PerRegion,  // each region's own dial; a region not listed takes `dial`
};

struct RegionDial {
  int region = 0;
  double dial = 0.45;
};

struct StrutSpec {
  Density mode = Density::Uniform;
  // R10: even steps of strut WIDTH on the largest cell. 0.01 = one line width; 1.0 = the
  // widest strut allowed (the open look, or the quilt with `allow_quilt`). Auto is 0.45.
  double dial = 0.45;
  std::vector<RegionDial> region_dial;   // read in PerRegion only (R6)
  // R11: a typed strut width, mm. > 0: this width in every cell, whatever the dial says.
  double width_mm = 0.0;
  // R2: off, no strut is wider than the open look (kSteppedPrintsOpenMaxStrutPerCell of
  // its cell). On, a strut may go up to the quilt.
  bool allow_quilt = false;
  // G4: how much the band raises a strut toward the quilt, as 2^strength, -1 .. 1.
  double strength = 0.0;
};

struct StrutReport {
  std::size_t at_bead = 0;      // cells where the asked width was under one line (R5)
  std::size_t at_ceiling = 0;   // cells where it was over the widest allowed (R2, R9)
};

// Sets every cell's strut width. Moves no cell. Octet only so far: any other type throws
// std::invalid_argument and leaves the layout untouched, because the open-look and quilt
// ratios here are octet's own.
StrutReport set_struts(Layout& layout, const StrutSpec& spec);

// In the plane of a flat region's face: how far `p` is inside the region's edge (its
// outline moved by Expand), mm. Negative outside. The depth is left out (G5). A curved
// region has no such plane: +infinity.
double region_edge_distance(const Region& r, const Vec3& p);

// Is `p` in the region's prism, with its Expand? At Expand 0 this IS
// point_in_clearance_region(prism, p, 0). Exposed for tests.
bool region_contains(const Region& r, const Vec3& p);

}  // namespace topopt::lattice_layout
