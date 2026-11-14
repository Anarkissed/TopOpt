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
#include <atomic>
#include <cmath>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
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
    // The depth of a point inside the part where it is under `limit`, and `limit` where it
    // is not: only the triangles within `limit` of the point are looked at, so a small
    // limit is cheap however deep the point is.
    double depth_up_to(const Vec3& p, double limit) const;
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
    bool inside(const Vec3& p) const { return inside_along(p, inside_line(), nullptr); }
    // The same, looking along `unit_dir` (any line gives the same answer). When the point
    // is inside, `*reach` receives the distance to the surface that way, as reach_in would.
    bool inside_along(const Vec3& p, const Vec3& unit_dir, double* reach) const;
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
    // `line`, when given, receives the line the answer was measured along: its direction
    // and how far the surface is each way from `p`.
    struct Line { Vec3 dir{}; double fwd = 0.0, back = 0.0; };
    double thickness_in(const Vec3& p, double at_least = 0.0, Line* line = nullptr) const;

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

// The thinnest strut, in line widths: it follows the NOZZLE (R14).
// TWO on a 0.4 mm nozzle, for a part as for a test piece: that is what the app and the
// worker lay with (`Settings::min_strut_lines`). History, all on his own prints: the
// 2026-11-11 coupon (4 mm octet cells, struts about one line wide) came out as blobs and
// strings; on 2026-11-12 he took the two-line rule to be for that coupon only and a part
// went back to one line; the same day his v2 stand, printed at one line, failed too:
// "Looks like single line does not print well at all. Without a 0.2mm nozzle, we can't
// print that small." Reviewer's ruling 2026-11-12 20:02Z: two lines, one line withdrawn.
// ONE is the fewest the engine will lay at all (a 0.2 mm nozzle's case, and what the
// layout's own rule tests are written at); it is `DomainSpec`'s starting value, and
// nothing he sees is laid with it.
inline constexpr double kMinStrutLines = 2.0;
inline constexpr double kFewestStrutLines = 1.0;
inline constexpr double kMinStrutLinesAllSmallest = 2.0;

struct DomainSpec {
  Start start = Start::AllSolid;
  double bead_mm = 0.45;
  // The thinnest strut, in line widths (R5, R14). Never under one. The smallest cell
  // follows from it (C14). Whoever lays for his printer passes kMinStrutLines (the Session
  // does); this starts at the fewest the engine lays.
  double min_strut_lines = kFewestStrutLines;
  // Rule D8: a wall narrower than this cannot hold lattice and is solid. The cell rules
  // (C3-C5) set it; 0 switches the check off. Measured through the wall along the owning
  // prism's direction, or as the narrowest width at the spot where there is no prism (C11).
  double min_wall_mm = 0.0;
  std::vector<Region> regions;
  std::vector<ProtectSkin> protect;
  // Finish Rim (S1, S2, S10): one solid bar round each flat Lattice region's outline,
  // this wide in the plane of the face and as deep as the lattice. It is the band of the
  // region within this distance of its own edge (so it is exactly as smooth as the
  // outline, never a row of blocks), and it stands only where the part's solid backs it:
  // not where the edge faces air, and not along a seam with another Lattice region.
  // 0 = no rim (S8). < 0 = the default width, two line widths (S10).
  double rim_mm = 0.0;
  // Finish Covered (S9): a solid outer shell over the lattice, for anyone who does not
  // care to see it. Lattice within this distance of the part's own surface is solid
  // instead, on every face; the cells start behind it as they do behind a Protect skin.
  // 0 = no cover. < 0 = the default thickness, two line widths.
  double cover_mm = 0.0;
};

enum class Why : std::uint8_t {
  Lattice,      // lattice goes here; `id` is the owning region, 0 = the whole part
  Outside,      // not inside the part (rule D2)
  NotAsked,     // solid: Start from All solid and no Lattice region covers it (D12)
  NoLattice,    // solid: a No lattice region; `id` is that region (D6)
  ProtectSkin,  // solid: within a Protect skin's depth; `id` is that skin (D5)
  WallTooThin,  // solid: lattice was asked for but the wall cannot hold it (D8);
                // `id` is the region that asked, 0 = the whole part
  Rim,          // solid: the rim round a flat Lattice region's outline (S1, S2, S10);
                // `id` is that region
  Cover,        // solid: Finish Covered's shell over the lattice (S9); `id` as Lattice
};

