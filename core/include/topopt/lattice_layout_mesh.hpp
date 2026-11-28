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
// straight full-width line (a weave's may have a round top over that underside: O14, `weave_round_top`). The part is
// printed standing on its lowest z.
// The other two (flat bed face, nothing starting in mid-air) are judged on the finished
// mesh layer by layer; what they find comes back in as `drop_at` and `posts`.
//
// Needs the Manifold library (TOPOPT_HAVE_MANIFOLD). Without it `mesh_available()` is
// false and `build_mesh` reports that and returns an empty mesh.
#pragma once

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <unordered_map>
#include <cmath>
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
  int threads = 0;            // 0 = every core
  // From the layer check. A strut whose LOWEST point is at one of these places is left out
  // (it hangs from above with nothing under its tip), and so is a small separate piece of
  // the solid body that starts there. A weave's bar is left out only when its lowest end is not held (O10:
  // bars_present with the weave regions, at `layer_mm`).
  std::vector<Vec3> drop_at;
  // The layer check's layer height, read for a weave's bars only (O10, a level end); build_printable_mesh sets it.
  double layer_mm = 0.2;
  // A vertical post, two lines across, from the first material below (`z_bottom`) up to
  // something that would otherwise start in mid-air or reach out held at one end (`z_top`).
  struct Post { double x = 0.0, y = 0.0, z_top = 0.0, z_bottom = 0.0; };
  std::vector<Post> posts;
  double post_mm = 0.9;
  // CUT 1b, the posts step (C3): a post the break check found weak, drawn wider. Matched to a decided post by its
  // place (x, y, z_top, z_bottom exactly); drawn `width` across, its box moved by (ox, oy) so it grows inward where the
  // part's outer face would trim it. Empty (every job but a posts step's re-make): every post as before.
  // C9, flared ends (the owner, 2026-11-27: "push it to cut 1"): `flare_mm` > 0 gives the post a foot and a head, each a
  // frustum with flat sloped sides over `flare_mm` of height, from the post's width at the shaft to a wide end where it
  // meets what it stands on (the foot) and what it holds up (the head); the wide end runs into that material by the
  // post's own run-in (0.25 mm). `foot` and `head` are how far the wide end reaches past the post's box on each side,
  // in the order +x, -x, +y, -y (0: that side stays vertical). 0 (every post but a flared one): the box as before.
  struct PostWide { double x = 0.0, y = 0.0, z_top = 0.0, z_bottom = 0.0, width = 0.0, ox = 0.0, oy = 0.0;
                    double flare_mm = 0.0; std::array<double, 4> foot{}, head{}; };
  std::vector<PostWide> post_wide;
  // The box a post is drawn as: its width and centre (post_mm at its own axis, or its posts-step entry).
  void post_box(const Post& p, double& w, double& cx, double& cy) const {
    w = post_mm;
    cx = p.x;
    cy = p.y;
    for (const PostWide& q : post_wide)
      if (q.x == p.x && q.y == p.y && q.z_top == p.z_top && q.z_bottom == p.z_bottom) {
        w = q.width;
        cx = p.x + q.ox;
        cy = p.y + q.oy;
      }
  }
  // C9: the post's posts-step entry when it is flared (null: drawn as its box alone).
  const PostWide* post_flare(const Post& p) const {
    const PostWide* f = nullptr;
    for (const PostWide& q : post_wide)
      if (q.x == p.x && q.y == p.y && q.z_top == p.z_top && q.z_bottom == p.z_bottom) f = q.flare_mm > 0.0 ? &q : nullptr;
    return f;
  }
  // O8, stands along the way (the owner's OR10: "a preference for stands along the way to keep it up"). A whole
  // shallow run of a weave (stage 1c's run, of the bars the bridge rules keep) that goes farther than this between two
  // stands gets one post at the middle of that stretch, when there is material straight below it (the post starts on
  // that material); with none below it stands as it is. A stand is a joint where another kept bar meets the run, or
  // where the run enters the solid. 0 = never. The number is the lead's (LatticeReview, 2026-11-14), not the owner's.
  // Read by build_printable_mesh only.
  double weave_stand_every_mm = 20.0;
  // O11, the blended foot (the owner's OR17: "blended when a strut meets a wall"). ONLY a bar of a weave region, and
  // ONLY at an end tagged Solid (it runs into the part's solid wall), is given a foot of this size f where it meets
  // the wall (the first point back from that end, along the bar, that is not solid: SolidAt, as the end was tagged).
  // A round strut flares in a straight cone from its own radius r, 3 f along the strut from the wall, to r + f at the
  // wall, and runs on into the solid at that radius. A shallow strut (a bridge, O5) keeps its flat underside exactly:
  // its foot widens by f each side and by f upward over the same 3 f, in straight tapers, and runs on into the solid
  // at that section. The taper never runs past the bar's other end. f is held at r (a foot is never more than twice
  // its strut). 0 = no foot: the mesh as before (the writer's own default, so every caller that does not ask is
  // unchanged). Below 0 = half the bar's own width (the file job's default: FileOptions). Joints between struts, ends
  // cut by the open surface and every cube-lattice bar are unchanged.
  double weave_foot_mm = 0.0;
  // O14, a round top on a weave's shallow struts (the owner approved "give shallow struts a flat bottom with a rounded
  // top instead of a square bar", 2026-11-14). ONLY a bar of a weave region that is a bridge (bar_is_bridge) is written
  // with a D-shaped section: its underside the same flat plane as the square bar's (same plane, same width), its two
  // sides rising straight for half the strut's width, its top a half round of the strut's width made of half
  // `bar_sides` flat facets (its corners on the round); as wide and as tall as the square bar. Its run-on, its foot
  // (O11: the D widened by f each side and f upward, its round's radius r + f, the underside kept) and the balls at its
  // joints are as for the square bar. Every cube-lattice bridge stays square. false = the square bar, the mesh as
  // before: the writer's own default, so every caller that does not ask is unchanged; the file job's default is true
  // (file_mesh_defaults).
  bool weave_round_top = false;
  // O17, O18: what happens to a weave strand that SAGS (the owner's OR29: "A traced curve that sags is never cut for
  // it"). Read by build_printable_mesh only, once, on the layout's bars before the writer (lift_weave_sags).
  // O17: a sag no deeper than this below the lower of its two held nodes is lifted onto the straight line between
  // them. 0 = never lift. The 0.9 mm is the owner's starting number (2026-11-15: "let's start at 0.9mm").
  double weave_sag_lift_mm = 0.9;
  // O18: a deeper sag with material straight below its low point gets a zig-zag leg, the old engine's shape, from that
  // material up to the low point. false = no leg (the sag is left to the layer check, as before).
  bool weave_sag_legs = true;
  // OF4 (brief E1): how a weave's bars reach the file. Merged (the writer's own default, today's route): joined with the
  // solid. Tubes: build_printable_mesh hands build_mesh no weave bar and writes them as closed shells of their own
  // beside the solid (weave_shells), never joined. Read by build_printable_mesh only.
  enum class WeaveMesh { Merged, Tubes };
  WeaveMesh weave_mesh = WeaveMesh::Merged;
  int tube_sides = 8;          // OF2: a weave tube's sides (of the same area as its round strut)
  // OV1: a round weave tube's centre line swept as a curve through its points (sweep_centre_line). Off here (the
  // writer's own default: every caller that does not ask is unchanged); the file job turns it on (organic_sweep).
  SweepAsk sweep{};
  // OS1, the file's vine shape (the owner, 2026-11-20: "the rounded ends aren't attached at the right places, there are
  // places without rounded ends at ALL, and there are just straight cuts to turn instead of angles"; "Build the better
  // vine shape"). Each is off here (the writer's own default: every caller that does not ask is unchanged, to the
  // bit); the file job turns them on (file_mesh_defaults).
  // OS1 B: a shallow run's end (its D or square section) is DOMED wherever a round tube's end gets a half-sphere (a
  // joint, a free end, a split, a proud end): the section's own half-dome, round in plan and on top, its underside the
  // bar's own flat plane; flat only in solid or at a flush face, as a round tube's. false: every such end flat.
  bool weave_bridge_domes = false;
  // OS1 A (his ruling R1): a round tube's sides per piece, from its widest ring: the fewest (even) sides whose flat
  // facet lies no more than this from the true circle (r (1 - cos(pi / n)) <= tube_facet_mm), from `tube_sides` (the
  // floor) up to 24. 0: `tube_sides` always.
  double tube_facet_mm = 0.0;
  // OS1 D: a piece is ended (a round end, or a dome) at a point whose mitred ring would cross the next ring (the
  // segment between them shorter than their two mitre offsets: the fold that drew thin fins). false: as before.
  bool weave_fold_split = false;
  // OS1 B (his ruling R2): the domes the print check made flat again (a finding on them); each listed end is flat.
  std::vector<Vec3> flat_domes_at;
  // OF4: every piece of the solid is kept (the tubes route: pieces the unmerged tubes tie together are not loose).
  // false: the mesh as before.
  bool keep_pieces = false;
  // Set, the work is given up between its steps and LayCancelled is thrown.
  const std::atomic<bool>* stop = nullptr;
};

