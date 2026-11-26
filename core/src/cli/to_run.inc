// to_run.inc -- preflight_job, run_job, refinish_job: the TO entry points.
//
// TO rebuild stage 0 (docs/design/to-rebuild/05-workplan.md): moved out of
// run_job.cpp unchanged, line for line. This is NOT a translation unit: it is
// included by run_job.cpp at the place the code used to stand, inside
// namespace topopt, so every name resolves exactly as before. Do not compile
// it on its own and do not include it anywhere else.

PreflightJobResult preflight_job(const JobDescription& job,
                                 const std::string& job_dir,
                                 const MaterialLibrary& materials) {
  refuse_flexible_job(job, "preflight_job");  // Flexible stage (flexible/job_block.hpp)
  const double t0 = steady_clock_ms();
  PreflightJobResult out;
  if (job.mode != "minimize_plastic")
    throw JobError("preflight: unsupported mode: " + job.mode);
  if (materials.find(job.material) == materials.end())
    throw JobError("material \"" + job.material +
                   "\" is not in the material library");
  const std::string model_path = join_path(job_dir, job.model);
  const bool model_is_mesh = part_format_for_path(job.model) != PartFormat::Step;
  try {
    out.model = import_part_file_resolved(model_path);
  } catch (const PartError& e) {
    throw JobError(std::string("cannot import model \"") + job.model +
                   "\": " + e.what());
  }
  if (!check_watertight(out.model.mesh).watertight)
    throw JobError("model tessellation is not watertight: " + job.model);
  // THE ONE setup — the identical call run_job makes.
  JobSetup setup = build_job_setup(job, out.model, model_is_mesh, materials);
  out.fixture_face_ids = setup.fixture_face_ids;
  const SolvedDesignDomain domain =
      resolve_design_domain(setup.grid, setup.bcs, setup.options);
  out.preflight = preflight_load_path(domain, setup.options);
  out.would_refuse =
      out.preflight.walk.decidable && !out.preflight.walk.connected;
  if (out.would_refuse)
    out.refusal = preflight_refusal_report(out.model, setup.grid, domain,
                                           setup.options, setup.lc,
                                           out.preflight,
                                           out.fixture_face_ids);
  out.wall_ms = steady_clock_ms() - t0;
  return out;
}