struct Where {
  Why why = Why::Outside;
  int id = 0;
  bool lattice() const { return why == Why::Lattice; }
  bool operator==(const Where& o) const { return why == o.why && id == o.id; }
};

// Stage E, cancel: what a step throws when the layout it is part of was asked to stop. Session::lay catches it and
// answers `cancelled`; a caller that never sets a stop flag never sees it.
struct LayCancelled {};

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
    // +infinity when the part has none. (From Finish Covered's shell it is read no
    // farther than 2 mm: a caller walking by this value takes steps of 2 mm at most.)
    double skin_gap(const Vec3& p) const;
    // C11a (reviewer's ruling 2026-11-11 23:52Z): the cells a member must hold are counted
    // across the ROOM BETWEEN THE SKINS, because that is where the cells live. The
    // material's narrowest width through `p` (PartMeasure::thickness), less what Protect
    // skins or the cover take of that same line. With neither, it is the thickness.
    // `at_least` as for thickness.
    double room_through(const Vec3& p, double at_least = 0.0) const;
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
    std::vector<MeshDistance> skin_groups_;   // one per depth (Domain::skin_groups_)
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
  // Cancel (stage E; 362's bridge, his slider): the flag one layout of this domain is asked to stop by; null = never.
  // Every thread loop of the layout reads it and stops taking work; the step then throws LayCancelled from the calling
  // thread once its threads are done, BEFORE it keeps or returns anything half made, so what the domain keeps for the
  // next layout is whole. Session::lay sets it for the length of one lay.
  void watch(const std::atomic<bool>* stop) { stop_ = stop; }
  bool stop_asked() const { return stop_ && stop_->load(std::memory_order_relaxed); }
  void check_stop() const { if (stop_asked()) throw LayCancelled{}; }
  // The depth a Protect skin is solid to: its own, or two line widths at 0 (rule D5).
  double protect_depth_mm(const ProtectSkin& s) const {
    return s.depth_mm > 0.0 ? s.depth_mm : 2.0 * spec_.bead_mm;
  }
  // The rim's width: the one asked for, or two line widths; 0 with no rim.
  double rim_width_mm() const { return spec_.rim_mm < 0.0 ? 2.0 * spec_.bead_mm : spec_.rim_mm; }
  // The deepest Protect skin or cover there is; 0 with neither.
  double skin_most_mm() const {
    double most = cover_depth_mm();
    for (const ProtectSkin& s : spec_.protect) most = std::max(most, protect_depth_mm(s));
    return most;
  }
  // The cover's thickness: the one asked for, or two line widths; 0 with no cover.
  double cover_depth_mm() const { return spec_.cover_mm < 0.0 ? 2.0 * spec_.bead_mm : spec_.cover_mm; }

 private:
  const PartMeasure* measure_;
  DomainSpec spec_;
  const std::atomic<bool>* stop_ = nullptr;
  std::vector<Near> near_skin_;    // one per Protect skin, within its depth
  // Every Protect skin of one depth as ONE surface (the distance to several surfaces is the least of their
  // distances, so nothing an answer is made of changes). How far a point is from "any skin's solid" is then one
  // question per depth, not one per skin: his v4 stand has 26 skins of 4 mm, and each lay took 289 s against 0.7 s
  // with them sent as one group (362's measure, 2026-11-13). WHICH skin a point is in is still asked skin by skin.
  struct SkinGroup { double depth_mm = 0.0; TriangleMesh faces; };
  std::vector<SkinGroup> skin_groups_;
  std::vector<Near> near_shell_;   // one per region (empty for a prism), within its depth
  // For a flat region: squares of its face that lie wholly inside its edge, or wholly
  // outside it (the distance to the edge at a square's middle is more than half the
  // square's diagonal). A point over such a square is answered without measuring to the
  // outline, which costs a pass over every segment of it.
  struct Sure {
    double u0 = 0.0, w0 = 0.0, pitch = 1.0;
    int nu = 0, nw = 0;
    std::vector<signed char> side;   // +1 inside, -1 outside, 0 near the edge: measure
    int at(double du, double dw) const {
      const double a = (du - u0) / pitch, b = (dw - w0) / pitch;
      if (!(a >= 0.0) || !(b >= 0.0) || a >= nu || b >= nw) return 0;
      return side[static_cast<std::size_t>(b) * nu + static_cast<std::size_t>(a)];
    }
  };
  std::vector<Sure> sure_;         // one per region (empty where it does not apply)
  // region_contains(spec_.regions[i], p), by the squares where they are sure.
  bool region_holds(std::size_t i, const Vec3& p) const;

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
  // D14b (his rule, 2026-11-12, on his v3 stand: "It's either consistently latticed all around the pocket, or it
  // isn't", "Why can't the pocket just cut the lattices wherever they are positioned"). A cell takes in every bit of
  // lattice inside its own cube that no cell of that bit's own region and wall holds: the seam where two regions
  // share a wall, the line between two walls of one face, a wedge beside a curved wall. And a cube that a curved
  // surface cuts so thinly that none of its sample points is lattice is still laid as a cut cell when the rest of it
  // is AIR (it faces the open surface): the lattice runs out to the surface instead of stopping at a solid crust.
  // Off: space no cell of its own holds is solid everywhere (D14 as first built).
  bool absorb_slivers = true;
  // R2, G11 (his rule, 2026-11-12: "without 'Allow quilting' set to 'on' it should NEVER
  // QUILT", meaning never past the open look). The same switch as StrutSpec::allow_quilt.
  //   allow_quilt  off: no cell is under the smallest cell that prints open (C14), in a
  //                Grade to shape band or anywhere else. On: a cell may go down to the
  //                smallest the thinnest strut draws without closing it (the quilt's
  //                cell), wherever a wall or a band needs it.
  //   band_cell_mm Manual: a typed smallest cell for a Grade to shape band, mm; 0 = the
  //                floor above. Held at that floor when it asks for less.
  bool allow_quilt = false;
  double band_cell_mm = 0.0;
  // "LET WALLS CUT CELLS" (his name for the option, 2026-11-14), off by default. On: one even grid that walls and
  // pockets cut through. Off: today's whole cells fitted to walls. Aesthetic only; Structural never shows it.
  // (His words, 2026-11-12: "Why can't the pocket just cut the lattices wherever they are positioned and then a
  // skin connect all the struts that are left disconnected in a pattern?"; his ruling, 2026-11-14: "I think
  // aesthetic should allow the one grid cut wherever. Not structural.", "BUT it should be an option available to
  // the user to select".) A per-part option, OFF unless the user turns it on; off, the layout is what it was, byte
  // for byte. Core does not know the stage, so whoever offers the switch offers it in Aesthetic and nowhere else
  // (a certified wall must hold its cells: C5).
  // On: each region is ONE regular grid of its base cell, and every surface, pocket, hole, Protect skin and the
  // region's own edge simply CUTS it (D3). A flat region's grid is in its face's own frame, the face a cell boundary
  // (C15 at the face), its base cell the largest size not above Max cell that divides the region's depth; it is laid
  // in one frame like a curved region, not wall by wall, and no wall map is read. A curved region and the whole
  // part keep the grid they had. In every region NO cell is refused for the material it stands in: the wall-fit
  // test (C2) and the cells a wall must hold (C3-C5) are not applied, and `min_cells_across` is not read at all.
  // Any cube holding lattice of its region is a cut cell, whose shape is that lattice (cell_holds).
  // Grade to shape is as before (G1-G7, G10), from the region's own outline; the smaller sizes come from the same
  // ladders and never go under the layout's floor cell. With no band every cell is the base cell.
  // What it gives up: C2/C12 (a cell may be wider than its wall), C15 at a wall's FAR side and at a Protect skin's
  // inner side (those cut through cells), and D8 by cell size (a thin wall is cut cells, not solid; the Domain's own
  // `min_wall_mm` still makes solid). A cut piece too small to hold a strut longer than its own width has none.
  bool one_grid = false;
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