// Is `bar` left out of the file for the layer check's place `s` (MeshSpec::drop_at)? Its LOWEST point is at `s`
// (within 0.45 mm in z) and the bar passes within its own radius + 0.35 mm of it. The one rule the mesh writer leaves
// struts out by; the strength check asks it too (a cell that lost a bar gets no credit).
inline bool bar_left_out_at(const Bar& x, const Vec3& s) {
  const double r = 0.5 * x.width;
  const Vec3 d{x.b.x - x.a.x, x.b.y - x.a.y, x.b.z - x.a.z};
  const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
  if (std::fabs(std::min(x.a.z, x.b.z) - r - s.z) > 0.45) return false;
  const double t = l2 > 0 ? std::clamp(((s.x - x.a.x) * d.x + (s.y - x.a.y) * d.y + (s.z - x.a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
  const double ex = x.a.x + t * d.x - s.x, ey = x.a.y + t * d.y - s.y, ez = x.a.z + t * d.z - s.z;
  return std::sqrt(ex * ex + ey * ey + ez * ez) < r + 0.35;
}

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
  // The owner's bridge rules for a weave (O6, O7, O9; weave_holds): its shallow bars kept with both ends held, at any
  // length, and those left out because an end is held by nothing kept. Both 0 with no weave region.
  std::size_t kept_any_length = 0, weave_left_unheld = 0;
  // O11: the weave ends given a foot, of them those whose f was held at r, and the material the feet add (each foot
  // as written between the wall and 3 f out, less the strut it wraps there; what runs on into the solid adds none).
  std::size_t feet = 0, feet_held = 0;
  double feet_mm3 = 0.0;
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

// ── THE OWNER'S BRIDGE RULES FOR A WEAVE (O6, O7, O9) ───────────────────────────
// They apply ONLY to the bars of a weave region (region one of `weave_regions`); every other bar is kept here, and
// judged as before.
//   O6, held: an end of such a bar is held when it is in the part's solid (Solid), or shares a joint with another bar
//     that is itself kept: a Node end at the joint (ends within 1e-5 mm are one, end_joints) where a kept bar has an
//     end, a Joined end in a bar (`into_a`, `into_b`) that is kept. A Surface or Loose end is held by nothing.
//   O7, any length: a shallow weave bar (bar_is_bridge at `rise`) with both ends held is kept, whatever its length.
//   O9, leads to nothing: a shallow one with an end not held, or any other weave bar with its LOWEST end not held (the a
//     end at a tie), is left out; then whatever it held is judged again, until nothing changes (a bar whose end lands
//     on a bar that is left out is left out too). It is never given a post instead. `left_unheld` counts both kinds.
// `present`: the bars still in the file (the layer check's `drop_at` leaves some out first); empty = all of them.
// The writer (build_mesh) leaves out what this leaves out; the layer check's loop reads the same answer.
struct WeaveHolds {
  std::vector<char> kept;         // per bar of `bars`: 1 kept (absent bars are 0)
  std::vector<char> shallow;      // per bar: a shallow bar of a weave region
  std::size_t kept_any_length = 0, left_unheld = 0;   // shallow kept; weave bars (shallow or not) left out here
};
WeaveHolds weave_holds(const Bars& bars, const std::vector<int>& weave_regions, const std::vector<char>& present = {},
                       double rise = kBridgeRise);
// The bars a list of `drop_at` places leaves in the file, as build_mesh reads it (per bar: 1 present). A place reaches a
// bar when the bar's lowest point is within 0.45 mm of it in height and the place within half the bar's width + 0.35 mm
// of its line; a bar a place reaches is left out. This form reads every bar so (a cube lattice's rule).
std::vector<char> bars_present(const Bars& bars, const std::vector<Vec3>& drop_at);
// The same, with the bars of `weave_regions` judged by O10 (a finding at a held end, a level end): a place leaves such
// a bar out only when the bar's own LOWEST end (a at a tie) is not held from below or level by what is still present:
// in the solid (Solid), or a Node end where another present bar ends whose other end is less than one layer
// (`layer_mm`, the layer check's height) above it, or a Joined end in a present bar whose lowest end is less than one
// layer above it. An end less than one layer below the bar's other end, when that end is so held, is at its level: the
// bar starts where it is held, and is not left out. Judged again until nothing changes. Every other bar as above; with
// no weave region exactly the form above. `used`, when given: per place, 1 when it left out a bar.
std::vector<char> bars_present(const Bars& bars, const std::vector<Vec3>& drop_at, const std::vector<int>& weave_regions,
                               double layer_mm = 0.2, std::vector<char>* used = nullptr);
// O6 (joints a hair apart): each bar end's joint, ends within a hundredth of a micron (1e-5 mm) of a point already seen
// being that point, as drop_loose_bars reads a joint. Per bar two numbers (a, b): `[2 i]`, `[2 i + 1]`.
std::vector<std::size_t> end_joints(const Bars& bars);
// O10, for the make-check-make loop: what a place of the layer check reaches (as `bars_present` reads it) of the bars
// still `present` (empty = all): how many bars, how many of them cube-lattice bars, how many weave bars held at their
// lowest end from below or level, how many held only at their level (an end less than a layer below a held end), and
// whether the place lies on a weave bar (within its half width + 0.35 mm of its line).
struct WeaveFinding { std::size_t reached = 0, cube = 0, held = 0, level = 0; bool on_weave = false; };
std::vector<WeaveFinding> weave_findings(const Bars& bars, const std::vector<int>& weave_regions,
                                         const std::vector<char>& present, const std::vector<Vec3>& places,
                                         double layer_mm = 0.2);
// SPEED (his 11-22: "We need to speed everything up EXPONENTIALLY"): the bars that can reach a place, found on a grid
// instead of by reading every bar. A bar is filed under every cell of its box grown by half its width + 0.35 mm (the
// farthest a place can lie from it and still read it: weave_findings' reach and "on the weave", the O7 shallow read), so
// a place's cell holds every bar that can reach it (and some that cannot: each is still judged exactly as before).
// `use` (empty: every bar): only the bars marked 1 are filed.
class BarGrid {
 public:
  explicit BarGrid(const Bars& bars, const std::vector<char>& use = {});
  // The bars filed in `p`'s cell, in increasing bar order (empty for a place off the grid or not finite).
  const std::vector<std::uint32_t>& near(const Vec3& p) const;
  static constexpr double kCell = 2.5;   // mm
 private:
  std::unordered_map<std::uint64_t, std::vector<std::uint32_t>> cells_;
  std::vector<std::uint32_t> none_;
};
// weave_findings for many places one by one (the print check's read of the part's own overhangs): the joints and the grid
// made once for `bars` and `present`, which must not change while it is read. `at(p)` == weave_findings(.., {p}, ..)[0].
class WeaveFindingsIndex {
 public:
  WeaveFindingsIndex(const Bars& bars, const std::vector<int>& weave_regions, const std::vector<char>& present,
                     double layer_mm = 0.2);
  WeaveFinding at(const Vec3& place) const;
 private:
  const Bars& bars_;
  std::vector<int> regions_;
  std::vector<char> here_;
  double layer_;
  std::vector<std::size_t> joints_;
  std::vector<std::vector<std::size_t>> at_;
  BarGrid grid_;
};
// The reference form of weave_findings (every bar read for every place, the joints made per call), kept for the tests
// that hold the grid to it.
std::vector<WeaveFinding> weave_findings_every_bar(const Bars& bars, const std::vector<int>& weave_regions,
                                                   const std::vector<char>& present, const std::vector<Vec3>& places,
                                                   double layer_mm = 0.2);
// ── WHAT HAPPENS TO A SAG (O17, O18; the owner's OR29) ─────────────────────────
// Only the bars of a weave region are read and moved; every other bar is never moved.
// HELD FROM BELOW (a node, a joint of end_joints): in the solid (a Solid end), or an end of a bar that is not a weave's,
// or reached by a bar from a node held from below whose far end is not a layer (`layer_mm`) or more below it, or the
// Joined end of a bar landing in a STANDING bar (its lowest node held from below, and, when it lies under 30 degrees,
// both) whose lowest end is less than a layer above it. Read walking upward from the solid, so the two arms of a V
// never hold each other.
// A LOW NODE: a node not held from below where only weave bars end, two or more of them (its ARMS: two of one strand,
// a curve's end and a tie, or more), lower than every node they join it to (a node at exactly its height is passed
// over). An arm runs from it along its bar and on (along the same strand where that strand goes on, else into the one
// other weave bar there) to the nearest node held from below (its held node), or to an end with none (an OPEN arm).
// Lowest low nodes first, each judged on the bars as the sags before it left them:
//   O17, lifted: every arm reaching a held node, and two arms to lift along (the only two, or of more the two of the
//     one strand passing through it; the others, its ties, ride with it), and `lift_mm` > 0: every node strictly
//     between those two held nodes would be moved straight up or down onto the straight line between them, the line read along the arms'
//     length in plan (each node at its share of the way, x and y kept). It is lifted only if no node would move more
//     than `lift_mm`, up or down; else it gets a leg (O18, counted `too_far`). Every weave bar end at a moved node moves
//     with it (the strand's own, its crossings', its ties'); a Joined end landing inside a moved bar moves with the bar
//     at its place along it. An open arm (`open_arm`), more than two arms with no strand through it, or a sag with no
//     length in plan (`not_covered`) has no line to lift it onto: it gets a leg.
//   O18, a leg: `legs` on, and material straight below the low point (the solid, or any bar but its own arms within
//     its half width of the plumb line) before the line leaves the part: a leg in the shape the old engine grew its
//     branched supports (organic_lattice.cpp, "BRANCHED SUPPORT"): from the low point it steps down ONE LAYER at a time;
//     each step leans toward the nearest material of a standing bar in the layer below, looked for on a grid of half
//     the leg's width out to 8 such steps (the old raster's 8 cells of the thinnest radius), by at most tan(40 degrees)
//     of a layer sideways (never flatter than 50 degrees from level), straight down when nothing is in reach; a step
//     that would come within half the leg's width of the part's surface goes straight down instead, and if that would
//     too, the leg is not made. It ends at the first material a step reaches: the solid (cut where the solid begins
//     and run on into it by its own width, end Solid, S11), or any bar but its own arms, standing or not (end Joined
//     into it): it never passes through a bar. Its width is the thinnest weave bar of its region, never under
//     Layout::min_strut_mm; the steps going on in one direction are one bar. Its bars are laid from the foot up (`a`
//     the lower end), each lower end on the one below, the top end on the low node (Node). Legs laid before are
//     material for the next. No material below, or no leg could be made: `unsupported`, the sag left as before.
// The bars of a sag are never cut for it. The hold rules (weave_holds) and the layer check then judge the result
// (build_printable_mesh: a leg they leave out, with the bar it landed on, is taken off `legs` and counted unsupported).
// Nothing changes with `lift_mm` 0 and `legs` false, with no weave region, or with no low node.
struct SagReport {
  std::size_t low_nodes = 0;       // low nodes found on the bars as laid
  std::size_t lifted = 0;          // O17: sags lifted
  double lift_largest_mm = 0.0;    // the most any node of a lifted sag moved, up or down
  std::size_t too_far = 0;         // O17: not lifted, a node would have moved more than lift_mm
  std::size_t open_arm = 0;        // an arm reached an end with no held node
  std::size_t not_covered = 0;     // more than two arms and no strand through it, or no length in plan
  std::size_t legs = 0;            // O18: legs laid (and, after build_printable_mesh, kept)
  std::size_t leg_bars = 0;        // their bars
  double legs_mm = 0.0;            // their length, run-in included
  std::size_t legs_left_out = 0;   // build_printable_mesh: legs the hold rules or the layer check left out
  std::size_t unsupported = 0;     // O18: no material straight below, no leg could be made, or its leg left out
  // Per leg laid: its first bar in the bars after the pass, and how many.
  std::vector<std::pair<std::size_t, std::size_t>> leg_at;
  bool changed() const { return lifted + leg_at.size() > 0; }
};
SagReport lift_weave_sags(const Domain& domain, const Layout& layout, Bars& bars, double lift_mm, bool legs,
                          double layer_mm = 0.2);

// O8: where a weave's whole shallow runs (of the bars `kept` keeps) go farther than `every_mm` between stands, the
// middle of each such stretch, on the run's centre line (`width`: the bar's there; `below_z`: the lowest point of the
// bar within 0.45 mm round it, where material under it is looked for). Runs as stage 1c's table chains them: joints
// where exactly two kept shallow weave bars end at one point and go on in line within 15 degrees. A stand is a joint of
// the run where an end of it is Solid or Joined, or another kept bar has an end, or where another kept bar's Joined end
// lands in one of its bars. A run with no stand (a closed ring tied to nothing) has no stretch. In bar order.
struct WeaveStand { Vec3 at{}; double width = 0.0, below_z = 0.0; };
std::vector<WeaveStand> weave_stands_wanted(const Bars& bars, const std::vector<int>& weave_regions,
                                            const std::vector<char>& kept, double every_mm, double rise = kBridgeRise);

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

// ── THE FILE AS THE SOLID PLUS UNMERGED TUBES (brief E1, OF2, OF3) ─────────────
// A weave's bars as closed, outward shells, each on its own vertices, never joined to each other or to the solid (a
// slicer fills them by the nonzero rule: LayerSpec::Fill::NonZero reads them as it does).
//   OF2 tubes: the strands come from weave_runs at tolerance 0 (links left out), of the bars `kept` (per bar, 1 = in the
//     file; empty = all) of a weave region, less the shallow ones (below). One tube per run, `tube_sides` sides of the
//     same area as the round strut, rings carried along by parallel transport, mitred in the bisecting plane at a turn;
//     at a joint between two bars of a run the WIDER of the two. A turn sharper than 60 degrees is not mitred: the tube
//     ends there and a new one starts. Ends: at a joint, a free end or a sharp-turn split, a half-sphere cap of the
//     tube's own radius; in solid (Solid) run on by build_mesh's own run-on and capped flat; on the part's surface
//     (Surface) capped flat there.
//   The other shapes build_mesh gives a weave bar are shells of their own, from build_mesh's own shape code: a shallow
//     bar (bar_is_bridge) its D section (O14) or square bar, with its run-on; the feet of every bar at a Solid end
//     (O11); and every post of `spec.posts` (the layer check's posts and the O8 stands).
//   OF3 trimmed (`trim`): every vertex more than 0.02 mm outside the part is moved onto its surface along
//     PartMeasure::Probe::through. A shell no longer closed with a positive volume, or under 5 % of its volume before,
//     is a tube made again from its run cut back where its line leaves the part (flat there), trimmed again; failing
//     that (or any other shell) it is left out and counted.
struct WeaveShells {
  TriangleMesh mesh;                     // the shells one after another, each on its own vertices
  std::vector<std::size_t> first_tri;    // per shell, its first triangle; one more at the end (= triangles)
  // tubes: round runs; bridges: shallow runs swept with their own section (D or square; the lead's ruling 2026-11-18).
  std::size_t tubes = 0, sharp_splits = 0, bridges = 0, feet = 0, posts = 0;
  std::size_t trimmed_vertices = 0, rebuilt = 0, left_out = 0;
  std::size_t cut_at_bed = 0;            // shells cut flat at the bed plane
  double trimmed_largest_mm = 0.0;       // the farthest a vertex was moved onto the surface
  double outside_largest_mm = 0.0;       // after trimming: the farthest any vertex lies outside the part (trim on)
  // OG2 (brief E6): run ends standing proud of an open face (a round tube's with a half-sphere cap; a shallow run's keeps
  // its flat end), the vertices the trim left outside as their proud part (each within proud_mm + one radius, a shallow
  // section's corner, of the surface), and the farthest of them outside, mm.
  std::size_t proud_ends = 0, proud_vertices = 0;
  double proud_outside_mm = 0.0;
  // OG2b (brief E6, leg B): bars of the runs whose tubes may stand out where they run along an open face
  // (Bar::along_proud), the vertices left outside for them (each no more than face_relief_mm out, never moved out), the
  // farthest; and how far the shells reach past each side of the part's box (-x, +x, -y, +y, -z, +z), after the trim.
  std::size_t along_bars = 0, along_vertices = 0;
  double along_outside_mm = 0.0;
  double grew_mm[6] = {0, 0, 0, 0, 0, 0};
  // OV1: the round tubes' centre-line pieces before and after the sweep, the spans curved, the inner points kept a
  // mitre by reason (a turn under min_turn_deg; a curve tighter than min_radius x r, its first 20 places; beside a span
  // held straight in solid), and the farthest the curve lies from its bars. All 0 with the sweep off.
  std::size_t sweep_pieces_before = 0, sweep_pieces_after = 0, sweep_spans_curved = 0;
  std::size_t sweep_mitre_small_turn = 0, sweep_mitre_tight = 0, sweep_mitre_straight_end = 0;
  std::vector<Vec3> sweep_tight_at;
  // OV1: every swept piece's centre line as swept (its solid ends after the run-on), for the preview's test.
  std::vector<std::vector<Vec3>> swept_lines;
  double sweep_largest_offset_mm = 0.0;
  // OS1: the shallow runs' domed ends, and those held flat for the print check (MeshSpec::flat_domes_at); each dome's
  // end point (before any run-on) and its half width, for the print check; the pieces ended at a fold (OS1 D); the
  // round tubes' sides, fewest and most (OS1 A; 0 with no round tube).
  std::size_t bridge_domes = 0, domes_held_flat = 0, fold_splits = 0;
  std::vector<std::array<double, 4>> dome_ends;
  int tube_sides_least = 0, tube_sides_most = 0;
  // OS1 (his rule of 11-12: "Please ensure bridges are flat and not curved"): the shallow runs' downward-facing area as
  // written (bars and rounded ends): level, a rising bar's own flat bottom, and the rest (curved or sloped), mm2.
  double bridge_under_level_mm2 = 0.0, bridge_under_own_mm2 = 0.0, bridge_under_other_mm2 = 0.0;
  double mm3 = 0.0;                      // the shells' own volumes, summed (overlaps counted twice)
  double ms = 0.0;
  std::size_t shells() const { return first_tri.empty() ? 0 : first_tri.size() - 1; }
};
WeaveShells weave_shells(const PartMeasure& part, const Domain& domain, const Layout& layout, const Bars& bars,
                         const std::vector<char>& kept, const Carved& carved, const MeshSpec& spec, bool trim = true);
// OS1 A: a round tube's sides for a piece whose widest bar is `width_mm` wide (MeshSpec::tube_facet_mm, tube_sides).
int tube_sides_for(double width_mm, const MeshSpec& spec);
// The equal-area factor of a `sides`-gon: its circumradius over the round's radius of the same area.
double tube_round_factor(int sides);
// OS1 D: the inner points of a swept piece's centre line `p` where it is ended so that no mitred ring crosses the next:
// ring j lies off its point along the bar by up to corner[j] x tan(turn_j / 2) (corner: the ring's farthest point from
// the line: a round tube's radius, a section's corner); a segment shorter than its two ends' offsets folds. Ended
// points have no offset; the larger of a folding segment's two offsets is ended first, until none folds. Sorted.
std::vector<std::size_t> mitre_fold_splits(const std::vector<Vec3>& p, const std::vector<double>& corner);
// Used by weave_shells (build_mesh's own shape code, solid_mesh.cpp): per bar of `bars`, with `strut[i]` its strut and
// with `feet[i]` its feet (O11) as build_mesh makes them; then every post of `spec.posts`. Each shape is appended to `out`
// as a closed shell on its own vertices, its first triangle to `first_tri`. Counts go to `rep` (bridges, feet, posts).
void weave_bar_shells(const Domain& domain, const Layout& layout, const Bars& bars, const std::vector<char>& strut,
                      const std::vector<char>& feet, const Carved& carved, const MeshSpec& spec, TriangleMesh& out,
                      std::vector<std::size_t>& first_tri, MeshReport& rep);
// build_mesh's run-on past a strut's end (MeshSpec::strut_reach_mm, its default read from the carving).
double strut_run_on_mm(const Carved& carved, const MeshSpec& spec);
// Per piece of the carved solid: 1 when build_mesh leaves it out for `drop_at` (a small piece starting at one of them).
std::vector<char> solid_slivers_left_out(const Carved& carved, const std::vector<Vec3>& drop_at);
// K1 (his rule, 2026-11-24): the carved solid itself (the part less the open space, every piece), as a mesh, so the
// print check can tell the material the carving left (the part's) from the material put into the open space (the
// lattice's). Empty without the mesh library or a carving.
TriangleMesh carved_solid_mesh(const Carved& carved);
// OF3 (the lead's ruling, 2026-11-18: the owner's rule is a flat bottom): a closed shell reaching under `bed` cut there,
// with a flat face on the bed plane (Manifold). False (the shell untouched) when it cannot be.
bool cut_shell_at_bed(TriangleMesh& shell, double bed);

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
// SPEED 11-22: the last pass's sections and judgements, so the next pass judges only the layers that changed
// (print_check.cpp; the passes own it). Opaque here.
struct LayerCache;
struct LayerSpec {
  double layer_mm = 0.2;
  double pixel_mm = 0.05;
  double one_ended_over_mm = 1.0;
  // Print rule (e) (reviewer, 2026-11-14, until he names his own number): no bridge reaches more than this past
  // what holds it (a bridge held at both ends reaches half its span). Clean files reach 1.4 to 3.3 mm; the two
  // faults of 2026-11-12 (a cap printed over a paper-thin slot) showed only as reaches of 8.88 and 20.01 mm.
  double reach_limit_mm = kBridgeReachLimitMm;
  // Rule (d), a COUNT only (reviewer, 2026-11-12): an island of a layer thinner than this
  // (and at least `thin_min_mm2` in area) is about one line wide: a strut lying in a
  // lattice face's plane, cut in half along its length by the face. His 8 mm sample has
  // them and printed clean, so nothing is changed for them; every file reports how many.
  double thin_under_mm = 0.6;
  double thin_min_mm2 = 0.15;
  // Places (x, y, and the height under which to look) to ask what material lies straight below: the same reading as
  // a post's foot (the highest layer under it with anything within 0.45 mm). Answered in LayerReport::below.
  std::vector<Vec3> below_of;
  // OF1: how a pixel row is filled from the crossings of the mesh's triangles. EvenOdd (the default, every result as
  // before): inside where an odd number of crossings lie at or before it, so two closed shells that overlap cancel.
  // NonZero (the slicer's rule, for a file of the solid plus unmerged closed tubes): each crossing counts +1 or -1 by
  // the side the triangle's normal faces along the row (+1 where it faces back, entering), inside where the sum is
  // above 0, so overlapping closed outward shells read as their union.
  enum class Fill { EvenOdd, NonZero };
  Fill fill = Fill::EvenOdd;
  // Set: LayerReport::layer_mm2 holds every layer's filled area (for comparing two files layer by layer).
  bool layer_areas = false;
  int threads = 0;
  const std::atomic<bool>* stop = nullptr;
  // SPEED 11-22: null = judge every layer (as before). With one, a layer whose section and the one below are the same
  // as at the last check given the same cache (same grid, layers and thresholds) keeps its judgement: the same report.
  LayerCache* cache = nullptr;
  // K1 (his rule, 2026-11-24): set, each finding keeps its island's pixels (MidAir / OneEnded::pixels: a mid-air start's
  // whole island, an overhang's or a bridge's overhanging patch), so the printable loop can ask what they are made of.
  bool keep_pixels = false;
};
struct LayerReport {
  double z_bed = 0.0;
  double bed_mm2 = 0.0;          // triangles lying flat on the bed
  double sloped_mm2 = 0.0;       // footprint of downward faces within the first layer that are NOT flat on the bed
  double first_layer_mm2 = 0.0;  // the first layer's cross-section
  int layers = 0;
  // K1: the check's pixel grid (pixel (c, r) has its middle at x0 + (c + 0.5) px, y0 + (r + 0.5) px; index r * w + c).
  int grid_w = 0, grid_h = 0;
  double grid_x0 = 0.0, grid_y0 = 0.0, grid_px = 0.0;
  // `pixels` (LayerSpec::keep_pixels only, else empty): the finding's island, as grid indices.
  struct MidAir { double z = 0, mm2 = 0, x = 0, y = 0, size_x = 0, size_y = 0, below_z = 0; bool anything_below = false;
                  std::vector<std::int32_t> pixels; };
  // `more` (a long bridge, LayerSpec::keep_pixels only): the other places of its patch, x y, that reach past
  // `reach_limit_mm` from what holds it and from the far point and each other (a post at each of them and at the far
  // point leaves no place of the patch reaching that far).
  struct OneEnded { double reach_mm = 0, z = 0, x = 0, y = 0, below_z = 0; bool anything_below = false;
                    std::vector<std::int32_t> pixels; std::vector<std::array<double, 2>> more; };
  std::vector<MidAir> mid_air;       // in layer order
  std::vector<OneEnded> one_ended;   // in layer order
  std::vector<OneEnded> long_bridges;   // held at two places or more, but reaching past `reach_limit_mm`; in layer order
  double longest_reach_mm = 0.0;
  std::size_t thin_islands = 0;      // rule (d): islands under `thin_under_mm` thick, all layers together
  int thin_layers = 0;               // layers that have at least one
  // One per LayerSpec::below_of: anything below, and the middle of the highest layer that has it.
  struct Below { bool anything = false; double z = 0.0; };
  std::vector<Below> below;
  // LayerSpec::layer_areas: per layer, its filled area, mm2 (empty otherwise).
  std::vector<double> layer_mm2;
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
// With a weave region, the owner's bridge rules (O5 to O10): the writer leaves out the shallow weave bars that lead
// to nothing (weave_holds); a one-ended overhang or a bridge reaching past `reach_limit_mm` found ON a kept shallow
// weave bar (within its half width + 0.35 mm, as `drop_at` is read) is not a finding: it is kept at any length (O7);
// a stretch of a shallow run longer than MeshSpec::weave_stand_every_mm between stands gets one post at its middle
// where material lies straight below (O8). Everything else, mid-air starts first of all, is judged as before (O10).
struct PrintableSpec {
  MeshSpec mesh;       // its drop_at and posts are where the loop starts from (normally empty)
  LayerSpec layers;
  int most_passes = 10;
  // false: nothing is ever left out; what would start in mid-air is tied down with posts from the first pass.
  bool leave_out = true;
  // ★ 362 11-23: told each try as it starts ("checking it prints: try 3 of at most 10"), so the Mac and the iPad can say
  // what a long check is doing (his worker window sat on "starting..." for seven minutes). Null: nothing said.
  void (*said)(const char*) = nullptr;
  // K1 (his rule, 2026-11-24: "the checking printability should ONLY check what was created in the app, not the rest of
  // the part. Assume the rest of the part is completely printable. That is for the user and the slicer."): a finding
  // counts only when its island (a mid-air start's island, an overhang's or a bridge's overhanging patch) holds an
  // overhang the app made, read pixel by pixel at the layer's middle: a pixel of
  //   - material the app put in: material of the file at least two pixels from the carved solid's own cross-section at
  //     that layer (a kept bar, a weave's tube, a post: what fills the open space), or
  //   - a finish the layout added: material of the carved solid at least 0.3 mm inside its cross-section (clear of the
  //     open space's 0.25 mm reading at its edge) where the domain says rim (S1), cover (S9) or Organic bed floor.
  // Anything else is the part's own and is never judged: material the layout only left in place (the part's walls, a
  // Protect skin, what no region asked for, a wall too thin, lattice space no cell holds, and the surfaces the carving
  // bared on them). (K6 took away the allowance for the app's material at the part's own underside: the bottom row's
  // struts, cut at the bed, hold what floated there.) Organic changes only where a finding lay on the part alone. Near
  // a bar is not on a bar. A long bridge
  // the app made gets a post under each of its places that reach too far, in one try (OneEnded::more), cell lattices
  // only. What F1 / OS17 left to the slicer stays the
  // slicer's, so his rule only ever judges fewer. The part's own is counted (`part_overhangs`, `own_by_k1`), its place
  // kept (`part_overhang_at`), never left out, never propped, never a reason the file is not clean. For a cell lattice
  // and a weave alike. false: F1 and OS17 as before (a finding read at its far point only: within half a bar's width +
  // 0.35 mm of a kept bar, or with part under it, judged).
  bool only_app_made = true;
};
struct PrintableReport {
  MeshReport mesh;     // of the mesh returned
  LayerReport layers;  // of the mesh returned
  int passes = 0;
  bool clean = false;  // the loop ended because the check was clean (not because it ran out of passes)
  std::vector<int> found_per_pass;   // mid-air starts + one-ended overhangs, pass by pass
  std::vector<Vec3> drop_at;         // what the loop ended with: the same call with these gives the mesh in one pass
  // OG2c (brief E6, leg C): where the final check's findings lie (mid-air starts, one-ended overhangs, long bridges;
  // empty when clean), the bars whose relief was cut back flush because a finding lay on their proud part, and how many
  // times the whole loop was run again for that.
  std::vector<Vec3> findings_at;
  // OS1 B (his ruling R2): domed shallow ends a finding lay on, made flat again (the pass made again), and how many
  // passes that took.
  std::size_t domes_flattened = 0;
  int dome_rounds = 0;
  std::vector<Vec3> flat_domes_at;   // OS1 B, leg U: every domed shallow end held flat, at its place (the last pass's)
  std::size_t relief_flushed = 0;
  int relief_rounds = 0;
  // OJ6 (leg J item 6): the two ends of each bar made flush, as it was given (so the preview can clear its relief).
  std::vector<std::array<Vec3, 2>> relief_flushed_at;
  std::vector<MeshSpec::Post> posts;
  std::size_t stands_added = 0;      // O8: of `posts`, those put under a weave's long shallow runs
  // O10, mid-air findings that are not findings for a weave, all passes together: a speck (an island smaller than
  // half a line width both ways, on a weave bar, reaching no cube-lattice bar), and a held start (a place that would
  // leave out no bar: every bar it reaches is a weave bar that starts where it is held, WeaveFinding held + level).
  std::size_t weave_specks_ignored = 0, weave_held_ignored = 0;
  // The lead's ruling (2026-11-19): with a weave region the print check judges and props weave bars only. A mid-air
  // start, an overhang held at one end or a bridge too long of the PART'S OWN solid (it reaches no bar, lies on no weave
  // bar, and right under it, a layer down, is outside the part) is the slicer's business: counted here, all passes
  // together, never left out, never propped, never a reason the file is not clean.
  std::size_t part_overhangs = 0;
  // ★ 362 11-23 (his regular lattice refused every time on his stand): F2, the posts not added because their column
  // leaves the part (the cut to the part deletes what of a post is outside it, so it could never hold anything); F3, the
  // loop stopped because a try had nothing new to try (the same findings, no new place to leave out, no new post), so
  // the next try would have been the same file again.
  std::size_t posts_outside = 0;
  bool stopped_repeating = false;
  // P3 (his print orientation): where the part's own overhangs are, of the LAST pass (the mesh returned): each finding
  // the weave's rule or the cell lattice's (F1) took as the part's own, its place (x, y, z, the layer's middle), so the
  // file can paint the part's triangles there as support enforcers (support_paint.hpp).
  std::vector<Vec3> part_overhang_at;
  // K1 (PrintableSpec::only_app_made), all passes together: of `part_overhangs`, the findings the far-point reading of
  // F1 / OS17 judged (a kept bar within half its width + 0.35 mm of it, or the part right under it) that his rule leaves
  // to the slicer. (What the far point left to the slicer stays the slicer's: his rule only ever judges fewer.)
  std::size_t own_by_k1 = 0;
  // O17, O18: what the sag pass did (once, before the first pass), and, when it changed a bar, the bars every pass
  // was made of (the layout's own otherwise: null). `drop_at` and `posts` are read against those.
  SagReport sags;
  std::shared_ptr<const Bars> sagged;
  // OF4, the tubes route (MeshSpec::weave_mesh Tubes with a weave region): the mesh returned is the solid (with any
  // cube lattice joined to it) and then every shell of the weave, unmerged. `shells` holds the last pass's counts (its
  // mesh is not kept: it is the mesh returned from `base_triangles` on), `shell_first_tri` each shell's first triangle in
  // the mesh returned (and one more at the end). The solid is made again only when the cube bars left in, or the slivers
  // of solid the layer check leaves out, change (`base_builds`).
  bool tubes = false;
  WeaveShells shells;
  std::size_t base_triangles = 0;
  std::vector<std::size_t> shell_first_tri;
  int base_builds = 0;
  double ms_shells = 0.0;            // all passes together
  // OF4 times, the tubes route: per pass, the shells, the layer check, and the solid when it was made again (else 0).
  struct PassTime { double shells_ms = 0.0, layers_ms = 0.0, solid_ms = 0.0; };
  std::vector<PassTime> pass_ms;
  double ms_carve = 0.0;             // the part carved, once for all the passes
  double ms = 0.0;
};
TriangleMesh build_printable_mesh(const PartMeasure& part, const Domain& domain, const Layout& layout,
                                  const Bars& bars, const OpenSpace& open, const PrintableSpec& spec = PrintableSpec{},
                                  PrintableReport* report = nullptr);

}  // namespace topopt::lattice_layout
