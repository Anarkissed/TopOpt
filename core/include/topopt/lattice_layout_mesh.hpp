// Lattice rebuild, stage F: the printable mesh, made FROM THE LAYOUT (rules L1, P1: the
// preview draws the layout and the run builds from the same one; nothing is laid twice).
//
// One closed surface of one piece of material:
//   - the part, less the open space of every cell (each cell's own shape, as `cell_holds`
//     and `read_at` give it: the same reading the cells were laid by);
//   - plus every bar of the layout as a solid strut, cut to the part.
// It is the writer his v2 stand was printed from on 2026-11-12 (first as a scratch tool),
// moved here unchanged in what it builds.
//
// What the mesh is cleaned of, because a slicer reads corners by PLACE:
//   - two surfaces that touch along a line or at a point (separate corners at one place)
//     are parted by a few microns, each corner drawn back into its own solid;
//   - a closed space inside the material that could not hold one cell is filled (lattice
//     sealed in behind skins on every side is larger: it stays), loose bits are left out;
//   - no triangle has two corners at one place.
//
// His print rules that live here (2026-11-12): a strut that lies flatter than 30 degrees
// is a BRIDGE: a square bar, its underside level, so its first layer across the gap is one
// straight full-width line. The part is printed standing on its lowest z.
// The other two (flat bed face, nothing starting in mid-air) are judged on the finished
// mesh layer by layer; what they find comes back in as `drop_at` and `posts`.
//
// Needs the Manifold library (TOPOPT_HAVE_MANIFOLD). Without it `mesh_available()` is
// false and `build_mesh` reports that and returns an empty mesh.
#pragma once

#include <atomic>
#include <cstddef>
#include <memory>
#include <string>
#include <vector>

#include "topopt/lattice_layout.hpp"
#include "topopt/mesh.hpp"

namespace topopt::lattice_layout {

// The open space of the layout's cells, as boxes in each cell's own frame. It depends on
// the domain and the cells only (not on the struts, nor on which of them are left out), so
// whoever makes the mesh more than once reads it once.
struct OpenSpace {
  struct Box { int frame = 0; double lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0}; };
  std::vector<Box> boxes;   // in cell order: the same for any number of threads
  double pitch_mm = 0.0;
  double ms = 0.0;
};
// `pitch_mm`: how finely each cell's shape is read (0.25 printed clean at a 0.45 mm line).
// `stop` as in Session::lay: set, the reading is given up and LayCancelled is thrown.
// Inside a cell, the points read one by one are put back together as few boxes as hold them
// exactly (neighbouring equal runs in a row, then equal rows); `merge` false leaves every
// run down a column a box of its own (the same open space, in many more boxes: for the test
// that holds the two the same).
// `keep_edge` (S11b, default on): the file never opens space past the lattice's edge where that edge is against
// solid. A point or column is opened when its middle is held, so its footprint can reach up to half a point past the
// true edge: against air that is wanted (no crust at an open surface), against solid it opened a slit under his v3
// stand's caps and thinned Protect skins by up to 0.11 mm. On, where opened space ends, a point whose footprint has
// solid at a corner (or half a step along its column) is not opened; against solid the file keeps up to one point
// more solid than the true edge, never less. Off: the reading as it was.
OpenSpace read_open_space(const Domain& domain, const Layout& layout, double pitch_mm = 0.25,
                          int threads = 0, const std::atomic<bool>* stop = nullptr, bool merge = true,
                          bool keep_edge = true);

