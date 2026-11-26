// to_export.inc -- the print-file export chain: marching cubes, resample, CAD projection, keep regions, finish, weld, re-check.
//
// TO rebuild stage 0 (docs/design/to-rebuild/05-workplan.md): moved out of
// run_job.cpp unchanged, line for line. This is NOT a translation unit: it is
// included by run_job.cpp at the place the code used to stand, inside
// namespace topopt, so every name resolves exactly as before. Do not compile
// it on its own and do not include it anywhere else.

// TO rebuild stage 3: the print surface from the optimiser's own function
// (level_surface.hpp). This file sits inside run_job.cpp's `namespace topopt {
// namespace {`, so the header is included at file scope by closing and reopening
// both (the same unnamed namespace is reopened). Goes when to_export becomes a
// real .cpp.
}  // namespace
}  // namespace topopt
#include "topopt/level_surface.hpp"
namespace topopt {
namespace {

// ENGINE BATCH E1 — a run's finishing context (finish.hpp): the printable minimum
// (2 x the outer wall line width), the export cell, the forbidden voxels (Keep clear
// and Protect's reach), the box (growth) or the part (reduction), and the CAD.
struct RunFinish {
  FinishContext ctx;
  std::vector<char> part_solid;
  std::vector<char> part_voxels;  // the part as drawn, either run type (pins without CAD)
  std::vector<ClearanceGeometry> keep_clears;  // the job's declared Keep clears, resolved
  const TriangleMesh* part = nullptr;          // the part's own solid (wins over a Keep clear)
  std::shared_ptr<const KeepClearCut> keep_clear_cut;  // made once (null: nothing to cut)
  // Stage 3: the frozen bodies as drawn-face geometry (frozen_sets.hpp), for the
  // surface from the function. Empty unless stage 1 filled them.
  std::vector<FrozenFaceSet> frozen;
};

RunFinish make_run_finish(const JobDescription& job, const MinimizePlasticOptions& o,
                          const StepModel* cad, const VoxelGrid& sg) {
  RunFinish f;
  const double outer = o.wall_line_width_outer_mm > 0.0 ? o.wall_line_width_outer_mm
                                                         : o.wall_line_width_mm;
  f.ctx.min_thickness_mm = outer > 0.0 ? 2.0 * outer : 0.0;
  char src[96];
  std::snprintf(src, sizeof src, "2 \u00D7 outer wall line width (%.2f mm)", outer);
  f.ctx.min_thickness_source = src;
  f.ctx.cell_mm = sg.spacing / static_cast<double>(std::max(1, job.output.smooth_factor));
  f.ctx.grid = &sg;
  if (!o.clearance_void.empty() && o.clearance_void.size() == sg.voxel_count())
    f.ctx.forbidden = &o.clearance_void;
  f.ctx.keeps = &job.keep_regions;
  f.ctx.growth = o.design_box.has_value();
  if (f.ctx.growth) {
    f.ctx.has_box = true;
    f.ctx.box = *o.design_box;
  } else {
    f.part_solid.resize(sg.voxel_count());
    for (std::size_t i = 0; i < sg.voxel_count(); ++i) f.part_solid[i] = sg.tags[i] != VoxelTag::Empty;
  }
  // CAD faces pin where the projection made them exact, and only there: a STATED face
  // (STEP) with project_cad_faces on. A fitted face (STL / 3MF segmentation) is not
  // projected (variant_export_model_mesh), so the export carries the voxel surface
  // there and an attribution by tolerance would differ between an STL and a 3MF
  // import of one part; such a part's own faces are told apart by the voxels instead
  // (thin_spot_cleanup: the part's boundary).
  f.ctx.cad = job.output.project_cad_faces && cad != nullptr && !cad->faces_are_fitted ? cad : nullptr;
  f.ctx.cad_spacing_mm = sg.spacing;
  if (f.ctx.cad == nullptr && cad != nullptr && !cad->mesh.empty()) {
    // The part as drawn on the solve grid: its own mesh voxelized there (a growth
    // run's grid tags the design box as material too).
    const VoxelGrid pv = voxelize_onto_grid(cad->mesh, sg);
    f.part_voxels.assign(sg.voxel_count(), 0);
    for (std::size_t i = 0; i < sg.voxel_count() && i < pv.tags.size(); ++i)
      f.part_voxels[i] = pv.tags[i] != VoxelTag::Empty;
  }
  if (cad != nullptr && !cad->mesh.empty()) {  // every file is cut out of its Keep clears
    f.keep_clears = lattice_keep_outs_from_job(job, *cad);
    f.part = &cad->drawn_mesh();  // stage 3: the 0.01 mm copy when made
    if (!f.keep_clears.empty() || !job.keep_regions.empty())
      f.keep_clear_cut = std::make_shared<const KeepClearCut>(
          make_keep_clear_cut(cad->drawn_mesh(), f.keep_clears, job.keep_regions));
  }
  f.ctx.slim_line_mm = 2.0 * f.ctx.min_thickness_mm;  // his ruling 2026-11-03: slim
  // A latticed job's versions carry a lattice companion built from the unfinished shape.
  f.ctx.outward_only = job.lattice.present || job.grading.present;
  f.frozen = o.frozen_sets;
  return f;
}

// The same finishing with C2's own thin-section line: the per-version fallback.
RunFinish safe_finish(const RunFinish& fin) {
  RunFinish f = fin;
  f.ctx.slim_line_mm = 0.0;
  if (!f.part_solid.empty()) f.ctx.part_solid = nullptr;  // re-pointed per use
  f.ctx.part_voxels = nullptr;
  return f;
}

FinishBlock finish_block(const FinishReport& r) {
  FinishBlock b;
  b.ran = r.ran;
  b.min_thickness_mm = r.min_thickness_mm;
  b.min_thickness_source = r.min_thickness_source;
  for (const ThinSpot& t : r.fixed) b.fixed.push_back({t.centre_mm, t.before_mm, t.after_mm, ""});
  for (const ThinSpot& t : r.left) b.left.push_back({t.centre_mm, t.before_mm, t.after_mm, t.reason});
  b.surface_applied = r.surface_applied;
  b.stair_step_removed_pct = r.stair_step_removed_pct;
  b.slim = r.slim;
  b.finish_fallback = r.fallback;
  b.finish_fallback_reason = r.fallback_reason;
  b.volume_before_mm3 = std::fabs(r.volume_before_mm3);
  b.volume_after_mm3 = std::fabs(r.volume_after_mm3);
  b.pinned_vertices = r.pinned_vertices;
  b.pinned_moved = r.pinned_moved;
  b.roughness_vertices = r.roughness_vertices;
  b.outward_only_vertices = r.outward_only_vertices;
  b.slim_guarded_vertices = r.slim_guarded_vertices;
  b.fold_walked_back = r.fold_held_vertices;
  b.keep_clear_held = r.keep_clear_held_vertices;
  b.keep_clear_left = r.keep_clear_left;
  b.slim_rounds = r.slim_rounds;
  b.roughness_before_mm = r.roughness_before_mm;
  b.roughness_after_mm = r.roughness_after_mm;
  b.seconds = r.seconds;
  return b;
}

TriangleMesh variant_export_model_mesh(const MinimizePlasticVariant& variant,
                                       const JobOutput& out, const VoxelGrid& sg,
                                       double printed_iso = 0.5,
                                       const StepModel* cad = nullptr,
                                       const std::vector<KeepRegion>& keeps = {},
                                       const RunFinish* fin = nullptr,
                                       FinishBlock* fb = nullptr,
                                       TriangleMesh* unfinished = nullptr,
                                       const std::vector<FrozenFaceSet>* frozen = nullptr,
                                       const DesignBox* box = nullptr) {
  if (fin != nullptr) {  // E1: the finished shape, after CAD projection and exact Protect
    const TriangleMesh raw = variant_export_model_mesh(
        variant, out, sg, printed_iso, cad, keeps, nullptr, nullptr, nullptr, &fin->frozen,
        fin->ctx.has_box ? &fin->ctx.box : nullptr);
    FinishContext c = fin->ctx;
    // Stage 3: a surface meshed from the function needs no curvature flow.
    if (to_surface_on()) c.flow = false;
    c.density = &variant.optimization.physical_density;
    if (!fin->part_solid.empty()) c.part_solid = &fin->part_solid;
    c.part_voxels = fin->part_voxels.empty() ? nullptr : &fin->part_voxels;
    FinishReport r;
    // Welded as written: the file is the shape (a float-coincident sliver goes).
    TriangleMesh m = weld_as_written(finish_shape(raw, c, &r));
    double cut = 0.0;
    if (fin->part != nullptr && fin->keep_clear_cut != nullptr)
      m = keep_clear_exact(m, *fin->keep_clear_cut, *fin->part, fin->keep_clears, keeps,
                           sg.spacing * sg.spacing * sg.spacing, &cut, c.min_thickness_mm);
    if (fb) {
      *fb = finish_block(r);
      fb->keep_clear_cut_mm3 = cut;
    }
    if (unfinished) *unfinished = raw;
    return m;
  }
  // Stage 3 (switch on): the surface from the function, with the keep regions
  // joined before its one cut by the drawn part (no second union, no nudge).
  if (to_surface_on() && cad != nullptr && !cad->mesh.empty()) {
    TriangleMesh keep_solid;
#ifdef TOPOPT_HAVE_MANIFOLD
    if (!keeps.empty()) {
      manifold::Manifold K;
      // Grown 0.01 mm, as keep_regions_exact's kCut: two regions that meet only along
      // an edge then overlap instead of leaving four triangles on that edge.
      for (const KeepRegion& k : keeps) K = K + keep_region_solid(k, 0.01);
      const manifold::MeshGL64 g = K.GetMeshGL64();
      for (std::size_t v = 0; v < g.NumVert(); ++v)
        keep_solid.vertices.push_back({g.vertProperties[v * g.numProp],
                                       g.vertProperties[v * g.numProp + 1],
                                       g.vertProperties[v * g.numProp + 2]});
      for (std::size_t t = 0; t < g.NumTri(); ++t)
        keep_solid.triangles.push_back({static_cast<int>(g.triVerts[3 * t]),
                                        static_cast<int>(g.triVerts[3 * t + 1]),
                                        static_cast<int>(g.triVerts[3 * t + 2])});
    }
#endif
    if (keeps.empty() || !keep_solid.triangles.empty()) {
      std::string why;
      FunctionSurfaceReport fr;
      TriangleMesh m = function_surface_mesh(
          variant, sg, cad->drawn_mesh(), std::max(1, out.smooth_factor), printed_iso, &why,
          &fr, frozen, cad, keeps.empty() ? nullptr : &keeps,
          keep_solid.triangles.empty() ? nullptr : &keep_solid, box);
      if (!m.triangles.empty()) {
        std::fprintf(stderr,
                     "[surface] vf %.2f: from the function: %lld triangles, mesh %.2f s, "
                     "cut %.2f s, %d frozen bodies by distance, %zu keep regions, stamped "
                     "%lld solid / %lld void voxels, slope at the surface %.2f / %.2f / %.2f "
                     "(min / median / max)\n",
                     variant.requested_volume_fraction, fr.triangles, fr.mesh_s, fr.cut_s,
                     fr.frozen_sets, keeps.size(), fr.stamped_solid, fr.stamped_void,
                     fr.slope_min, fr.slope_median, fr.slope_max);
        return m;
      }
      std::fprintf(stderr, "[surface] vf %.2f: kept the voxel export: %s\n",
                   variant.requested_volume_fraction, why.c_str());
    }
  }
  if (!keeps.empty() && cad != nullptr)  // item KEEP: exact inside each keep region
    return keep_regions_exact(
        variant_export_model_mesh(variant, out, sg, printed_iso, cad, {}, nullptr, nullptr,
                                  nullptr, frozen, box),
        cad->drawn_mesh(),
        keeps, sg.spacing * sg.spacing * sg.spacing);
  const int sf = out.smooth_factor;
  TriangleMesh smooth;  // only populated when sf > 1
  if (sf > 1) {
    const TriangleMesh raw = marching_cubes_resampled(
        sg.nx, sg.ny, sg.nz, sg.spacing, sg.origin,
        variant.optimization.physical_density, printed_iso, sf,
        ResampleInterp::Tricubic);
    // CORE LIST item 41 — every body holding an anchor or a load, mapped from the
    // solve grid's bodies (keep_largest_component's shell on a one-body part).
    BodyShells shells = carrying_body_shells(
        raw, sg,
        printed_bodies(sg, variant.optimization.physical_density, printed_iso));
    if (shells.bodies_without_shell > 0)
      std::fprintf(stderr,
                   "WARNING: variant vf %.2f: %d carrying body(ies) left no shell "
                   "in the smooth_factor %d resample, so the exported file does "
                   "not carry them.\n",
                   variant.requested_volume_fraction, shells.bodies_without_shell,
                   sf);
    smooth = std::move(shells.mesh);
  }
  // CAD-FACE PROJECTION (task 2026-08-06-cad-face-projection), DEFAULT OFF.
  //
  // WHY IT HAPPENS HERE, and it is the only place it can. The exported mesh
  // carries no face ids and cannot: it is extracted by marching cubes from a
  // scalar density field (the call just above), which has no face channel, and
  // written to STL/3MF, which have no per-triangle attribute slot. So the
  // attribution has to be re-established from geometry — and this is the last
  // point in the pipeline where the imported CAD is still in hand.
  //
  // It runs BEFORE the bake rotation so the projection is done in the frame the
  // CAD's own planes and cylinder axes are stated in.
  // ★ AND ONLY WHERE THE SURFACES WERE READ, NOT FITTED (task
  // 2026-08-06-arm-projection-and-void-check, the PR 309 CI failure).
  //
  // `faces_are_fitted` is true for an STL/3MF import, whose "faces" are
  // manufactured by segmentation: segment.cpp:185 fits a plane from a patch's
  // MEAN NORMAL and :280 fits a cylinder by least squares, within a tolerance.
  // Projecting onto those is not restoring a stated surface, it is snapping
  // geometry onto an estimate of itself — the one thing this operation promised
  // never to do ("nothing is averaged, no surface is estimated", job.hpp).
  //
  // IT ALSO BREAKS AN INVARIANT, which is how it was caught. The fit is computed
  // FROM the imported vertices, so the same part imported from STL (quantised to
  // float32 by the format) and from 3MF (full double, decimal text) fits
  // slightly different surfaces and therefore exports different files. On
  // plate_bore that is ~1000 of 6972 corners differing by ~2.4e-07 mm — a
  // pervasive last-bit divergence, six orders of magnitude smaller than the
  // ~1.5 mm voxel, i.e. exactly the size of a float32 quantum in the INPUT.
  // `threemf_import`'s "STL and 3MF export byte-identical variant meshes" is the
  // assertion that says two front doors to the same part must not disagree, and
  // it is right.
  //
  // Measured, not reasoned: the fixture passes on the merge base, fails on this
  // branch, and passes again with `project_cad_faces` false — see
  // evidence/…/a1_root_cause.txt.
  TriangleMesh projected;
  if (out.project_cad_faces && cad != nullptr && !cad->faces.empty() &&
      !cad->faces_are_fitted) {
    const TriangleMesh& src = (sf > 1) ? smooth : variant.exported_mesh();
    CadProjectOptions po = cad_project_options_for_grid(sg.spacing);
    po.enabled = true;
    const CadAttribution att = attribute_to_cad_faces(src, *cad, po);
    projected = project_onto_cad_faces(src, *cad, po, att);
  }
  if (!projected.vertices.empty()) return projected;
  return (sf > 1) ? smooth : variant.exported_mesh();
}

// E1 (e) WITH HIS FALLBACK (reviewer's rulings 2026-11-03 02:46 + 02:48): one
// version's finished shape, re-checked as the FILE it ships as (the normal import:
// the file is clean), slim first and, when a re-check fails, safe
// (finish_with_fallback). Margin, Keep clear, pieces, loose pieces and thin joints
// (edge / corner-only contacts of the file on the solve grid, against the unfinished
// file's) — the reason is plain words, never a silent pass.
struct VersionFinish {
  TriangleMesh mesh;  // the finished shape that ships (model frame)
  FinishBlock fb;
  std::string refusal;  // non-empty: refused after finishing, for this reason
  AnalyzeJobResult analysis;
};
// A streamed version's slim finish, made when its file was written: (e) re-checks it
// instead of finishing the version again.
struct StreamedFinish {
  TriangleMesh mesh;  // the finished shape (model frame)
  TriangleMesh raw;   // the unfinished export it was finished from
  FinishBlock fb;
};

// The finished FILE's own checks beside its analysis, filled into `fb`: Keep clear
// voxels it prints (`exclude`, may be null: voxels not counted, strengthen's frozen
// part), its bodies, loose pieces and edge-only joints, each against the unfinished
// file `raw` (only what finishing added refuses), and the analysis's own gate. The
// caller sets the margin it needs (`rc.margin_required`) before finish_verdict_reason.
// The solve-grid voxels whose centres a file `m` encloses.
std::vector<char> file_occupancy(const TriangleMesh& m, const VoxelGrid& sg) {
  const VoxelGrid fv = voxelize_onto_grid(m, sg);
  std::vector<char> o(sg.voxel_count(), 0);
  for (std::size_t i = 0; i < o.size() && i < fv.tags.size(); ++i) o[i] = fv.tags[i] != VoxelTag::Empty;
  return o;
}

// Keep clear voxels a file prints (`clearance` may be null: none; `exclude` may be null:
// voxels it freezes solid, strengthen's frozen part, are not counted).
long long file_keep_clear_voxels(const std::vector<char>& occ, const DesignMask* clearance,
                                 const DesignMask* exclude) {
  long long n = 0;
  if (clearance != nullptr && clearance->size() == occ.size())
    for (std::size_t i = 0; i < occ.size(); ++i)
      n += occ[i] && (*clearance)[i] == MaskValue::FrozenVoid &&
           !(exclude != nullptr && (*exclude)[i] == MaskValue::FrozenSolid);
  return n;
}

double point_triangle_d2(const Vec3& p, const Vec3& a, const Vec3& b, const Vec3& c);

// The same count, each centre CONFIRMED on the file itself: the voxel test's +Z ray
// parity misreads columns through the thin band an uncut export leaves on a bore wall
// (his efe18e33: 14,988 voxels by the voxel test, 35 confirmed; 4 and 4 once cut), so
// every centre it counts is checked by the generalized winding number (mesh_encloses).
// A centre inside the part's own solid (`part`, may be null) is part material, which
// wins over a Keep clear (rasterize_clearance's precedence), and one on the part's own
// face is the part's surface: `in_part` and `on_face` (may be null) count those and
// they are not in the result.
long long file_keep_clear_exact(const TriangleMesh& m, const VoxelGrid& sg,
                                const std::vector<char>& occ, const DesignMask* clearance,
                                const DesignMask* exclude, const TriangleMesh* part,
                                long long* in_part = nullptr, long long* on_face = nullptr) {
  if (in_part) *in_part = 0;
  if (on_face) *on_face = 0;
  if (clearance == nullptr || clearance->size() != occ.size()) return 0;
  const std::size_t nx = static_cast<std::size_t>(sg.nx), nxy = nx * static_cast<std::size_t>(sg.ny);
  std::vector<Vec3> c;
  for (std::size_t i = 0; i < occ.size(); ++i)
    if (occ[i] && (*clearance)[i] == MaskValue::FrozenVoid &&
        !(exclude != nullptr && (*exclude)[i] == MaskValue::FrozenSolid))
      c.push_back(sg.voxel_center(static_cast<int>(i % nx), static_cast<int>((i % nxy) / nx),
                                  static_cast<int>(i / nxy)));
  // A centre within kOnFace of the part's surface AND of the file's is ON the part's own
  // face, not material in a Keep clear: the cut holds the part's surface by 2-8 um (so
  // it never re-cuts it), and the file is written in float (about 4 um at 100 mm). His
  // efe18e33 kept 4 such centres after the cut, 0.02-0.4 um outside the part's bore
  // walls, the file's surface 1.6-2 um further out.
  constexpr double kOnFace = 0.01;  // mm
  auto near = [](const TriangleMesh& s, const Vec3& p) {
    for (const auto& t : s.triangles)
      if (point_triangle_d2(p, s.vertices[t[0]], s.vertices[t[1]], s.vertices[t[2]]) <
          kOnFace * kOnFace)
        return true;
    return false;
  };
  // One winding sum is O(triangles): the centres are split over the cores.
  std::vector<char> enc(c.size(), 0), inp(c.size(), 0), onf(c.size(), 0);
  const unsigned hc = std::max(1u, std::min(16u, std::thread::hardware_concurrency()));
  std::vector<std::thread> pool;
  for (unsigned t = 0; t < hc; ++t)
    pool.emplace_back([&, t] {
      for (std::size_t k = t; k < c.size(); k += hc) {
        enc[k] = mesh_encloses(m, c[k]);
        if (enc[k] && part != nullptr) inp[k] = mesh_encloses(*part, c[k]);
        if (enc[k] && !inp[k] && part != nullptr) onf[k] = near(*part, c[k]) && near(m, c[k]);
      }
    });
  for (std::thread& th : pool) th.join();
  long long n = 0, p = 0, f = 0;
  for (std::size_t k = 0; k < c.size(); ++k) {
    n += enc[k] && !inp[k] && !onf[k];
    p += enc[k] && inp[k];
    f += onf[k];
  }
  if (in_part) *in_part = p;
  if (on_face) *on_face = f;
  return n;
}

FinishRecheck recheck_file(const TriangleMesh& m, const TriangleMesh& raw, const VoxelGrid& sg,
                           const DesignMask* clearance, const DesignMask* exclude,
                           const AnalyzeJobResult& a, double margin_required, FinishBlock& fb,
                           const TriangleMesh* part) {
  const std::vector<char> occ = file_occupancy(m, sg), occ0 = file_occupancy(raw, sg);
  fb.recheck_ran = true;
  fb.margin = a.analysis.margin_effective;
  // ANY material in a Keep clear refuses (ruling 2026-11-03 19:55), each voxel confirmed
  // on the file and outside the part's own solid.
  fb.keep_clear_voxels = file_keep_clear_exact(m, sg, occ, clearance, exclude, part);
  // Pieces: the file's bodies (positive-volume shells; a sealed void is not one).
  fb.pieces = positive_volume_bodies(m);
  // Edge- and corner-only joints, exactly, on the file's own mesh: an edge on more than
  // two triangles, a vertex where shells touch. (On its voxels a smoother surface flips
  // a few centres: his unfinished files read 32-42 diagonal contacts each, 2-4 more
  // finished, none of them in the mesh.)
  const WrittenAudit wa = audit_as_written(m), wa0 = audit_as_written(raw);
  fb.thin_joints = wa.non_manifold_edges + wa.non_manifold_vertices;
  fb.loose_pieces = file_loose_pieces(sg, occ);
  const FixedDesignAnalysis& an = a.analysis;
  FinishRecheck rc;
  rc.ran = true;
  rc.margin = fb.margin;
  rc.margin_required = a.margin_required > 0.0 ? a.margin_required : margin_required;
  rc.non_convergent = an.non_convergent;
  rc.anchors_slide = an.contact_held_by_sliding;
  // The file's own gate: accepted = load path && margin (&& not sliding).
  rc.load_path_ok = an.accepted || an.non_convergent || an.contact_held_by_sliding ||
                    an.margin_effective < rc.margin_required * (1.0 - 1e-12);
  rc.keep_clear_voxels = fb.keep_clear_voxels;
  // A Keep clear closed in on every side refuses too: nothing reaches it.
  fb.keep_clear_sealed = file_sealed_keep_clears(m, sg, clearance);
  rc.keep_clear_sealed = fb.keep_clear_sealed;
  rc.keep_clear_before = file_keep_clear_voxels(occ0, clearance, exclude);
  if (clearance != nullptr && clearance->size() == occ.size()) {
    const std::size_t nx = static_cast<std::size_t>(sg.nx), nxy = nx * static_cast<std::size_t>(sg.ny);
    for (std::size_t i = 0; i < occ.size(); ++i)
      if (occ[i] && !occ0[i] && (*clearance)[i] == MaskValue::FrozenVoid &&
          !(exclude != nullptr && (*exclude)[i] == MaskValue::FrozenSolid)) {
        const Vec3 c = sg.voxel_center(static_cast<int>(i % nx), static_cast<int>((i % nxy) / nx),
                                       static_cast<int>(i / nxy));
        rc.keep_clear_added += mesh_encloses(m, c) && !mesh_encloses(raw, c);
      }
  }
  fb.keep_clear_before = rc.keep_clear_before;
  fb.keep_clear_added = rc.keep_clear_added;
  // Only a piece the finishing ADDED refuses: the unfinished file's N bodies stay N.
  rc.pieces = fb.pieces > std::max(1, positive_volume_bodies(raw)) ? fb.pieces : 1;
  rc.loose_pieces = fb.loose_pieces;
  rc.loose_pieces_before = file_loose_pieces(sg, occ0);
  rc.thin_joints = fb.thin_joints;
  rc.thin_joints_before = wa0.non_manifold_edges + wa0.non_manifold_vertices;
  return rc;
}

VersionFinish finish_and_recheck(const MinimizePlasticVariant& v, const JobDescription& job,
                                 const std::string& job_dir, const VoxelGrid& sg, double iso,
                                 const StepModel* model, const RunFinish& fin,
                                 const DesignMask* clearance, double density_g_cm3,
                                 const MaterialLibrary& materials, const SettingsRules& rules,
                                 const std::string& check_dir, double margin_before,
                                 double margin_required, const StreamedFinish* pre = nullptr) {
  const auto t0 = std::chrono::steady_clock::now();
  VersionFinish out;
  const RunFinish safe = safe_finish(fin);
  TriangleMesh raw;
  // The finished FILE is re-checked as the solid it is: the job's own analysis, without
  // what the analyze path adds on top. A "grading" block would run the lattice-only
  // grading law over the file (and refuse a minimize_plastic job, whose demand
  // allowable is never set); the lattice companion is built from the unfinished shape.
  JobDescription file_job = job;
  file_job.grading.present = false;
  file_job.has_orientation_recheck = false;
  auto finish = [&](bool slim) -> const TriangleMesh& {
    if (slim && pre != nullptr) {  // made when the version streamed
      out.fb = pre->fb;
      out.mesh = pre->mesh;
      if (raw.triangles.empty()) raw = pre->raw;
      return out.mesh;
    }
    out.fb = FinishBlock{};
    out.mesh = variant_export_model_mesh(v, job.output, sg, iso, model, job.keep_regions,
                                         slim ? &fin : &safe, &out.fb,
                                         raw.triangles.empty() ? &raw : nullptr);
    return out.mesh;
  };
  auto check = [&](const TriangleMesh& m) -> std::string {
    std::error_code mk;
    std::filesystem::create_directories(check_dir, mk);
    const std::string stl = join_path(check_dir, "v.stl");
    write_stl_file(stl, m);
    try {
      out.analysis = analyze_job(file_job, job_dir, check_dir, materials, rules, stl, {});
    } catch (const std::exception& e) {
      const WrittenAudit w = audit_as_written(m);
      std::fprintf(stderr, "[finish] version vf %.2f: the finished file could not be re-checked: %s\n",
                   v.requested_volume_fraction, e.what());
      if (w.non_manifold_edges > 0 || w.boundary_edges > 0)
        return "After finishing, the file is not one clean solid (" +
               std::to_string(w.non_manifold_edges + w.boundary_edges) + " bad edge(s))";
      return "After finishing, the file could not be re-checked";
    }
    FinishBlock& fb = out.fb;
    fb.margin_before = margin_before;
    // Mass from the files themselves: the finished one, and the unfinished export.
    fb.mass_grams = density_g_cm3 * fb.volume_after_mm3 / 1000.0;
    fb.mass_before_grams = density_g_cm3 * fb.volume_before_mm3 / 1000.0;
    // TO rebuild stage 2 (ledger M-07; the maintainer: "Never the solid unless the
    // user set infill to 100%"): the grams he is shown are the grams printed at his
    // walls and infill. The file's own volume gives the solid grams, as above; the
    // share of it that is really printed comes from the re-check's wall-and-core
    // model of this same file (printed_mass.hpp). At 100 % infill the share is 1.
    if (to_stage2_on() && out.analysis.voxel_mass_solid_grams > 0.0 &&
        out.analysis.voxel_mass_grams > 0.0) {
      const double share = out.analysis.voxel_mass_grams / out.analysis.voxel_mass_solid_grams;
      std::fprintf(stderr,
                   "[finish] version vf %.2f: printed grams %.2f of %.2f solid (share %.3f at "
                   "the job's walls and infill)\n",
                   v.requested_volume_fraction, share * fb.mass_grams, fb.mass_grams, share);
      fb.mass_grams *= share;
      fb.mass_before_grams *= share;
    }
    return finish_verdict_reason(
        recheck_file(m, raw, sg, clearance, nullptr, out.analysis, margin_required, fb,
                     fin.part));
  };
  const FallbackOutcome o = finish_with_fallback(finish, check);
  if (o.fallback) {
    std::string r = o.fallback_reason;
    const std::string pre = "After finishing, ";
    if (r.rfind(pre, 0) == 0) r = "With the slim finish, " + r.substr(pre.size());
    out.fb.finish_fallback = true;
    out.fb.finish_fallback_reason = r;
  }
  out.refusal = o.refusal;
  out.fb.seconds =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  return out;
}

std::string export_variant_mesh(const MinimizePlasticVariant& variant,
                                const std::string& out_dir, const JobOutput& out,
                                const VoxelGrid& sg, double printed_iso = 0.5,
                                const StepModel* cad = nullptr,
                                const std::vector<KeepRegion>& keeps = {},
                                const RunFinish* fin = nullptr,
                                const TriangleMesh* finished = nullptr) {
  const std::string path = join_path(
      out_dir, mesh_file_name(out.mesh_prefix, variant.requested_volume_fraction,
                              out.mesh_format));
  const TriangleMesh model_mesh =
      finished != nullptr ? *finished
                          : variant_export_model_mesh(variant, out, sg, printed_iso, cad, keeps, fin);
  const std::optional<BuildFrameRotation> R = variant_bake_rotation(variant);
  TriangleMesh baked;
  // A rotated file is welded as written again (unchanged when nothing coincides).
  if (R) baked = fin != nullptr || finished != nullptr ? weld_as_written(rotate_mesh(model_mesh, *R))
                                                       : rotate_mesh(model_mesh, *R);
  const TriangleMesh& export_mesh = R ? baked : model_mesh;
  if (out.mesh_format == "3mf") {
#ifdef TOPOPT_HAVE_3MF
    write_3mf_file(path, export_mesh);
#else
    throw JobError("3MF support unavailable in this build");  // unreachable
#endif
  } else {
    write_stl_file(path, export_mesh);
  }
  return path;
}

// --- Lattice export (handoff 2026-07-28-lattice-generation-production) --------
// Emit a LATTICED companion to an accepted variant's solid mesh: the solid shell
// (variant.v3.mesh) unioned with an octet strut lattice filling the part's solid
// interior, STREAMED to disk so peak RSS stays flat in the output size. The union
// is written as an interpenetrating triangle soup — three fresh vertices per
// facet, exactly what the harness emitted and the PR 201 print certified — so the
// slicer's boolean union resolves the overlaps. Runs wherever run_job runs (the
// Mac worker's topopt-cli); the file lands in out_dir and is fetched on demand, so
// the iPad never holds the mesh.
struct LatticeExportOutcome {
  std::vector<std::string> paths;  // files written (STL and/or 3MF)
  LatticeGenStats stats;           // generator counts (identical across formats)
  // ★ Finding 8: a sheet's mesh, simplified (mesh_simplify.hpp). The deviations are
  // MEASURED on every written triangle: on the sheet's own surface, and at the cuts (kept
  // as contoured; under solid in a run). samples_past_floor = samples that cut a wall
  // below its bead (0 = none). The steps (the wall is graded per voxel, so it jumps at a
  // voxel's face): how many samples lie off their own band within reach of one, how far the
  // mesh sits from its own voxel's surface there, and what the contouring left outside the
  // step's band (kept as contoured; inward, a wall under its floor by that much).
  bool sheet_simplified = false;
  long long sheet_triangles_contoured = 0, sheet_triangles = 0;
  double sheet_max_deviation_mm = 0.0, sheet_cut_max_deviation_mm = 0.0;
  long long sheet_samples_past_floor = 0;
  double sheet_step_max_deviation_mm = 0.0, sheet_step_worst_outside_band_mm = 0.0;
  long long sheet_step_samples = 0, sheet_step_samples_outside_band = 0, sheet_samples = 0;
  // ★★ ORGANIC's POST-CLIP connectivity (OrganicGenStats): the connectedness of what
  // was WRITTEN, after the boundary clip trimmed and dropped spans. The tracer's own
  // number describes the lattice it traced; this one describes the file.
  // ★★ WHERE THE MILLIMETRES WENT. Live span length at each stage of the emission
  // pipeline, plus the grown length handed in. -1 in a stage means that pass DID NOT
  // RUN — it is not zero length, and differencing without checking is how an unrun
  // pass reads as having deleted everything.
  std::vector<double> organic_census_len_mm;
  std::vector<int> organic_census_components;
  int organic_support_components_before = -1;
  int organic_support_components_after = -1;
  long long organic_support_fragments_dropped = 0;
  double organic_support_fragment_length_mm = 0.0;
  long long organic_base_mat_stitches = 0;
  long long organic_base_mat_clusters = 0;
  long long organic_fill_mat_cells_outside_region = 0;
  // ★ spans that run over open air. The overhang fillet that used to flare them was
  // removed (it deposited blobs up to nine times the strut); the count remains so the
  // receipt still says how much of the lattice is unsupported.
  long long organic_unsupported_spans = 0;
  // (The shape-fit counters live on the variant result, not here: this struct had a
  // second set that nothing ever wrote and nothing ever read, shadowing the real ones.)
  // ★ synthetic stress for dead walls: what was laid in, so the receipt says it RAN
  SyntheticStressReport organic_synthetic;
  // ★ THE EMITTED SPANS, carried out so the STRUCTURAL CERTIFICATE can read the
  // geometry that ships. They are post-clip, post-prune, post-finish and
  // post-endpoint-fit -- the same spans lattice.emit_organic_spans writes.
  std::vector<OrganicSpan> organic_spans_out;
  double organic_census_grown_len_mm = 0.0;
  long long organic_emitted_components = 0;
  double organic_emitted_largest_fraction = 0.0;
  double organic_emitted_stranded_mm = 0.0;
  long long organic_floating_before = 0;
  long long organic_floating_after = 0;
  long long organic_repair_legs = 0;
  long long organic_repair_rounds = 0;
  long long organic_free_ends = 0;
  double organic_free_end_len = 0.0;
  long long organic_free_before = 0;
  long long organic_ties = 0;
  double organic_tie_len = 0.0;
  long long organic_free_unresolved = 0;
  long long organic_pruned = 0;
  double organic_pruned_len = 0.0;
  long long organic_prune_rounds = 0;
  long long organic_plate_contacts = 0;
  long long organic_net_landings = 0;
  long long organic_net_members = 0;
  double organic_net_length = 0.0;
  long long organic_net_joined = 0;
  long long organic_net_fallback = 0;
  long long organic_net_edge_landings = 0;
  long long organic_stranded_comps = 0;
  long long organic_stranded_spans = 0;
  double organic_stranded_len = 0.0;
  long long organic_nodes_merged = 0;
  long long organic_merge_clusters = 0;
  long long organic_merge_degenerate = 0;
  long long organic_net_pruned = 0;
  long long organic_net_deg1 = 0;
  long long organic_unsupported_found = 0;
  long long organic_unsupported_left = 0;
  long long organic_support_legs = 0;
  double organic_support_leg_len = 0.0;
  long long organic_support_rounds = 0;
  bool organic_support_rounds_converged = false;
  long long organic_fp_rounds = 0;
  bool organic_fp_converged = false;
  long long organic_mutations = 0;
  long long organic_support_impossible = 0;
  long long organic_unsupported_cells = 0;
  double organic_unsupported_mm3 = 0.0;
  long long organic_support_diagonal = 0;
  long long organic_support_cut = 0;
  long long organic_support_cleanup = 0;
  double organic_base_trim_z = 0.0;
  long long organic_base_trim_cut = 0;
  long long organic_base_trim_clipped = 0;
  double organic_base_trim_len = 0.0;
  bool organic_base_trim_found = false;
  long long organic_base_mat_struts = 0;
  long long organic_base_mat_touchdowns = 0;
  long long organic_slenderness_violating = 0;
  long long organic_slenderness_propped = 0;
  long long organic_slenderness_impossible = 0;
  long long organic_slenderness_props = 0;
  double organic_cantilever_reach = 0.0;
  long long organic_cantilever_islands = 0;
  // ── ★★ GROWTH TELEMETRY (task PR-353 amendment §1) ──────────────────────────
  // `growth_ran` distinguishes "growth measured zero" from "growth never ran": a
  // traced run reports false and every counter below is meaningless, which is the
  // same rule this receipt already applies to shape-fit reporting. Without it a run
  // that truncated at the tip budget is indistinguishable from one that finished.
  // ★★ CARRY THE STRUCT, NOT A FLATTENED COPY OF IT. Twelve mirrored fields meant a
  // thirteenth counter had to be added in FIVE places, one of which was a hand-written
  // block with no compiler enforcement — precisely the shape that let the growth
  // counters be filled and never read in the first place. Holding the generator's own
  // struct means adding a counter is one line in OrganicGenStats and nothing else.
  OrganicGenStats growth;
  bool growth_ran = false;
  long long organic_arched_spans = 0;
  double organic_arch_rise = 0.0;
  // (organic_filleted / organic_fillet_radius are gone with the overhang fillet they
  // counted. Nothing wrote them and nothing serialised them; the live measurement for
  // spans over air is `unsupported_spans`.)
  double organic_base_mat_len = 0.0;
  double organic_base_mat_z = 0.0;
  long long organic_fill_cells = 0;
  long long organic_fill_struts = 0;
  double organic_fill_len = 0.0;
  long long organic_branch_seeds = 0;
  long long organic_branch_merges = 0;
  long long organic_branch_trunks = 0;
  long long organic_branch_anchored = 0;
  double organic_branch_len = 0.0;
  double organic_support_cut_len = 0.0;
  long long organic_unsupported_found_cells = 0;
  double organic_support_layer_mm = 0.0;
  bool organic_support_grid_too_large = false;
  // The welded single-body file, when one was asked for.
  bool welded = false;
  OrganicWeldStats weld;
  long long region_voxels = 0;     // SOLID voxels inside the latticed cells
  // SOLID COMPANION (task lattice-page-core-hookup, stages 1+4). When roles or
  // grading leave printed voxels UN-latticed (exclude regions, everything
  // outside the include union, the grading law's too-thin-stays-solid
  // fallback), the exported file must honour "kept solid": those voxels are
  // emitted as a closed marching-cubes body into the same interpenetrating
  // soup, and their volume is accounted SEPARATELY from interior/skin/rim
  // (H1c; voxel basis, count × spacing³, matching the mass accounting).
  // Emitted ONLY when roles/grading are in play — a legacy uniform whole-part
  // job writes byte-identical files.
  bool solid_companion = false;
  long long solid_region_voxels = 0;      // printed, non-keep-out, not latticed
  double solid_region_volume_mm3 = 0.0;   // voxel basis: count × spacing³
  std::uint64_t solid_region_triangles = 0;
  // ★ THE SOLID ON THE PART'S OWN SURFACE (reviewer's ruling 11-09, the rim coupon's
  // SOLID). Asked when the part itself is latticed: the companion is the part's own mesh
  // intersected with the solid zone, so its outer faces ARE the part's faces. Refused
  // (the voxel body kept, and said why) only when the boolean cannot be made.
  bool solid_on_part_surface_asked = false;
  bool solid_on_part_surface = false;
  std::string solid_on_part_surface_refused;

