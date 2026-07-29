// test_smooth_recert_loadcase — THE RECEIPT IS REAL (bar S3, handoff
// 2026-07-28-constrained-smooth-ui).
//
// The whole differentiated value of constrained smoothing is the RECEIPT: every
// smoothed mesh is re-voxelized and re-certified, so the numbers shown next to the
// smoothed geometry describe the SMOOTHED part — never the pre-smoothing one. The
// honesty rule bites hardest when smoothing WEAKENS the part: the re-analysed margin
// must DROP, and a large enough strength must flip the acceptance verdict to
// REJECTED.
//
// PR 196/200 could not show that on a SELF-WEIGHT demo: a lighter part carries less
// of its own weight, so removing material only ever RAISES a self-weight margin. The
// missing ingredient was a DECLARED EXTERNAL LOAD — a fixed traction that does not
// fall when material is removed. This test builds that specimen IN CODE (a synthetic
// StepModel, no OCCT), drives it through the SAME build_production_loadcase the
// optimizer and the CLI analyze path use, and certifies it through the SAME
// analyze_fixed_design the run's per-rung recovery block calls:
//
//   * a COG bar in axial TENSION (a star/gear section — load-bearing ribs — anchor
//     one end, pull the other), sized so the SOLID margin sits above the 1.5 stop —
//     not the 2000x of a self-weight demo. Why a cog and not a smooth box: shrink-
//     compensated Taubin barely moves a smooth prismatic bar (a smooth surface has
//     nothing to denoise — it shifts by microns), so its re-voxelized margin would
//     not budge. What smoothing DOES remove is high-frequency convex material — the
//     ribs here, print terracing / marching-cubes stair-steps in the field;
//   * constrained Taubin smoothing at rising strength rounds the ribs off, the
//     re-voxelized section shrinks, the tensile stress F/A rises, and the re-analysed
//     margin falls — from ACCEPTED at strength 0, through a CROSSING of the 1.5 stop,
//     to REJECTED. The mounting and loaded caps are FROZEN (bit-identical);
//   * at strength 0 the receipt is byte-identical to the un-smoothed certification.
//
// It also exercises: S4 (volume drift REPORTED against the Taubin bound at every
// strength — and honestly EXCEEDING it here, because rounding real ribs moves far
// more material than the small-perturbation bound covers; the receipt shows the true
// drift, which is the signal a user needs); S5 (determinism — same mesh + strength
// twice is byte-identical); S7 (a certification solve that cannot converge is
// reported non_convergent with accepted == false — never a false receipt); and the
// min-feature HARD CONSTRAINT as the SAFETY that refuses this rib-rounding when
// enforced (it would thin the ribs below the printable floor).
//
// No third-party framework (ARCHITECTURE §4): the self-contained CHECK harness the
// other core tests use, public API only.

#include "topopt/analyze.hpp"
#include "topopt/clearance.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/fea.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/production.hpp"
#include "topopt/smooth.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>
#include <tuple>
#include <vector>

using topopt::analyze_fixed_design;
using topopt::build_production_loadcase;
using topopt::ClearanceGeometry;
using topopt::ClearanceParams;
using topopt::constrained_taubin_smooth;
using topopt::default_face_clearance;
using topopt::DirichletBC;
using topopt::FixedDesignAnalysis;
using topopt::KnockdownSpec;
using topopt::knockdown_spec_for;
using topopt::Material;
using topopt::MinimizePlasticOptions;
using topopt::NodalLoad;
using topopt::ProductionLoadCase;
using topopt::ProductionRunSetup;
using topopt::resolve_clearance_from_face;
using topopt::SimpParams;
using topopt::SmoothConstraints;
using topopt::SmoothResult;
using topopt::SmoothStats;
using topopt::StepFaceInfo;
using topopt::StepModel;
using topopt::StepSurfaceKind;
using topopt::TaubinParams;
using topopt::taubin_params_for_strength;
using topopt::taubin_volume_drift_bound;
using topopt::TriangleMesh;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;
using topopt::voxelize_onto_grid;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

namespace {

// A vertex-welding builder: identical coordinates (to 1e-6 mm) collapse to one
// shared vertex, so the produced mesh has the umbrella-Laplacian ADJACENCY the
// constrained smoother needs (an unwelded triangle soup would give every vertex
// only its own triangle's two others as "neighbours", and the smoother would not
// round an edge). Face ids are assigned per triangle for build_production_loadcase.
struct WeldedBuilder {
  StepModel model;
  std::map<std::tuple<long long, long long, long long>, int> index;