struct MeshSpec {
  int bar_sides = 12;         // a round strut is a bar of this many flat sides, of the same area
  double block_mm = 12.0;     // struts are joined block by block (memory stays flat), then the blocks
  double grow_mm = 0.02;      // open boxes overlap their neighbours by this, never only touch
  double clean_mm = 0.004;    // no edge shorter than this is left in the mesh
  double part_mm = 0.006;     // how far touching corners are drawn apart
  // A closed space inside the material smaller than this is filled; a larger one is
  // lattice sealed in behind skins and stays. Below 0 = the volume of the smallest cell
  // the layout laid: a sealed scrap that could not hold one cell is not lattice anyone
  // asked for (his stand has one of 4 mm3), and a slicer would count it as a second part.
  double fill_under_mm3 = -1.0;
  // A strut whose rise is under this share of its length (0.5 = 30 degrees) is a bridge.
  // 0 = every strut round.
  double bridge_rise = kBridgeRise;
  // Every strut is written this much longer at each end, along its own line, than the layout's bar (round struts and
  // bridges alike; a bridge keeps its level underside; posts are not changed; the struts are still cut to the part).
  // The open space is read in columns of its pitch, and an opened column can reach up to half a column past the true
  // edge of the lattice, while a strut is cut exactly at that edge: where lattice ends against solid each strut could
  // stop up to about 0.1 mm short of the solid it should stand on (his v3 stand: an empty line under each cap, tied
  // down only by the make-check-make loop's posts). Run on, it is fused into the solid. The layout's bars are not
  // changed: the preview and the strength check see the same bars. Below 0 = half the open space's pitch + the grow_mm
  // it was carved with + 0.05 mm (0.195 mm at the defaults); 0 = off, the mesh as before.
  double strut_reach_mm = -1.0;
  // S12, the joint fillet (Manual control 9: "the blend radius where struts meet. Joints are where lattices crack").
  // 0 = off: the mesh as before, exactly. Above 0, at every strut end the part's surface does not cut flush:
  //   - the ball at the joint is the widest strut's half width there plus f_eff;
  //   - a round strut flares into the joint in a straight cone, from its own half width r at r + 3 f_eff from the end
  //     to r + f_eff at the end (a slope of at most 1 in 3); its middle is not changed, and the run-on past the end
  //     (strut_reach_mm) keeps the flared width;
  //   - a bridge does not flare (its underside stays level, P8 c); only the ball at its joint grows.
  // f_eff = min(fillet_mm, r): a joint is never more than twice its strut (for a ball, r of the widest strut there).
  // An end that runs into solid flares the same way: the strut meets the wall with a fillet. The layout's bars are
  // not changed: the preview and the strength check see the same bars.
  double fillet_mm = 0.0;
  int threads = 0;            // 0 = every core
  // From the layer check. A strut whose LOWEST point is at one of these places is left out
  // (it hangs from above with nothing under its tip), and so is a small separate piece of
  // the solid body that starts there.
  std::vector<Vec3> drop_at;
  // A vertical post, two lines across, from the first material below (`z_bottom`) up to
  // something that would otherwise start in mid-air or reach out held at one end (`z_top`).
  struct Post { double x = 0.0, y = 0.0, z_top = 0.0, z_bottom = 0.0; };
  std::vector<Post> posts;
  double post_mm = 0.9;
  // Set, the work is given up between its steps and LayCancelled is thrown.
  const std::atomic<bool>* stop = nullptr;
};

struct MeshReport {
  bool ok = false;
  std::string why;                 // when not ok: one plain line
  double part_mm3 = 0.0;
  std::size_t bars = 0, bridges = 0, balls = 0;
  std::size_t bars_left_out = 0;   // for `drop_at`
  double bars_left_out_mm = 0.0;
  std::size_t drop_unanswered = 0; // `drop_at` places no strut answered for
  std::size_t posts = 0;
  double posts_mm = 0.0;
  double fillet_mm = 0.0;          // S12: as asked
  std::size_t flares = 0;          // round strut ends flared into their joint
  std::size_t fillet_held = 0;     // round struts flared whose half width is under fillet_mm: held at their half width
  double struts_mm3 = 0.0;         // joined and cut to the part
  double solid_mm3 = 0.0;          // the part less the open space
  std::size_t solid_pieces = 0;
  std::size_t slivers_left_out = 0;
  double slivers_mm3 = 0.0;
  std::size_t touching_places = 0; // parted
  double filled_under_mm3 = 0.0;   // the size a closed space had to reach to stay
  std::size_t air_pockets = 0;     // closed spaces smaller than that: filled
  double air_pockets_mm3 = 0.0;
  std::size_t sealed_spaces = 0;   // lattice sealed in behind skins: kept
  std::size_t loose_bits = 0;      // left out
  double loose_mm3 = 0.0;
  std::size_t flat_triangles = 0;  // two corners at one place: left out
  std::size_t triangles = 0;       // of the mesh returned
  double mm3 = 0.0;                // of the mesh returned
  double ms_struts = 0.0, ms_solid = 0.0, ms_finish = 0.0;
};

bool mesh_available();

// The part with every cell's open space taken out of it: the slow half of the mesh, and
// the half that does not depend on the struts. Whoever makes the mesh more than once (the
// make-check-make loop below changes only which struts are left out and which posts are
// added) carves once and hands it to every build. `kept` is the writer's own.
struct Carved {
  bool ok = false;
  std::string why;      // when not ok: one plain line
  double ms = 0.0;
  std::shared_ptr<const void> kept;
};
// `grow_mm` as MeshSpec::grow_mm. A stop flag gives the work up by throwing LayCancelled.
Carved carve_part(const PartMeasure& part, const Layout& layout, const OpenSpace& open, double grow_mm = 0.02,
                  const std::atomic<bool>* stop = nullptr);

// The mesh of `layout` and `bars` in `part` (the measure the domain was made on).
// Corners are at 32-bit places (what an STL holds), written into the mesh's doubles
// exactly, so the file has the corners the checks were made on.
// The same inputs give the same mesh, triangle for triangle, for any number of threads.
TriangleMesh build_mesh(const PartMeasure& part, const Domain& domain, const Layout& layout,
                        const Bars& bars, const OpenSpace& open, const MeshSpec& spec = MeshSpec{},
                        MeshReport* report = nullptr);
// The same mesh, triangle for triangle, from a part already carved (of the same part,
// layout and open space; `spec.grow_mm` is not read, the carving's own was used).
TriangleMesh build_mesh(const PartMeasure& part, const Domain& domain, const Layout& layout,
                        const Bars& bars, const Carved& carved, const MeshSpec& spec = MeshSpec{},
                        MeshReport* report = nullptr);