  // ★ THE NO-PROTRUSION INVARIANT, MEASURED ON WHAT WAS WRITTEN (task
  // 2026-08-08-strut-clip-matches-shell, bar R3). Every vertex of every LATTICE
  // triangle — struts, nodes, anchor balls, skin, rim; NOT the shell's own
  // triangles and NOT the solid companion's — is evaluated against the exact
  // signed distance to the shell in the same file, and the largest amount by
  // which any of them lies OUTSIDE it is recorded here.
  //
  // MEASURED, not derived. The clip's Lipschitz certificate proves containment
  // for the spans it certified, but the generator also has a fast path that
  // skips the clip entirely (lattice_gen.cpp:344), a node/anchor ball pass, and
  // a skin pass with its own relaxed predicate — so "the clip is correct"
  // and "nothing was written outside the shell" are different claims. This is
  // the second one, and it is what the maintainer can actually see in a slicer.
  //
  // The measurement runs on the STREAM, so peak RSS stays flat in output size
  // (bar B8): the sink wrapper holds one running maximum, and a per-voxel
  // lower-bound field keeps deep-interior vertices to an array lookup.
  bool protrusion_measured = false;
  // THE ONLY GEOMETRY ALLOWED OUTSIDE THE SHELL, in mm — the clip's own crossing
  // tolerance, PLUS the freeform skin's declared sag budget when that pass ran.
  // The freeform skin deliberately buys `kLatticeSkinSagBudgetMm` of overshoot
  // against the base surface (lattice_gen.hpp says why), so a run that armed it
  // is allowed exactly that and not a micron more; every other run is allowed
  // nothing. Recorded so the receipt states the bar it was judged against rather
  // than leaving the reader to infer it.
  double protrusion_allowance_mm = 0.0;
  // WHICH SURFACE THE STRUTS WERE CLIPPED AGAINST, read from the boundary
  // itself rather than written as a constant beside it. The whole defect was two
  // surfaces that everyone believed were one, so a receipt that ASSERTS the
  // answer instead of reporting it would be repeating the mistake in prose.
  bool clipped_against_shell = false;
  double max_protrusion_mm = 0.0;   // largest distance OUTSIDE the shell
  long long protruding_vertices = 0;  // triangle CORNERS strictly outside it
  // ★ what the corner count could not say: how many DISTINCT points escaped, and how
  // many elements they belong to. One vertex of valence five reads as five corners.
  long long protruding_unique_vertices = 0;
  long long protruding_elements = 0;
  long long measured_vertices = 0;    // lattice vertices examined
  Vec3 worst_protrusion_at{};         // where the worst one is, model frame
  // WHICH GENERATOR PASS emitted the worst one. The generator has five of them
  // (interior struts, node balls, anchor balls, skin, rim) and they reach the
  // boundary through DIFFERENT predicates — the struts through a certified clip,
  // the node balls through a single sd >= r test, the freeform skin through a
  // deliberately relaxed one. A refusal that says only "0.8 mm somewhere" sends
  // the next reader back to the whole file; naming the pass is the difference
  // between a diagnosis and a puzzle.
  std::string worst_protrusion_pass;
  // ★ THE RIM ON A REAL PART (ruling 11-08 (A)): the sharp edges found on the shipped
  // surface, which chains took the rim, and what was laid. `mesh_rim_ran` is false on every
  // run that asks for no rim, and then no receipt changes.
  bool mesh_rim_ran = false;
  FeatureEdgeStats rim_edges;
  long long rim_chains_other_skin = 0;   // chains whose midpoint zone asks for another skin
  double rim_line_width_mm = 0.0;
  std::string rim_rides;                 // which clean surface the chains came from
  LatticeMeshRimReport rim;
};

// ── ★★ THE RECEIPT A REFUSED RUN LEAVES BEHIND ────────────────────────────────
// A guard that throws before run_info.json is written destroys the very measurements
// needed to diagnose it. The organic census is complete by the time the export guards
// run, so this writes it out, marked refused and with the reason named, next to the
// run's other outputs. It is a DIAGNOSTIC receipt: it never claims the run succeeded,
// and nothing downstream may read it as a certificate.
void write_refusal_receipt(const std::string& out_dir, const char* reason,
                           const LatticeExportOutcome& oc) {
  const std::string path = join_path(out_dir, "refusal_receipt.json");
  std::ofstream f(path);
  if (!f) return;
  f << "{\n";
  f << "  \"refused\": true,\n";
  f << "  \"reason\": \"" << reason << "\",\n";
  f << "  \"note\": \"DIAGNOSTIC ONLY. This run was REFUSED and wrote no "
       "certified geometry. These are the measurements taken before the refusal, "
       "so the refusal can be diagnosed without re-running with a guard disabled. "
       "Never read this as a certificate.\",\n";
  f << "  \"max_protrusion_mm\": " << oc.max_protrusion_mm << ",\n";
  f << "  \"protrusion_allowance_mm\": " << oc.protrusion_allowance_mm << ",\n";
  f << "  \"protruding_unique_vertices\": " << oc.protruding_unique_vertices << ",\n";
  f << "  \"protruding_elements\": " << oc.protruding_elements << ",\n";
  f << "  \"protruding_triangle_corners\": " << oc.protruding_vertices << ",\n";
  f << "  \"organic_support_rounds_converged\": "
    << (oc.organic_support_rounds_converged ? "true" : "false") << ",\n";
  f << "  \"organic_support_legs\": " << oc.organic_support_legs << ",\n";
  f << "  \"organic_unsupported_cells\": " << oc.organic_unsupported_cells << ",\n";
  f << "  \"organic_emitted_components\": " << oc.organic_emitted_components << "\n";
  f << "}\n";
}


std::string lattice_base_name(const std::string& prefix, double requested_vf) {
  char digits[8];
  std::snprintf(digits, sizeof(digits), "%03d",
                static_cast<int>(std::lround(requested_vf * 100.0)));
  return prefix + "_" + digits + "_lattice";
}

// Forward declarations of two small JSON/vec helpers defined lower in this TU, so
// the lattice certification helpers below (which precede them) can use them.
Vec3 normalized(const Vec3& v);
std::string json_num(double v);
std::string json_str(const std::string& s);
double mesh_enclosed_volume_mm3(const TriangleMesh& m);

// Shared lattice OCCUPANCY + BOUNDARY (lattice certification E2E, handoff
// 2026-07-29-lattice-certification-e2e; boundary finish, handoff
// 2026-07-29-lattice-boundary-finish). The ONE predicate is now a
// LatticeBoundary: the design's solid voxel set (physical_density >= 0.5, the
// marching-cubes iso) as the base region, minus every declared clearance
// keep-out — the EXISTING resolved ClearanceGeometry, never a second keep-out
// concept. BOTH the exported geometry (generate_lattice activates cells by
// OVERLAP with it and clips every strut solid against it) and the certification
// posture (lattice_certification_mask) are built from THIS ONE object, so the
// object the gate certifies and the file the slicer opens are the SAME region
// by construction — extended from the region to the boundary (bar B7).
// `sg`/`dens` must outlive the returned boundary.
// The job's lattice ROLE regions (task lattice-page-core-hookup stage 1),
// resolved through the SAME manual-primitive machinery a hand-placed clearance
// uses (resolve_clearance_manual) with ZERO margins — the primitive IS the
// region, there is no keep-out growth. No second geometry concept.
struct LatticeRoleRegions {
  std::vector<ClearanceGeometry> includes;
  std::vector<ClearanceGeometry> excludes;
  // ★ E2.2 + E3: lattice.whole_part's include regions, resolved like includes and
  // numbered 1.. in their own order. They limit nothing; they only say which voxels
  // take a region's own grading.
  std::vector<ClearanceGeometry> carriers;
};

// ★ RESOLVE ONE face REGION INTO A VOXEL MASK (task 2026-08-15-lattice-regions).
//
// THE VOLUME IS THE PROTECTION'S VOLUME. `region_member_voxels` + `cut_voxels`
// at `region_depth_layers(depth_mm, spacing)` layers is EXACTLY what
// `mask_step_region` walks for a protection at the same depth — same primitive,
// same rounding, same voxels. That identity is bar R5, and it is structural
// here rather than agreed: both call the same two functions with the same
// arguments.
//
// The mask carries the grid it was built on, so every later membership test
// converts the query point into THIS lattice regardless of which grid the caller
// is walking (an expanded design-box grid, the certification grid, the part
// grid).
std::shared_ptr<const ClearanceVoxelMask> region_lattice_mask(
    const VoxelGrid& grid, const StepModel& model,
    const ResolvedFaceRegion& region, double depth_mm) {
  auto m = std::make_shared<ClearanceVoxelMask>();
  m->nx = grid.nx;
  m->ny = grid.ny;
  m->nz = grid.nz;
  m->spacing = grid.spacing;
  m->origin = grid.origin;
  m->inside.assign(grid.voxel_count(), 0);
  const int layers = region_depth_layers(depth_mm, grid.spacing);
  if (to_stage1_on()) {
    // TO rebuild stage 1: the protection is frozen by true distance in mm, so the
    // lattice region is too, through the SAME function (mask_region_by_stage), and
    // bar R5 stays structural. The voxel path below is untouched.
    DesignMask frozen = make_active_mask(grid);
    mask_region_by_stage(grid, model, region, MaskValue::FrozenSolid, layers, depth_mm,
                         frozen);
    for (std::size_t idx = 0; idx < frozen.size() && idx < m->inside.size(); ++idx)
      if (frozen[idx] == MaskValue::FrozenSolid) m->inside[idx] = 1;
    return m;
  }
  const std::vector<int> members =
      region_member_voxels(grid, model, region, layers);
  for (int idx : cut_voxels(grid, members, region.cuts))
    if (idx >= 0 && static_cast<std::size_t>(idx) < m->inside.size())
      m->inside[static_cast<std::size_t>(idx)] = 1;
  return m;
}

// `model` / `grid` are needed ONLY by `kind == "region"`; a job with no
// region-backed lattice region may pass nullptr and takes a byte-identical path.
// A region-backed one with nothing to resolve against REFUSES rather than
// resolving to an empty mask — an empty include region silently latticing
// NOTHING is the failure this whole track exists to stop seeing.
LatticeRoleRegions lattice_role_regions_from_job(const JobDescription& job,
                                                 const StepModel* model,
                                                 const VoxelGrid* grid) {
  LatticeRoleRegions rr;
  std::vector<ResolvedFaceRegion> resolved;
  bool resolved_done = false;
  // ★ K6: every DECLARED include is numbered, including one that fails to resolve, so
  // the id survives the skip below.
  int declared_include = 0;
  for (const JobLatticeRegion& r : job.lattice.regions) {
    if (r.role == "include") ++declared_include;
    if (r.kind == "region") {
      if (model == nullptr || grid == nullptr)
        throw JobError(
            "lattice region_id " + std::to_string(r.region_id) +
            ": a \"region\" lattice region needs the imported model and the "
            "run's grid to resolve its voxels, and this call site has neither. "
            "This is a wiring defect, not a job error.");
      if (!resolved_done) {
        resolved = resolve_face_regions(*model, job.loads.face_regions);
        resolved_done = true;
      }
      const ResolvedFaceRegion* found = nullptr;
      for (const ResolvedFaceRegion& rr2 : resolved)
        if (rr2.id == r.region_id) { found = &rr2; break; }
      if (found == nullptr)
        throw JobError(
            "a \"region\" lattice region names region_id " +
            std::to_string(r.region_id) +
            ", which is not declared in \"loads.face_regions\". A region must "
            "be declared once and referred to by id.");
      ClearanceGeometry g;
      g.valid = true;
      g.kind = ClearanceKind::Face;  // unread while `mask` is set; a stable default
      g.mask = region_lattice_mask(*grid, *model, *found, r.depth_mm);
      if (g.mask->set_count() == 0)
        throw JobError(
            "lattice region " + std::to_string(r.region_id) +
            (found->name.empty() ? "" : " \"" + found->name + "\"") +
            " selects NO solid voxels at " + std::to_string(r.depth_mm) +
            " mm depth on this grid (spacing " +
            std::to_string(grid->spacing) +
            " mm). It would lattice nothing and report success; it is refused "
            "instead. Use a coarser depth, a finer resolution, or a region that "
            "reaches part material.");
      g.declared_region_id = r.role == "include" ? declared_include : 0;
    (r.role == "include" ? rr.includes : rr.excludes).push_back(std::move(g));
      continue;
    }
    ManualClearanceGeometry mg;
    ClearanceParams p;  // all margins zero: the primitive is the region
    if (r.kind == "bolt") {
      mg.kind = ClearanceKind::Bolt;
      p.kind = ClearanceKind::Bolt;
      mg.axis_point = r.axis_point;
      mg.axis_dir = r.axis_dir;
      mg.radius_mm = r.radius_mm;
      mg.half_length_mm = r.half_length_mm;
    } else {  // "face" — a bounded slab; the region's own depth is the extent
      mg.kind = ClearanceKind::Face;
      p.kind = ClearanceKind::Face;
      p.slab_depth_mm = r.depth_mm;
      mg.origin = r.origin;
      mg.normal = r.normal;
      mg.half_u_mm = r.half_u_mm;
      mg.half_w_mm = r.half_w_mm;
      mg.outline_uv = r.outline_uv;
      mg.frame_u = r.frame_u;      // zero unless the job stated them
      mg.frame_w = r.frame_w;
    }
    ClearanceGeometry g = resolve_clearance_manual(mg, p);
    // ★ K6, COMPLETED (#354 reading 3952c411, 2026-10-10). The declared id was set on the
    // `kind == "region"` branch ONLY, and this path -- the manual face/bolt path, which
    // carries every region the app plans -- pushed its geometry with the id still 0. So
    // `stepped_region_owner` fell back to the POSITION for every FACE include, which is
    // precisely the defect K6 exists to fix: the built vector is compacted by the skip
    // below, and the app numbers includes without it. Set here, before that skip, so no
    // later branch can push an unnumbered geometry.
    g.declared_region_id = r.role == "include" ? declared_include : 0;
    // ★ A STATED FRAME THAT DISAGREES WITH plane_basis() IS A REFUSAL, and it is
    // raised HERE because this is where the face can be named. Skipping the region
    // would drop it silently -- the outline would be gone and the wall unlatticed,
    // which reads as a modelling choice rather than an error.
    if (g.frame_conflict)
      throw JobError(
          "lattice region " + std::to_string(&r - &job.lattice.regions[0] + 1) +
          " (face " + std::to_string(r.face_id) + ") states \"frame_u\"/\"frame_w\" "
          "that do not match the in-plane basis core derives from its normal. The two "
          "have agreed until now by coincidence of construction, so a disagreement "
          "means one side has changed its convention: the outline would be read in one "
          "frame and everything else in another, and a mirrored outline has the same "
          "AREA as a correct one, so nothing downstream would catch it. Send axes that "
          "match the normal, or omit them and core will derive the basis as before.");
    if (!g.valid) continue;  // degenerate → the rasterizer's safe no-op
                             // (parse_job already refused zero extents)
    (r.role == "include" ? rr.includes : rr.excludes).push_back(g);
  }
  // ── ★ K6: EVERY INCLUDE CARRIES ITS DECLARED NUMBER, CHECKED HERE ────────────
  // This is the guard that would have caught the defect #354 found by reading. The id was
  // set on the `kind == "region"` branch only, so the manual face/bolt path -- the one
  // carrying every region the app plans -- pushed geometries numbered 0, and
  // `stepped_region_owner` silently fell back to the POSITION, which is the compaction bug
  // K6 exists to remove. A unit test on the function could not see it, because the test
  // built its geometries by hand and never came through this builder.
  //
  // A branch that forgets to number is now a refusal rather than a silent fallback. It is
  // a can't-happen today -- an id of 0 would mean this loop pushed an include it never
  // counted -- and it still refuses, by name, because the failure it replaces was invisible.
  for (std::size_t i = 0; i < rr.includes.size(); ++i)
    if (rr.includes[i].declared_region_id <= 0)
      throw JobError(
          "internal: include region at position " + std::to_string(i + 1) +
          " was built without its declared region number. Core resolves which region owns "
          "a shared voxel by that number (stepped_region_owner), and the built list is "
          "compacted when an include fails to resolve, so a position is not a number. "
          "Refusing rather than answering with the position, which is the defect this "
          "check exists to prevent.");
  // ★ E2.2 + E3: the whole-part regions, through this same resolver.
  if (!job.lattice.whole_part_includes.empty()) {
    JobDescription carried = job;
    carried.lattice.regions = job.lattice.whole_part_includes;
    carried.lattice.whole_part_includes.clear();
    rr.carriers = lattice_role_regions_from_job(carried, model, grid).includes;
  }
  return rr;
}

// Copy the grading law's CELL-SIZE plan into the run_info record — ONE filler for
// both call sites (analyze_job and run_job), so the two receipts can never disagree
// about what the cell law did (handoff 2026-08-01-lattice-cell-size-sweep).
// A +inf member width is the "thicker than the EDT cap" sentinel; it is carried as a
// negative here and serialized as JSON null, matching the scalar fields above.
void fill_grading_cell_plan(RunInfo& gi, const GradedField& gf) {
  const CellSizePlan& P = gf.cell_plan;
  gi.grading_cell_mode = cell_size_mode_name(gf.cell_mode);
  gi.grading_cell_base_mm = P.base_cell_mm;
  gi.grading_cell_max_level = P.max_level;
  gi.grading_cell_latticed_cells = P.latticed_cells;
  gi.grading_cells_raised_to_floor = P.cells_raised_to_floor;
  gi.grading_cells_dropped_unprintable = P.cells_dropped_unprintable;
  gi.grading_cells_dropped_by_window = P.cells_dropped_by_window;  // ★ E3
  gi.grading_cells_split_by_balance = P.cells_split_by_balance;
  gi.grading_cell_any_out_of_regime = P.any_out_of_regime;
  gi.grading_cell_levels.clear();
  for (const CellLevelReport& r : P.levels) {
    RunInfo::GradingCellLevel L;
    L.level = r.level;
    L.cell_size_mm = r.cell_size_mm;
    L.cells = r.cells;
    L.voxels = r.voxels;
    L.min_member_width_mm =
        std::isfinite(r.min_member_width_mm) ? r.min_member_width_mm : -1.0;
    L.min_cells_per_member =
        std::isfinite(r.min_cells_per_member) ? r.min_cells_per_member : -1.0;
    L.min_strut_diameter_mm =
        std::isfinite(r.min_strut_diameter_mm) ? r.min_strut_diameter_mm : 0.0;
    L.max_strut_diameter_mm = r.max_strut_diameter_mm;
    L.out_of_regime = r.out_of_regime;
    L.any_strut_below_min = r.any_strut_below_min;
    gi.grading_cell_levels.push_back(L);
  }
}

// THE PRINTED-SET THRESHOLD this run reads designs at (task multiscale-lattice-to).
// 0.5 — the M3.5 iso — on every classic run, so every existing path is byte-for-byte
// unchanged; below the certified band's floor on a MULTISCALE run, where a voxel at
// density 0.30 is a real 30%-dense lattice cell and not a half-empty solid voxel.
// ONE resolver, read by the mesh export, the lattice candidate set, the boundary
// base and the grading law, so the shape the file carries and the shape the gate
// certified cannot disagree. See lattice_material.hpp for the derivation.
double run_printed_iso(const MinimizePlasticOptions& o) {
  return o.multiscale_lattice ? multiscale_printed_iso(o.multiscale_topology) : 0.5;
}

// THE MULTISCALE REGION (task multiscale-lattice-to) — which voxels the OPTIMIZER
// treats as lattice material. This is the DESIGN-INDEPENDENT half of
// lattice_certification_mask: the same keep-out and role membership tests, on the
// same resolved ClearanceGeometry objects, with the density-dependent terms (the
// printed-iso test and the cell-overlap proof) deliberately left out.
//
// WHY IT MUST BE DESIGN-INDEPENDENT: this mask decides each voxel's MATERIAL LAW
// for the whole run. If it were a function of the evolving density it would flip
// voxels between the cubic and the penalized isotropic law from iteration to
// iteration, which is a discontinuous objective and a guaranteed oscillation. The
// role regions and keep-outs are pure geometry, so this is well-defined before the
// first solve and is resolved exactly once.
//
// The consequence is stated rather than hidden: a voxel in the region that the
// certification mask later drops (its cell could not be proven to overlap, or the
// grading law left its member solid) was optimized as lattice and will be printed
// SOLID — which is CONSERVATIVE (solid is stiffer than the lattice the optimizer
// assumed) and is exactly the direction the accept gate can absorb. The receipts
// report both counts so the difference is visible.
std::vector<char> multiscale_region_mask(
    const VoxelGrid& sg, const std::vector<ClearanceGeometry>& kos,
    const LatticeRoleRegions& roles) {
  LatticeBoundary members;
  for (const ClearanceGeometry& g : kos)
    members.add_keep_out(g, g.kind == ClearanceKind::Bolt);
  for (const ClearanceGeometry& g : roles.includes) members.add_include_region(g);
  for (const ClearanceGeometry& g : roles.excludes) members.add_exclude_region(g);
  std::vector<char> mask(sg.voxel_count(), 0);
  for (int k = 0; k < sg.nz; ++k)
    for (int j = 0; j < sg.ny; ++j)
      for (int i = 0; i < sg.nx; ++i) {
        if (!sg.solid(i, j, k)) continue;
        const Vec3 c{sg.origin.x + (i + 0.5) * sg.spacing,
                     sg.origin.y + (j + 0.5) * sg.spacing,
                     sg.origin.z + (k + 0.5) * sg.spacing};
        // PRECEDENCE, identical to lattice_certification_mask: clearance beats
        // both roles; exclude beats include.
        if (members.in_keep_out(c, 0.0)) continue;
        if (members.in_exclude_region(c, 0.0)) continue;
        if (members.has_include_regions() && !members.in_include_region(c, 0.0))
          continue;
        mask[sg.index(i, j, k)] = 1;
      }
  return mask;
}


// ── FIT MODE (task 2026-08-05-lattice-cell-fit-mode) ──────────────────────────────

// ★ THE ONE PLACE `"auto"` IS RESOLVED (bar S4). Every caller that turns the job's
// cell_mode string into a CellSizeMode goes through here, so the constant that decides
// what `auto` means is read once and cannot be applied on one path and missed on
// another. `false` for an unknown name, exactly like cell_size_mode_from_name.
bool resolve_cell_mode(const std::string& name, CellSizeMode& out) {
  if (!cell_size_mode_from_name(name.c_str(), out)) return false;
  if (out == CellSizeMode::Auto && production_lattice_auto_is_fit())
    out = CellSizeMode::Fit;
  return true;
}

// The region's THINNEST declared dimension — the one that bounds how many cells can
// lie across the latticed body. Spelled ONCE: the pre-flight and the fit derivation
// must measure the same thing or they describe different jobs.
double lattice_region_thinnest_extent_mm(const JobLatticeRegion& r) {
  return r.kind == "bolt"
             ? std::min(2.0 * r.radius_mm, 2.0 * r.half_length_mm)
             : std::min(r.depth_mm,
                        std::min(2.0 * r.half_u_mm, 2.0 * r.half_w_mm));
}

// ★ THE SAME QUESTION, ASKED OF A VOXEL SET (task 2026-08-15-lattice-regions
// §1c). The analytic version above reads the region's thinnest DECLARED
// dimension. A face region declares no dimensions — it is a set — so the
// thickness has to be measured.
//
// IT IS NOT A SECOND MEASUREMENT. `local_member_thickness_mm` (voxel.hpp, PR
// 206) is the Hildebrand inscribed-sphere thickness already used by the
// width-aware knockdown gate and by the grading law's cells-per-member test:
// tau(v) is the diameter of the largest ball that fits inside the set and
// contains v. Run over a synthetic density that is 1 inside the region and 0
// outside, it measures the REGION's own local thickness — exactly what "the
// thinnest dimension of this volume" means, and by the same definition the
// grading law compares a cell against. Reused, not re-derived, as §1c asks.
//

// What FIT derived for ONE declared include region.
struct FitRegionCell {
  std::size_t job_region_index = 0;   // index into job.lattice.regions
  // ★ The density the derivation WOULD have chosen, kept alongside the one in
  // force, so a receipt can show both and the app can show the valid range
  // (§2d): [derived, rho_max] is exactly the set of densities that print at
  // this region's cell.
  double derived_relative_density = 0.0;
  double stated_relative_density = 0.0;  // 0 = none stated
  double extent_mm = 0.0;             // the thinnest declared dimension
  bool feasible = false;              // a printable AND percolating pair exists
  double cell_mm = 0.0;               // the derived cell (0 when infeasible)
  double relative_density = 0.0;      // the lightest band density printing at it
  double strut_mm = 0.0;
  double cells_per_member = 0.0;      // extent / cell
  bool out_of_regime = false;         // under the ACCURACY floor: buildable, uncertified
  double min_printable_cell_mm = 0.0; // w / phi(rho_max) — region-independent
  double min_width_certifiable_mm = 0.0;
  double min_width_buildable_mm = 0.0;
};

// ★ THE DERIVATION, PER DECLARED INCLUDE REGION. The law, in one line:
//
//     cell = max(extent / N*, the finest printable cell)
//
// N* cells across where the region can hold them (which is the LIGHTEST certified
// lattice for that member — exactly the coarse end lattice_derive_cell_for_member
// reports), and the finest printable cell where it cannot, because that is the cell
// with the MOST cells across and therefore the least inaccuracy accepted. Both ends
// come from lattice_derive_cell_for_member; nothing is invented here.
//
// The returned vector is in the SAME ORDER as LatticeRoleRegions::includes — it
// mirrors that resolver's own filtering — so a 1-based region id from the grading
// call site indexes it directly. The call sites assert the two sizes agree rather
// than trusting the mirror.
// The derivation itself, shared by the analytic and the region-backed branches
// of fit_region_cells so the two cannot describe different laws. `f.extent_mm`
// must already be set — that is the ONLY thing the two branches derive
// differently (declared half-extents vs a measured voxel-set thickness).
// ★ THE STATED DENSITY ENTERS HERE, AT THE DENSITY STEP, AND THE CELL DOES NOT
// MOVE (task 2026-08-16-per-sector-density-override §1c).
//
// The derived chain is extent -> cell = max(extent/N*, finest printable) ->
// rho = the LIGHTEST density whose strut still prints at that cell -> strut.
// A stated rho replaces the third step only. The consequences, both measured
// (evidence r0_density_range.txt):
//
//   * the strut becomes cell * phi(rho) and RISES with rho, so the region stays
//     printable and stays at exactly N* cells per member — it keeps certifying;
//   * a rho BELOW the derived one implies a strut under the profile's bead and
//     is REFUSED with the number. It is refusable rather than clampable because
//     the derived density IS the floor of the valid range at a fixed cell.
//
// ★ WHAT RE-DERIVING THE CELL WOULD HAVE DONE (cell = w / phi(rho)): the strut
// would be pinned at exactly the bead width for EVERY density, so nothing could
// ever refuse — but cells-per-member would fall with rho, and on his part a
// stated 0.25 against a 6.8211 mm body gives 3.52 cells per member, i.e. the
// region silently stops certifying. Both readings are honest; this one keeps
// certification and refuses what it cannot do, and the other trades
// certification away without the user asking. The full table for both is in
// r0_density_range.txt.
void fill_fit_region_cell(FitRegionCell& f, LatticeTopology topo,
                          double min_extrudable_width_mm, double n_star,
                          double stated_density = 0.0,
                          // ★ D1: the job's density cap. Fit's cell floor and its derived
                          // density both hang off the smallest printable cell, and that is
                          // the capped one -- `fit.min_printable_cell_mm` was the capped
                          // number while the per-region receipt printed the uncapped one.
                          double max_relative_density = 0.0) {
  const LatticeCellDerivation d = lattice_derive_cell_for_member(
      topo, f.extent_mm, min_extrudable_width_mm, 0.0, max_relative_density);
  f.min_printable_cell_mm = d.min_printable_cell_mm;
  f.min_width_certifiable_mm = d.min_member_width_certifiable_mm;
  f.min_width_buildable_mm = d.min_member_width_buildable_mm;
  // FEASIBLE means a pair exists that PRINTS and PERCOLATES. The accuracy floor
  // is not part of this test — a region that clears percolation but not accuracy
  // is buildable and uncertifiable, which is a verdict, not a refusal.
  f.feasible = d.feasible_percolation;
  if (!f.feasible) return;
  f.cell_mm = std::max(f.extent_mm / n_star, d.min_printable_cell_mm);
  const double rho = lattice_min_density_for_strut(
      topo, f.cell_mm, min_extrudable_width_mm, max_relative_density);
  // ★ D1: when nothing in the band prints at this cell the fallback is the densest the
  // JOB allows, not the band's top -- reporting a density the job forbids is the same
  // defect one line up.
  const double band_top_allowed =
      (std::isfinite(max_relative_density) && max_relative_density > 0.0)
          ? std::min(lattice_rho_max(topo), max_relative_density)
          : lattice_rho_max(topo);
  f.derived_relative_density = rho >= 0.0 ? rho : band_top_allowed;
  f.stated_relative_density = stated_density;
  f.relative_density =
      stated_density > 0.0 ? stated_density : f.derived_relative_density;
  f.strut_mm = lattice_strut_diameter_mm(topo, f.relative_density, f.cell_mm);
  f.cells_per_member = f.extent_mm / f.cell_mm;
  f.out_of_regime = f.cells_per_member < n_star;
}

// ★ `roles` / `grid` are needed ONLY to price a `kind == "region"` include: its
// extent is MEASURED from its voxel mask (region_thinnest_extent_mm) rather than
// read off declared half-extents. Both default to nullptr, so every existing
// call site is unchanged and an all-analytic job takes the identical path.
//
// The extent is measured on the MASK's own grid, so no grid is passed here.
//
// A region-backed include with no `roles` supplied is DROPPED from this vector,
// which would silently break the index mirror `includes` relies on — so the
// call sites that can see a region kind pass them, and the mirror assertion at
// each call site is what catches it if one does not.
std::vector<FitRegionCell> fit_region_cells(const JobDescription& job,
                                            LatticeTopology topo,
                                            double min_extrudable_width_mm,
                                            const LatticeRoleRegions* roles = nullptr) {
  std::vector<FitRegionCell> out;
  if (!(min_extrudable_width_mm > 0.0)) return out;
  const double n_star = lattice_cells_per_member_min(topo);
  std::size_t include_index = 0;  // mirrors LatticeRoleRegions::includes order
  for (std::size_t ri = 0; ri < job.lattice.regions.size(); ++ri) {
    const JobLatticeRegion& r = job.lattice.regions[ri];
    if (r.role != "include") continue;
    if (r.kind == "region") {
      // The mask was resolved once by lattice_role_regions_from_job; its extent
      // is measured, not declared.
      if (roles == nullptr || include_index >= roles->includes.size() ||
          !roles->includes[include_index].mask)
        continue;
      FitRegionCell f;
      f.job_region_index = ri;
      f.extent_mm =
          region_thinnest_extent_mm(*roles->includes[include_index].mask);
      fill_fit_region_cell(f, topo, min_extrudable_width_mm, n_star,
                           r.relative_density,
                                                                                                job.grading.max_relative_density);
      out.push_back(f);
      ++include_index;
      continue;
    }
    // MIRRORS lattice_role_regions_from_job's validity filter, so the indices line
    // up. A degenerate region is dropped there and must be dropped here too.
    ManualClearanceGeometry mg;
    ClearanceParams p;
    if (r.kind == "bolt") {
      mg.kind = ClearanceKind::Bolt;
      p.kind = ClearanceKind::Bolt;
      mg.axis_point = r.axis_point;
      mg.axis_dir = r.axis_dir;
      mg.radius_mm = r.radius_mm;
      mg.half_length_mm = r.half_length_mm;
    } else {
      mg.kind = ClearanceKind::Face;
      p.kind = ClearanceKind::Face;
      p.slab_depth_mm = r.depth_mm;
      mg.origin = r.origin;
      mg.normal = r.normal;
      mg.half_u_mm = r.half_u_mm;
      mg.half_w_mm = r.half_w_mm;
      mg.outline_uv = r.outline_uv;
      mg.frame_u = r.frame_u;      // same geometry as the mask path sees
      mg.frame_w = r.frame_w;
    }
    if (!resolve_clearance_manual(mg, p).valid) continue;
    ++include_index;

    FitRegionCell f;
    f.job_region_index = ri;
    f.extent_mm = lattice_region_thinnest_extent_mm(r);
    fill_fit_region_cell(f, topo, min_extrudable_width_mm, n_star,
                         r.relative_density,
                                                                                            job.grading.max_relative_density);
    out.push_back(f);
  }
  return out;
}

// ★ §2(c) — THE SLIVER GUARD, ON THE LATTICE SIDE (task 2026-08-15-lattice-
// regions). PR 331's §5(a) refuses a grid split whose cells fall under the voxel
// floor, naming the number AND the arithmetic ("at most 42 sub-regions can clear
// the floor here"). The lattice side needs the same shape of refusal for the
// same reason: a sector that cannot carry a lattice at ANY legal cell should say
// so before the run, not leave a receipt to be read afterwards.
//
// ★ IT REFUSES ON `!feasible`, NOT ON `out_of_regime`, and that boundary is not
// mine to move. This file already decided, deliberately and in writing, that a
// region which "clears percolation but not accuracy is buildable and
// uncertifiable, which is a verdict, not a refusal" (fill_fit_region_cell, the
// pre-flight's case C). Refusing there would overturn an existing decision on
// every analytic job too. Infeasible is different in kind: no printable AND
// percolating pair exists at any cell, so there is nothing to build.
//
// Scoped to `kind == "region"`: an analytic include behaves exactly as it did.
// ★ §2(a) — A STATED DENSITY TOO LIGHT TO PRINT REFUSES, WITH THE NUMBER
// (task 2026-08-16-per-sector-density-override). NEVER a silent clamp: clamping
// turns the user's instruction into a different part, and this project has been
// bitten by that exact shape before.
//
// `min_extrudable_width_mm` is USER INPUT from his print profile, and core's
// convention is that 0 means UNSET, never "use a sensible number" — so a stated
// density with no profile width refuses too rather than being checked against a
// default nobody chose.
//
// ★ MEASURED: that width branch is UNREACHABLE from the CLI. The schema already
// refuses both `lattice.min_extrudable_width_mm` and
// `grading.min_extrudable_width_mm` at 0 when their block is present, so a job
// cannot arrive here with an unset width — verified by running two jobs that try
// (evidence 2026-08-16-per-sector-density-override/r4_refusals.txt). It stays as
// a guard for direct callers of this namespace, and is NOT claimed as a
// demonstrated refusal anywhere in the handoff.
void refuse_unprintable_stated_density(
    const JobDescription& job, const std::vector<FitRegionCell>& cells,
    LatticeTopology topo, double min_extrudable_width_mm) {
  for (const FitRegionCell& f : cells) {
    if (!(f.stated_relative_density > 0.0)) continue;
    if (f.job_region_index >= job.lattice.regions.size()) continue;
    const JobLatticeRegion& r = job.lattice.regions[f.job_region_index];
    if (!(min_extrudable_width_mm > 0.0))
      throw JobError(
          "lattice region " + std::to_string(r.region_id) +
          " states relative_density " + json_num(f.stated_relative_density) +
          ", but \"min_extrudable_width_mm\" is unset (0). That value is the "
          "print profile's extrusion width and there is no safe default for it: "
          "whether a stated density prints at all is a question about the "
          "nozzle. Declare it and re-run.");
    // ★ THE DECISION IS lattice_stated_density_unprintable's, not this
    // function's (bar R1'). This wrapper only builds the message. The predicate
    // is asserted in test_lattice_refusal.cpp, including the unreachability that
    // makes a no-override job inert here for EVERY region shape.
    if (!lattice_stated_density_unprintable(topo, f.stated_relative_density, f.cell_mm,
                                            min_extrudable_width_mm))
      continue;
    const double strut =
        lattice_strut_diameter_mm(topo, f.stated_relative_density, f.cell_mm);
    throw JobError(
        "lattice region " + std::to_string(r.region_id) +
        ": a stated relative_density of " +
        json_num(f.stated_relative_density) + " puts this region's strut at " +
        json_num(strut) + " mm, under your profile's " +
        json_num(min_extrudable_width_mm) +
        " mm extrusion width, so it cannot be printed. At this region's " +
        json_num(f.cell_mm) + " mm cell the lightest printable density is " +
        json_num(f.derived_relative_density) +
        " — state that or heavier (up to " + json_num(lattice_rho_max(topo)) +
        "), or declare a deeper region so the derivation picks a larger cell. "
        "The density is NOT clamped: a part you did not ask for is worse than a "
        "refusal.");
  }
}

void refuse_infeasible_region_lattice(const JobDescription& job,
                                      const std::vector<FitRegionCell>& cells,
                                      double min_extrudable_width_mm) {
  for (const FitRegionCell& f : cells) {
    if (f.feasible) continue;
    if (f.job_region_index >= job.lattice.regions.size()) continue;
    const JobLatticeRegion& r = job.lattice.regions[f.job_region_index];
    if (r.kind != "region") continue;   // the analytic kinds keep their verdict
    throw JobError(
        "lattice region " + std::to_string(r.region_id) +
        " cannot carry a lattice at ANY legal cell: its body measures " +
        json_num(f.extent_mm) + " mm across, and this topology needs at least " +
        json_num(f.min_width_buildable_mm) +
        " mm to build a strut at the declared " +
        json_num(min_extrudable_width_mm) +
        " mm extrusion width (and " + json_num(f.min_width_certifiable_mm) +
        " mm to certify one). Declare a deeper region, run at a finer "
        "resolution, or split the parent into fewer pieces.");
  }
}

// ★ THE PER-VOXEL STATED DENSITY (task 2026-08-16-per-sector-density-override).
// Built exactly like `fit_cell_field` and by the SAME membership test, so a voxel
// gets the cell and the density of the SAME region and the two cannot disagree
// about which region owns it. 0.0 where no region states one — the law's sentinel
// for "derive", so a job with no override hands in an all-zero field that is
// behaviourally identical to handing in nothing.
std::vector<double> region_density_field(
    const VoxelGrid& grid, const std::vector<ClearanceGeometry>& includes,
    const std::vector<FitRegionCell>& cells) {
  std::vector<double> out(grid.voxel_count(), 0.0);
  if (includes.size() != cells.size()) return out;  // caller asserts; never guess
  bool any = false;
  for (const FitRegionCell& c : cells)
    if (c.stated_relative_density > 0.0) any = true;
  if (!any) return out;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const Vec3 c{grid.origin.x + (i + 0.5) * grid.spacing,
                     grid.origin.y + (j + 0.5) * grid.spacing,
                     grid.origin.z + (k + 0.5) * grid.spacing};
        // the OWNER rule (ruling 4): nearest face plane, tie to the lower id, never declaration order.
        if (const int ow = stepped_region_owner(c, includes))
          out[grid.index(i, j, k)] = cells[ow - 1].stated_relative_density;
      }
  return out;
}

// The per-voxel desired cell the grading law's Fit mode consumes: the derived cell of
// the include region owning each voxel, 0 elsewhere. Built from the SAME membership
// test the certification mask uses (`point_in_clearance_region`), resolved by the OWNER
// rule where prisms overlap (stepped_region_owner: nearest face plane, tie to the lower
// id), so the cell a voxel is graded at is the cell derived for the region that voxel
// belongs to -- and not, as it was, for whichever region happened to be declared first.
std::vector<double> fit_cell_field(const VoxelGrid& grid,
                                   const std::vector<ClearanceGeometry>& includes,
                                   const std::vector<FitRegionCell>& cells) {
  std::vector<double> out(grid.voxel_count(), 0.0);
  if (includes.size() != cells.size()) return out;  // caller asserts; never guess
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const Vec3 c{grid.origin.x + (i + 0.5) * grid.spacing,
                     grid.origin.y + (j + 0.5) * grid.spacing,
                     grid.origin.z + (k + 0.5) * grid.spacing};
        // the OWNER rule (ruling 4): nearest face plane, tie to the lower id, never declaration order.
        if (const int ow = stepped_region_owner(c, includes))
          out[grid.index(i, j, k)] = cells[ow - 1].cell_mm;  // 0 when infeasible
      }
  return out;
}

