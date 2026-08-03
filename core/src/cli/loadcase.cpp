#include "topopt/loadcase.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "topopt/observability.hpp"  // steady_clock_ms (the counterfactual cost)
#include "topopt/production.hpp"  // configure_production_options, production_reduction_ladder
#include "topopt/simp.hpp"        // effective_design_mask (the pre-flight allowed set)

namespace topopt {

namespace {

// The process-global per-load-group log sink (loadcase.hpp). Defaults to one line
// on stderr; a front-end can reroute it (e.g. os_log) and a test can capture it.
LoadcaseLogFn& loadcase_sink() {
  static LoadcaseLogFn sink = [](const std::string& line) {
    std::fprintf(stderr, "%s\n", line.c_str());
  };
  return sink;
}

// Emit one per-group diagnostic line. `status` is "ok", "zero-force", or
// "zero-tagged"; a skipped group is flagged so it stands out in the log.
void log_load_group(std::size_t index, std::size_t face_count, double force_mag,
                    std::size_t voxels_tagged, const char* status) {
  const LoadcaseLogFn& sink = loadcase_sink();
  if (!sink) return;
  const bool skipped =
      std::string(status) == "zero-force" || std::string(status) == "zero-tagged";
  char buf[256];
  std::snprintf(buf, sizeof(buf),
                "[loadcase] load-group %zu: faces=%zu |F|=%.3gN voxels_tagged=%zu %s=%s",
                index, face_count, force_mag, voxels_tagged,
                skipped ? "SKIP" : "status", status);
  sink(std::string(buf));
}

// Emit one clearance diagnostic line (handoff 100) through the same sink: the
// face, its kind, how many voxels it forbade, and — the honest bit — whether the
// region reached the solved grid at all. An out-of-grid region is flagged SKIP so
// a front-end (and the device/CLI log) surfaces the silent no-op instead of
// pretending the clearance took effect.
void log_clearance(int face_id, ClearanceKind kind, std::size_t voxels_frozen,
                   bool in_grid) {
  const LoadcaseLogFn& sink = loadcase_sink();
  if (!sink) return;
  char buf[256];
  std::snprintf(buf, sizeof(buf),
                "[loadcase] clearance face=%d kind=%s voxels_frozen=%zu %s",
                face_id, kind == ClearanceKind::Bolt ? "bolt" : "face",
                voxels_frozen,
                in_grid ? "status=ok" : "SKIP=region-outside-grid");
  sink(std::string(buf));
}

// Emit one Face-protection diagnostic line (handoff 124) through the same sink:
// the face, how many part voxels it froze FrozenSolid, the depth (voxels) used,
// and — the honest edge — whether the face's own solid was thinner than that
// depth (so it froze what exists, no silent over-claim). A protection that tags no
// solid voxels is flagged SKIP so the log surfaces the no-op rather than hiding it.
void log_face_protection(int face_id, std::size_t voxels_frozen, int depth_voxels,
                         bool thinner_than_depth) {
  const LoadcaseLogFn& sink = loadcase_sink();
  if (!sink) return;
  char buf[256];
  std::snprintf(buf, sizeof(buf),
                "[loadcase] face-protection face=%d voxels_frozen=%zu depth=%d %s%s",
                face_id, voxels_frozen, depth_voxels,
                voxels_frozen == 0 ? "SKIP=no-solid-tagged" : "status=ok",
                thinner_than_depth ? " thinner-than-depth" : "");
  sink(std::string(buf));
}

// Echo the warm-start decision through the same per-group sink (handoff 114), so
// a device / CLI log confirms which start the shared builder chose and that BOTH
// front-ends inherited it here — no separate wiring. `inherit` is the flip's
// result; `self_weight` (external loads empty) names the mode the gate saw.
void log_warm_start_config(bool inherit, bool self_weight) {
  const LoadcaseLogFn& sink = loadcase_sink();
  if (!sink) return;
  char buf[128];
  std::snprintf(buf, sizeof(buf),
                "[loadcase] warm_start_inherit=%d mode=%s",
                inherit ? 1 : 0, self_weight ? "self-weight" : "load-case");
  sink(std::string(buf));
}

// Task analyze-loadcase-resolution (N5) — validate a face id at the point it is
// RESOLVED, with a message that names the id, the count available and the valid
// range. `context` names where the id came from ("load case anchor",
// "load group 2"), so the user knows which selection to fix. Before this, an
// out-of-range id surfaced as tag_step_face's bare "face_id out of range" —
// loud, but naming nothing the user could act on. A model that carries NO face
// ids at all (an exported variant mesh, or a model whose face-overrides sidecar
// was not found next to it) is called out as such: no selection can ever
// resolve against it, which is a different problem than one bad id.
void validate_face_id(int fid, const StepModel& model,
                      const std::string& context) {
  if (fid >= 0 && fid < model.face_count) return;
  if (model.face_count <= 0)
    throw std::invalid_argument(
        context + " face id " + std::to_string(fid) +
        " cannot be resolved — this model carries no face ids at all (an "
        "exported variant mesh, or a model whose face-overrides sidecar was "
        "not found). The load case was authored on a different model or "
        "import than the one being analyzed.");
  throw std::invalid_argument(
      context + " face id " + std::to_string(fid) +
      " is out of range — the model carries " +
      std::to_string(model.face_count) + " faces (valid ids 0.." +
      std::to_string(model.face_count - 1) +
      "). The load case appears to have been authored on a different model "
      "or import than the one being analyzed.");
}

// Task 2026-08-03-growth-ladder — announce the AUTO-DERIVED growth box through the
// same sink. A box the user did not draw must be visible in the run log as well as
// on the setup: this is a domain the optimizer may fill, and "where did that
// material come from" must never need archaeology to answer.
void log_growth_box(const DesignBox& b, double spacing) {
  const LoadcaseLogFn& sink = loadcase_sink();
  if (!sink) return;
  char buf[256];
  std::snprintf(buf, sizeof(buf),
                "[loadcase] growth design box AUTO-DERIVED (none drawn): "
                "min=(%.3g,%.3g,%.3g) max=(%.3g,%.3g,%.3g) mm spacing=%.4g",
                b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z, spacing);
  sink(std::string(buf));
}

// Task 2026-08-03-growth-ladder — name the mode the run is in, in one line, on
// every load-case run. "minimize plastic" unticked used to change BOTH the ladder
// and the anchor pad with nothing in the log saying either; both facts are stated
// here now, beside the rungs they govern.
void log_ladder_mode(bool growth, const std::vector<double>& ladder, bool pad) {
  const LoadcaseLogFn& sink = loadcase_sink();
  if (!sink) return;
  std::string rungs;
  for (double v : ladder) {
    char r[32];
    std::snprintf(r, sizeof(r), "%.2f", v);
    rungs += (rungs.empty() ? "" : ",") + std::string(r);
  }
  sink(std::string("[loadcase] ladder=") + (growth ? "GROWTH" : "REDUCTION") +
       " rungs=[" + rungs + "] anchor_pad=" + (pad ? "1" : "0") + " — " +
       (growth ? "add as little plastic as possible to reach the required margin"
               : "remove as much plastic as possible while holding the required "
                 "margin"));
}

// Count the voxels currently carrying `tag` in `grid`.
std::size_t count_tagged(const VoxelGrid& grid, VoxelTag tag) {
  std::size_t n = 0;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i)
        if (grid.tag(i, j, k) == tag) ++n;
  return n;
}

}  // namespace