// The cells sorted into a coarse grid of the part's own space, to find the cubes round a point.
struct CellIndex {
  double pitch = 4.0;
  std::map<std::array<long long, 3>, std::vector<std::uint32_t>> grid;   // each list in cell order
};

// Why lattice that was asked for is solid in a cube no cell could take (D14): for the one line the app shows.
enum class NoCell : std::uint8_t {
  Other = 0,       // none of the below; the app says only "no cell fits here"
  WallNarrow,      // C2: the wall there is narrower than the smallest cell allowed
  TooFewAcross,    // C3 to C5: a cell fits the wall, but not as many across as the setting asks
  Sliver,          // D14b: a cut piece of this region's lattice too small for a cell, that no neighbouring cell took in
  RegionShallow,   // C15: the region is shallower than the smallest cell allowed
};
struct SolidWhy {
  NoCell why = NoCell::Other;
  float have_mm = 0.0f;   // what is there: the wall's width (WallNarrow, TooFewAcross), the piece's thickness (Sliver), the region's depth (RegionShallow)
  float need_mm = 0.0f;   // what it would have to be for a cell to be laid there with today's settings
};

struct Layout {
  // D14b: cells take in lattice slivers inside their cubes (CellSpec::absorb_slivers). `index` is lay_cells' own.
  bool absorb = false;
  std::shared_ptr<const CellIndex> index;
  double floor_cell_mm = 0.0;        // the smallest cell allowed (C14; the quilt's with Allow quilt)
  double bead_mm = 0.0;              // the line width it was laid for
  double min_strut_mm = 0.0;         // the thinnest strut allowed (R5): lines x line width
  // The type's own two limits, as strut width over cell size (core's lattice_width_bounds):
  // the open look, and where neighbouring struts touch (the quilt). R2, R9.
  double open_look = 0.0, touch = 0.0;
  LatticeTopology topology = LatticeTopology::Octet;
  std::vector<Frame> frames;
  std::vector<WallMap> walls;        // one per frame
  std::vector<Cell> cells;           // in a fixed order: same input, same bytes (D18)
  // D14: space inside a region no cell covers. Solid, and drawn solid. Same shape as a
  // cell: the cube that was tried and did not fit. This is what the laying found, to
  // within its own sample points; the rule itself is for whoever draws or builds:
  // lattice space that cell_holds is true for in no cell is solid.
  std::vector<Cell> solid;
  // D14c: why each cube of `solid` got no cell, and the two sizes. A cube is put down to the first of these that holds:
  //   RegionShallow  the region's own cell is under the smallest cell allowed because the region is too shallow for it
  //                  (have: the region's depth; need: the depth whose cell prints), or, in a region with no face
  //                  (curved), the region's depth is what cuts the wall below the cell tried.
  //   WallNarrow     the wall read there is narrower than the smallest cell tried at that spot (need: that cell).
  //   TooFewAcross   that cell fits the wall, but not min_cells_across of them (have: the member's narrowest width;
  //                  need: that many cells).
  //   Other          anything else (a cell setting under the printable floor; a Stepped unit the band kept empty).
  // Sliver is not recorded today: every cube recorded solid was refused by what its own points read, so one of the
  // first three holds for it. The sliver D14b leaves solid (a thin cut piece with solid beyond it) has no cube here.
  // `need` is rounded up to a micron, so a wall or depth made exactly `need` lays a cell.
  std::vector<SolidWhy> solid_why;  // one per entry of solid, same order
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
// With Layout::absorb (D14b) it also holds lattice inside its cube that belongs to another region or wall, when no
// cell of that region and wall holds it and this is the first cell, in layout order, whose cube the point is in.
bool cell_holds(const Layout& layout, const Domain::Probe& probe, const Cell& cell, const Vec3& p);
// The same for cell number `cell` of the layout at a point (a, b, c) of the cell's own frame, WITHOUT the cube test
// (for a point of the cell's own struts, already a hair inside it).
bool cell_holds_at(const Layout& layout, const Domain::Probe& probe, std::size_t cell, double a, double b, double c);
std::shared_ptr<const CellIndex> index_cells(const Layout& layout, double pitch = 4.0);

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
  // its cell), in a Grade to shape band as anywhere else: the band still thickens its
  // struts toward the outline, and stops there. On, a strut may go up to the quilt.
  bool allow_quilt = false;
  // G4: how much the band raises a strut toward the quilt, as 2^strength, -1 .. 1.
  double strength = 0.0;
};