// ★ WHERE THE SKIPPED VOXELS WERE (review Q2). Walks the printed set once and splits
// it by declared include region, so the receipt can say whether a voxel that got no
// derived cell was INSIDE a region the user declared (a defect in this law) or OUTSIDE
// every one of them (the candidate set reaching past the declaration — a different
// defect, and one this project has paid for twice).
//
// Uses the SAME membership test and the same first-match precedence as
// `fit_cell_field`, so the two cannot disagree about which region owns a voxel.
void fill_fit_region_voxels(RunInfo& gi, const VoxelGrid& grid,
                            const std::vector<double>& density, double iso,
                            const std::vector<ClearanceGeometry>& includes,
                            const GradedField& gf) {
  if (gi.grading_fit_regions.size() != includes.size()) return;
  long long outside = 0;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        if (!(density[e] > iso)) continue;      // not printed: not a candidate at all
        const Vec3 c{grid.origin.x + (i + 0.5) * grid.spacing,
                     grid.origin.y + (j + 0.5) * grid.spacing,
                     grid.origin.z + (k + 0.5) * grid.spacing};
        // the OWNER rule (ruling 4): nearest face plane, tie to the lower id, never declaration order. A point in no prism has NO owner and is counted outside.
        const int ow = stepped_region_owner(c, includes);
        if (ow == 0) { ++outside; continue; }
        const std::size_t owner = static_cast<std::size_t>(ow - 1);
        RunInfo::GradingFitRegion& R = gi.grading_fit_regions[owner];
        ++R.candidate_voxels;
        if (e < gf.posture.mask.size() && gf.posture.mask[e]) ++R.latticed_voxels;
      }
  gi.grading_fit_printed_outside_regions = outside;
}

