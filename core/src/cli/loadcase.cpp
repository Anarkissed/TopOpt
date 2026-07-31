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

#include "topopt/production.hpp"  // configure_production_options, production_reduction_ladder

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
  // gravity_direction defines the reported build orientation = its unit negation.
  opts.gravity_direction = Vec3{-build_dir.x, -build_dir.y, -build_dir.z};
  opts.gravity = 9810.0 * 1e-9;  // self-weight magnitude, used only if external empty
  opts.volume_fraction_ladder =
      lc.minimize_plastic ? production_reduction_ladder() : std::vector<double>{0.9};

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
  // The pad is minimize_plastic-only (the {0.9} conservative variant keeps material
  // anyway); a Face protection is the user's explicit request and is honored in
  // BOTH modes. Built whenever there is something to freeze; with neither declared
  // the overlay stays empty and the run is byte-identical (THE ONE RULE).
  const bool want_pad = lc.minimize_plastic;
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
    const VoxelGrid& solved = setup.solved_grid;
    const double s = solved.spacing;
    const int oi = static_cast<int>(std::lround((grid.origin.x - solved.origin.x) / s));
    const int oj = static_cast<int>(std::lround((grid.origin.y - solved.origin.y) / s));
    const int ok = static_cast<int>(std::lround((grid.origin.z - solved.origin.z) / s));
    DesignMask clearance(solved.voxel_count(), MaskValue::Active);
    setup.clearance_reports.reserve(lc.clearances.size());
    for (const ProductionLoadCase::Clearance& c : lc.clearances) {
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
          rasterize_clearance(solved, grid, oi, oj, ok, geom, clearance);
      setup.clearance_reports.push_back(
          {c.face_id, c.params.kind, rr.voxels_frozen, rr.region_in_grid});
      log_clearance(c.face_id, c.params.kind, rr.voxels_frozen, rr.region_in_grid);
    }
    opts.clearance_void = std::move(clearance);  // opts aliases setup.options
  }

  return setup;
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
