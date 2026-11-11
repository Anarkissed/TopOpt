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
#include <map>
#include <memory>
#include <mutex>
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

 private:
  // The triangles sorted into a uniform grid, for straight lines through the part.
  struct RayGrid {
    Vec3 lo{};
    double cell = 1.0;
    int n[3] = {1, 1, 1};
    std::vector<std::uint32_t> start;   // per cell, into `tris` (one more than cells)
    std::vector<std::uint32_t> tris;
    bool outward = true;                // the triangles' own normals point out of the part
  };
 public:
  // A probe answers questions for ONE thread (MeshDistance keeps per-instance scratch).
  // Making one costs about a millisecond.
  class Probe {
   public:
    // Depth below the surface, mm. Positive inside the part, negative outside.
    double depth(const Vec3& p) const { return md_.signed_distance(p); }
    // From a point inside the part, the distance to the surface along `unit_dir`.
    // 0 when `p` is not inside.
    // Read as a straight line against the part's own triangles (exact, and the same cost
    // however deep the point is); should that line ever disagree with the distance (it
    // leaves the mesh between two triangles), walked by the distance instead.
    double reach(const Vec3& p, const Vec3& unit_dir) const { return reach(p, unit_dir, depth(p)); }
    // The same, for a caller that has already read depth(p).
    double reach(const Vec3& p, const Vec3& unit_dir, double depth_at_p) const;
    // The same from a point known to be inside (no distance is read at all).
    double reach_in(const Vec3& p, const Vec3& unit_dir) const {
      const double t = reach_by_line(p, unit_dir);
      return t >= 0.0 ? t : reach(p, unit_dir, depth(p));
    }
    // The two ways `reach` reads, for the test that holds them together. The line gives
    // < 0 when it meets no triangle at all.
    double reach_by_line(const Vec3& p, const Vec3& unit_dir) const { return cast(p, unit_dir, nullptr); }
    double reach_by_walk(const Vec3& p, const Vec3& unit_dir, double depth_at_p) const;
    // Is `p` inside the part by more than a micron? The same answer as depth(p) > 1e-6
    // (a point ON the surface is not inside), read without a distance: the triangles a
    // micron around the point, then which way the first surface along one line faces.
    bool inside(const Vec3& p) const;
    // The one line `inside` looks along: a direction no face of a designed part lies in.
    static Vec3 inside_line() { return Vec3{0.36514837167011, 0.54772255750517, 0.75277265270908}; }
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
    // A caller that only needs to know whether the material is narrower than some width
    // passes it as `at_least`: when no line through `p` is shorter, the shortest is
    // returned as it is (it is not narrower, and which line "is the wall" no longer matters).
    double thickness(const Vec3& p, double at_least = 0.0) const {
      return depth(p) <= 0.0 ? 0.0 : thickness_in(p, at_least);
    }
    // The same from a point known to be inside.
    double thickness_in(const Vec3& p, double at_least = 0.0) const;

   private:
    friend class PartMeasure;
    Probe(const TriangleMesh& m, double max_mm, const RayGrid* grid)
        : md_(m), max_mm_(max_mm), mesh_(&m), grid_(grid) {}
    // The nearest triangle along the line, < 0 for none. `facing`, when given, receives
    // 1 when that surface is seen from inside the material, -1 from outside, 0 when the
    // line meets an edge between one of each.
    double cast(const Vec3& p, const Vec3& unit_dir, int* facing) const;
    MeshDistance md_;
    double max_mm_;
    const TriangleMesh* mesh_;
    const RayGrid* grid_;
  };
  Probe probe() const { return Probe(*mesh_, diag_, grid_.get()); }

 private:
  std::shared_ptr<const RayGrid> grid_;
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
    Where where(const Vec3& p, double* wall_mm = nullptr) const { return where(p, wall_mm, nullptr); }
    // The lattice's own room through `p` under a flat region, along the region's
    // direction: a Protect skin met before the part's surface ends it (D5: the lattice is
    // right behind the skin). `back` is toward the region's face, `on` away from it; each
    // is read only when its flag is set, and is then the distance from `p` to the skin.
    // `part_back` and `part_on` are the same two distances to the part's own surface.
    struct Room {
      bool skin_back = false, skin_on = false;
      double back = 0.0, on = 0.0;
      double part_back = 0.0, part_on = 0.0;
    };
    Where where(const Vec3& p, double* wall_mm, Room* room) const;
    // How far `p` is from the nearest Protect skin's solid: negative inside one, and
    // +infinity when the part has none.
    double skin_gap(const Vec3& p) const;
    const PartMeasure::Probe& part() const { return part_; }

   private:
    friend class Domain;
    Probe(const Domain& d);
    const Domain* d_;
    PartMeasure::Probe part_;
    // From `p` along `dir`, the distance at which a Protect skin's solid begins, looking
    // no farther than `limit`. Negative when none begins that near.
    double skin_ahead(const Vec3& p, const Vec3& dir, double limit) const;
    std::vector<MeshDistance> skins_;
    std::vector<MeshDistance> shells_;   // one per region, empty mesh for a prism
  };
  Probe probe() const { return Probe(*this); }

  // Which cells of a coarse grid come within a set distance of a surface. A point in no
  // such cell is certainly farther than that, and its exact distance need not be read
  // (the exact distance to a surface far away is the costly kind).
  struct Near {
    Vec3 lo{};
    double cell = 1.0;
    int n[3] = {0, 0, 0};
    std::vector<unsigned char> on;
    Near() = default;
    Near(const TriangleMesh& surface, double within_mm);
    bool maybe(const Vec3& p) const {
      const double q[3] = {(p.x - lo.x) / cell, (p.y - lo.y) / cell, (p.z - lo.z) / cell};
      for (int a = 0; a < 3; ++a)
        if (!(q[a] >= 0.0) || q[a] >= n[a]) return false;
      return on[(static_cast<std::size_t>(q[2]) * n[1] + static_cast<std::size_t>(q[1])) * n[0] +
                static_cast<std::size_t>(q[0])] != 0;
    }
  };

  const DomainSpec& spec() const { return spec_; }
  const PartMeasure& measure() const { return *measure_; }
  // The depth a Protect skin is solid to: its own, or two line widths at 0 (rule D5).
  double protect_depth_mm(const ProtectSkin& s) const {
    return s.depth_mm > 0.0 ? s.depth_mm : 2.0 * spec_.bead_mm;
  }

 private:
  const PartMeasure* measure_;
  DomainSpec spec_;
  std::vector<Near> near_skin_;    // one per Protect skin, within its depth
  std::vector<Near> near_shell_;   // one per region (empty for a prism), within its depth

 public:
  // Readings a layout takes of this domain that do not depend on any cell setting (what
  // lies under each flat region's face). The first layout makes them; every later layout
  // of the same domain reuses them, so dragging a cell-size or band slider does not read
  // the part again (P2). `make` runs at most once per id. Safe from any thread.
  template <class T, class Make>
  std::shared_ptr<const T> kept(int id, Make make) const {
    std::lock_guard<std::mutex> lock(kept_->mutex);
    std::shared_ptr<const void>& slot = kept_->by_id[id];
    if (!slot) slot = make();
    return std::static_pointer_cast<const T>(slot);
  }

 private:
  struct Kept {
    std::mutex mutex;
    std::map<int, std::shared_ptr<const void>> by_id;
  };
  std::shared_ptr<Kept> kept_ = std::make_shared<Kept>();
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
  // Under a flat region: the wall it was laid for (index into its WallMap's walls), or -1
  // for a cell of the space no wall holds. A cut cell is the part of its cube that is
  // lattice of its own region AND of this wall (see cell_holds).
  int wall = -1;
  double strut = 0.0;   // strut width, mm (R1). 0 until set_struts has run.
  double own = 0.0;     // the region's (or wall's) own cell at this spot, mm
  // Grade to shape: 0 at the region's outline, 1 at the band's inner edge and beyond.
  // 1 when no band applies.
  double band = 1.0;
  bool finest = false;  // the smallest cell this spot's ladder allows
  bool operator==(const Cell& o) const {
    return region == o.region && frame == o.frame && lo[0] == o.lo[0] && lo[1] == o.lo[1] &&
           lo[2] == o.lo[2] && size == o.size && cut == o.cut && wall == o.wall && strut == o.strut &&
           own == o.own && band == o.band && finest == o.finest;
  }
};