// FIT's run_info block. Recomputed from the JOB rather than plumbed through the
// variant outcome: the derivation is pure arithmetic on core's own constants and the
// declared geometry, so recomputing it here cannot disagree with what the run used —
// while a second copy carried down the call chain could go stale.
// ★ `roles` IS NOT OPTIONAL FOR CORRECTNESS HERE, only for the analytic path
// (task 2026-08-15-lattice-regions, bar R3). A region-backed include is dropped
// from `fit_region_cells` without it, which makes this vector shorter than
// `includes` — and `fill_fit_region_voxels` then returns EARLY on the size
// mismatch, so the per-region breakdown silently vanishes for exactly the
// regions this task added. That is the "green run that measures nothing" shape,
// so every call site passes the roles it resolved.
void fill_grading_fit(RunInfo& gi, const GradedField& gf,
                      const JobDescription& job,
                      const LatticeRoleRegions* roles = nullptr) {
  gi.grading_min_printable_cell_mm = gf.min_printable_cell_mm;
  gi.grading_density_raised_for_print_voxels =
      static_cast<long long>(gf.density_raised_for_print_voxels);
  if (gf.cell_mode != CellSizeMode::Fit) return;
  gi.grading_fit_out_of_regime_voxels =
      static_cast<long long>(gf.fit_out_of_regime_voxels);
  gi.grading_fit_no_derivation_voxels =
      static_cast<long long>(gf.fit_no_derivation_voxels);
  gi.grading_fit_distinct_cells = static_cast<long long>(gf.fit_distinct_cells);
  gi.grading_fit_regions.clear();
  for (const FitRegionCell& f :
       fit_region_cells(job, gf.posture.topology,
                        job.grading.min_extrudable_width_mm, roles)) {
    RunInfo::GradingFitRegion R;
    R.region_index = static_cast<int>(f.job_region_index);
    R.extent_mm = f.extent_mm;
    R.feasible = f.feasible;
    R.cell_mm = f.cell_mm;
    R.relative_density = f.relative_density;
    R.stated_relative_density = f.stated_relative_density;
    R.derived_relative_density = f.derived_relative_density;
    R.strut_mm = f.strut_mm;
    R.cells_per_member = f.cells_per_member;
    R.out_of_regime = f.out_of_regime;
    gi.grading_fit_regions.push_back(R);
  }
}

