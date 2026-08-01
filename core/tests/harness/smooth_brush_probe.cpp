// smooth_brush_probe — bar AE4 and the brush's device-real measurement
// (handoff 2026-08-02-smoothing-page).
//
// PR 200 could not prove re-certification would ever LOWER a verdict: under
// self-weight the demo margins were 2000–9800× and smoothing RAISED them (a
// lighter part carries less of its own weight). Since PR 261 fixed the face-id
// load-resolution bug the maintainer's WallMount bracket runs with a REAL
// resolved traction, so the question is finally answerable on a real part.
//
// This probe answers it, and reports the numbers whichever way they come out:
//
//   AE4  smooth the WallMount bracket AGGRESSIVELY and report whether the verdict
//        changes — and by how much the margin moves. "It never drops" is a
//        finding, not a failure: it would mean smoothing is safe by construction
//        on this part, and the numbers say so.
//   H2   min-feature violations are reported BOTH WAYS. PR 200 measured them
//        FALLING on real tendrilly variants (961 → 639) because smoothing removes
//        terracing that counted as sub-printable.
//   H3   the certified object is the RE-VOXELIZATION of the smoothed mesh, so the
//        mesh's own volume fraction and the voxel set's are both printed and the
//        gap between them is a number.
//   BRUSH the local-vs-global comparison: the same strength applied to ONE region
//        instead of the whole surface, so "smoothing only where it's needed" has a
//        measured cost as well as a stated one.
//
// Every solve goes through the SHIPPED path — build_production_loadcase, then
// analyze_fixed_design, the same two calls the CLI's analyze and the optimizer's
// own certification use. Nothing here re-derives physics.
//
// A HARNESS, not a test: it prints a table and writes evidence, and it asserts
// only the preconditions that would make its own numbers meaningless.

#include "topopt/analyze.hpp"
#include "topopt/clearance.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/fea.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/production.hpp"
#include "topopt/report.hpp"
#include "topopt/smooth.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;