RunJobResult run_job(const JobDescription& job, const std::string& job_dir,
                     const std::string& out_dir,
                     const MaterialLibrary& materials,
                     const SettingsRules& rules, bool emit_progress,
                     const RunObservability& obs) {
  refuse_flexible_job(job, "run_job");  // Flexible stage (flexible/job_block.hpp)
  // Fail fast on everything checkable before heavy work: the mode, the
  // material, and whether this build can write the requested mesh format.
  // MODE VALIDATION STAYS STRICT (H3a): run_job optimizes minimize_plastic jobs
  // and NOTHING else — an "analyze" job is one fixed-design solve and must go
  // through analyze_job (`topopt-cli analyze`; the LAN worker routes on the
  // job's mode), never be optimized here.
  if (job.mode != "minimize_plastic")
    throw JobError(
        job.mode == "analyze"
            ? std::string(
                  "unsupported mode for `run`: \"analyze\" is one fixed-design "
                  "analysis solve, not an optimization — run it with "
                  "`topopt-cli analyze <job.json>`")
            : "unsupported mode: " + job.mode);
  const auto mat_it = materials.find(job.material);
  if (mat_it == materials.end())
    throw JobError("material \"" + job.material +
                   "\" is not in the material library");
  const Material& material = mat_it->second;
#ifndef TOPOPT_HAVE_3MF
  if (job.output.mesh_format == "3mf")
    throw JobError(
        "this build has no 3MF support (lib3mf was not available): "
        "output.mesh_format \"3mf\" cannot be written, use \"stl\"");
#endif

  // The pre-flight region forecast's numbers (task 2026-08-04-protect-freeze-vs-
  // solidity, item 6), carried to run_info far below. Declared here because the
  // forecast runs BEFORE the import — that is the whole point of it.
  int fc_region_too_thin = 0, fc_include_regions = 0;
  double fc_required_mm = 0.0, fc_thinnest_mm = 0.0;

  // ──▶ Lattice pre-flight (handoff 2026-07-29-lattice-certification-e2e). Refuse
  // BEFORE any import / voxelize / solve — nothing is written — on the condition
  // the E2E certification cannot honor:
  //   * A density OUTSIDE the certifiable band (read from CORE — lattice_rho_min/max,
  //     not hardcoded). The band is a hard gate at certification (bar E5):
  //     analyze_fixed_design also throws LatticeDensityOutOfBand mid-run, but failing
  //     up front wastes no solve and names the band in the message.
  // Stage 4 (task lattice-page-core-hookup): grading on the OPTIMIZE path
  // requires a lattice block — without one there is nothing to grade into, and
  // silently ignoring the block is exactly the reported gap this closes.
  if (job.grading.present && !job.lattice.present)
    throw JobError(
        "a \"grading\" block on the optimize path requires a \"lattice\" block: "
        "run_job grades each accepted variant's lattice from that variant's own "
        "final stress field, so without a lattice there is nothing to grade "
        "into. Add a \"lattice\" block (without cell_mm/strut_radius_mm — the "
        "graded run derives those) or drop \"grading\".");
  // GRADING + a DESIGN BOX runs (reviewer's ruling 2026-11-03 23:05, option (b)). It
  // was refused because the graded cell PLAN came from grade_lattice before the
  // added-material policy could speak, and the SWEPT levels (and the plan's passes)
  // took their cells from that plan rather than from the final certification mask: a
  // graded design-box run could write struts into cells the certificate calls solid.
  // Now the law's candidates leave the added material out, and every level and pass
  // lays only cells covering a voxel of the final mask (lattice_one_variant, audited
  // per grid in the added-material receipt). Organic stays refused with a box.
  if (job.grading.present && job.has_design_box &&
      resolve_lattice_algorithm(job.grading) == LatticeAlgorithm::Organic)
    throw JobError(kOrganicDesignBoxRefusal);
  if (job.lattice.present) {
    // A DESIGN BOX no longer refuses (task 2026-08-03-design-box-recertification).
    // The refusal existed because the latticed re-certification reconstructed the
    // load case at run_job level with NO remap onto the expanded grid — it was
    // protecting against a second reconstruction written on the assumption that
    // the grid never expands, not against something impossible. There is now ONE
    // remap (resolve_design_domain / design_domain_loads, pipeline.hpp) and both
    // the optimize path and this certification call it, so the load case cannot
    // be a different one. Material grown OUTSIDE the imported part is governed by
    // kDesignBoxAddedMaterialKeptSolid and reported per variant.
    //
    // The uniform-density band fast-fail. A GRADED run has no uniform
    // cell/radius (the schema rejects them); its per-voxel densities are
    // in-band by the grading law's construction (bar L2), and the band is
    // still enforced per voxel inside analyze_fixed_design (E5 / H4b).
    if (!job.grading.present) {
      const double lat_rho =
          lattice_density_from_strut(
              lattice_topology_from_id(job.grading.topology), job.lattice.cell_mm, job.lattice.strut_radius_mm);
      const double lo = lattice_rho_min(lattice_topology_from_id(job.grading.topology));
      const double hi = lattice_rho_max(lattice_topology_from_id(job.grading.topology));
      if (lat_rho < lo || lat_rho > hi)
        throw JobError(
            "lattice cell_mm " + std::to_string(job.lattice.cell_mm) +
            " / strut_radius_mm " + std::to_string(job.lattice.strut_radius_mm) +
            " implies " + job.lattice.topology + " relative density " + std::to_string(lat_rho) +
            ", outside the certifiable band [" + std::to_string(lo) + ", " +
            std::to_string(hi) +
            "]. The gate refuses to certify against a clamped tensor (bar E5); choose a "
            "strut radius whose density lands in the band.");
    }
    // ── PRE-FLIGHT FORECAST: CAN THIS REGION HOLD A LATTICE AT ALL? (task
    // 2026-08-04-protect-freeze-vs-solidity, item 6)
    //
    // THE SECOND REASON the maintainer's include regions produced nothing, and it
    // is PHYSICS, not a bug: his include regions are 4 mm-deep face slabs, and
    // the cells-per-member floor demands 5 cells × 4.6026 mm = 23.0 mm of member.
    // Separating "frozen" from "solid" does not touch that — a 4 mm slab cannot
    // hold a certifiable lattice at any depth he would want, and no rung, cell
    // size or tag change alters it.
    //
    // He should learn it BEFORE the run, so it is stated here: before any import,
    // voxelize or solve, from the declared geometry and the two constants alone.
    //
    // *** WHY THE REGION'S OWN EXTENT IS THE RIGHT THING TO MEASURE. *** The
    // certification mask lattices ONLY voxels inside the include union; material
    // outside it stays solid (the companion body). So the latticed body is a
    // SUBSET of the region, and its thinnest dimension is at most the region's
    // thinnest dimension. If that is under n* × cell, nothing inside the region
    // can hold n* cells across.
    //
    // *** AND WHY THIS IS A FORECAST, NOT A GATE. *** The grading law's own
    // too-thin test reads `local_member_thickness_mm`, which measures the
    // DESIGN's printed solid — it does not know the region restriction. On a
    // thick wall with a thin include slab the two disagree: the law sees the
    // wall's width and admits the voxel, while the body actually latticed is only
    // as deep as the slab. That is a real coherence gap (FILED, with the
    // reproduction, in the handoff §item-7b) and closing it MOVES the latticed
    // mask on existing paths, which this task's bar 5 makes a blocked-stop. So
    // this states the number and changes nothing.
    if (!job.lattice.regions.empty()) {
      const LatticeTopology topo =
          lattice_topology_from_id(job.grading.topology);
      const double n_star = lattice_cells_per_member_min(topo);
      // The cell this run will actually use, by the SAME rules the law applies:
      // AUTO takes the printability floor, FIXED the target raised to the floor that
      // actually binds (S2), SWEPT the finest rung its OWN dyadic ladder can print
      // (S1, task 2026-08-07); a uniform job states its cell. FIT has NO single
      // planned cell — it derives one per region — so the scalar below carries the
      // FINEST derived cell and every table row uses that region's own.
      //
      // ★ THIS IS `planned_cell_mm`, CALLED — not copied. The two used to be duplicate
      // switches, and the duplication is exactly how the defect survived: task
      // 2026-08-05-lattice-cell-fit-mode's S2 corrected FIXED in both copies and left
      // SWEPT unchanged in both (commit 4032ce8, diff context lines 245/431).
      //
      // `swept_light_floor=false` is the S1 CORRECTION and it is the refusal path's
      // answer. `multiscale_floor_cell_mm` — the other caller — passes true and says
      // at length why: its value reaches geometry, and moving it flips a design on a
      // job that runs today. Nothing here reaches geometry, so nothing here is gated
      // on that decision.
      CellSizeMode pf_mode = CellSizeMode::Fixed;
      const bool pf_mode_known =
          !job.grading.present ||
          resolve_cell_mode(job.grading.cell_mode, pf_mode);
      (void)pf_mode_known;  // an unknown mode is refused by the grading call itself
      const bool pf_fit = job.grading.present && pf_mode == CellSizeMode::Fit;
      double cell_mm = job.lattice.cell_mm;
      double floor_mm = 0.0;
      std::vector<FitRegionCell> pf_fit_cells;
      if (job.grading.present) {
        floor_mm = lattice_cell_printability_floor_mm(
            topo, job.grading.min_extrudable_width_mm);
        if (pf_fit)
          // ★ NO `roles` HERE, AND THAT IS A REAL LIMIT, NOT AN OVERSIGHT: the
          // pre-flight runs BEFORE the import and before the grid exists, so a
          // region-backed include has no mask yet and no derivable extent. Such
          // regions are omitted from the forecast table below (and counted), and
          // the run's own per-region verdicts report them for real. See the
          // handoff §2(a) — closing this means voxelizing inside the pre-flight.
          pf_fit_cells = fit_region_cells(job, topo,
                                          job.grading.min_extrudable_width_mm);
        cell_mm = planned_cell_mm(job, /*swept_light_floor=*/false);
      }
      const double required_mm = n_star * cell_mm;
      // The stated bead width the derivation is evaluated at. A uniform job carries
      // it on the lattice block; a graded job on the grading block. 0 means the job
      // never stated one, and then no derivation is possible — the refusal below
      // does not fire and the forecast is all that is reported.
      const double w_min_fc = job.grading.present
                                  ? job.grading.min_extrudable_width_mm
                                  : job.lattice.min_extrudable_width_mm;
      // ── A SWEPT WINDOW WHOSE TOP IS UNDER THE PRINTABLE FRONTIER (found by this
      // task's own R3 table, case S_underfrontier).
      //
      // Every rung of the ladder is `cell_min_mm * 2^L <= cell_max_mm`, so if
      // `cell_max_mm` itself is below `w / phi(rho_max)` then NO rung prints at any
      // density in the band. The plan drops every base cell as unprintable, the run
      // emits no lattice, and the solve is spent for nothing — which is exactly the
      // outcome this pre-flight exists to predict.
      //
      // ★ REPORTED, NOT REFUSED, and the distinction is deliberate. Refusing it would
      // be a NEW refusal on jobs that run today: before S1 the planned cell here was
      // the LIGHT floor, so a job whose regions cleared percolation against that
      // number ran to completion (emitting nothing). This task's R3 makes a new
      // refusal on such a job a blocked-stop, so the pre-flight says the sentence and
      // changes no verdict. Turning it into a refusal is a one-line change behind its
      // own gate table.
      std::string swept_unprintable_note;
      if (job.grading.present && pf_mode == CellSizeMode::Swept && w_min_fc > 0.0) {
        // ★ D1: the swept frontier is the capped floor -- the plan can lay no rung below it.
        const double frontier_mm =
            lattice_min_printable_cell_mm(topo, w_min_fc, job.grading.max_relative_density);
        if (job.grading.cell_max_mm < frontier_mm)
          swept_unprintable_note =
              "\n     ★ AND SEPARATELY: your whole swept window (" +
              json_num(job.grading.cell_min_mm) + " to " +
              json_num(job.grading.cell_max_mm) +
              " mm) is FINER than the smallest cell that prints at a " +
              json_num(w_min_fc) + " mm strut line width, which is " +
              json_num(frontier_mm) +
              " mm. No level of the ladder can carry a strut, so this run will "
              "solve and then emit NO LATTICE AT ALL. Raise \"cell_max_mm\" to at "
              "least that value.";
      }
      // ── S3: PER-REGION OUTPUT IS ONE TABLE ROW, AND THE EXPLANATION APPEARS ONCE
      // (task 2026-08-07-cell-mode-fit-and-swept-floor).
      //
      // WHAT WAS WRONG, in the maintainer's words: "Nothing is clear. This is a
      // *horrible* way to help the user." Nine declared regions produced NINE
      // near-identical paragraphs — each one restating the same floor, the same cell
      // and the same physics — and the single sentence telling him what to TYPE came
      // last, below the fold on an iPad, cut off mid-word. The completeness bar (every
      // number, every remedy) was met; readability was never specified, so it was not
      // met at all.
      //
      // The shape is now fixed and it is the same for every case below:
      //     HEADLINE — what happened, with the count and the planned cell
      //     ACTION   — the number to type, FIRST, before any explanation
      //     TABLE    — one row per declared region, and nothing else per region
      //     Why:     — the explanation, ONCE
      //
      // Nothing here decides anything. The three-case machine below is untouched: the
      // same jobs refuse, for the same reasons, with the same arithmetic. Only the
      // composition of the text changed.
      struct PfRow {
        std::size_t ri = 0;
        std::string kind;
        double extent_mm = 0.0;
        const FitRegionCell* fit = nullptr;  // FIT only; null on every other mode
        bool thin = false;                   // counted against `thin_regions`
      };
      std::vector<PfRow> pf_rows;
      int thin_regions = 0, include_regions = 0;
      // Region-backed includes the pre-flight cannot price (see above).
      int unforecastable_regions = 0;
      double thinnest_mm = std::numeric_limits<double>::infinity();
      for (std::size_t ri = 0; ri < job.lattice.regions.size(); ++ri) {
        const JobLatticeRegion& r = job.lattice.regions[ri];
        if (r.role != "include") continue;
        ++include_regions;
        // The region's THINNEST dimension — the one that bounds how many cells
        // can lie across the latticed body. ONE definition, shared with the fit
        // derivation, so the two cannot describe different regions.
        // ★ A REGION-BACKED INCLUDE HAS NO DECLARED EXTENT (task
        // 2026-08-15-lattice-regions). Reading half-extents that are all zero
        // gives 0, and the derivation then throws "member_width_mm must be > 0"
        // — which is exactly how this bit on the FIRST §4 run: the pre-flight
        // reached the analytic reader before the fit path ever ran. Its extent
        // is MEASURED from its mask, the same number fit_region_cells uses.
        // ★ A REGION-BACKED INCLUDE HAS NO DECLARED EXTENT (task
        // 2026-08-15-lattice-regions). Reading half-extents that are all zero
        // gives 0, and the derivation then throws "member_width_mm must be > 0"
        // — which is exactly how this bit on the FIRST §4 run: the pre-flight
        // reached the analytic reader on a kind that has nothing for it to read.
        // Its extent is only knowable after the import, so it is skipped here
        // and counted; the run's per-region verdicts carry the real numbers.
        if (r.kind == "region") { ++unforecastable_regions; continue; }
        const double extent_mm = lattice_region_thinnest_extent_mm(r);
        if (extent_mm < thinnest_mm) thinnest_mm = extent_mm;
        PfRow row;
        row.ri = ri;
        row.kind = r.kind;
        row.extent_mm = extent_mm;
        // ── FIT reports what this region DERIVED, not what one part-wide cell
        // demands of it. That is the whole difference the mode makes, and it is
        // the row the maintainer reads to see his own region.
        if (pf_fit) {
          // Matched by the region's OWN job index rather than by a running counter:
          // fit_region_cells drops a degenerate region (mirroring the role resolver)
          // and this loop does not, so a counter would silently misalign the rest of
          // the list behind one bad region.
          const FitRegionCell* f = nullptr;
          for (const FitRegionCell& c : pf_fit_cells)
            if (c.job_region_index == ri) { f = &c; break; }
          if (f == nullptr) continue;   // degenerate region, dropped by the resolver
          row.fit = f;
          row.thin = !f->feasible || f->out_of_regime;
        } else {
          row.thin = extent_mm < required_mm;
        }
        if (row.thin) ++thin_regions;
        pf_rows.push_back(row);
      }
      if (include_regions > 0) {
        fc_region_too_thin = thin_regions;
        fc_include_regions = include_regions;
        fc_required_mm = required_mm;
        fc_thinnest_mm = thinnest_mm;
      }

      // THE TABLE. Fixed-width columns so nine rows read as nine rows and not as a
      // wall; the header names the cell every "cells across" number is measured at,
      // so that cell appears ONCE rather than on every line.
      auto pf_table = [&]() {
        std::string t;
        char line[320];
        for (const PfRow& row : pf_rows) {
          const std::string label =
              "  " + std::to_string(row.ri) + " (" + row.kind + ")";
          if (t.empty())
            t += pf_fit ? "  region        thinnest      cell   density    strut  "
                          "cells\n"
                        : "  region        thinnest   cells\n";
          if (pf_fit && row.fit != nullptr && !row.fit->feasible) {
            std::snprintf(line, sizeof(line),
                          "%-14s %7.3f        —        —        —      —  SOLID: "
                          "no (cell, density) pair prints AND percolates\n",
                          label.c_str(), row.extent_mm);
          } else if (pf_fit && row.fit != nullptr) {
            std::snprintf(line, sizeof(line),
                          "%-14s %7.3f %9.4f %8.4f %8.4f %6.2f  %s\n",
                          label.c_str(), row.extent_mm, row.fit->cell_mm,
                          row.fit->relative_density, row.fit->strut_mm,
                          row.fit->cells_per_member,
                          row.fit->out_of_regime ? "OUT OF REGIME"
                                                 : "certifiable");
          } else if (pf_fit) {
            continue;
          } else {
            std::snprintf(line, sizeof(line), "%-14s %7.3f %7.2f  %s\n",
                          label.c_str(), row.extent_mm,
                          cell_mm > 0.0 ? row.extent_mm / cell_mm : 0.0,
                          row.thin ? "SOLID: under the floor" : "certifiable");
          }
          t += line;
        }
        // The cell every "cells" number is measured at, named ONCE under the table
        // instead of on every row — which is what the nine paragraphs were doing.
        if (!t.empty() && !pf_fit) {
          std::snprintf(line, sizeof(line),
                        "  (\"cells\" = the region's thinnest extent across the "
                        "planned %.4f mm cell)\n", cell_mm);
          t += line;
        }
        return t;
      };

      // ONE composer for every message this pre-flight can produce — refusal or
      // forecast. The order is the bar: action before explanation, always.
      auto pf_compose = [&](const std::string& headline, const std::string& action,
                            const std::string& why) {
        std::string s = headline;
        if (!action.empty()) s += "\n" + action;
        s += "\n\n" + pf_table();
        if (!why.empty()) s += "\nWhy: " + why;
        // Appended to EVERY shape rather than to one branch: the window being
        // unprintable is a fact about the job, not about which of the three cases
        // the regions landed in, and it is the sentence that saves the solve.
        s += swept_unprintable_note;
        return s;
      };
      // Printing a composed block to stderr keeps the existing "[lattice] " prefix on
      // every line, so a log grep for the tag still finds the whole message.
      auto pf_print = [&](const std::string& block) {
        std::string out = "[lattice] ";
        for (char c : block) {
          out += c;
          if (c == '\n') out += "[lattice] ";
        }
        out += "\n";
        std::fwrite(out.data(), 1, out.size(), stderr);
        std::fflush(stderr);
      };

      // ── THE REFUSAL (task 2026-08-05-lattice-cell-size-adaptation, B1).
      //
      // WHAT WAS WRONG. Everything above is a FORECAST: it computes the exact
      // arithmetic, prints it, records it in run_info — and returns. Nothing
      // consumes it as a stop. The maintainer's overnight run (fingerprint
      // b3abcf880554) declared seven include regions, every one 4 mm across its
      // thinnest dimension, against an 8 mm cell whose floor needs 5 x 8 = 40 mm.
      // It forecast `7 of 7 include regions are thinner than the 40.000 mm the
      // floor requires`, then solved four rungs overnight, marked all four
      // lattice_accepted, and shipped a part with 1131 lattice cells — none of them
      // able to be where he asked. A forecast that says NOTHING you declared can
      // hold a lattice is not a warning; it is a description of a useless run.
      //
      // WHY *ALL* AND NOT *ANY*. Refusing when SOME region is too thin would break
      // every legitimate mixed job — a user may knowingly declare a thin rib
      // alongside a thick boss and want the boss latticed. When EVERY declared
      // region fails there is no such reading left: the run cannot honour a single
      // thing the user asked for. So the condition is exactly `thin == include`,
      // and a job with one admissible region is untouched (bar R3 — this cannot
      // flip a verdict on a path that produces usable lattice, because it does not
      // fire on one).
      //
      // WHAT IT SAYS. Per §2's rule, a region is never reported un-latticeable
      // without the cell and density at which it WOULD be latticeable, or the
      // statement that no such pair exists WITH the arithmetic. Both come from
      // lattice_derive_cell_for_member (lattice.hpp), evaluated at the thinnest
      // declared extent — the same core law, read at run time, no literal here.
      //
      // ── WHAT REVIEW CHANGED (M1 / M8c). The trigger above USED TO BE
      // `thin_regions == include_regions`, where `thin` meant "thinner than N* x
      // the planned cell" and the planned cell on a graded AUTO job is
      // lattice_cell_printability_floor_mm — evaluated at rho_MIN. That is exactly
      // the hidden condition §3 of this task took apart, used as a refusal trigger.
      // It refused a graded AUTO job whose regions were 6 mm while this task's own
      // derivation says 5.4748 mm is feasible: a NEW refusal, on a path that
      // previously ran, on a job Stage A calls fine.
      //
      // THE TRIGGER IS NOW THE DERIVATION, and it distinguishes THREE cases that
      // the single test collapsed. Two floors govern, and they are different
      // failure modes with different remedies (lattice.hpp):
      //   PERCOLATION (~1 cell) — below it there is no connected strut network.
      //     The generator emits debris. His shipped mesh ran at 0.4263 cells per
      //     member and carried 123 isolated fragments.
      //   ACCURACY (5 cells)    — below it the homogenized tensor stops describing
      //     the member. The part still PRINTS; the certificate is out of regime.
      //
      //   (A) No (cell, rho) pair clears PRINTABILITY and PERCOLATION.
      //       Genuinely un-latticeable at any setting -> REFUSE.
      //   (B) A pair exists, but the PLANNED cell does not percolate in these
      //       regions -> REFUSE, with a DISTINCT message: the cell is wrong, not
      //       the part. Chosen over proceeding because proceeding is precisely
      //       what shipped him debris — 0.5 cells per member, 123 loose
      //       fragments, a night of solve. A run that can be fixed by one number
      //       in the job should say that number, not print rubble.
      //   (C) The planned cell percolates but sits below the ACCURACY floor.
      //       Buildable and uncertifiable — the regime sub-floor retention exists
      //       for. NOT refused: reported loudly and left to the opt-in. This is
      //       the case that was wrongly refused, and it is where his 4 mm back
      //       wall actually sits.
      // ── HOW FIT ENTERS THE SAME THREE CASES (task
      // 2026-08-05-lattice-cell-fit-mode, S1). It reuses this machine rather than
      // adding a second refusal, with two scoped differences that follow from what
      // fit does:
      //   * (A) fires only when NO declared region is feasible. Under one part-wide
      //     cell the thinnest region decides the run; under fit each region gets its
      //     own cell, so a job with one thin region and six good ones can still
      //     honour the six. Refusing it would be refusing work fit can do.
      //   * (B) CANNOT fire. The derived cell is chosen at or below extent /
      //     percolation floor by construction, so a feasible region's planned cell
      //     percolates. That is the defect this mode removes, and the assertion
      //     below states it rather than leaving it implied.
      const bool fit_any_feasible =
          pf_fit && std::any_of(pf_fit_cells.begin(), pf_fit_cells.end(),
                                [](const FitRegionCell& f) { return f.feasible; });
      const bool pf_decidable =
          include_regions > 0 && w_min_fc > 0.0 && !(pf_fit && fit_any_feasible);
      if (pf_decidable) {
        const double perc_floor = lattice_percolation_cells_per_member_min(topo);
        const LatticeCellDerivation d = lattice_derive_cell_for_member(
            topo, thinnest_mm, w_min_fc, 0.0, job.grading.max_relative_density);
        // Does the PLANNED cell percolate across the thinnest declared region?
        const double planned_cpm = thinnest_mm / cell_mm;
        const bool planned_percolates = planned_cpm >= perc_floor;

        std::string msg;
        if (!d.feasible_percolation) {
          // (A) — nothing can be built here at any setting.
          //
          // S3 SHAPE: headline, then the action (what to change and to what), then the
          // per-region table, then the explanation ONCE. Every number the old
          // paragraph-per-region form carried is still here — the region indices,
          // kinds and extents in the table, the floors and the bead in the prose.
          const std::string headline =
              std::to_string(include_regions) + " of " +
              std::to_string(include_regions) +
              " declared lattice include regions are too thin to hold a CONNECTED "
              "lattice at any cell size or density — refusing before spending a "
              "solve.";
          std::string action =
              "THICKEN the region to at least " +
              json_num(d.min_member_width_buildable_mm) +
              " mm for a connected lattice, or " +
              json_num(d.min_member_width_certifiable_mm) +
              " mm for a CERTIFIED one — or use a strut line width of at most " +
              json_num((thinnest_mm / perc_floor) *
                       (w_min_fc / lattice_min_printable_cell_mm(topo, w_min_fc, job.grading.max_relative_density))) +
              " mm. Your thinnest region has " + json_num(thinnest_mm) +
              " mm. Both are your call, not this pipeline's.";
          std::string why =
              "at a " + json_num(w_min_fc) +
              " mm strut line width the smallest cell any certifiable strut prints "
              "at is " + json_num(d.min_printable_cell_mm) +
              " mm, and a connected strut network needs " + json_num(perc_floor) +
              " cell(s) across it — so " +
              json_num(d.min_member_width_buildable_mm) +
              " mm of material is the least a lattice can live in, whatever the "
              "cell size or density. Nothing printable can go where you asked.\n";
          // ── M2: EVERY REMEDY A REFUSAL NAMES MUST CHANGE THE OUTCOME.
          // A SKIN is deliberately NOT offered here. It was, and it should not
          // have been: the rim/skin finish dresses only ANALYTIC boundary faces,
          // and a voxel-derived part with no bolt clearance has none, so a skin
          // produces exactly zero geometry there (handoff §7). Recommending it
          // sent the user to a door that is painted on. It is named as
          // UNAVAILABLE rather than omitted, so nobody re-adds it.
          why += "     NOT AVAILABLE as an alternative on this part: a SKIN / RIM "
                 "finish. It dresses analytic faces (flat planes, bolt bores) "
                 "and this part's boundary comes from the voxel grid, so it "
                 "would emit nothing at all. The export refuses it rather than "
                 "producing an undressed part silently.";
          msg = pf_compose(headline, action, why);
        } else if (!planned_percolates) {
          // (B) — the CELL is wrong, and a working range exists. Name it FIRST.
          const std::string headline =
              std::to_string(thin_regions) + " of " +
              std::to_string(include_regions) +
              " declared lattice include regions are too thin for the planned " +
              json_num(cell_mm) +
              " mm cell — refusing before spending a solve.";
          // ── WHICH KEY, FOR THIS JOB. The old copy said `Set "cell_mm" in the
          // GRADING block` on EVERY graded path — and the schema REFUSES "cell_mm"
          // alongside both "auto" and "swept" (job.cpp: "a target cell alongside a
          // ladder is a CONFLICT, not a hint"). So the remedy it named was a job core
          // would reject, on the two modes the app can actually send. Named per mode
          // now; the range itself is unchanged.
          std::string action =
              "SET cell size between " + json_num(d.min_printable_cell_mm) +
              " mm and " + json_num(thinnest_mm / perc_floor) + " mm";
          if (job.grading.present) {
            if (pf_mode == CellSizeMode::Swept)
              action += " — lower \"cell_min_mm\" in the GRADING block into that "
                        "range (\"cell_mm\" is refused alongside a swept ladder).";
            else if (pf_mode == CellSizeMode::Auto)
              action += " — set \"cell_mode\": \"fixed\" with \"cell_mm\" in that "
                        "range (\"auto\" takes core's own floor, which is how you "
                        "got here).";
            else
              action += " — set \"cell_mm\" in the GRADING block to a value in "
                        "that range.";
            action += " Or set \"cell_mode\": \"fit\" and core derives it per "
                      "region.";
          } else {
            action += " — set \"cell_mm\" in the lattice block to a value in that "
                      "range.";
          }
          // THE EXPLANATION, ONCE. Every number the nine paragraphs carried is here
          // or in the table: the region indices, kinds and extents are rows; the
          // planned cell heads the "cells across" column and the headline; the
          // floors, the bead and the admissible window are stated once.
          std::string why =
              "a strut network only connects when at least " +
              json_num(perc_floor) +
              " cell(s) lie across the member. The planned " + json_num(cell_mm) +
              " mm cell puts " + json_num(planned_cpm) +
              " across your thinnest region (" + json_num(thinnest_mm) +
              " mm), so this run would emit loose fragments rather than a lattice. "
              "At a " + json_num(w_min_fc) +
              " mm strut line width that region admits cells from " +
              json_num(d.min_printable_cell_mm) + " mm (printability) up to " +
              json_num(thinnest_mm / perc_floor) + " mm (percolation).\n";
          // ── WHAT S2 CHANGED HERE (task 2026-08-05-lattice-cell-fit-mode).
          // This message used to say that setting "cell_mm" on a GRADED job WILL
          // NOT WORK, and it was correct: grading.cpp took max(target,
          // lattice_cell_printability_floor_mm), a floor evaluated at rho_MIN, so
          // a 1.2 mm target was silently raised to 4.6026 mm at a 0.42 bead and
          // landed straight back in this refusal (measured on his own geometry:
          // "planned cell 4.602619932 mm gives 0.8690702381 cells across").
          //
          // The override is FIXED (grading.cpp, the `abs_floor_mm` bound): a Fixed
          // target is now raised only to the cell below which NO density in the
          // band prints, and the density is raised with the cell. So the remedy
          // this message names is a remedy the code path no longer overrides.
          if (job.grading.present)
            why += "     A graded cell is raised only to " +
                   json_num(lattice_min_printable_cell_mm(topo, w_min_fc, job.grading.max_relative_density)) +
                   " mm (the cell below which no density in the band prints), and "
                   "the density is raised with it so the strut still clears your "
                   "strut line width.\n";
          if (thinnest_mm < d.min_member_width_certifiable_mm) {
            // ── N1/N2: say what the region will actually DO on this path, and
            // lead with the remedy the user can actually reach.
            why += "     Separately: a CERTIFIED lattice needs " +
                   json_num(d.min_member_width_certifiable_mm) +
                   " mm of member and your thinnest region has " +
                   json_num(thinnest_mm) + " mm. What that means here:\n";
            if (job.grading.present) {
              why += "       * GRADED run: the grading law falls sub-floor "
                     "candidates back to SOLID, so setting the cell alone will "
                     "get you past this refusal and STILL leave those regions "
                     "solid with no lattice in them.\n";
              // ★ CORRECTED (task 2026-08-07). This bullet used to read "THAT SWITCH
              // IS NOT EXPOSED IN THE APP … from the iPad this region cannot be
              // latticed at all today". Task 2026-08-05-lattice-retention-app-control
              // shipped the control; the sentence has been telling the maintainer to
              // give up on a switch that is on his own lattice page.
              why += "       * To lattice them anyway, arm "
                     "\"retain_subfloor_in_unloaded_regions\" (the app's \"Keep "
                     "lattice in thin members\" control, or the job-JSON key). The "
                     "lattice is then built and the certificate over it is OUT OF "
                     "REGIME — read the exposure the receipt reports before arming "
                     "it.\n";
              why += "       * OR set \"cell_mode\": \"fit\", which derives a "
                     "cell from each region's own extent, lattices it, and "
                     "reports the out-of-regime material it emitted — no "
                     "retention switch involved. Use fit when the regions differ "
                     "in thickness; use retention when they do not. They are "
                     "mutually exclusive, and core refuses a job that arms both.\n";
            } else {
              why += "       * UNIFORM run: no cells-per-member floor is applied "
                     "on this path, so a lattice in the range above WILL be built "
                     "here — CONNECTED but NOT CERTIFIED. The margin over it is "
                     "out of regime and lattice_strut_out_of_regime is raised.\n";
            }
          }
          msg = pf_compose(headline, action, why);
        } else {
          // (C) — percolates. Not a refusal. Report and continue.
          //
          // TWO SUB-CASES, and the second is the one M3 is about. The planned cell
          // still comes from lattice_cell_printability_floor_mm (rho_MIN); the
          // derivation is REPORTING-ONLY and feeds no cell selection. So a region
          // can be comfortably above the certifiable minimum and STILL have every
          // voxel rejected, because the planned cell is far coarser than the one
          // the derivation would pick. Saying so here costs a printf and saves a
          // whole solve — which is the entire point of a pre-flight.
          if (thinnest_mm >= d.min_member_width_certifiable_mm &&
              planned_cpm < n_star) {
            char n1[1024];
            std::snprintf(
                n1, sizeof(n1),
                "A cell of %.4f mm at relative density %.4f (strut %.4f mm) puts "
                "%.2f cells across your thinnest region and certifies — set it, or "
                "set \"cell_mode\": \"fit\" and core derives exactly that, per "
                "region.",
                d.lightest_cell_size_mm, d.lightest_relative_density,
                d.lightest_strut_diameter_mm, d.lightest_cells_per_member);
            char n1why[1024];
            std::snprintf(
                n1why, sizeof(n1why),
                "your thinnest declared region (%.3f mm) IS thick enough for a "
                "CERTIFIED lattice — it needs %.3f mm — but the planned %.4f mm "
                "cell puts only %.2f cells across it, under the %.2f-cell accuracy "
                "floor, so the grading law will reject it and emit no lattice. The "
                "cell is what is wrong, not the part. (\"cell_mode\": \"auto\" will "
                "NOT fix it: it selects the printability floor at the band's "
                "LIGHTEST density, %.4f mm, which is how you got here.)",
                thinnest_mm, d.min_member_width_certifiable_mm, cell_mm,
                planned_cpm, n_star, cell_mm);
            pf_print(pf_compose(
                std::to_string(thin_regions) + " of " +
                    std::to_string(include_regions) +
                    " declared lattice include regions will come back SOLID at the "
                    "planned " + json_num(cell_mm) + " mm cell.",
                std::string(n1), std::string(n1why)));
          }
          if (thinnest_mm < d.min_member_width_certifiable_mm) {
            // ── N1: WHAT ACTUALLY HAPPENS HERE DEPENDS ON THE PATH, and an
            // earlier version of this note said "the lattice will be built"
            // unconditionally. That is FALSE on a graded run and it set up
            // exactly the failure this branch exists to stop: clear pre-flight,
            // spend the solve, get a solid wall.
            //
            // GRADED — grade_lattice enforces the accuracy floor
            // (src/simp/grading.cpp:102 reads lattice_cells_per_member_min, and
            // note_member_too_thin at :20-28 records the fallback). A sub-floor
            // candidate is graded back to SOLID. That is the DEFAULT, and
            // flipping it is the entire purpose of
            // retain_subfloor_in_unloaded_regions.
            //
            // UNIFORM — no cells-per-member floor is applied anywhere on this
            // path. Every `cells_per_member` reference in this file outside the
            // grading receipt and this pre-flight is reporting only, and
            // lattice_strut_out_of_regime (src/simp/analyze.cpp:458-460) is a
            // FLAG, not a gate. That is why the maintainer's own uniform run
            // emitted 1131 cells at 0.4263 cells per member with
            // strut_out_of_regime true and strut_gated false.
            char n2why[1400];
            std::snprintf(
                n2why, sizeof(n2why),
                "your thinnest declared region (%.3f mm) percolates at the planned "
                "%.4f mm cell (%.2f cells across, percolation floor %.2f) but is "
                "BELOW the %.2f-cell accuracy floor, which needs %.3f mm. %s",
                thinnest_mm, cell_mm, planned_cpm, perc_floor, n_star,
                d.min_member_width_certifiable_mm,
                job.grading.present
                    ? "The grading law falls sub-floor candidates back to solid, "
                      "SO THOSE REGIONS WILL COME BACK SOLID and no lattice will "
                      "be emitted in them unless retention is armed — in which "
                      "case they are latticed and the certificate over them is "
                      "OUT OF REGIME."
                    : "The uniform path applies NO cells-per-member floor, so the "
                      "lattice WILL be built here and the certificate over it will "
                      "be OUT OF REGIME (lattice_strut_out_of_regime is raised; it "
                      "is a flag, not a gate). This is reported, not refused.");
            // ★ CORRECTED (task 2026-08-07): the graded arm used to end "That switch
            // is a job-JSON key and is NOT exposed in the app today, so on the iPad
            // this region cannot be latticed at all." Retention SHIPPED to the app in
            // task 2026-08-05-lattice-retention-app-control.
            pf_print(pf_compose(
                std::to_string(thin_regions) + " of " +
                    std::to_string(include_regions) +
                    " declared lattice include regions are under the accuracy "
                    "floor at the planned " + json_num(cell_mm) + " mm cell.",
                job.grading.present
                    ? std::string(
                          "ARM \"retain_subfloor_in_unloaded_regions\" (the app's "
                          "\"Keep lattice in thin members\" control) to lattice "
                          "them OUT OF REGIME — or set \"cell_mode\": \"fit\", "
                          "which derives a cell per region instead. The two are "
                          "mutually exclusive and core refuses a job arming both.")
                    : std::string(
                          "Nothing to set: this uniform run builds the lattice "
                          "anyway and stamps the certificate OUT OF REGIME."),
                std::string(n2why)));
          }
          std::fflush(stderr);
        }
        if (!msg.empty()) {
          msg += "\n     To proceed anyway with lattice OUTSIDE your declared "
                 "regions, remove the include regions from the lattice block — but "
                 "read the receipt first: this run would have put every cell in "
                 "material you did not select.";
          throw JobError(msg);
        }
      } else if (include_regions > 0) {
        // ── THE PATHS THE THREE-CASE MACHINE DOES NOT DECIDE, reported in the SAME
        // shape (S3). Two of them:
        //   * FIT with at least one feasible region. It never refuses — each region
        //     gets its own cell — but it must still SAY what each region derived, and
        //     that is exactly one table row per region.
        //   * A job that stated no strut line width. No derivation is possible, so
        //     there is no action to name; the table still reports what was declared.
        // This is where the old "FORECAST: N of M include regions are thinner than …"
        // summary lived, and it is the line that must not be lost: with no refusal and
        // no per-region paragraphs, silence would read as "everything is fine".
        std::string headline, action, why;
        if (pf_fit) {
          const double cert_mm =
              pf_fit_cells.empty() ? 0.0
                                   : pf_fit_cells.front().min_width_certifiable_mm;
          headline =
              thin_regions == 0
                  ? ("all " + std::to_string(include_regions) +
                     " declared lattice include regions certify at the cell FIT "
                     "derived for them (finest " + json_num(cell_mm) + " mm).")
                  : (std::to_string(thin_regions) + " of " +
                     std::to_string(include_regions) +
                     " declared lattice include regions cannot reach the " +
                     json_num(n_star) +
                     "-cell accuracy floor at the cell FIT derived for them "
                     "(thinnest region " + json_num(thinnest_mm) +
                     " mm; finest derived cell " + json_num(cell_mm) + " mm).");
          if (thin_regions > 0 && cert_mm > 0.0)
            action = "NOTHING TO SET — fit already picked the finest cell each "
                     "region can print. To CERTIFY a row marked OUT OF REGIME, "
                     "thicken that region to " + json_num(cert_mm) +
                     " mm; otherwise the part is buildable and the certificate "
                     "does not cover that material.";
          why = "fit derives cell = max(region extent / " + json_num(n_star) +
                ", the finest printable cell) per declared region, then raises the "
                "density with it so the strut still clears your strut line width. A "
                "region with fewer than " + json_num(n_star) +
                " cells across is BUILDABLE and its homogenized tensor stops "
                "describing the member, so the certificate over it is OUT OF REGIME "
                "— reported, never silently certified. A row marked SOLID has no "
                "(cell, density) pair that both prints and percolates at any "
                "setting.";
        } else {
          headline =
              std::to_string(thin_regions) + " of " +
              std::to_string(include_regions) +
              " declared lattice include regions are thinner than the " +
              json_num(required_mm) + " mm the accuracy floor requires at the "
              "planned " + json_num(cell_mm) + " mm cell (thinnest " +
              json_num(thinnest_mm) + " mm).";
          action = "This job states no strut line width, so core cannot derive a "
                   "cell that would work — state \"min_extrudable_width_mm\" and "
                   "this pre-flight will name the range.";
          why = "the cells-per-member floor needs " + json_num(n_star) +
                " x " + json_num(cell_mm) + " mm = " + json_num(required_mm) +
                " mm of material across a member before its homogenized tensor "
                "describes it. That is a property of the region's geometry and the "
                "printability floor (nozzle-derived), not of the optimizer and not "
                "of any Protect setting.";
        }
        pf_print(pf_compose(headline, action, why));
      }
    }
  }

  RunJobResult result;

  // §5 pipeline: import the part into the face-carrying StepModel every
  // downstream stage consumes. The FRONT DOOR is the ONLY format-aware line —
  // import_part_file dispatches on the extension (handoff 134):
  //   .step/.stp  ──OCCT B-rep──▶ StepModel  (REAL faces; the identical code
  //                                            path it always took, byte for byte)
  //   .stl / .3mf ──read+repair+segment──▶ StepModel  (PSEUDO-faces)
  // Everything after this point — the watertight check, voxelize, tag,
  // build_production_loadcase, the ladder, the report, the export — is written
  // against `StepModel` + `face_id` and does not know or care which door the
  // model came through. `model_is_mesh` is used ONLY to name the tagging call
  // honestly (tag_mesh_face vs tag_step_face); the two are identical.
  const std::string model_path = join_path(job_dir, job.model);
  const bool model_is_mesh =
      part_format_for_path(job.model) != PartFormat::Step;
  // import_part_file_resolved throws PartError on a read/parse failure, an
  // unavailable format (STEP without OCCT, 3MF without lib3mf), or a mesh REFUSED
  // by the Phase-1 inspection (non-manifold, open, non-orientable, zero-thickness).
  // Any of those is a job-level failure, so surface it as a JobError with the
  // core's own plain-language reason rather than letting PartError escape
  // run_job's documented JobError contract.
  //
  // `_resolved` (vs the bare `import_part_file`) applies a face-overrides sidecar
  // sitting next to the model if the app wrote one: the tuned segmentation
  // threshold and any PAINTED pseudo-faces (handoff 2026-07-24). With no sidecar
  // it is byte-for-byte the old import, so STEP jobs and un-painted mesh jobs are
  // unchanged. This is why the run reproduces exactly the faces the user saw and
  // painted — the load/anchor/clearance/protect face ids below resolve against
  // the SAME partition.
  try {
    result.model = import_part_file_resolved(model_path);
  } catch (const PartError& e) {
    throw JobError(std::string("cannot import model \"") + job.model +
                   "\": " + e.what());
  }

  // ──▶ watertight check (both modes AND both sources). For a STEP part this is
  // the unchanged tessellation check. For a mesh part the Phase-1 importer has
  // already REFUSED an open surface (OpenBoundary), so a mesh that reaches here
  // is watertight; the check is kept as a belt-and-suspenders guard that also
  // covers the (rare) tessellation that welds to a hole no defect scan caught.
  if (!check_watertight(result.model.mesh).watertight)
    throw JobError("model tessellation is not watertight: " + job.model);

  // Two modes, both driving the SAME production optimizer configuration as the
  // iPad app (handoff 093). THE ONE setup: build_job_setup above — the same call
  // preflight_job makes, so a pre-flight can never describe a different job than
  // the one that then runs (task 2026-08-03-preflight-feasibility-and-divergence).
  JobSetup setup = build_job_setup(job, result.model, model_is_mesh, materials);
  VoxelGrid grid = std::move(setup.grid);
  std::vector<DirichletBC> bcs = std::move(setup.bcs);
  MinimizePlasticOptions options = std::move(setup.options);
  ProductionLoadCase lc = std::move(setup.lc);
  std::string loadcase_receipt = std::move(setup.loadcase_receipt);
  result.fixture_face_ids = std::move(setup.fixture_face_ids);

  // ──▶ output dir (created before the run so streamed artifacts can land in it).
  {
    std::error_code ec;
    std::filesystem::create_directories(out_dir, ec);
    if (ec)
      throw JobError("cannot create output directory " + out_dir + ": " +
                     ec.message());
  }
  // The load-case receipt (bar Z2), beside the artifacts it describes. A new,
  // separate document — report.json / fields.bin / the meshes are untouched.
  result.loadcase_receipt_path = join_path(out_dir, "loadcase.json");
  result.loadcase_receipt_json = loadcase_receipt;
  write_text_file(result.loadcase_receipt_path, loadcase_receipt);

  // THE domain the run solves on — the expanded grid AND the BCs/loads remapped
  // onto it under a design box (resolve_design_domain, pipeline.hpp), verbatim
  // inputs without one. Needed up front so a streamed variant's mesh is resampled
  // on the right grid, and so the latticed re-certification below certifies under
  // the SAME load case minimize_plastic solves under — it is literally the same
  // object, not a second reconstruction of it (task
  // 2026-08-03-design-box-recertification).
  const SolvedDesignDomain domain = resolve_design_domain(grid, bcs, options);
  const VoxelGrid& solved_grid = domain.grid;
#ifndef NDEBUG
  // The two derivations agreed before this task by discipline; now they are the
  // same call. Asserted rather than commented (pure geometry, no solve).
  {
    const VoxelGrid mp = minimize_plastic_solved_grid(grid, options);
    assert(solved_grid.nx == mp.nx && solved_grid.ny == mp.ny &&
           solved_grid.nz == mp.nz && solved_grid.spacing == mp.spacing &&
           "the solved grid resolve_design_domain reports must be the grid "
           "minimize_plastic solves on");
  }
#endif

  // ──▶ PRE-FLIGHT LOAD-PATH CONNECTIVITY (task 2026-08-03-preflight-feasibility-
  // and-divergence, guard 1). BEFORE ANY SOLVE, with the clearances frozen and
  // the design domain resolved: can the load-tagged voxels reach the anchors
  // through voxels the optimizer is ALLOWED to fill? A flood fill — milliseconds
  // against the ten hours a severed job otherwise spends discovering it.
  //
  // REFUSE ONLY ON DISCONNECTION. Connectivity is necessary, not sufficient; a
  // connected-but-hopeless path still diverges, which is what guards 2 and 3 are
  // for. The narrowest-cross-section reading is reported as INFORMATION and never
  // refuses anything.
  const PreflightLoadPath preflight = preflight_load_path(domain, options);
  result.preflight = preflight;
  if (preflight.walk.decidable) {
    char buf[512];
    std::snprintf(
        buf, sizeof(buf),
        "[preflight] load path %s: %zu load voxels, %zu anchor voxels, %zu of "
        "%zu voxels allowed to hold material; narrowest separating "
        "cross-section %d voxels (%.4g mm^2) at %d/%d steps from the anchor; "
        "%.2f ms",
        preflight.walk.connected ? "CONNECTED" : "SEVERED",
        preflight.walk.load_voxels, preflight.walk.anchor_voxels,
        preflight.walk.printed_voxels, solved_grid.voxel_count(),
        preflight.walk.narrowest_separator_voxels,
        preflight.walk.narrowest_separator_mm2,
        preflight.walk.narrowest_separator_level, preflight.walk.geodesic_levels,
        preflight.wall_ms);
    std::fprintf(stderr, "%s\n", buf);
    std::fflush(stderr);
  }
  if (preflight.walk.decidable && !preflight.walk.connected) {
    const std::string why = preflight_refusal_report(
        result.model, grid, domain, options, lc, preflight,
        result.fixture_face_ids);
    // THE GUARDS ARE OBSERVABLE (bar P6) even when the guard REFUSES: write
    // run_info.json with the pre-flight block before throwing, so the refusal
    // leaves a machine-readable record beside the load-case receipt and not only
    // a line in a log.
    if (emit_progress) {
      RunInfo refused = build_run_info(job, options, obs);
      fill_run_info_preflight(refused, preflight);
      result.run_info_path = join_path(out_dir, "run_info.json");
      write_run_info(result.run_info_path, refused);
    }
    throw JobError(why);
  }

  // LOUD PARITY GATE (task: multigrid-odd-axis-cliff, O1/O2). Say at RUN START
  // what geometric multigrid will do on this grid. The motivating run solved
  // 128x31x118 — one odd axis — for six hours on Jacobi-CG, discoverable only
  // in run_info.json afterwards. Now: a grid the solver's parity pad rescues
  // gets a NOTE naming the odd axes and the padded shape; a grid that will
  // still reject its hierarchy gets a WARNING naming the offending axes, the
  // achievable level count and the concrete remedy shape. Coarsenable grids
  // stay silent. Pure prediction from the same rule the solver enforces
  // (topopt/coarsen.hpp); the post-run observed warning below is unchanged.
  if (options.simp.solver == SolverKind::MultigridCG ||
      options.simp.solver == SolverKind::MultigridCG_Matfree) {
    char banner[512];
    if (mg_startup_banner(solved_grid.nx, solved_grid.ny, solved_grid.nz,
                          fea_mg_parity_pad_mode() != 0, banner,
                          sizeof(banner)) != 0) {
      std::fprintf(stderr, "%s\n", banner);
      std::fflush(stderr);
    }
  }

  // Job wall clock start (lattice P6: generation time as a fraction of the whole
  // job). Captured here, after import/voxelize, so it spans the solve + export the
  // lattice generation competes with. An observer — never affects output bytes.
  const double job_t0 = wall_seconds();

  // Streaming (topopt-cli binary): print machine-parseable checkpoints and export
  // each accepted variant's mesh AS IT COMPLETES, so a wrapper can forward live
  // progress + progressive artifacts. Pure observers — the design/report/mesh
  // bytes are unchanged, so run_job stays deterministic (the default, false, is
  // the exact batch path the tests exercise). See job.hpp.
  // Handoff 114 — observability capture (CLI path only). run_info.json is written
  // now (config is finalized); the per-iteration CSV + density snapshots are wired
  // as read-only observers on `options`. Declared here so they outlive the
  // synchronous minimize_plastic call below. All artifacts land in out_dir.
  std::unique_ptr<IterationCsvWriter> csv;
  std::unique_ptr<SnapshotCapture> snaps;
  // Held across the run so its cg_multigrid / mg_levels can be finalized from the
  // OBSERVED solver outcome after minimize_plastic returns (below).
  RunInfo run_info;
  bool wrote_run_info = false;
  if (emit_progress) {
    run_info = build_run_info(job, options, obs);
    fill_run_info_preflight(run_info, preflight);
    result.run_info_path = join_path(out_dir, "run_info.json");
    write_run_info(result.run_info_path, run_info);
    wrote_run_info = true;
    if (obs.iteration_csv) {
      result.iteration_csv_path = join_path(out_dir, "iterations.csv");
      csv = std::make_unique<IterationCsvWriter>(result.iteration_csv_path);
      options.on_iteration = [&csv](std::size_t rung, std::size_t /*rungs*/,
                                    const SimpIterationObservation& o) {
        csv->append(rung, o);
      };
    }
    if (obs.density_snapshots) {
      snaps = std::make_unique<SnapshotCapture>(
          join_path(out_dir, "snapshots"), obs.snapshot_every, obs.snapshot_cap);
      options.on_density_snapshot = [&snaps](const DensitySnapshotEvent& ev) {
        snaps->capture(*ev.grid, *ev.density, ev.rung_index, ev.iteration,
                       ev.boundary);
      };
    }
  }

  // Lattice-export accumulator (handoff 2026-07-28-lattice-generation-production).
  // Summed over accepted variants so run_info records ONE posture for the run.
  // `wall_s` is the generation time only — its fraction of total job time is the
  // P6 bar (finalized after the run). Untouched when no lattice block is present.
  struct LatticeAgg {
    bool any = false;
    long long cells = 0, voxels = 0, tris = 0;
    int variants = 0;
    // Rungs the grading law could lattice NOTHING of, so nothing was emitted for
    // them and nothing of theirs entered the aggregates below (bar B3 / L3).
    // Counted rather than dropped silently: "3 of 4 rungs latticed" is a fact the
    // receipt has to carry, or the missing files look like a transport failure.
    int ungradeable_variants = 0;
    double r_min = 1e30, r_max = 0.0;
    double wall_s = 0.0;
    // THE ENCLOSED-VOID RULE (task 2026-08-05-lattice-void-reaches-exterior).
    // All zero and `void_check_ran` false unless the job armed
    // `require_lattice_void_reaches_exterior`, so a run that did not arm it
    // writes no key. `void_wall_s` is the CHECK's own time, kept out of `wall_s`
    // (which is generation) so the two costs are never conflated. Rungs the rule
    // REFUSED are counted like ungradeable ones and, like them, contribute
    // nothing to the aggregates below.
    bool void_check_ran = false;
    int void_sealed_variants = 0;
    int volume_refused_variants = 0;  // ★ Finding 7: rungs the volume check refused
    bool volume_check_ran = false;
    double volume_worst_gap = 0.0;     // the largest |gap| over every checked rung
    double volume_certified_mm3 = 0.0, volume_exported_mm3 = 0.0;  // accepted rungs
    long long void_sealed_cells = 0, void_sealed_voxels = 0;
    double void_sealed_volume_mm3 = 0.0;
    long long void_latticed_reached = 0, void_latticed_cells = 0;
    double void_reachable_volume_mm3 = 0.0;
    long long void_bfs_visits = 0;
    int void_escape_depth_max = -1;
    bool void_face_escapes[6] = {false, false, false, false, false, false};
    long long void_sealed_pockets_without_lattice = 0;
    double void_wall_s = 0.0;
    // Boundary finish (handoff 2026-07-29-lattice-boundary-finish): what the
    // clip/skin passes did, summed over variants — B9's volume accounting.
    long long clipped = 0, landings = 0, anchors = 0;
    long long skin_tris = 0, rim_tris = 0;
    double interior_vol = 0.0, skin_vol = 0.0, rim_vol = 0.0;
    // Freeform skin (task 2026-07-30-lattice-skin-freeform): chord accounting,
    // summed over variants. All zero on the default "shell" finish.
    long long chords = 0, chords_band = 0, chords_proj = 0, chords_clipped = 0;
    // Certification posture (E2E bars E1/E3), summed over accepted latticed variants
    // so run_info records ONE posture. rho is uniform (same for every variant) so its
    // range is a point; the margins are the WORST (min) over the variants — the
    // conservative run-level summary — while each variant's receipt carries its exact
    // numbers.
    bool cert_ran = false;
    double rho_lo = 1e30, rho_hi = 0.0;
    long long cert_voxels = 0;
    double lat_margin_min = 1e300, lat_margin_eff_min = 1e300;
    bool lat_accepted_all = true;
    bool strut_uncertified = false;
    // Strut-strength REPORT (task 2026-07-31-lattice-strut-strength-report):
    // run-level worst (min over latticed variants) of the report-only margins —
    // like the certified margins above, conservative summary here, exact numbers
    // in each variant's receipt. NEVER a gate input.
    bool strut_report = false;
    double strut_in_plane_min = 1e300, strut_il_min = 1e300,
           strut_worst_min = 1e300;
    double strut_zk = 0.0, strut_cpm_min = 1e300;
    bool strut_oor = false;  // any variant out of the cells-per-member regime
    long long strut_clamped = 0;  // summed law-span rho clamps (bar L5)
    // Lattice roles + solid companion (task lattice-page-core-hookup stage 1),
    // summed over variants like the counters above. All zero/false on a job
    // with no lattice.regions and no grading — run_info stays byte-identical.
    bool roles_present = false;
    long long include_regions = 0, exclude_regions = 0;
    long long solid_voxels = 0, solid_tris = 0, include_void = 0;
    double solid_vol = 0.0;
    // Include-void by CAUSE, and the frozen-material split (task 2026-08-04-
    // protect-freeze-vs-solidity). Summed over variants like everything above.
    long long include_void_clearance = 0;
    long long frozen_printed = 0, frozen_latticed = 0, frozen_solid = 0;
    long long frozen_not_emitted = 0, frozen_both = 0;
    long long frozen_unexplained = 0, frozen_excl_latticed = 0;
    // Graded run (stage 4): run_info's "grading" object records the LAST graded
    // variant's law report (each variant's own full record — including field
    // provenance and clamp counts — lives in its receipt). Scalars only.
    bool graded = false;
    double g_cell = 0.0, g_floor = 0.0;
    bool g_floored = false;
    double g_band_lo = 0.0, g_band_hi = 0.0, g_cpm_floor = 0.0;
    double g_rho_lo = 0.0, g_rho_hi = 0.0;
    long long g_region = 0, g_latticed = 0, g_fallback = 0;
    double g_min_width = 0.0, g_min_cpm = 0.0, g_min_d = 0.0, g_max_d = 0.0;
    bool g_below_min = false, g_ungradeable = false;
    // The CELL-SIZE plan record, carried verbatim from the last graded variant
    // (handoff 2026-08-01-lattice-cell-size-sweep). Held as a RunInfo so the ONE
    // filler used by analyze_job serves this path too — the two receipts cannot
    // drift.
    RunInfo g_cell_ri;
  } lat_agg;
  std::vector<std::string> lattice_paths;  // merged into result.mesh_paths at end
  std::map<double, std::vector<std::string>> lattice_paths_by_vf;  // E1: per version
  // Emit ONE accepted variant's latticed companion: generate the mesh, RE-CERTIFY it
  // against the octet tensor (bar E1 — the margin then describes the exported file,
  // not the solid design), write the per-variant certification receipt, fold both into
  // the accumulator, and (streaming path) print a machine-parseable LATTICE checkpoint
  // carrying the LATTICED margin so the worker forwards the right verdict.
  // The lattice keep-outs (protected features): resolved ONCE per job from the
  // declared clearances via the existing clearance machinery. Empty when no
  // loads/clearances are declared — the boundary is then just the solid design.
  const std::vector<ClearanceGeometry> lattice_kos =
      job.lattice.present
          ? lattice_keep_outs_from_job(job, result.model)
          : std::vector<ClearanceGeometry>{};
  // The job's lattice ROLE regions (stage 1), resolved once — empty on a job
  // with no lattice.regions (byte-identical path).
  const LatticeRoleRegions lattice_roles =
      job.lattice.present
          // `grid` here IS the part grid build_production_loadcase voxelized
          // (the solved domain expands it later); a region's voxels live on the
          // part, so that is the lattice the mask is built in.
          ? lattice_role_regions_from_job(job, &result.model, &grid)
          : LatticeRoleRegions{};

  // ★ REFUSE HERE, BEFORE THE SOLVE (task 2026-08-16-per-sector-density-override).
  // Both region refusals — infeasible geometry and an unprintable stated density —
  // also run inside the grading step below, which is where they were born. But
  // that step runs PER VARIANT, AFTER minimize_plastic: on his part that is over
  // an hour of solving before the user is told a number they typed cannot print.
  // A refusal that arrives after the work is nearly worthless.
  //
  // Everything both checks read is already known at this point: the job, and the
  // regions resolved against the part grid one statement above. Nothing here
  // needs the solved design. The pre-flight is EARLIER still and cannot host
  // this — it runs before the import, so a "region" kind has no body to measure
  // there (that is exactly why the pre-flight skips-and-counts them).
  //
  // ★ The copies below stay. This is a duplicate guard, not a move: the grading
  // step is reached by other callers, and a refusal must not depend on which
  // entry point ran. Identical inputs, identical predicate, so the two cannot
  // disagree — the first one to see the job wins, and that is this one.
  if (job.lattice.present && !lattice_roles.includes.empty()) {
    CellSizeMode preflight_mode = CellSizeMode::Fixed;
    if (resolve_cell_mode(job.grading.cell_mode, preflight_mode) &&
        preflight_mode == CellSizeMode::Fit) {
      const LatticeTopology job_topo = lattice_topology_from_id(job.grading.topology);
      const std::vector<FitRegionCell> early_cells = fit_region_cells(
          job, job_topo, job.grading.min_extrudable_width_mm, &lattice_roles);
      refuse_infeasible_region_lattice(job, early_cells,
                                       job.grading.min_extrudable_width_mm);
      refuse_unprintable_stated_density(job, early_cells, job_topo,
                                        job.grading.min_extrudable_width_mm);
    }
  }

  // ── MULTISCALE LATTICE TO (task multiscale-lattice-to) ─────────────────────
  // Arm the optimizer's lattice material law for THIS job, if the job asked and
  // production permits. Absent `lattice.multiscale` => nothing here runs and the
  // ladder below is the two-step pipeline, byte-for-byte.
  //
  // REFUSALS ARE LOUD. A job that asks for multiscale on a mode with no optimizer,
  // or while production withholds the permission, is refused with a message that
  // says which — it is never silently downgraded to the two-step, because the whole
  // point of the flag is that the two-step does not work here.
  if (job.lattice.present && job.lattice.multiscale) {
    if (!production_multiscale_lattice_to())
      throw JobError(
          "run_job: lattice.multiscale was requested but this build withholds the "
          "permission (production_multiscale_lattice_to() is false)");
    options.multiscale_lattice = true;
    // The job's type. minimize_plastic refuses any type whose material model cannot
    // steer a design loop (lattice_material_model_trustworthy), naming why.
    options.multiscale_topology = lattice_topology_from_id(job.grading.topology);
    options.multiscale_region =
        multiscale_region_mask(solved_grid, lattice_kos, lattice_roles);
    options.multiscale_floor_cell_mm = multiscale_floor_cell_mm(job);
    // The floor is measured every iteration: the whole reason it is reported is to
    // make a design starving its members visible AS IT HAPPENS. The measurement is
    // an EDT over the design; it is charged honestly in the cost table rather than
    // hidden behind a coarse stride.
    options.multiscale_floor_stride = 1;
    // ── LENGTH-SCALE CONTROL FROM THE FLOOR (task multiscale-lattice-to) ─────
    // THE MEASURED REASON THIS EXISTS. Multiscale legalizes intermediate
    // density, and the optimizer exploits that by SPREADING material into thin
    // diffuse webs — which is exactly what the cells-per-member floor forbids.
    // Measured on a control fixture whose region was fully reachable and whose
    // ceiling admitted 10,002 of 10,040 voxels: the two-step latticed 19.0 % and
    // multiscale latticed 0.8 %, with 71 % of the multiscale design's members
    // spanning under 5 cells. SIMP's rho^3 was accidentally PROTECTING
    // latticeability by forcing consolidation; removing the penalization removed
    // that protection with nothing put back.
    //
    // The fix is length-scale control, not a constraint fighting the objective:
    // the density filter's radius sets the smallest member the design can
    // EXPRESS, so a radius derived from the floor makes a sub-floor member
    // inexpressible rather than merely unrewarded. This is standard minimum-
    // length-scale practice and it is a reparametrization — the objective, the
    // gate and the tolerance are untouched.
    //
    // THE ARITHMETIC. A member must span floor_cells * cell_mm to be latticeable.
    // The filter's length parameter in this codebase is a RADIUS (physical_filter
    // _radius divides min_feature_mm by the spacing), and a cone filter of radius
    // R yields a minimum member half-width ~R, so the member width it enforces is
    // ~2R. Hence min_feature_mm = floor_cells * cell_mm / 2.
    //
    // NEVER LOWERS what the job already asked for: max() with the incoming value,
    // so a job demanding a coarser feature size keeps it.
    {
      const double floor_cells =
          lattice_cells_per_member_min(options.multiscale_topology);
      const double implied_mm =
          0.5 * floor_cells * options.multiscale_floor_cell_mm;
      const double was = options.min_feature_mm;
      if (implied_mm > options.min_feature_mm) options.min_feature_mm = implied_mm;
      run_info.multiscale_min_feature_implied_mm = implied_mm;
      run_info.multiscale_min_feature_used_mm = options.min_feature_mm;
      std::fprintf(stderr,
                   "[multiscale] length scale: floor %.1f cells x %.4f mm = "
                   "%.3f mm member => min_feature %.3f mm (was %.3f mm)%s\n",
                   floor_cells, options.multiscale_floor_cell_mm,
                   2.0 * implied_mm, options.min_feature_mm, was,
                   implied_mm > was ? " RAISED" : " (job already coarser)");
    }
    // ── IS THE REGION EVEN OPTIMIZABLE? ──────────────────────────────────────
    // A lattice region is only reachable by the optimizer where the design mask
    // leaves it ACTIVE. A voxel the mask pinned FrozenSolid — a declared load or
    // fixture face, or a face-protection collar — is held at density 1 for the
    // whole run and can never become lattice, in ANY formulation. Counted and
    // reported here because it is the difference between "the optimizer chose
    // not to lattice this" and "nothing could have", and because a job that
    // declares its lattice region ON a protected face is asking for two
    // incompatible things and should be told so at the start rather than shown
    // an empty receipt at the end.
    {
      const DesignMask dm = design_domain_mask(domain, options);
      std::size_t active = 0, frozen_solid = 0, frozen_void = 0, empty = 0;
      for (std::size_t e = 0; e < options.multiscale_region.size(); ++e) {
        if (!options.multiscale_region[e]) continue;
        switch (dm[e]) {
          case MaskValue::Active: ++active; break;
          case MaskValue::FrozenSolid: ++frozen_solid; break;
          case MaskValue::FrozenVoid: ++frozen_void; break;
          default: ++empty; break;
        }
      }
      const std::size_t total = active + frozen_solid + frozen_void + empty;
      std::fprintf(stderr,
                   "[multiscale] region reachability: active=%zu frozen_solid=%zu "
                   "frozen_void=%zu empty=%zu (of %zu)\n",
                   active, frozen_solid, frozen_void, empty, total);
      if (total > 0 && active * 2 < total)
        std::fprintf(stderr,
                     "[multiscale] WARNING: %.1f%% of the declared lattice region "
                     "is NOT optimizable (pinned by the design mask — a declared "
                     "load/fixture face or a face-protection collar). Material "
                     "there is held SOLID for the whole run and can never become "
                     "lattice, in this or any formulation. If a latticed interior "
                     "is the goal, the lattice region and the protected faces are "
                     "asking for incompatible things.\n",
                     100.0 * static_cast<double>(total - active) /
                         static_cast<double>(total));
      run_info.multiscale_region_active = static_cast<long long>(active);
      run_info.multiscale_region_frozen_solid =
          static_cast<long long>(frozen_solid);
      run_info.multiscale_region_frozen_void = static_cast<long long>(frozen_void);
    }
    std::fprintf(stderr,
                 "[multiscale] armed: topology=%s region_voxels=%zu "
                 "floor_cell=%.4f mm floor_cells=%.1f\n",
                 lattice_topology_name(options.multiscale_topology),
                 static_cast<std::size_t>(
                     std::count_if(options.multiscale_region.begin(),
                                   options.multiscale_region.end(),
                                   [](char c) { return c != 0; })),
                 options.multiscale_floor_cell_mm,
                 lattice_cells_per_member_min(options.multiscale_topology));
    std::fflush(stderr);
  }

  auto emit_lattice = [&](const MinimizePlasticVariant& v, bool stream_lines) {
    if (!job.lattice.present) return;
    const bool roles_present = !job.lattice.regions.empty();
    // THE per-variant lattice pipeline — grade, boundary, mask, geometry,
    // composite certification, receipt — lives in ONE function (see
    // lattice_one_variant), shared with the re-lattice entry point so a variant
    // latticed later goes through the identical body. This lambda is now only
    // the run-level AGGREGATION and the streaming checkpoint line.
    const LatticeVariantOutcome R =
        lattice_one_variant(v, job, grid, domain, options, material,
                            lattice_kos, lattice_roles, out_dir, nullptr, &result.model);
    // ── THIS RUNG PRODUCED NO LATTICE (task
    // 2026-08-04-variant-volume-fraction-mismatch, bar B3 / L3).
    //
    // Skipped BEFORE the aggregation, and that is the point. The aggregates take
    // a MIN over rungs — `lat_agg.r_min = min(r_min, min_strut_diameter/2)`,
    // `lat_agg.rho_lo = min(rho_lo, gf.rho_min_used)` — and an ungradeable rung
    // carries both of those as 0, because grading.cpp only assigns them when
    // `latticed_voxels > 0`. One thin rung therefore dragged the WHOLE run's
    // report to zero. That is the "filled at 0% density … strut radius
    // 0.00–0.65 mm" the maintainer read: MEASURED in worker run
    // 4dabe3b8512d4d59, whose other rungs latticed 132 cells at radii up to
    // 0.645 mm perfectly well. Nothing was wrong with those rungs; the run-level
    // minimum was reading a rung that had no struts at all.
    if (R.ungradeable) {
      std::fprintf(stderr, "[lattice] vf=%.2f NO LATTICE EMITTED — %s\n",
                   v.requested_volume_fraction, R.ungradeable_reason.c_str());
      std::fflush(stderr);
      // `any` is still set: a lattice WAS requested and attempted, and a run
      // whose every rung was ungradeable must still write a lattice_export
      // record saying so. Silence there would read as a transport failure.
      lat_agg.any = true;
      ++lat_agg.ungradeable_variants;
      return;
    }
    // THE ENCLOSED-VOID RULE (task 2026-08-05-lattice-void-reaches-exterior).
    // Aggregated FIRST, and unconditionally on `void_check_ran`, so a PASS is
    // recorded too — a run whose receipt only spoke when something was wrong
    // would be indistinguishable from a run where the check never fired.
    if (R.void_check_ran) {
      const LatticeVoidEscapeReport& vr = R.void_report;
      lat_agg.void_check_ran = true;
      lat_agg.void_wall_s += R.void_check_seconds;
      lat_agg.void_bfs_visits += vr.bfs_visits;
      lat_agg.void_latticed_reached += vr.latticed_reached;
      lat_agg.void_latticed_cells += vr.latticed_cells;
      lat_agg.void_reachable_volume_mm3 += vr.reachable_escape_volume_mm3;
      lat_agg.void_sealed_pockets_without_lattice +=
          vr.sealed_pockets_without_lattice;
      if (vr.lattice_escape_depth > lat_agg.void_escape_depth_max)
        lat_agg.void_escape_depth_max = vr.lattice_escape_depth;
      for (int f = 0; f < 6; ++f)
        if (vr.face_escapes[f]) lat_agg.void_face_escapes[f] = true;
      if (R.void_sealed) {
        lat_agg.void_sealed_cells += vr.sealed_cells;
        lat_agg.void_sealed_voxels += vr.latticed_sealed;
        lat_agg.void_sealed_volume_mm3 += vr.sealed_volume_mm3;
      }
    }
    // The REFUSAL, on the ladder: skip this rung, say so, and — exactly as for
    // an ungradeable rung — leave it OUT of the aggregates below, which take
    // MINs that a rung with no geometry would drag to zero. The other rungs are
    // unaffected; one unlatticeable rung must not destroy the run's output.
    if (R.void_sealed) {
      std::fprintf(stderr, "[lattice] vf=%.2f NO LATTICE EMITTED — %s\n",
                   v.requested_volume_fraction, R.void_sealed_reason.c_str());
      std::fflush(stderr);
      lat_agg.any = true;
      ++lat_agg.void_sealed_variants;
      return;
    }
    if (R.volume_check.ran) {
      lat_agg.volume_check_ran = true;
      if (R.volume_check.worst_gap < lat_agg.volume_worst_gap)
        lat_agg.volume_worst_gap = R.volume_check.worst_gap;
      if (!R.volume_refused) {
        lat_agg.volume_certified_mm3 += R.volume_check.certified_mm3;
        lat_agg.volume_exported_mm3 += R.volume_check.exported_mm3;
      }
    }
    // ★ Finding 7: the volume check's refusal skips the rung the same way.
    if (R.volume_refused) {
      std::fprintf(stderr, "[lattice] vf=%.2f NO LATTICE EMITTED — %s\n",
                   v.requested_volume_fraction, R.volume_refused_reason.c_str());
      std::fflush(stderr);
      lat_agg.any = true;
      ++lat_agg.volume_refused_variants;
      return;
    }
    lat_agg.wall_s += R.gen_seconds;
    const LatticeExportOutcome& oc = R.oc;
    const LatticeCertOutcome& cc = R.cc;
    const GradedField& gf = R.gf;
    const bool graded = R.graded;
    const double cell = R.cell_mm;
    const LatticeRoleReceipt& role_rcpt = R.role_rcpt;
    const std::string& rcpt_path = R.receipt_path;

    lat_agg.any = true;
    // Role / companion / grading aggregation (stages 1+4).
    if (roles_present) {
      lat_agg.roles_present = true;
      lat_agg.include_regions =
          static_cast<long long>(lattice_roles.includes.size());
      lat_agg.exclude_regions =
          static_cast<long long>(lattice_roles.excludes.size());
      lat_agg.include_void += role_rcpt.include_void_voxels;
      lat_agg.include_void_clearance += role_rcpt.include_void_by_clearance;
    }
    // ── FROZEN MATERIAL, PER VARIANT, ON STDERR (task 2026-08-04-protect-freeze-
    // vs-solidity). The maintainer's whole case was invisible because nothing
    // ever said it: 91.5 % of his declared lattice region was frozen, and the
    // receipt he read had no word for that. This line says it at the moment it
    // becomes true, in the same place every other per-variant fact is logged.
    //
    // *** IT IS NOT A WARNING, AND MUST NOT BECOME ONE. *** Lattice over frozen
    // material is a legitimate, now-expressible intent ("do not reshape this
    // wall, but DO lattice inside it"). Warning on it would train users away
    // from the thing they are supposed to be able to do. The warning below
    // fires on the case that IS unsatisfiable: an include region over a
    // clearance void, where there is no material to lattice and never will be.
    const LatticeFrozenReceipt& fz = R.frozen_rcpt;
    if (fz.present) {
      lat_agg.frozen_printed += fz.frozen_printed;
      lat_agg.frozen_latticed += fz.frozen_latticed;
      lat_agg.frozen_solid += fz.frozen_kept_solid;
      lat_agg.frozen_not_emitted += fz.frozen_cells_not_emitted;
      lat_agg.frozen_both += fz.frozen_voxels_strut_and_solid;
      lat_agg.frozen_unexplained += fz.frozen_strut_and_solid_unexplained;
      lat_agg.frozen_excl_latticed += fz.frozen_in_exclude_latticed;
      std::fprintf(stderr,
                   "[lattice] vf=%.2f frozen material: printed=%lld latticed=%lld "
                   "solid=%lld in_include=%lld in_exclude=%lld/%lld latticed "
                   "(audit: cells_not_emitted=%lld strut_and_solid=%lld "
                   "unexplained=%lld)\n",
                   v.requested_volume_fraction, fz.frozen_printed,
                   fz.frozen_latticed, fz.frozen_kept_solid,
                   fz.frozen_in_include, fz.frozen_in_exclude_latticed,
                   fz.frozen_in_exclude, fz.frozen_cells_not_emitted,
                   fz.frozen_voxels_strut_and_solid,
                   fz.frozen_strut_and_solid_unexplained);
    }
    // THE WARNING, AIMED AT THE THING THAT CANNOT WORK: an include region over a
    // declared keep-clear. There is no material there and no rung, cell size or
    // formulation can put any there — unlike frozen material (which is material,
    // and can be latticed) or optimizer-removed material (which a heavier rung
    // may carry). This is the ONLY lattice-region overlap that is a real
    // conflict, so it is the only one that warns.
    if (role_rcpt.include_void_by_clearance > 0)
      std::fprintf(stderr,
                   "[lattice] WARNING: vf=%.2f — %lld voxels of the declared "
                   "lattice INCLUDE region fall inside a declared \"Keep clear\" "
                   "region. A keep-clear is a hole: there is no material there "
                   "to lattice, and no rung or cell size can create any. Move "
                   "the include region off the keep-clear, or drop the "
                   "keep-clear.\n",
                   v.requested_volume_fraction,
                   role_rcpt.include_void_by_clearance);
    if (oc.solid_companion) {
      lat_agg.solid_voxels += oc.solid_region_voxels;
      lat_agg.solid_vol += oc.solid_region_volume_mm3;
      lat_agg.solid_tris += static_cast<long long>(oc.solid_region_triangles);
    }
    if (graded) {
      lat_agg.graded = true;
      lat_agg.g_cell = gf.cell_size_mm;
      lat_agg.g_floor = gf.printability_floor_mm;
      lat_agg.g_floored = gf.cell_size_floored;
      lat_agg.g_band_lo = gf.band_rho_min;
      lat_agg.g_band_hi = gf.band_rho_max;
      lat_agg.g_cpm_floor = gf.cells_per_member_floor;
      lat_agg.g_rho_lo = gf.rho_min_used;
      lat_agg.g_rho_hi = gf.rho_max_used;
      lat_agg.g_region = static_cast<long long>(gf.region_voxels);
      lat_agg.g_latticed = static_cast<long long>(gf.latticed_voxels);
      lat_agg.g_fallback = static_cast<long long>(gf.solid_fallback_voxels);
      lat_agg.g_min_width = gf.min_member_width_mm;
      lat_agg.g_min_cpm = gf.min_cells_per_member;
      lat_agg.g_min_d = gf.min_strut_diameter_mm;
      lat_agg.g_max_d = gf.max_strut_diameter_mm;
      lat_agg.g_below_min = gf.any_strut_below_min;
      lat_agg.g_ungradeable = gf.region_ungradeable;
      fill_grading_cell_plan(lat_agg.g_cell_ri, gf);
      fill_grading_fit(lat_agg.g_cell_ri, gf, job, &lattice_roles);
      if (gf.cell_mode == CellSizeMode::Fit)
        fill_fit_region_voxels(lat_agg.g_cell_ri, solved_grid,
                               v.optimization.physical_density,
                               run_printed_iso(options), lattice_roles.includes, gf);
      fill_grading_subfloor(lat_agg.g_cell_ri, gf);
      // ── ★ THE PLAN'S OWN RECEIPTS, ON THIS PATH TOO (found by running his job) ──
      // This path -- the ladder, which is what `lattice-variant` takes on his jobs --
      // aggregates per-variant lattice numbers into `lat_agg` and copies a hand-kept
      // list into run_info. The plan receipts (K3's remainder, K4's per-region detail,
      // K5's density reach, ruling 2's clip volume) were wired only into the OTHER
      // receipt writer, the single-variant one at lattice_variant_job's tail. So every
      // one of them was absent from run_info on 570B38E2 -- the run printed them on
      // stderr and the receipt did not carry one.
      //
      // Found by running HIS job and reading the file, not by reading the code: my own
      // fixtures take the single-variant path, where the keys were there all along. A
      // receipt wired into one of two writers is a receipt that is missing exactly where
      // it is needed.
      //
      // Carried from the last graded variant, which is the convention every grading
      // field above already follows (g_cell_ri's own comment says so). The plan's cells,
      // regions, passes, sizes and phases are identical across rungs -- they are the
      // job's -- so only the LAID counts and the voxel-basis volumes are rung-dependent.
      lat_agg.g_cell_ri.stepped_anystep_cells = R.anystep_cells;
      lat_agg.g_cell_ri.stepped_anystep_regions = R.anystep_regions;
      lat_agg.g_cell_ri.stepped_anystep_passes = R.anystep_passes;
      lat_agg.g_cell_ri.stepped_anystep_histogram = R.anystep_histogram;
      lat_agg.g_cell_ri.stepped_anystep_rho_by_size = R.anystep_rho_by_size;
      lat_agg.g_cell_ri.stepped_plan_solid_remainder_mm3 = R.plan_solid_remainder_mm3;
      lat_agg.g_cell_ri.stepped_plan_latticed_mm3 = R.plan_latticed_mm3;
      lat_agg.g_cell_ri.stepped_plan_rho_fallback_by_region =
          R.plan_rho_fallback_by_region;
      lat_agg.g_cell_ri.stepped_clip_outside_region_mm3 = R.clip_outside_region_mm3;
      lat_agg.g_cell_ri.stepped_clip_outside_by_cause_mm3 = R.clip_outside_by_cause_mm3;
      lat_agg.g_cell_ri.stepped_plan_rho_queries_plan = R.plan_rho_queries_plan;
      lat_agg.g_cell_ri.stepped_plan_rho_queries_posture = R.plan_rho_queries_posture;
      lat_agg.g_cell_ri.stepped_plan_rho_queries_floor = R.plan_rho_queries_floor;
      lat_agg.g_cell_ri.stepped_plan_by_region = R.plan_by_region;
      lat_agg.g_cell_ri.stepped_plan_laid_unattributed = R.plan_laid_unattributed;
      lat_agg.g_cell_ri.stepped_plan_laid_measured = R.plan_laid_measured;
      lat_agg.g_cell_ri.stepped_law_ungradeable_reported = R.law_ungradeable_reported;
      lat_agg.g_cell_ri.stepped_law_ungradeable_note = R.law_ungradeable_note;
      lat_agg.g_cell_ri.lattice_outline_beam_mm = R.outline_beam_mm;
      lat_agg.g_cell_ri.lattice_outline_bleed_mm = R.outline_bleed_mm;
      lat_agg.g_cell_ri.lattice_outline_inward_mm = R.outline_inward_mm;
      lat_agg.g_cell_ri.lattice_outline_voxels = R.outline_beam_voxels;
    }
    lat_agg.cells += oc.stats.latticed_cells;
    lat_agg.voxels += oc.region_voxels;
    lat_agg.tris += static_cast<long long>(oc.stats.triangles);
    lat_agg.clipped += static_cast<long long>(oc.stats.clipped_struts);
    lat_agg.landings += static_cast<long long>(oc.stats.landings);
    lat_agg.anchors += static_cast<long long>(oc.stats.anchor_nodes);
    lat_agg.skin_tris += static_cast<long long>(oc.stats.skin_triangles);
    lat_agg.rim_tris += static_cast<long long>(oc.stats.rim_triangles);
    lat_agg.interior_vol += oc.stats.interior_volume_mm3;
    lat_agg.skin_vol += oc.stats.skin_volume_mm3;
    lat_agg.rim_vol += oc.stats.rim_volume_mm3;
    lat_agg.chords += static_cast<long long>(oc.stats.skin_chords);
    lat_agg.chords_band +=
        static_cast<long long>(oc.stats.skin_chords_rejected_band);
    lat_agg.chords_proj +=
        static_cast<long long>(oc.stats.skin_chords_rejected_projection);
    lat_agg.chords_clipped +=
        static_cast<long long>(oc.stats.skin_chords_clipped_away);
    ++lat_agg.variants;
    lat_agg.r_min = std::min(lat_agg.r_min, oc.stats.min_strut_diameter_mm / 2.0);
    lat_agg.r_max = std::max(lat_agg.r_max, oc.stats.max_strut_diameter_mm / 2.0);
    lat_agg.cert_ran = true;
    // Graded runs have no uniform rho — the certified range is the law's
    // achieved band; uniform runs keep the point value.
    lat_agg.rho_lo =
        std::min(lat_agg.rho_lo, graded ? gf.rho_min_used : cc.rho);
    lat_agg.rho_hi =
        std::max(lat_agg.rho_hi, graded ? gf.rho_max_used : cc.rho);
    lat_agg.cert_voxels += static_cast<long long>(cc.lattice.lattice_voxels);
    lat_agg.lat_margin_min =
        std::min(lat_agg.lat_margin_min, cc.lattice.margin.worst_case);
    lat_agg.lat_margin_eff_min =
        std::min(lat_agg.lat_margin_eff_min, cc.lattice.margin_effective);
    // The run-level verdict uses the same upstream finish refusal as the
    // receipt: a "skin" finish is never reported accepted (finish_note there).
    const bool eff_accepted =
        cc.lattice.accepted && job.lattice.outer_finish != "skin";
    lat_agg.lat_accepted_all = lat_agg.lat_accepted_all && eff_accepted;
    lat_agg.strut_uncertified =
        lat_agg.strut_uncertified || cc.lattice.lattice_strength_uncertified;
    // Strut-strength report roll-up (report-only; min = worst variant).
    if (cc.lattice.lattice_strut_report) {
      const StrutStrengthReport& ss = cc.lattice.lattice_strut;
      lat_agg.strut_report = true;
      lat_agg.strut_in_plane_min =
          std::min(lat_agg.strut_in_plane_min, ss.margin_in_plane);
      lat_agg.strut_il_min = std::min(lat_agg.strut_il_min, ss.margin_interlayer);
      lat_agg.strut_worst_min =
          std::min(lat_agg.strut_worst_min, ss.margin_worst_case);
      lat_agg.strut_zk = ss.z_knockdown_used;
      lat_agg.strut_cpm_min = std::min(lat_agg.strut_cpm_min,
                                       cc.lattice.lattice_min_cells_per_member);
      lat_agg.strut_oor =
          lat_agg.strut_oor || cc.lattice.lattice_strut_out_of_regime;
      lat_agg.strut_clamped += static_cast<long long>(ss.rho_clamped_voxels);
    }
    lattice_paths.insert(lattice_paths.end(), oc.paths.begin(), oc.paths.end());
    lattice_paths_by_vf[v.requested_volume_fraction].insert(
        lattice_paths_by_vf[v.requested_volume_fraction].end(), oc.paths.begin(), oc.paths.end());
    if (stream_lines)
      for (const std::string& p : oc.paths) {
        if (graded) {
          // Graded line (NEW with stage 4 — no pre-existing consumer): the
          // uniform strut_r/rho keys would be lies here, so the line carries
          // graded=1 + the achieved rho RANGE instead. Key=value tokens, same
          // discipline as the uniform line.
          std::printf(
              "LATTICE vf=%.6f topology=%s cell_mm=%.6g graded=1 rho_min=%.6g "
              "rho_max=%.6g cells=%lld tris=%llu lattice_margin=%.6g "
              "lattice_accepted=%d report=%s mesh=%s\n",
              v.requested_volume_fraction, job.lattice.topology.c_str(), cell,
              gf.rho_min_used, gf.rho_max_used, oc.stats.latticed_cells,
              (unsigned long long)oc.stats.triangles,
              cc.lattice.margin.worst_case, eff_accepted ? 1 : 0,
              rcpt_path.c_str(), p.c_str());
        } else {
          std::printf(
              "LATTICE vf=%.6f topology=%s cell_mm=%.6g strut_r_mm=%.6g rho=%.6g "
              "cells=%lld tris=%llu lattice_margin=%.6g lattice_accepted=%d "
              "report=%s mesh=%s\n",
              v.requested_volume_fraction, job.lattice.topology.c_str(),
              job.lattice.cell_mm, job.lattice.strut_radius_mm, cc.rho,
              oc.stats.latticed_cells, (unsigned long long)oc.stats.triangles,
              cc.lattice.margin.worst_case, eff_accepted ? 1 : 0,
              rcpt_path.c_str(), p.c_str());
        }
        std::fflush(stdout);
      }
  };

  // Fold the summed lattice EXPORT + CERTIFICATION postures into run_info. Called
  // from the mid-run finalize (streaming path, lat_agg complete by then) AND after
  // the batch export loop (batch path generates the lattice later). Idempotent — a
  // no-lattice run (lat_agg.any == false) touches nothing, so run_info.json stays
  // byte-for-byte the pre-lattice record (bar E2).
  // THE EXPORTED GEOMETRY'S FRAME (handoff 2026-08-01-bake-build-orientation).
  // Recorded from the rung the user actually exports — the lightest ACCEPTED
  // one, the same rung the build-orientation receipt describes — so run_info and
  // that receipt can never name different orientations. A run that writes
  // model-space coordinates sets nothing and its run_info stays byte-identical.
  auto finalize_export_frame_run_info = [&]() {
    const MinimizePlasticVariant* v = nullptr;
    for (const MinimizePlasticVariant& c : result.pipeline.evaluated)
      if (c.accepted) v = &c;
    if (v == nullptr || !v->export_baked) return;
    run_info.export_baked = true;
    run_info.export_build_direction_auto_applied = v->build_direction_auto_applied;
    run_info.export_rotation_exact =
        build_frame_rotation(v->applied_build_dir).axis_permutation;
    run_info.applied_build_dir_x = v->applied_build_dir.x;
    run_info.applied_build_dir_y = v->applied_build_dir.y;
    run_info.applied_build_dir_z = v->applied_build_dir.z;
  };

  auto finalize_lattice_run_info = [&]() {
    if (!lat_agg.any) return;
    const double job_wall = std::max(1e-9, wall_seconds() - job_t0);
    // Geometry (handoff 2026-07-28-lattice-generation-production).
    run_info.lattice_export_present = true;
    run_info.lattice_export_topology = job.lattice.topology;
    // Graded runs: the cell is the LAW's (per the last graded variant; each
    // variant's own cell is in its receipt). Uniform runs: the job's.
    run_info.lattice_export_cell_mm =
        lat_agg.graded ? lat_agg.g_cell : job.lattice.cell_mm;
    // A run where EVERY rung was ungradeable emitted no geometry at all, so the
    // "smallest strut" sentinel (1e30) is not an answer — there were no struts.
    // Zeroed explicitly rather than leaked, and `ungradeable_variants` beside it
    // is what says why (bar B3 / L3).
    run_info.lattice_export_strut_radius_min_mm =
        lat_agg.variants > 0 ? lat_agg.r_min : 0.0;
    run_info.lattice_export_strut_radius_max_mm = lat_agg.r_max;
    run_info.lattice_export_latticed_cells = lat_agg.cells;
    run_info.lattice_export_region_voxels = lat_agg.voxels;
    run_info.lattice_export_triangles = lat_agg.tris;
    run_info.lattice_export_variant_count = lat_agg.variants;
    run_info.lattice_export_ungradeable_variants = lat_agg.ungradeable_variants;
    // THE ENCLOSED-VOID RULE (task 2026-08-05-lattice-void-reaches-exterior).
    // Only when the check actually ran; otherwise every field stays at its zero
    // default and the serializer writes no key at all (bar R1).
    if (lat_agg.volume_check_ran) {
      run_info.lattice_volume_check_ran = true;
      run_info.lattice_volume_refused_variants = lat_agg.volume_refused_variants;
      run_info.lattice_volume_worst_gap = lat_agg.volume_worst_gap;
      run_info.lattice_volume_certified_mm3 = lat_agg.volume_certified_mm3;
      run_info.lattice_volume_exported_mm3 = lat_agg.volume_exported_mm3;
    }
    if (lat_agg.void_check_ran) {
      run_info.lattice_void_check_ran = true;
      run_info.lattice_void_sealed_variants = lat_agg.void_sealed_variants;
      run_info.lattice_void_sealed_cells = lat_agg.void_sealed_cells;
      run_info.lattice_void_sealed_voxels = lat_agg.void_sealed_voxels;
      run_info.lattice_void_sealed_volume_mm3 = lat_agg.void_sealed_volume_mm3;
      run_info.lattice_void_latticed_reached = lat_agg.void_latticed_reached;
      run_info.lattice_void_latticed_cells = lat_agg.void_latticed_cells;
      run_info.lattice_void_reachable_volume_mm3 =
          lat_agg.void_reachable_volume_mm3;
      run_info.lattice_void_bfs_visits = lat_agg.void_bfs_visits;
      run_info.lattice_void_escape_depth_max = lat_agg.void_escape_depth_max;
      run_info.lattice_void_sealed_pockets_without_lattice =
          lat_agg.void_sealed_pockets_without_lattice;
      run_info.lattice_void_wall_seconds = lat_agg.void_wall_s;
      std::string faces;
      for (int f = 0; f < 6; ++f)
        if (lat_agg.void_face_escapes[f]) {
          if (!faces.empty()) faces += ",";
          faces += grid_face_name(static_cast<GridFace>(f));
        }
      run_info.lattice_void_escape_faces = faces;
    }
    run_info.lattice_export_emit_stl = job.lattice.emit_stl;
    run_info.lattice_export_emit_3mf = job.lattice.emit_3mf;
    run_info.lattice_export_interpenetrating_soup = true;
    run_info.lattice_export_gen_seconds = lat_agg.wall_s;
    run_info.lattice_export_gen_fraction = lat_agg.wall_s / job_wall;
    // Boundary finish (bar B9): the skin/rim/collar are part of the printed
    // object, so their triangle and volume shares are recorded, not folded in
    // silently. Volumes are the analytic per-primitive sums (soup basis).
    run_info.lattice_export_skin = job.lattice.skin;
    run_info.lattice_export_clipped_struts = lat_agg.clipped;
    run_info.lattice_export_landings = lat_agg.landings;
    run_info.lattice_export_anchor_nodes = lat_agg.anchors;
    run_info.lattice_export_skin_triangles = lat_agg.skin_tris;
    run_info.lattice_export_rim_triangles = lat_agg.rim_tris;
    run_info.lattice_export_interior_volume_mm3 = lat_agg.interior_vol;
    run_info.lattice_export_skin_volume_mm3 = lat_agg.skin_vol;
    run_info.lattice_export_rim_volume_mm3 = lat_agg.rim_vol;
    // Outer finish (task 2026-07-30-lattice-skin-freeform); the serializer
    // writes these keys only for a non-"shell" finish (byte-identity).
    run_info.lattice_export_outer_finish = job.lattice.outer_finish;
    run_info.lattice_export_skin_chords = lat_agg.chords;
    run_info.lattice_export_skin_chords_rejected_band = lat_agg.chords_band;
    run_info.lattice_export_skin_chords_rejected_projection = lat_agg.chords_proj;
    run_info.lattice_export_skin_chords_clipped_away = lat_agg.chords_clipped;
    run_info.lattice_export_finish_certified = job.lattice.outer_finish != "skin";
    // Lattice roles + solid companion (task lattice-page-core-hookup stage 1;
    // keys emitted only when roles/companion were in play — byte-identity).
    run_info.lattice_export_role_regions_present =
        lat_agg.roles_present || lat_agg.solid_voxels > 0 ||
        lat_agg.graded;  // graded runs emit the companion too
    run_info.lattice_export_include_regions = lat_agg.include_regions;
    run_info.lattice_export_exclude_regions = lat_agg.exclude_regions;
    run_info.lattice_export_solid_region_voxels = lat_agg.solid_voxels;
    run_info.lattice_export_solid_region_volume_mm3 = lat_agg.solid_vol;
    run_info.lattice_export_solid_region_triangles = lat_agg.solid_tris;
    run_info.lattice_export_include_void_voxels = lat_agg.include_void;
    run_info.lattice_export_include_void_by_clearance =
        lat_agg.include_void_clearance;
    run_info.lattice_forecast_present = fc_include_regions > 0;
    run_info.lattice_forecast_include_regions = fc_include_regions;
    run_info.lattice_forecast_region_too_thin = fc_region_too_thin;
    run_info.lattice_forecast_required_mm = fc_required_mm;
    run_info.lattice_forecast_thinnest_region_mm = fc_thinnest_mm;
    run_info.lattice_export_frozen_present = lat_agg.frozen_printed > 0;
    run_info.lattice_export_frozen_printed = lat_agg.frozen_printed;
    run_info.lattice_export_frozen_latticed = lat_agg.frozen_latticed;
    run_info.lattice_export_frozen_solid = lat_agg.frozen_solid;
    run_info.lattice_export_frozen_cells_not_emitted = lat_agg.frozen_not_emitted;
    run_info.lattice_export_frozen_voxels_strut_and_solid = lat_agg.frozen_both;
    run_info.lattice_export_frozen_strut_and_solid_unexplained =
        lat_agg.frozen_unexplained;
    run_info.lattice_export_frozen_in_exclude_latticed =
        lat_agg.frozen_excl_latticed;
    // Graded run (stage 4): the "grading" object — the same record the analyze
    // path writes, filled from the LAST graded variant (per-variant records live
    // in the receipts).
    if (lat_agg.graded) {
      run_info.grading_present = true;
      run_info.grading_topology = job.lattice.topology;
      run_info.grading_band_rho_min = lat_agg.g_band_lo;
      run_info.grading_band_rho_max = lat_agg.g_band_hi;
      run_info.grading_cells_per_member_floor = lat_agg.g_cpm_floor;
      run_info.grading_cell_size_mm = lat_agg.g_cell;
      run_info.grading_printability_floor_mm = lat_agg.g_floor;
      run_info.grading_cell_size_floored = lat_agg.g_floored;
      run_info.grading_min_extrudable_width_mm =
          job.grading.min_extrudable_width_mm;
      run_info.grading_rho_min_used = lat_agg.g_rho_lo;
      run_info.grading_rho_max_used = lat_agg.g_rho_hi;
      run_info.grading_region_voxels = lat_agg.g_region;
      run_info.grading_latticed_voxels = lat_agg.g_latticed;
      run_info.grading_solid_fallback_voxels = lat_agg.g_fallback;
      run_info.grading_min_member_width_mm = lat_agg.g_min_width;
      run_info.grading_min_cells_per_member = lat_agg.g_min_cpm;
      run_info.grading_min_strut_diameter_mm = lat_agg.g_min_d;
      run_info.grading_max_strut_diameter_mm = lat_agg.g_max_d;
      run_info.grading_any_strut_below_min = lat_agg.g_below_min;
      run_info.grading_region_ungradeable = lat_agg.g_ungradeable;
      // SUB-FLOOR RETENTION carried through the same aggregate carrier the cell
      // plan uses, so the optimize-path receipt cannot disagree with the
      // lattice-variant one about what was retained (handoff 2026-08-04-subfloor-
      // lattice-unloaded-regions).
      run_info.grading_subfloor_armed = lat_agg.g_cell_ri.grading_subfloor_armed;
      run_info.grading_subfloor_stress_fraction_ceiling =
          lat_agg.g_cell_ri.grading_subfloor_stress_fraction_ceiling;
      run_info.grading_subfloor_region_stress_fraction =
          lat_agg.g_cell_ri.grading_subfloor_region_stress_fraction;
      run_info.grading_subfloor_region_qualified =
          lat_agg.g_cell_ri.grading_subfloor_region_qualified;
      run_info.grading_subfloor_candidate_voxels =
          lat_agg.g_cell_ri.grading_subfloor_candidate_voxels;
      run_info.grading_subfloor_retained_voxels =
          lat_agg.g_cell_ri.grading_subfloor_retained_voxels;
      run_info.grading_subfloor_recovered_voxels =
          lat_agg.g_cell_ri.grading_subfloor_recovered_voxels;
      run_info.grading_subfloor_min_cells_per_member =
          lat_agg.g_cell_ri.grading_subfloor_min_cells_per_member;
      run_info.grading_subfloor_max_cells_per_member =
          lat_agg.g_cell_ri.grading_subfloor_max_cells_per_member;
      run_info.grading_cell_mode = lat_agg.g_cell_ri.grading_cell_mode;
      run_info.grading_cell_base_mm = lat_agg.g_cell_ri.grading_cell_base_mm;
      run_info.grading_cell_max_level = lat_agg.g_cell_ri.grading_cell_max_level;
      run_info.grading_cell_latticed_cells =
          lat_agg.g_cell_ri.grading_cell_latticed_cells;
      run_info.grading_cells_raised_to_floor =
          lat_agg.g_cell_ri.grading_cells_raised_to_floor;
      run_info.grading_cells_dropped_unprintable =
          lat_agg.g_cell_ri.grading_cells_dropped_unprintable;
      run_info.grading_cells_dropped_by_window =
          lat_agg.g_cell_ri.grading_cells_dropped_by_window;
      run_info.grading_cells_split_by_balance =
          lat_agg.g_cell_ri.grading_cells_split_by_balance;
      run_info.grading_cell_any_out_of_regime =
          lat_agg.g_cell_ri.grading_cell_any_out_of_regime;
      run_info.grading_cell_levels = lat_agg.g_cell_ri.grading_cell_levels;
      // FIT, through the same carrier for the same reason.
      run_info.grading_min_printable_cell_mm =
          lat_agg.g_cell_ri.grading_min_printable_cell_mm;
      run_info.grading_density_raised_for_print_voxels =
          lat_agg.g_cell_ri.grading_density_raised_for_print_voxels;
      run_info.grading_fit_out_of_regime_voxels =
          lat_agg.g_cell_ri.grading_fit_out_of_regime_voxels;
      run_info.grading_fit_no_derivation_voxels =
          lat_agg.g_cell_ri.grading_fit_no_derivation_voxels;
      run_info.grading_fit_distinct_cells =
          lat_agg.g_cell_ri.grading_fit_distinct_cells;
      run_info.grading_fit_printed_outside_regions =
          lat_agg.g_cell_ri.grading_fit_printed_outside_regions;
      run_info.grading_fit_regions = lat_agg.g_cell_ri.grading_fit_regions;
      // ★ and the plan's own receipts, carried the same way (see the note above).
      run_info.stepped_anystep_cells = lat_agg.g_cell_ri.stepped_anystep_cells;
      run_info.stepped_anystep_regions = lat_agg.g_cell_ri.stepped_anystep_regions;
      run_info.stepped_anystep_passes = lat_agg.g_cell_ri.stepped_anystep_passes;
      run_info.stepped_anystep_histogram = lat_agg.g_cell_ri.stepped_anystep_histogram;
      run_info.stepped_anystep_rho_by_size =
          lat_agg.g_cell_ri.stepped_anystep_rho_by_size;
      run_info.stepped_plan_solid_remainder_mm3 =
          lat_agg.g_cell_ri.stepped_plan_solid_remainder_mm3;
      run_info.stepped_plan_latticed_mm3 = lat_agg.g_cell_ri.stepped_plan_latticed_mm3;
      run_info.stepped_plan_rho_fallback_by_region =
          lat_agg.g_cell_ri.stepped_plan_rho_fallback_by_region;
      run_info.stepped_clip_outside_region_mm3 =
          lat_agg.g_cell_ri.stepped_clip_outside_region_mm3;
      run_info.stepped_clip_outside_by_cause_mm3 =
          lat_agg.g_cell_ri.stepped_clip_outside_by_cause_mm3;
      run_info.stepped_plan_rho_queries_plan =
          lat_agg.g_cell_ri.stepped_plan_rho_queries_plan;
      run_info.stepped_plan_rho_queries_posture =
          lat_agg.g_cell_ri.stepped_plan_rho_queries_posture;
      run_info.stepped_plan_rho_queries_floor =
          lat_agg.g_cell_ri.stepped_plan_rho_queries_floor;
      run_info.stepped_plan_by_region = lat_agg.g_cell_ri.stepped_plan_by_region;
      run_info.stepped_plan_laid_unattributed =
          lat_agg.g_cell_ri.stepped_plan_laid_unattributed;
      run_info.stepped_plan_laid_measured =
          lat_agg.g_cell_ri.stepped_plan_laid_measured;
      run_info.stepped_law_ungradeable_reported =
          lat_agg.g_cell_ri.stepped_law_ungradeable_reported;
      run_info.stepped_law_ungradeable_note =
          lat_agg.g_cell_ri.stepped_law_ungradeable_note;
      run_info.lattice_outline_beam_mm = lat_agg.g_cell_ri.lattice_outline_beam_mm;
      run_info.lattice_outline_bleed_mm = lat_agg.g_cell_ri.lattice_outline_bleed_mm;
      run_info.lattice_outline_inward_mm = lat_agg.g_cell_ri.lattice_outline_inward_mm;
      run_info.lattice_outline_voxels = lat_agg.g_cell_ri.lattice_outline_voxels;
    }
    // Certification (handoff 2026-07-29-lattice-certification-e2e, bars E1/E3) — WHAT
    // the composite gate certified, so a variant's provenance is recoverable.
    if (lat_agg.cert_ran) {
      run_info.lattice_present = true;
      run_info.lattice_topology = job.lattice.topology;
      run_info.lattice_cell_size_mm =
          lat_agg.graded ? lat_agg.g_cell : job.lattice.cell_mm;
      run_info.lattice_rho_min = lat_agg.rho_lo;
      run_info.lattice_rho_max = lat_agg.rho_hi;
      run_info.lattice_region_voxels = lat_agg.cert_voxels;
      run_info.lattice_margin_worst_case = lat_agg.lat_margin_min;
      run_info.lattice_margin_effective = lat_agg.lat_margin_eff_min;
      run_info.lattice_accepted = lat_agg.lat_accepted_all;
      run_info.lattice_strength_uncertified = lat_agg.strut_uncertified;
      // Strut-strength REPORT (task 2026-07-31-lattice-strut-strength-report):
      // the run-level worst of the report-only de-homogenized margins. Keys are
      // emitted only when a report ran, so older latticed records (and every
      // non-lattice record) stay byte-identical.
      if (lat_agg.strut_report) {
        run_info.lattice_strut_report_present = true;
        run_info.lattice_strut_margin_in_plane = lat_agg.strut_in_plane_min;
        run_info.lattice_strut_margin_interlayer = lat_agg.strut_il_min;
        run_info.lattice_strut_margin_worst_case = lat_agg.strut_worst_min;
        run_info.lattice_strut_z_knockdown = lat_agg.strut_zk;
        run_info.lattice_strut_min_cells_per_member = lat_agg.strut_cpm_min;
        run_info.lattice_strut_out_of_regime = lat_agg.strut_oor;
        run_info.lattice_strut_rho_clamped_voxels = lat_agg.strut_clamped;
      }
    }
  };

  std::vector<std::string> streamed_paths;
  // E1: each streamed version's slim finish (reused by the re-check), and the latticed
  // companions each version wrote (withdrawn with it if finishing refuses it).
  std::map<double, StreamedFinish> streamed_finish;
  // TO rebuild stage 1 (ledger R-07): on the stage 1 path a version's FILE is
  // checked when it is made, before the version is shown; (e) below reuses the
  // verdict instead of checking again after the whole ladder.
  std::map<double, VersionFinish> early_finish;
  const bool strengthen_run = job.loads.present && job.loads.redesign == "strengthen";
  // ── THE DESIGN CONTAINER, PUBLISHED AS THE LADDER GOES (task
  //    2026-08-03-variant-postprocessing-fix, defect 1) ────────────────────────
  // design.bin used to be written ONCE, after the whole ladder (see the write at
  // the end of this function). A streaming client shows each variant the moment
  // its VARIANT line arrives, so for the entire length of a run — and forever
  // after, for a run that ends any way other than "ran to completion" — the
  // variants on screen had no design container and could not be latticed or
  // smoothed. That is exactly what the maintainer hit: his M2_verticalStand run
  // streamed three variants, was killed on rung 4 of 4, and its out/ has the
  // three meshes and NO design.bin, report.json or fields.bin at all.
  //
  // So the container is now flushed after EVERY variant the driver reports. The
  // flush carries the SAME blocks the final write would for those variants (one
  // writer, one rule: every evaluated variant with a density field), and the
  // final write is unchanged — so a run that does complete produces the identical
  // file it produced before. Publication is atomic (design_store.cpp renames),
  // because the worker may serve this file mid-rewrite.
  //
  // Scoped to the STREAMING path deliberately: only a run someone is watching can
  // be observed part-way, and a batch `topopt-cli run` writes exactly what it did.
  //
  // ── …AND THE FIELD CONTAINER WITH IT (task
  //    2026-08-03-variant-postprocessing-concurrency, bar 3) ───────────────────
  // A four-rung ladder takes hours. Rung 1's OWN von Mises field is what the
  // lattice page's AUTO density grades from and what the results overlays draw,
  // and it exists in memory the moment rung 1 finishes — but `fields.bin` was
  // written only at final assembly, so for the whole rest of the run (and forever,
  // if the run died) rung 1 had a design and no field. Both halves of "the
  // artifacts a variant carries" are now published together, per rung.
  //
  // BORROWED, NOT COPIED — AND BORROWED ONLY WITHIN ONE CALL. A per-rung flush
  // must serialise every rung so far, and copying them would cost ~50 MB per rung
  // of duplication at 128³ (PR 291's first cut copied a trimmed variant per rung;
  // adding the fields to that was not affordable). So it borrows.
  //
  // What it does NOT do is ACCUMULATE the borrowed pointers. An earlier cut kept a
  // `std::vector<const MinimizePlasticVariant*>` alive across calls, which is
  // correct exactly as long as `result.evaluated` never reallocates. It does not —
  // minimize_plastic.cpp reserves it to the ladder length, states the invariant out
  // loud and asserts it, and this repo -UNDEBUGs the `topopt` target so that assert
  // survives Release. But the invariant lived in a different file from the code
  // depending on it, and the cost of someone deleting that reserve() is
  // use-after-free, not a wrong number. So `on_variant` now hands over the live
  // container and the pointers are built and consumed INSIDE this lambda. They
  // cannot outlive a reallocation because they do not outlive the call, and the
  // reserve is an optimisation again rather than a correctness requirement.
  const std::string design_stream_path = join_path(out_dir, "design.bin");
  const std::string fields_stream_path = join_path(out_dir, "fields.bin");
  auto publish_artifacts_so_far =
      [&](const std::vector<MinimizePlasticVariant>& evaluated_so_far) {
    // ACCEPTED only, which is exactly what the accumulating version held:
    // `on_variant` fires only for accepted rungs, so every pointer it ever pushed
    // was an accepted one. Filtering here says so directly instead of depending on
    // the ladder stopping at the first rejection, and keeps the streamed
    // containers byte-identical to what they carried before.
    std::vector<const MinimizePlasticVariant*> so_far;
    so_far.reserve(evaluated_so_far.size());
    for (const MinimizePlasticVariant& e : evaluated_so_far)
      if (e.accepted) so_far.push_back(&e);
    // Best-effort BOTH: an artifact that cannot be written must never take a run
    // down. The final writes still throw — those are the contract.
    try {
      write_design_file(design_stream_path, so_far, solved_grid);
    } catch (const std::exception&) {
    }
    try {
      write_fields_file(fields_stream_path, so_far, solved_grid);
    } catch (const std::exception&) {
    }
    try {  // LOAD SCENARIOS: every scenario's own fields (none without 2+)
      write_scenario_fields_file(join_path(out_dir, "scenario_fields.bin"), so_far,
                                 solved_grid);
    } catch (const std::exception&) {
    }
  };
  if (emit_progress) {
    options.progress = [](std::size_t rung, std::size_t rungs, int iter) {
      std::printf("PROGRESS rung=%zu rungs=%zu iter=%d\n", rung, rungs, iter);
      std::fflush(stdout);
    };
    options.on_variant = [&](const MinimizePlasticVariant& v,
                             const std::vector<MinimizePlasticVariant>&
                                 evaluated_so_far) {
      // `on_variant` fires ONLY for ACCEPTED rungs (minimize_plastic.cpp guards
      // the call with `if (result.evaluated.back().accepted)`), so the running
      // containers hold exactly the rungs that have streamed — which is exactly
      // the set a client can see. The FINAL writes add any rejected rungs
      // design.bin also carries, and are unchanged, so a completed run ships the
      // identical files it always did.
      publish_artifacts_so_far(evaluated_so_far);
      if (!v.accepted) return;
      const RunFinish fin = make_run_finish(job, options, &result.model, solved_grid);
      const RunFinish safe = safe_finish(fin);  // a strengthen version that fell back
      std::string p;
      if (strengthen_run) {  // verified (and finished) inside strengthen_versions
        p = export_variant_mesh(v, out_dir, job.output, solved_grid, run_printed_iso(options),
                                &result.model, job.keep_regions,
                                v.report.finish.finish_fallback ? &safe : &fin);
      } else {  // finished slim once, here; (e) re-checks this very shape
        StreamedFinish& sf = streamed_finish[v.requested_volume_fraction];
        sf.mesh = variant_export_model_mesh(v, job.output, solved_grid, run_printed_iso(options),
                                            &result.model, job.keep_regions, &fin, &sf.fb,
                                            &sf.raw);
        const TriangleMesh* shipped = &sf.mesh;
        if (to_stage1_on()) {
          const DesignMask* clearance =
              !options.clearance_void.empty() &&
                      options.clearance_void.size() == solved_grid.voxel_count()
                  ? &options.clearance_void
                  : nullptr;
          VersionFinish& f = early_finish[v.requested_volume_fraction];
          f = finish_and_recheck(
              v, job, job_dir, solved_grid, run_printed_iso(options), &result.model, fin,
              clearance, material.density_g_cm3, materials, rules,
              join_path(out_dir, "finish_check"), v.report.margin_effective,
              v.report.margin_required, &sf);
          if (!f.refusal.empty()) {
            // Never shown: no file, no VARIANT line, no FINISH line. (e) records it.
            std::fprintf(stderr,
                         "[finish] version vf %.2f refused before it was shown: %s\n",
                         v.requested_volume_fraction, f.refusal.c_str());
            streamed_finish.erase(v.requested_volume_fraction);
            return;
          }
          if (f.fb.finish_fallback) shipped = &f.mesh;  // the safe finish is what ships
        }
        p = export_variant_mesh(v, out_dir, job.output, solved_grid, run_printed_iso(options),
                                &result.model, job.keep_regions, &fin, shipped);
      }
      streamed_paths.push_back(p);
      // The analytic design, written BESIDE the mesh into out_dir (S1(d)).
      // ★ AND DELIBERATELY NOT PUSHED INTO THE PATH LIST. `mesh_paths` means
      // "one exported MESH per accepted variant" — test_cli asserts exactly
      // that, by count and by filename pattern, and then re-imports each entry
      // as a mesh. An `alpha.f64` in that list breaks all three, which is what
      // it did until this line changed. The file still lands in out_dir and the
      // worker still serves out_dir; it simply is not a mesh and does not claim
      // to be one.
      (void)export_variant_alpha(v, out_dir, job.output, solved_grid);
      // `achieved` is the optimizer-achieved (continuous) fraction — the stream's
      // join key against the report's volume_fraction; `printed` is the printed/count
      // basis the app's savings uses (handoff 104, additive — a new field; older
      // readers ignore it). Both come from the same variant.
      std::printf(
          "VARIANT vf=%.6f achieved=%.6f printed=%.6f margin=%.6g accepted=1 mesh=%s\n",
          v.requested_volume_fraction, v.optimization.volume_fraction,
          v.report.printed_fraction, v.report.margin.worst_case, p.c_str());
      std::fflush(stdout);
      // Latticed companion (streaming path): generated + checkpointed as the
      // variant completes, alongside the solid mesh.
      emit_lattice(v, /*stream_lines=*/true);
    };
  }

  // ★ THE THREAD OVERRIDE, APPLIED HERE AND NOWHERE EARLIER (task
  // 2026-08-10-plsm-production). `configure_production_options` sets the
  // matrix-free apply's thread count to the performance-core pin, so a caller
  // that set it before run_job would have been silently overwritten. 0 (the
  // default) leaves the production rule alone and this line does nothing. It is
  // a pure performance control — fea.hpp guarantees the apply is BIT-IDENTICAL
  // for any thread count, because it colours the grid deterministically — so it
  // cannot move a number, only how much of the machine the run takes.
  if (obs.matfree_threads > 0) {
    fea_set_matfree_threads(obs.matfree_threads);
    if (options.plsm.mode == PlsmMode::Parametric)
      options.plsm.threads = obs.matfree_threads;
  }
  // ★ AND THE SOLVER POSTURE OVERRIDES, HERE FOR THE SAME REASON AND NOT ONE
  // LINE EARLIER (task solver-speed-arm-and-diagnose). See RunObservability in
  // job.hpp: `configure_production_options` re-asserts both of these globals at
  // the start of the run — deliberately, so a thread that ran a harness earlier
  // cannot carry an armed solver into a production run — which means the ONLY
  // correct place to override them is after it and before the first solve.
  // -1 is the default on both and applies nothing, so the CLI's runs and every
  // existing caller are byte-identical.
  if (obs.mg_algebraic_level1 >= 0)
    fea_set_mg_algebraic_level1(obs.mg_algebraic_level1 != 0);
  if (obs.matfree_mixed_precision >= 0)
    fea_set_matfree_mixed_precision(obs.matfree_mixed_precision != 0);
  // The latch re-arm is NOT re-asserted by configure_production_options (it has
  // no production writer at all), but it IS zeroed by the run-start latch reset
  // in minimize_plastic, so it is applied here alongside the other two rather
  // than relying on a caller having set it at the right moment.
  if (obs.mg_rearm_period > 0)
    fea_matfree_set_mg_rearm_period(obs.mg_rearm_period);
  // The run_info written up front recorded the PRE-override posture; re-read it
  // now so the artifact says what the run actually did. Without this an armed
  // arm reports `mg_algebraic_level1: false` and reads as a null result.
  run_info.mg_algebraic_level1 = fea_mg_algebraic_level1_enabled();
  run_info.mixed_precision = fea_matfree_mixed_precision_enabled();
  if (job.loads.present && job.loads.redesign == "strengthen") {
    // CORE LIST item 50 — the versions are searched and verified inside; only the
    // final ones are streamed, through the same callback a ladder rung uses.
    result.pipeline =
        strengthen_versions(job, job_dir, out_dir, materials, rules, result.model,
                            model_is_mesh, material, grid, bcs, options, domain,
                            emit_progress);
    if (options.on_variant)
      for (const MinimizePlasticVariant& v : result.pipeline.evaluated)
        options.on_variant(v, result.pipeline.evaluated);
  } else {
    result.pipeline =
        minimize_plastic(grid, material, job.material, bcs, rules, options);
  }

  // LOUD FALLBACK (handoff: multigrid-coarsenability-padding). Record the OBSERVED
  // multigrid outcome now the run is done (the up-front write left it null), and —
  // if a multigrid solver was requested but silently fell back to Jacobi-CG — print
  // a WARNING. A silent slowdown violates the honesty principle exactly like a
  // wrong number does, so it must be reported, not swallowed.
  const bool solver_is_multigrid =
      options.simp.solver == SolverKind::MultigridCG ||
      options.simp.solver == SolverKind::MultigridCG_Matfree;
  if (wrote_run_info) {
    run_info.cg_multigrid = result.pipeline.used_multigrid;
    run_info.mg_levels = result.pipeline.mg_levels;
    run_info.cg_multigrid_observed = true;  // outcome now known -> emit real values
    // ★ ACHIEVED MASS AS A FRACTION OF THE SOLID PART (task 2026-08-13 §0.5).
    // The rung is a fraction of the ACTIVE envelope, so a frozen region that
    // stopped costing its envelope moves what the rung MEANS — and a latticed
    // ladder then cannot be compared with an unlatticed one at all. This is the
    // one number that survives that: the same denominator either way.
    //
    // The denominator is the PART grid, not the design box. The numerator is the
    // RECOMMENDED variant, i.e.
    // the last accepted rung, which is the recommendation under BOTH ladders.
    // Mass here is analyze.cpp's own formula, not a re-derivation: density_g_cm3
    // x voxel-equivalents x voxel_volume / 1000.
    {
      // `grid` here is `setup.grid` — the PART grid, BEFORE design-box
      // expansion (`resolve_design_domain` derives the solved grid from it), so
      // the box's empty space is correctly not part of "the solid part".
      const double solid_voxels = static_cast<double>(grid.solid_count());
      const double solid_mass_g = material.density_g_cm3 * solid_voxels *
                                  grid.voxel_volume() / 1000.0;
      const MinimizePlasticVariant* rec = nullptr;
      for (const MinimizePlasticVariant& v : result.pipeline.evaluated)
        if (v.accepted) rec = &v;
      // Left unobserved (JSON null) when nothing was accepted or the part has no
      // solid voxels — a 0.0 would read like a measured weightless part.
      if (rec != nullptr && solid_mass_g > 0.0) {
        run_info.achieved_solid_fraction = rec->mass_grams / solid_mass_g;
        run_info.achieved_solid_fraction_observed = true;
      }
    }
    // Lattice CERTIFICATION posture (handoff 2026-07-29-lattice-certification-e2e,
    // bars E1/E3). When the job declared a lattice block, each accepted variant was
    // re-certified against the octet tensor (emit_lattice → certify_latticed_variant),
    // and the run-level posture is summed here — like lattice_export. The serializer
    // emits the "lattice" key ONLY when lattice_present, so a NON-lattice run writes no
    // key and run_info.json stays byte-for-byte the pre-lattice record (bar E2). This
    // records WHAT was certified: the composite object's worst strength margin, the
    // density and the certifiable band the gate enforced (E5), and the honest
    // strut-strength-uncertified flag — so a variant's provenance is recoverable. It is
    // populated by finalize_lattice_run_info (called just before write_run_info below),
    // which covers BOTH the streaming and batch generation paths.
    // Handoff 128 — the run-level fallback mode. Only meaningful for a multigrid
    // solver; for JacobiCG leave mg_mode empty (serialized null). "carried" when
    // MG carried the run; otherwise "stagnated-latched" if a hierarchy ever built
    // (built-but-never-carried == stagnation, the 127 latch may have engaged) or
    // "build-rejected" if none ever did (never coarsenable).
    if (solver_is_multigrid) {
      run_info.mg_mode =
          result.pipeline.used_multigrid
              ? "carried"
              : (result.pipeline.mg_hierarchy_ever_built ? "stagnated-latched"
                                                         : "build-rejected");
      run_info.mg_mode_observed = true;
    }
    // Handoff 2026-08-02-warm-start-coarse-experiment — finalize the coarse
    // pre-solve's own cost (0/0 when it was never armed), so the run record
    // carries the price beside the posture and no speedup read off this run can
    // omit it.
    run_info.warm_start_coarse_iterations =
        result.pipeline.warm_start_coarse_iterations;
    run_info.warm_start_coarse_ms = result.pipeline.warm_start_coarse_ms;
    run_info.warm_start_coarse_matvecs =
        result.pipeline.warm_start_coarse_matvecs;
    // The DOF-weighted cost and BOTH its denominators. solved_grid_dofs is
    // filled even when the cascade was never armed: it is the denominator any
    // DOF-weighted reading of this run needs, and a record that only carries it
    // when a feature fired cannot be used to compare against a run where it
    // didn't.
    run_info.warm_start_coarse_dof_touches =
        result.pipeline.warm_start_coarse_dof_touches;
    run_info.warm_start_coarse_grid_dofs =
        result.pipeline.warm_start_coarse_grid_dofs;
    run_info.solved_grid_dofs = result.pipeline.solved_grid_dofs;
    // Handoff 123 — finalize the conditional-projection outcome: which rungs fired
    // and the grayscale Mnd measured on each (empty when the gate was disarmed).
    run_info.conditional_projection_fired.assign(
        result.pipeline.conditional_projection_fired.begin(),
        result.pipeline.conditional_projection_fired.end());
    run_info.conditional_projection_rung_mnd =
        result.pipeline.rung_grayscale_mnd;
    // Task 2026-08-08-semdot-does-it-come-out-smoother — finalize the per-rung
    // SEMDOT outcome from each rung's own SimpOptimizeResult. Empty when the mode
    // was off, so an unarmed run claims nothing about it.
    if (options.simp.semdot) {
      run_info.semdot_rung_level_set.clear();
      run_info.semdot_rung_fractional_voxels.clear();
      run_info.semdot_rung_design_voxels.clear();
      for (const MinimizePlasticVariant& v : result.pipeline.evaluated) {
        run_info.semdot_rung_level_set.push_back(v.optimization.semdot_level_set);
        run_info.semdot_rung_fractional_voxels.push_back(
            static_cast<long long>(v.optimization.semdot_fractional_voxels));
        run_info.semdot_rung_design_voxels.push_back(
            static_cast<long long>(v.optimization.semdot_design_voxels));
      }
    }
    // Task 2026-08-10-plsm-production — finalize the PARAMETRIC posture from the
    // run's own first evaluated rung: the RESOLVED knot spacing (three numbers,
    // per axis), the coefficient count, and the measured load-path floor. The
    // resolved spacing overwrites the requested one, because a receipt has to
    // state what ran; a job that left the knots at zero asked for the derived
    // rule, and this is what the rule gave. Untouched (and zero) when the mode
    // was off, so an unarmed run claims nothing about it.
    if (options.plsm.mode == PlsmMode::Parametric &&
        !result.pipeline.evaluated.empty()) {
      const MinimizePlasticVariant& v0 = result.pipeline.evaluated.front();
      run_info.plsm_knots_vox[0] = v0.plsm_lattice.dx;
      run_info.plsm_knots_vox[1] = v0.plsm_lattice.dy;
      run_info.plsm_knots_vox[2] = v0.plsm_lattice.dz;
      run_info.plsm_coefficients =
          static_cast<long long>(v0.plsm_lattice.count());
      run_info.plsm_frozen_floor_occupancy = v0.plsm_frozen_floor_occupancy;
      // Task 2026-08-13 — WHAT ACTUALLY HAPPENED, from the first evaluated
      // rung. `plsm_stop_reason` is the one that cannot be omitted: a run that
      // hit the iteration ceiling and a run whose certified margin plateaued
      // are different objects, and reading the second as the first is what made
      // a 60-iteration cap look like a converged setting for three tasks.
      run_info.plsm_stop_reason = v0.plsm_stop_reason;
      run_info.plsm_margin_peak_iteration = v0.plsm_margin_peak_iteration;
      run_info.plsm_margin_peak = v0.plsm_margin_peak;
      run_info.plsm_margin_probe_wall_s = v0.plsm_margin_probe_wall_s;
      run_info.plsm_frac_cut_cells =
          static_cast<long long>(v0.plsm_frac_cut_cells);
      run_info.plsm_frac_sample_wall_s = v0.plsm_frac_sample_wall_s;
      run_info.plsm_frac_sens_wall_s = v0.plsm_frac_sens_wall_s;
      run_info.plsm_void_components = v0.plsm_topology.components;
      run_info.plsm_void_chi = v0.plsm_topology.chi;
      run_info.plsm_void_enclosed_solid = v0.plsm_topology.enclosed_solid;
      run_info.plsm_void_sealed_pockets = v0.plsm_topology.sealed_pockets;
      run_info.plsm_void_tunnels = v0.plsm_topology.tunnels;
      run_info.plsm_void_sealed_voxels = v0.plsm_topology.sealed_voxels;
      run_info.plsm_void_sealed_volume_mm3 = v0.plsm_topology.sealed_volume_mm3;
    }
    // Handoff 131 — finalize the per-rung infeasibility outcome (one entry per
    // evaluated rung; all-false is the positive statement "no rung lost its load
    // path"). Written only now, like cg_multigrid, so an unfinished run claims
    // nothing either way.
    run_info.rung_infeasible.assign(result.pipeline.rung_infeasible.begin(),
                                    result.pipeline.rung_infeasible.end());
    // Handoff 2026-07-27-nonconvergence-rejection — finalize the per-rung
    // non-convergence outcome (which rungs a linear solve failed to converge on,
    // with the iteration and residual each reached), same finalize-only discipline.
    run_info.rung_non_convergent.assign(
        result.pipeline.rung_non_convergent.begin(),
        result.pipeline.rung_non_convergent.end());
    run_info.rung_non_convergent_iteration.assign(
        result.pipeline.rung_non_convergent_iteration.begin(),
        result.pipeline.rung_non_convergent_iteration.end());
    run_info.rung_non_convergent_residual.assign(
        result.pipeline.rung_non_convergent_residual.begin(),
        result.pipeline.rung_non_convergent_residual.end());
    // Task 2026-08-03-preflight-feasibility-and-divergence — finalize the two
    // DIVERGENCE guards' per-rung outcomes, each with the numbers it fired on
    // (bar P6). All-false is the positive statement "no guard fired".
    run_info.rung_diverged.assign(result.pipeline.rung_diverged.begin(),
                                  result.pipeline.rung_diverged.end());
    run_info.rung_diverged_iteration =
        result.pipeline.rung_diverged_iteration;
    run_info.rung_diverged_c_ratio = result.pipeline.rung_diverged_c_ratio;
    run_info.rung_diverged_cg_ratio = result.pipeline.rung_diverged_cg_ratio;
    run_info.rung_diverged_wall_ratio =
        result.pipeline.rung_diverged_wall_ratio;
    run_info.rung_time_budget.assign(result.pipeline.rung_time_budget.begin(),
                                     result.pipeline.rung_time_budget.end());
    run_info.rung_time_budget_iteration =
        result.pipeline.rung_time_budget_iteration;
    run_info.rung_time_budget_ms = result.pipeline.rung_time_budget_ms;
    run_info.rung_time_budget_elapsed_ms =
        result.pipeline.rung_time_budget_elapsed_ms;
    run_info.rung_time_budget_baseline_ms =
        result.pipeline.rung_time_budget_baseline_ms;
    run_info.rung_time_budget_phase = result.pipeline.rung_time_budget_phase;
    run_info.rung_time_budget_phase_ms =
        result.pipeline.rung_time_budget_phase_ms;
    // active-domain phase 1 — finalize the per-rung latch outcome. All-false
    // (with a band > 0) is the positive statement "the band held for every
    // rung"; a true entry names the rung that fell back to the full domain and
    // why, so a run that bought nothing SAYS so instead of silently costing.
    for (const MinimizePlasticVariant& v : result.pipeline.evaluated) {
      // The DERIVED k this rung ran with (what the AUTO sentinel resolved to), so
      // a run armed with active_domain_band = -1 records the concrete width beside
      // the request.
      run_info.active_domain_band_resolved.push_back(
          v.optimization.active_domain_band);
      run_info.active_domain_latched.push_back(
          v.optimization.active_domain_latched ? 1 : 0);
      run_info.active_domain_latch_iteration.push_back(
          v.optimization.active_domain_latch_iteration);
      run_info.active_domain_escape_count.push_back(
          v.optimization.active_domain_escape_count);
      run_info.active_domain_latch_reason.push_back(
          v.optimization.active_domain_latch_reason);
      run_info.active_domain_fraction_mean.push_back(
          v.optimization.active_fraction_mean);
    }
    // Handoff 2026-07-25-draft-quality — finalize the per-rung draft outcome (empty
    // when draft was off): the measured tightening tail k, the certified-vs-
    // trajectory compliance gap, and which rungs escalated. Same finalize-only
    // discipline as cg_multigrid, so an unfinished run asserts nothing about draft.
    run_info.draft_rung_tail_k.assign(result.pipeline.draft_rung_tail_k.begin(),
                                      result.pipeline.draft_rung_tail_k.end());
    run_info.draft_rung_c_gap = result.pipeline.draft_rung_c_gap;
    run_info.draft_rung_escalated.assign(
        result.pipeline.draft_rung_escalated.begin(),
        result.pipeline.draft_rung_escalated.end());
    // Handoff 2026-07-26-draft-quality-phase2 — the design-space probe outcome.
    run_info.draft_rung_probe_flip = result.pipeline.draft_rung_probe_flip;
    run_info.draft_rung_probe_cg = result.pipeline.draft_rung_probe_cg;
    // Handoff 2026-07-29-geneo-arming — finalize the GenEO deflation lifecycle:
    // basis builds / coarse refreshes / preconditioned fallback solves this run,
    // and the coarse dimension + stored MB held at run end. All 0 when the
    // feature is off or no solve ever reached the stagnation trigger.
    // Task algebraic-level1-coarsening — finalize what the LAST algebraic
    // hierarchy build produced (aggregates, level-1 dimension, depth, added
    // bytes) and whether it REFUSED and fell back to the geometric builder.
    // All 0 / false when the path is off, which is every reference run.
    {
      const MgAlgebraicLevel1Info a = fea_mg_algebraic_level1_info();
      run_info.mg_algebraic_aggregates = a.aggregates;
      run_info.mg_algebraic_coarse_dim = a.coarse_dim;
      run_info.mg_algebraic_levels = a.levels;
      run_info.mg_algebraic_added_mb =
          static_cast<double>(a.bytes) / (1024.0 * 1024.0);
      run_info.mg_algebraic_level1_refused = a.refused;
      run_info.mg_algebraic_refuse_reason = a.refuse_reason;
    }
    // MULTISCALE LATTICE TO (task multiscale-lattice-to) — the receipt for "the
    // optimizer placed the lattice". Filled from the per-variant reports the
    // driver produced, in ladder order, so every EVALUATED rung is described,
    // not only the shipped one. Absent entirely on a non-multiscale run.
    if (options.multiscale_lattice) {
      run_info.multiscale_armed = true;
      run_info.multiscale_topology =
          lattice_topology_name(options.multiscale_topology);
      run_info.multiscale_floor_cell_mm = options.multiscale_floor_cell_mm;
      run_info.multiscale_floor_stride = options.multiscale_floor_stride;
      run_info.multiscale_floor_cells =
          lattice_cells_per_member_min(options.multiscale_topology);
      for (const MinimizePlasticVariant& v : result.pipeline.evaluated) {
        const MinimizePlasticVariant::MultiscaleReport& m = v.multiscale;
        if (!m.multiscale) continue;
        run_info.multiscale_region_voxels =
            static_cast<long long>(m.region_voxels);
        run_info.multiscale_fit_rows = static_cast<long long>(m.fit_rows);
        run_info.multiscale_rho_lo = m.rho_lo;
        run_info.multiscale_rho_hi = m.rho_hi;
        run_info.multiscale_floor_ceiling_measured =
            static_cast<long long>(m.floor_ceiling_measured);
        run_info.multiscale_floor_ceiling_eligible =
            static_cast<long long>(m.floor_ceiling_eligible);
        run_info.multiscale_floor_ceiling_min_cells = m.floor_ceiling_min_cells;
        RunInfo::MultiscaleRung R;
        R.volume_fraction = v.requested_volume_fraction;
        R.voxels_void = static_cast<long long>(m.voxels_void);
        R.voxels_band = static_cast<long long>(m.voxels_band);
        R.voxels_solid = static_cast<long long>(m.voxels_solid);
        R.voxels_lower_gap = static_cast<long long>(m.voxels_lower_gap);
        R.voxels_upper_gap = static_cast<long long>(m.voxels_upper_gap);
        R.band_rho_min = m.band_rho_min;
        R.band_rho_max = m.band_rho_max;
        R.projected_lower = static_cast<long long>(m.projected_lower);
        R.projected_upper = static_cast<long long>(m.projected_upper);
        R.projection_volume_delta = m.projection_volume_delta;
        R.projection_max_density_move = m.projection_max_density_move;
        R.volume_fraction_before_projection = m.volume_fraction_before_projection;
        R.volume_fraction_after_projection = m.volume_fraction_after_projection;
        R.volume_fraction_target = m.volume_fraction_target;
        R.volume_constraint_violation = m.volume_constraint_violation;
        R.floor_measured_voxels = static_cast<long long>(m.floor_measured_voxels);
        R.floor_below_voxels = static_cast<long long>(m.floor_below_voxels);
        R.floor_min_cells_per_member = m.floor_min_cells_per_member;
        for (std::size_t b : m.floor_histogram)
          R.floor_histogram.push_back(static_cast<long long>(b));
        for (const auto& fs : m.floor_history) {
          RunInfo::MultiscaleRung::FloorSample S;
          S.iteration = fs.iteration;
          S.measured = static_cast<long long>(fs.measured);
          S.below = static_cast<long long>(fs.below);
          S.min_cells_per_member = fs.min_cells_per_member;
          R.floor_history.push_back(S);
        }
        run_info.multiscale_rungs.push_back(std::move(R));
      }
    }
    run_info.geneo_basis_builds = fea_geneo_basis_builds();
    run_info.geneo_coarse_refreshes = fea_geneo_coarse_refreshes();
    run_info.geneo_armed_solves = fea_geneo_armed_solves();
    run_info.geneo_basis_dim = fea_geneo_basis_dim();
    run_info.geneo_basis_mb =
        static_cast<double>(fea_geneo_basis_bytes()) / (1024.0 * 1024.0);
    // Handoff 2026-08-02-geneo-disarm — the engagement gate's decisions: how many
    // fallback solves a held basis was offered to and declined, and the event log
    // of every arm/disarm transition with the numbers it fired on (bar AA5).
    run_info.geneo_declined_solves = fea_geneo_declined_solves();
    run_info.geneo_decisions_dropped = fea_geneo_decisions_dropped();
    run_info.geneo_decisions.clear();
    for (int gi = 0; gi < fea_geneo_decision_count(); ++gi)
      run_info.geneo_decisions.push_back(fea_geneo_decision_at(gi));
    // Lattice EXPORT + CERTIFICATION posture — finalized via the shared lambda so the
    // streaming and batch paths agree; a no-lattice run writes NO key (P1 / bar E2).
    // On the batch path lat_agg is still empty here (emit_lattice runs after the mesh
    // loop below); the post-export re-write catches it.
    finalize_lattice_run_info();
    finalize_export_frame_run_info();
    write_run_info(result.run_info_path, run_info);
  }
  // A recovery solve (which sets used_multigrid) runs only for a non-cancelled
  // rung; without one, used_multigrid is its unobserved default and must not warn.
  bool any_solve = false;
  for (const MinimizePlasticVariant& v : result.pipeline.evaluated)
    if (!v.optimization.cancelled) { any_solve = true; break; }
  if (solver_is_multigrid && any_solve && !result.pipeline.used_multigrid) {
    const VoxelGrid& sg = result.pipeline.solved_grid;
    std::fprintf(stderr,
                 "WARNING: multigrid solver \"%s\" fell back to Jacobi-CG on the "
                 "%dx%dx%d solved grid (the hierarchy could not be built, OR the "
                 "V-cycle stagnated on a high-contrast field) — expect a large "
                 "slowdown. Linear solves ran Jacobi-CG; run_info.json records "
                 "cg_multigrid=false. See iterations.csv for the per-solve record.\n",
                 solver_name(options.simp.solver), sg.nx, sg.ny, sg.nz);
    std::fflush(stderr);
  }

  // Handoff 131 — LOUD INFEASIBILITY. A rung whose load path was severed is a
  // failed rung, not a quiet one: say so on stderr, once per rung, in the same
  // spirit as the multigrid loud fallback above. Silence here is what let the
  // motivating run ship a corpse as an accepted variant.
  for (std::size_t i = 0; i < result.pipeline.evaluated.size(); ++i) {
    const MinimizePlasticVariant& v = result.pipeline.evaluated[i];
    if (!v.infeasible) continue;
    std::fprintf(stderr,
                 "WARNING: rung %zu (vf %.2f) is INFEASIBLE — %s. The optimizer "
                 "severed the load path: compliance stayed >= %.4gx this rung's "
                 "starting value, flat to within %.4g, with a >= %.4gx CG blow-up, "
                 "for %d consecutive iterations, and the rung was ended at "
                 "iteration %d. No mesh, no "
                 "stress analysis and no margin are reported for it, and no later "
                 "rung inherits its design. See report.json rejected_variants and "
                 "run_info.json rung_infeasible.\n",
                 i, v.requested_volume_fraction, kRungInfeasibleReason,
                 options.simp.infeasible_compliance_ratio,
                 options.simp.infeasible_flat_tol,
                 options.simp.infeasible_cg_blowup,
                 options.simp.infeasible_window,
                 v.optimization.infeasible_iteration);
    std::fflush(stderr);
  }

  // Handoff 2026-07-27-nonconvergence-rejection — LOUD NON-CONVERGENCE. A rung whose
  // linear solve did not converge is a rejected rung, not a quiet one, and — unlike
  // before this change — it no longer takes the whole run down with it. Say so on
  // stderr, once per rung, with the iteration and residual the solve reached, in the
  // same spirit as the loud infeasibility warning above.
  for (std::size_t i = 0; i < result.pipeline.evaluated.size(); ++i) {
    const MinimizePlasticVariant& v = result.pipeline.evaluated[i];
    if (!v.non_convergent) continue;
    const int nc_iter = i < result.pipeline.rung_non_convergent_iteration.size()
                            ? result.pipeline.rung_non_convergent_iteration[i]
                            : 0;
    const double nc_resid =
        i < result.pipeline.rung_non_convergent_residual.size()
            ? result.pipeline.rung_non_convergent_residual[i]
            : 0.0;
    // The tolerance the failed solve really ran at (the optimiser's loose or tight
    // one), not the configured default, which is what this line used to print.
    const double nc_tol =
        i < result.pipeline.rung_non_convergent_tolerance.size() &&
                result.pipeline.rung_non_convergent_tolerance[i] > 0.0
            ? result.pipeline.rung_non_convergent_tolerance[i]
            : options.simp.cg_tolerance;
    std::fprintf(stderr,
                 "WARNING: rung %zu (vf %.2f) was REJECTED — %s. A linear solve did "
                 "not reach the CG tolerance %.3g: it stalled at residual %.3g after "
                 "%d iterations. This rung was NOT certified and no mesh, stress "
                 "analysis or margin is reported for it; the run completed and every "
                 "already-accepted variant is unaffected. See report.json "
                 "rejected_variants and run_info.json rung_non_convergent.\n",
                 i, v.requested_volume_fraction, kRungNonConvergentReason,
                 nc_tol, nc_resid, nc_iter);
    std::fflush(stderr);
  }

  // active-domain phase 1 — LOUD LATCH. A band that switched itself off cost the
  // derivation and bought nothing; say so, in the same spirit as the multigrid
  // loud fallback above. Unreachable from a plain `topopt-cli run` today (the
  // band is deliberately NOT a job.json key — it is a solver-internal
  // accelerator, not a user knob), and deliberately written anyway so it is live
  // the moment any front-end arms it.
  if (options.simp.active_domain_band != 0) {
    for (std::size_t i = 0; i < result.pipeline.evaluated.size(); ++i) {
      const MinimizePlasticVariant& v = result.pipeline.evaluated[i];
      if (!v.optimization.active_domain_latched) continue;
      std::fprintf(stderr,
                   "WARNING: rung %zu (vf %.2f) LATCHED the active domain off at "
                   "iteration %d — %s. Every solve from there ran the FULL "
                   "domain: the design is unaffected, the run is simply not "
                   "accelerated. run_info.json records active_domain_latched.\n",
                   i, v.requested_volume_fraction,
                   v.optimization.active_domain_latch_iteration,
                   v.optimization.active_domain_latch_reason.c_str());
      std::fflush(stderr);
    }
  }

  // Handoff 2026-07-23-gate-honesty-connectivity-rejection — LOUD DISCONNECTION,
  // the same discipline for the connectivity belt's verdict, once per rung. A rung
  // the belt rejected has, almost always, an EXCELLENT-looking margin (no load path
  // => no stress), so the one thing that must not happen is for it to be dropped
  // quietly and leave those numbers to speak for themselves.
  for (std::size_t i = 0; i < result.pipeline.evaluated.size(); ++i) {
    const MinimizePlasticVariant& v = result.pipeline.evaluated[i];
    if (v.report.rejection_reason != kLoadPathNotConnectedReason) continue;
    std::fprintf(stderr,
                 "WARNING: rung %zu (vf %.2f) was REJECTED — %s. No printed "
                 "material connects the anchor (Fixture) voxels to the load "
                 "(Load) voxels, so this design carries nothing: its measured "
                 "margin %.4g describes a SEVERED structure and is not a strength "
                 "result. No mesh is exported for it and no later rung inherits "
                 "its design; the ladder continues. See report.json "
                 "rejected_variants.\n",
                 i, v.requested_volume_fraction, kLoadPathNotConnectedReason,
                 v.report.margin_effective);
    std::fflush(stderr);
  }

  // CORE LIST item 47 — LOUD DETACHMENT: a rung whose design let go of an
  // anchored piece is rejected; say which anchors, once per rung.
  for (std::size_t i = 0; i < result.pipeline.evaluated.size(); ++i) {
    const MinimizePlasticVariant& v = result.pipeline.evaluated[i];
    if (v.report.rejection_reason != kAnchorDetachedReason) continue;
    std::string faces;
    for (const int f : v.report.lost_anchor_face_ids)
      faces += (faces.empty() ? "" : ", ") + std::to_string(f);
    for (const int r : v.report.lost_anchor_region_ids)
      faces += (faces.empty() ? "region " : ", region ") + std::to_string(r);
    std::fprintf(stderr,
                 "WARNING: rung %zu (vf %.2f) was REJECTED — %s. %d anchored "
                 "piece(s) (%lld voxels; anchor face(s): %s) hold no load in this "
                 "design: the material joining them to the part was removed, so "
                 "the bolt there would hold nothing. No mesh is exported for it "
                 "and no later rung inherits its design. See report.json "
                 "rejected_variants.\n",
                 i, v.requested_volume_fraction, kAnchorDetachedReason,
                 v.report.anchored_pieces_lost, v.report.lost_anchor_voxels,
                 faces.empty() ? "not named" : faces.c_str());
    std::fflush(stderr);
  }

  // CORE LIST item 40 — LOUD STARVATION. A rung that asked for less than the frozen
  // material alone prints got the density floor as its target and printed the
  // frozen share instead; the worker log says so once, with the numbers.
  if (result.pipeline.report.frozen_share.evaluated) {
    const FrozenShareReport& fs = result.pipeline.report.frozen_share;
    std::size_t protections = 0;
    for (const FrozenSourceCount& s : fs.sources)
      if (s.source == "face_protection") ++protections;
    std::fprintf(stderr,
                 "WARNING: %.3g of the part (%lld of %lld voxels) is FROZEN — the "
                 "anchor and load faces, the anchor pad and %zu face "
                 "protection(s) — so every rung that asked for less clamped to the "
                 "density floor: it removed every free voxel and printed the frozen "
                 "material alone. %zu later rung(s) would only repeat that design "
                 "and were skipped. To reduce further, release protections. See "
                 "report.json frozen_share.\n",
                 fs.share, fs.frozen_voxels, fs.part_solid_voxels, protections,
                 fs.skipped_rungs.size());
    std::fflush(stderr);
  }

  // Handoff 114 — record how many density snapshots were written (0 unless
  // opt-in snapshots ran). The CSV/run_info paths are already set above.
  if (snaps) result.snapshot_count = snaps->written();

  // ──▶ E1 (e): EVERY CHECK ON THE FINISHED SHAPE. Each accepted version's exported
  // shape (CAD projection, exact Protect, thin-spot cleanup, surface finish) is
  // re-certified as a file, exactly as strengthen verifies its versions: margin, Keep
  // clear, pieces, thin joints, thin spots left, mass. A version whose finished shape
  // fails is refused with the plain reason — never accepted silently. Strengthen runs
  // did all of this per version already.
  std::map<double, TriangleMesh> finished_meshes;  // by requested_volume_fraction
  if (!(job.loads.present && job.loads.redesign == "strengthen")) {
    const VoxelGrid& sg = result.pipeline.solved_grid;
    const RunFinish fin = make_run_finish(job, options, &result.model, sg);
    const std::string check_dir = join_path(out_dir, "finish_check");
    const DesignMask* clearance =
        !options.clearance_void.empty() && options.clearance_void.size() == sg.voxel_count()
            ? &options.clearance_void
            : nullptr;
    for (MinimizePlasticVariant& v : result.pipeline.evaluated) {
      if (!v.accepted) continue;
      const auto streamed = streamed_finish.find(v.requested_volume_fraction);
      const auto early = early_finish.find(v.requested_volume_fraction);
      VersionFinish f =
          early != early_finish.end()
              ? std::move(early->second)  // stage 1: checked when the file was made
              : finish_and_recheck(
                    v, job, job_dir, sg, run_printed_iso(options), &result.model, fin,
                    clearance, material.density_g_cm3, materials, rules, check_dir,
                    v.report.margin_effective, v.report.margin_required,
                    streamed != streamed_finish.end() ? &streamed->second : nullptr);
      FinishBlock& fb = f.fb;
      if (!f.refusal.empty()) {
        fb.verdict_changed = true;
        fb.verdict_reason = f.refusal;
        v.accepted = false;
        v.report.accepted = false;
        v.report.rejection_reason = f.refusal;
        std::fprintf(stderr, "[finish] version vf %.2f refused after finishing: %s\n",
                     v.requested_volume_fraction, f.refusal.c_str());
      } else {
        if (fb.finish_fallback)
          std::fprintf(stderr, "[finish] version vf %.2f uses the safe finish: %s\n",
                       v.requested_volume_fraction, fb.finish_fallback_reason.c_str());
        finished_meshes[v.requested_volume_fraction] = std::move(f.mesh);
      }
      v.report.finish = fb;
      // The report's own lists carry copies of the line: update them, and move a
      // refused one to the rejected list.
      auto& acc = result.pipeline.report.variants;
      for (std::size_t q = 0; q < acc.size(); ++q)
        if (acc[q].requested_volume_fraction == v.requested_volume_fraction) {
          acc[q].finish = fb;
          if (fb.verdict_changed) {
            acc[q].accepted = false;
            acc[q].rejection_reason = fb.verdict_reason;
            result.pipeline.report.rejected.push_back(acc[q]);
            acc.erase(acc.begin() + static_cast<std::ptrdiff_t>(q));
          }
          break;
        }
      std::fprintf(stderr, "[finish] version vf %.2f: %zu thin spot(s) fixed, %zu left; surface "
                   "%.1f %% stair-step removed; margin %.4g -> %.4g; mass %.4g -> %.4g g; %.1f s\n",
                   v.requested_volume_fraction, fb.fixed.size(), fb.left.size(),
                   fb.stair_step_removed_pct, fb.margin_before, fb.margin, fb.mass_before_grams,
                   fb.mass_grams, fb.seconds);
      if (fb.keep_clear_cut_mm3 > 0.0 || fb.keep_clear_sealed > 0)
        std::fprintf(stderr, "[keep clear] version vf %.2f: %.4g mm3 cut out of its Keep clears; "
                     "%d sealed inside the part\n",
                     v.requested_volume_fraction, fb.keep_clear_cut_mm3, fb.keep_clear_sealed);
    }
    // A version refused after finishing joins the rejected list in ladder order (a run
    // with no refusal keeps its list as it was).
    bool any_refused = false;
    for (const MinimizePlasticVariant& v : result.pipeline.evaluated)
      any_refused = any_refused || v.report.finish.verdict_changed;
    if (any_refused) {
      auto rank = [&](double vf) {
        for (std::size_t q = 0; q < result.pipeline.evaluated.size(); ++q)
          if (result.pipeline.evaluated[q].requested_volume_fraction == vf) return q;
        return result.pipeline.evaluated.size();
      };
      std::stable_sort(result.pipeline.report.rejected.begin(),
                       result.pipeline.report.rejected.end(),
                       [&](const VariantReport& a, const VariantReport& b) {
                         return rank(a.requested_volume_fraction) <
                                rank(b.requested_volume_fraction);
                       });
    }
    std::error_code rm;
    std::filesystem::remove_all(check_dir, rm);
    // STREAMED RUNS: a version's file went out as it finished optimizing (slim). Once
    // (e) has decided, every streamed version gets one FINISH line on stdout:
    //   FINISH vf=<requested> status=slim|safe|refused mesh=<path>[ reason=<plain words>]
    // "safe": the file was written again as the safe finish (re-fetch it); "refused":
    // the file, its alpha design and its latticed companions are withdrawn. report.json
    // is the final word either way.
    if (emit_progress) {
      auto mesh_path_of = [&](const MinimizePlasticVariant& v) {
        return join_path(out_dir, mesh_file_name(job.output.mesh_prefix,
                                                 v.requested_volume_fraction,
                                                 job.output.mesh_format));
      };
      std::vector<std::string> kept;
      for (const std::string& path : streamed_paths) {
        bool refused = false;
        for (const MinimizePlasticVariant& v : result.pipeline.evaluated)
          if (!v.accepted && v.report.finish.verdict_changed && path == mesh_path_of(v))
            refused = true;
        if (refused) std::remove(path.c_str()); else kept.push_back(path);
      }
      streamed_paths = std::move(kept);
      for (const MinimizePlasticVariant& v : result.pipeline.evaluated) {
        if (streamed_finish.count(v.requested_volume_fraction) == 0) continue;  // never streamed
        const std::string path = mesh_path_of(v);
        const char* status = "slim";
        if (!v.accepted && v.report.finish.verdict_changed) {
          status = "refused";
          char digits[8];
          std::snprintf(digits, sizeof(digits), "%03d",
                        static_cast<int>(std::lround(v.requested_volume_fraction * 100.0)));
          const std::string stem =
              join_path(out_dir, job.output.mesh_prefix + "_" + digits + "_alpha");
          std::remove((stem + ".f64").c_str());
          std::remove((stem + ".meta").c_str());
          const auto lp = lattice_paths_by_vf.find(v.requested_volume_fraction);
          if (lp != lattice_paths_by_vf.end())
            for (const std::string& q : lp->second) {
              std::remove(q.c_str());
              lattice_paths.erase(std::remove(lattice_paths.begin(), lattice_paths.end(), q),
                                  lattice_paths.end());
            }
        } else if (v.accepted && v.report.finish.finish_fallback) {
          // Streamed slim, re-checked safe: the file is written again as that shape.
          status = "safe";
          const auto m = finished_meshes.find(v.requested_volume_fraction);
          if (m != finished_meshes.end())
            (void)export_variant_mesh(v, out_dir, job.output, sg, run_printed_iso(options),
                                      &result.model, job.keep_regions, &fin, &m->second);
        } else if (!v.accepted) {
          continue;
        }
        const std::string& why = std::string(status) == "refused"
                                     ? v.report.finish.verdict_reason
                                     : v.report.finish.finish_fallback_reason;
        std::printf("FINISH vf=%.6f status=%s mesh=%s%s%s\n", v.requested_volume_fraction, status,
                    path.c_str(), why.empty() ? "" : " reason=", why.c_str());
      }
      std::fflush(stdout);
    }
  }

  // TO rebuild stage 1 (ledger A-05): a reduction run that accepted nothing says
  // how the part AS DRAWN stands against the load, so "nothing passed" is not read
  // as "nothing to optimise". One analysis solve, on this path only; the same
  // call Strengthen makes for its reference. Never takes the run down.
  if (to_stage1_on() && job.loads.present && job.loads.redesign != "strengthen" &&
      !result.pipeline.growth_ladder) {
    bool any_accepted = false;
    for (const MinimizePlasticVariant& v : result.pipeline.evaluated)
      any_accepted = any_accepted || v.accepted;
    if (!any_accepted) {
      try {
        const std::string drawn_dir = join_path(out_dir, "as_drawn_check");
        const AnalyzeJobResult drawn =
            analyze_job(job, job_dir, drawn_dir, materials, rules, "", {});
        result.pipeline.report.as_drawn.evaluated = true;
        result.pipeline.report.as_drawn.margin = drawn.analysis.margin_effective;
        result.pipeline.report.as_drawn.required = drawn.margin_required;
        std::error_code rm;
        std::filesystem::remove_all(drawn_dir, rm);
        std::fprintf(stderr, "[as drawn] no version passed; the part as drawn stands at "
                     "%.3g against %.3g\n",
                     drawn.analysis.margin_effective, drawn.margin_required);
      } catch (const std::exception& e) {
        std::fprintf(stderr, "[as drawn] could not be checked: %s\n", e.what());
      }
    }
  }

  // ──▶ report (both paths).
  result.report_json = job_report_json(result.pipeline.report);
  result.report_path = join_path(out_dir, job.output.report);
  write_text_file(result.report_path, result.report_json);

  // ──▶ the BUILD-ORIENTATION RECEIPT (handoff 2026-08-01-build-direction-
  // separation). A SEPARATE document, written only when the scorer was armed, so
  // report.json above and the meshes below are byte-identical whether it ran or
  // not (bar U1). It carries the RECOMMENDATION for the rung the run itself
  // recommends — the LIGHTEST ACCEPTED variant, i.e. the design the user is
  // actually going to print. Ranking the heavier rungs too would publish
  // recommendations for designs nobody exports.
  {
    const MinimizePlasticVariant* rec_variant = nullptr;
    for (const MinimizePlasticVariant& v : result.pipeline.evaluated)
      if (v.accepted && v.build_orientation.evaluated) rec_variant = &v;
    if (rec_variant != nullptr) {
      result.build_orientation_path =
          join_path(out_dir, "build_orientation.json");
      // The receipt reports the direction in the MODEL frame (every candidate
      // vector in the document is a model-frame vector) and carries the export
      // rotation beside it, so the reader is told which frame is which rather
      // than left to infer it. Off the bake path the rotation is absent and the
      // document is byte-identical to PR 271's.
      const std::optional<BuildFrameRotation> R =
          variant_bake_rotation(*rec_variant);
      result.build_orientation_json = build_orientation_report_json(
          rec_variant->build_orientation, rec_variant->applied_build_dir,
          R ? &*R : nullptr);
      write_text_file(result.build_orientation_path,
                      result.build_orientation_json);
    }
  }

  // ──▶ meshes: already written progressively when streaming; otherwise one
  // exported mesh per accepted variant now (byte-identical to the streamed files).
  if (emit_progress) {
    result.mesh_paths = std::move(streamed_paths);
    // Lattice companions were generated in the on_variant callback (streaming).
  } else {
    // E1: every file is the finished shape — the very mesh (e) re-checked, or, on a
    // strengthen run, the same finishing its verify ran.
    const RunFinish final_fin =
        make_run_finish(job, options, &result.model, result.pipeline.solved_grid);
    const RunFinish final_safe = safe_finish(final_fin);
    for (const MinimizePlasticVariant& variant : result.pipeline.evaluated) {
      if (!variant.accepted) continue;
      const auto cached = finished_meshes.find(variant.requested_volume_fraction);
      // A strengthen version that fell back in its verify exports the safe finish.
      result.mesh_paths.push_back(export_variant_mesh(
          variant, out_dir, job.output, result.pipeline.solved_grid,
          run_printed_iso(options), &result.model, job.keep_regions,
          variant.report.finish.finish_fallback ? &final_safe : &final_fin,
          cached != finished_meshes.end() ? &cached->second : nullptr));
      // The analytic design, written beside the mesh (S1(d)) and NOT added to
      // `mesh_paths` — see the streaming branch above for why.
      (void)export_variant_alpha(variant, out_dir, job.output,
                                 result.pipeline.solved_grid);
      emit_lattice(variant, /*stream_lines=*/false);  // batch: no stdout lines
    }
  }
  // Latticed companions land AFTER the solid meshes in mesh_paths (both paths), so
  // the worker serves them as ordinary out_dir artifacts (item 3: the iPad fetches
  // the file, never holds the mesh).
  result.mesh_paths.insert(result.mesh_paths.end(), lattice_paths.begin(),
                           lattice_paths.end());

  // Batch path (no streaming): emit_lattice ran in the loop just above, AFTER the
  // mid-run run_info write, so lat_agg is only now complete. Re-finalize the lattice
  // posture and re-write so a batch lattice run records its certification/export
  // provenance too (handoff 2026-07-29-lattice-certification-e2e). A streaming run
  // already recorded it; this re-write is identical there. Gated on lat_agg.any, so a
  // no-lattice run never touches run_info here (byte-identical, bar E2).
  if (wrote_run_info && !emit_progress && lat_agg.any) {
    finalize_lattice_run_info();
    finalize_export_frame_run_info();
    write_run_info(result.run_info_path, run_info);
  }

  // ──▶ *** THE ORIENTATION WAS CHOSEN FOR YOU — SAID OUT LOUD ***
  // (handoff 2026-08-01-bake-build-orientation, bar V7.) A run that picks the
  // orientation and rotates the exported geometry onto it has made a decision
  // the user did not make, and one that can change the verdict. The receipt says
  // so and the app says so; a CLI user who reads neither still gets told here,
  // on stderr, beside the other WARNINGs — the same channel that already
  // announces a rejected rung. Silence is the one thing this must never be.
  {
    // The rung the user actually exports — the LIGHTEST accepted one, the same
    // rung build_orientation.json describes, so the two cannot name different
    // orientations.
    const MinimizePlasticVariant* v = nullptr;
    for (const MinimizePlasticVariant& c : result.pipeline.evaluated)
      if (c.accepted && c.build_direction_auto_applied) v = &c;
    if (v != nullptr) {
    const bool rescued = v->build_orientation.auto_apply_changed_verdict;
    std::fprintf(
        stderr,
        "%s: no build_direction was declared, so this run CHOSE one "
        "(%.4g, %.4g, %.4g) and ROTATED the exported geometry onto it — in the "
        "file the build direction is +Z. The verdict describes that "
        "orientation.%s Declare \"build_direction\" to use your own instead "
        "(the export is then left in model coordinates). See "
        "build_orientation.json.\n",
        // `+ 0.0` clears NEGATIVE ZEROS before printing: unit(-gravity) of
        // (0,0,-1) is (-0,-0,1), and "(-0, -0, 1)" reads like a bug in a line
        // whose whole job is to be trusted at a glance.
        rescued ? "*** IMPORTANT" : "NOTE", v->applied_build_dir.x + 0.0,
        v->applied_build_dir.y + 0.0, v->applied_build_dir.z + 0.0,
        rescued ? " *** THIS PART PASSES BECAUSE OF THAT CHOICE: printed the "
                  "way this run would otherwise have assumed (the opposite of "
                  "gravity) it FAILS its strength check. ***"
                : "");
    std::fflush(stderr);
    }
  }

  // ──▶ per-voxel result fields (handoff 122): one versioned container for the
  // accepted variants' von Mises / displacement fields + voxel mass & support,
  // so a LAN remote run lights up the same overlays a local run does. Indexed to
  // the grid the run actually solved on (the expanded domain under a design box).
  // Additive: older readers ignore it; the meshes/report above are unchanged.
  result.fields_path = join_path(out_dir, "fields.bin");
  result.fields_variant_count =
      write_fields_file(result.fields_path, result.pipeline,
                        result.pipeline.solved_grid);
  // LOAD SCENARIOS — every scenario's own fields beside it (the Scenario menu's
  // views); fields.bin stays the governing scenario's. No file without 2+ scenarios.
  result.scenario_fields_variant_count = write_scenario_fields_file(
      join_path(out_dir, "scenario_fields.bin"), result.pipeline, result.pipeline.solved_grid);
  if (result.scenario_fields_variant_count > 0)
    result.scenario_fields_path = join_path(out_dir, "scenario_fields.bin");

  // ──▶ the DESIGN container (task 2026-08-02-lattice-a-variant): each evaluated
  // variant's own density field, the thing "lattice this variant" needs and the
  // one artifact a run never kept. A SEPARATE file, deliberately: report.json,
  // fields.bin and every mesh above stay byte-for-byte what they were, so the
  // whole existing optimize path is unchanged (bar Z6) and this is purely
  // additive. Older readers ignore it. See design_store.hpp for why the field is
  // stored at full double precision.
  result.design_path = join_path(out_dir, "design.bin");
  result.design_variant_count =
      write_design_file(result.design_path, result.pipeline,
                        result.pipeline.solved_grid);

  return result;
}