  int vertex(const Vec3& p) {
    const auto key = std::make_tuple(llround(p.x * 1e6), llround(p.y * 1e6),
                                     llround(p.z * 1e6));
    auto it = index.find(key);
    if (it != index.end()) return it->second;
    const int id = static_cast<int>(model.mesh.vertices.size());
    model.mesh.vertices.push_back(p);
    index.emplace(key, id);
    return id;
  }
  void tri(int fid, const Vec3& a, const Vec3& b, const Vec3& c) {
    model.mesh.triangles.push_back({vertex(a), vertex(b), vertex(c)});
    model.triangle_face.push_back(fid);  // what build_production_loadcase reads
  }
  // A quad a->b->c->d (outward winding by caller), subdivided along the a->b/d->c
  // direction into m strips (so the extruded lateral surface has interior vertices
  // along the axis for the smoother to move). Boundary rows weld to neighbours.
  void quad_strip(int fid, const Vec3& a, const Vec3& b, const Vec3& c,
                  const Vec3& d, int m) {
    auto lerp = [](const Vec3& p, const Vec3& q, double t) {
      return Vec3{p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t,
                  p.z + (q.z - p.z) * t};
    };
    for (int i = 0; i < m; ++i) {
      const double t0 = double(i) / m, t1 = double(i + 1) / m;
      const Vec3 a0 = lerp(a, b, t0), a1 = lerp(a, b, t1);
      const Vec3 d0 = lerp(d, c, t0), d1 = lerp(d, c, t1);
      tri(fid, a0, a1, d1);
      tri(fid, a0, d1, d0);
    }
  }
};

// A "cog" bar: a star/gear cross-section (Nteeth sharp teeth alternating r_out /
// r_in about a centroid) extruded LX along +X, capped flat at both ends. Why a cog
// and not a plain box: shrink-compensated Taubin barely moves a smooth prismatic
// bar (a smooth part has nothing to smooth — its surface shifts by microns), so its
// re-voxelized margin does not change. What smoothing DOES remove is HIGH-FREQUENCY
// CONVEX material — sharp teeth, print terracing, marching-cubes stair-steps. The
// cog makes that concrete and load-bearing: the teeth carry axial tension (F/A), and
// rounding them off shrinks the cross-section, so the tensile stress rises and the
// re-analysed margin falls — the honest weakening the receipt must report. The core
// stays fat (min-feature is never violated), so smoothing runs to full strength.
//
// Faces: 0 = -X cap (anchor), 1 = +X cap (load), 2 = the toothed lateral surface.
StepModel make_cog_bar(double lx, double r_out, double r_in, int teeth, int m_axis) {
  WeldedBuilder b;
  const double cy = r_out + 1.0, cz = r_out + 1.0;  // keep the section in +Y,+Z
  const int np = 2 * teeth;                          // polygon vertices (tip,valley,...)
  auto poly = [&](int k, double x) {
    const double ang = 2.0 * M_PI * k / np;
    const double r = (k % 2 == 0) ? r_out : r_in;    // even = tooth tip
    return Vec3{x, cy + r * std::cos(ang), cz + r * std::sin(ang)};
  };
  // Lateral surface (face 2): one axial strip per polygon edge, outward winding.
  for (int k = 0; k < np; ++k) {
    const Vec3 p0 = poly(k, 0.0), p1 = poly((k + 1) % np, 0.0);
    const Vec3 q0 = poly(k, lx), q1 = poly((k + 1) % np, lx);
    // outward: going around the section CCW (in +Y,+Z) with +X extrusion, the
    // outward face is p0 -> q0 -> q1 -> p1.
    b.quad_strip(2, p0, q0, q1, p1, m_axis);
  }
  // End caps: triangle fan from the centroid. -X cap (face 0, normal -X) winds so
  // its outward normal is -X; +X cap (face 1, normal +X) the reverse.
  const Vec3 c0{0.0, cy, cz}, c1{lx, cy, cz};
  for (int k = 0; k < np; ++k) {
    const Vec3 a0 = poly(k, 0.0), a1 = poly((k + 1) % np, 0.0);
    b.tri(0, c0, a1, a0);  // -X outward (normal -X)
    const Vec3 e0 = poly(k, lx), e1 = poly((k + 1) % np, lx);
    b.tri(1, c1, e0, e1);  // +X outward (normal +X)
  }
  b.model.face_count = 3;
  b.model.faces.resize(3);
  auto plane = [&](int fid, Vec3 nrm, Vec3 origin) {
    b.model.faces[fid].kind = StepSurfaceKind::Plane;
    b.model.faces[fid].plane_normal = nrm;
    b.model.faces[fid].plane_origin = origin;
  };
  plane(0, Vec3{-1, 0, 0}, Vec3{0.0, cy, cz});
  plane(1, Vec3{1, 0, 0}, Vec3{lx, cy, cz});
  b.model.faces[2].kind = StepSurfaceKind::Other;  // lateral: not a freeze face
  b.model.solid_count = 1;
  return b.model;
}

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

// The freeze regions the analyze path resolves for a loadcase: the anchor and the
// load faces (both structural — keep the clamp and the traction attached to
// bit-identical solid). Face slab predicates via the shared resolver.
std::vector<ClearanceGeometry> freeze_ends(const StepModel& model, double spacing) {
  std::vector<ClearanceGeometry> out;
  for (int fid : {0, 1}) {
    ClearanceParams p = default_face_clearance();
    p.slab_depth_mm = spacing;
    const ClearanceGeometry g = resolve_clearance_from_face(model, fid, p);
    if (g.valid) out.push_back(g);
  }
  return out;
}

// One re-certification of the (optionally smoothed) bar under the FIXED external
// traction, exactly as analyze_job's loadcase path does: smooth -> re-voxelize onto
// the model grid -> carry Fixture/Load tags -> analyze_fixed_design.
struct Recert {
  FixedDesignAnalysis a;
  SmoothStats stats;
  TriangleMesh smoothed;
};

Recert recertify(const StepModel& model, const ProductionRunSetup& setup,
                 const Material& material, double strength, bool enforce_min_feature) {
  Recert r;
  const VoxelGrid& model_grid = setup.grid;

  TriangleMesh design_mesh = model.mesh;
  if (strength > 0.0) {
    SmoothConstraints c;
    c.freeze_regions = freeze_ends(model, model_grid.spacing);
    c.min_feature_grid = &model_grid;
    c.enforce_min_feature = enforce_min_feature;
    SmoothResult sr = constrained_taubin_smooth(
        model.mesh, taubin_params_for_strength(strength), c);
    design_mesh = std::move(sr.mesh);
    r.stats = sr.stats;
  }
  r.smoothed = design_mesh;

  VoxelGrid design_grid = voxelize_onto_grid(design_mesh, model_grid);
  for (std::size_t i = 0; i < design_grid.tags.size(); ++i) {
    if (model_grid.tags[i] == VoxelTag::Fixture &&
        design_grid.tags[i] != VoxelTag::Empty)
      design_grid.tags[i] = VoxelTag::Fixture;
    else if (model_grid.tags[i] == VoxelTag::Load)
      design_grid.tags[i] = VoxelTag::Load;  // keep the traction surface solid
  }
  std::vector<double> density(design_grid.voxel_count(), 0.0);
  for (std::size_t i = 0; i < density.size(); ++i)
    if (design_grid.tags[i] != VoxelTag::Empty) density[i] = 1.0;

  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;
  const Vec3 gdir = setup.options.gravity_direction;
  const double gn = std::sqrt(gdir.x * gdir.x + gdir.y * gdir.y + gdir.z * gdir.z);
  const Vec3 build_dir =
      gn > 0 ? Vec3{-gdir.x / gn, -gdir.y / gn, -gdir.z / gn} : Vec3{0, 0, 1};
  const KnockdownSpec knockdown = knockdown_spec_for(setup.options);
  const bool load_path_ok = topopt::load_path_connected(design_grid, density, 0.5);
  const double part_solid = static_cast<double>(model_grid.solid_count());

  r.a = analyze_fixed_design(
      design_grid, params, density, setup.bcs, setup.options.external_loads,
      material, build_dir, setup.options.simp.cg_tolerance,
      setup.options.simp.cg_max_iterations, setup.options.simp.solver,
      setup.options.margin_stop, knockdown, load_path_ok, part_solid);
  return r;
}

}  // namespace

