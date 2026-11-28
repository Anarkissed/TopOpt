// to_strengthen.inc -- strengthen_versions and its helpers: the strengthen ladder.
//
// TO rebuild stage 0 (docs/design/to-rebuild/05-workplan.md): moved out of
// run_job.cpp unchanged, line for line. This is NOT a translation unit: it is
// included by run_job.cpp at the place the code used to stand, inside
// namespace topopt, so every name resolves exactly as before. Do not compile
// it on its own and do not include it anywhere else.

// ── "REDESIGN TO STRENGTHEN" (CORE LIST item 50) ─────────────────────────────
// The reviewer's brief of 2026-10-24 22:59, approved 01:52 (arm B dropped), with
// the search changed after the sample (02:16): the margin can sit on a plateau
// set by frozen features, so the fraction is BRACKETED (halved while the aim
// holds, doubled while it fails, then bisected) instead of moved +-5 % a step.
//
// Every optimize is an ordinary one-rung minimize_plastic call on the run's own
// (domain_box_only, volume_basis_domain) options; no solver file is involved.
// The coarse runs start fresh; a version's fine run starts from the passing
// coarse design with its loose pieces taken out (clean_strengthen_start; ruling
// 2026-10-25), a repair from the design it repairs, cleaned the same way. Each version's fraction is searched on a res/2 grid, the
// version is then run once at the job's resolution and VERIFIED: its exported
// solid (variant_export_model_mesh, the shell the file carries) re-voxelized and
// certified by analyze_job, the same certification `topopt-cli analyze` runs.
// THE LADDER (his decision of 2026-10-26, replacing 25 / 50 / 75 % less worst stress):
// version 1's target is the user's safety margin (the lightest redesign that is just
// safe), versions 2 and 3 each 10 % over the version before, on its VERIFIED margin.
constexpr double kStrengthenLadderStep = 1.10;
constexpr double kStrengthenDelta = 0.10;     // aim above the target (da Silva 2021)
constexpr double kStrengthenGamma = 0.75;     // the repair's exponent
constexpr double kStrengthenCeilingUse = 0.95;
constexpr double kStrengthenStepOver = 1.05;  // each version >= 1.05 x the previous
constexpr int kStrengthenCoarseRuns = 6;
constexpr int kStrengthenRepairs = 2;

// Move a one-rung result's rung onto `into`, keeping every per-rung vector aligned
// with `evaluated` (run_info reads them by rung index).
void append_rung(MinimizePlasticResult& into, MinimizePlasticResult&& from) {
  auto take = [](auto& a, auto& b) {
    for (auto& x : b) a.push_back(std::move(x));
  };
  take(into.evaluated, from.evaluated);
  take(into.rung_grayscale_mnd, from.rung_grayscale_mnd);
  take(into.conditional_projection_fired, from.conditional_projection_fired);
  take(into.rung_infeasible, from.rung_infeasible);
  take(into.rung_non_convergent, from.rung_non_convergent);
  take(into.rung_non_convergent_iteration, from.rung_non_convergent_iteration);
  take(into.rung_non_convergent_residual, from.rung_non_convergent_residual);
  take(into.rung_non_convergent_tolerance, from.rung_non_convergent_tolerance);
  take(into.rung_diverged, from.rung_diverged);
  take(into.rung_diverged_iteration, from.rung_diverged_iteration);
  take(into.rung_diverged_c_ratio, from.rung_diverged_c_ratio);
  take(into.rung_diverged_cg_ratio, from.rung_diverged_cg_ratio);
  take(into.rung_diverged_wall_ratio, from.rung_diverged_wall_ratio);
  take(into.rung_time_budget, from.rung_time_budget);
  take(into.rung_time_budget_iteration, from.rung_time_budget_iteration);
  take(into.rung_time_budget_ms, from.rung_time_budget_ms);
  take(into.rung_time_budget_elapsed_ms, from.rung_time_budget_elapsed_ms);
  take(into.rung_time_budget_baseline_ms, from.rung_time_budget_baseline_ms);
  take(into.rung_time_budget_phase, from.rung_time_budget_phase);
  take(into.rung_time_budget_phase_ms, from.rung_time_budget_phase_ms);
  take(into.draft_rung_tail_k, from.draft_rung_tail_k);
  take(into.draft_rung_c_gap, from.draft_rung_c_gap);
  take(into.draft_rung_escalated, from.draft_rung_escalated);
  take(into.draft_rung_probe_flip, from.draft_rung_probe_flip);
  take(into.draft_rung_probe_cg, from.draft_rung_probe_cg);
  take(into.draft_rung_probe_tightmove, from.draft_rung_probe_tightmove);
  take(into.report.variants, from.report.variants);
  take(into.report.rejected, from.report.rejected);
}