namespace {

struct FaceInfo {
  int id = 0;
  int tris = 0;
  Vec3 centroid{0, 0, 0};
  Vec3 normal{0, 0, 0};
  double area = 0.0;
};

std::vector<FaceInfo> face_table(const StepModel& m) {
  std::vector<FaceInfo> out(static_cast<std::size_t>(m.face_count));
  for (int f = 0; f < m.face_count; ++f) out[static_cast<std::size_t>(f)].id = f;
  for (std::size_t t = 0; t < m.triangle_face.size(); ++t) {
    const std::size_t f = static_cast<std::size_t>(m.triangle_face[t]);
    if (f >= out.size()) continue;
    const auto& tri = m.mesh.triangles[t];
    const Vec3& a = m.mesh.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = m.mesh.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& c = m.mesh.vertices[static_cast<std::size_t>(tri[2])];
    out[f].centroid.x += (a.x + b.x + c.x) / 3.0;
    out[f].centroid.y += (a.y + b.y + c.y) / 3.0;
    out[f].centroid.z += (a.z + b.z + c.z) / 3.0;
    const Vec3 e1{b.x - a.x, b.y - a.y, b.z - a.z};
    const Vec3 e2{c.x - a.x, c.y - a.y, c.z - a.z};
    const Vec3 n{e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z,
                 e1.x * e2.y - e1.y * e2.x};
    out[f].normal.x += n.x;
    out[f].normal.y += n.y;
    out[f].normal.z += n.z;
    out[f].area += 0.5 * std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    out[f].tris++;
  }
  for (FaceInfo& fi : out) {
    if (fi.tris == 0) continue;
    fi.centroid.x /= fi.tris;
    fi.centroid.y /= fi.tris;
    fi.centroid.z /= fi.tris;
    const double nl = std::sqrt(fi.normal.x * fi.normal.x +
                                fi.normal.y * fi.normal.y +
                                fi.normal.z * fi.normal.z);
    if (nl > 0) {
      fi.normal.x /= nl;
      fi.normal.y /= nl;
      fi.normal.z /= nl;
    }
  }
  return out;
}

double axis(const Vec3& v, int a) { return a == 0 ? v.x : (a == 1 ? v.y : v.z); }

// The faces at one extreme of `ax` — the wall plate at min, the shelf lip at max.
// Chosen by GEOMETRY and PRINTED, so which faces carry the clamp and the traction
// is on the record rather than a magic id list.
std::vector<int> faces_at_extreme(const std::vector<FaceInfo>& faces, int ax,
                                  bool maximum, double tol, int min_tris) {
  double best = maximum ? -1e30 : 1e30;
  for (const FaceInfo& f : faces) {
    if (f.tris < min_tris) continue;
    const double v = axis(f.centroid, ax);
    if (maximum ? (v > best) : (v < best)) best = v;
  }
  std::vector<int> out;
  for (const FaceInfo& f : faces) {
    if (f.tris < min_tris) continue;
    if (std::fabs(axis(f.centroid, ax) - best) <= tol) out.push_back(f.id);
  }
  return out;
}

// One certification of `design_mesh` under `setup`, exactly as the CLI's analyze
// path does it: re-voxelize onto the model grid, carry the Fixture/Load tags,
// then analyze_fixed_design.
struct Reading {
  FixedDesignAnalysis a;
  double mesh_volume_mm3 = 0.0;
  double voxel_volume_mm3 = 0.0;
  double grid_volume_mm3 = 0.0;
  int min_feature = 0;
};

Reading certify(const ProductionRunSetup& setup, const Material& material,
                const TriangleMesh& design_mesh, const KnockdownSpec& knockdown) {
  Reading r;
  const VoxelGrid& model_grid = setup.grid;
  VoxelGrid design_grid = voxelize_onto_grid(design_mesh, model_grid);
  for (std::size_t i = 0; i < design_grid.tags.size(); ++i) {
    if (model_grid.tags[i] == VoxelTag::Fixture &&
        design_grid.tags[i] != VoxelTag::Empty)
      design_grid.tags[i] = VoxelTag::Fixture;
    else if (model_grid.tags[i] == VoxelTag::Load)
      design_grid.tags[i] = VoxelTag::Load;
  }
  std::vector<double> density(design_grid.voxel_count(), 0.0);
  std::size_t solid = 0;
  for (std::size_t i = 0; i < density.size(); ++i)
    if (design_grid.tags[i] != VoxelTag::Empty) {
      density[i] = 1.0;
      ++solid;
    }

  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;
  const Vec3 gdir = setup.options.gravity_direction;
  const double gn = std::sqrt(gdir.x * gdir.x + gdir.y * gdir.y + gdir.z * gdir.z);
  const Vec3 build_dir =
      gn > 0 ? Vec3{-gdir.x / gn, -gdir.y / gn, -gdir.z / gn} : Vec3{0, 0, 1};
  const bool load_path_ok = load_path_connected(design_grid, density, 0.5);

  r.a = analyze_fixed_design(
      design_grid, params, density, setup.bcs, setup.options.external_loads,
      material, build_dir, setup.options.simp.cg_tolerance,
      setup.options.simp.cg_max_iterations, setup.options.simp.solver,
      setup.options.margin_stop, knockdown, load_path_ok,
      static_cast<double>(model_grid.solid_count()));
  r.min_feature = r.a.v3.min_feature_violations;
  r.mesh_volume_mm3 = std::fabs(signed_volume(design_mesh));
  r.voxel_volume_mm3 = static_cast<double>(solid) * design_grid.voxel_volume();
  r.grid_volume_mm3 = static_cast<double>(design_grid.nx) *
                      static_cast<double>(design_grid.ny) *
                      static_cast<double>(design_grid.nz) *
                      design_grid.voxel_volume();
  return r;
}

// The freeze regions the analyze path resolves for this load case: the anchor and
// load faces (structural — the clamp and the traction must stay attached to
// bit-identical solid across the re-voxelization).
std::vector<ClearanceGeometry> freeze_faces(const StepModel& model,
                                            const std::vector<int>& ids,
                                            double spacing) {
  std::vector<ClearanceGeometry> out;
  for (const int fid : ids) {
    if (fid < 0 || fid >= model.face_count) continue;
    const StepFaceInfo& face = model.faces[static_cast<std::size_t>(fid)];
    ClearanceParams p;
    if (face.kind == StepSurfaceKind::Cylinder) {
      p.kind = ClearanceKind::Bolt;
    } else if (face.kind == StepSurfaceKind::Plane) {
      p.kind = ClearanceKind::Face;
      p.slab_depth_mm = spacing;
    } else {
      continue;
    }
    const ClearanceGeometry g = resolve_clearance_from_face(model, fid, p);
    if (g.valid) out.push_back(g);
  }
  return out;
}

const char* verdict(const FixedDesignAnalysis& a) {
  if (a.non_convergent) return "NON-CONVERGENT";
  return a.accepted ? "ACCEPTED" : "REJECTED";
}

}  // namespace