LoadcaseLogFn set_loadcase_log_sink(LoadcaseLogFn sink) {
  LoadcaseLogFn prev = loadcase_sink();
  loadcase_sink() = std::move(sink);
  return prev;
}

ProductionRunSetup build_production_loadcase(const StepModel& model,
                                             int resolution,
                                             const ProductionLoadCase& lc) {
  ProductionRunSetup setup;
  VoxelGrid& grid = setup.grid;
  grid = voxelize(model.mesh, resolution);

  // Anchors -> Fixture (clamped + retained). Snapshot the anchors-only grid as
  // the clean base for per-group traction, so each group's traction covers ONLY
  // its own faces (traction_loads spreads a force over every Load voxel it sees).
  // Ids are validated here, at the point of resolution, so an out-of-range id
  // fails naming the id / the count / which selection it came from (N5) — the
  // same condition tag_step_face would have thrown on, made legible.
  for (int fid : lc.anchor_face_ids)
    validate_face_id(fid, model, "load case anchor");
  for (int fid : lc.anchor_face_ids)
    tag_step_face(grid, model, fid, VoxelTag::Fixture);
  const VoxelGrid base_grid = grid;

  std::vector<NodalLoad> external;
  // The load faces actually retained on the main grid (the non-zero groups),
  // collected so their structural pad is frozen alongside the anchors' below.
  std::vector<int> retained_load_faces;
  setup.load_group_reports.reserve(lc.load_groups.size());
  for (std::size_t gi = 0; gi < lc.load_groups.size(); ++gi) {
    const ProductionLoadCase::LoadGroup& group = lc.load_groups[gi];
    const Vec3 force = group.force;
    const double force_mag =
        std::sqrt(force.x * force.x + force.y * force.y + force.z * force.z);
    if (!(std::fabs(force.x) + std::fabs(force.y) + std::fabs(force.z) > 0.0)) {
      // A zero-force group contributes nothing (the user left it unset / the
      // force was lost upstream). Log why, then skip — BEFORE resolving its
      // face ids, exactly as before the resolution task (a dead group's ids
      // are never validated, so pre-task jobs keep their behavior).
      log_load_group(gi, group.face_ids.size(), force_mag, 0, "zero-force");
      setup.load_group_reports.push_back(
          {gi, group.face_ids, force_mag, 0,
           LoadGroupReport::Status::ZeroForce});
      continue;
    }
    // Resolution point (N5): validate this live group's ids legibly — the same
    // condition tag_step_face would throw on, now naming the group and the id.
    for (int fid : group.face_ids)
      validate_face_id(fid, model, "load group " + std::to_string(gi));
    VoxelGrid gg = base_grid;  // anchors only, no other group's Load
    for (int fid : group.face_ids)
      tag_step_face(gg, model, fid, VoxelTag::Load);
    const std::size_t tagged = count_tagged(gg, VoxelTag::Load);
    if (tagged == 0) {
      // The group's faces tagged NO solid voxels — a face smaller than a voxel
      // footprint at this resolution (handoff 099). Its traction can't be built,
      // so it contributes nothing and `external` stays empty for this group. Log
      // the reason (this is what the require_external_loads guard then refuses on).
      log_load_group(gi, group.face_ids.size(), force_mag, 0, "zero-tagged");
      setup.load_group_reports.push_back(
          {gi, group.face_ids, force_mag, 0,
           LoadGroupReport::Status::ZeroTagged});
      continue;
    }
    const std::vector<NodalLoad> tl = traction_loads(gg, VoxelTag::Load, force);
    external.insert(external.end(), tl.begin(), tl.end());
    // Retain the load faces on the MAIN grid (Load voxels are implicitly
    // FrozenSolid, so the surface the traction sits on is never optimized away).
    for (int fid : group.face_ids) {
      tag_step_face(grid, model, fid, VoxelTag::Load);
      retained_load_faces.push_back(fid);
    }
    log_load_group(gi, group.face_ids.size(), force_mag, tagged, "ok");
    setup.load_group_reports.push_back(
        {gi, group.face_ids, force_mag, tagged, LoadGroupReport::Status::Ok});
  }

  // Dirichlet BCs from the Fixture voxels (clamp all 8 corner nodes, deduped).
  std::vector<DirichletBC>& bcs = setup.bcs;
  std::set<int> clamped;
  auto clamp_node = [&](int n) {
    if (clamped.insert(n).second) {
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  };
  bool any_fixture = false;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i)
        if (grid.tag(i, j, k) == VoxelTag::Fixture) {
          any_fixture = true;
          for (int dk = 0; dk <= 1; ++dk)
            for (int dj = 0; dj <= 1; ++dj)
              for (int di = 0; di <= 1; ++di)
                clamp_node(fea_node_index(grid, i + di, j + dj, k + dk));
        }
  if (!any_fixture) {
    // No anchors declared: fall back to clamping the min-x boundary so the
    // system is well-posed (mirrors the self-weight path).
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        if (grid.solid(0, j, k)) grid.set_tag(0, j, k, VoxelTag::Fixture);
    for (int c = 0; c <= grid.nz; ++c)
      for (int b = 0; b <= grid.ny; ++b)
        clamp_node(fea_node_index(grid, 0, b, c));
  }

  // Build direction (orientation for the interlayer margin); default +Z.
  Vec3 build_dir = lc.build_dir;
  if (!(std::fabs(build_dir.x) + std::fabs(build_dir.y) +
            std::fabs(build_dir.z) >
        0.0))
    build_dir = Vec3{0.0, 0.0, 1.0};

  MinimizePlasticOptions& opts = setup.options;
  // Shared production solver config (matrix-free multigrid + Galerkin cache +
  // physical min-feature + projection): the SAME call the app makes.
  configure_production_options(opts);
  opts.external_loads = external;  // the user's load case; empty => self-weight

  // Warm-start production flip — LOAD-CASE MODE ONLY (handoff 114; evidence:
  // handoff 113's ~64-scale warm-gate table). With inheritance on, each ladder
  // rung seeds from its predecessor's converged design instead of uniform grey.
  // 113 measured this on both modes at production scale:
  //   * LOAD-CASE: ~20% fewer iters, terminal |Δρ|=0.0227, margins comparable
  //     (warmA 15.03 vs cold 15.31) — a small, measured design change the
  //     maintainer signs off on. ADOPTED here.
  //   * SELF-WEIGHT: the SAME ~20% savings but |Δρ|=0.284 — a materially
  //     different optimum (086: a non-convex MMA lands on another valid
  //     plateau). Explicitly NOT flipped; self-weight stays COLD and its output
  //     is byte-identical to today. Revisitable by a future measured decision.
  // The gate is "does this run actually carry external loads?" — i.e. the run IS
  // the load-case mode. `external` empty => self-weight, so a builder-driven
  // self-weight run (no load groups declared) is covered by the same predicate
  // and keeps the cold start. This is the ONE conditional the flip needs; the
  // app (TopOptBridge) and topopt-cli both build load cases through here, so both
  // inherit it with no per-front-end wiring. Their direct self-weight paths call
  // configure_production_options() without the builder and never see it (cold).
  opts.warm_start_inherit = !external.empty();
  log_warm_start_config(opts.warm_start_inherit, external.empty());
  // Diagnosis (3D-block fragmentation): the silent-self-weight-fall-through
  // guard, relocated here from bridge.cpp during the PR-119 reconcile — this is
  // the ONE builder both the app and topopt-cli call, so both front-ends get it.
  // When the user declared load groups but every group was zero-force / tagged
  // no voxels / was lost upstream, `external` is empty and the run would
  // silently optimize under self-weight — stripping the unfrozen tab and
  // fragmenting the design. Surface it as a clear error instead. A load case
  // with NO groups declared keeps self-weight as a legitimate mode.
  opts.require_external_loads = !lc.load_groups.empty();
  // The service gravity a load case implies: opposite the declared build
  // direction. (Historically this was the ONLY plumbing — the build direction
  // round-tripped through gravity and every certification path inferred it back
  // out, which is the conflation handoff 2026-08-01-build-direction-separation
  // measured. Kept exactly as-is so self-weight inside a load case is unchanged.)
  opts.gravity_direction = Vec3{-build_dir.x, -build_dir.y, -build_dir.z};
  // ...and, since a load case DID declare a plate orientation, carry it as the
  // build direction DIRECTLY rather than making resolve_build_direction infer it
  // back from gravity. Numerically identical (the round trip is exact — that is
  // why this stays byte-identical), but honest: this run's orientation is a
  // stated input, not a guess, and the receipt can say so. Only a DECLARED
  // direction is forwarded; lc.build_dir == (0,0,0) means "not declared" (the
  // +Z default above), which is left for the documented gravity fallback.
  if (std::fabs(lc.build_dir.x) + std::fabs(lc.build_dir.y) +
          std::fabs(lc.build_dir.z) >
      0.0)
    opts.build_direction = build_dir;
  // ...and a DECLARED plate normal overrides that: this is the front-end saying
  // the two questions have different answers for this part. Zero declares
  // nothing and leaves the line above (or the gravity fallback) in charge.
  if (std::fabs(lc.plate_dir.x) + std::fabs(lc.plate_dir.y) +
          std::fabs(lc.plate_dir.z) >
      0.0)
    opts.build_direction = lc.plate_dir;
  opts.build_orientation_report = lc.build_orientation_report;
  opts.gravity = 9810.0 * 1e-9;  // self-weight magnitude, used only if external empty
  // ── THE TWO LADDERS (task 2026-08-03-growth-ladder) ───────────────────────
  // ONE line each, and they are the only two things this checkbox now means:
  //
  //   minimize_plastic ON  — REDUCE: walk [0.68, 0.52, 0.38, 0.26] of the part's
  //       volume and recommend the LIGHTEST variant that still clears the margin.
  //   minimize_plastic OFF — GROW: walk [1.55, 1.25, 1.10] of the part's volume
  //       and recommend the SMALLEST ADDITION that clears the margin.
  //
  // OFF used to be `{0.9}` — one conservative variant, no search, and the code's
  // own comment said so. That answered a question nobody asked: a user who unticks
  // "minimize plastic" is not asking for 90% of their part, they are saying "you
  // may grow MORE plastic to reach the strength I want — as little as possible".
  // The growth ladder is that, and it is the SAME walk in the SAME direction, so
  // "recommend the last accepted rung" already means "the smallest addition that
  // passes" (see production.hpp for the rung derivation and minimize_plastic.cpp
  // for the growth rules). The ON path is untouched, to the byte.
  const bool growth = !lc.minimize_plastic;
  opts.volume_fraction_ladder =
      growth ? production_growth_ladder() : production_reduction_ladder();
  setup.growth_ladder = growth;

  // M7.anchor-integrity (FIX 1): freeze an N-voxel structural PAD behind every
  // anchor and (retained) load face, not just the 1-voxel BC skin tag_step_face
  // produces, so the boss is tied into the body and the optimizer routes load
  // through it (diagnosis 064). Built on BOTH the no-box and design-box path
  // (handoff 082: the whole-domain box default makes the import removable, so the
  // pad is needed there too). Only the reduction-ladder path pads; the single
  // conservative variant is left untouched.
  //
  // Handoff 124 — Face protections share this ONE PART-grid FrozenSolid overlay:
  // both the anchor/load pad and a protected face's preserved skin are keep-in
  // (FrozenSolid) regions mask_step_face writes, and minimize_plastic merges the
  // overlay into the effective mask (design-box path) or uses it directly (no-box).
  // A Face protection is the user's explicit request and is honored in BOTH modes.
  //
  // Since this task the PAD is built in both modes too, so `want_pad` is in fact
  // always true and the overlay is always built. It is kept as an expression, not
  // folded to a constant, because it NAMES the decision (kGrowthPathAnchorPad) and
  // is where a future reversal would land. The ON path is unaffected either way —
  // it already padded unconditionally.
  //
  // ── THE PAD ON THE GROWTH PATH — DECIDED, AND MEASURED (task
  // 2026-08-03-growth-ladder). The pad used to be `lc.minimize_plastic` exactly,
  // on the reasoning that "the {0.9} conservative variant keeps material anyway".
  // That reasoning was a hidden side effect of a checkbox that reads as an
  // OBJECTIVE toggle, and it was at its weakest precisely here: a growth run is by
  // definition a run whose structure is UNDER-strength, the anchors most of all,
  // and "0.9 of the part keeps material anyway" says nothing about 1.55 of a part
  // inside a design box several times its volume — where the optimizer is free to
  // spend its budget in the box and carve the boss it grew away from.
  //
  // It is not argued here, it is MEASURED: the same growth ladder was run with the
  // pad and without, and the difference is in
  // evidence/2026-08-03-growth-ladder/pad_on_off.txt (and §"G5" of the handoff).
  // kGrowthPathAnchorPad records the decision that measurement produced, so the
  // pad's coupling to the mode is now an explicit, priced choice with a name —
  // never again an inherited side effect.
  const bool want_pad = lc.minimize_plastic || (growth && kGrowthPathAnchorPad);
  setup.growth_anchor_pad = growth && want_pad;
  log_ladder_mode(growth, opts.volume_fraction_ladder, want_pad);
  const bool want_protect = !lc.face_protection_face_ids.empty();
  if (want_pad || want_protect) {
    DesignMask pad = make_active_mask(grid);
    if (want_pad) {
      for (int fid : lc.anchor_face_ids)
        mask_step_face(grid, model, fid, MaskValue::FrozenSolid,
                       kProductionAnchorPadDepthVoxels, pad);
      for (int fid : retained_load_faces)
        mask_step_face(grid, model, fid, MaskValue::FrozenSolid,
                       kProductionAnchorPadDepthVoxels, pad);
    }
    if (want_protect) {
      // ONE global depth (mm) → voxel layers on THIS run's grid; floored at 1 so a
      // protection always freezes a real skin. mask_step_face walks part-SOLID
      // layers, so this NEVER frees void — it only pins existing part material.
      const int depth_vox = std::max(
          1, static_cast<int>(std::lround(lc.face_protection_depth_mm / grid.spacing)));
      setup.face_protection_reports.reserve(lc.face_protection_face_ids.size());
      for (int fid : lc.face_protection_face_ids) {
        if (fid < 0 || fid >= model.face_count) continue;
        // Freeze this face's skin into a PER-FACE mask so the report counts THIS
        // face's frozen voxels (not ones an anchor pad or an earlier protection
        // already froze — both are the same FrozenSolid value). Freeze once more a
        // layer deeper: an equal count means the face's own solid was fully
        // consumed at `depth_vox` (thinner than / equal to the requested depth) —
        // the honest "freezes what exists and SAYS so" signal, no silent over-claim.
        DesignMask one = make_active_mask(grid);
        const std::size_t frozen = mask_step_face(
            grid, model, fid, MaskValue::FrozenSolid, depth_vox, one);
        DesignMask deeper = make_active_mask(grid);
        const std::size_t frozen_deeper = mask_step_face(
            grid, model, fid, MaskValue::FrozenSolid, depth_vox + 1, deeper);
        for (std::size_t idx = 0; idx < pad.size(); ++idx)
          if (one[idx] == MaskValue::FrozenSolid) pad[idx] = MaskValue::FrozenSolid;
        const bool thin = frozen_deeper == frozen;
        setup.face_protection_reports.push_back({fid, frozen, depth_vox, thin});
        log_face_protection(fid, frozen, depth_vox, thin);
      }
    }
    opts.design_mask = std::move(pad);
  }

  // Design-domain expansion: grow material into the box beyond the frozen import
  // (dom-core expand_design_domain). Model space matches the voxel/mesh frame.
  // Unset → byte-identical to the no-box path.
  if (lc.has_design_box) {
    opts.design_box = lc.design_box;
    opts.keep_out_boxes = lc.keep_out_boxes;
  } else if (growth) {
    // ── GROWTH NEEDS SOMEWHERE TO GO, AND WE SAY SO (task
    // 2026-08-03-growth-ladder). A growth ladder with no design box can only
    // REDISTRIBUTE the part's own material: the ladder target would degenerate to
    // simp's fraction of the part itself, the run would print at most the part,
    // and the receipt would announce growth that never happened. minimize_plastic
    // refuses that outright.
    //
    // The front-ends must not simply inherit the refusal, though: unticking a
    // checkbox is not a promise to also draw a box, and a user who never opened
    // the design-box tool would meet a hard error where the feature is supposed to
    // help. So a MINIMAL box is derived here — the part's own bounding box
    // inflated by the smallest whole number of voxels that can hold the TOP rung's
    // ask with routing headroom (production.hpp, minimal_growth_design_box) — and
    // the derivation is RECORDED on the setup and logged. Auto-derived is a
    // reportable fact, never a silent one: the receipt says the box was derived
    // and states its extents, so nobody mistakes it for a box they drew.
    setup.growth_box_auto_derived = true;
    setup.growth_box = minimal_growth_design_box(
        grid, opts.volume_fraction_ladder.front(), kGrowthBoxHeadroom);
    opts.design_box = setup.growth_box;
    log_growth_box(setup.growth_box, grid.spacing);
  }

  // Infill override: only forward an actual override (>= 0); a negative value
  // leaves the core default (100 = solid, knockdown 1.0) untouched.
  if (lc.infill_percent >= 0.0) opts.infill_percent = lc.infill_percent;

  // Width-aware knockdown slicer metadata (handoff 2026-07-26-width-aware-knockdown):
  // forward the wall geometry so the accept gate can size the solid wall ring when
  // armed. wall_loops always carries (0 = none); a negative line width leaves the
  // core default. The width-aware gate itself is armed by configure_production_options
  // (kProductionWidthAwareKnockdown), not here — this only supplies its inputs.
  opts.wall_loops = lc.wall_loops;
  if (lc.wall_line_width_mm > 0.0) opts.wall_line_width_mm = lc.wall_line_width_mm;
  // Only forward a real outer-width override (> 0); a negative value leaves the
  // MinimizePlasticOptions default (< 0 → mirror inner), so a caller that supplies one
  // line width still sizes the ring at loops·inner, byte-identical to before.
  if (lc.wall_line_width_outer_mm > 0.0)
    opts.wall_line_width_outer_mm = lc.wall_line_width_outer_mm;

  // The grid the run will actually solve on (the expanded domain when a design
  // box is set), computed WITHOUT running the solve — the SAME expand_design_domain
  // the driver runs, so the two never disagree. Needed up front to index a
  // progressive-variant stream a front-end registers before minimize_plastic
  // returns.
  setup.solved_grid = minimize_plastic_solved_grid(grid, opts);

  // Handoff 100 — rasterize the declared "Keep clear" clearances onto the SOLVED
  // grid as a FrozenVoid overlay (mask_clearance_region), which minimize_plastic
  // ORs into the effective mask (FrozenSolid/part wins). The part sits inside the
  // solved grid at a whole-voxel offset — 0 on the no-box path (solved == part),
  // (part.origin − solved.origin)/spacing on the design-box path (only the high
  // side of the expanded grid grows, so this offset is exact; see voxel.hpp). The
  // rasterizer's precedence guard needs that offset to protect part material. No
  // clearance → the overlay stays empty and the run is byte-identical.
  if (!lc.clearances.empty()) {
    opts.clearance_void =
        build_clearance_overlay(model, grid, setup.solved_grid, lc.clearances,
                                -1, &setup.clearance_reports);
    for (const ProductionRunSetup::ClearanceReport& r : setup.clearance_reports)
      log_clearance(r.face_id, r.kind, r.voxels_frozen, r.in_grid);
  }

  return setup;
}

