// CORE LIST item 42, option B (the reviewer's ruling of 2026-10-25 03:58; his "we
// really need to implement that singular model logic") — ONE PIECE.
//
// The optimizer has no connectivity constraint: a part that was one piece as drawn
// can come out as several (his Carriage Arms split into two arms; a run's anchored
// pads left as islands). With `bridge_pieces`, the carrying bodies the part as drawn
// held in one body are bridged back together before the rung is certified, and the
// line says how many bridges it laid.
//
// Two hand-built parts on the design-box path, each at the density floor (item 40),
// so the free material is removed deterministically:
//   (a) TWO BLOCKS JOINED BY A WEB, each anchored below and loaded above (his two
//       arms): without the bridge the floor rung is two bodies; with it, one,
//       accepted, "bridged".
//   (b) THE L-BRACKET WITH A STRAY ANCHOR (item 47's case): without the bridge the
//       floor rung is rejected, "anchored piece detached" (47's rule, kept as the
//       fallback); with it, the anchor is joined back and the rung is accepted.
//   (c) A PART DRAWN AS TWO BODIES stays two: the bridge only rejoins what the
//       drawing joined.
// THE BRIDGE HOLDS ITSELF (the reviewer's values of 2026-10-25 07:05; his "definitely
// needs to be able to hold itself"). A bar whose middle the floor rung removes: block
// A anchored and loaded, block B anchored only, so B must hang from the bridge:
//   (d) under three times B's weight plus a tenth of the real load across the bridge,
//       a one-voxel bridge is too thin; it is thickened a layer at a time until its
//       own margin clears margin_stop, and the receipt says how thick and how often;
//   (e) a load no three layers can hold: the bridge is lifted, B is let go again and
//       item 47 rejects the rung, the receipt naming the bridge that did not hold;
//   (f) the bridge is at least 2 x wall_loops x wall_line_width thick when the job
//       carries walls (else the min feature).
// Eigen (minimize_plastic), OCCT-free.

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cstdio>
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;
#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

Material fdm() {
  Material m;
  m.youngs_modulus_mpa = 3500.0; m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24; m.z_knockdown = 0.55; m.poisson = 0.33; m.family = "fdm";
  return m;
}

void clamp_voxel_nodes(const VoxelGrid& g, int i, int j, int k, std::vector<DirichletBC>& bcs) {
  for (int c = 0; c < 8; ++c) {
    const int n = fea_node_index(g, i + (c & 1), j + ((c >> 1) & 1), k + ((c >> 2) & 1));
    for (int d = 0; d < 3; ++d) bcs.push_back({n, d, 0.0});
  }
}

// One floor rung of a part whose frozen material is `frozen`, in a snug design box.
MinimizePlasticResult run(const VoxelGrid& part, const std::vector<DirichletBC>& bcs,
                          const DesignMask& frozen, bool bridge, const SettingsRules& rules,
                          Vec3 force = Vec3{0.0, 0.0, -2.0}, int wall_loops = 0,
                          double wall_line_width_mm = 0.45) {
  MinimizePlasticOptions o;
  o.volume_fraction_ladder = {0.26};
  o.margin_stop = 1.5;
  o.external_loads = traction_loads(part, VoxelTag::Load, force);
  o.wall_loops = wall_loops;
  o.wall_line_width_mm = wall_line_width_mm;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.updater = SimpUpdater::MMA;
  o.infill_percent = 100.0;
  o.bake_build_orientation = BakeBuildOrientation::Off;
  o.design_box = DesignBox{part.origin, Vec3{part.origin.x + part.nx * part.spacing,
                                            part.origin.y + part.ny * part.spacing,
                                            part.origin.z + part.nz * part.spacing}};
  o.design_mask = frozen;
  o.bridge_pieces = bridge;
  return minimize_plastic(part, fdm(), "fdm", bcs, rules, o);
}

int carrying_bodies(const MinimizePlasticResult& r) {
  const PrintedBodies pb =
      printed_bodies(r.solved_grid, r.evaluated.front().optimization.physical_density, 0.5);
  int n = 0;
  for (const PrintedBody& b : pb.bodies) n += b.carries();
  return n;
}

VoxelGrid blank(int nx, int ny, int nz) {
  VoxelGrid g;
  g.nx = nx; g.ny = ny; g.nz = nz; g.spacing = 2.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Empty);
  return g;
}

}  // namespace