// The FINEST lattice cell (mm) the grading law could grant any member on this job —
// the most favourable cell a member could be measured against, and therefore the
// honest denominator for any cells-per-member statement about the run.
// AUTO takes the printability floor itself; FIXED takes its target raised to the floor
// that actually binds (S2); SWEPT's finest level comes from the PLAN'S OWN LADDER (S1);
// FIT's is the finest cell any declared region derived. Mirrors grading.cpp's and
// cell_plan.cpp's own resolution — it does not invent a second rule.
//
// `swept_light_floor` selects the PRE-S1 swept answer. It exists for exactly one
// caller and that caller documents why (see `multiscale_floor_cell_mm` below); no new
// code should pass true.
double planned_cell_mm(const JobDescription& job, bool swept_light_floor) {
  // ★ THE JOB'S TOPOLOGY, RESOLVED ONCE (task 2026-09-28-lattice-types-core).
  // This function read `LatticeTopology::Octet` four times under the note "job
  // schema restricts topology to octet". True while octet was the only id; the
  // schema now admits any LIVE type, so the planner asks the job.
  // `lattice_topology_from_id` refuses an unknown id rather than defaulting, and
  // the schema has already accepted this one, so it cannot throw here.
  const LatticeTopology topo = lattice_topology_from_id(job.grading.topology);
  const double floor_mm = lattice_cell_printability_floor_mm(
      topo, job.grading.min_extrudable_width_mm);
  // S2: the cell below which NO density in the band prints — the bound Fixed applies.
  // ★ D1: ONE function, and it takes the cap. This was the UNCAPPED floor.
  const double abs_floor_mm = lattice_min_printable_cell_mm(
      topo, job.grading.min_extrudable_width_mm, job.grading.max_relative_density);
  CellSizeMode mode = CellSizeMode::Fixed;
  if (!resolve_cell_mode(job.grading.cell_mode, mode))
    return floor_mm;  // unknown mode is refused downstream; report the floor
  switch (mode) {
    // AUTO KEEPS THE LIGHT FLOOR, DELIBERATELY. "auto" means "the lightest lattice
    // core can print", and `lattice_cell_printability_floor_mm` — evaluated at
    // rho_MIN — is exactly the cell that claim implies. It is the mode's ANSWER, not
    // a bound on someone else's number, so S1 does not touch it and past auto runs
    // stay reproducible.
    case CellSizeMode::Auto:  return floor_mm;
    // ★ S1 (task 2026-08-07-cell-mode-fit-and-swept-floor). SWEPT'S DECLARED MINIMUM
    // IS THE USER STATING AN INTENT, and it must be bounded by what can PRINT — not
    // by what a LIGHT lattice needs. This used to be `max(cell_min_mm, floor_mm)`,
    // which silently reported a declared 1.173 mm minimum as 4.9314 mm at a 0.45 mm
    // strut line width; `plan_cell_sizes` meanwhile takes `cell_min_mm` VERBATIM as
    // its base cell (cell_plan.cpp) and climbs the dyadic ladder per base cell. The
    // forecast and the planner therefore DISAGREED — measured, in
    // evidence/2026-08-07-cell-mode-fit-and-swept-floor/s1_disagreement.txt. The
    // ladder is now read from `cell_plan_finest_printable_cell_mm`, which IS the
    // planner's own arithmetic.
    case CellSizeMode::Swept:
      return swept_light_floor
                 ? std::max(job.grading.cell_min_mm, floor_mm)
                 : cell_plan_finest_printable_cell_mm(
                       topo, job.grading.cell_min_mm,
                       job.grading.cell_max_mm,
                       job.grading.min_extrudable_width_mm,
                       job.grading.max_relative_density);  // D1: the cap
    case CellSizeMode::Fit: {
      double finest = 0.0;
      for (const FitRegionCell& f :
           fit_region_cells(job, topo,
                            job.grading.min_extrudable_width_mm))
        if (f.feasible && (finest == 0.0 || f.cell_mm < finest)) finest = f.cell_mm;
      return finest > 0.0 ? finest : abs_floor_mm;
    }
    case CellSizeMode::Fixed: break;
  }
  return std::max(job.grading.cell_mm, abs_floor_mm);
}