// ── THE WALLS UNDER A FLAT REGION (C11, C12, C15; settled 2026-11-10, item 6) ──
// Under one face the material is not one thickness: behind part of it there may be a
// slot, a step, another face, a Protect skin. Each stretch where the lattice's column
// (from where it starts below the face, over the smaller of the region's depth and the
// material there) is ONE start and ONE width is a wall of its own: its cells divide THAT
// width exactly and are centred on THAT stretch. This is a coarse map of the face, used
// only to tell the stretches apart; which wall a point belongs to is then decided by the
// column read at the point itself, so the line between two walls is the true step in the
// part, not the map's grid.
struct WallMap {
  static constexpr double kPitch = 1.0;    // mm between map nodes
  static constexpr double kBin = 0.05;     // mm: widths this close are one width
  bool flat = false;         // false: not a flat region's frame, and nothing below is read
  double depth = 0.0;        // the region's own depth; a wall is never read deeper (C12)
  double u0 = 0, w0 = 0;
  int nu = 0, nw = 0;
  // Under one node there can be more than one stretch of material within the region's
  // depth (a wall, a pocket, the wall behind it): up to kDeep are kept, the nearest the
  // face first. The three lists below hold kDeep entries per node.
  static constexpr int kDeep = 3;
  std::vector<long> bin;     // per stretch: its width in bins, -1 = none
  std::vector<long> sbin;    // per stretch: where it starts below the face, in bins
  std::vector<int> wall;     // per stretch: index into `walls`, -1 = not in a wall
  struct Wall {
    // `start`: where its lattice begins below the face. 0, a Protect skin's depth (D5),
    // or where the material begins behind a pocket.
    double start = 0, width = 0, cell = 0;
    int layers = 0;
    double lo[2] = {0, 0}, hi[2] = {0, 0};   // its extent on the face
  };
  std::vector<Wall> walls;