int main() {
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);

  // ── (a) two blocks joined by a web ─────────────────────────────────────────
  {
    VoxelGrid g = blank(12, 3, 6);
    std::vector<DirichletBC> bcs;
    DesignMask frozen(g.voxel_count(), MaskValue::Active);
    for (int k = 0; k < 6; ++k)
      for (int j = 0; j < 3; ++j)
        for (int i = 0; i < 12; ++i) {
          const bool block = i < 4 || i >= 8;
          const bool web = !block && k < 2;
          if (!block && !web) continue;
          g.set_tag(i, j, k, VoxelTag::Interior);
          if (block) frozen[g.index(i, j, k)] = MaskValue::FrozenSolid;
          if (block && k == 0) {
            g.set_tag(i, j, k, VoxelTag::Fixture);
            clamp_voxel_nodes(g, i, j, k, bcs);
          }
          if (block && k == 5) g.set_tag(i, j, k, VoxelTag::Load);
        }
    const MinimizePlasticResult off = run(g, bcs, frozen, false, rules);
    const MinimizePlasticResult on = run(g, bcs, frozen, true, rules);
    std::printf("[42] two blocks: without the bridge %d carrying bodies; with it %d, "
                "%d bridge(s), %lld voxels, %s\n",
                carrying_bodies(off), carrying_bodies(on), on.evaluated.front().report.bridges,
                on.evaluated.front().report.bridge_voxels,
                on.evaluated.front().accepted ? "accepted" : "rejected");
    CHECK(carrying_bodies(off) == 2,
          "precondition (a): at the floor the web goes and the part splits in two");
    CHECK(carrying_bodies(on) == 1, "(a) the bridge rejoins the two blocks");
    CHECK(on.evaluated.front().report.bridges >= 1 &&
              on.evaluated.front().report.bridge_voxels > 0 &&
              on.evaluated.front().report.bodies_reported,
          "(a) the line says the rung was bridged, and with how much");
    CHECK(on.evaluated.front().accepted, "(a) the bridged rung is certified and accepted");
  }

  // ── (b) the L-bracket with a stray anchor ──────────────────────────────────
  {
    VoxelGrid g = blank(8, 3, 8);
    std::vector<DirichletBC> bcs;
    DesignMask frozen(g.voxel_count(), MaskValue::Active);
    for (int k = 0; k < 8; ++k)
      for (int j = 0; j < 3; ++j)
        for (int i = 0; i < 8; ++i)
          if (i < 2 || k < 2) g.set_tag(i, j, k, VoxelTag::Interior);
    for (int j = 0; j < 3; ++j)
      for (int i = 0; i < 2; ++i) {
        g.set_tag(i, j, 7, VoxelTag::Fixture);
        clamp_voxel_nodes(g, i, j, 7, bcs);
      }
    for (int k = 0; k < 2; ++k)
      for (int j = 0; j < 3; ++j) g.set_tag(7, j, k, VoxelTag::Load);
    g.set_tag(4, 2, 0, VoxelTag::Fixture);  // the stray anchor, off the frozen path
    clamp_voxel_nodes(g, 4, 2, 0, bcs);
    for (int k = 0; k < 8; ++k)
      for (int i = 0; i < 8; ++i)
        if (i < 2 || k < 2) frozen[g.index(i, 0, k)] = MaskValue::FrozenSolid;  // y=0 slab
    const MinimizePlasticResult off = run(g, bcs, frozen, false, rules);
    const MinimizePlasticResult on = run(g, bcs, frozen, true, rules);
    const VariantReport& ro = off.evaluated.front().report;
    const VariantReport& rn = on.evaluated.front().report;
    std::printf("[42] stray anchor: without the bridge %s (%s); with it %s, %d bridge(s)\n",
                off.evaluated.front().accepted ? "accepted" : "rejected",
                ro.rejection_reason.c_str(), on.evaluated.front().accepted ? "accepted" : "rejected",
                rn.bridges);
    CHECK(!off.evaluated.front().accepted && ro.rejection_reason == kAnchorDetachedReason,
          "(b) without the bridge, item 47's rule still rejects the rung");
    CHECK(on.evaluated.front().accepted && rn.bridges >= 1 && rn.anchored_pieces_lost == 0,
          "(b) with it, the stray anchor is joined back and the rung is accepted");
    CHECK(carrying_bodies(on) == 1, "(b) one piece");
  }

  // ── (c) a part drawn as two bodies stays two ────────────────────────────────
  {
    VoxelGrid g = blank(12, 3, 6);
    std::vector<DirichletBC> bcs;
    DesignMask frozen(g.voxel_count(), MaskValue::Active);
    for (int k = 0; k < 6; ++k)
      for (int j = 0; j < 3; ++j)
        for (int i = 0; i < 12; ++i) {
          if (!(i < 4 || i >= 8)) continue;
          g.set_tag(i, j, k, k == 0 ? VoxelTag::Fixture : k == 5 ? VoxelTag::Load
                                                               : VoxelTag::Interior);
          frozen[g.index(i, j, k)] = MaskValue::FrozenSolid;
          if (k == 0) clamp_voxel_nodes(g, i, j, k, bcs);
        }
    const MinimizePlasticResult on = run(g, bcs, frozen, true, rules);
    std::printf("[42] drawn as two: %d carrying bodies, %d bridge(s)\n", carrying_bodies(on),
                on.evaluated.front().report.bridges);
    CHECK(carrying_bodies(on) == 2 && on.evaluated.front().report.bridges == 0,
          "(c) a part drawn as two bodies is not bridged");
  }

  // ── (d)-(f) the bridge holds itself ─────────────────────────────────────────
  {
    VoxelGrid g = blank(14, 5, 6);
    std::vector<DirichletBC> bcs;
    DesignMask frozen(g.voxel_count(), MaskValue::Active);
    for (int k = 0; k < 6; ++k)
      for (int j = 0; j < 5; ++j)
        for (int i = 0; i < 14; ++i) {
          const bool a = i < 4, b = i >= 10;
          g.set_tag(i, j, k, VoxelTag::Interior);
          if (!a && !b) continue;
          frozen[g.index(i, j, k)] = MaskValue::FrozenSolid;
          if (k == 0) {
            g.set_tag(i, j, k, VoxelTag::Fixture);
            clamp_voxel_nodes(g, i, j, k, bcs);
          }
          if (a && k == 5) g.set_tag(i, j, k, VoxelTag::Load);
        }
    auto line = [](const char* what, const MinimizePlasticResult& r) {
      const VariantReport& v = r.evaluated.front().report;
      std::printf("[42] %s: %s%s%s, %d bridge(s)", what,
                  r.evaluated.front().accepted ? "accepted" : "rejected",
                  v.rejection_reason.empty() ? "" : " - ", v.rejection_reason.c_str(),
                  v.bridges);
      for (const BridgeHoldReport& h : v.bridge_holds)
        std::printf("; %.1f mm, hold margin %.2f, %d thickening(s), %s", h.size_mm,
                    h.hold_margin, h.thickenings, h.held ? "held" : "LIFTED");
      std::printf("\n");
    };

    const MinimizePlasticResult held = run(g, bcs, frozen, true, rules, Vec3{0.0, 0.0, -1500.0});
    line("hold (d)", held);
    const VariantReport& hd = held.evaluated.front().report;
    CHECK(hd.bridges >= 1 && hd.bridge_holds.size() == static_cast<std::size_t>(hd.bridges),
          "(d) one hold receipt per bridge");
    bool thick = !hd.bridge_holds.empty();
    for (const BridgeHoldReport& h : hd.bridge_holds)
      thick = thick && h.held && h.thickenings >= 1 && h.thickenings <= 3 &&
              h.hold_margin >= 1.5 && h.size_mm > 3.0 * 2.0;
    CHECK(thick, "(d) the thin bridge is thickened until its own margin clears margin_stop");
    CHECK(held.evaluated.front().accepted && carrying_bodies(held) == 1,
          "(d) one piece, accepted");

    const MinimizePlasticResult lifted =
        run(g, bcs, frozen, true, rules, Vec3{0.0, 0.0, -40000.0});
    line("hold (e)", lifted);
    const VariantReport& lf = lifted.evaluated.front().report;
    bool gone = !lf.bridge_holds.empty();
    for (const BridgeHoldReport& h : lf.bridge_holds)
      gone = gone && !h.held && h.thickenings == 3 && h.hold_margin < 1.5;
    CHECK(gone, "(e) a bridge three layers cannot make hold is lifted, and said so");
    CHECK(!lifted.evaluated.front().accepted && lf.rejection_reason == kAnchorDetachedReason,
          "(e) the piece it held is let go and item 47 rejects the rung");

    const MinimizePlasticResult walls =
        run(g, bcs, frozen, true, rules, Vec3{0.0, 0.0, -2.0}, 5, 0.8);
    line("hold (f)", walls);
    const VariantReport& wl = walls.evaluated.front().report;
    CHECK(!wl.bridge_holds.empty() && wl.bridge_holds.front().size_mm >= 8.0 &&
              wl.bridge_holds.front().thickenings == 0 && wl.bridge_holds.front().held,
          "(f) with walls the bridge starts at 2 x 5 loops x 0.8 mm = 8 mm");
  }

  if (g_failures == 0) {
    std::printf("bridge (item 42 B): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "bridge (item 42 B): %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