// Squared distance from p to triangle abc (closest point, Ericson's regions).
double point_triangle_d2(const Vec3& p, const Vec3& a, const Vec3& b, const Vec3& c) {
  auto sub = [](const Vec3& u, const Vec3& v) { return Vec3{u.x - v.x, u.y - v.y, u.z - v.z}; };
  auto dot = [](const Vec3& u, const Vec3& v) { return u.x * v.x + u.y * v.y + u.z * v.z; };
  auto d2 = [&](const Vec3& q) { const Vec3 e = sub(p, q); return dot(e, e); };
  const Vec3 ab = sub(b, a), ac = sub(c, a), ap = sub(p, a);
  const double d1 = dot(ab, ap), d2v = dot(ac, ap);
  if (d1 <= 0 && d2v <= 0) return d2(a);
  const Vec3 bp = sub(p, b);
  const double d3 = dot(ab, bp), d4 = dot(ac, bp);
  if (d3 >= 0 && d4 <= d3) return d2(b);
  const double vc = d1 * d4 - d3 * d2v;
  if (vc <= 0 && d1 >= 0 && d3 <= 0) {
    const double t = d1 / (d1 - d3);
    return d2(Vec3{a.x + t * ab.x, a.y + t * ab.y, a.z + t * ab.z});
  }
  const Vec3 cp = sub(p, c);
  const double d5 = dot(ab, cp), d6 = dot(ac, cp);
  if (d6 >= 0 && d5 <= d6) return d2(c);
  const double vb = d5 * d2v - d1 * d6;
  if (vb <= 0 && d2v >= 0 && d6 <= 0) {
    const double t = d2v / (d2v - d6);
    return d2(Vec3{a.x + t * ac.x, a.y + t * ac.y, a.z + t * ac.z});
  }
  const double va = d3 * d6 - d5 * d4;
  if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0) {
    const double t = (d4 - d3) / ((d4 - d3) + (d5 - d6));
    return d2(Vec3{b.x + t * (c.x - b.x), b.y + t * (c.y - b.y), b.z + t * (c.z - b.z)});
  }
  const double den = 1.0 / (va + vb + vc);
  const double v = vb * den, w = vc * den;
  return d2(Vec3{a.x + ab.x * v + ac.x * w, a.y + ab.y * v + ac.y * w,
                 a.z + ab.z * v + ac.z * w});
}

// The ceiling's worst-stress site (the reviewer's ruling of 2026-10-25 03:58).
void strengthen_cap_site(StrengthenReport& sr, const VoxelGrid& G,
                         const std::vector<double>& von_mises, const StepModel& model) {
  if (von_mises.size() != G.voxel_count()) return;
  std::size_t at = 0;
  for (std::size_t i = 1; i < von_mises.size(); ++i)
    if (von_mises[i] > von_mises[at]) at = i;
  const int x = static_cast<int>(at % static_cast<std::size_t>(G.nx));
  const int y = static_cast<int>((at / static_cast<std::size_t>(G.nx)) %
                                 static_cast<std::size_t>(G.ny));
  const int z = static_cast<int>(at / (static_cast<std::size_t>(G.nx) *
                                       static_cast<std::size_t>(G.ny)));
  sr.cap_point = G.voxel_center(x, y, z);
  double best = std::numeric_limits<double>::infinity();
  for (std::size_t t = 0; t < model.mesh.triangles.size(); ++t) {
    const auto& tri = model.mesh.triangles[t];
    const double d = point_triangle_d2(sr.cap_point, model.mesh.vertices[tri[0]],
                                       model.mesh.vertices[tri[1]],
                                       model.mesh.vertices[tri[2]]);
    if (d < best) {
      best = d;
      sr.cap_face_id = model.triangle_face[t];
    }
  }
  for (int dk = -1; dk <= 1; ++dk)
    for (int dj = -1; dj <= 1; ++dj)
      for (int di = -1; di <= 1; ++di) {
        const int i = x + di, j = y + dj, k = z + dk;
        if (i < 0 || j < 0 || k < 0 || i >= G.nx || j >= G.ny || k >= G.nz) continue;
        const VoxelTag t = G.tag(i, j, k);
        if (t == VoxelTag::Fixture) sr.cap_at_anchor_face = true;
        if (t == VoxelTag::Load) sr.cap_at_load_face = true;
      }
  char line[400];
  std::snprintf(line, sizeof(line),
                "the box filled solid peaks at (%.1f, %.1f, %.1f) mm, on face %d%s",
                sr.cap_point.x, sr.cap_point.y, sr.cap_point.z, sr.cap_face_id,
                sr.cap_at_anchor_face || sr.cap_at_load_face
                    ? (sr.cap_at_anchor_face
                           ? ", at the edge of an anchor face: a fixed-support "
                             "corner, where voxel stress grows with resolution, so "
                             "this cap may not be real"
                           : ", at the edge of a load face: where voxel stress "
                             "grows with resolution, so this cap may not be real")
                    : "");
  sr.cap_note = line;
}