int main() {
  const Material material = fdm_material();

  // A cog bar in axial tension: an 8-tooth star section (r_out 12, r_in 8 mm)
  // extruded 48 mm, voxelized at resolution 48 -> 1 mm spacing so the 4 mm teeth are
  // several voxels tall and their rounding registers.
  const double LX = 48.0;
  const int RES = 48;
  const StepModel model = make_cog_bar(LX, /*r_out=*/10.0, /*r_in=*/8.0,
                                       /*teeth=*/10, /*m_axis=*/24);

  // Axial +X traction on the +X cap (face 1); anchor the -X cap (face 0). Sized
  // (empirically) so the SOLID margin sits above the 1.5 acceptance stop and the
  // weakening sweep crosses it mid-way.
  const double kAxialForceN = 3550.0;
  const bool kEnforceMinFeature = false;  // sweep: probe the full weakening curve
  ProductionLoadCase lc;
  lc.anchor_face_ids = {0};
  {
    ProductionLoadCase::LoadGroup g;
    g.face_ids = {1};
    g.force = Vec3{kAxialForceN, 0.0, 0.0};
    lc.load_groups.push_back(g);
  }
  lc.minimize_plastic = false;  // a single fixed design, not a ladder
  const ProductionRunSetup setup = build_production_loadcase(model, RES, lc);
  CHECK(!setup.options.external_loads.empty(),
        "the load face tags voxels -> a real external traction");
  CHECK(setup.options.margin_stop == 1.5,
        "loadcase gate uses the production 1.5 margin stop");

  // ── the SOLID certification (strength 0 = identity) ──────────────────────────
  const Recert solid = recertify(model, setup, material, 0.0, true);
  CHECK(!solid.a.non_convergent, "the solid bar certification converges");
  CHECK(solid.a.max_von_mises > 0.0, "the loaded bar carries real tensile stress");
  const double m_solid = solid.a.margin.worst_case;
  std::fprintf(stderr,
               "[S3] SOLID: vm=%.3f MPa  margin=%.4f  effective=%.4f  accepted=%d\n",
               solid.a.max_von_mises, m_solid, solid.a.margin_effective,
               solid.a.accepted ? 1 : 0);
  CHECK(solid.a.accepted, "the solid bar is ACCEPTED (margin >= 1.5)");
  CHECK(m_solid > 1.5 && m_solid < 3.0,
        "the solid margin sits near the stop (not a 2000x self-weight number)");

  // ── the sweep: rising strength rounds the ribs, the margin drops ─────────────
  const std::vector<double> strengths = {0.0, 0.05, 0.10, 0.20, 0.40, 1.00};
  std::vector<double> margins(strengths.size());
  std::vector<bool> accepted(strengths.size());
  std::vector<double> drifts(strengths.size(), 0.0), bounds(strengths.size(), 0.0);
  std::fprintf(stderr, "[S3] strength  pairs  vm(MPa)  margin   accepted  "
                       "drift%%  bound%%\n");
  for (std::size_t i = 0; i < strengths.size(); ++i) {
    const Recert r =
        recertify(model, setup, material, strengths[i], kEnforceMinFeature);
    margins[i] = r.a.margin.worst_case;
    accepted[i] = r.a.accepted;
    if (strengths[i] > 0.0) {
      drifts[i] = r.stats.volume_drift_fraction;
      bounds[i] = r.stats.volume_drift_bound;
    }
    std::fprintf(stderr,
                 "[S3]   %.2f     %3d   %6.3f  %6.4f     %d      %.3f   %.3f\n",
                 strengths[i], r.stats.applied_pairs, r.a.max_von_mises,
                 margins[i], accepted[i] ? 1 : 0, drifts[i] * 100.0,
                 bounds[i] * 100.0);
    // S4 — volume drift is REPORTED against the stated Taubin bound at every
    // strength. The bound is a small-perturbation bound: it holds for DENOISING a
    // smooth surface (proven on the sphere/variant in test_smooth), where the
    // enclosed volume lives in the pass-band modes. Rounding off REAL load-bearing
    // ribs moves far more material — a high-frequency mode the smoother attenuates —
    // so the measured drift EXCEEDS the bound here, and that is exactly the honest
    // signal the receipt surfaces ("this was aggressive, not gentle denoising"). So
    // the assertion is that the drift is reported and the bound is the correct value
    // — NOT that this aggressive case sits under it.
    if (strengths[i] > 0.0) {
      CHECK(drifts[i] > 0.0, "S4: a non-zero volume drift is measured and reported");
      CHECK(bounds[i] ==
                taubin_volume_drift_bound(taubin_params_for_strength(strengths[i])),
            "S4: the reported bound is taubin_volume_drift_bound(params)");
    }
  }
  const std::size_t last = strengths.size() - 1;

  // S3a — strength 0 reproduces the solid certification exactly (identity).
  CHECK(margins[0] == m_solid && accepted[0] == solid.a.accepted,
        "S3: strength 0 is byte-identical to the un-smoothed certification");

  // S3b — the margin falls MONOTONICALLY as strength rises (weakening, no spurious
  // strengthening). A tiny tolerance absorbs re-voxelization quantization noise
  // between two nearly-equal smoothed meshes at the high-strength plateau.
  bool monotone = true;
  for (std::size_t i = 1; i < strengths.size(); ++i)
    if (margins[i] > margins[i - 1] + 5e-3) monotone = false;
  CHECK(monotone, "S3: the re-analysed margin is non-increasing in strength");

  // S3c — smoothing MEASURABLY weakens the part (the receipt shows a lower margin).
  CHECK(margins[last] < m_solid - 1e-2,
        "S3: the smoothed part is measurably weaker than the solid (margin drops)");

  // S3d — a large enough strength flips the verdict to REJECTED, below 1.5, and the
  // solid was ACCEPTED, so it is a true state change driven by smoothing.
  CHECK(!accepted[last], "S3: max strength flips the verdict to REJECTED");
  CHECK(margins[last] < 1.5,
        "S3: the REJECTED margin is genuinely below the 1.5 stop");
  CHECK(accepted[0] && !accepted[last],
        "S3: ACCEPTED -> REJECTED is a true flip driven by smoothing");

  // S3e — the flip has a CROSSING: at least one low strength is still ACCEPTED and a
  // higher strength is REJECTED, so the receipt shows a graceful decline through the
  // gate, not a cliff between "solid" and "gone".
  bool crossing = false;
  for (std::size_t i = 1; i < strengths.size(); ++i)
    if (accepted[i - 1] && !accepted[i]) crossing = true;
  CHECK(crossing,
        "S3: the sweep crosses the gate (an accepted strength above a rejected one)");

  // ── The min-feature HARD CONSTRAINT is the safety: with it ENFORCED, the SAME
  // full-strength smoothing that collapsed the margin above is REFUSED/CAPPED,
  // because rounding the ribs would thin them below the printable floor. So a user
  // who leaves the (default) constraint on never reaches the REJECTED state — the
  // constraint stops the weakening before the re-cert has to. The receipt reports
  // the cap (applied < requested) honestly. (The re-analysed margin of the capped
  // result is therefore at or near the solid's — the weakening never happens.)
  {
    const Recert guarded = recertify(model, setup, material, 1.0, /*min_feature=*/true);
    CHECK(guarded.stats.applied_pairs < guarded.stats.requested_pairs,
          "S2/S3: min-feature enforcement CAPS the rib-rounding (applied < requested)");
    CHECK(guarded.stats.min_feature_limited,
          "S2/S3: the receipt records that min-feature limited the smoothing");
    CHECK(guarded.a.margin.worst_case > margins[last] + 1e-2,
          "S2/S3: the guarded (capped) part is stronger than the unguarded collapse");
    std::fprintf(stderr,
                 "[S3] min-feature ON @1.0: applied=%d/%d limited=%d margin=%.4f "
                 "accepted=%d\n",
                 guarded.stats.applied_pairs, guarded.stats.requested_pairs,
                 guarded.stats.min_feature_limited ? 1 : 0,
                 guarded.a.margin.worst_case, guarded.a.accepted ? 1 : 0);
  }

  // ── S5: determinism — same mesh + strength twice is byte-identical ───────────
  {
    const Recert x = recertify(model, setup, material, 0.40, kEnforceMinFeature);
    const Recert y = recertify(model, setup, material, 0.40, kEnforceMinFeature);
    bool verts_identical = x.smoothed.vertices.size() == y.smoothed.vertices.size();
    for (std::size_t i = 0; verts_identical && i < x.smoothed.vertices.size(); ++i)
      verts_identical = x.smoothed.vertices[i].x == y.smoothed.vertices[i].x &&
                        x.smoothed.vertices[i].y == y.smoothed.vertices[i].y &&
                        x.smoothed.vertices[i].z == y.smoothed.vertices[i].z;
    CHECK(verts_identical, "S5: the smoothed mesh is byte-identical run-to-run");
    CHECK(x.a.margin.worst_case == y.a.margin.worst_case &&
              x.a.max_von_mises == y.a.max_von_mises &&
              x.a.accepted == y.a.accepted,
          "S5: the re-analysed numbers are byte-identical run-to-run");
  }

  // ── S7: a certification solve that cannot converge is reported, NEVER a false
  // receipt. Force it with a 1-iteration CG cap on the same problem: the solve
  // misses tolerance, analyze_fixed_design sets non_convergent and forces
  // accepted == false (handoff 2026-07-27-nonconvergence-rejection) rather than
  // returning a plausible-but-wrong margin. This is the boundary the UI surfaces
  // as "couldn't re-certify at this strength — try lower".
  {
    VoxelGrid dg = setup.grid;
    std::vector<double> density(dg.voxel_count(), 0.0);
    for (std::size_t i = 0; i < density.size(); ++i)
      if (dg.tags[i] != VoxelTag::Empty) density[i] = 1.0;
    SimpParams params;
    params.youngs_modulus = material.youngs_modulus_mpa;
    params.poisson = material.poisson;
    params.penalty = 3.0;
    const KnockdownSpec knockdown = knockdown_spec_for(setup.options);
    const FixedDesignAnalysis nc = analyze_fixed_design(
        dg, params, density, setup.bcs, setup.options.external_loads, material,
        Vec3{0, 0, 1}, setup.options.simp.cg_tolerance, /*cg_max_iterations=*/1,
        setup.options.simp.solver, setup.options.margin_stop, knockdown,
        /*load_path_ok=*/true, static_cast<double>(dg.solid_count()));
    CHECK(nc.non_convergent, "S7: a capped solve is reported non_convergent");
    CHECK(!nc.accepted,
          "S7: a non-convergent certification is NEVER accepted (no false receipt)");
  }

  // ── device-real evidence dump (opt-in): write the exact cog specimen as an STL
  // so the compiled topopt-cli can re-certify it under a hand-authored loadcase job
  // (material "PLA" == this test's material), and print the imported pseudo-face
  // ids + their mean x so the job's anchor (min-x cap) and load (max-x cap) faces
  // can be named. Off by default -> the test is pure and writes nothing.
  if (const char* dir = std::getenv("TOPOPT_S3_EVIDENCE_DIR")) {
    const std::string stl = std::string(dir) + "/cog_bar.stl";
    topopt::write_stl_file(stl, model.mesh);
    std::fprintf(stderr, "[S3] wrote specimen STL: %s (force=%.0f N, PLA)\n", stl.c_str(),
                 kAxialForceN);
    const StepModel reimported = topopt::import_part_file_resolved(stl);
    std::fprintf(stderr, "[S3] re-imported pseudo-faces: %d\n", reimported.face_count);
    std::vector<double> sx(reimported.face_count, 0.0);
    std::vector<int> cnt(reimported.face_count, 0);
    for (std::size_t t = 0; t < reimported.triangle_face.size(); ++t) {
      const int f = reimported.triangle_face[t];
      const auto& tri = reimported.mesh.triangles[t];
      const double mx = (reimported.mesh.vertices[tri[0]].x +
                         reimported.mesh.vertices[tri[1]].x +
                         reimported.mesh.vertices[tri[2]].x) / 3.0;
      sx[f] += mx;
      cnt[f]++;
    }
    int fmin = 0, fmax = 0;
    for (int f = 0; f < reimported.face_count; ++f) {
      const double mean = cnt[f] ? sx[f] / cnt[f] : 0.0;
      std::fprintf(stderr, "[S3]   face %d: tris=%d mean_x=%.2f\n", f, cnt[f], mean);
      if (cnt[f] && mean < (cnt[fmin] ? sx[fmin] / cnt[fmin] : 1e9)) fmin = f;
      if (cnt[f] && mean > (cnt[fmax] ? sx[fmax] / cnt[fmax] : -1e9)) fmax = f;
    }
    std::fprintf(stderr, "[S3] anchor(min-x cap)=face %d  load(max-x cap)=face %d\n",
                 fmin, fmax);
  }

  std::fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
  if (g_failures == 0) std::fprintf(stderr, "PASS: smooth_recert_loadcase\n");
  return g_failures == 0 ? 0 : 1;
}