struct StrutReport {
  std::size_t at_bead = 0;      // cells where the asked width was under the thinnest strut (R5)
  std::size_t at_ceiling = 0;   // cells where it was over the widest allowed (R2, R9)
};

// Sets every cell's strut width. Moves no cell. The two limits are the layout's own type's
// (Layout::open_look, Layout::touch, from core's lattice_width_bounds).
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
  bool skin = false;     // a skin bar (S3): it lies on the part's surface, between cut ends
  // The plane of its cell's own grid that the strut lies in, as that plane's unit normal
  // (an octet strut lies in exactly one: a cell face, or the plane half way between two).
  // Zero for a strut that lies in none, or in two. The skin follows these planes.
  Vec3 flat{};
  // For a Joined end: the bar it ends in (its place in Bars::bars), -1 otherwise. If that
  // bar is removed, this end lands on nothing again (drop_loose_bars follows it).
  int into_a = -1, into_b = -1;
};

// Preview is the spec (reviewer, 2026-11-12): a bar lying flatter than 30 degrees is written to the file as a BRIDGE,
// a square bar with a level underside (his print rule P8 c), not a round one. `up` is the print direction (the part
// stands on its lowest z). The file writer and whoever draws the bars ask this one function.
inline constexpr double kBridgeRise = 0.5;   // rise over length: 30 degrees
inline bool bar_is_bridge(const Bar& bar, double rise = kBridgeRise) {
  const double dx = bar.b.x - bar.a.x, dy = bar.b.y - bar.a.y, dz = bar.b.z - bar.a.z;
  const double len = std::sqrt(dx * dx + dy * dy + dz * dz);
  return len > 1e-9 && rise > 0.0 && std::fabs(dz) / len < rise;
}