// ── DON'T CARRY SPECKS ACROSS GRIDS (core-loose-pieces, ruling 2026-10-25) ──
// The fine run of a version starts from a DESIGN, never from a speckled one:
// the coarse search's passing design (resampled onto the fine grid by voxel
// centre) or, for a repair, the fine design it repairs. Before it is handed on,
// its LOOSE pieces — face-connected pieces of material touching no support or
// load, the solves' own rule (fea_loose_pieces) — lose their design material.
// Frozen voxels cannot be removed (the run unions them in), so a frozen piece
// that is loose stays and the solves' connection rule takes it out of each
// system; `loose_left` counts the NON-frozen loose voxels left, which is 0 by
// construction and checked by a second census. (Until this, the fine run
// started from the parametric level set's hole array at the coarse fraction:
// on his Carriage Arms at that fraction it was 2,038 pieces, 2,031 of them
// loose, and the first fine solve never ended.)
struct StrengthenStart {
  std::vector<double> design;          // on the fine grid; empty = none
  std::string from;                    // "coarse design" | "repaired design"
  int loose = 0;                       // loose pieces in the hand-off
  long long loose_voxels_removed = 0;  // design voxels they lost
  long long loose_left = 0;            // non-frozen loose voxels left (0)
  int frozen_loose = 0;                // frozen-only pieces still loose
  double ms = 0.0;                     // the two censuses' wall time
};

StrengthenStart clean_strengthen_start(const VoxelGrid& G, std::vector<double> design,
                                       const DesignMask& mask,
                                       const SolvedDesignDomain& domain, double iso,
                                       const char* from) {
  StrengthenStart out;
  const std::size_t nv = G.voxel_count();
  if (design.size() != nv || mask.size() != nv) return out;
  out.from = from;
  auto frozen = [&](std::size_t i) {
    return mask[i] == MaskValue::FrozenSolid || G.tags[i] == VoxelTag::Load ||
           G.tags[i] == VoxelTag::Fixture;
  };
  for (std::size_t i = 0; i < nv; ++i)
    if (G.tags[i] == VoxelTag::Empty || mask[i] == MaskValue::FrozenVoid)
      design[i] = 0.0;
  // What anchors a piece: the run's supports, its declared loads, and every node
  // of a Load voxel (a superset of the loaded nodes, so the cleaning never
  // removes a piece a solve would keep).
  std::vector<NodalLoad> loads = domain.external_loads;
  for (int k = 0; k < G.nz; ++k)
    for (int j = 0; j < G.ny; ++j)
      for (int i = 0; i < G.nx; ++i) {
        if (G.tag(i, j, k) != VoxelTag::Load) continue;
        for (int c = 0; c < 8; ++c)
          loads.push_back({fea_node_index(G, i + (c & 1), j + ((c >> 1) & 1),
                                          k + ((c >> 2) & 1)),
                           0, 1.0});
      }
  auto census = [&]() {
    std::vector<char> solid(nv, 0);
    for (std::size_t i = 0; i < nv; ++i)
      solid[i] = G.tags[i] != VoxelTag::Empty && (design[i] > iso || frozen(i)) ? 1 : 0;
    return fea_loose_pieces(G, solid, domain.bcs, loads);
  };
  const LoosePieceCensus before = census();
  out.loose = before.loose;
  for (int e : before.loose_voxel) {
    const std::size_t i = static_cast<std::size_t>(e);
    if (frozen(i)) continue;
    design[i] = 0.0;
    ++out.loose_voxels_removed;
  }
  const LoosePieceCensus after = census();
  for (int e : after.loose_voxel)
    if (!frozen(static_cast<std::size_t>(e))) ++out.loose_left;
  out.frozen_loose = after.loose;
  out.ms = before.ms + after.ms;
  out.design = std::move(design);
  return out;
}

// The coarse design, resampled onto the fine grid: each fine voxel takes the
// density of the coarse voxel holding its centre (0 outside the coarse grid).
std::vector<double> resample_design(const VoxelGrid& coarse,
                                    const std::vector<double>& rho,
                                    const VoxelGrid& fine) {
  std::vector<double> out;
  if (rho.size() != coarse.voxel_count() || !(coarse.spacing > 0.0)) return out;
  out.assign(fine.voxel_count(), 0.0);
  for (int k = 0; k < fine.nz; ++k)
    for (int j = 0; j < fine.ny; ++j)
      for (int i = 0; i < fine.nx; ++i) {
        const Vec3 c = fine.voxel_center(i, j, k);
        const int a = static_cast<int>(std::floor((c.x - coarse.origin.x) / coarse.spacing));
        const int b = static_cast<int>(std::floor((c.y - coarse.origin.y) / coarse.spacing));
        const int d = static_cast<int>(std::floor((c.z - coarse.origin.z) / coarse.spacing));
        if (a < 0 || b < 0 || d < 0 || a >= coarse.nx || b >= coarse.ny || d >= coarse.nz)
          continue;
        out[fine.index(i, j, k)] = rho[coarse.index(a, b, d)];
      }
  return out;
}

void record_start(StrengthenVersionReport& vr, const StrengthenStart& st, int version,
                  double vf) {
  vr.fine_start = st.design.empty() ? "hole array" : st.from;
  vr.fine_start_loose = st.loose;
  vr.fine_start_loose_voxels_removed = st.loose_voxels_removed;
  vr.fine_start_loose_left = st.loose_left;
  vr.fine_start_frozen_loose = st.frozen_loose;
  std::fprintf(stderr,
               "[strengthen] version %d: fine start at vf %.4f from the %s: %d loose "
               "piece(s) taken out (%lld design voxels), %lld non-frozen loose voxels "
               "left, %d frozen piece(s) still loose (the solves take them out) ; "
               "%.1f ms\n",
               version, vf, vr.fine_start.c_str(), st.loose, st.loose_voxels_removed,
               st.loose_left, st.frozen_loose, st.ms);
  std::fflush(stderr);
}

