#include "topopt/loadcase.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <set>
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
  for (int fid : lc.anchor_face_ids)
    tag_step_face(grid, model, fid, VoxelTag::Fixture);
  const VoxelGrid base_grid = grid;

  std::vector<NodalLoad> external;
  // The load faces actually retained on the main grid (the non-zero groups),
  // collected so their structural pad is frozen alongside the anchors' below.
  std::vector<int> retained_load_faces;
  for (std::size_t gi = 0; gi < lc.load_groups.size(); ++gi) {
    const ProductionLoadCase::LoadGroup& group = lc.load_groups[gi];
    const Vec3 force = group.force;
    const double force_mag =
        std::sqrt(force.x * force.x + force.y * force.y + force.z * force.z);
    if (!(std::fabs(force.x) + std::fabs(force.y) + std::fabs(force.z) > 0.0)) {
      // A zero-force group contributes nothing (the user left it unset / the
      // force was lost upstream). Log why, then skip.
      log_load_group(gi, group.face_ids.size(), force_mag, 0, "zero-force");
      continue;
    }
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
  if (lc.minimize_plastic) {
    DesignMask pad = make_active_mask(grid);
    for (int fid : lc.anchor_face_ids)
      mask_step_face(grid, model, fid, MaskValue::FrozenSolid,
                     kProductionAnchorPadDepthVoxels, pad);
    for (int fid : retained_load_faces)
      mask_step_face(grid, model, fid, MaskValue::FrozenSolid,
                     kProductionAnchorPadDepthVoxels, pad);
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

  // The grid the run will actually solve on (the expanded domain when a design
  // box is set), computed WITHOUT running the solve — the SAME expand_design_domain
  // the driver runs, so the two never disagree. Needed up front to index a
  // progressive-variant stream a front-end registers before minimize_plastic
  // returns.
  setup.solved_grid = minimize_plastic_solved_grid(grid, opts);
  return setup;
}

}  // namespace topopt