int main(int argc, char** argv) {
  const std::string mesh_path =
      argc > 1 ? argv[1]
               : std::string(MESH_FIXTURE_DIR) + "/WallMount_ShelfBracket.stl";
  const int res = argc > 2 ? std::atoi(argv[2]) : 64;
  const double force_n = argc > 3 ? std::atof(argv[3]) : 0.0;
  const double infill = argc > 4 ? std::atof(argv[4]) : 35.0;
  const char* evidence_dir = argc > 5 ? argv[5] : std::getenv("SMOOTH_EVIDENCE_DIR");

  StepModel model = import_part_file_resolved(mesh_path);
  Vec3 lo, hi;
  bounding_box(model.mesh, lo, hi);
  std::printf("== SPECIMEN ==\n");
  std::printf("%s\n", mesh_path.c_str());
  std::printf("bbox  %.1f x %.1f x %.1f mm   tris=%zu  pseudo-faces=%d\n",
              hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, model.mesh.triangles.size(),
              model.face_count);

  const std::vector<FaceInfo> faces = face_table(model);
  std::printf("\n== THE 12 LARGEST PSEUDO-FACES (the load case is chosen from "
              "these, by geometry) ==\n");
  {
    std::vector<FaceInfo> sorted = faces;
    std::sort(sorted.begin(), sorted.end(),
              [](const FaceInfo& a, const FaceInfo& b) { return a.area > b.area; });
    for (std::size_t i = 0; i < sorted.size() && i < 12; ++i) {
      const FaceInfo& f = sorted[i];
      std::printf("  face %3d  tris=%4d  area=%8.1f mm^2  centroid=(%7.2f %7.2f "
                  "%7.2f)  n=(%5.2f %5.2f %5.2f)\n",
                  f.id, f.tris, f.area, f.centroid.x, f.centroid.y, f.centroid.z,
                  f.normal.x, f.normal.y, f.normal.z);
    }
  }

  // THE LOAD CASE. A wall bracket: the back plate is clamped to the wall, the
  // shelf carries a downward load. Both face sets are chosen by geometry (the
  // extremes along the two longest axes) and PRINTED above, so nothing here is a
  // magic id.
  //
  // The default is the shelf-bracket reading of THIS part: the wall plate is the
  // face set at max-x, the shelf's free end is the set at min-y, and the load
  // hangs off that end. The four selectors are argv-settable so the choice is
  // inspectable and changeable rather than compiled in.
  const double ex = hi.x - lo.x, ey = hi.y - lo.y, ez = hi.z - lo.z;
  const int anchor_axis = argc > 6 ? std::atoi(argv[6]) : 0;
  const bool anchor_max = argc > 7 ? (std::atoi(argv[7]) != 0) : true;
  const int load_axis = argc > 8 ? std::atoi(argv[8]) : 1;
  const bool load_max = argc > 9 ? (std::atoi(argv[9]) != 0) : false;
  const double tol = 0.02 * std::max(ex, std::max(ey, ez));

  const std::vector<int> anchor_faces =
      faces_at_extreme(faces, anchor_axis, anchor_max, tol, 8);
  const std::vector<int> load_faces =
      faces_at_extreme(faces, load_axis, load_max, tol, 8);
  std::printf("\n== LOAD CASE (chosen by geometry) ==\n");
  std::printf("  anchor: %zu face(s) at %s-%c :", anchor_faces.size(),
              anchor_max ? "max" : "min", "xyz"[anchor_axis]);
  for (const int f : anchor_faces) std::printf(" %d", f);
  std::printf("\n  load  : %zu face(s) at %s-%c :", load_faces.size(),
              load_max ? "max" : "min", "xyz"[load_axis]);
  for (const int f : load_faces) std::printf(" %d", f);
  std::printf("\n");
  if (anchor_faces.empty() || load_faces.empty()) {
    std::fprintf(stderr, "PRECONDITION FAILED: no anchor/load faces resolved\n");
    return 1;
  }

  MaterialLibrary lib = load_materials_file(MATERIALS_JSON_PATH);
  auto it = lib.find("PLA");
  if (it == lib.end()) {
    std::fprintf(stderr, "PRECONDITION FAILED: PLA not in the catalog\n");
    return 1;
  }
  const Material material = it->second;

  // The traction is DOWNWARD (−z of the load axis' complement is not meaningful
  // on an arbitrary part, so: along −(the anchor axis' normal-most axis)). For a
  // shelf bracket the honest direction is gravity: straight down the shortest
  // world axis is wrong, so the load is applied along −y, the world down the app
  // uses by default. It is stated here rather than inferred.
  auto build = [&](double f_n) {
    ProductionLoadCase lc;
    lc.anchor_face_ids = anchor_faces;
    ProductionLoadCase::LoadGroup g;
    g.face_ids = load_faces;
    g.force = Vec3{0.0, -f_n, 0.0};
    lc.load_groups.push_back(g);
    lc.minimize_plastic = false;
    lc.infill_percent = infill;
    return build_production_loadcase(model, res, lc);
  };

  // CALIBRATION — AND WHY THERE ARE TWO POSTURES.
  //
  // The maintainer's run reported worst-case margin 2.7814 at max_stress 14.459
  // MPa. But that run was REJECTED, and PR 276 established why: at 35% infill the
  // knockdown is 0.207, so the number the GATE compares is 0.576, not 2.78. The
  // part is strong; the infill is what rejected it.
  //
  // That matters here, because "does smoothing move the verdict" is only a real
  // question if the specimen starts on the ACCEPTED side. A part that is already
  // REJECTED stays REJECTED however hard you smooth it, and reporting that as
  // "the verdict never changed" would be true and worthless.
  //
  // So the probe runs the sweep TWICE:
  //   posture A — AS REPORTED. The traction is calibrated so the SOLID part's
  //     worst-case margin is 2.7814, the maintainer's own number. At 35% infill
  //     that starts REJECTED, exactly as their run did, and the interesting
  //     number is how far the raw margin MOVES.
  //   posture B — AT THE GATE. The traction is calibrated so the SOLID part's
  //     EFFECTIVE margin (what the gate compares) sits just above the stop. Now a
  //     verdict CAN cross, and whether it does is a real answer.
  // Both are linear: margin scales exactly inversely with the traction, so one
  // probe solve fixes each force.
  const double kTargetMargin = 2.7814;
  double force = force_n;
  ProductionRunSetup setup = build(force > 0 ? force : 100.0);
  if (setup.options.external_loads.empty()) {
    std::fprintf(stderr, "PRECONDITION FAILED: the load faces tagged no voxels — "
                         "%s\n",
                 no_external_load_message(setup, res).c_str());
    return 1;
  }
  KnockdownSpec knockdown = knockdown_spec_for(setup.options);
  double force_at_gate = 0.0;
  const double kJustAboveStop = 1.10;
  if (force <= 0) {
    const Reading probe = certify(setup, material, model.mesh, knockdown);
    if (probe.a.non_convergent || !(probe.a.margin.worst_case > 0)) {
      std::fprintf(stderr, "PRECONDITION FAILED: the calibration solve gave no "
                           "usable margin\n");
      return 1;
    }
    force = 100.0 * probe.a.margin.worst_case / kTargetMargin;
    std::printf("\n== CALIBRATION ==\n");
    std::printf("  100 N on the CAD solid: worst-case margin %.4f, effective "
                "%.4f (the number the gate compares)\n",
                probe.a.margin.worst_case, probe.a.margin_effective);
    std::printf("  posture A (as reported): %.1f N -> worst-case ~%.4f, the "
                "maintainer's own number. Starts REJECTED at %.0f%% infill, as "
                "their run did.\n",
                force, kTargetMargin, infill);
    std::printf("  posture B is calibrated below, from posture A's own reading "
                "of the DESIGN UNDER TEST (calibrating on the CAD solid would "
                "aim at a different object than the one being smoothed).\n");
    setup = build(force);
    knockdown = knockdown_spec_for(setup.options);
  }

  // THE DESIGN UNDER TEST. Not the CAD solid — a marching-cubes ISO-SURFACE of
  // its own voxelization, which is the kind of surface an optimizer variant has:
  // terraced, high-frequency, and exactly what smoothing acts on. Smoothing a
  // smooth prismatic CAD surface moves it by microns and would answer nothing.
  std::vector<double> occ(setup.grid.voxel_count(), 0.0);
  for (std::size_t i = 0; i < occ.size(); ++i)
    if (setup.grid.tags[i] != VoxelTag::Empty) occ[i] = 1.0;
  const TriangleMesh design = marching_cubes(setup.grid, occ);
  std::printf("\n== DESIGN UNDER TEST ==\n");
  std::printf("  iso-surface of the %dx%dx%d voxelization: %zu verts, %zu tris "
              "(spacing %.3f mm)\n",
              setup.grid.nx, setup.grid.ny, setup.grid.nz,
              design.vertices.size(), design.triangles.size(),
              setup.grid.spacing);

  SmoothConstraints base;
  base.freeze_regions = freeze_faces(model, anchor_faces, setup.grid.spacing);
  for (auto& r : freeze_faces(model, load_faces, setup.grid.spacing))
    base.freeze_regions.push_back(std::move(r));
  base.min_feature_grid = &setup.grid;
  base.enforce_min_feature = false;  // the sweep probes the whole curve
  const std::vector<char> frozen =
      compute_freeze_mask(design, base.freeze_regions, 0.75 * setup.grid.spacing);
  std::size_t nfrozen = 0;
  for (const char f : frozen) nfrozen += (f ? 1u : 0u);
  std::printf("  frozen (anchor + load faces): %zu of %zu vertices\n", nfrozen,
              design.vertices.size());

  // ── AE4: the sweep, run once per posture ──────────────────────────────────
  struct Sweep {
    Reading solid;
    Reading strongest;
    double min_worst = 0.0;
    double min_effective = 0.0;
    bool verdict_dropped = false;
    bool nonconvergent = false;
  };
  const double strengths[] = {0.10, 0.25, 0.50, 0.75, 1.00};

  auto sweep = [&](const char* posture, const ProductionRunSetup& s_setup,
                   const KnockdownSpec& s_knock, double s_force) -> Sweep {
    Sweep sw;
    sw.solid = certify(s_setup, material, design, s_knock);
    sw.strongest = sw.solid;
    sw.min_worst = sw.solid.a.margin.worst_case;
    sw.min_effective = sw.solid.a.margin_effective;
    std::printf("\n== AE4 · %s ==\n", posture);
    std::printf("  material PLA · resolution %d · traction %.1f N · infill "
                "%.0f%% · required margin %.2f\n",
                res, s_force, infill, s_setup.options.margin_stop);
    std::printf("\n  strength  pairs  frozen  vm(MPa)  in-plane  interlayer  "
                "worst   effective  minfeat  mass(g)  verdict\n");
    auto row = [&](const char* label, int pairs, std::size_t nf, const Reading& r) {
      std::printf("  %-8s  %5d  %6zu  %7.3f  %8.4f  %10.4f  %6.4f  %9.4f  %7d  "
                  "%7.2f  %s\n",
                  label, pairs, nf, r.a.max_von_mises, r.a.margin.in_plane,
                  r.a.margin.interlayer, r.a.margin.worst_case,
                  r.a.margin_effective, r.min_feature, r.a.mass_grams,
                  verdict(r.a));
    };
    row("0.00", 0, nfrozen, sw.solid);
    for (const double s : strengths) {
      SmoothConstraints c = base;
      const TaubinParams p = taubin_params_for_strength(s);
      const SmoothResult sr = constrained_taubin_smooth(design, p, c);
      const Reading r = certify(s_setup, material, sr.mesh, s_knock);
      char label[16];
      std::snprintf(label, sizeof(label), "%.2f", s);
      row(label, sr.stats.applied_pairs, sr.stats.frozen_vertices, r);
      if (r.a.non_convergent) {
        sw.nonconvergent = true;
        continue;
      }
      if (sw.solid.a.accepted && !r.a.accepted) sw.verdict_dropped = true;
      sw.min_worst = std::min(sw.min_worst, r.a.margin.worst_case);
      sw.min_effective = std::min(sw.min_effective, r.a.margin_effective);
      sw.strongest = r;
    }
    std::printf("\n  ANSWER: ");
    if (sw.verdict_dropped) {
      std::printf("*** THE VERDICT DROPS. *** The unsmoothed iso-surface is "
                  "ACCEPTED and smoothing takes it to REJECTED; the effective "
                  "margin falls %.4f -> %.4f (%.1f%%) through the %.2f stop.\n",
                  sw.solid.a.margin_effective, sw.min_effective,
                  100.0 * (sw.min_effective - sw.solid.a.margin_effective) /
                      sw.solid.a.margin_effective,
                  s_setup.options.margin_stop);
    } else if (!sw.solid.a.accepted) {
      std::printf("the specimen starts REJECTED, so no verdict CAN drop here — "
                  "the reading is the SIZE OF THE MOVE: worst-case %.4f -> %.4f "
                  "(%+.1f%%), effective %.4f -> %.4f.\n",
                  sw.solid.a.margin.worst_case, sw.min_worst,
                  100.0 * (sw.min_worst - sw.solid.a.margin.worst_case) /
                      sw.solid.a.margin.worst_case,
                  sw.solid.a.margin_effective, sw.min_effective);
    } else {
      std::printf("THE VERDICT DOES NOT CHANGE at any strength. Effective "
                  "margin moves %.4f -> %.4f (%+.1f%%) and stays above the %.2f "
                  "stop. On this specimen smoothing is safe by construction — a "
                  "finding, not a gap.\n",
                  sw.solid.a.margin_effective, sw.min_effective,
                  100.0 * (sw.min_effective - sw.solid.a.margin_effective) /
                      sw.solid.a.margin_effective,
                  s_setup.options.margin_stop);
    }
    if (sw.nonconvergent)
      std::printf("  (at least one strength was NON-CONVERGENT — hazard H1, "
                  "reported rather than certified)\n");
    return sw;
  };

  const Sweep posture_a =
      sweep("POSTURE A · AS THE MAINTAINER'S RUN WAS (worst-case 2.7814, 35% "
            "infill)", setup, knockdown, force);

  // POSTURE B — the same specimen loaded so it sits JUST ABOVE the gate, which
  // is the only posture in which "can smoothing drop a verdict" is a question
  // with two possible answers.
  //
  // The force is derived from POSTURE A'S OWN READING of the design under test,
  // not from the CAD solid: the margin is exactly inverse in the traction, so
  //   force_B = force_A * effective_A / target
  // lands the iso-surface — the thing actually being smoothed — at `target`. The
  // target is 1.10x the stop, chosen so the specimen starts comfortably ACCEPTED
  // and posture A's measured ~17% fall would carry it through. Whether it
  // actually does is the answer, and it is not pre-decided by this arithmetic.
  Sweep posture_b = posture_a;
  if (force_n <= 0.0 && posture_a.solid.a.margin_effective > 0.0) {
    force_at_gate = force * posture_a.solid.a.margin_effective /
                    (kJustAboveStop * setup.options.margin_stop);
    std::printf("\n  posture B force: %.1f N x %.4f / %.4f = %.1f N (the design "
                "under test starts at effective ~%.4f)\n",
                force, posture_a.solid.a.margin_effective,
                kJustAboveStop * setup.options.margin_stop, force_at_gate,
                kJustAboveStop * setup.options.margin_stop);
  }
  if (force_at_gate > 0.0) {
    const ProductionRunSetup gate_setup = build(force_at_gate);
    const KnockdownSpec gate_knock = knockdown_spec_for(gate_setup.options);
    posture_b = sweep("POSTURE B · CALIBRATED TO SIT JUST ABOVE THE GATE",
                      gate_setup, gate_knock, force_at_gate);
  }

  const Reading& solid = posture_a.solid;
  const Reading& last = posture_a.strongest;
  const double worst_margin = posture_a.min_worst;
  const bool verdict_dropped = posture_b.verdict_dropped;
  const bool any_nonconvergent =
      posture_a.nonconvergent || posture_b.nonconvergent;

  // ── H2 / H3 · reported both ways, and the analyzed-vs-printed gap ──────────
  std::printf("\n== H2 · MIN-FEATURE, BOTH DIRECTIONS ==\n");
  std::printf("  unsmoothed %d violations -> strongest smoothing %d violations "
              "(%s)\n",
              solid.min_feature, last.min_feature,
              last.min_feature < solid.min_feature
                  ? "FELL — smoothing removed terracing that counted as "
                    "sub-printable"
                  : (last.min_feature > solid.min_feature
                         ? "ROSE — smoothing thinned something below the floor"
                         : "unchanged"));

  std::printf("\n== H3 · THE CERTIFIED OBJECT IS THE RE-VOXELIZATION ==\n");
  auto vf = [](const Reading& r) {
    return r.grid_volume_mm3 > 0 ? r.mesh_volume_mm3 / r.grid_volume_mm3 : 0.0;
  };
  auto vvf = [](const Reading& r) {
    return r.grid_volume_mm3 > 0 ? r.voxel_volume_mm3 / r.grid_volume_mm3 : 0.0;
  };
  std::printf("  unsmoothed : mesh volume fraction %.5f  voxel %.5f  gap %+.2f%%\n",
              vf(solid), vvf(solid),
              vf(solid) > 0 ? 100.0 * (vvf(solid) - vf(solid)) / vf(solid) : 0.0);
  std::printf("  smoothed   : mesh volume fraction %.5f  voxel %.5f  gap %+.2f%%\n",
              vf(last), vvf(last),
              vf(last) > 0 ? 100.0 * (vvf(last) - vf(last)) / vf(last) : 0.0);
  std::printf("  The mesh is the deliverable; the margin describes the voxel "
              "proxy. Both numbers are on the app's receipt for the same reason.\n");

  // ── THE BRUSH · local vs global at the SAME strength ──────────────────────
  //
  // The page's whole reason for existing: smoothing only where it is needed. So
  // the same strength is applied to ONE HALF of the surface and the cost is
  // compared with applying it everywhere.
  std::printf("\n== THE BRUSH · LOCAL vs GLOBAL AT THE SAME STRENGTH ==\n");
  {
    const double s = 1.00;
    const TaubinParams p = taubin_params_for_strength(s);

    SmoothConstraints global = base;
    global.vertex_weight.assign(design.vertices.size(), 1.0);
    const SmoothResult gr = constrained_taubin_smooth(design, p, global);
    const Reading g = certify(setup, material, gr.mesh, knockdown);

    Vec3 dlo, dhi;
    bounding_box(design, dlo, dhi);
    const double mid = 0.5 * (axis(dlo, load_axis) + axis(dhi, load_axis));
    SmoothConstraints local = base;
    local.vertex_weight.assign(design.vertices.size(), 0.0);
    std::size_t painted = 0;
    for (std::size_t v = 0; v < design.vertices.size(); ++v)
      if (axis(design.vertices[v], load_axis) > mid) {
        local.vertex_weight[v] = 1.0;
        ++painted;
      }
    const SmoothResult lr = constrained_taubin_smooth(design, p, local);
    const Reading l = certify(setup, material, lr.mesh, knockdown);

    std::printf("  brushed vertices: global %zu of %zu · local %zu of %zu "
                "(the far half from the anchor)\n",
                gr.stats.brushed_vertices, gr.stats.total_vertices, painted,
                design.vertices.size());
    std::printf("\n  brush     brushed  unbrushed  worst    effective  minfeat  "
                "drift%%  bound%%  verdict\n");
    auto brow = [&](const char* label, const SmoothStats& st, const Reading& r) {
      std::printf("  %-8s  %7zu  %9zu  %6.4f  %9.4f  %7d  %6.3f  %6.3f  %s\n",
                  label, st.brushed_vertices, st.unbrushed_vertices,
                  r.a.margin.worst_case, r.a.margin_effective, r.min_feature,
                  100.0 * st.volume_drift_fraction, 100.0 * st.volume_drift_bound,
                  verdict(r.a));
    };
    brow("global", gr.stats, g);
    brow("local", lr.stats, l);
    std::printf("\n  Local smoothing costs %.4f of margin against the global "
                "%.4f — %s.\n",
                solid.a.margin.worst_case - l.a.margin.worst_case,
                solid.a.margin.worst_case - g.a.margin.worst_case,
                (solid.a.margin.worst_case - l.a.margin.worst_case) <
                        (solid.a.margin.worst_case - g.a.margin.worst_case)
                    ? "brushing only where it is needed costs strictly less"
                    : "on this specimen the local brush is not cheaper");

    if (evidence_dir != nullptr) {
      const std::string path = std::string(evidence_dir) + "/wallmount_sweep.txt";
      std::ofstream out(path);
      out << "WallMount bracket · smoothing sweep (AE4)\n"
          << "specimen: " << mesh_path << "\n"
          << "resolution: " << res << "  traction: " << force
          << " N  infill: " << infill << "%\n"
          << "posture A (as reported): solid worst-case "
          << posture_a.solid.a.margin.worst_case << " effective "
          << posture_a.solid.a.margin_effective << " verdict "
          << verdict(posture_a.solid.a)
          << " -> strongest worst-case " << posture_a.min_worst << " effective "
          << posture_a.min_effective << "\n"
          << "posture B (at the gate): solid effective "
          << posture_b.solid.a.margin_effective << " verdict "
          << verdict(posture_b.solid.a) << " -> strongest effective "
          << posture_b.min_effective << "\n"
          << "verdict dropped (posture B): " << (verdict_dropped ? "YES" : "NO")
          << "\n"
          << "min-feature: " << solid.min_feature << " -> " << last.min_feature
          << "\n"
          << "global brush margin: " << g.a.margin.worst_case
          << "  local brush margin: " << l.a.margin.worst_case << "\n";
      std::printf("\nwrote %s\n", path.c_str());
    }
  }
  return 0;
}
