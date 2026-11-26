// to_analyze.inc -- analyze_job: the strength certificate of a finished shape.
//
// TO rebuild stage 0 (docs/design/to-rebuild/05-workplan.md): moved out of
// run_job.cpp unchanged, line for line. This is NOT a translation unit: it is
// included by run_job.cpp at the place the code used to stand, inside
// namespace topopt, so every name resolves exactly as before. Do not compile
// it on its own and do not include it anywhere else.

AnalyzeJobResult analyze_job(const JobDescription& job, const std::string& job_dir,
                             const std::string& out_dir,
                             const MaterialLibrary& materials,
                             const SettingsRules& rules,
                             const std::string& analyze_mesh_path,
                             const SmoothRequest& smooth) {
  // E1 (f) — "PRINT IT THIS WAY": the version's exported file re-checked along a new
  // build direction, without re-optimizing: one analysis solve with the interlayer
  // knockdown along the NEW Z, the overhang area that would need support (and the
  // baseline direction's, from the same file), the verdict and a plain reason.
  if (job.has_orientation_recheck) {
    JobDescription j = job;
    j.has_orientation_recheck = false;
    const Vec3 base_dir = job.loads.present ? job.loads.build_dir
                          : job.has_build_direction ? job.build_direction
                                                    : Vec3{0.0, 0.0, 1.0};
    j.has_build_direction = true;
    j.build_direction = job.orientation_recheck_dir;
    if (j.loads.present) j.loads.build_dir = job.orientation_recheck_dir;
    // The mesh path stays relative to job_dir, as analyze_job takes it, and the file
    // is read for the overhang through the same import (STL or 3MF).
    const std::string rel =
        analyze_mesh_path.empty() ? job.orientation_recheck_mesh : analyze_mesh_path;
    AnalyzeJobResult r = analyze_job(j, job_dir, out_dir, materials, rules, rel, smooth);
    TriangleMesh m;
    try {
      m = import_part_file_resolved(join_path(job_dir, rel)).mesh;
    } catch (const std::exception& e) {
      throw JobError(std::string("orientation re-check: cannot read the mesh: ") + e.what());
    }
    const Overhang now = overhang_of(m, job.orientation_recheck_dir);
    const Overhang base = overhang_of(m, base_dir);
    const FixedDesignAnalysis& a = r.analysis;
    auto x = [](double v) {
      char b[32];
      std::snprintf(b, sizeof b, "%.2f", v);
      return std::string(b) + "\u00D7";
    };
    char area[64];
    std::snprintf(area, sizeof area, "%.0f mm\u00B2 needs support", now.area_mm2);
    std::string reason;
    if (a.accepted)
      reason = "Strong enough printed this way: " + x(a.margin_effective) + " (needs " +
               x(r.margin_required) + "); " + area;
    else if (a.margin.interlayer <= a.margin.in_plane)
      reason = "Printed this way the layers would split: " + x(a.margin_effective) + " (needs " +
               x(r.margin_required) + ")";
    else
      reason = "Printed this way it is not strong enough: " + x(a.margin_effective) +
               " (needs " + x(r.margin_required) + ")";
    auto v3 = [](const Vec3& v) {
      return "[" + json_num(v.x) + ", " + json_num(v.y) + ", " + json_num(v.z) + "]";
    };
    // P5, his "Check strength" (spec 2d): the part standing each way, as the benefits modal compares them (both MEASURED
    // on the file): its height and layers, the face on the bed, the part's own overhangs painted (the 45 degree rule: a
    // topology result has no layer check) with the support under them (an estimate), and, along the new up, the file
    // itself turned to stand on that face (base at z = 0) and painted: "oriented.3mf" (an up along one of the part's
    // six axes; Phase 1). Nothing here changes the solve or the verdict above.
    const double layer_h = job.loads.layer_height_mm > 0.0 ? job.loads.layer_height_mm : 0.2;
    std::string oriented_file;
    const auto standing = [&](const Vec3& up_dir, bool write) {
      PrintFrame pf;
      std::string why;
      if (!print_frame_for_up(up_dir, pf, &why)) return std::string(", \"standing\": null");
      TriangleMesh tm = m;
      print_frame_set_base(pf, tm);
      turn_mesh(pf, tm);
      // Phase 2 (his "edges held by supports"): standing on an edge, the stand supports cut in and painted first.
      std::string stand_json;
      StandPaint stand;
      {
        OrientationCandidates cs = print_candidates(tm);
        if (!cs.list.empty() && cs.list.front().kind == OrientationCandidate::Kind::Edge) {
          OrientationCandidate& c0 = cs.list.front();
          orientation_stand(c0, mesh_centroid(tm));
          if (c0.stands) stand = paint_stand_supports(tm, 0, c0);
          stand_json = ", \"stand\": {\"rests_on\": \"edge\", \"stands\": " + std::string(c0.stands ? "true" : "false") +
                       ", \"band_mm\": [" + json_num(c0.band1_mm) + ", " + json_num(c0.band2_mm) + "], \"triangles\": " +
                       std::to_string(stand.triangles) + ", \"area_mm2\": " + json_num(stand.area_mm2) +
                       ", \"est_volume_mm3\": " + json_num(c0.stand_support_mm3) + "}";
        }
      }
      SupportPaintAsk pa;
      pa.layer_mm = layer_h;
      const SupportPaint sp = paint_supports(tm, pa);
      const OrientationGeometry g = orientation_geometry(tm)[0];   // +Z of the turned mesh: the new up
      std::string file = "null";
      if (write) {
        const std::string path = join_path(out_dir, "oriented.3mf");
        try {
          StreamingThreeMfWriter::Options o;
          o.indexed = true;
          o.deflate = true;
          o.supports = sp.triangles > 0 || stand.triangles > 0;
          StreamingThreeMfWriter w(path, o);
          for (const Vec3& v : tm.vertices) w.add_vertex(v);
          for (std::size_t i = 0; i < tm.triangles.size(); ++i)
            w.add_indexed(static_cast<std::uint64_t>(tm.triangles[i][0]), static_cast<std::uint64_t>(tm.triangles[i][1]),
                          static_cast<std::uint64_t>(tm.triangles[i][2]),
                          o.supports && (sp.painted[i] != 0 || (i < stand.painted.size() && stand.painted[i] != 0)));
          w.finish();
          oriented_file = path;
          file = json_str("oriented.3mf");
        } catch (const std::exception& e) {
          std::remove(path.c_str());
          throw JobError(std::string("orientation re-check: cannot write oriented.3mf: ") + e.what());
        }
      }
      return ", \"standing\": {\"height_mm\": " + json_num(g.height_mm) + ", \"layers\": " +
             json_num(std::ceil(g.height_mm / layer_h - 1e-9)) + ", \"layer_mm\": " + json_num(layer_h) +
             ", \"bed_contact_mm2\": " + json_num(g.contact_mm2) + ", \"painted\": {\"triangles\": " +
             std::to_string(sp.triangles) + ", \"area_mm2\": " + json_num(sp.area_mm2) + ", \"est_volume_mm3\": " +
             json_num(sp.est_volume_mm3) + "}" + stand_json + ", \"slicer_supports\": " +
             json_str(sp.triangles > 0 || stand.triangles > 0 ? "painted" : "off") +
             ", \"file\": " + file + ", \"print_frame\": " + print_frame_json(pf) + "}";
    };
    const std::string now_standing = standing(job.orientation_recheck_dir, true);
    const std::string base_standing = standing(base_dir, false);
    const std::string block =
        "  \"orientation_recheck\": {\"build_dir\": " + v3(job.orientation_recheck_dir) +
        ", \"margin\": " + json_num(a.margin_effective) +
        ", \"interlayer_margin\": " + json_num(a.margin.interlayer) +
        ", \"margin_required\": " + json_num(r.margin_required) +
        ", \"accepted\": " + (a.accepted ? "true" : "false") +
        ", \"overhang_area_mm2\": " + json_num(now.area_mm2) +
        ", \"support_volume_mm3\": " + json_num(now.support_volume_mm3) + now_standing +
        ", \"reason\": " + json_str(reason) + ", \"baseline\": {\"build_dir\": " +
        v3(base_dir) + ", \"overhang_area_mm2\": " + json_num(base.area_mm2) + base_standing + "}}\n";
    std::ifstream in(r.provenance_path);
    std::string prov((std::istreambuf_iterator<char>(in)), {});
    const std::size_t end = prov.rfind("\n}");
    if (end != std::string::npos) {
      prov = prov.substr(0, end) + ",\n" + block + "}\n";
      write_text_file(r.provenance_path, prov);
    }
    r.orientation_recheck_reason = reason;
    r.orientation_recheck_overhang_mm2 = now.area_mm2;
    r.orientation_recheck_baseline_overhang_mm2 = base.area_mm2;
    r.orientation_recheck_file = oriented_file;   // P5: the file to print, standing that way
    return r;
  }
  refuse_flexible_job(job, "analyze_job");  // Flexible stage (flexible/job_block.hpp)
  const auto mat_it = materials.find(job.material);
  if (mat_it == materials.end())
    throw JobError("material \"" + job.material +
                   "\" is not in the material library");
  const Material& material = mat_it->second;

  AnalyzeJobResult result;

  // ── import the ORIGINAL model (the BCs are keyed on ITS anchor/fixture faces) ─
  const std::string model_path = join_path(job_dir, job.model);
  const bool model_is_mesh =
      part_format_for_path(job.model) != PartFormat::Step;
  try {
    result.model = import_part_file_resolved(model_path);
  } catch (const std::exception& e) {
    throw JobError(std::string("analyze: cannot import model: ") + e.what());
  }
  if (!check_watertight(result.model.mesh).watertight)
    throw JobError("analyze: model tessellation is not watertight: " + job.model);

  // ── the model grid + BCs + production options, MODE-SPECIFIC ──────────────────
  // A declared "loads" block re-certifies the design under that EXTERNAL load; no
  // "loads" block is the self-weight path (unchanged). Both establish the same
  // downstream contract: `model_grid` (fixture/anchor node indices + part-solid
  // baseline), `bcs`, and `options` (production solver config + gravity/build
  // orientation + margin_stop). The single certification tail below is shared.
  VoxelGrid model_grid;
  std::vector<DirichletBC> bcs;
  MinimizePlasticOptions options;
  const bool loadcase = job.loads.present;
  // loadcase only: the distributed tractions from the declared force groups are
  // computed on the model faces up front (INDEPENDENT of the fixed design's
  // internal geometry — a substitute/smoothed design changes no external load)
  // and ride on `options.external_loads`; the certification below takes them from
  // design_domain_loads, which is also where they get remapped onto an expanded
  // grid. They are no longer copied aside here — one place held them, one place
  // reads them.
  // loadcase only: the LOAD faces, frozen (alongside the anchors) when smoothing so
  // the traction stays attached to bit-identical solid. Empty in self-weight mode
  // (byte-identical). Without this a smoothed load cap erodes and the traction lands
  // on a void DOF ("under-constrained system") — the S3 specimen hits exactly that.
  std::vector<int> load_freeze_face_ids;

  if (loadcase) {
    // The SAME front-end-neutral mapping + core builder the optimizer's loadcase
    // path uses (production_loadcase_from_job → build_production_loadcase), so a
    // declared load case is resolved identically whether it is optimized or merely
    // analyzed. The anchors become the Dirichlet BCs (or the min-x fallback the
    // builder applies when none are declared); each force group becomes a
    // distributed traction; the production margin (default 1.5) + gravity/build
    // orientation come back on `options`.
    const ProductionLoadCase lc =
        production_loadcase_from_job(job, result.model);
    result.fixture_face_ids = lc.anchor_face_ids;
    ProductionRunSetup setup;
    try {
      setup = build_production_loadcase(result.model, job.resolution, lc);
    } catch (const JobError&) {
      throw;  // already a clean, loud job diagnostic (e.g. a selector match miss)
    } catch (const std::exception& e) {
      // A raw anchor/load face id outside the model's face set reaches here as
      // the builder's legible out-of-range diagnostic (validate_face_id names
      // the id, the count and which selection it came from). The wrap adds the
      // ONE fact the builder cannot know: WHICH mesh the ids were resolved
      // against (L5 + N5: a declared load referencing a face that does not
      // exist must fail loudly, naming id / count / mesh).
      throw JobError(std::string("analyze: cannot build the declared load "
                                 "case against model \"") +
                     job.model + "\": " + e.what());
    }
    // L5 — NEVER silently fall back to self-weight. When the job declared load
    // groups but every one was zero-force or tagged no voxels at this resolution,
    // the builder arms require_external_loads and leaves external_loads empty.
    // The optimizer would refuse in minimize_plastic; the analyze path never runs
    // the optimizer, so it must refuse HERE — analyzing under self-weight instead
    // of the declared load is exactly the silent-degradation bug (PR 178).
    if (setup.options.require_external_loads &&
        setup.options.external_loads.empty())
      // The refusal stays as LOUD as before; the per-group reports make it
      // legible — WHICH group resolved to nothing and WHY (N4), instead of the
      // old "every force group was zero-force or tagged no voxels" that named
      // neither.
      throw JobError(
          "analyze: the declared load case produced NO external load — " +
          no_external_load_message(setup, job.resolution) +
          ". Refusing to analyze under SELF-WEIGHT instead of the declared "
          "load (that silent fallback is the PR-178 param-drop bug).");
    model_grid = std::move(setup.grid);
    bcs = std::move(setup.bcs);
    options = std::move(setup.options);
    for (const ProductionLoadCase::LoadGroup& g : lc.load_groups)
      for (const int fid : g.face_ids) load_freeze_face_ids.push_back(fid);
  } else {
    // ── SELF-WEIGHT path (unchanged): voxelize + tag the fixture faces, clamp
    // their nodes, and apply the production config + the job's gravity/margin.
    // The fixture NODE indices and the part-solid count are geometry, so we take
    // them from the model grid and reuse them for any same-geometry design.
    model_grid = voxelize(result.model.mesh, job.resolution);
    result.fixture_face_ids =
        resolve_selectors(result.model, job.fixture_faces, "fixture_faces");
    std::size_t tagged = 0;
    for (const int f : result.fixture_face_ids)
      tagged += to_stage1_on()
                    ? tag_face_by_stage(model_grid, result.model, f, VoxelTag::Fixture)
                    : model_is_mesh
                        ? tag_mesh_face(model_grid, result.model, f, VoxelTag::Fixture)
                        : tag_step_face(model_grid, result.model, f, VoxelTag::Fixture);
    if (tagged == 0)
      throw JobError(
          "analyze: fixture faces tagged no voxels (resolution too coarse "
          "for the selected faces?)");
    for (const int n : fea_tagged_nodes(model_grid, VoxelTag::Fixture))
      for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});
    configure_production_options(options);
    options.material_catalog = &materials;  // gate diagnosis, READ ONLY (see above)
    options.margin_stop = job.margin_stop;
    options.gravity = job.gravity.magnitude_mm_s2 * kGramPerCm3ToTonnePerMm3;
    options.gravity_direction = job.gravity.direction;
  }
  // The build-plate normal, separated from gravity (handoff
  // 2026-08-01-build-direction-separation). AFTER the mode branch so it governs
  // both modes; absent key => byte-identical.
  apply_build_direction_options(options, job);
  // Optional design-domain expansion. The loadcase branch already carries it on
  // `options` (build_production_loadcase forwards the job's box); the
  // self-weight branch did not, so it is set here — a re-analysis that dropped
  // the box would silently certify a TRUNCATED design (task
  // 2026-08-03-design-box-recertification, bar AI5).
  if (job.has_design_box && !options.design_box.has_value()) {
    options.design_box = to_design_box(job.design_box);
    for (const JobBox& ko : job.keep_out_boxes)
      options.keep_out_boxes.push_back(to_design_box(ko));
  }
  // THE domain the originating run solved on — the SAME core call it used, so a
  // smoothed design-box variant is re-certified on the grid it was produced on
  // and under the load case that produced it, rather than clipped back onto the
  // part grid. Without a design box `domain.grid` IS `model_grid` and
  // `domain.bcs` IS `bcs`, so every existing analyze run is byte-identical.
  const SolvedDesignDomain domain = resolve_design_domain(model_grid, bcs, options);
  // *** THE EXPANSION IS ONLY FOR A SUBSTITUTE MESH. *** The expanded grid exists
  // to hold a DESIGN that grew outside the imported part. A `--mesh` analyze is
  // handed such a design and must be voxelized onto it, or the material outside
  // the part is silently clipped away. A NO-MESH analyze is not: it certifies
  // the imported part AS DRAWN, and its occupancy comes from the grid's own tags
  // — and expand_design_domain tags the whole in-box Active region `Interior`,
  // i.e. SOLID. Certifying on the expanded grid there would certify a FILLED
  // BOX rather than the part, which is what RUN SIM and every non-smoothing
  // re-certification ask for. So the no-mesh path keeps the model grid, exactly
  // as it did before this task. Asserted, not argued: a design-box no-mesh
  // analyze must report the same solid count and mass as the same analyze with
  // no design box (test_designbox_lattice_recert, section E).
  const bool expand_for_mesh = domain.expanded && !analyze_mesh_path.empty();
  const VoxelGrid& cert_grid = expand_for_mesh ? domain.grid : model_grid;
  const std::vector<DirichletBC>& cert_bcs = expand_for_mesh ? domain.bcs : bcs;
  // The PART's solid count — the part-relative denominator, which under
  // expansion is NOT the solved grid's solid count (handoff 080).
  const double part_solid = static_cast<double>(model_grid.solid_count());

  // ── the FIXED design to analyse (its OWN occupancy grid) ─────────────────────
  // `design_grid` carries the solid tags of the geometry being certified (so the
  // stress solve's printed-voxel gate matches it and self-weight is the design's
  // own weight); `density` is that occupancy as a binary field. Same voxel geometry
  // as `cert_grid`, so the fixture node indices above stay valid.
  if (smooth.enabled && analyze_mesh_path.empty())
    throw JobError("analyze: --smooth requires a --mesh input to smooth");

  VoxelGrid design_grid = cert_grid;
  // The smoothed mesh, held until the applied build orientation is known (see
  // below). Empty unless --smooth ran.
  TriangleMesh pending_smoothed_mesh;
  if (!analyze_mesh_path.empty()) {
    StepModel edited;
    try {
      edited = import_part_file_resolved(join_path(job_dir, analyze_mesh_path));
    } catch (const std::exception& e) {
      throw JobError(std::string("analyze: cannot import analyze mesh: ") +
                     e.what());
    }

    // ── CONSTRAINED SMOOTHING (handoff 2026-07-26-constrained-smooth-ui) ───────
    // Smooth the input mesh BEFORE re-voxelizing, so everything below re-certifies
    // the SMOOTHED geometry (the honesty rule: the numbers shown always describe
    // what is exported). Frozen vertices come from the model's B-rep fixture faces
    // (bores + pads) AND — in loadcase mode — the LOAD faces, so both the clamp and
    // the traction stay attached to bit-identical solid across the re-voxelization
    // (without the load faces frozen, smoothing erodes the loaded cap and the
    // traction lands on a void DOF). The min-feature constraint is evaluated against
    // cert_grid — the run's SOLVED grid, so under a design box it covers the
    // material the optimizer grew outside the part instead of stopping at the
    // part's bounding box. Same spacing and same voxel lattice either way, so a
    // no-box run measures exactly what it measured before.
    TriangleMesh design_mesh = edited.mesh;
    if (smooth.enabled) {
      const TaubinParams params =
          taubin_params_for_strength(smooth.strength, smooth.max_pairs);
      SmoothConstraints c;
      std::vector<int> freeze_face_ids = result.fixture_face_ids;
      freeze_face_ids.insert(freeze_face_ids.end(),
                             load_freeze_face_ids.begin(),
                             load_freeze_face_ids.end());
      c.freeze_regions = freeze_regions_from_faces(
          result.model, freeze_face_ids, cert_grid.spacing);
      c.freeze_tol_mm = smooth.freeze_tol_mm;
      c.min_feature_grid = &cert_grid;
      c.enforce_min_feature = smooth.enforce_min_feature;
      SmoothResult sr = constrained_taubin_smooth(edited.mesh, params, c);
      design_mesh = std::move(sr.mesh);
      result.smoothed = true;
      result.smooth_strength = smooth.strength;
      result.smooth_stats = sr.stats;
      // Export the smoothed mesh (task item 5): <analyze_mesh basename>_smoothed.stl.
      {
        std::error_code ec;
        std::filesystem::create_directories(out_dir, ec);
        if (ec)
          throw JobError("analyze: cannot create output directory " + out_dir +
                         ": " + ec.message());
      }
      const std::string stem =
          std::filesystem::path(analyze_mesh_path).stem().string();
      result.smoothed_mesh_path = join_path(out_dir, stem + "_smoothed.stl");
      // DEFERRED (handoff 2026-08-01-bake-build-orientation). This file is the
      // geometry this run certifies, so it is an EXPORT and must carry the
      // certified orientation like every other one — and the applied orientation
      // is not known until the analysis below has run. The mesh is held and
      // written after it; the path and (off the bake path) the bytes are
      // unchanged.
      pending_smoothed_mesh = design_mesh;
    }

    // Re-voxelize the (smoothed) mesh onto the MODEL's grid geometry, then carry the
    // model's Fixture (clamp) and Load (traction) tags over. The Fixture clamp is
    // carried only where the substitute still has material. The LOAD surface is
    // FORCED solid — the declared traction is applied to a mounting interface that is
    // implicitly FrozenSolid the same way the optimizer retains load faces, so the
    // force always has stiffness even where an aggressive smooth eroded the loaded
    // cap (otherwise the solve hits a void DOF — no equilibrium). This restores
    // exactly the loaded face the traction was declared on; the load-bearing BODY
    // (the ribs) still erodes and still lowers the margin. In self-weight mode
    // `cert_grid` carries no Load tags, so this is byte-identical to carrying
    // Fixture alone. The quantization gap (mesh surface vs this voxelization) is
    // disclosed below.
    //
    // The target is `cert_grid`, the run's SOLVED grid: under a design box the
    // mesh being re-certified EXTENDS BEYOND the imported part, and voxelizing it
    // onto the part grid would silently CLIP the material the optimizer grew and
    // certify a smaller object than the file it describes. expand_design_domain
    // preserves the part's Fixture/Load tags at the domain offset, so the tag
    // carry-over below reads the same tags it always did.
    design_grid = voxelize_onto_grid(design_mesh, cert_grid);
    for (std::size_t i = 0; i < design_grid.tags.size(); ++i) {
      if (cert_grid.tags[i] == VoxelTag::Load) {
        // When WE smoothed, the loaded cap is restored solid (see above). For a raw
        // substitute mesh (no smoothing) keep 228's contract — certify what was
        // handed in, carrying the Load tag only where the mesh has material — so the
        // non-smoothed loadcase analyze stays byte-identical (bar S6).
        if (smooth.enabled) design_grid.tags[i] = VoxelTag::Load;
        else if (design_grid.tags[i] != VoxelTag::Empty)
          design_grid.tags[i] = VoxelTag::Load;
      } else if (design_grid.tags[i] != VoxelTag::Empty &&
                 cert_grid.tags[i] == VoxelTag::Fixture) {
        design_grid.tags[i] = VoxelTag::Fixture;
      }
    }
    result.analyzed_mesh = true;
    result.analyzed_mesh_path = analyze_mesh_path;
    result.mesh_mass_grams =
        material.density_g_cm3 * mesh_enclosed_volume_mm3(design_mesh) / 1000.0;
  }
  std::vector<double> density(design_grid.voxel_count(), 0.0);
  for (std::size_t i = 0; i < density.size(); ++i)
    if (design_grid.tags[i] != VoxelTag::Empty) density[i] = 1.0;

  // ── the certification load case (production config already on `options`) ─────
  // The production solver config + margin + gravity/build orientation were set on
  // `options` in the mode branch above (build_production_loadcase in loadcase mode,
  // configure_production_options in self-weight mode). Here we only pick the loads:
  //   * loadcase   — the declared EXTERNAL tractions, fixed on the model faces
  //                  (independent of the fixed design's internal geometry);
  //   * self-weight — the DESIGN's own weight, recomputed on `design_grid` so a
  //                  substitute/smoothed design carries its own mass.
  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;  // ARCHITECTURE §4 (density_min stays the 1e-3 default)

  // THE ONE resolver (handoff 2026-08-01-build-direction-separation) — the third
  // and last of the sites that used to derive this from gravity independently.
  // A standalone re-analysis of a part now certifies against the orientation the
  // originating run used, because both ask the same function.
  const Vec3 build_dir = resolve_build_direction(options);
  // THE ONE BAKE DECISION for this re-analysis (handoff
  // 2026-08-01-bake-build-orientation) — the same function the optimize path
  // asks, so a part re-certified later is placed the same way the run that
  // produced it placed it.
  const BuildOrientationBakePlan bake_plan = resolve_bake_plan(options);
  const bool score_orientations =
      options.build_orientation_report || bake_plan.needs_scorer;
  // loadcase: THE ONE definition (design_domain_loads), which returns the
  // declared tractions REMAPPED onto the solved grid — the remap this path also
  // lacked under a design box. self-weight: DELIBERATELY the design's OWN weight
  // on `design_grid` (a substitute/smoothed design carries its own mass), which
  // is why this branch is not design_domain_loads — that would weigh the run's
  // occupancy, not this design's.
  const std::vector<NodalLoad> loads =
      loadcase ? (expand_for_mesh
                      // the declared tractions REMAPPED onto the expanded grid
                      // the substitute mesh was voxelized onto
                      ? design_domain_loads(domain, options,
                                            material.density_g_cm3)
                      // no mesh (or no box): the analysis runs on the MODEL grid,
                      // where the declared tractions are already correctly
                      // indexed — remapping them here would point them at nodes
                      // of a grid this branch never uses
                      : options.external_loads)
               : self_weight_loads(design_grid, material.density_g_cm3,
                                   options.gravity, options.gravity_direction);
  const bool load_path_ok = load_path_connected(design_grid, density, 0.5);
  // The gate knockdown posture (handoff 2026-07-26-width-aware-knockdown), built
  // from the SAME options the originating run used so a standalone re-analysis gates
  // on the identical rule. THE ONE builder (knockdown_spec_for) — shared with the
  // optimizer's per-rung gate and the on-device bridge so all three agree by
  // construction. width_aware defaults false → the scalar f^1.5 gate.
  // TO rebuild stage 2 (see to_setup.inc); set here, after the load case has
  // replaced the options.
  if (strength_mode() == StrengthMode::Size)
    options.stress_reading_mm = reading_size_for_job_mm(job.material);
  const KnockdownSpec knockdown = knockdown_spec_for(options);

  // ── THE single analysis solve — no optimization ─────────────────────────────
  auto certify_one = [&](const std::vector<DirichletBC>& cbcs,
                         const std::vector<NodalLoad>& cloads) {
    return analyze_fixed_design(
      design_grid, params, density, cbcs, cloads, material, build_dir,
      options.simp.cg_tolerance, options.simp.cg_max_iterations,
      options.simp.solver, options.margin_stop, knockdown, load_path_ok,
      part_solid, /*lattice=*/nullptr,
      // The re-analysis ranks the SAME candidate set the originating run did
      // (build_orientation_candidates is derived inside analyze_fixed_design),
      // so a part's recommendation cannot change just because it was re-analysed.
      score_orientations, resolve_build_direction_is_inferred(options),
      bake_plan.auto_apply);
  };
  // LOAD SCENARIOS (rulings 2026-10-26 03:45 and 12:46): EVERY scenario certified on
  // this design (the export, for strengthen's verify), the worst governs. Their supports
  // and loads on the certified grid (the design box's when a mesh was voxelized onto
  // it), the weak springs sized for the material. One load case: the one solve, as
  // always.
  const std::vector<SimpScenario> cert_scenarios =
      loadcase && !options.scenarios.empty()
          ? sized_scenarios(expand_for_mesh ? domain.scenarios : options.scenarios,
                            material.youngs_modulus_mpa, cert_grid.spacing)
          : std::vector<SimpScenario>();
  std::vector<ScenarioFields> an_scenario_fields;
  if (cert_scenarios.empty()) {
    result.analysis = certify_one(cert_bcs, loads);
  } else {
    // ★ E2.1: a graded lattice grades from the worst of the scenarios it uses, so
    // their fields are kept when there is one to grade.
    ScenarioCertification sc =
        certify_scenarios(design_grid, cert_scenarios, certify_one,
                          /*keep_fields=*/job.lattice.present && job.grading.present);
    result.analysis = std::move(sc.governing);
    an_scenario_fields = std::move(sc.fields);
    result.scenarios = std::move(sc.reports);
    result.unheld_scenario = std::move(sc.unheld);
  }
  const FixedDesignAnalysis& a = result.analysis;
  // The orientation this re-analysis certifies, and the rotation the exported
  // geometry carries (empty when the export stays in model coordinates).
  const Vec3 applied_build_dir = a.applied_build_dir;
  std::optional<BuildFrameRotation> analyze_bake;
  if (bake_plan.bake) analyze_bake = build_frame_rotation(applied_build_dir);
  result.voxel_mass_grams = a.mass_grams;
  result.voxel_mass_solid_grams = a.mass_grams_solid;  // TO rebuild stage 2

  {
    std::error_code ec;
    std::filesystem::create_directories(out_dir, ec);
    if (ec)
      throw JobError("analyze: cannot create output directory " + out_dir + ": " +
                     ec.message());
  }

  // ── the SMOOTHED mesh export, now that the certified orientation is known ────
  // (handoff 2026-08-01-bake-build-orientation.) This is the geometry the run
  // certifies, so it is baked exactly like the optimize path's variant meshes.
  // Off the bake path the bytes are what write_stl_file produced before.
  if (!result.smoothed_mesh_path.empty())
    write_stl_file(result.smoothed_mesh_path,
                   analyze_bake ? rotate_mesh(pending_smoothed_mesh, *analyze_bake)
                                : pending_smoothed_mesh);

  // ── the LATTICE GRADING LAW (handoff 2026-07-29-lattice-grading-law) ─────────────
  // When a "grading" block is present, feed the certification's von Mises field to the
  // grading law: it produces a per-voxel density + one uniform cell size, clamped to
  // the certifiable band and the cells-per-member floor it READS from core, and leaves
  // members too thin to grade SOLID (bar L4). The full report is written to run_info's
  // "grading" object. Absent -> this block is skipped, no run_info is written, and the
  // analyze path is byte-identical (bar L1).
  if (job.grading.present) {
    GradingLawParams gp;
    gp.topology = lattice_topology_from_id(job.grading.topology);  // the job's type
    gp.target_cell_size_mm = job.grading.cell_mm;
    gp.min_extrudable_width_mm = job.grading.min_extrudable_width_mm;
    gp.demand_exponent = job.grading.demand_exponent;
    gp.organic_geometry =
        resolve_lattice_algorithm(job.grading) == LatticeAlgorithm::Organic;
    // Cell-size mode; an absent "cell_mode" parses as "fixed" — the pre-sweep path.
    if (!resolve_cell_mode(job.grading.cell_mode, gp.cell_mode))
      throw JobError("analyze: unknown grading cell_mode \"" +
                     job.grading.cell_mode + "\"");
    gp.min_cell_size_mm = job.grading.cell_min_mm;
    gp.max_cell_size_mm = job.grading.cell_max_mm;
    // ── ★ ABSOLUTE UTILISATION, ARMED ON THE LATTICE-ONLY PATH (task
    //    2026-08-20-lattice-only-grading, §0 / §2 / §3) ──────────────────────────
    // ★ THIS BLOCK IS WHY §5(a) HOLDS STRUCTURALLY. `analyze` is the LATTICE-ONLY
    // path — a part latticed with NO topology optimisation, which is what RUN SIM
    // drives. The TO+lattice path is `minimize_plastic`, a different function, and
    // it never reaches this code: `demand_allowable_mpa` is left at its 0.0 default
    // there, which is the peak-relative law byte-for-byte. The scoping is therefore
    // a property of WHERE the field is set, not a promise in a comment.
    //
    // ★ WHICH ALLOWABLE (bar R9): the IN-PLANE one, yield / margin_stop, with the
    // z knockdown NOT in it. The demand field is von Mises — an in-plane measure —
    // and the gate's in-plane margin is yield / von Mises, so utilisation 1.0 means
    // exactly "in-plane margin == margin_stop". The knockdown belongs to the
    // interlayer mode, priced from a different field, and folding an unsourced
    // constant into every density would be worse than leaving it where the gate
    // already applies it. The interlayer check is untouched.
    gp.demand_allowable_mpa = material.yield_strength_mpa / options.margin_stop;
    // ★ THE GOAL IS THE USER'S EXISTING CHECKBOX (§3c) — no second control.
    // ON  = "use as little plastic as possible" -> work the whole allowable.
    // OFF = "make a sturdy model regardless of extra plastic" -> stop at a stated
    //       fraction of it, so the same field buys more material.
    gp.utilisation_target = job.loads.present && !job.loads.minimize_plastic
                                ? kSturdyUtilisationTarget
                                : 1.0;
    gp.unloaded_utilisation_max = kUnloadedUtilisationMax;
    // ── ★ THE INTENT (amendment §1d) ─────────────────────────────────────────
    // ★ AESTHETIC IS THE DEFAULT **HERE**, on the lattice-only job — not in
    // GradingLawParams, where every caller would inherit it and the TO+lattice and
    // multiscale paths would silently change. An absent "intent" key means the
    // common case: a lattice the user wants to SEE, on a part that usually does not
    // need one structurally.
    if (job.grading.intent.empty()) {
      gp.intent = GradingIntent::Aesthetic;
    } else if (!grading_intent_from_name(job.grading.intent.c_str(), gp.intent)) {
      throw JobError("analyze: unknown grading intent \"" + job.grading.intent + "\"");
    }
    gp.aesthetic_percentile = job.grading.aesthetic_percentile;
    gp.aesthetic_rho_min = job.grading.aesthetic_rho_min;
    gp.aesthetic_rho_max = job.grading.aesthetic_rho_max;
    gp.max_relative_density = job.grading.max_relative_density;
    gp.aesthetic_adaptive_cells_per_member =
        job.grading.aesthetic_adaptive_cells_per_member;
    gp.aesthetic_error_budget = job.grading.aesthetic_error_budget;
    // ★★ IS A BOUNDARY FINISH WRITTEN? This is what lets the adaptive floor reach ONE
    // cell per member (lattice.hpp states the measurement). A finish exists unless the
    // export is the BARE lattice — `outer_finish: "skin"` drops the solid shell, and
    // for organic `grading.organic_boundary_finish: "clean"` then emits nothing at all
    // on the surface either. Any other combination writes a shell, a skin, a rim or a
    // diagrid, and any of those re-ties the struts trimming severed.
    {
      const bool shell_written = lattice_shell_written(job.lattice);
      const bool surface_net =
          job.grading.algorithm == "organic"
              ? job.grading.organic_boundary_finish != "clean"
              : job.lattice.skin != "none";
      gp.boundary_finish_written = shell_written || surface_net;
    }
    // FIT needs the per-region derivation here too, or the analyze receipt would
    // describe a cell law the run never used. `nullptr` region below means the
    // candidate set is the whole printed design, so voxels outside every declared
    // include region get no derived cell and stay solid — which grade_lattice counts
    // as `fit_no_derivation_voxels` rather than guessing a cell for them.
    std::vector<FitRegionCell> fit_cells;
    std::vector<double> fit_field;
    std::vector<double> an_rho_field;
    LatticeRoleRegions an_roles;
    if (gp.cell_mode == CellSizeMode::Fit) {
      an_roles = lattice_role_regions_from_job(job, &result.model, &model_grid);
      fit_cells = fit_region_cells(job, gp.topology,
                                   job.grading.min_extrudable_width_mm,
                                   &an_roles);
      if (fit_cells.size() != an_roles.includes.size())
        throw JobError(
            "analyze: fit derivation and the resolved include regions disagree on "
            "how many regions this job has");
      fit_field = fit_cell_field(design_grid, an_roles.includes, fit_cells);
      gp.fit_cell_size_mm = &fit_field;
      an_rho_field = region_density_field(design_grid, an_roles.includes, fit_cells);
      gp.region_relative_density = &an_rho_field;
    }
    // ★ THE ALGORITHM (task 2026-08-21-organic-lattice, §4). Resolved BEFORE the law
    // runs, so an organic + structural job is refused before it spends a solve on a
    // density it is not allowed to certify.
    const LatticeAlgorithm an_alg = resolve_lattice_algorithm(job.grading);
    refuse_organic_structural(an_alg, job.grading);
    // ★ E2.1: graded from the worst of the scenarios the lattice uses.
    const std::vector<char> an_scen_on = lattice_scenario_flags(job, cert_scenarios);
    std::vector<double> an_vm_storage;
    const std::vector<double>& an_vm =
        lattice_grading_stress(a.von_mises_field, result.scenarios, an_scenario_fields,
                               an_scen_on, an_vm_storage, nullptr);
    const GradedField gf = grade_lattice(design_grid, density, an_vm, nullptr, gp);

    // ★ ORGANIC. The grading law above chose the DENSITY (all three algorithms honour
    // the same intent, §4b); this turns that density into a spacing field and traces.
    // Doubled and stepped skip it entirely, so their receipts are unchanged.
    // STEPPED needs the per-voxel region membership; on the analyze path the
    // candidate set is the whole printed design (region == nullptr above), so the ids
    // are built here from the same declared regions the geometry path uses.
    SteppedOutcome an_step;
    bool an_synthetic = false;
    for (const JobLatticeRegion& rg : job.lattice.regions)
      if (rg.role == "include" && rg.synthetic_stress) an_synthetic = true;
    std::vector<int> an_ids;   // per-voxel include-region ids, when a consumer needs them
    if (an_alg == LatticeAlgorithm::Stepped ||
        (an_alg == LatticeAlgorithm::Organic && an_synthetic)) {
      const LatticeRoleRegions sr =
          lattice_role_regions_from_job(job, &result.model, &model_grid);
      std::vector<int> ids(design_grid.voxel_count(), 0);
      for (int k = 0; k < design_grid.nz; ++k)
        for (int j = 0; j < design_grid.ny; ++j)
          for (int i = 0; i < design_grid.nx; ++i) {
            const std::size_t e = design_grid.index(i, j, k);
            if (!gf.posture.mask[e]) continue;
            const Vec3 c{design_grid.origin.x + (i + 0.5) * design_grid.spacing,
                         design_grid.origin.y + (j + 0.5) * design_grid.spacing,
                         design_grid.origin.z + (k + 0.5) * design_grid.spacing};
            // the OWNER rule (ruling 4): nearest face plane, tie to the lower id, never declaration order.
            ids[e] = stepped_region_owner(c, sr.includes);
          }
      an_ids = ids;
      if (an_alg == LatticeAlgorithm::Stepped)
        an_step = run_stepped_step(design_grid, density, gf.posture.mask,
                                   gf.posture.relative_density, ids, job.grading, 0.5,
                                   gp.thickness_cap_voxels);
    }
    OrganicOutcome an_org;
    SyntheticStressReport an_synth_rep;
    const std::vector<double> an_stress =
        an_alg == LatticeAlgorithm::Organic
            ? stress_tensor_for_organic(job, design_grid, gf.posture.mask, an_ids,
                                        a.stress_tensor_field, &an_synth_rep)
            : std::vector<double>();
    if (an_alg == LatticeAlgorithm::Organic)
      an_org = run_organic_step(lattice_shell_written(job.lattice),
                                design_grid, density, an_stress,
                                gf.posture.mask, gf.posture.relative_density,
                                gf.band_rho_min, gf.band_rho_max, job.grading,
                                job.loads.present && job.loads.minimize_plastic,
                                applied_build_dir, 0.5, gp.thickness_cap_voxels,
                                job.loads.layer_height_mm);
    // ★ THE WELD'S RASTER PITCH, so the generator can refuse to emit a base mat too
    // thin for that raster to KEEP. Set beside the layer height below for the same
    // reason: both are machine facts the generator cannot infer, and without this one
    // a mat under a voxel tall is erased silently — which is how a deliberately
    // thinned mat vanished from the slice entirely while every stat still read green.
    an_org.lat.weld_pitch_hint_mm = job.lattice.welded_pitch_mm;
    // ★ THE LAYER HEIGHT THE MACHINE WILL ACTUALLY USE. The mid-air-start check
    // rasters Z at this pitch; without it the check is COARSER THAN THE PRINTER
    // and passes parts that float for two real layers. 0 = not stated, and the
    // check says so on the receipt rather than inferring one.
    an_org.lat.layer_height_mm = job.loads.layer_height_mm;
    an_org.lat.base_mat = job.grading.organic_base_mat;
    an_org.lat.fill_mat = job.grading.organic_fill_mat;
    an_org.lat.trim_below_base = job.grading.organic_trim_below_base;

    RunInfo gi = build_run_info(job, options, build_identity());
    gi.grading_present = true;
    gi.grading_algorithm = lattice_algorithm_name(an_alg);
    // ★ THE COMPARABLE NUMBER (bar R10): the solid volume THIS algorithm's own
    // per-voxel density implies. Read from the algorithm's own field, never from
    // another's, so the three-way table compares one quantity three times.
    {
      const std::vector<double>& rho_used =
          an_org.ran ? an_org.lat.relative_density : gf.posture.relative_density;
      const std::vector<char>& msk_used =
          an_org.ran ? an_org.lat.mask : gf.posture.mask;
      const double vox = design_grid.spacing * design_grid.spacing *
                         design_grid.spacing;
      double sum = 0.0;
      long long cnt = 0;
      for (std::size_t e = 0; e < msk_used.size(); ++e)
        if (msk_used[e]) { sum += rho_used[e]; ++cnt; }
      gi.grading_lattice_solid_volume_mm3 = sum * vox;
      gi.grading_algorithm_latticed_voxels = cnt;
    }
    if (an_org.ran) fill_organic_run_info(gi, an_org);
    if (an_step.ran) fill_stepped_run_info(gi, an_step);
    gi.grading_topology = lattice_topology_name(gf.posture.topology);
    gi.grading_band_rho_min = gf.band_rho_min;
    gi.grading_band_rho_max = gf.band_rho_max;
    gi.grading_cells_per_member_floor = gf.cells_per_member_floor;
    gi.grading_cell_size_mm = gf.cell_size_mm;
    gi.grading_printability_floor_mm = gf.printability_floor_mm;
    gi.grading_cell_size_floored = gf.cell_size_floored;
    gi.grading_min_extrudable_width_mm = job.grading.min_extrudable_width_mm;
    gi.grading_rho_min_used = gf.rho_min_used;
    gi.grading_rho_max_used = gf.rho_max_used;
    gi.grading_region_voxels = static_cast<long long>(gf.region_voxels);
    gi.grading_latticed_voxels = static_cast<long long>(gf.latticed_voxels);
    gi.grading_demand_allowable_mpa = gf.demand_allowable_mpa_used;
    gi.grading_utilisation_target = gf.utilisation_target_used;
    gi.grading_max_utilisation = gf.max_utilisation;
    gi.grading_median_utilisation = gf.median_utilisation;
    gi.grading_over_allowable_voxels =
        static_cast<long long>(gf.over_allowable_voxels);
    gi.grading_unloaded_voxels = static_cast<long long>(gf.unloaded_voxels);
    gi.grading_clamped_lo_voxels = static_cast<long long>(gf.clamped_lo_voxels);
    gi.grading_clamped_hi_voxels = static_cast<long long>(gf.clamped_hi_voxels);
    gi.grading_density_at_floor_voxels =
        static_cast<long long>(gf.density_at_floor_voxels);
    gi.grading_density_at_ceiling_voxels =
        static_cast<long long>(gf.density_at_ceiling_voxels);
    // ── ★ RE-CERTIFY THE LATTICED OBJECT — STRUCTURAL INTENT ONLY ─────────────
    // ★ THE GAP THIS CLOSES. Until now the lattice-only path solved ONCE, on the
    // SOLID part, and graded from that field afterwards. Nothing ever certified the
    // object that would actually be PRINTED: the certificate described the part
    // BEFORE it was hollowed out. In structural intent the density IS a strength
    // claim, so that is exactly the claim nobody was checking.
    //
    // ★ STRUCTURAL ONLY, as scoped. An aesthetic density is not a strength claim
    // (`density_meaning` says so on the receipt), so re-solving for it would spend a
    // second FEA to certify a number that is not making a promise. NOTE THE RESIDUAL
    // RISK, because it does not disappear: latticing removes material whatever the
    // intent, so an aesthetic lattice through a load path still weakens the part and
    // is still not re-certified here. That is a KNOWN, STATED gap, not an oversight.
    //
    // Costs a second solve. It runs only when a grading block asked for a structural
    // lattice, so no existing path pays for it.
    if (gf.intent_used == GradingIntent::Structural && gf.latticed_voxels > 0) {
      // ★ E2.1: re-certified under each scenario the lattice uses; the worst
      // governs and every one must pass. Before E2.1, scenario 1 alone.
      // ★ E2.4: an OPEN finish re-certifies with its cut cells given no credit, as the
      // run path does (open_finish_cut_cells).
      const std::vector<double>* recert_density = &density;
      const LatticePosture* recert_post = &gf.posture;
      bool recert_load_path_ok = load_path_ok;
      std::vector<double> floored_density;
      LatticePosture floored_post;
      if (job.lattice.present && job.lattice.outer_finish == "none") {
        const std::vector<char> cut = open_finish_cut_cells(design_grid, density, 0.5, gf.posture);
        long long ncut = 0;
        floored_density = density;
        floored_post = gf.posture;
        for (std::size_t e = 0; e < cut.size(); ++e)
          if (cut[e]) {
            floored_density[e] = 0.0;
            floored_post.mask[e] = 0;
            ++ncut;
          }
        gi.grading_recertified_open_cut_voxels = ncut;
        recert_density = &floored_density;
        recert_post = &floored_post;
        recert_load_path_ok = load_path_connected(design_grid, floored_density, 0.5);
      }
      auto recert_one = [&](const std::vector<DirichletBC>& rb,
                            const std::vector<NodalLoad>& rl) {
        return analyze_fixed_design(
          design_grid, params, *recert_density, rb, rl, material, build_dir,
          options.simp.cg_tolerance, options.simp.cg_max_iterations,
          options.simp.solver, options.margin_stop, knockdown, recert_load_path_ok,
          part_solid, recert_post);
      };
      FixedDesignAnalysis relat;
      if (cert_scenarios.empty()) {
        relat = recert_one(cert_bcs, loads);
      } else {
        std::vector<SimpScenario> used;
        for (std::size_t sx = 0; sx < cert_scenarios.size(); ++sx)
          if (an_scen_on[sx]) used.push_back(cert_scenarios[sx]);
        std::vector<char> used_ok;
        std::string not_certified;  // ★ 11-06 2(a): its words, as certify_posture
        ScenarioCertification rs = certify_scenarios(
            design_grid, used,
            [&](const std::vector<DirichletBC>& rb, const std::vector<NodalLoad>& rl) {
              FixedDesignAnalysis r = recert_one(rb, rl);
              used_ok.push_back(r.accepted ? 1 : 0);
              if (r.lattice_not_certified && not_certified.empty())
                not_certified = "Under \"" + used[used_ok.size() - 1].name + "\": " +
                                r.lattice_not_certified_reason;
              return r;
            });
        relat = std::move(rs.governing);
        for (const char ok : used_ok)
          if (!ok) relat.accepted = false;
        if (!not_certified.empty()) {
          relat.lattice_not_certified = true;
          relat.lattice_not_certified_reason = not_certified;
        }
        for (const ScenarioReport& r : rs.reports) {
          gi.grading_recertified_scenario_names.push_back(r.name);
          gi.grading_recertified_scenario_margins.push_back(r.margin);
          gi.grading_recertified_scenario_governs.push_back(r.governs ? 1 : 0);
        }
      }
      gi.grading_recertified = true;
      gi.grading_recertified_margin = relat.margin_effective;
      gi.grading_recertified_accepted = relat.accepted;
      gi.grading_recertified_not_certified = relat.lattice_not_certified_reason;
      gi.grading_recertified_non_convergent = relat.non_convergent;
      gi.grading_recertified_max_von_mises = relat.max_von_mises;
      gi.grading_solid_margin = a.margin_effective;
      // ★ SAY IT OUT LOUD WHEN THE LATTICE CHANGES THE VERDICT. A part that passed
      // solid and fails latticed is the entire reason this solve exists, and it must
      // not be something a reader has to derive by comparing two numbers.
      gi.grading_recertify_changed_verdict = (a.accepted != relat.accepted);
    }
    gi.grading_recommended_layer_height_mm = gf.recommended_layer_height_mm;
    gi.grading_layer_height_bound_strut_mm = gf.layer_height_bound_strut_mm;
    gi.grading_layer_height_bound_overhang_mm = gf.layer_height_bound_overhang_mm;
    gi.grading_declared_layer_height_mm = job.loads.layer_height_mm;
    gi.grading_intent = grading_intent_name(gf.intent_used);
    gi.grading_aesthetic_percentile = gf.aesthetic_percentile_used;
    gi.grading_aesthetic_percentile_mpa = gf.aesthetic_percentile_mpa;
    gi.grading_aesthetic_rho_min = gf.aesthetic_rho_min_used;
    gi.grading_aesthetic_rho_max = gf.aesthetic_rho_max_used;
    gi.grading_aesthetic_weight_exponent = gf.aesthetic_weight_exponent_used;
    gi.grading_above_percentile_voxels =
        static_cast<long long>(gf.above_percentile_voxels);
    gi.grading_adaptive_cells_armed = gf.aesthetic_adaptive_cells_armed;
    gi.grading_adaptive_error_budget = gf.aesthetic_error_budget_used;
    gi.grading_adaptive_min_cells_allowed =
        gf.aesthetic_min_cells_per_member_allowed;
    gi.grading_below_accuracy_floor_voxels =
        static_cast<long long>(gf.aesthetic_below_accuracy_floor_voxels);
    if (gf.intent_used == GradingIntent::Aesthetic)
      gi.grading_density_meaning = kAestheticDensityMeaning;
    gi.grading_density_histogram.assign(
        gf.density_histogram, gf.density_histogram + GradedField::kDensityBins);
    gi.grading_solid_fallback_voxels =
        static_cast<long long>(gf.solid_fallback_voxels);
    gi.grading_min_member_width_mm = gf.min_member_width_mm;
    gi.grading_min_cells_per_member = gf.min_cells_per_member;
    gi.grading_min_strut_diameter_mm = gf.min_strut_diameter_mm;
    gi.grading_max_strut_diameter_mm = gf.max_strut_diameter_mm;
    gi.grading_any_strut_below_min = gf.any_strut_below_min;
    gi.grading_region_ungradeable = gf.region_ungradeable;
    fill_grading_cell_plan(gi, gf);
    fill_grading_fit(gi, gf, job, &an_roles);
    if (gp.cell_mode == CellSizeMode::Fit)
      fill_fit_region_voxels(gi, design_grid, density, 0.5, an_roles.includes, gf);
    fill_grading_subfloor(gi, gf);

    result.grading_run_info_path = join_path(out_dir, "run_info.json");
    write_run_info(result.grading_run_info_path, gi);
    result.graded = true;
  }

  // ── report.json (VariantReport schema — the NEW, re-analysed numbers) ────────
  const double part_dim_mm =
      std::max({static_cast<double>(design_grid.nx),
                static_cast<double>(design_grid.ny),
                static_cast<double>(design_grid.nz)}) *
      design_grid.spacing;
  VariantReport vr;
  vr.volume_fraction = a.printed_fraction;
  vr.printed_fraction = a.printed_fraction;
  vr.max_stress_mpa = a.max_von_mises;
  vr.max_interlayer_tension_mpa = a.max_interlayer_tension;
  vr.margin = a.margin;
  // The build direction IN THE FRAME OF THE EXPORTED MESH (handoff
  // 2026-08-01-bake-build-orientation) — see VariantReport::orientation. Off the
  // bake path this is `applied_build_dir` == `build_dir`, byte-identical.
  vr.export_baked = analyze_bake.has_value();
  vr.orientation_model = applied_build_dir;
  vr.orientation =
      vr.export_baked ? Vec3{0.0, 0.0, 1.0} : applied_build_dir;
  vr.settings =
      recommend_settings(rules, material.family, a.margin.worst_case, part_dim_mm);
  vr.min_feature_violations = a.v3.min_feature_violations;
  vr.min_feature_warning =
      min_feature_warning_text(rules, a.v3.min_feature_violations);
  vr.accepted = a.accepted;
  // The REQUIRED margin is the one the gate actually used (options.margin_stop):
  // job.margin_stop in self-weight mode (identical), the production default in
  // loadcase mode (the loads schema rejects a margin_stop key, so job.margin_stop
  // is unset there — reporting it would falsely show 0). Surfaced on the result so
  // the CLI prints the threshold the verdict was made against.
  const double margin_required = options.margin_stop;
  result.margin_required = margin_required;
  vr.margin_required = margin_required;
  vr.margin_effective = a.margin_effective;
  vr.contact_rounds = a.contact_rounds;  // REAL BOLTS
  vr.contact_tangent_share = a.contact_tangent_share;
  vr.contact_held_by_sliding = a.contact_held_by_sliding;
  vr.contact_settled = a.contact_settled;
  vr.contact_kept_last = a.contact_kept_last;
  vr.contact_engaged = a.contact_engaged;
  vr.contact_released = a.contact_released;
  vr.contact_load_share = a.contact_load_share;
  vr.scenarios = result.scenarios;  // LOAD SCENARIOS (empty when none)
  if (!a.accepted)
    vr.rejection_reason = !load_path_ok ? std::string(kLoadPathNotConnectedReason)
                          : !result.unheld_scenario.empty()
                              ? scenario_unheld_reason(result.unheld_scenario)
                          : a.contact_held_by_sliding ? std::string(kAnchorsSlidingReason)
                                                      : std::string(kMarginBelowRequiredReason);
  JobReport report;
  report.material = job.material;
  (a.accepted ? report.variants : report.rejected).push_back(vr);
  result.report_json = job_report_json(report);
  result.report_path = join_path(out_dir, "analysis_report.json");
  write_text_file(result.report_path, result.report_json);

  // The BUILD-ORIENTATION RECEIPT for this re-analysis — the same document the
  // optimize path writes, from the same emitter, so a part's ranking reads the
  // same whether it was just optimized or merely re-certified. Only when armed.
  if (a.build_orientation.evaluated) {
    result.build_orientation_path = join_path(out_dir, "build_orientation.json");
    // The receipt reports the APPLIED direction (the one the verdict and the
    // file both describe) and carries the export rotation, so every vector in
    // the document names its frame.
    result.build_orientation_json = build_orientation_report_json(
        a.build_orientation, applied_build_dir,
        analyze_bake ? &*analyze_bake : nullptr);
    write_text_file(result.build_orientation_path,
                    result.build_orientation_json);
  }

  // ── fields.bin (one analysed "variant", so app overlays light up) ────────────
  MinimizePlasticResult fields_result;
  fields_result.report.material = job.material;
  MinimizePlasticVariant fv;
  fv.requested_volume_fraction = a.printed_fraction;
  fv.accepted = a.accepted;
  fv.von_mises_field = a.von_mises_field;
  fv.stress_tensor_field = a.stress_tensor_field;
  fv.displacement_field = a.displacement_field;
  fv.mass_grams = a.mass_grams;
  fv.support_volume_voxels = a.support_volume_voxels;
  fv.report = vr;
  fields_result.evaluated.push_back(std::move(fv));
  result.fields_path = join_path(out_dir, "fields.bin");
  // accepted_only = false: the analyze field is served REGARDLESS of the margin
  // verdict (task analyze-loadcase-resolution, N3). Under the default filter a
  // REJECTED analyze wrote an empty container — the overlay went flat exactly
  // when the part was overstressed. The verdict still travels in the receipt.
  write_fields_file(result.fields_path, fields_result, design_grid,
                    /*accepted_only=*/false);

  // ── analysis.json — the PROVENANCE record (task items 3–5) ───────────────────
  // "smoothed / re-analyzed": analyzed=true, the source, the resolution, BOTH mass
  // figures, and the quantization footnote. The pre-analysis numbers NEVER appear.
  std::string prov;
  prov += "{\n";
  prov += "  \"provenance\": \"smoothed / re-analyzed\",\n";
  prov += "  \"analyzed\": true,\n";
  prov += "  \"optimization\": false,\n";
  // Stage 3 (task lattice-page-core-hookup) — the analyze route's honest label
  // (H3b/H3c): ONE linear analysis solve, no design loop, no variant meshes;
  // and the field's SCOPE, so the "this is the SOLID part's field — optimizing
  // invalidates it" statement travels WITH the result and cannot be lost in
  // transit (the app's RUN SIM gate states the same thing UI-side).
  prov += "  \"analysis_solves\": 1,\n";
  prov += "  \"variant_meshes_written\": 0,\n";
  prov += "  \"field_scope\": " +
          json_str(result.analyzed_mesh ? "substitute_mesh" : "solid_part") +
          ",\n";
  if (!result.analyzed_mesh)
    prov +=
        "  \"field_scope_note\": \"this stress/displacement field describes the "
        "SOLID part under the declared load case; a topology-optimized design "
        "has different geometry, so optimization INVALIDATES this field\",\n";
  prov += "  \"source\": " +
          json_str(result.analyzed_mesh ? ("mesh:" + analyze_mesh_path)
                                        : "model_solid") +
          ",\n";
  prov += "  \"model\": " + json_str(job.model) + ",\n";
  prov += "  \"resolution\": " + std::to_string(job.resolution) + ",\n";
  // Design box (task 2026-08-03-design-box-recertification) — emitted ONLY when
  // the run expanded, so a no-box provenance is byte-identical. It says which
  // grid this re-certification actually ran on, because "the part grid" and "the
  // solved grid" are different objects here and a reader must not have to guess:
  // a smoothed design-box variant is re-certified on the EXPANDED grid, so the
  // material the optimizer grew outside the part is certified, not clipped away.
  if (expand_for_mesh) {
    prov += "  \"design_box\": {\n";
    prov += "    \"expanded\": true,\n";
    prov += "    \"part_grid\": [" + std::to_string(model_grid.nx) + ", " +
            std::to_string(model_grid.ny) + ", " +
            std::to_string(model_grid.nz) + "],\n";
    prov += "    \"solved_grid\": [" + std::to_string(cert_grid.nx) + ", " +
            std::to_string(cert_grid.ny) + ", " + std::to_string(cert_grid.nz) +
            "],\n";
    prov += "    \"part_offset\": [" + std::to_string(domain.offset_i) + ", " +
            std::to_string(domain.offset_j) + ", " +
            std::to_string(domain.offset_k) + "],\n";
    prov += "    \"note\": \"the analysed geometry is voxelized onto the SOLVED "
            "grid and the declared load case is remapped onto it, so material "
            "grown outside the imported part is certified rather than clipped "
            "at the part's bounding box\"\n";
    prov += "  },\n";
  }
  prov += "  \"voxel_mass_grams\": " + json_num(result.voxel_mass_grams) + ",\n";
  prov += "  \"mesh_mass_grams\": " +
          (result.analyzed_mesh ? json_num(result.mesh_mass_grams)
                                : std::string("null")) +
          ",\n";
  // Load-case receipt (loadcase-analyze handoff) — emitted ONLY in loadcase mode,
  // so the self-weight provenance is byte-identical to before (L1). Records that
  // this re-analysis ran under a DECLARED external load (never self-weight), the
  // declared force groups + their resultant, the anchor count, and the number of
  // nodal loads the tractions produced — the honest counterpart to the self-weight
  // path's implicit "load_source": self_weight.
  if (loadcase) {
    Vec3 resultant{0.0, 0.0, 0.0};
    for (const JobLoadGroup& g : job.loads.groups) {
      resultant.x += g.force.x;
      resultant.y += g.force.y;
      resultant.z += g.force.z;
    }
    const double resultant_mag =
        std::sqrt(resultant.x * resultant.x + resultant.y * resultant.y +
                  resultant.z * resultant.z);
    prov += "  \"load_source\": \"loadcase\",\n";
    prov += "  \"load_groups\": " + std::to_string(job.loads.groups.size()) +
            ",\n";
    prov += "  \"anchor_faces\": " +
            std::to_string(result.fixture_face_ids.size()) + ",\n";
    prov += "  \"external_load_nodes\": " + std::to_string(loads.size()) + ",\n";
    prov += "  \"declared_force_resultant_n\": " + json_num(resultant_mag) + ",\n";
  }
  // Smoothing receipt (task items 1, 5; bars S2/S4) — emitted ONLY when smoothing
  // ran, so the analyse-only provenance is byte-identical to before (bar S6). Both
  // mass figures above already describe the SMOOTHED mesh in this branch.
  if (result.smoothed) {
    const SmoothStats& s = result.smooth_stats;
    prov += "  \"smoothed\": true,\n";
    prov += "  \"smooth_strength\": " + json_num(result.smooth_strength) + ",\n";
    prov += "  \"smooth_pairs_requested\": " +
            std::to_string(s.requested_pairs) + ",\n";
    prov += "  \"smooth_pairs_applied\": " + std::to_string(s.applied_pairs) +
            ",\n";
    prov += "  \"frozen_vertices\": " + std::to_string(s.frozen_vertices) + ",\n";
    prov += "  \"total_vertices\": " + std::to_string(s.total_vertices) + ",\n";
    prov += "  \"volume_before_mm3\": " + json_num(s.volume_before_mm3) + ",\n";
    prov += "  \"volume_after_mm3\": " + json_num(s.volume_after_mm3) + ",\n";
    prov += "  \"volume_drift_fraction\": " + json_num(s.volume_drift_fraction) +
            ",\n";
    prov += "  \"volume_drift_bound\": " + json_num(s.volume_drift_bound) + ",\n";
    prov += "  \"min_feature_baseline\": " +
            std::to_string(s.min_feature_baseline) + ",\n";
    prov += "  \"min_feature_after\": " + std::to_string(s.min_feature_after) +
            ",\n";
    prov += "  \"min_feature_limited\": " +
            std::string(s.min_feature_limited ? "true" : "false") + ",\n";
    prov += "  \"smoothed_mesh\": " + json_str(result.smoothed_mesh_path) + ",\n";
  }
  prov += "  \"max_stress_mpa\": " + json_num(a.max_von_mises) + ",\n";
  prov += "  \"margin_worst_case\": " + json_num(a.margin.worst_case) + ",\n";
  prov += "  \"margin_required\": " + json_num(margin_required) + ",\n";
  prov += "  \"margin_effective\": " + json_num(a.margin_effective) + ",\n";
  prov += "  \"accepted\": " + std::string(a.accepted ? "true" : "false") + ",\n";
  prov += "  \"min_feature_violations\": " +
          std::to_string(a.v3.min_feature_violations) + ",\n";
  prov +=
      "  \"quantization_note\": \"Re-analysis runs on the "
      "voxelization of the analyzed mesh at the grid resolution, so the analyzed "
      "and printed geometry differ by up to ~half a voxel. The stress margin and "
      "voxel mass describe the voxel proxy; the mesh mass is the surface-enclosed "
      "volume.\"\n";
  prov += "}\n";
  result.provenance_path = join_path(out_dir, "analysis.json");
  write_text_file(result.provenance_path, prov);

  return result;
}