DesignMask build_clearance_overlay(
    const StepModel& model, const VoxelGrid& part_grid,
    const VoxelGrid& solved_grid,
    const std::vector<ProductionLoadCase::Clearance>& clearances,
    int skip_index,
    std::vector<ProductionRunSetup::ClearanceReport>* reports) {
  // The part sits inside the solved grid at a whole-voxel offset — 0 on the
  // no-box path (solved == part), (part.origin − solved.origin)/spacing on the
  // design-box path (only the HIGH side of the expanded grid grows, so this
  // offset is exact; see voxel.hpp). The rasterizer's precedence guard needs
  // that offset to protect part material.
  const double s = solved_grid.spacing;
  const int oi =
      static_cast<int>(std::lround((part_grid.origin.x - solved_grid.origin.x) / s));
  const int oj =
      static_cast<int>(std::lround((part_grid.origin.y - solved_grid.origin.y) / s));
  const int ok =
      static_cast<int>(std::lround((part_grid.origin.z - solved_grid.origin.z) / s));
  DesignMask clearance(solved_grid.voxel_count(), MaskValue::Active);
  if (reports) reports->reserve(clearances.size());
  for (std::size_t ci = 0; ci < clearances.size(); ++ci) {
    if (static_cast<int>(ci) == skip_index) continue;  // the counterfactual
    const ProductionLoadCase::Clearance& c = clearances[ci];
    // An AUTO primitive is derived from model.faces[face_id] (skipped, exactly
    // as before, when the id is out of range). A MANUAL primitive carries its
    // own geometry (no B-rep face). Both resolve to the SAME predicate and take
    // the SAME rasterizer, so the mask is identical for identical geometry
    // (handoff group-editing, BAR B2).
    ClearanceGeometry geom;
    if (c.manual) {
      geom = resolve_clearance_manual(c.manual_geom, c.params);
    } else {
      if (c.face_id < 0 || c.face_id >= model.face_count) continue;
      geom = resolve_clearance_from_face(model, c.face_id, c.params);
    }
    const ClearanceRasterResult rr =
        rasterize_clearance(solved_grid, part_grid, oi, oj, ok, geom, clearance);
    if (reports)
      reports->push_back(
          {c.face_id, c.params.kind, rr.voxels_frozen, rr.region_in_grid});
  }
  return clearance;
}