// ★★ S1's SECOND CONSUMER, DELIBERATELY LEFT ON THE OLD RULE — BUILT + DISARMED.
//
// This is the ONE place the swept resolution reaches GEOMETRY rather than text: its
// return value becomes `options.min_feature_mm` (the density filter's length scale) on
// a `lattice.multiscale` job, so changing it changes the design.
//
// MEASURED, not assumed. evidence/2026-08-07-cell-mode-fit-and-swept-floor/
// r1_byte_identity.txt case G — a swept multiscale job declaring a 0.6 mm minimum at a
// 0.20 mm strut line width:
//     old rule : floor 5.0 cells x 2.1917 mm = 10.959 mm member => min_feature 5.479 mm
//     new rule : floor 5.0 cells x 0.6000 mm =  3.000 mm member => min_feature 2.500 mm
// and EVERY artifact moved — design.bin, both meshes, report.json, fields.bin. That is
// a verdict moving on a job that runs today, which this task's R3 makes a
// BLOCKED-STOP. So the correction stops at the refusal path (which touches no
// geometry, proven by the same script's cases A-F) and this caller keeps the old
// answer until the maintainer decides.
//
// IT IS THE SAME DEFECT. The old answer here is too COARSE in the same way and for the
// same reason: it forces a length scale derived from a cell the plan would never use,
// which forbids members the lattice could actually hold. Flipping the argument below
// to false is the whole change; what it needs is a gate table on multiscale swept jobs,
// not more code.
double multiscale_floor_cell_mm(const JobDescription& job) {
  return planned_cell_mm(job, /*swept_light_floor=*/true);
}