// ── HIS PRINT RULES, JUDGED LAYER BY LAYER (P8) ─────────────────────────────────
// The mesh as a printer lays it, standing on its lowest z: one cross-section per layer,
// read at mid-layer on a grid of pixels. "Under" a layer is the layer below grown by one
// layer height (the usual 45 degree rule).
//   - BED: is the lowest face flat, and how much of the first layer rests on it.
//   - MID-AIR: an island of a layer with nothing under it at all. Never allowed (P8 b).
//   - ONE-ENDED: a patch reaching more than 1 mm past anything under it and held at one
//     place only (a bridge is held at two or more separate places and is fine).
//   - the longest reach of any bridge, for the report.
// Judged on the finished mesh, never strut by strut: a strut-by-strut rule threw out
// 3,033 good struts on his stand (2026-11-12) and made a 3.3 mm overhang.
struct LayerSpec {
  double layer_mm = 0.2;
  double pixel_mm = 0.05;
  double one_ended_over_mm = 1.0;
  // Print rule (e) (reviewer, 2026-11-14, until he names his own number): no bridge reaches more than this past
  // what holds it (a bridge held at both ends reaches half its span). Clean files reach 1.4 to 3.3 mm; the two
  // faults of 2026-11-12 (a cap printed over a paper-thin slot) showed only as reaches of 8.88 and 20.01 mm.
  double reach_limit_mm = 5.0;
  // Rule (d), a COUNT only (reviewer, 2026-11-12): an island of a layer thinner than this
  // (and at least `thin_min_mm2` in area) is about one line wide: a strut lying in a
  // lattice face's plane, cut in half along its length by the face. His 8 mm sample has
  // them and printed clean, so nothing is changed for them; every file reports how many.
  double thin_under_mm = 0.6;
  double thin_min_mm2 = 0.15;
  int threads = 0;
  const std::atomic<bool>* stop = nullptr;
};
struct LayerReport {
  double z_bed = 0.0;
  double bed_mm2 = 0.0;          // triangles lying flat on the bed
  double sloped_mm2 = 0.0;       // footprint of downward faces within the first layer that are NOT flat on the bed
  double first_layer_mm2 = 0.0;  // the first layer's cross-section
  int layers = 0;
  struct MidAir { double z = 0, mm2 = 0, x = 0, y = 0, size_x = 0, size_y = 0, below_z = 0; bool anything_below = false; };
  struct OneEnded { double reach_mm = 0, z = 0, x = 0, y = 0, below_z = 0; bool anything_below = false; };
  std::vector<MidAir> mid_air;       // in layer order
  std::vector<OneEnded> one_ended;   // in layer order
  std::vector<OneEnded> long_bridges;   // held at two places or more, but reaching past `reach_limit_mm`; in layer order
  double longest_reach_mm = 0.0;
  std::size_t thin_islands = 0;      // rule (d): islands under `thin_under_mm` thick, all layers together
  int thin_layers = 0;               // layers that have at least one
  // The bed face is flat (no sloped or curved underside in the first layer worth the name,
  // and the first layer rests on the bed), nothing starts in mid-air, nothing is one-ended.
  bool bed_flat() const { return sloped_mm2 <= 0.5 && bed_mm2 >= 0.98 * first_layer_mm2; }
  bool clean() const { return mid_air.empty() && one_ended.empty() && long_bridges.empty(); }
};
LayerReport check_layers(const TriangleMesh& mesh, const LayerSpec& spec = LayerSpec{});

// The mesh that PRINTS: made, checked layer by layer, and made again until nothing starts
// in mid-air and nothing is one-ended. What the check finds is first answered by leaving
// out the struts (and specks of solid) that start there; when that stops helping, by a
// post from the first material below. This is the loop his v2 stand file came out of.
struct PrintableSpec {
  MeshSpec mesh;       // its drop_at and posts are where the loop starts from (normally empty)
  LayerSpec layers;
  int most_passes = 10;
  // false: nothing is ever left out; what would start in mid-air is tied down with posts from the first pass.
  bool leave_out = true;
};
struct PrintableReport {
  MeshReport mesh;     // of the mesh returned
  LayerReport layers;  // of the mesh returned
  int passes = 0;
  bool clean = false;  // the loop ended because the check was clean (not because it ran out of passes)
  std::vector<int> found_per_pass;   // mid-air starts + one-ended overhangs, pass by pass
  std::vector<Vec3> drop_at;         // what the loop ended with: the same call with these gives the mesh in one pass
  std::vector<MeshSpec::Post> posts;
  double ms_carve = 0.0;             // the part carved, once for all the passes
  double ms = 0.0;
};
TriangleMesh build_printable_mesh(const PartMeasure& part, const Domain& domain, const Layout& layout,
                                  const Bars& bars, const OpenSpace& open, const PrintableSpec& spec = PrintableSpec{},
                                  PrintableReport* report = nullptr);

}  // namespace topopt::lattice_layout