struct Bars {
  std::vector<Bar> bars;
  std::size_t stubs = 0;      // pieces shorter than their own width: not kept (S4)
  std::size_t dropped = 0;    // by drop_loose_bars
  std::size_t joined = 0;     // ends, by join_loose_bars
  // Where drop_loose_bars removed a strut that the part's surface had cut and nothing
  // held: the places a stepped edge is left (S4).
  struct CutEnd { Vec3 at{}; int region = 0; double cell = 0.0; };
  std::vector<CutEnd> cut_in_air;
};

// S4: "where a stepped edge is left, the app points at it and says Rim or Skin will fix
// this". The cut ends drop_loose_bars removed, gathered into edges: ends within one and a
// half cells of each other are one edge. A lone end or two is not an edge. Largest first.
struct SteppedEdge {
  int region = 0;
  Vec3 at{};                  // the middle of its ends: where to point
  Vec3 lo{}, hi{};            // the box round them
  std::size_t ends = 0;
};
std::vector<SteppedEdge> stepped_edges(const Bars& bars);

Bars lay_bars(const Layout& layout, const Domain& domain, int threads = 0);

// S5: where two walls with different cells meet (or two regions, or two cell sizes whose
// cells are cut against each other), each side's struts stop Loose at the line between
// them. Each such bar is run straight on, in its own direction, until it meets a bar of
// the other side and ends inside it (Joined), or meets solid (Solid, as S11), or has gone
// one cell of its own without meeting anything, in which case it is left as it was. No new
// direction of strut is made, and no join relies on the part's shell. Returns the number
// of ends that landed.
// `layout`, when given, lets the line know D14: lattice space that no cell holds is
// solid, and a bar that reaches it ends in it like in any other solid.
std::size_t join_loose_bars(Bars& bars, const Domain& domain, int threads = 0,
                            const Layout* layout = nullptr);

// D14, as one question: is `p` solid? Inside the part and either not lattice at all, or
// lattice that no cell of `layout` holds. Built once for a layout; asked from any thread
// with that thread's own probe.
class SolidAt {
 public:
  explicit SolidAt(const Layout& layout);
  bool operator()(const Domain::Probe& probe, const Vec3& p) const;
  // The same, for a point already read as `w`.
  bool operator()(const Domain::Probe& probe, const Vec3& p, const Where& w) const;
  // D14c: for a point this calls solid where lattice was asked for (lattice by the domain, held by no cell), the
  // reason recorded with the solid cube that holds it (Layout::solid_why): the first, in layout order, whose cube the
  // point is in and whose region (and, under a flat region, wall) the point's lattice is. Other when no recorded cube
  // holds it, and for any point this does not call solid where lattice was asked for.
  SolidWhy why(const Domain::Probe& probe, const Vec3& p) const;

 private:
  const Layout* layout_;
  double pitch_ = 4.0;
  std::map<std::array<long long, 3>, std::vector<std::uint32_t>> grid_;
  std::map<std::array<long long, 3>, std::vector<std::uint32_t>> solid_grid_;   // the same, of Layout::solid
};