// ---------------------------------------------------------------------------
// PRE-FLIGHT DIAGNOSIS (task 2026-08-03-preflight-feasibility-and-divergence,
// bar P2: "a refusal is actionable").
//
// The core check (pipeline.hpp preflight_load_path) answers YES / NO in
// milliseconds. This is everything a person needs to ACT on a NO, and every
// remedy it states has been MEASURED by re-running the same check on the
// modified job — never guessed (PR 276's verified-counterfactual rule).

namespace {

// One clearance's counterfactual: does the load path RECONNECT with this
// clearance removed, or with its axial clearance reduced?
struct ClearanceCounterfactual {
  int index = -1;
  bool removal_reconnects = false;
  // For a BOLT clearance whose removal reconnects: the largest whole millimetre
  // of axial_clearance_mm that still leaves the path connected (bisected on the
  // real rasterizer + the real belt), or -1 when even 0 mm does not reconnect
  // (the concentric margin alone severs it) / the kind has no such knob.
  double max_axial_clearance_mm = -1.0;
};

// Re-run the pre-flight with `clearances` overridden. Rebuilds ONLY the
// clearance overlay + the design-domain mask — no import, no voxelize, no solve
// — so each probe costs one rasterization and one flood fill.
PreflightLoadPath preflight_with_clearances(
    const StepModel& model, const VoxelGrid& part_grid,
    const SolvedDesignDomain& domain, const MinimizePlasticOptions& options,
    const std::vector<ProductionLoadCase::Clearance>& clearances,
    int skip_index) {
  MinimizePlasticOptions probe = options;
  probe.clearance_void = build_clearance_overlay(
      model, part_grid, domain.grid, clearances, skip_index, nullptr);
  return preflight_load_path(domain, probe);
}

// The largest whole-millimetre axial clearance on `ci` that keeps the path
// connected, by bisection over [0, requested]. Returns -1 when even 0 mm leaves
// it severed. Monotone by construction (a larger swept cylinder only ever
// forbids MORE voxels, so connectivity can only be lost as the value grows),
// which is what makes a bisection a valid search rather than a sample.
double max_connected_axial_clearance_mm(
    const StepModel& model, const VoxelGrid& part_grid,
    const SolvedDesignDomain& domain, const MinimizePlasticOptions& options,
    std::vector<ProductionLoadCase::Clearance> clearances, std::size_t ci) {
  const double requested = clearances[ci].params.axial_clearance_mm;
  auto connected_at = [&](double mm) {
    clearances[ci].params.axial_clearance_mm = mm;
    return preflight_with_clearances(model, part_grid, domain, options,
                                     clearances, -1)
        .walk.connected;
  };
  if (!connected_at(0.0)) return -1.0;
  double lo = 0.0, hi = std::max(1.0, std::ceil(requested));  // lo connects, hi does not
  while (hi - lo > 1.0) {
    const double mid = std::floor((lo + hi) / 2.0);
    if (connected_at(mid)) lo = mid; else hi = mid;
  }
  return lo;
}

// Compose the refusal. Names WHICH load groups lost their path, WHICH anchor
// faces were walked from, WHICH clearance is the verified cause, and — when the
// cause is a bolt clearance — the largest axial clearance that would work.
}  // namespace