// Copy the SUB-FLOOR RETENTION record into run_info — ONE filler for both call sites,
// for the same reason the cell plan has one (handoff 2026-08-04-subfloor-lattice-
// unloaded-regions). Every field stays at its zero default when a job did not opt in,
// and the serializer emits no block at all then, so a run that did not arm retention
// is byte-identical (bar S1).
void fill_grading_subfloor(RunInfo& gi, const GradedField& gf) {
  gi.grading_subfloor_armed = gf.subfloor_retention_armed;
  gi.grading_subfloor_stress_fraction_ceiling = gf.subfloor_stress_fraction_max;
  gi.grading_subfloor_region_stress_fraction = gf.region_stress_fraction;
  gi.grading_subfloor_region_qualified = gf.region_qualified_unloaded;
  gi.grading_subfloor_candidate_voxels =
      static_cast<long long>(gf.subfloor_candidate_voxels);
  gi.grading_subfloor_retained_voxels =
      static_cast<long long>(gf.subfloor_retained_voxels);
  gi.grading_subfloor_recovered_voxels =
      static_cast<long long>(gf.subfloor_recovered_in_regime_voxels);
  gi.grading_subfloor_min_cells_per_member = gf.subfloor_min_cells_per_member;
  gi.grading_subfloor_max_cells_per_member = gf.subfloor_max_cells_per_member;
}

// ★ THE SHELL THE LATTICED FILE CARRIES (task 2026-08-08-strut-clip-matches-
// shell). `export_latticed_variant` pushes `variant.v3.mesh` as the solid shell,
// and `variant.v3.mesh` is
// `keep_largest_component(marching_cubes(grid, density, printed_iso))` —
// voxelize.cpp:735 + :813, from `check_v3(grid, density, kIso)` at
// analyze.cpp:389.
//
// ★★ THAT `kIso` IS THE RUN'S PRINTED ISO, NOT THE CONSTANT 0.5, and an earlier
// version of this comment said the opposite — confidently, and wrongly, in a way
// that got a follow-up task filed against a defect that does not exist (task
// 2026-08-09-shell-at-runs-printed-iso). analyze.cpp declares TWO things called
// `kIso`: a file-scope `constexpr double kIso = 0.5` at :25, and
// `const double kIso = printed_iso;` at :143 INSIDE analyze_fixed_design, whose
// body runs to :564. Line 389 is inside that body, so it binds to the SHADOWING
// LOCAL. On a multiscale run `minimize_plastic.cpp:573` resolves that argument to
// `multiscale_printed_iso()` (0.0252 for octet), and the exported shell is cut
// there — measured, and asserted by the ctest `shell_iso_provenance`.
//
// ISO IS A PARAMETER HERE FOR THAT REASON. It was a file-scope constant, which
// is what let the wrong belief be written down as fact and would silently cut the
// wrong surface the first time a caller with a non-0.5 iso appeared. A caller
// must now say which iso it means, and the only caller says
// `run_printed_iso`-equivalent explicitly.
//
// Spelled ONCE so the surface the struts are clipped against, the surface the
// invariant is measured against and the surface the file carries are the same
// object by construction rather than by three sites agreeing. The forecast path
// has no `v3.mesh` in hand and calls this to reconstruct it from the stored
// design, which is why it takes the field rather than the variant.
TriangleMesh exported_shell_for(const VoxelGrid& sg,
                                const std::vector<double>& dens,
                                double printed_iso) {
  if (!(printed_iso > 0.0 && printed_iso < 1.0))
    throw JobError("exported_shell_for: printed_iso must be in (0, 1)");
  return keep_largest_component(marching_cubes(sg, dens, printed_iso));
}