// S3, Finish Skin: bars across the part's surface joining the cut strut ends, "a flat
// lattice over the lattice". It is open and does not seal (that is Protect skin, D5).
// A REGULAR pattern (his answer, 2026-11-12): the skin is the lattice's own grid drawn on
// the surface. Every strut lies in one plane of its cells' grid (a cell face, or the
// plane half way between two), so its cut end lies on the line where that plane meets
// the surface; the skin joins neighbouring cut ends ALONG that line, and nothing else.
// On a flat face that gives straight rows, one per plane, a half cell apart, in each of
// the grid's directions that cross the face; round a boss, rings and uprights.
// Two cut ends of one plane are joined when no other cut end of that plane lies in or on
// the ball between them, when they are no farther apart than `reach_cells` of the larger
// of their two cells, and when the bar between them lies on the surface (not across a
// notch, nor through the part). Ends of struts that lie in no single plane are joined to
// each other by the same three tests.
// A cut end that gets a skin bar has landed (End::Joined). Returns the number of skin bars.
struct SkinSpec {
  double width_mm = 0.0;      // 0 = as wide as the thinner of the two struts it joins
  double reach_cells = 1.2;
  // Round a CURVED wall a straight bar between two points of the surface leaves the surface by the bow of the curve:
  // into the air on a hollow wall (a pocket), into the part on a bulging one. A bar may bow by this share of its own
  // length and still count as lying on the surface (0.1 is a wall curved as tightly as 1.3 times the bar's length).
  // At 0 only bars that lie in the surface are made: on a pocket's wall that is lines along its axis and no rings
  // (his v3 stand, 2026-11-12: "not just with singular vertical lines, but with a lattice all along the face").
  double bow = 0.1;
};
std::size_t lay_skin(Bars& bars, const Domain& domain, const SkinSpec& spec = SkinSpec{});

// S4, Finish None: a bar is kept only if each of its ends lands on another bar or on
// solid. Removes the rest (a cut end in the air or loose in the lattice, and then any
// bar left holding a node alone), and counts them in `dropped`.
void drop_loose_bars(Bars& bars);

// S4, S5, S6: is the lattice one piece, and is it joined to the part? Bars are one piece
// when they share an end, when an end of one lies inside the other, or when their middle
// lines pass within a quarter of the wider one's width (two struts crossing in the face
// two cells share). A piece is joined to the part when one of its bars ends in solid, or
// has an end touching solid (a node on the plane where the lattice stops).
struct Pieces {
  std::size_t pieces = 0;
  // Pieces not joined to the part's solid. When the whole part is lattice and nothing is
  // joined to solid, the largest piece is the part itself and is not counted here.
  std::size_t adrift = 0;
  std::size_t adrift_bars = 0;
  double adrift_mm = 0.0;        // their struts' total length
  double largest_adrift_mm = 0.0;
};
// `adrift_bar`, when given, receives one flag per bar; `piece_of`, the piece each bar is
// in (pieces numbered from 0 in the order of their first bar).
// `layout`, when given: a bar standing on lattice space that no cell holds stands on solid (D14).
Pieces count_pieces(const Bars& bars, const Domain& domain, std::vector<char>* adrift_bar = nullptr,
                    std::vector<int>* piece_of = nullptr, const Layout* layout = nullptr);
// Finish None, completed: a piece that is not joined to the part cannot be printed and is
// removed. Counted in `dropped`. Returns what count_pieces found before removing.
Pieces drop_adrift_bars(Bars& bars, const Domain& domain, const Layout* layout = nullptr);