std::string preflight_refusal_report(
    const StepModel& model, const VoxelGrid& part_grid,
    const SolvedDesignDomain& domain, const MinimizePlasticOptions& options,
    const ProductionLoadCase& lc, const PreflightLoadPath& pf,
    const std::vector<int>& anchor_face_ids) {
  std::vector<ClearanceCounterfactual> cfs_out;
  double probe_ms_out = 0.0;
  const LoadPathWalk& w = pf.walk;
  std::string m =
      "run: PRE-FLIGHT REFUSED this job before any solve — THE LOAD PATH IS "
      "SEVERED.\n";
  {
    char buf[640];
    std::snprintf(
        buf, sizeof(buf),
        "  %zu of %zu load-tagged voxels cannot be reached from any of the %zu "
        "anchor-tagged voxels, EVEN IF the optimizer filled every one of the "
        "%zu voxels it is allowed to fill (%zu voxels are forbidden: outside "
        "the design domain, or frozen void by a keep-clear / keep-out). No "
        "design this job can produce carries force from the load to the anchor, "
        "so no amount of solving will find one.\n",
        w.unreached_load_voxels, w.load_voxels, w.anchor_voxels,
        w.printed_voxels, pf.forbidden_voxels);
    m += buf;
  }
  // WHICH anchors, WHICH load groups. The grid tags do not carry the group, so
  // re-tag each group on a scratch grid (the identical tag_step_face call
  // build_production_loadcase makes) and intersect with the unreached set. This
  // runs ONLY on the refusal path.
  {
    m += "  anchor faces: [";
    for (std::size_t i = 0; i < anchor_face_ids.size(); ++i)
      m += (i ? ", " : "") + std::to_string(anchor_face_ids[i]);
    m += "]\n";
    // Recompute the reachable set once so each group can be tested against it.
    const DesignMask eff =
        effective_design_mask(domain.grid, design_domain_mask(domain, options));
    std::vector<double> allowed(domain.grid.voxel_count(), 0.0);
    for (std::size_t i = 0; i < eff.size(); ++i)
      if (eff[i] != MaskValue::FrozenVoid) allowed[i] = 1.0;
    for (std::size_t gi = 0; gi < lc.load_groups.size(); ++gi) {
      const ProductionLoadCase::LoadGroup& g = lc.load_groups[gi];
      // Tag ONLY this group on a copy of the part grid, then carry the tags onto
      // the solved grid at the domain offset, and walk. A group that keeps its
      // path while another loses it is exactly the fact a user needs.
      VoxelGrid probe_part = part_grid;
      for (std::size_t i = 0; i < probe_part.tags.size(); ++i)
        if (probe_part.tags[i] == VoxelTag::Load)
          probe_part.tags[i] = VoxelTag::Interior;
      bool ok_ids = true;
      for (const int fid : g.face_ids) {
        if (fid < 0 || fid >= model.face_count) { ok_ids = false; break; }
        tag_step_face(probe_part, model, fid, VoxelTag::Load);
      }
      if (!ok_ids) continue;
      VoxelGrid probe = domain.grid;
      for (std::size_t i = 0; i < probe.tags.size(); ++i)
        if (probe.tags[i] == VoxelTag::Load) probe.tags[i] = VoxelTag::Interior;
      for (int pk = 0; pk < part_grid.nz; ++pk)
        for (int pj = 0; pj < part_grid.ny; ++pj)
          for (int pi = 0; pi < part_grid.nx; ++pi)
            if (probe_part.tag(pi, pj, pk) == VoxelTag::Load)
              probe.set_tag(pi + domain.offset_i, pj + domain.offset_j,
                            pk + domain.offset_k, VoxelTag::Load);
      const LoadPathWalk gw = walk_load_path(probe, allowed, 0.5);
      char buf[320];
      std::snprintf(buf, sizeof(buf),
                    "  load group %zu (faces [", gi);
      std::string line = buf;
      for (std::size_t i = 0; i < g.face_ids.size(); ++i)
        line += (i ? ", " : "") + std::to_string(g.face_ids[i]);
      std::snprintf(buf, sizeof(buf),
                    "]): %zu of %zu of its load voxels unreachable — %s\n",
                    gw.unreached_load_voxels, gw.load_voxels,
                    gw.connected ? "this group STILL has a path"
                                 : "THIS GROUP HAS NO PATH");
      m += line + buf;
    }
  }

  // THE VERIFIED CAUSE. One re-check per declared clearance, with that
  // clearance omitted. A clearance whose removal RECONNECTS the path caused the
  // severance; anything else did not.
  const double t0 = steady_clock_ms();
  bool any_single = false;
  for (std::size_t ci = 0; ci < lc.clearances.size(); ++ci) {
    ClearanceCounterfactual cf;
    cf.index = static_cast<int>(ci);
    cf.removal_reconnects =
        preflight_with_clearances(model, part_grid, domain, options,
                                  lc.clearances, static_cast<int>(ci))
            .walk.connected;
    if (cf.removal_reconnects &&
        lc.clearances[ci].params.kind == ClearanceKind::Bolt)
      cf.max_axial_clearance_mm = max_connected_axial_clearance_mm(
          model, part_grid, domain, options, lc.clearances, ci);
    any_single = any_single || cf.removal_reconnects;
    cfs_out.push_back(cf);
  }
  for (const ClearanceCounterfactual& cf : cfs_out) {
    if (!cf.removal_reconnects) continue;
    const ProductionLoadCase::Clearance& c =
        lc.clearances[static_cast<std::size_t>(cf.index)];
    char buf[640];
    std::snprintf(
        buf, sizeof(buf),
        "  VERIFIED CAUSE: clearance #%d (%s, face %d, concentric_margin %.4g "
        "mm, axial_clearance %.4g mm) — with THAT ONE clearance removed the "
        "load path RECONNECTS (re-checked on the real rasterizer, not "
        "inferred).\n",
        cf.index, c.params.kind == ClearanceKind::Bolt ? "bolt" : "face",
        c.face_id, c.params.concentric_margin_mm, c.params.axial_clearance_mm);
    m += buf;
    if (c.params.kind == ClearanceKind::Bolt) {
      if (cf.max_axial_clearance_mm >= 0.0) {
        std::snprintf(
            buf, sizeof(buf),
            "  WHAT WOULD FIX IT: at this resolution the largest "
            "axial_clearance_mm on clearance #%d that still leaves a load path "
            "is %.0f mm (measured by bisecting the real check); you asked for "
            "%.4g mm. Reduce it to <= %.0f mm, or give the optimizer somewhere "
            "else to route through — widen the design_box on the axis the bore "
            "runs along, or move/enlarge the anchor faces so the path does not "
            "have to pass the bore.\n",
            cf.index, cf.max_axial_clearance_mm, c.params.axial_clearance_mm,
            cf.max_axial_clearance_mm);
      } else {
        std::snprintf(
            buf, sizeof(buf),
            "  WHAT WOULD FIX IT: NOT the axial clearance — clearance #%d "
            "severs the path even at axial_clearance_mm = 0 (measured), so the "
            "concentric margin %.4g mm on a bore of this radius is already wide "
            "enough to cut the part. Reduce concentric_margin_mm, or widen the "
            "design_box so material can route around the bore.\n",
            cf.index, c.params.concentric_margin_mm);
      }
      m += buf;
    }
  }
  if (!any_single && !lc.clearances.empty()) {
    // No single removal reconnects. Ask the only other question that separates
    // "the clearances did it, jointly" from "the clearances are innocent":
    // remove ALL of them (an empty clearance list => an all-Active overlay).
    const bool none_at_all =
        preflight_with_clearances(model, part_grid, domain, options, {}, -1)
            .walk.connected;
    m += none_at_all
             ? "  VERIFIED CAUSE: no SINGLE clearance is responsible — removing "
               "any one of them leaves the path severed, but removing ALL of "
               "them reconnects it (measured). They sever it together; reduce "
               "them jointly, or widen the design_box so material can route "
               "around all of them.\n"
             : "  VERIFIED: the clearances are NOT the cause — removing every "
               "one of them still leaves the path severed (measured). The load "
               "and anchor faces are not connectable inside this design domain: "
               "check the design_box covers the region between them, that the "
               "keep_out boxes do not cut across it, and that the anchor and "
               "load faces are on the same body.\n";
  }
  if (lc.clearances.empty())
    m += "  This job declares NO clearances, so the severance is the design "
         "domain itself: check that the design_box covers the region between "
         "the load and anchor faces, that no keep_out box cuts across it, and "
         "that the two faces are on the same body.\n";
  probe_ms_out = steady_clock_ms() - t0;
  {
    char buf[192];
    std::snprintf(buf, sizeof(buf),
                  "  (pre-flight %.2f ms; counterfactuals %.2f ms — against the "
                  "10 hours the solve would have spent proving the same thing.)",
                  pf.wall_ms, probe_ms_out);
    m += buf;
  }
  return m;
}