MinimizePlasticResult strengthen_versions(
    const JobDescription& job, const std::string& job_dir,
    const std::string& out_dir, const MaterialLibrary& materials,
    const SettingsRules& rules, const StepModel& model, bool model_is_mesh,
    const Material& material, const VoxelGrid& grid,
    const std::vector<DirichletBC>& bcs, const MinimizePlasticOptions& options,
    const SolvedDesignDomain& domain, bool emit_progress) {
  const std::string work = join_path(out_dir, "strengthen");
  std::filesystem::create_directories(work);
  StrengthenReport sr;
  sr.evaluated = true;
  sr.delta = kStrengthenDelta;
  sr.gamma = kStrengthenGamma;
  sr.vf_step = 0.0;  // bracketing search, no per-step cap (see above)
  sr.margin_required = options.margin_stop;
  const double iso = run_printed_iso(options);

  // PROGRESS lines through the whole pass (the worker only understands
  // `PROGRESS rung=<i> rungs=<n> iter=<k>`; extra keys are ignored). The three
  // versions are the three "rungs" ("Variant k of 3" on the app); within a
  // version `iter` counts every optimizer iteration of its coarse and fine runs,
  // cumulatively, so it never runs backwards; it restarts only when the version
  // (the rung) advances, as a ladder's does. The minimize_plastic runs below
  // forward nothing of their own (quiet() clears their progress).
  int p_rung = 0, p_base = 0, p_last = 0;
  const char* p_step = "reference";
  auto say = [&](int iter) {
    if (!emit_progress) return;
    std::printf("PROGRESS rung=%d rungs=%d iter=%d stage=strengthen step=%s\n", p_rung,
                3, iter, p_step);
    std::fflush(stdout);
  };
  say(0);

  // The reference: the part as drawn, certified.
  const AnalyzeJobResult drawn =
      analyze_job(job, job_dir, join_path(work, "as_drawn"), materials, rules, "", {});
  // The drawing is measured as INFORMATION only ("your drawing: N x, M g"): the targets
  // are the safety margin and the versions before (the ladder above).
  sr.as_drawn_margin = drawn.analysis.margin_effective;
  sr.reference_margin = sr.margin_required;
  // LOAD SCENARIOS (ruling 2026-10-26 12:46): every step on the WORST scenario
  // (analyze_job certifies them all). A part as drawn that cannot carry one of them
  // has no margin worth referencing: the reference is the requirement alone.
  const bool with_scenarios = !job.loads.scenarios.empty();
  sr.as_drawn_unheld = drawn.unheld_scenario;
  sr.original_mass_grams = drawn.voxel_mass_grams;

  // The ceiling: the domain (box, minus keep-outs and Keep Clears, plus everything
  // frozen) filled solid, certified the same way.
  const VoxelGrid& G = domain.grid;
  const DesignMask mask = design_domain_mask(domain, options);
  const std::vector<char> drawn_part = original_part_voxels(grid, domain);
  std::vector<double> filled(G.voxel_count(), 0.0);
  for (std::size_t i = 0; i < filled.size(); ++i)
    if (G.tags[i] != VoxelTag::Empty && mask[i] != MaskValue::FrozenVoid)
      filled[i] = 1.0;
  if (options.design_box.has_value()) {
    const DesignBox& b = *options.design_box;
    for (std::size_t i = 0; i < filled.size(); ++i) {
      if (mask[i] != MaskValue::FrozenSolid && G.tags[i] != VoxelTag::Load &&
          G.tags[i] != VoxelTag::Fixture)
        continue;
      const int x = static_cast<int>(i % static_cast<std::size_t>(G.nx));
      const int y = static_cast<int>((i / static_cast<std::size_t>(G.nx)) %
                                     static_cast<std::size_t>(G.ny));
      const int z = static_cast<int>(i / (static_cast<std::size_t>(G.nx) *
                                          static_cast<std::size_t>(G.ny)));
      const Vec3 c = G.voxel_center(x, y, z);
      if (c.x < b.min.x || c.x > b.max.x || c.y < b.min.y || c.y > b.max.y ||
          c.z < b.min.z || c.z > b.max.z)
        ++sr.frozen_outside_box_voxels;
    }
  }
  const std::string ceiling_stl = join_path(work, "ceiling.stl");
  write_stl_file(ceiling_stl, keep_largest_component(marching_cubes(G, filled, 0.5)));
  p_step = "ceiling";
  say(0);
  {
    const AnalyzeJobResult ceil =
        analyze_job(job, job_dir, join_path(work, "ceiling"), materials, rules,
                    ceiling_stl, {});
    sr.ceiling_margin = ceil.analysis.margin_effective;
    sr.ceiling_unheld = ceil.unheld_scenario;
    strengthen_cap_site(sr, G, ceil.analysis.von_mises_field, model);
  }

  // The coarse problem: the same job at half the resolution.
  JobDescription coarse_job = job;
  // Half the resolution, but never below 48 (or the job's own when it is finer
  // than that): at res 32 his Carriage Arms' 3-voxel pads are a third of the part,
  // and the coarse margin read 5.8 where the job's resolution gave 4.85.
  coarse_job.resolution =
      std::min(job.resolution, std::max(job.resolution / 2, 48));
  sr.coarse_resolution = coarse_job.resolution;
  JobSetup coarse = build_job_setup(coarse_job, model, model_is_mesh, materials);
  auto quiet = [](MinimizePlasticOptions o) {
    o.on_variant = nullptr;  // the caller streams the final versions itself
    o.on_density_snapshot = nullptr;
    o.on_iteration = nullptr;
    o.progress = nullptr;    // the pass speaks for itself (say() above)
    return o;
  };
  const MinimizePlasticOptions coarse_opts = quiet(coarse.options);
  // LATER COARSE RUNS START FROM A DESIGN (reviewer's order, 2026-10-26): the
  // first coarse run of the pass starts from the level set's hole array as
  // before; every later one — the rest of the bracket and every later version's
  // — starts from the most recent coarse design, its loose pieces taken out
  // (clean_strengthen_start on the coarse domain). At the low fractions the
  // bracket reaches, the hole array is a field of disconnected blobs, which is
  // what sent his Fine job's coarse runs 5-6 into the Jacobi-CG fallback.
  const SolvedDesignDomain coarse_domain =
      resolve_design_domain(coarse.grid, coarse.bcs, coarse.options);
  const DesignMask coarse_mask = design_domain_mask(coarse_domain, coarse.options);
  std::vector<double> coarse_last;  // the most recent coarse design
  const MinimizePlasticOptions fine_opts = quiet(options);
  auto run_one = [&](const JobSetup* s, double vf,
                     const std::vector<double>& seed) {
    MinimizePlasticOptions o = s ? coarse_opts : fine_opts;
    o.volume_fraction_ladder = {vf};
    o.initial_design = seed;
    p_step = s ? "coarse" : "fine";
    p_last = 0;
    if (emit_progress)
      o.progress = [&](std::size_t, std::size_t, int it) {
        p_last = std::max(p_last, it);
        say(p_base + it);
      };
    MinimizePlasticResult r = minimize_plastic(s ? s->grid : grid, material,
                                               job.material, s ? s->bcs : bcs, rules, o);
    p_base += p_last;
    return r;
  };
  auto margin_of = [](const MinimizePlasticResult& r) {
    const MinimizePlasticVariant& v = r.evaluated.front();
    return v.accepted ? v.report.margin_effective : -1.0;
  };

  // Load nodes of the solve grid, for the deflection read on the verified solve.
  std::vector<int> load_nodes;
  for (int k = 0; k < G.nz; ++k)
    for (int j = 0; j < G.ny; ++j)
      for (int i = 0; i < G.nx; ++i) {
        if (G.tag(i, j, k) != VoxelTag::Load) continue;
        for (int c = 0; c < 8; ++c)
          load_nodes.push_back(fea_node_index(G, i + (c & 1), j + ((c >> 1) & 1),
                                              k + ((c >> 2) & 1)));
      }

  MinimizePlasticResult out;
  double prev_vf = 0.0, prev_verified = 0.0;
  bool prev_ok = true;  // the version before was built (version 1 builds on nothing)
  for (int k = 0; k < 3; ++k) {
    const auto t0 = std::chrono::steady_clock::now();
    StrengthenVersionReport vr;
    vr.version = k + 1;
    p_rung = k;
    p_base = 0;
    p_step = "search";
    say(0);
    vr.stress_cut = 0.0;  // the old ladder's field; the target rule says what it is now
    vr.target_rule = k == 0 ? "your safety margin"
                            : "10% over version " + std::to_string(k) + "'s verified margin";
    const double target =
        k == 0 ? sr.margin_required
               : std::max(kStrengthenLadderStep, kStrengthenStepOver) * prev_verified;
    vr.target_margin = target;
    if (!prev_ok) {
      vr.status = "unreachable";
      vr.note = "version " + std::to_string(k) + " was not built, so there is nothing to " +
                "build 10% over";
      vr.target_margin = 0.0;
      sr.versions.push_back(vr);
      continue;
    }
    prev_ok = false;  // until this version is built (verified, repaired or merged)
    if (!sr.ceiling_unheld.empty()) {
      // LOAD SCENARIOS: even the box filled solid gives that load no path.
      vr.status = "unreachable";
      vr.note = scenario_unheld_reason(sr.ceiling_unheld) + ", even with the box filled solid";
      sr.versions.push_back(vr);
      continue;
    }
    if (target > kStrengthenCeilingUse * sr.ceiling_margin) {
      vr.status = "unreachable";
      char note[200];
      std::snprintf(note, sizeof(note),
                    "above %.2f x the box filled solid (margin %.4g): unreachable "
                    "in this design space",
                    kStrengthenCeilingUse, sr.ceiling_margin);
      vr.note = note;
      sr.versions.push_back(vr);
      continue;
    }
    // 1. Bracket the fraction on the coarse grid.
    const double aim = target * (1.0 + kStrengthenDelta);
    const double floor_vf = std::max(prev_vf, 0.02);
    double vf = std::clamp(std::pow(target / sr.ceiling_margin, 1.0 / 1.5),
                           floor_vf, 1.0);
    double pass_vf = -1.0, fail_vf = -1.0, best_m = -1.0;
    std::vector<double> pass_design;  // the passing coarse design (coarse grid)
    VoxelGrid pass_grid;
    while (vr.coarse_runs < kStrengthenCoarseRuns) {
      std::vector<double> cseed;
      if (!coarse_last.empty()) {
        StrengthenStart cs = clean_strengthen_start(coarse_domain.grid, coarse_last,
                                                    coarse_mask, coarse_domain, iso,
                                                    "previous coarse design");
        if (!cs.design.empty()) {
          std::fprintf(stderr,
                       "[strengthen] version %d coarse run %d at vf %.4f: starts from "
                       "the previous coarse design: %d loose piece(s) taken out (%lld "
                       "design voxels), %lld non-frozen loose voxels left ; %.1f ms\n",
                       k + 1, vr.coarse_runs + 1, vf, cs.loose, cs.loose_voxels_removed,
                       cs.loose_left, cs.ms);
          cseed = std::move(cs.design);
          ++vr.coarse_seeded;
        }
      }
      MinimizePlasticResult cr = run_one(&coarse, vf, cseed);
      const double m = margin_of(cr);
      ++vr.coarse_runs;
      if (cr.evaluated.front().optimization.physical_density.size() ==
          coarse_domain.grid.voxel_count())
        coarse_last = cr.evaluated.front().optimization.physical_density;
      best_m = std::max(best_m, m);
      if (m >= aim) {
        pass_vf = vf;
        pass_design = std::move(cr.evaluated.front().optimization.physical_density);
        pass_grid = std::move(cr.solved_grid);
        if (vf <= floor_vf + 1e-9) break;
        vf = fail_vf > 0.0 ? 0.5 * (vf + fail_vf) : std::max(floor_vf, 0.5 * vf);
      } else {
        fail_vf = vf;
        if (vf >= 1.0 - 1e-9) break;
        vf = pass_vf > 0.0 ? 0.5 * (vf + pass_vf) : std::min(1.0, 2.0 * vf);
      }
      if (pass_vf > 0.0 && fail_vf > 0.0 && pass_vf / fail_vf < 1.08) break;
    }
    if (pass_vf < 0.0) {
      vr.status = "unreachable";
      char note[200];
      std::snprintf(note, sizeof(note),
                    "no fraction of the box reached it on the coarse grid (best "
                    "margin %.4g)",
                    best_m);
      vr.note = note;
      vr.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
                       .count();
      sr.versions.push_back(vr);
      continue;
    }
    // 2. Fine run, verify the export, repair at most twice. The fine run starts
    // from the passing coarse design, its loose pieces taken out (see
    // clean_strengthen_start): the fine start holds no loose design material.
    vf = pass_vf;
    StrengthenStart start = clean_strengthen_start(
        G, resample_design(pass_grid, pass_design, G), mask, domain, iso,
        "coarse design");
    record_start(vr, start, k + 1, vf);
    const std::vector<double> coarse_start = std::move(start.design);
    std::vector<double> seed = coarse_start;
    MinimizePlasticResult best;
    double best_verified = -1.0;
    StrengthenAttemptReport best_attempt;
    int shown_bridges = 0;  // 42-B's straight bridges on the shown attempt
    bool ok = false;
    for (int attempt = 0; attempt <= kStrengthenRepairs; ++attempt) {
      MinimizePlasticResult r = run_one(nullptr, vf, seed);
      const MinimizePlasticVariant& v = r.evaluated.front();
      p_step = "verify";
      say(p_base);
      const std::string stl =
          join_path(work, "v" + std::to_string(k + 1) + "_" +
                              std::to_string(attempt) + ".stl");
      // E1: the version is verified on its FINISHED file, the one it exports: slim,
      // and when that file fails, the safe finish's (his fallback ruling 2026-11-03).
      const RunFinish fin = make_run_finish(job, options, &model, r.solved_grid);
      const RunFinish safe_fin = safe_finish(fin);
      auto verify_file = [&](const TriangleMesh& m) {
        write_stl_file(stl, m);
        return analyze_job(job, job_dir, join_path(work, "verify"), materials, rules, stl, {});
      };
      FinishBlock fb;
      TriangleMesh raw_mesh;
      const TriangleMesh slim_mesh = variant_export_model_mesh(
          v, job.output, r.solved_grid, iso, &model, job.keep_regions, &fin, &fb, &raw_mesh);
      AnalyzeJobResult a = verify_file(slim_mesh);
      double verified = a.analysis.margin_effective;
      // The finished file's own checks (E1): margin against the version's target.
      const DesignMask* clearance_p =
          !options.clearance_void.empty() && options.clearance_void.size() == r.solved_grid.voxel_count()
              ? &options.clearance_void
              : nullptr;
      auto file_reason = [&](const TriangleMesh& m, const AnalyzeJobResult& an, FinishBlock& b) {
        FinishRecheck rc =
            recheck_file(m, raw_mesh, r.solved_grid, clearance_p, &mask, an, target, b, fin.part);
        rc.margin = rc.margin_required;  // the margin is the target test below, not this one
        return finish_verdict_reason(rc);
      };
      // What the version prints, against the part as drawn and the Keep Clears.
      const std::vector<double>& rho = v.optimization.physical_density;
      long long inter = 0, uni = 0, clear = 0;
      for (std::size_t i = 0; i < rho.size(); ++i) {
        const bool printed = rho[i] > iso;
        inter += printed && drawn_part[i];
        uni += printed || drawn_part[i];
        clear += printed && !options.clearance_void.empty() &&
                 options.clearance_void[i] == MaskValue::FrozenVoid &&
                 mask[i] != MaskValue::FrozenSolid;
      }
      // ITEM 50 ACCEPTANCE (reviewer's ruling 2026-10-26; strengthen_accept.hpp):
      // the verified export meets the target (already >= 1.05 x the previous
      // version's), no anchored piece detached / load path severed, no Keep
      // Clear voxel. Dropped specks are a note, never a refusal.
      StrengthenAttemptReport att;
      att.attempt = attempt;
      att.verified_margin = verified;
      att.specks = v.v3.specks_dropped;
      att.speck_volume_mm3 = v.report.speck_volume_mm3;
      att.keep_clear_voxels = clear;
      att.anchors_attached = v.report.rejection_reason != kAnchorDetachedReason;
      att.rejection_reason = v.report.rejection_reason;
      att.unheld_scenario = a.unheld_scenario;  // LOAD SCENARIOS, on the export
      if (!att.unheld_scenario.empty())
        att.unheld_reason = scenario_unheld_reason(att.unheld_scenario);
      att.finish_reason = file_reason(slim_mesh, a, fb);
      // The safe finish is tried only where finishing can change the outcome: not for a
      // detached anchor, a design-level Keep clear or the variant's own refusal.
      const bool finish_can_help =
          att.anchors_attached && att.keep_clear_voxels == 0 &&
          !strengthen_structural_rejection(att, kMarginBelowRequiredReason);
      if (finish_can_help && !strengthen_attempt_accepted(att, target, kMarginBelowRequiredReason)) {
        FinishBlock sfb;
        const TriangleMesh safe_mesh = variant_export_model_mesh(
            v, job.output, r.solved_grid, iso, &model, job.keep_regions, &safe_fin, &sfb);
        AnalyzeJobResult sa = verify_file(safe_mesh);
        StrengthenAttemptReport satt = att;
        satt.verified_margin = sa.analysis.margin_effective;
        satt.unheld_scenario = sa.unheld_scenario;
        satt.unheld_reason =
            sa.unheld_scenario.empty() ? "" : scenario_unheld_reason(sa.unheld_scenario);
        satt.finish_reason = file_reason(safe_mesh, sa, sfb);
        if (strengthen_attempt_accepted(satt, target, kMarginBelowRequiredReason)) {
          FinishRecheck rc;
          rc.ran = true;
          rc.margin = verified;
          rc.margin_required = target;
          std::string why = !att.unheld_reason.empty()   ? att.unheld_reason
                            : !att.finish_reason.empty() ? att.finish_reason
                                                         : finish_verdict_reason(rc);
          const std::string pre = "After finishing, ";
          if (why.rfind(pre, 0) == 0) why = "With the slim finish, " + why.substr(pre.size());
          sfb.finish_fallback = true;
          sfb.finish_fallback_reason = why;
          std::fprintf(stderr, "[finish] strengthen version %d uses the safe finish: %s\n",
                       k + 1, why.c_str());
          fb = sfb;
          a = std::move(sa);
          att = satt;
          verified = att.verified_margin;
        } else {
          write_stl_file(stl, slim_mesh);  // the attempt shown is the slim one, as before
        }
      }
      double defl = 0.0;
      if (a.analysis.displacement_field.size() ==
          static_cast<std::size_t>(3 * fea_node_count(G)))
        for (const int n : load_nodes) {
          const double* u = &a.analysis.displacement_field[3 * static_cast<std::size_t>(n)];
          defl = std::max(defl, std::sqrt(u[0] * u[0] + u[1] * u[1] + u[2] * u[2]));
        }
      vr.attempts.push_back(att);
      const bool accepted_here =
          strengthen_attempt_accepted(att, target, kMarginBelowRequiredReason);
      // A repair warm-starts from this design only if it kept every anchor:
      // warm-starting from a design that let anchored pieces go kept them loose.
      std::vector<double> next_seed =
          v.report.rejection_reason != kAnchorDetachedReason
              ? v.optimization.physical_density
              : std::vector<double>();
      // The version shows the ACCEPTED attempt when there is one, else the best
      // verified one.
      if (accepted_here || verified > best_verified) {
        best_verified = verified;
        vr.volume_fraction = vf;
        vr.in_loop_margin = v.report.margin_effective;
        vr.verified_margin = verified;
        vr.mass_grams = v.mass_grams;
        vr.mass_fraction_of_original =
            sr.original_mass_grams > 0.0 ? v.mass_grams / sr.original_mass_grams : 0.0;
        vr.max_deflection_mm = defl;
        vr.iou_with_original =
            uni > 0 ? static_cast<double>(inter) / static_cast<double>(uni) : 0.0;
        vr.essentially_original = vr.iou_with_original > 0.9;
        vr.anchors_attached = v.report.rejection_reason != kAnchorDetachedReason;
        vr.specks = v.v3.specks_dropped;
        vr.keep_clear_voxels = clear;
        // E1: strengthen's verify IS the finished-shape re-check (recheck_file filled
        // the file's Keep clear, pieces, loose pieces and joints).
        fb.recheck_ran = true;
        fb.margin = verified;
        fb.margin_before = v.report.margin_effective;
        // Mass from the files themselves: the finished one, and the unfinished export.
        fb.mass_grams = material.density_g_cm3 * fb.volume_after_mm3 / 1000.0;
        fb.mass_before_grams = material.density_g_cm3 * fb.volume_before_mm3 / 1000.0;
        vr.finish = fb;
        vr.repairs = attempt;
        vr.scenarios = a.scenarios;  // LOAD SCENARIOS: every one, on this export
        shown_bridges = v.report.bridges;
        best_attempt = att;
        best = std::move(r);
      }
      if (accepted_here) {
        ok = true;
        break;
      }
      // Repair: raise the fraction by the shortfall (at least x1.25, so two repairs
      // can cover a coarse-to-fine gap), from this design — its loose pieces
      // taken out first — or, if it let an anchor go, from the clean coarse
      // start again (never from a speckled hole array).
      seed = next_seed.empty()
                 ? coarse_start
                 : clean_strengthen_start(G, std::move(next_seed), mask, domain, iso,
                                          "repaired design")
                       .design;
      const double ratio = verified > 0.0 ? target / verified : 2.0;
      vf = std::min(1.0, vf * std::max(1.25, std::pow(ratio, 1.0 / kStrengthenGamma)));
    }
    vr.seconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    if (!ok) {
      // The REAL reason, from the attempt shown (strengthen_refusal_note).
      vr.status = "unreachable";
      vr.note = strengthen_refusal_note(best_attempt, target, kMarginBelowRequiredReason,
                                        static_cast<int>(vr.attempts.size()) - 1,
                                        kStrengthenRepairs);
      sr.versions.push_back(vr);
      continue;
    }
    // Two versions at the same design are one.
    if (!out.evaluated.empty() && std::fabs(vr.volume_fraction - prev_vf) <= 0.01 * prev_vf) {
      vr.status = "merged";
      vr.note = "the same design as version " + std::to_string(k);
      prev_ok = true;
      prev_verified = vr.verified_margin;
      sr.versions.push_back(vr);
      continue;
    }
    vr.status = vr.repairs > 0 ? "repaired" : "verified";
    if (vr.essentially_original) vr.note = "essentially your original";
    if (with_scenarios && shown_bridges > 0) {
      // LOAD SCENARIOS: the scenarios did not grow the connection on their own; the
      // fallback joined the split (said, never silent).
      const std::string b = "the split was joined by the straight bridge (" +
                            std::to_string(shown_bridges) + "), the fallback";
      vr.note = vr.note.empty() ? b : vr.note + "; " + b;
    }
    {
      const std::string specks = strengthen_speck_note(best_attempt);
      if (!specks.empty()) vr.note = vr.note.empty() ? specks : vr.note + "; " + specks;
    }
    prev_vf = vr.volume_fraction;
    prev_verified = vr.verified_margin;
    prev_ok = true;
    sr.versions.push_back(vr);
    out.solved_grid = best.solved_grid;
    out.used_multigrid = best.used_multigrid;
    out.mg_levels = best.mg_levels;
    out.mg_hierarchy_ever_built = best.mg_hierarchy_ever_built;
    out.growth_ladder = false;
    // A version accepted on its VERIFIED export margin (strengthen_accept.hpp: the
    // in-loop margin never refuses it) is that version's design even when its in-loop
    // margin sat under the gate: it is written and listed with the accepted variants, at
    // the margin it was accepted on. Without this a version was "verified" with no file
    // (test_keep_strengthen: in loop 1.32, verified 2.43, target 1.5).
    MinimizePlasticVariant& shown = best.evaluated.front();
    shown.report.finish = vr.finish;  // E1: the export finishes it as it was verified
    for (VariantReport& rv : best.report.variants) rv.finish = vr.finish;  // one rung
    if (!shown.accepted) {
      shown.accepted = true;
      shown.report.accepted = true;
      shown.report.margin_effective = vr.verified_margin;
      shown.report.rejection_reason.clear();
      best.report.rejected.clear();  // a version's run is one rung
      best.report.variants = {shown.report};
    }
    append_rung(out, std::move(best));
  }
  if (out.evaluated.empty()) out.solved_grid = domain.grid;
  out.report.material = job.material;
  out.report.strengthen = std::move(sr);
  return out;
}