// ── SESSION (stage E) ─────────────────────────────────────────────────────────
// What the app holds for one part while its Lattice page is open. It measures the part
// once, and between two layouts keeps everything the changed settings do not touch (P2):
// a cell-size, band or strut slider re-lays the cells without reading the part again; a
// region, depth, Expand, Protect skin, rim or line-width change reads it again, once.
struct Settings {
  struct RegionAsk {
    int id = 0;
    Role role = Role::Lattice;
    std::vector<int> faces;      // the model's own face numbers
    double depth_mm = 0.0;
    double expand_mm = 0.0;
  };
  struct ProtectAsk {
    int id = 0;
    std::vector<int> faces;
    double depth_mm = 0.0;       // 0 = two line widths (D5)
  };
  // Where lattice goes.
  Start start = Start::AllSolid;
  double bead_mm = 0.45;
  double min_strut_lines = kMinStrutLines;
  double min_wall_mm = 0.0;
  double rim_mm = 0.0;           // Finish Rim: 0 none, < 0 two line widths
  double cover_mm = 0.0;         // Finish Covered: 0 none, < 0 two line widths
  std::vector<RegionAsk> regions;
  std::vector<ProtectAsk> protect;
  // The cells, the struts, and what happens to cut ends.
  CellSpec cells;          // its allow_quilt and one_grid are not read: the switches are struts.allow_quilt, one_grid
  StrutSpec struts;
  // Per part, OFF unless he turns it on (his words, 2026-11-12: "I definitely want it as a per-part choice. Especially
  // in the app itself."). A wall too thin for a cell that the thinnest strut leaves open (R5, C14) is normally solid.
  // On, the cells may be as small there as Allow quilt would let them (so the wall is latticed), but no strut is made
  // thicker for it: a cell too small for the open look carries the THINNEST strut and nothing more, and every other
  // cell keeps the open look. Denser than the open look in those small cells, never touching. (His v2 stand, printed
  // with two-line struts: its wing edges, socket walls and spotface walls.) Allow quilt on makes this moot.
  bool small_cells_in_thin_walls = false;
  // "Let walls cut cells" (his ruling 2026-11-14): per part, OFF unless the user turns it on. The session
  // hands it to the cells as CellSpec::one_grid (see there): on, each region is one even grid that every wall, pocket,
  // hole, Protect skin and the region's own edge cuts; off, the layout is what it was, byte for byte. Core does not
  // know Aesthetic from Structural: the app offers the switch in Aesthetic only. A cell setting: changing it lays the
  // cells again and does not read the part again.
  bool one_grid = false;
  bool bars = true;              // false: cells and strut widths only
  bool join_loose = true;        // S5
  bool skin = false;             // Finish Skin (S3)
  SkinSpec skin_spec;
  bool drop_loose = true;        // S4, Finish None's rule; then pieces adrift go too
};

struct Outcome {
  Layout layout;
  StrutReport struts;
  Bars bars;
  Pieces pieces;                 // as found before any piece adrift was removed
  std::vector<SteppedEdge> stepped_edges;   // what Finish None left ragged (S4)
  bool read_again = false;       // the part was read for this layout (a "where" setting changed)
  bool cancelled = false;        // the stop flag was set before the layout was whole: nothing else here is filled
  std::vector<int> empty_regions;   // asked-for regions none of whose faces has triangles
  double ms_read = 0.0, ms_cells = 0.0, ms_bars = 0.0;
};

class Session {
 public:
  // Welds and measures the model once. `open_edges()` is 0 for a part that can be measured.
  explicit Session(StepModel model);
  // `stop`, when given, is read between the steps and inside their thread loops: once it is true the layout is given
  // up and the answer is `cancelled` with nothing else in it (within one cell's or one row's work, not after the
  // whole step). What the session keeps for the next lay() is not harmed: the same settings asked again give the
  // layout a fresh session gives. The flag must outlive the call; the session never writes it.
  Outcome lay(const Settings& settings, int threads = 0, const std::atomic<bool>* stop = nullptr);
  std::size_t open_edges() const { return open_edges_; }
  const PartMeasure& measure() const { return *measure_; }
  // The domain the last lay() was laid in: null before the first, REPLACED when a "where" setting changes. Read it after a
  // lay() and never hold it across the next one (362's bridge, the 4th call: a batch of points -> lattice / rim / solid).
  const Domain* domain() const { return domain_.get(); }

 private:
  StepModel model_;
  std::size_t open_edges_ = 0;
  std::unique_ptr<PartMeasure> measure_;
  std::string where_;                  // the "where" settings the kept domain was made for
  std::unique_ptr<Domain> domain_;
  bool unread_ = false;                // the kept domain has not been laid in once yet (its first lay was cancelled)
  std::vector<int> empty_regions_;
};

// In the plane of a flat region's face: how far `p` is inside the region's edge (its
// outline moved by Expand), mm. Negative outside. The depth is left out (G5). A curved
// region has no such plane: +infinity.
double region_edge_distance(const Region& r, const Vec3& p);

// Is `p` in the region's prism, with its Expand? At Expand 0 this IS
// point_in_clearance_region(prism, p, 0). Exposed for tests.
bool region_contains(const Region& r, const Vec3& p);

}  // namespace topopt::lattice_layout