std::string no_external_load_message(const ProductionRunSetup& setup,
                                     int resolution) {
  std::string msg =
      "every declared load group contributed nothing at resolution " +
      std::to_string(resolution) + ": ";
  bool first = true;
  for (const LoadGroupReport& r : setup.load_group_reports) {
    if (!first) msg += "; ";
    first = false;
    msg += "group " + std::to_string(r.index) + " (";
    for (std::size_t i = 0; i < r.face_ids.size(); ++i)
      msg += (i ? ", face " : "face ") + std::to_string(r.face_ids[i]);
    {
      char amt[32];
      std::snprintf(amt, sizeof(amt), "%.3g", r.force_mag);
      msg += std::string(", |F|=") + amt + " N): ";
    }
    switch (r.status) {
      case LoadGroupReport::Status::ZeroForce:
        msg += "zero force — set a non-zero force on this load";
        break;
      case LoadGroupReport::Status::ZeroTagged:
        msg += "its faces tagged no voxels at resolution " +
               std::to_string(resolution) +
               " — each face is smaller than one voxel at this grid spacing; "
               "raise the resolution or select a larger face";
        break;
      case LoadGroupReport::Status::Ok:
        // Never expected when the external set is empty; state it honestly
        // rather than hiding a contradiction.
        msg += "ok (" + std::to_string(r.voxels_tagged) + " voxels tagged)";
        break;
    }
  }
  if (setup.load_group_reports.empty())
    msg += "no load groups were declared";
  return msg;
}

}  // namespace topopt