LatticeBoundary lattice_boundary_for(const VoxelGrid& sg,
                                     const std::vector<double>& dens,
                                     double cell_mm,
                                     const std::vector<ClearanceGeometry>& kos,
                                     const LatticeRoleRegions& roles,
                                     double printed_iso = 0.5,
                                     // THE EXPORTED SHELL. Non-null => the base
                                     // region is its interior (set_shell_base);
                                     // null keeps the voxel-cube union, which is
                                     // what every test that builds a boundary
                                     // without a mesh still gets.
                                     const TriangleMesh* shell = nullptr) {
  LatticeBoundary B;
  // Window: clipping needs exact distances only out to one cell of slack past
  // the largest erosion; two cells is comfortably conservative.
  B.set_voxel_base(&sg, &dens, printed_iso, 2.0 * cell_mm);
  // ★ ONE SURFACE, NOT TWO. The voxel-cube union is NOT the surface the export
  // writes: a marching-cubes vertex sits between voxel CENTRES, so the two
  // coincide on a flat face and the isosurface CHAMFERS the cube union at a
  // convex edge — measured at h/sqrt(3) = 0.984 mm on his 1.705 mm voxel
  // (evidence/2026-08-08-strut-clip-matches-shell/s1b_surface_gap.csv). Struts
  // clipped to the cube union therefore ended outside the shell at edges and
  // only at edges, which is exactly what the maintainer photographed. When the
  // shell is in hand it supersedes the cube union (set_shell_base).
  if (shell != nullptr && !shell->triangles.empty()) B.set_shell_base(shell);
  for (const ClearanceGeometry& g : kos)
    B.add_keep_out(g, /*collar=*/g.kind == ClearanceKind::Bolt);
  // Lattice roles (stage 1): activation + certification-mask terms of the SAME
  // shared predicate — never a second boundary object (H1b). Empty on a job
  // with no lattice.regions => byte-identical behaviour.
  for (const ClearanceGeometry& g : roles.includes) B.add_include_region(g);
  for (const ClearanceGeometry& g : roles.excludes) B.add_exclude_region(g);
  return B;
}

// The lattice keep-outs: the job's clearance regions resolved through the SAME
// functions the optimizer's FrozenVoid rasterization uses (handoff 100 /
// group-editing) — resolve_clearance_from_face for B-rep faces,
// resolve_clearance_manual for hand-placed primitives.
std::vector<ClearanceGeometry> lattice_keep_outs_from_job(
    const JobDescription& job, const StepModel& model) {
  std::vector<ClearanceGeometry> out;
  if (!job.loads.present) return out;
  // ★ E4 (j): a cut piece's Keep clear -- its member faces' own, clipped by its cuts.
  std::vector<ResolvedFaceRegion> clear_regions;
  for (const JobClearance& jc : job.loads.clearances)
    if (jc.region_id >= 0) {
      clear_regions = resolve_face_regions(model, job.loads.face_regions);
      break;
    }
  for (const JobClearance& jc : job.loads.clearances) {
    const bool bolt = jc.kind == "bolt";
    const ResolvedFaceRegion* piece = nullptr;
    for (const ResolvedFaceRegion& r : clear_regions)
      if (jc.region_id >= 0 && r.id == jc.region_id) piece = &r;
    double bore_r = 0.0;
    if (bolt) {
      if (jc.manual)
        bore_r = jc.radius_mm;
      else if (piece != nullptr)
        bore_r = largest_bore_radius_mm(model, piece->member_faces);
      else if (jc.face_id >= 0 && jc.face_id < model.face_count)
        bore_r =
            model.faces[static_cast<std::size_t>(jc.face_id)].cylinder_radius_mm;
    }
    ClearanceParams params = bolt ? default_bolt_clearance(bore_r)
                                  : default_face_clearance();
    if (jc.concentric_margin_mm > 0.0)
      params.concentric_margin_mm = jc.concentric_margin_mm;
    if (jc.axial_clearance_mm > 0.0)
      params.axial_clearance_mm = jc.axial_clearance_mm;
    if (jc.slab_depth_mm > 0.0) params.slab_depth_mm = jc.slab_depth_mm;
    if (piece != nullptr) {
      try {
        for (const ClearanceGeometry& g : resolve_clearance_from_region(model, *piece, params))
          out.push_back(g);
      } catch (const std::invalid_argument& e) {
        throw JobError(e.what());
      }
      continue;
    }
    ClearanceGeometry g;
    if (jc.manual) {
      ManualClearanceGeometry mg;
      mg.kind = bolt ? ClearanceKind::Bolt : ClearanceKind::Face;
      mg.axis_point = jc.axis_point;
      mg.axis_dir = jc.axis_dir;
      mg.radius_mm = jc.radius_mm;
      mg.half_length_mm = jc.half_length_mm;
      mg.origin = jc.origin;
      mg.normal = jc.normal;
      mg.half_u_mm = jc.half_u_mm;
      mg.half_w_mm = jc.half_w_mm;
      g = resolve_clearance_manual(mg, params);
    } else {
      if (jc.face_id < 0 || jc.face_id >= model.face_count) continue;
      g = resolve_clearance_from_face(model, jc.face_id, params);
    }
    if (g.valid) out.push_back(g);
  }
  return out;
}

// The lattice cell grid over the solved grid; activation (which cells emit) is
// decided by `boundary` (overlap, not centre — bar (a)).
LatticeRegion lattice_region_for(const VoxelGrid& sg, double cell_mm,
                                 const LatticeBoundary* boundary) {
  LatticeRegion R;
  R.origin = sg.origin;
  R.cell_mm = cell_mm;
  R.nx = std::max(1, static_cast<int>(std::ceil(sg.nx * sg.spacing / cell_mm)));
  R.ny = std::max(1, static_cast<int>(std::ceil(sg.ny * sg.spacing / cell_mm)));
  R.nz = std::max(1, static_cast<int>(std::ceil(sg.nz * sg.spacing / cell_mm)));
  R.boundary = boundary;
  return R;
}

// The skin spec a job's lattice block implies. The clamp is computed by CORE's
// law (lattice_skin_min_radius_mm) from the STATED extrudable width; a job that
// states none makes no printability claim and the skin tracks the interior.
LatticeSkinSpec lattice_skin_for(const JobLattice& lat) {
  LatticeSkinSpec S;
  S.mode = lat.skin == "none"  ? LatticeSkinMode::None
           : lat.skin == "rim" ? LatticeSkinMode::Rim
                               : LatticeSkinMode::Diagrid;
  S.min_radius_mm = lat.min_extrudable_width_mm > 0.0
                        ? lattice_skin_min_radius_mm(lat.min_extrudable_width_mm)
                        : 0.0;
  // A non-"shell" outer finish arms the FREEFORM skin (task 2026-07-30-
  // lattice-skin-freeform): the diagrid extends onto the voxel-derived outer
  // surface — as the outer finish itself ("skin") or laid on the shell
  // ("shell+skin"). Default "shell" leaves it off: byte-identical.
  S.freeform = lat.outer_finish == "skin" || lat.outer_finish == "shell+skin";
  return S;
}

// ★ SKIN PER ZONE (ruling 11-08 (1)): what a skin + finish lays at a point
// (LatticeSkinHere, lattice_gen.hpp). The part's: "none" and "rim" lay no diagrid,
// "diagrid" lays the boundary-finish diagrid, woven over the surface only under the
// freeform finishes. A zone's own "diagrid" is always woven: that is what Skin is.
LatticeSkinHere lattice_skin_here(const std::string& skin, const std::string& finish) {
  if (skin != "diagrid") return LatticeSkinHere::Off;
  return finish == "skin" || finish == "shell+skin" ? LatticeSkinHere::Woven
                                                    : LatticeSkinHere::Plain;
}

// ★ THE RIM ON A REAL PART (ruling 11-08 (A)). The edge angle a rim starts at (the
// reviewer's start; the receipt states it), and a chain's midpoint: the point half its
// length along it, by which a zone takes the chain (as a skin chord is taken by its own).
constexpr double kRimFeatureAngleDeg = 30.0;
Vec3 feature_chain_midpoint(const FeatureChain& c) {
  const std::size_t np = c.points.size();
  if (np == 0) return {0, 0, 0};
  const std::size_t nseg = c.closed ? np : np - 1;
  double half = 0.5 * c.length_mm;
  for (std::size_t i = 0; i < nseg; ++i) {
    const Vec3& a = c.points[i];
    const Vec3& b = c.points[(i + 1) % np];
    const double l = std::sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y) +
                               (b.z - a.z) * (b.z - a.z));
    if (half <= l && l > 0.0) {
      const double t = half / l;
      return {a.x + t * (b.x - a.x), a.y + t * (b.y - a.y), a.z + t * (b.z - a.z)};
    }
    half -= l;
  }
  return c.points.back();
}

// Whether the export writes the solid shell: "shell" and "shell+skin" do; "skin" and
// ★ E2.4's "none" (the open lattice) do not.
bool lattice_shell_written(const JobLattice& lat) {
  return lat.outer_finish == "shell" || lat.outer_finish == "shell+skin";
}

// ★ THE SOLID ON THE PART'S OWN SURFACE (reviewer's ruling 11-09, the rim coupon's SOLID).
// The companion was the marching cubes of the solid voxels, so its outer faces were raw
// voxel steps. Here it is the part's own mesh INTERSECTED with the solid ZONE:
//   * inside the part, the zone is the solid voxels (the lattice's voxels, a clearance's
//     and a design cut's are not in it), so the solid/lattice interface is where it was;
//   * outside the part, each voxel within two of the printed set takes the label of the
//     printed voxels beside it (solid wins a tie), so the zone runs past the part's
//     surface wherever the solid meets air, and the part's faces cut it there.
// The faces that meet air are therefore the part's own, exactly; the interface stays the
// voxel boundary the certificate counts. A boolean that cannot be made keeps the voxel
// body and says why (never a half-written solid).
struct SolidOnSurface {
  TriangleMesh mesh;
  bool ok = false;
  std::string why;
};
double mesh_signed_volume(const TriangleMesh& m) {
  double v = 0.0;
  for (const auto& t : m.triangles) {
    const Vec3& a = m.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& c = m.vertices[static_cast<std::size_t>(t[2])];
    v += a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) +
         a.z * (b.x * c.y - b.y * c.x);
  }
  return v / 6.0;
}
TriangleMesh outward_wound(TriangleMesh m) {
  if (mesh_signed_volume(m) < 0.0)
    for (auto& t : m.triangles) std::swap(t[1], t[2]);
  return m;
}
SolidOnSurface solid_on_part_surface(const VoxelGrid& sg, const std::vector<double>& comp,
                                     const std::vector<double>& dens, double printed_iso,
                                     const TriangleMesh& surface) {
  SolidOnSurface out;
#ifdef TOPOPT_HAVE_MANIFOLD
  const int pad = 3, nx = sg.nx, ny = sg.ny, nz = sg.nz;
  const int px = nx + 2 * pad, py = ny + 2 * pad, pz = nz + 2 * pad;
  const std::size_t np = static_cast<std::size_t>(px) * py * pz;
  auto at = [&](int i, int j, int k) {
    return (static_cast<std::size_t>(k) * py + j) * px + i;
  };
  std::vector<double> zone(np, 0.0);
  std::vector<int> layer(np, -1);  // 0: printed; 1, 2: outside, that far; -2: a cut
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t e = sg.index(i, j, k);
        const std::size_t q = at(i + pad, j + pad, k + pad);
        if (dens[e] >= printed_iso) {
          layer[q] = 0;
          zone[q] = comp[e] > 0.5 ? 1.0 : 0.0;
        } else if (sg.solid(i, j, k)) {
          layer[q] = -2;  // inside the part, removed by the design: never filled
        }
      }
  const int off[6][3] = {{-1, 0, 0}, {1, 0, 0}, {0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}};
  for (int d = 1; d <= 2; ++d) {
    std::vector<std::pair<std::size_t, double>> next;
    for (int k = 1; k + 1 < pz; ++k)
      for (int j = 1; j + 1 < py; ++j)
        for (int i = 1; i + 1 < px; ++i) {
          const std::size_t q = at(i, j, k);
          if (layer[q] != -1) continue;
          bool reached = false, solid = false;
          for (const auto& o : off) {
            const std::size_t r = at(i + o[0], j + o[1], k + o[2]);
            if (layer[r] != d - 1) continue;
            reached = true;
            if (zone[r] > 0.5) solid = true;
          }
          if (reached) next.emplace_back(q, solid ? 1.0 : 0.0);
        }
    for (const auto& [q, z] : next) {
      layer[q] = d;
      zone[q] = z;
    }
  }
  const Vec3 o{sg.origin.x - pad * sg.spacing, sg.origin.y - pad * sg.spacing,
               sg.origin.z - pad * sg.spacing};
  const TriangleMesh zmesh = outward_wound(marching_cubes(px, py, pz, sg.spacing, o, zone, 0.5));
  if (zmesh.triangles.empty()) {
    out.why = "the solid zone is empty";
    return out;
  }
  const manifold::Manifold Z = mesh_manifold(zmesh);
  if (Z.Status() != manifold::Manifold::Error::NoError) {
    out.why = "the solid zone's marching-cubes surface is not a closed manifold";
    return out;
  }
  const manifold::Manifold P = mesh_manifold(outward_wound(surface));
  if (P.Status() != manifold::Manifold::Error::NoError) {
    out.why = "the part's own mesh is not a closed manifold";
    return out;
  }
  const manifold::Manifold S = P ^ Z;
  if (S.Status() != manifold::Manifold::Error::NoError || S.IsEmpty()) {
    out.why = "the part and the solid zone did not intersect cleanly";
    return out;
  }
  out.mesh = manifold_mesh(S.GetMeshGL());
  out.ok = !out.mesh.triangles.empty();
  if (!out.ok) out.why = "the intersection came out empty";
#else
  (void)sg; (void)comp; (void)dens; (void)printed_iso; (void)surface;
  out.why = "this build has no boolean (manifold) library";
#endif
  return out;
}