// E1 — THE FLIP TABLE (reviewer's brief 2026-11-02): a finished job's stored designs
// (its out/design.bin) re-finished WITHOUT re-optimizing. Per accepted version the
// unfinished export (today's file) and the finished one are each re-certified as a
// file (analyze_job), so mass, margin and the verdict compare like for like. One JSON
// line per version; a job whose solve grid no longer matches its store says so.
std::vector<std::string> refinish_job(const JobDescription& job, const std::string& job_dir,
                                      const std::string& design_path,
                                      const std::string& out_dir,
                                      const MaterialLibrary& materials,
                                      const SettingsRules& rules, bool export_only) {
  std::vector<std::string> lines;
  const StepModel model = import_part_file_resolved(join_path(job_dir, job.model));
  const bool model_is_mesh = part_format_for_path(job.model) != PartFormat::Step;
  JobSetup setup = build_job_setup(job, model, model_is_mesh, materials);
  const VoxelGrid sg = minimize_plastic_solved_grid(setup.grid, setup.options);
  const DesignStore ds = read_design_file(design_path);
  if (ds.nx != sg.nx || ds.ny != sg.ny || ds.nz != sg.nz) {
    lines.push_back("{\"error\": \"the stored designs' grid " + std::to_string(ds.nx) + "x" +
                    std::to_string(ds.ny) + "x" + std::to_string(ds.nz) +
                    " is not this core's solve grid " + std::to_string(sg.nx) + "x" +
                    std::to_string(sg.ny) + "x" + std::to_string(sg.nz) + "\"}");
    return lines;
  }
  const Material& material = materials.at(job.material);
  const RunFinish fin = make_run_finish(job, setup.options, &model, sg);
  const double iso = run_printed_iso(setup.options);
  std::error_code mk;
  std::filesystem::create_directories(out_dir, mk);
  for (const StoredDesign& d : ds.variants) {
    if (!d.accepted || d.density.size() != sg.voxel_count()) continue;
    const auto t0 = std::chrono::steady_clock::now();
    MinimizePlasticVariant v;
    v.requested_volume_fraction = d.requested_volume_fraction;
    v.accepted = true;
    v.optimization.physical_density = d.density;
    const TriangleMesh raw = weld_as_written(
        variant_export_model_mesh(v, job.output, sg, iso, &model, job.keep_regions));
    if (export_only) {  // the written file's edges, stage by stage (no solves)
      FinishBlock fb;
      const TriangleMesh done =
          variant_export_model_mesh(v, job.output, sg, iso, &model, job.keep_regions, &fin, &fb);
      const DesignMask* clear_p =
          setup.options.clearance_void.size() == sg.voxel_count() ? &setup.options.clearance_void : nullptr;
      auto kc = [&](const TriangleMesh& m) {
        return file_keep_clear_voxels(file_occupancy(m, sg), clear_p, nullptr);
      };
      const TriangleMesh raw_unwelded =
          variant_export_model_mesh(v, job.output, sg, iso, &model, job.keep_regions);
      // The cut moves nothing away from the Keep clears: every vertex of the uncut
      // finished file outside them (by 0.05 mm) is in the cut file, bit for bit, or in a
      // piece the cut left loose (gone as every loose piece goes: on e5909008 a cap 0.5 mm
      // thick that sat on the part's face only through a Keep clear 0.17 mm past it).
      // Lost vertices: in a loose piece, then by place: on the part's own surface (CAD /
      // Protect, must be 0), in a Protect region, in a declared Keep clear (the cut),
      // elsewhere (must be 0).
      long long cut_lost = 0, cut_lost_far = 0, cut_lost_part = 0, cut_lost_keep = 0, cut_lost_loose = 0;
      {
        RunFinish nocut = fin;
        nocut.part = nullptr;
        nocut.keep_clear_cut = nullptr;
        FinishBlock fb0;
        const TriangleMesh done0 =
            variant_export_model_mesh(v, job.output, sg, iso, &model, job.keep_regions, &nocut, &fb0);
        auto f3 = [](const Vec3& q) {
          return std::array<float, 3>{static_cast<float>(q.x), static_cast<float>(q.y), static_cast<float>(q.z)};
        };
        std::set<std::array<float, 3>> have, whole;  // the cut file; the cut before its loose pieces go
        for (const Vec3& q : done.vertices) have.insert(f3(q));
#ifdef TOPOPT_HAVE_MANIFOLD
        if (fin.keep_clear_cut != nullptr && fin.keep_clear_cut->any)  // try 0's cutter
          for (const Vec3& q :
               weld_as_written(manifold_mesh((mesh_manifold(done0) - fin.keep_clear_cut->cutter).GetMeshGL()))
                   .vertices)
            whole.insert(f3(q));
#endif
        for (const Vec3& q : done0.vertices) {
          if (have.count(f3(q))) continue;
          ++cut_lost;
          if (whole.count(f3(q))) { ++cut_lost_loose; continue; }
          double d2 = 1e30;
          for (const auto& t : model.mesh.triangles)
            d2 = std::min(d2, point_triangle_d2(q, model.mesh.vertices[t[0]], model.mesh.vertices[t[1]],
                                                model.mesh.vertices[t[2]]));
          if (d2 < 1e-8) { ++cut_lost_part; continue; }  // within 0.1 um of the part's surface
          bool in_clear = false, in_keep = false;
          for (const ClearanceGeometry& g : fin.keep_clears) in_clear = in_clear || point_in_clearance_region(g, q, 0.05);
          for (const KeepRegion& k : job.keep_regions) in_keep = in_keep || k.contains(q);
          cut_lost_keep += in_keep && !in_clear;
          cut_lost_far += !in_keep && !in_clear;
        }
      }
      long long kc_part = 0, kc_face = 0;  // confirmed on the file: inside the part / on its face
      const long long kc_exact = file_keep_clear_exact(done, sg, file_occupancy(done, sg), clear_p,
                                                       nullptr, &model.mesh, &kc_part, &kc_face);
      const long long kc_unwelded = kc(raw_unwelded);
      long long design_kc = 0;  // the design's own: printed voxels (rho > iso) kept clear
      if (clear_p != nullptr)
        for (std::size_t i = 0; i < d.density.size(); ++i)
          design_kc += d.density[i] > iso && (*clear_p)[i] == MaskValue::FrozenVoid;
      auto au = [](const char* name, const TriangleMesh& m) {
        const WrittenAudit w = audit_as_written(m);
        char b[256];
        std::snprintf(b, sizeof b, "\"%s\": [%d, %d, %d, %d, %d]", name, w.non_manifold_edges,
                      w.boundary_edges, w.non_manifold_vertices, w.shells, w.bodies);
        std::string s = b;
        for (const Vec3& p : w.bad_edge_midpoints) {
          std::snprintf(b, sizeof b, " (%.3f %.3f %.3f)", p.x, p.y, p.z);
          s += b;
        }
        return s;
      };
      lines.push_back("{\"vf\": " + std::to_string(d.requested_volume_fraction) + ", " +
                      au("mc", variant_export_model_mesh(v, job.output, sg, iso, nullptr, {})) + ", " +
                      au("cad", variant_export_model_mesh(v, job.output, sg, iso, &model, {})) + ", " +
                      au("keep", raw) + ", " + au("finished", done) + ", \"keep_clear\": [" +
                      std::to_string(kc(variant_export_model_mesh(v, job.output, sg, iso, nullptr, {}))) + ", " +
                      std::to_string(kc(variant_export_model_mesh(v, job.output, sg, iso, &model, {}))) + ", " +
                      std::to_string(kc(raw)) + ", " + std::to_string(kc(done)) + "], " +
                      "\"design_keep_clear\": " + std::to_string(design_kc) + ", \"thin_joints\": [" +
                      std::to_string(file_thin_joints(sg, file_occupancy(raw, sg))) + ", " +
                      std::to_string(file_thin_joints(sg, file_occupancy(done, sg))) + "], \"held\": " +
                      std::to_string(fb.keep_clear_held) + ", \"left\": " + std::to_string(fb.keep_clear_left) +
                      ", \"kc_unwelded_raw\": " + std::to_string(kc_unwelded) +
                      ", \"kc_exact\": [" + std::to_string(kc_exact) + ", " + std::to_string(kc_part) + ", " +
                      std::to_string(kc_face) + "]" +
                      ", \"kc_cut_mm3\": " + std::to_string(fb.keep_clear_cut_mm3) +
                      ", \"kc_sealed\": " + std::to_string(file_sealed_keep_clears(done, sg, clear_p)) +
                      ", \"cut_lost\": [" + std::to_string(cut_lost) + ", " + std::to_string(cut_lost_part) + ", " +
                      std::to_string(cut_lost_keep) + ", " + std::to_string(cut_lost_far) + ", " +
                      std::to_string(cut_lost_loose) + "]" + ", \"stair_step_pct\": " +
                      std::to_string(fb.stair_step_removed_pct) + ", \"slim\": " +
                      (fb.slim ? "true" : "false") + ", \"diag\": [" +
                      std::to_string(done.vertices.size()) + ", " + std::to_string(fb.pinned_vertices) +
                      ", " + std::to_string(fb.outward_only_vertices) + ", " +
                      std::to_string(fb.roughness_vertices) + ", " +
                      std::to_string(fb.slim_rounds) + ", " +
                      std::to_string(fb.slim_guarded_vertices) + ", " +
                      std::to_string(fb.fold_walked_back) + ", " +
                      std::to_string(fb.roughness_before_mm) + ", " +
                      std::to_string(fb.roughness_after_mm) + "], \"why\": " +
                      json_str(fb.finish_fallback_reason) + "}");
      continue;
    }
    // Before: the unfinished file, re-certified (welded as written, as a file is).
    const std::string a_stl = join_path(out_dir, "before.stl");
    write_stl_file(a_stl, raw);
    AnalyzeJobResult a;
    std::string a_err;
    try {
      a = analyze_job(job, job_dir, join_path(out_dir, "a"), materials, rules, a_stl, {});
    } catch (const std::exception& e) {
      a_err = e.what();
    }
    // After: what a run ships — slim, the safe finish on a failing re-check.
    const DesignMask* clearance =
        !setup.options.clearance_void.empty() &&
                setup.options.clearance_void.size() == sg.voxel_count()
            ? &setup.options.clearance_void
            : nullptr;
    const double req0 = a_err.empty() ? a.margin_required : 0.0;
    VersionFinish f = finish_and_recheck(v, job, job_dir, sg, iso, &model, fin, clearance,
                                         material.density_g_cm3, materials, rules,
                                         join_path(out_dir, "b"),
                                         a_err.empty() ? a.analysis.margin_effective : 0.0, req0);
    const FinishBlock& fb = f.fb;
    const TriangleMesh& done = f.mesh;
    const WrittenAudit w = audit_as_written(done);
    // The bar's own measures: a member newly under the slim line (by moving material
    // in; and as the surface measure reads it), a pinned vertex moved (CAD / Protect
    // bit-identical), on the same vertex indices.
    int new_under = 0, new_under_measured = 0, pinned_moved = 0;
    double thinnest_new = 0.0;
    {
      const ThinnedCount tc = count_thinned(raw, done, fin.ctx.slim_line_mm);
      new_under = tc.comparable ? tc.by_inward : -1;  // -1: the weld merged vertices
      new_under_measured = tc.comparable ? tc.measured : -1;
      thinnest_new = tc.thinnest_mm;
    }
    pinned_moved = static_cast<int>(fb.pinned_moved);
    const double req = f.analysis.margin_required > 0.0 ? f.analysis.margin_required : req0;
    const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    char buf[1500];
    std::snprintf(buf, sizeof buf,
                  "{\"vf\": %.4f, \"mass_before_g\": %.4f, \"mass_after_g\": %.4f, "
                  "\"margin_before\": %.4f, \"margin_after\": %.4f, \"margin_required\": %.4f, "
                  "\"accept_before\": %s, \"accept_after\": %s, \"thin_fixed\": %zu, "
                  "\"thin_left\": %zu, \"stair_step_pct\": %.1f, \"style\": \"%s\", "
                  "\"fallback\": %s, \"pieces_before\": %d, \"pieces_after\": %d, "
                  "\"bad_edges\": %d, \"open_edges\": %d, \"point_contacts\": %d, "
                  "\"shells\": %d, \"bodies\": %d, \"new_under_line\": %d, "
                  "\"new_under_line_measured\": %d, "
                  "\"thinnest_new_mm\": %.3f, \"pinned_moved\": %d, \"keep_clear_voxels\": %lld, "
                  "\"keep_clear_before\": %lld, \"keep_clear_added\": %lld, \"keep_clear_left\": %zu, "
                  "\"thin_joints\": %d, \"keep_clear_cut_mm3\": %.4f, \"keep_clear_sealed\": %d, "
                  "\"finish_s\": %.2f, "
                  "\"seconds\": %.1f}",
                  d.requested_volume_fraction,
                  material.density_g_cm3 * std::fabs(signed_volume(raw)) / 1000.0,
                  material.density_g_cm3 * std::fabs(signed_volume(done)) / 1000.0,
                  a_err.empty() ? a.analysis.margin_effective : -1.0, fb.margin, req,
                  a_err.empty() && a.analysis.margin_effective >= req ? "true" : "false",
                  f.refusal.empty() ? "true" : "false", fb.fixed.size(), fb.left.size(),
                  fb.stair_step_removed_pct, fb.slim ? "slim" : "safe",
                  fb.finish_fallback ? "true" : "false", positive_volume_bodies(raw),
                  positive_volume_bodies(done), w.non_manifold_edges, w.boundary_edges,
                  w.non_manifold_vertices, w.shells, w.bodies, new_under, new_under_measured,
                  thinnest_new,
                  pinned_moved, fb.keep_clear_voxels, fb.keep_clear_before, fb.keep_clear_added,
                  fb.keep_clear_left, fb.thin_joints, fb.keep_clear_cut_mm3, fb.keep_clear_sealed,
                  fb.seconds, secs);
    std::map<std::string, int> why;
    for (const FinishPlace& p : fb.left) ++why[p.reason];
    std::string wr;
    for (const auto& kv : why) wr += (wr.empty() ? "" : "; ") + kv.first + " " + std::to_string(kv.second);
    std::string line = buf;
    line.pop_back();
    line += ", \"left_reasons\": " + json_str(wr) + ", \"fallback_reason\": " +
            json_str(fb.finish_fallback_reason) + ", \"refusal\": " + json_str(f.refusal) +
            ", \"before_error\": " + json_str(a_err) + ", \"vertices\": " +
            std::to_string(done.vertices.size()) + ", \"pinned\": " +
            std::to_string(fb.pinned_vertices) + ", \"measured\": " +
            std::to_string(fb.roughness_vertices) + "}";
    lines.push_back(line);
  }
  return lines;
}