  static long bin_of(double width);
  // The wall a point at (u, w) belongs to, whose lattice starts `start` below the face
  // and is `width` wide; or -1.
  int find(double u, double w, double start, double width) const;
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
  std::vector<WallMap> walls;        // one per frame
  std::vector<Cell> cells;           // in a fixed order: same input, same bytes (D18)
  // D14: space inside a region no cell covers. Solid, and drawn solid. Same shape as a
  // cell: the cube that was tried and did not fit. This is what the laying found, to
  // within its own sample points; the rule itself is for whoever draws or builds:
  // lattice space that cell_holds is true for in no cell is solid.
  std::vector<Cell> solid;
  std::vector<RegionCells> regions;
};

// `threads`: 0 = all of this machine's; the layout is the same for any number (D18).
Layout lay_cells(const Domain& domain, const CellSpec& spec, int threads = 0);

// What the layout reads at one point (a, b, c) of a frame: the domain's answer and, under
// a flat region, the lattice's column there (where it starts below the face, how wide it
// is) and the wall the point stands in (-1: in none). The one reading both the laying and
// anyone drawing or building from the layout use.
// Under a flat region `start` and `width` are the lattice's own column through the point,
// along the frame's depth: from the face (0), or a Protect skin's inner side, or where
// the material itself begins when there is a pocket under the face; to the far surface,
// a far skin, or the region's depth, whichever comes first (C2, C12, D5).
struct Reading {
  Where where;
  double start = 0.0, width = 0.0;
  int wall = -1;
};
Reading read_at(const Domain::Probe& probe, const Frame& frame, const WallMap& walls,
                double a, double b, double c);

// Is `p` lattice of this cell: inside its cube, lattice by the domain, of the cell's own
// region and, under a flat region, of the cell's own wall? A cut cell (D3) is exactly the
// part of its cube this holds for; two walls' cut cells may overlap as cubes where the
// walls meet, never as this. Lattice space this holds for in no cell is solid (D14).
bool cell_holds(const Layout& layout, const Domain::Probe& probe, const Cell& cell, const Vec3& p);

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

// ── BARS (stage D) ────────────────────────────────────────────────────────────
// The struts themselves: every strut of every cell, once (a strut two cells share is one
// bar, as wide as the wider cell asks), and for a cut cell the pieces of each strut that
// lie in the cell's own shape (cell_holds). The cell's own type gives the struts
// (lattice_strut_cell); a type with no cell there throws std::invalid_argument.
struct Bar {
  Vec3 a{}, b{};         // its two ends, in the part's own coordinates
  double width = 0.0;    // mm
  double cell = 0.0;     // the size of the cell it is a strut of, mm
  int region = 0;
  // How an end finishes.
  enum class End : std::uint8_t {
    Node,      // a node of its cell: other struts meet it there
    Solid,     // the lattice stops and the part's solid begins: the bar runs on into the
               // solid by one width, so it is joined to it, not butted against it (S11)
    Surface,   // cut flat by the part's own surface: air beyond (S11)
    Loose,     // the cell's shape stops inside the lattice: another wall's or region's
               // cells begin, or space no cell holds. join_loose_bars joins these (S5).
    Joined,    // was Loose: the bar was run on until it met another bar, and ends in it
  };
  End end_a = End::Node, end_b = End::Node;
  bool piece = false;    // part of a strut of a cut cell, not a whole strut
};

struct Bars {
  std::vector<Bar> bars;
  std::size_t stubs = 0;      // pieces shorter than their own width: not kept (S4)
  std::size_t dropped = 0;    // by drop_loose_bars
  std::size_t joined = 0;     // ends, by join_loose_bars
};

Bars lay_bars(const Layout& layout, const Domain& domain, int threads = 0);

// S5: where two walls with different cells meet (or two regions, or two cell sizes whose
// cells are cut against each other), each side's struts stop Loose at the line between
// them. Each such bar is run straight on, in its own direction, until it meets a bar of
// the other side and ends inside it (Joined), or meets solid (Solid, as S11), or has gone
// one cell of its own without meeting anything, in which case it is left as it was. No new
// direction of strut is made, and no join relies on the part's shell. Returns the number
// of ends that landed.
std::size_t join_loose_bars(Bars& bars, const Domain& domain);

// S4, Finish None: a bar is kept only if each of its ends lands on another bar or on
// solid. Removes the rest (a cut end in the air or loose in the lattice, and then any
// bar left holding a node alone), and counts them in `dropped`.
void drop_loose_bars(Bars& bars);

// In the plane of a flat region's face: how far `p` is inside the region's edge (its
// outline moved by Expand), mm. Negative outside. The depth is left out (G5). A curved
// region has no such plane: +infinity.
double region_edge_distance(const Region& r, const Vec3& p);

// Is `p` in the region's prism, with its Expand? At Expand 0 this IS
// point_in_clearance_region(prism, p, 0). Exposed for tests.
bool region_contains(const Region& r, const Vec3& p);

}  // namespace topopt::lattice_layout
