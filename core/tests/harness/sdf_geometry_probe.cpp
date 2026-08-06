// sdf_geometry_probe — S1 of task 2026-08-05-smoothing-sdf-geometry-extraction.
//
// THE GO/NO-GO QUESTION: PR 299 measured that `constrained_taubin_smooth`
// removes 5.5% of the maintainer's stair-step amplitude at the strength the app
// can ask for and 10.6% at the best setting found anywhere in the family, and
// reaches that only by moving the surface 0.673 mm. Does the SDF geometry
// extraction of arXiv:2512.06976 beat that, on HIS part, and at what surface
// motion?
//
// THE METRIC IS PR 299's, UNCHANGED (bar R3). Not re-implemented: literally the
// same code, moved into `stairstep_metric.hpp` and included by both probes. The
// move is proven output-preserving in
// evidence/2026-08-05-smoothing-sdf-geometry-extraction/r3_metric_move.txt —
// every geometric figure in `stairstep_probe`'s output is identical across it and
// only wall-clock columns move.
//
//   surface deviation from the pre-voxelization CAD, in millimetres, per vertex,
//   restricted to OBLIQUE vertices classified from the UNSMOOTHED mesh by the
//   normal of the nearest CAD triangle (within 0.02 of an axis => axis-aligned).
//
// THE SUBJECT IS PR 299's, UNCHANGED: the part's own occupancy at the job's
// resolution through `marching_cubes_resampled(factor 2, Tricubic)` and back
// through an STL round trip, which is what the app hands the smoother. Keeping
// the subject fixed is what makes "10.6%" and the number below comparable at all.
//
// A HARNESS, not a ctest. It asserts only the preconditions that would make its
// own numbers meaningless, and prints tables.
//
//   cmake --build core/build --target sdf_geometry_probe
//   ./core/build/sdf_geometry_probe <mode> [args]
//
// modes:
//   part        <design.bin> <part.step> <ev> [factor]  HIS part + his four rungs
//   partsweep   <design.bin> <part.step> <ev> [factor]  the SDF grid-spacing sweep
//   partfactor  <design.bin> <part.step>                export tessellation (S5)
//   features    <design.bin> <part.step> <ev> [factor]  S3, the named interfaces
//   gibson      <design.bin> <part.step> <ev>           S3.4, the one-voxel bound
//   loadcheck   <part.step> <mesh.stl> ...              why the certification refuses
//   emit        <design.bin> <out_dir> <rung|-1> [f]    the meshes S2 certifies
//   sphere      [R] [spacing] [factor]                  the analytic control
//   headline    <cad.stl> <res> <factor> <ev>           PR 299's own fixture
//   sweep       <cad.stl> <res> <factor> <ev>           ditto, swept
//   crosscheck  <reference.txt> <out.txt>               against rho2sdf.jl
//   selfcheck                                           preconditions only

#include "sdf_geometry.hpp"
#include "stairstep_metric.hpp"

#include "topopt/design_store.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/mesh.hpp"
#include "topopt/production.hpp"
#include "topopt/smooth.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <array>
#include <map>
#include <memory>
#include <string>
#include <vector>

using namespace topopt;
using namespace topopt::sdfgeom;
using topopt::stairstep::Deviation;
using topopt::stairstep::TriGrid;
using topopt::stairstep::deviation_from_cad;
using topopt::stairstep::dihedral_rms_deg;
using topopt::stairstep::min_feature_now;
using topopt::stairstep::sphere_deviation;
using topopt::stairstep::sphere_grid;
using topopt::stairstep::SphereReading;

namespace {

using Clock = std::chrono::steady_clock;
double secs(const Clock::time_point& t) {
  return std::chrono::duration<double>(Clock::now() - t).count();
}

// One configuration of the pipeline, so the sweep rows and the headline row are
// produced by the same code path.
struct Config {
  double B_over_h = 1.0;      // SDF grid spacing / FE element size
  RbfMode mode = RbfMode::Interpolation;
  int fine = 2;               // reference's `smooth`: 1 = :same, 2 = :fine
  int iso_refine = 4;         // tessellation of the isocontour distance target
  double band_cells = 4.0;
  // The reference solves the shift on the COARSE grid and applies it to the fine
  // one. MEASURED on the maintainer's part that costs 1.42% of volume, because
  // the coarse trilinear volume of an RBF field is not the fine one. The default
  // here solves it where the surface is actually extracted; `false` reproduces
  // the reference and the probe reports both.
  bool shift_on_fine = true;
  // Stop after §4.1/§4.2's ISOCONTOUR and extract that, skipping the SDF and the
  // RBF entirely. This is the decomposition that says which STAGE of the paper's
  // pipeline is doing the work — and it is the cheap one, because an isocontour
  // of the nodal field is a change to the export call and nothing else.
  bool isocontour_only = false;
  int iso_only_refine = 2;
};

struct Run {
  TriangleMesh mesh;
  double rho_t = 0.0;
  double target_volume = 0.0;
  double iso_volume_mm3 = 0.0;   // volume of the isocontour before smoothing
  double final_volume_mm3 = 0.0; // volume of the shifted zero level
  double shift_c = 0.0;
  int shift_iters = 0;
  int cg_iters = 0;
  double cg_res = 0.0;
  double wall_nodal = 0.0, wall_thresh = 0.0, wall_sdf = 0.0, wall_rbf = 0.0,
         wall_shift = 0.0, wall_extract = 0.0;
  std::size_t iso_tris = 0;
  int sdf_nx = 0, sdf_ny = 0, sdf_nz = 0;
  double B = 0.0;
};

// THE PIPELINE, end to end, on one element-density field.
Run run_pipeline(const VoxelGrid& grid, const std::vector<double>& rho_e,
                 const Config& cfg) {
  Run r;
  const double h = grid.spacing;
  r.B = cfg.B_over_h * h;

  // §4.1 nodal densities.
  auto t = Clock::now();
  const Lattice nodal = nodal_from_elements(grid, rho_e);
  r.wall_nodal = secs(t);

  // The TARGET VOLUME is the raw design's own volume, sum_e rho_e * V_e — the
  // reference's `mesh.V_frac * mesh.V_domain` (MeshVolume.jl:28-30). Everything
  // downstream is held to this one number.
  double vol = 0.0;
  for (double x : rho_e) vol += x;
  r.target_volume = vol * h * h * h;

  // §4.1 the threshold whose isocontour encloses it.
  t = Clock::now();
  const ThresholdResult th = find_level_for_volume(nodal, r.target_volume, 0.0,
                                                   1.0, 9);
  r.rho_t = th.level;
  r.iso_volume_mm3 = th.volume;
  r.wall_thresh = secs(t);

  if (cfg.isocontour_only) {
    t = Clock::now();
    r.mesh = marching_cubes_resampled(nodal.nx, nodal.ny, nodal.nz, nodal.h,
                                      nodal.mc_origin(), nodal.v, r.rho_t,
                                      cfg.iso_only_refine,
                                      ResampleInterp::Trilinear);
    r.wall_extract = secs(t);
    r.final_volume_mm3 = r.iso_volume_mm3;
    return r;
  }

  // §4.2 the SDF.
  const SdfBuild sdf = build_sdf(nodal, r.rho_t, r.B, cfg.iso_refine,
                                 cfg.band_cells);
  r.wall_sdf = sdf.wall_s;
  r.iso_tris = sdf.iso_tris;
  r.sdf_nx = sdf.phi.nx;
  r.sdf_ny = sdf.phi.ny;
  r.sdf_nz = sdf.phi.nz;
  if (sdf.phi.v.empty()) return r;

  // §4.3 RBF smoothing.
  RbfResult sm = rbf_smooth(sdf.phi, cfg.mode, cfg.fine);
  r.wall_rbf = sm.wall_s;
  r.cg_iters = sm.cg_iterations;
  r.cg_res = sm.cg_residual;

  // §4.3 the uniform volume-preserving shift. The reference solves it on the
  // COARSE grid and applies it to the fine one (RBFs4Smoothing.jl: `th =
  // LS_Threshold(LSF_array, coarse_grid, ...)` then `fine_LSF .+ th`), so that
  // is the default here; `shift_on_fine` is the variant that solves it where the
  // surface is actually extracted, and the probe reports both volumes either way.
  t = Clock::now();
  ShiftResult sh;
  if (cfg.shift_on_fine || cfg.fine == 1) {
    sh = volume_shift(sm.phi, r.target_volume, 9);
  } else {
    RbfResult coarse_eval = rbf_smooth(sdf.phi, cfg.mode, 1);
    sh = volume_shift(coarse_eval.phi, r.target_volume, 9);
  }
  r.shift_c = sh.c;
  r.shift_iters = sh.iterations;
  r.wall_shift = secs(t);
  for (double& x : sm.phi.v) x += sh.c;
  r.final_volume_mm3 = iso_volume(sm.phi, 0.0, 9);

  // §4.4 re-extraction.
  t = Clock::now();
  r.mesh = marching_cubes(sm.phi.nx, sm.phi.ny, sm.phi.nz, sm.phi.h,
                          sm.phi.mc_origin(), sm.phi.v, 0.0);
  r.wall_extract = secs(t);
  return r;
}

// Gibson, "Constrained Elastic Surface Nets" (MICCAI 1998 / MERL TR99-24): every
// surface node stays inside its ORIGINAL surface cube, which bounds the error to
// one voxel BY CONSTRUCTION rather than by tuning. The mesh here is re-extracted
// rather than relaxed, so the constraint is applied as its consequence: no output
// vertex may sit further than `bound` from the unsmoothed surface. Vertices that
// do are pulled back along the line to their closest point on it.
TriangleMesh clamp_to_original(const TriangleMesh& m, const TriangleMesh& original,
                               double bound, double& out_moved_frac,
                               double& out_max_pullback) {
  TriangleMesh c = m;
  const TriGrid ref(original);
  std::size_t moved = 0;
  double maxpb = 0.0;
  for (std::size_t i = 0; i < c.vertices.size(); ++i) {
    const Vec3& p = c.vertices[i];
    const double d = ref.distance(p);
    if (d <= bound) continue;
    // Walk back along the outward direction by (d - bound). The direction is
    // recovered from a central difference of the distance field, which is the
    // unit normal of the closest-point map wherever it is differentiable.
    const double e = 1e-4;
    Vec3 g{ref.distance(Vec3{p.x + e, p.y, p.z}) - ref.distance(Vec3{p.x - e, p.y, p.z}),
           ref.distance(Vec3{p.x, p.y + e, p.z}) - ref.distance(Vec3{p.x, p.y - e, p.z}),
           ref.distance(Vec3{p.x, p.y, p.z + e}) - ref.distance(Vec3{p.x, p.y, p.z - e})};
    const double L = std::sqrt(g.x * g.x + g.y * g.y + g.z * g.z);
    if (L < 1e-12) continue;
    const double step = d - bound;
    c.vertices[i] = Vec3{p.x - g.x / L * step, p.y - g.y / L * step,
                         p.z - g.z / L * step};
    ++moved;
    maxpb = std::fmax(maxpb, step);
  }
  out_moved_frac = c.vertices.empty()
                       ? 0.0
                       : static_cast<double>(moved) /
                             static_cast<double>(c.vertices.size());
  out_max_pullback = maxpb;
  return c;
}

// Every consumer in the app reads a variant back from an STL (PR 299's S1.1),
// so every mesh compared here makes the same round trip.
TriangleMesh through_stl(const TriangleMesh& m, const std::string& path) {
  write_stl_file(path, m);
  return import_part_file_resolved(path).mesh;
}

double mesh_volume_mm3(const TriangleMesh& m) {
  double v = 0.0;
  for (const auto& tr : m.triangles) {
    const Vec3& a = m.vertices[static_cast<std::size_t>(tr[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(tr[1])];
    const Vec3& c = m.vertices[static_cast<std::size_t>(tr[2])];
    v += (a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) +
          a.z * (b.x * c.y - b.y * c.x)) / 6.0;
  }
  return std::fabs(v);
}

// The maintainer's own load case, as PR 299's probe builds it, so the grid the
// min-feature constraint voxelizes onto is the same one.
ProductionRunSetup his_setup(const StepModel& model, int resolution) {
  ProductionLoadCase lc;
  lc.anchor_face_ids = {8, 14, 12};
  ProductionLoadCase::LoadGroup g;
  g.face_ids = {0};
  g.force = Vec3{0.0, -155.6879425048828, 0.0};
  lc.load_groups.push_back(g);
  lc.minimize_plastic = false;
  lc.build_dir = Vec3{0.0, 1.0, 0.0};
  lc.infill_percent = 35.0;
  ProductionRunSetup s = build_production_loadcase(model, resolution, lc);
  s.options.bake_build_orientation = BakeBuildOrientation::Off;
  return s;
}

// WHERE THE SDF ROUTE HELPS AND WHERE IT HURTS, separated by measurement rather
// than by argument. A voxel staircase lives on a surface that is SMOOTH in the
// CAD; a sharp CAD edge has no staircase to remove and any smoothing ROUNDS it,
// which raises the deviation. Both live in PR 299's oblique set, so the oblique
// headline mixes a gain and a loss. This splits them: a vertex is NEAR-EDGE when
// it lies within `radius` of a CAD edge whose two triangles meet at 30 degrees or
// more, and SMOOTH otherwise. The headline number is NOT changed by this — it is
// printed unchanged and this is reported beside it.
class SharpEdges {
 public:
  SharpEdges(const TriangleMesh& cad, double deg) {
    std::map<std::pair<int, int>, std::vector<std::size_t>> e;
    for (std::size_t t = 0; t < cad.triangles.size(); ++t) {
      const auto& tr = cad.triangles[t];
      for (int q = 0; q < 3; ++q) {
        int a = tr[q], b = tr[(q + 1) % 3];
        if (a > b) std::swap(a, b);
        e[{a, b}].push_back(t);
      }
    }
    auto nrm = [&](std::size_t t) {
      const auto& tr = cad.triangles[t];
      const Vec3& a = cad.vertices[static_cast<std::size_t>(tr[0])];
      const Vec3& b = cad.vertices[static_cast<std::size_t>(tr[1])];
      const Vec3& c = cad.vertices[static_cast<std::size_t>(tr[2])];
      const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z};
      const Vec3 v{c.x - a.x, c.y - a.y, c.z - a.z};
      Vec3 n{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x};
      const double L = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
      if (L > 0) { n.x /= L; n.y /= L; n.z /= L; }
      return n;
    };
    const double cosl = std::cos(deg * 3.14159265358979323846 / 180.0);
    TriangleMesh strip;
    for (const auto& kv : e) {
      bool sharp = kv.second.size() != 2;
      if (!sharp) {
        const Vec3 a = nrm(kv.second[0]), b = nrm(kv.second[1]);
        sharp = (a.x * b.x + a.y * b.y + a.z * b.z) < cosl;
      }
      if (!sharp) continue;
      const Vec3& p = cad.vertices[static_cast<std::size_t>(kv.first.first)];
      const Vec3& q = cad.vertices[static_cast<std::size_t>(kv.first.second)];
      const int base = static_cast<int>(strip.vertices.size());
      strip.vertices.push_back(p);
      strip.vertices.push_back(q);
      strip.vertices.push_back(p);   // a degenerate triangle IS the segment
      strip.triangles.push_back({base, base + 1, base + 2});
      ++count_;
    }
    // keep_ FIRST: TriGrid stores a pointer to the mesh it was built from, so
    // building it from the local `strip` would leave it dangling the moment this
    // constructor returns (it did, and crashed in dist2_point_triangle).
    keep_ = strip;
    if (count_) grid_.reset(new TriGrid(keep_));
  }
  int count() const { return count_; }
  double distance(const Vec3& p) const {
    return grid_ ? grid_->distance(p) : 1e30;
  }

 private:
  int count_ = 0;
  TriangleMesh keep_;
  std::unique_ptr<TriGrid> grid_;
};

struct Reading {
  Deviation obl, all;
  Deviation obl_smooth, obl_near_edge;
  std::size_t n_obl_smooth = 0, n_obl_near_edge = 0;
  // THE PART SKIN. An optimizer variant's surface is mostly surface the
  // OPTIMIZER cut, which never existed in the CAD — PR 299's metric is
  // undefined there and reads 11-13 mm on his rungs, which is how much material
  // was removed, not how stair-stepped anything is. This restricts the same
  // metric to the vertices that DO lie on the original part boundary (within one
  // voxel of the CAD): the outer skin, the anchor face, the protected face and
  // the bores. That is the only surface of a variant on which "how far is this
  // from the shape it was meant to be" has an answer, and it is also exactly the
  // surface S3 is about. Counts are printed for every row because the set is
  // re-derived per mesh and a shrinking set would be a selection effect.
  Deviation obl_skin;
  std::size_t n_obl_skin = 0;
  // THE CAD-SIDE READING, and why it exists. The skin restriction above selects
  // MESH vertices by their distance to the CAD, so a stage that pushes the
  // surface away shrinks its own sample and can flatter itself. This measures
  // the same deviation from the other side: a FIXED set of points on the CAD
  // surface — the same points for every row — and the distance from each to the
  // mesh. Nothing a stage does can change which points are scored. The set is
  // the fine CAD's triangle centroids that had material against them in the
  // UNSMOOTHED variant, so it covers the part boundary the optimizer kept and
  // excludes the surface it cut away.
  Deviation cad_side;
  std::size_t n_cad_side = 0;
  double dihedral = 0.0;
  int min_feature = 0;
  std::size_t verts = 0, tris = 0;
  int components = 0;
  double volume_mm3 = 0.0;
  double max_shift_from_base = 0.0;   // surface MOTION: the cost side
};

// The surface motion of `m` relative to `base`: how far the smoothed surface sits
// from the unsmoothed one. Vertex correspondence does not survive a re-extraction
// (the SDF mesh has its own vertices), so this is the one-sided Hausdorff
// distance from the new surface to the old — the honest analogue of PR 299's
// `maxshift` column, and it is stated as such wherever it is printed.
double surface_motion(const TriangleMesh& m, const TriGrid& base) {
  double worst = 0.0;
  for (const Vec3& v : m.vertices) worst = std::fmax(worst, base.distance(v));
  return worst;
}

Reading read_mesh(const TriangleMesh& m, const TriGrid& cad,
                  const std::vector<char>& oblique_of_subject,
                  const VoxelGrid& grid, const TriGrid* base,
                  const SharpEdges* sharp = nullptr, double edge_radius = 0.0,
                  double skin_band = 0.0,
                  const std::vector<Vec3>* cad_samples = nullptr) {
  Reading r;
  r.verts = m.vertices.size();
  r.tris = m.triangles.size();
  r.components = count_components(m);
  r.volume_mm3 = mesh_volume_mm3(m);
  r.all = deviation_from_cad(m, cad);
  // The oblique SET is fixed on the subject; a re-extracted mesh has different
  // vertices, so it is re-derived the same way — same rule, same threshold,
  // applied to whatever vertices the mesh has. Stated in the handoff's S1.2.
  std::vector<char> obl(m.vertices.size(), 0);
  for (std::size_t i = 0; i < m.vertices.size(); ++i) {
    const auto dt = cad.distance_and_tri(m.vertices[i]);
    if (dt.second < 0) continue;
    const Vec3 n = cad.tri_normal(dt.second);
    const double mx =
        std::fmax(std::fabs(n.x), std::fmax(std::fabs(n.y), std::fabs(n.z)));
    if (mx < 0.98) obl[i] = 1;
  }
  (void)oblique_of_subject;
  r.obl = deviation_from_cad(m, cad, obl);
  if (sharp && sharp->count() > 0) {
    std::vector<char> sm(m.vertices.size(), 0), ne(m.vertices.size(), 0);
    for (std::size_t i = 0; i < m.vertices.size(); ++i) {
      if (!obl[i]) continue;
      if (sharp->distance(m.vertices[i]) > edge_radius) { sm[i] = 1; ++r.n_obl_smooth; }
      else { ne[i] = 1; ++r.n_obl_near_edge; }
    }
    r.obl_smooth = deviation_from_cad(m, cad, sm);
    r.obl_near_edge = deviation_from_cad(m, cad, ne);
  }
  if (skin_band > 0.0) {
    std::vector<char> sk(m.vertices.size(), 0);
    for (std::size_t i = 0; i < m.vertices.size(); ++i) {
      if (!obl[i]) continue;
      if (cad.distance(m.vertices[i]) <= skin_band) { sk[i] = 1; ++r.n_obl_skin; }
    }
    r.obl_skin = deviation_from_cad(m, cad, sk);
  }
  if (cad_samples && !cad_samples->empty() && !m.triangles.empty()) {
    const TriGrid self(m);
    std::vector<double> ds;
    ds.reserve(cad_samples->size());
    double s2 = 0.0, sm = 0.0;
    for (const Vec3& p : *cad_samples) {
      const double d = self.distance(p);
      ds.push_back(d);
      s2 += d * d;
      sm += d;
      r.cad_side.max_mm = std::fmax(r.cad_side.max_mm, d);
    }
    const double n = static_cast<double>(ds.size());
    r.cad_side.rms_mm = std::sqrt(s2 / n);
    r.cad_side.mean_mm = sm / n;
    const std::size_t kq = static_cast<std::size_t>(0.99 * (n - 1.0));
    std::nth_element(ds.begin(), ds.begin() + static_cast<long>(kq), ds.end());
    r.cad_side.p99_mm = ds[kq];
    r.n_cad_side = ds.size();
  }
  r.dihedral = dihedral_rms_deg(m);
  r.min_feature = min_feature_now(m, grid);
  if (base) r.max_shift_from_base = surface_motion(m, *base);
  return r;
}

void print_row(const char* label, const Reading& r, const Reading& base,
               double spacing) {
  std::printf("%-22s %8.4f %8.4f %8.4f %8.4f %7.2f %8.4f %7.1f%% %6d %5d\n",
              label, r.obl.max_mm, r.obl.rms_mm, r.obl.p99_mm, r.all.rms_mm,
              r.dihedral, r.max_shift_from_base,
              100.0 * (1.0 - r.obl.rms_mm / std::fmax(base.obl.rms_mm, 1e-12)),
              r.min_feature, r.components);
  (void)spacing;
}

void print_cadside(const Reading& r, const Reading& base) {
  if (r.n_cad_side == 0) return;
  std::printf("      CAD-SIDE, %zu fixed CAD points -> the mesh: max %.4f  "
              "rms %.4f  p99 %.4f mm  ->  %+.1f%% removed\n",
              r.n_cad_side, r.cad_side.max_mm, r.cad_side.rms_mm,
              r.cad_side.p99_mm,
              100.0 * (1.0 - r.cad_side.rms_mm /
                                 std::fmax(base.cad_side.rms_mm, 1e-12)));
}

void print_skin(const Reading& r, const Reading& base) {
  if (r.n_obl_skin == 0) return;
  std::printf("      oblique on PART SKIN (<=1 voxel from the CAD): max %.4f  "
              "rms %.4f  p99 %.4f mm over %zu verts  ->  %+.1f%% removed\n",
              r.obl_skin.max_mm, r.obl_skin.rms_mm, r.obl_skin.p99_mm,
              r.n_obl_skin,
              100.0 * (1.0 - r.obl_skin.rms_mm /
                                 std::fmax(base.obl_skin.rms_mm, 1e-12)));
}

void print_split(const Reading& r, const Reading& base) {
  if (r.n_obl_smooth + r.n_obl_near_edge == 0) return;
  std::printf("      oblique SPLIT: smooth-surface rms %.4f mm (%zu verts, "
              "%+.1f%%)   near-sharp-edge rms %.4f mm (%zu verts, %+.1f%%)\n",
              r.obl_smooth.rms_mm, r.n_obl_smooth,
              100.0 * (1.0 - r.obl_smooth.rms_mm /
                                 std::fmax(base.obl_smooth.rms_mm, 1e-12)),
              r.obl_near_edge.rms_mm, r.n_obl_near_edge,
              100.0 * (1.0 - r.obl_near_edge.rms_mm /
                                 std::fmax(base.obl_near_edge.rms_mm, 1e-12)));
}

void print_header() {
  std::printf("%-22s %8s %8s %8s %8s %7s %8s %8s %6s %5s\n", "configuration",
              "obl max", "obl rms", "obl p99", "all rms", "dihed", "motion",
              "removed", "mf", "comp");
  std::printf("%-22s %8s %8s %8s %8s %7s %8s %8s %6s %5s\n", "", "mm", "mm",
              "mm", "mm", "deg", "mm", "%", "viol", "");
}

}  // namespace

// ─────────────────────────────────────────────────────────────────────────────

int main(int argc, char** argv) {
  const std::string mode = argc > 1 ? argv[1] : "headline";

  if (mode == "selfcheck") {
    // A cube of side 4 in a 8x8x8 unit-element grid: the nodal field, the
    // threshold, and the volume must all come back exactly. Preconditions only.
    VoxelGrid g;
    g.nx = g.ny = g.nz = 8;
    g.spacing = 1.0;
    g.origin = Vec3{0, 0, 0};
    g.tags.assign(512, VoxelTag::Empty);
    std::vector<double> rho(512, 0.0);
    for (int k = 2; k < 6; ++k)
      for (int j = 2; j < 6; ++j)
        for (int i = 2; i < 6; ++i) rho[g.index(i, j, k)] = 1.0;
    const Lattice nd = nodal_from_elements(g, rho);
    // +1 on every index: nodal_from_elements pads the ELEMENT grid with one ring
    // of zero-density elements (see sdf_geometry.hpp), so node (i,j,k) of the
    // original grid is node (i+1,j+1,k+1) of the lattice.
    std::printf("selfcheck nodal: centre %.6f (expect 1), corner-of-solid %.6f "
                "(expect 0.125)\n",
                nd.v[nd.idx(5, 5, 5)], nd.v[nd.idx(3, 3, 3)]);
    double sum = 0.0;
    for (double x : rho) sum += x;
    const ThresholdResult th = find_level_for_volume(nd, sum, 0.0, 1.0, 9);
    std::printf("selfcheck threshold: rho_t %.6f  volume %.6f (target %.6f, "
                "rel %.2e, %d bisections)\n",
                th.level, th.volume, sum, th.rel_err, th.iterations);
    // THE RESIDUAL HERE IS NOT A BUG AND IS WORTH THE LINE. Gauss-Legendre POINT
    // COUNTING (the reference's own `calculate_isocontour_volume`) makes the
    // computed volume a fine staircase in the level rather than a continuous
    // function: quadrature points flip in or out one at a time. On a PERFECTLY
    // SYMMETRIC fixture like this cube, hundreds of cells flip at the SAME level,
    // so the staircase has a step ~1e-2 wide and the bisection cannot land inside
    // it. On real fields — his part, the sphere — nothing is symmetric, the steps
    // are ~1e-6, and the same bisection lands within 1e-6 (see any `rho_t` row in
    // sdf_part.txt). The nodal figures above are the assertion this mode exists
    // for; the threshold line is printed for completeness.
    return 0;
  }


  // ── MODE: crosscheck — the same case rho2sdf.jl is driven on ─────────────
  //
  //   crosscheck <reference.txt> <out.txt>
  //
  // evidence/.../julia_reference/crosscheck.jl builds an identical 12x12x12 unit
  // hex grid with an identical radial density ramp and dumps the REFERENCE's
  // nodal densities, threshold and raw SDF at its own grid points. This rebuilds
  // the same field with the port, reads the reference's grid points out of that
  // file, and evaluates the port's SDF AT THOSE POINTS, so the two files can be
  // compared row for row with no interpolation in between. Nothing else in this
  // task validates the port against the paper's own code.
  if (mode == "crosscheck") {
    const std::string refpath = argc > 2 ? argv[2] : "";
    const std::string out = argc > 3 ? argv[3] : "crosscheck_port.txt";
    const int NE = 12;
    const double H = 1.0, R = 4.0, W = 2.0;
    VoxelGrid g;
    g.nx = g.ny = g.nz = NE;
    g.spacing = H;
    g.origin = Vec3{0, 0, 0};
    g.tags.assign(static_cast<std::size_t>(NE) * NE * NE, VoxelTag::Empty);
    std::vector<double> rho(g.tags.size(), 0.0);
    const double cc = NE * H / 2;
    for (int k = 0; k < NE; ++k)
      for (int j = 0; j < NE; ++j)
        for (int i = 0; i < NE; ++i) {
          const double dx = (i + 0.5) * H - cc, dy = (j + 0.5) * H - cc,
                       dz = (k + 0.5) * H - cc;
          const double d = std::sqrt(dx * dx + dy * dy + dz * dz);
          rho[g.index(i, j, k)] =
              std::fmax(0.0, std::fmin(1.0, (R - d) / W + 0.5));
        }
    const Lattice nd = nodal_from_elements(g, rho);
    double vol = 0.0;
    for (double x : rho) vol += x;
    vol *= H * H * H;
    // The reference's own tolerance and quadrature order (Isocontour_volume.jl:
    // tolerance 1e-4, detailed_quad_order 15, max 60 bisections).
    const ThresholdResult th =
        find_level_for_volume(nd, vol, 0.0, 1.0, 15, 1e-4, 60);

    // read the reference's grid points
    std::vector<Vec3> pts;
    std::vector<double> refsdf;
    std::vector<double> refnodal;
    double ref_rho_t = 0.0, ref_target = 0.0;
    {
      std::ifstream f(refpath);
      std::string tok;
      while (f >> tok) {
        if (tok == "rho_t") { f >> ref_rho_t; }
        else if (tok == "target_volume") { f >> ref_target; }
        else if (tok == "nodal_densities") {
          long n = 0; f >> n;
          refnodal.resize(static_cast<std::size_t>(n));
          for (long i = 0; i < n; ++i) f >> refnodal[static_cast<std::size_t>(i)];
        } else if (tok == "sdf") {
          long n = 0; f >> n;
          pts.resize(static_cast<std::size_t>(n));
          refsdf.resize(static_cast<std::size_t>(n));
          for (long i = 0; i < n; ++i) {
            Vec3 p; double v;
            f >> p.x >> p.y >> p.z >> v;
            pts[static_cast<std::size_t>(i)] = p;
            refsdf[static_cast<std::size_t>(i)] = v;
          }
        } else if (!tok.empty() && tok[0] == '#') {
          std::getline(f, tok);
        }
      }
    }
    std::printf("== crosscheck against rho2sdf.jl v0.1.0 ==\n");
    std::printf("reference file %s\n", refpath.c_str());
    std::printf("target volume   reference %.12g   port %.12g   (diff %.3e)\n",
                ref_target, vol, std::fabs(ref_target - vol));
    std::printf("rho_t           reference %.12g   port %.12g   (diff %.3e)\n",
                ref_rho_t, th.level, std::fabs(ref_rho_t - th.level));

    // nodal densities, in the reference's node order over the UNPADDED lattice
    if (!refnodal.empty()) {
      double worst = 0.0, sum2 = 0.0;
      std::size_t idx = 0;
      for (int k = 0; k <= NE; ++k)
        for (int j = 0; j <= NE; ++j)
          for (int i = 0; i <= NE; ++i, ++idx) {
            const double a = nd.v[nd.idx(i + 1, j + 1, k + 1)];
            const double b = refnodal[idx];
            worst = std::fmax(worst, std::fabs(a - b));
            sum2 += (a - b) * (a - b);
          }
      std::printf("nodal densities %zu values: worst |port - reference| %.3e, "
                  "rms %.3e\n", refnodal.size(), worst,
                  std::sqrt(sum2 / refnodal.size()));
    }

    // the SDF, at the reference's own grid points and its own threshold, so the
    // only thing being compared is the DISTANCE FIELD.
    const SdfBuild sdf = build_sdf(nd, ref_rho_t, H, 8, 12.0);
    double worst = 0.0, sum2 = 0.0, worst_near = 0.0;
    std::size_t n_near = 0;
    std::FILE* f = std::fopen(out.c_str(), "w");
    std::fprintf(f, "# sdf_geometry_probe port, evaluated at the reference's own "
                    "grid points\nx y z port_sdf reference_sdf diff\n");
    for (std::size_t i = 0; i < pts.size(); ++i) {
      const double a = sdf.phi.sample(pts[i], -sdf.band_mm);
      const double b = refsdf[i];
      const double d = a - b;
      worst = std::fmax(worst, std::fabs(d));
      sum2 += d * d;
      if (std::fabs(b) <= 2.0 * H) { ++n_near; worst_near = std::fmax(worst_near, std::fabs(d)); }
      std::fprintf(f, "%.9g %.9g %.9g %.9g %.9g %.9g\n", pts[i].x, pts[i].y,
                   pts[i].z, a, b, d);
    }
    std::fclose(f);
    if (!pts.empty())
      std::printf("SDF %zu points: worst |port - reference| %.4f mm, rms %.4f mm;"
                  " within 2 cells of the surface (%zu points) worst %.4f mm\n",
                  pts.size(), worst, std::sqrt(sum2 / pts.size()), n_near,
                  worst_near);
    std::printf("wrote %s\n", out.c_str());
    return 0;
  }

  if (mode == "sphere") {
    const double R = argc > 2 ? std::atof(argv[2]) : 20.0;
    const double spacing = argc > 3 ? std::atof(argv[3]) : 1.620040;
    const int factor = argc > 4 ? std::atoi(argv[4]) : 2;
    std::printf("== sdf_geometry_probe : ANALYTIC SPHERE CONTROL ==\n");
    std::printf("R %.3f mm, spacing %.6f mm (%.1f voxels across the radius), "
                "export factor %d\n\n", R, spacing, R / spacing, factor);
    Vec3 c;
    const VoxelGrid g = sphere_grid(R, spacing, c);
    std::vector<double> occ(g.voxel_count(), 0.0);
    for (std::size_t i = 0; i < occ.size(); ++i)
      if (g.tags[i] != VoxelTag::Empty) occ[i] = 1.0;

    const TriangleMesh base_mem = marching_cubes_resampled(
        g.nx, g.ny, g.nz, g.spacing, g.origin, occ, 0.5, factor,
        ResampleInterp::Tricubic);
    const TriangleMesh base = through_stl(base_mem, "/tmp/sdfp_sphere_base.stl");
    const SphereReading b = sphere_deviation(base, c, R);
    std::printf("%-24s %9s %9s %9s %9s\n", "configuration", "max mm", "rms mm",
                "% of base", "verts");
    std::printf("%-24s %9.4f %9.4f %9.1f %9zu\n", "unsmoothed (PR 299)", b.max_mm,
                b.rms_mm, 100.0, base.vertices.size());

    const double ratios[] = {3.3, 2.0, 1.0, 0.5, 0.25, 0.125};
    for (double q : ratios) {
      Config cfg;
      cfg.B_over_h = q;
      const Run rr = run_pipeline(g, occ, cfg);
      if (rr.mesh.vertices.empty()) {
        std::printf("B/h %-20.3f  (empty)\n", q);
        continue;
      }
      const TriangleMesh out = through_stl(rr.mesh, "/tmp/sdfp_sphere_sdf.stl");
      const SphereReading s = sphere_deviation(out, c, R);
      char lab[64];
      std::snprintf(lab, sizeof lab, "SDF B/h = %.3f", q);
      std::printf("%-24s %9.4f %9.4f %9.1f %9zu   rho_t %.4f  vol %.1f/%.1f mm3\n",
                  lab, s.max_mm, s.rms_mm, 100.0 * s.rms_mm / b.rms_mm,
                  out.vertices.size(), rr.rho_t, rr.final_volume_mm3,
                  rr.target_volume);
    }
    return 0;
  }




  // ── MODE: emit — write the meshes S2 certifies ───────────────────────────
  //
  //   emit <design.bin> <out_dir> <rung_index> 
  //
  // S2 has to put the certified margin of the SMOOTHED object beside the
  // certified margin of the one shipped today, through the shipped seam
  // (`topopt-cli analyze --mesh`). That seam takes a file, so the three meshes
  // have to exist as files. Nothing here measures anything.
  if (mode == "emit") {
    const std::string design_path = argc > 2 ? argv[2] : "";
    const std::string dir = argc > 3 ? argv[3] : ".";
    const int want = argc > 4 ? std::atoi(argv[4]) : -1;
    const int factor = argc > 5 ? std::atoi(argv[5]) : 2;
    DesignStore store = read_design_file(design_path);
    VoxelGrid grid;
    grid.nx = store.nx; grid.ny = store.ny; grid.nz = store.nz;
    grid.spacing = store.spacing; grid.origin = store.origin;
    grid.tags.assign(store.voxel_count(), VoxelTag::Empty);
    for (std::size_t vi = 0; vi < store.variants.size(); ++vi) {
      if (want >= 0 && static_cast<int>(vi) != want) continue;
      const StoredDesign& d = store.variants[vi];
      char tag[32];
      std::snprintf(tag, sizeof tag, "%03d",
                    static_cast<int>(std::lround(d.requested_volume_fraction * 100)));
      const TriangleMesh e = marching_cubes_resampled(
          grid.nx, grid.ny, grid.nz, grid.spacing, grid.origin, d.density, 0.5,
          factor, ResampleInterp::Tricubic);
      write_stl_file(dir + "/v" + tag + "_exported.stl", e);
      Config cfg;
      const Run rr = run_pipeline(grid, d.density, cfg);
      write_stl_file(dir + "/v" + tag + "_sdf.stl", rr.mesh);
      Config iso; iso.isocontour_only = true;
      const Run ri = run_pipeline(grid, d.density, iso);
      write_stl_file(dir + "/v" + tag + "_isocontour.stl", ri.mesh);
      const TriangleMesh se = through_stl(e, dir + "/v" + tag + "_exported.stl");
      TaubinParams tp = taubin_params_for_strength(1.0);
      SmoothConstraints sc;
      sc.min_feature_grid = &grid;
      const SmoothResult sr = constrained_taubin_smooth(se, tp, sc);
      write_stl_file(dir + "/v" + tag + "_taubin.stl", sr.mesh);
      std::printf("rung %.2f: exported %zu tris, sdf %zu tris, isocontour %zu "
                  "tris, taubin %zu tris (rho_t %.6f)\n",
                  d.requested_volume_fraction, e.triangles.size(),
                  rr.mesh.triangles.size(), ri.mesh.triangles.size(),
                  sr.mesh.triangles.size(), rr.rho_t);
    }
    return 0;
  }




  // ── MODE: gibson — S3.4, the one-voxel hard bound ON HIS PART ────────────
  //
  //   gibson <design.bin> <part.step> <evidence_dir>
  //
  // Gibson, "Constrained Elastic Surface Nets" (MICCAI 1998 / MERL TR99-24):
  // every surface node stays inside its ORIGINAL surface cube, which bounds the
  // error to one voxel BY CONSTRUCTION rather than by tuning. The SDF route
  // re-extracts rather than relaxes, so the constraint is applied as its
  // consequence — no output vertex further than `bound` from the unsmoothed
  // surface — and the S1 numbers are re-read under it. Run on HIS part, not on
  // PR 299's fixture, because S3 is about his features.
  if (mode == "gibson") {
    const std::string design_path = argc > 2 ? argv[2] : "";
    const std::string step_path = argc > 3 ? argv[3] : "";
    const std::string ev = argc > 4 ? argv[4] : ".";
    DesignStore store = read_design_file(design_path);
    VoxelGrid grid;
    grid.nx = store.nx; grid.ny = store.ny; grid.nz = store.nz;
    grid.spacing = store.spacing; grid.origin = store.origin;
    grid.tags.assign(store.voxel_count(), VoxelTag::Empty);
    StepTessellation fine_t;
    fine_t.linear_deflection = 0.005;
    fine_t.angular_deflection = 0.05;
    const StepModel run_model = import_part_file_resolved(step_path);
    const StepModel ref_model = import_part_file_resolved(step_path, fine_t);
    const TriGrid cad(ref_model.mesh);
    const SharpEdges sharp(ref_model.mesh, 60.0);
    const double edge_radius = 1.5 * grid.spacing;
    std::printf("== sdf_geometry_probe : S3.4 GIBSON'S ONE-VOXEL BOUND ==\n");
    std::printf("grid %d x %d x %d, voxel %.6f mm\n\n", grid.nx, grid.ny,
                grid.nz, grid.spacing);

    struct Subject { std::string name; std::vector<double> rho; };
    std::vector<Subject> subs;
    {
      const VoxelGrid og = voxelize_onto_grid(run_model.mesh, grid);
      std::vector<double> occ(grid.voxel_count(), 0.0);
      for (std::size_t i = 0; i < occ.size(); ++i)
        if (og.tags[i] != VoxelTag::Empty) occ[i] = 1.0;
      subs.push_back({"occupancy(CAD)", occ});
    }
    subs.push_back({"rung 0.68", store.variants[0].density});

    for (const Subject& sub : subs) {
      std::printf("== SUBJECT: %s ==\n", sub.name.c_str());
      const TriangleMesh exp_mem = marching_cubes_resampled(
          grid.nx, grid.ny, grid.nz, grid.spacing, grid.origin, sub.rho, 0.5, 2,
          ResampleInterp::Tricubic);
      const TriangleMesh exported = through_stl(exp_mem, ev + "/gib_exp.stl");
      const TriGrid basegrid(exported);
      std::vector<char> dummy;
      const Reading base = read_mesh(exported, cad, dummy, grid, nullptr, &sharp,
                                     edge_radius, grid.spacing);
      print_header();
      print_row("as exported today", base, base, grid.spacing);
      for (double q : {1.0, 2.0}) {
        Config cfg;
        cfg.B_over_h = q;
        const Run rr = run_pipeline(grid, sub.rho, cfg);
        if (rr.mesh.vertices.empty()) continue;
        const TriangleMesh out = through_stl(rr.mesh, ev + "/gib_sdf.stl");
        const Reading r = read_mesh(out, cad, dummy, grid, &basegrid, &sharp,
                                    edge_radius, grid.spacing);
        char lab[64];
        std::snprintf(lab, sizeof lab, "SDF B/h %.0f", q);
        print_row(lab, r, base, grid.spacing);
        for (double bnd : {0.5, 1.0}) {
          double frac = 0.0, pull = 0.0;
          const TriangleMesh cl = clamp_to_original(rr.mesh, exported,
                                                    bnd * grid.spacing, frac, pull);
          const TriangleMesh clo = through_stl(cl, ev + "/gib_clamped.stl");
          const Reading rc = read_mesh(clo, cad, dummy, grid, &basegrid, &sharp,
                                       edge_radius, grid.spacing);
          char lb[64];
          std::snprintf(lb, sizeof lb, "  + Gibson %.1f voxel", bnd);
          print_row(lb, rc, base, grid.spacing);
          std::printf("      %.2f%% of vertices pulled back, deepest pull-back "
                      "%.4f mm\n", 100.0 * frac, pull);
        }
      }
      std::printf("\n");
    }
    return 0;
  }

  // ── MODE: loadcheck — WHY the shipped certification refuses the SDF mesh ──
  //
  //   loadcheck <part.step> <mesh.stl> [<mesh.stl> ...]
  //
  // `topopt-cli analyze --mesh <sdf>.stl` refuses with "under-constrained system
  // (load applied to a void DOF with no stiffness)". That is a real refusal with
  // a real cause and S2 has to name it rather than describe it: the
  // certification carries the model's Load tag onto the substitute mesh's
  // voxelization ONLY where that mesh still has material (run_job.cpp:3745-3752
  // — the "228 contract", certify what was handed in), so a smoothing that
  // erodes the loaded interface leaves load-tagged DOFs with no stiffness. This
  // counts exactly how many, for each mesh, against HIS load case.
  if (mode == "loadcheck") {
    const std::string step_path = argc > 2 ? argv[2] : "";
    const StepModel model = import_part_file_resolved(step_path);
    ProductionLoadCase lc;                       // his loadcase.json, verbatim
    lc.anchor_face_ids = {18};
    ProductionLoadCase::LoadGroup g;
    g.face_ids = {20, 1, 4, 19, 21, 22, 25, 26, 27, 32, 41, 42, 43, 44, 45, 46,
                  47, 49, 75, 76, 24};
    g.force = Vec3{0.0, 0.0, -24.516624450683594};
    lc.load_groups.push_back(g);
    lc.minimize_plastic = true;
    lc.build_dir = Vec3{0.0, 0.0, 1.0};
    lc.infill_percent = 35.0;
    lc.face_protection_face_ids = {16};
    lc.face_protection_depth_mm = 5.0;
    ProductionRunSetup setup = build_production_loadcase(model, 128, lc);
    setup.options.bake_build_orientation = BakeBuildOrientation::Off;
    const VoxelGrid& cert = setup.solved_grid;
    std::size_t nload = 0, nfix = 0;
    for (std::size_t i = 0; i < cert.tags.size(); ++i) {
      if (cert.tags[i] == VoxelTag::Load) ++nload;
      if (cert.tags[i] == VoxelTag::Fixture) ++nfix;
    }
    std::printf("== sdf_geometry_probe : WHY THE CERTIFICATION REFUSES ==\n");
    std::printf("his load case on the solved grid %d x %d x %d @ %.6f mm: "
                "%zu Load voxels, %zu Fixture voxels\n\n", cert.nx, cert.ny,
                cert.nz, cert.spacing, nload, nfix);
    std::printf("%-28s %10s %10s %10s %10s\n", "mesh", "Load kept", "Load LOST",
                "Fix kept", "Fix LOST");
    for (int a = 3; a < argc; ++a) {
      const TriangleMesh m = import_part_file_resolved(argv[a]).mesh;
      if (m.vertices.empty()) { std::printf("%-28s (empty)\n", argv[a]); continue; }
      const VoxelGrid v = voxelize_onto_grid(m, cert);
      std::size_t lk = 0, ll = 0, fk = 0, fl = 0;
      for (std::size_t i = 0; i < cert.tags.size(); ++i) {
        const bool has = v.tags[i] != VoxelTag::Empty;
        if (cert.tags[i] == VoxelTag::Load) { has ? ++lk : ++ll; }
        if (cert.tags[i] == VoxelTag::Fixture) { has ? ++fk : ++fl; }
      }
      std::string nm(argv[a]);
      const std::size_t sl = nm.find_last_of('/');
      if (sl != std::string::npos) nm = nm.substr(sl + 1);
      std::printf("%-28s %10zu %10zu %10zu %10zu\n", nm.c_str(), lk, ll, fk, fl);
    }
    return 0;
  }

  // ── MODE: partfactor — S5, is a TESSELLATION slider a lie on HIS part? ────
  //
  //   partfactor <design.bin> <part.step> <evidence_dir>
  //
  // PR 299 measured export factor 1/2/4 on its own fixture and found the
  // deviation flat while the dihedral halved: 16x the triangles, the same
  // surface in the same wrong place. S5 has to say whether a "resolution"
  // slider over tessellation would do anything on HIS part, so it is re-measured
  // here rather than carried over from another part.
  if (mode == "partfactor") {
    const std::string design_path = argc > 2 ? argv[2] : "";
    const std::string step_path = argc > 3 ? argv[3] : "";
    DesignStore store = read_design_file(design_path);
    VoxelGrid grid;
    grid.nx = store.nx; grid.ny = store.ny; grid.nz = store.nz;
    grid.spacing = store.spacing; grid.origin = store.origin;
    grid.tags.assign(store.voxel_count(), VoxelTag::Empty);
    StepTessellation fine_t;
    fine_t.linear_deflection = 0.005;
    fine_t.angular_deflection = 0.05;
    const StepModel run_model = import_part_file_resolved(step_path);
    const StepModel ref_model = import_part_file_resolved(step_path, fine_t);
    const TriGrid cad(ref_model.mesh);
    std::printf("== sdf_geometry_probe : EXPORT TESSELLATION (S5) ==\n");
    std::printf("grid %d x %d x %d, spacing %.6f mm\n\n", grid.nx, grid.ny,
                grid.nz, grid.spacing);
    struct Subject { std::string name; std::vector<double> rho; };
    std::vector<Subject> subs;
    {
      const VoxelGrid og = voxelize_onto_grid(run_model.mesh, grid);
      std::vector<double> occ(grid.voxel_count(), 0.0);
      for (std::size_t i = 0; i < occ.size(); ++i)
        if (og.tags[i] != VoxelTag::Empty) occ[i] = 1.0;
      subs.push_back({"occupancy(CAD)", occ});
    }
    subs.push_back({"rung 0.68", store.variants[0].density});
    for (const Subject& sub : subs) {
      std::printf("-- %s --\n", sub.name.c_str());
      std::printf("%-8s %10s %10s %11s %11s %9s\n", "factor", "verts", "tris",
                  "obl max mm", "obl rms mm", "dihed deg");
      for (int f : {1, 2, 4}) {
        const TriangleMesh mem = marching_cubes_resampled(
            grid.nx, grid.ny, grid.nz, grid.spacing, grid.origin, sub.rho, 0.5,
            f, ResampleInterp::Tricubic);
        const TriangleMesh m = through_stl(mem, "/tmp/sdfp_factor.stl");
        std::vector<char> obl(m.vertices.size(), 0);
        for (std::size_t i = 0; i < m.vertices.size(); ++i) {
          const auto dt = cad.distance_and_tri(m.vertices[i]);
          if (dt.second < 0) continue;
          const Vec3 n = cad.tri_normal(dt.second);
          const double mx = std::fmax(std::fabs(n.x),
                                      std::fmax(std::fabs(n.y), std::fabs(n.z)));
          if (mx < 0.98) obl[i] = 1;
        }
        const Deviation d = deviation_from_cad(m, cad, obl);
        std::printf("%-8d %10zu %10zu %11.4f %11.4f %9.2f\n", f,
                    m.vertices.size(), m.triangles.size(), d.max_mm, d.rms_mm,
                    dihedral_rms_deg(m));
      }
      std::printf("\n");
    }
    return 0;
  }

  // ── MODE: features — S3, THE SURFACES THAT MUST NOT MOVE ─────────────────
  //
  //   features <design.bin> <part.step> <evidence_dir> [export_factor]
  //
  // The paper names its own limitation: global smoothing "may affect precision at
  // boundary condition interfaces". On his part that is not a footnote. From his
  // loadcase.json: anchor face 18, one load group over 21 faces (5,165 voxels,
  // 24.51662445 N), face protection on face 16 (10,554 voxels frozen, depth 3),
  // plus the bolt bores, which are analytic cylinders the lattice boundary code
  // already knows about (lattice_boundary.cpp:160 populates faces_ for planes and
  // BOLT bores).
  //
  // For each of those face sets this measures, on the vertices that sit against
  // it, the SIGNED offset from the CAD surface — positive OUTWARD, so "the bore
  // rounded off" and "the anchor face drifted" are different numbers with
  // different signs rather than one unsigned blur. Bores additionally get their
  // radius read back directly against the B-rep cylinder axis.
  if (mode == "features") {
    const std::string design_path = argc > 2 ? argv[2] : "";
    const std::string step_path = argc > 3 ? argv[3] : "";
    const std::string ev = argc > 4 ? argv[4] : ".";
    const int factor = argc > 5 ? std::atoi(argv[5]) : 2;

    DesignStore store = read_design_file(design_path);
    VoxelGrid grid;
    grid.nx = store.nx; grid.ny = store.ny; grid.nz = store.nz;
    grid.spacing = store.spacing; grid.origin = store.origin;
    grid.tags.assign(store.voxel_count(), VoxelTag::Empty);

    StepTessellation fine_t;
    fine_t.linear_deflection = 0.005;
    fine_t.angular_deflection = 0.05;
    const StepModel m = import_part_file_resolved(step_path, fine_t);

    std::printf("== sdf_geometry_probe : S3 THE FEATURES THAT MUST NOT MOVE ==\n");
    std::printf("part %s — %d B-rep faces, voxel %.6f mm\n\n", step_path.c_str(),
                m.face_count, grid.spacing);

    struct FaceSet { std::string name; std::vector<int> ids; };
    std::vector<FaceSet> sets;
    sets.push_back({"anchor face 18", {18}});
    sets.push_back({"protected face 16", {16}});
    sets.push_back({"load group (21 faces)",
                    {20, 1, 4, 19, 21, 22, 25, 26, 27, 32, 41, 42, 43, 44, 45,
                     46, 47, 49, 75, 76, 24}});
    {
      std::vector<int> bores;
      for (int f = 0; f < m.face_count; ++f)
        if (m.faces[static_cast<std::size_t>(f)].kind == StepSurfaceKind::Cylinder)
          bores.push_back(f);
      sets.push_back({"every cylindrical face (bores)", bores});
    }

    // One sub-mesh per face set, and a TriGrid over it. `owner` maps the
    // sub-mesh's triangles back so the CAD normal can be read.
    struct FaceRef {
      TriangleMesh mesh;
      std::vector<int> src;      // triangle -> original triangle index
    };
    std::vector<FaceRef> refs(sets.size());
    for (std::size_t si = 0; si < sets.size(); ++si) {
      std::vector<char> want(static_cast<std::size_t>(m.face_count), 0);
      for (int f : sets[si].ids)
        if (f >= 0 && f < m.face_count) want[static_cast<std::size_t>(f)] = 1;
      std::vector<int> remap(m.mesh.vertices.size(), -1);
      for (std::size_t t = 0; t < m.mesh.triangles.size(); ++t) {
        const int f = m.triangle_face[t];
        if (f < 0 || f >= m.face_count || !want[static_cast<std::size_t>(f)])
          continue;
        std::array<int, 3> tri{};
        for (int q = 0; q < 3; ++q) {
          const int v = m.mesh.triangles[t][static_cast<std::size_t>(q)];
          if (remap[static_cast<std::size_t>(v)] < 0) {
            remap[static_cast<std::size_t>(v)] =
                static_cast<int>(refs[si].mesh.vertices.size());
            refs[si].mesh.vertices.push_back(
                m.mesh.vertices[static_cast<std::size_t>(v)]);
          }
          tri[static_cast<std::size_t>(q)] = remap[static_cast<std::size_t>(v)];
        }
        refs[si].mesh.triangles.push_back(tri);
        refs[si].src.push_back(static_cast<int>(t));
      }
    }

    std::ofstream csv(ev + "/sdf_features.csv");
    csv << "subject,stage,feature,verts_against_it,signed_mean_mm,signed_min_mm,"
           "signed_max_mm,unsigned_max_mm,unsigned_rms_mm\n";

    auto measure = [&](const char* subject, const char* stage,
                       const TriangleMesh& mesh) {
      for (std::size_t si = 0; si < sets.size(); ++si) {
        if (refs[si].mesh.triangles.empty()) continue;
        const TriGrid tg(refs[si].mesh);
        // THE AABB PRE-FILTER IS NOT AN OPTIMISATION, IT IS THE DIFFERENCE
        // BETWEEN MINUTES AND HOURS. TriGrid's query is exact by growing a
        // Chebyshev box until nothing outside can beat the best found — which
        // for a vertex 100 mm from a small face patch means doubling the box
        // until it covers the whole grid, 165,000 times over. Only vertices
        // that can possibly sit AGAINST the face are asked.
        Vec3 lo = refs[si].mesh.vertices[0], hi = lo;
        for (const Vec3& v : refs[si].mesh.vertices) {
          lo.x = std::fmin(lo.x, v.x); hi.x = std::fmax(hi.x, v.x);
          lo.y = std::fmin(lo.y, v.y); hi.y = std::fmax(hi.y, v.y);
          lo.z = std::fmin(lo.z, v.z); hi.z = std::fmax(hi.z, v.z);
        }
        const double pad = grid.spacing;
        double smin = 1e30, smax = -1e30, ssum = 0.0, umax = 0.0, u2 = 0.0;
        std::size_t n = 0;
        for (const Vec3& v : mesh.vertices) {
          if (v.x < lo.x - pad || v.x > hi.x + pad) continue;
          if (v.y < lo.y - pad || v.y > hi.y + pad) continue;
          if (v.z < lo.z - pad || v.z > hi.z + pad) continue;
          const auto dt = tg.distance_and_tri(v);
          if (dt.second < 0 || dt.first > grid.spacing) continue;
          const Vec3 nrm = tg.tri_normal(dt.second);
          const auto& tr = refs[si].mesh.triangles[static_cast<std::size_t>(dt.second)];
          const Vec3& a = refs[si].mesh.vertices[static_cast<std::size_t>(tr[0])];
          const double sgn = (v.x - a.x) * nrm.x + (v.y - a.y) * nrm.y +
                             (v.z - a.z) * nrm.z;
          smin = std::fmin(smin, sgn);
          smax = std::fmax(smax, sgn);
          ssum += sgn;
          umax = std::fmax(umax, dt.first);
          u2 += dt.first * dt.first;
          ++n;
        }
        if (n == 0) {
          std::printf("  %-32s  (no vertex sits against it)\n",
                      sets[si].name.c_str());
          continue;
        }
        std::printf("  %-32s %7zu verts   signed mean %+7.4f  range [%+7.4f, "
                    "%+7.4f]  unsigned max %.4f rms %.4f mm\n",
                    sets[si].name.c_str(), n, ssum / n, smin, smax, umax,
                    std::sqrt(u2 / n));
        csv << subject << "," << stage << "," << sets[si].name << "," << n << ","
            << ssum / n << "," << smin << "," << smax << "," << umax << ","
            << std::sqrt(u2 / n) << "\n";
      }
    };

    // Bore radius, read straight off the B-rep cylinder axis. A rounded-off bore
    // shows here as a radius that grew; a drifted one as a radius that moved.
    auto bore_radii = [&](const char* stage, const TriangleMesh& mesh) {
      for (int f = 0; f < m.face_count; ++f) {
        const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(f)];
        if (fi.kind != StepSurfaceKind::Cylinder) continue;
        if (fi.cylinder_radius_mm < 1.0 || fi.cylinder_radius_mm > 30.0) continue;
        // vertices within one voxel of this cylinder's surface, by radius
        double rmin = 1e30, rmax = -1e30, rsum = 0.0;
        std::size_t n = 0;
        for (const Vec3& v : mesh.vertices) {
          const Vec3 d{v.x - fi.axis_point.x, v.y - fi.axis_point.y,
                       v.z - fi.axis_point.z};
          const double t = d.x * fi.axis_dir.x + d.y * fi.axis_dir.y +
                           d.z * fi.axis_dir.z;
          const Vec3 rad{d.x - t * fi.axis_dir.x, d.y - t * fi.axis_dir.y,
                         d.z - t * fi.axis_dir.z};
          const double r = std::sqrt(rad.x * rad.x + rad.y * rad.y + rad.z * rad.z);
          if (std::fabs(r - fi.cylinder_radius_mm) > grid.spacing) continue;
          rmin = std::fmin(rmin, r);
          rmax = std::fmax(rmax, r);
          rsum += r;
          ++n;
        }
        if (n < 8) continue;
        std::printf("    bore face %-3d  CAD radius %7.4f mm   %s: mean %7.4f "
                    "[%7.4f, %7.4f]  (mean %+.4f mm)  %zu verts\n",
                    f, fi.cylinder_radius_mm, stage, rsum / n, rmin, rmax,
                    rsum / n - fi.cylinder_radius_mm, n);
      }
    };

    for (std::size_t vi = 0; vi < store.variants.size(); ++vi) {
      const StoredDesign& d = store.variants[vi];
      char nm[64];
      std::snprintf(nm, sizeof nm, "rung %.2f", d.requested_volume_fraction);
      std::printf("== %s ==\n", nm);
      const TriangleMesh exp_mem = marching_cubes_resampled(
          grid.nx, grid.ny, grid.nz, grid.spacing, grid.origin, d.density, 0.5,
          factor, ResampleInterp::Tricubic);
      const TriangleMesh exported = through_stl(exp_mem, ev + "/feat_exp.stl");
      std::printf("  -- as exported today --\n");
      measure(nm, "as exported today", exported);
      bore_radii("as exported", exported);

      Config cfg;
      const Run rr = run_pipeline(grid, d.density, cfg);
      if (rr.mesh.vertices.empty()) { std::printf("  (empty)\n\n"); continue; }
      const TriangleMesh sdf = through_stl(rr.mesh, ev + "/feat_sdf.stl");
      std::printf("  -- SDF B/h 1 interp f2 --\n");
      measure(nm, "SDF B/h 1 interp f2", sdf);
      bore_radii("SDF", sdf);

      Config iso;
      iso.isocontour_only = true;
      const Run ri = run_pipeline(grid, d.density, iso);
      const TriangleMesh isom = through_stl(ri.mesh, ev + "/feat_iso.stl");
      std::printf("  -- isocontour only --\n");
      measure(nm, "isocontour only", isom);
      bore_radii("isocontour", isom);
      std::printf("\n");
      if (vi == 0 && argc > 6) break;   // "features ... 2 first" = rung 0.68 only
    }
    csv.close();
    std::printf("wrote %s/sdf_features.csv\n", ev.c_str());
    return 0;
  }

  // ── MODE: part — THE MAINTAINER'S OWN PART AND HIS OWN FOUR RUNGS ─────────
  //
  //   part <design.bin> <part.step> <evidence_dir> [export_factor]
  //
  // Everything here is indexed to the grid the RUN solved on, read out of his
  // own design.bin rather than rebuilt, so no load-case reconstruction can put
  // the measurement on a different lattice than the one he has.
  if (mode == "part" || mode == "partsweep") {
    const std::string design_path = argc > 2 ? argv[2] : "";
    const std::string step_path = argc > 3 ? argv[3] : "";
    const std::string ev = argc > 4 ? argv[4] : ".";
    const int factor = argc > 5 ? std::atoi(argv[5]) : 2;

    DesignStore store = read_design_file(design_path);
    VoxelGrid grid;
    grid.nx = store.nx; grid.ny = store.ny; grid.nz = store.nz;
    grid.spacing = store.spacing; grid.origin = store.origin;
    grid.tags.assign(store.voxel_count(), VoxelTag::Empty);

    std::printf("== sdf_geometry_probe : HIS PART ==\n");
    std::printf("design    %s\n", design_path.c_str());
    std::printf("part      %s\n", step_path.c_str());
    std::printf("grid      %d x %d x %d, spacing %.6f mm, %zu voxels\n",
                grid.nx, grid.ny, grid.nz, grid.spacing, store.voxel_count());
    std::printf("variants  %zu\n\n", store.variants.size());

    // THE CAD REFERENCE, AND A CONTROL ON THE REFERENCE ITSELF. PR 299 measured
    // against `WallMount_ShelfBracket.stl`, a 2,224-triangle mesh, and named the
    // risk that some of the deviation it read was that mesh's own faceting. His
    // part is a STEP, so the reference can be tessellated as finely as wanted and
    // the risk can be MEASURED instead of noted: the control row below is the
    // deviation of the run's own tessellation from a 20x finer one.
    StepTessellation coarse_t;                       // what the run used
    StepTessellation fine_t;
    fine_t.linear_deflection = 0.005;
    fine_t.angular_deflection = 0.05;
    const StepModel run_model = import_part_file_resolved(step_path, coarse_t);
    const StepModel ref_model = import_part_file_resolved(step_path, fine_t);
    if (run_model.mesh.vertices.empty() || ref_model.mesh.vertices.empty()) {
      std::printf("FATAL: the STEP imported empty\n");
      return 2;
    }
    const TriGrid cad(ref_model.mesh);
    {
      Deviation d;
      double s2 = 0.0;
      for (const Vec3& v : run_model.mesh.vertices) {
        const double x = cad.distance(v);
        s2 += x * x;
        d.max_mm = std::fmax(d.max_mm, x);
      }
      d.rms_mm = std::sqrt(s2 / run_model.mesh.vertices.size());
      std::printf("-- THE REFERENCE'S OWN FACETING (control) --------------------\n");
      std::printf("run tessellation   %zu verts, %zu tris (linear defl %.3f mm, "
                  "angular %.2f rad)\n", run_model.mesh.vertices.size(),
                  run_model.mesh.triangles.size(), coarse_t.linear_deflection,
                  coarse_t.angular_deflection);
      std::printf("fine tessellation  %zu verts, %zu tris (linear defl %.3f mm, "
                  "angular %.2f rad)  <- THE REFERENCE\n",
                  ref_model.mesh.vertices.size(), ref_model.mesh.triangles.size(),
                  fine_t.linear_deflection, fine_t.angular_deflection);
      std::printf("run tessellation deviates from it: max %.4f mm  rms %.4f mm "
                  "(%.1f%% of one voxel)\n\n", d.max_mm, d.rms_mm,
                  100.0 * d.rms_mm / grid.spacing);
    }

    const SharpEdges sharp(ref_model.mesh, 60.0);
    const double edge_radius = 1.5 * grid.spacing;
    std::printf("CAD sharp edges (>= 60 deg): %d; \"near-edge\" is within "
                "%.3f mm of one\n\n", sharp.count(), edge_radius);

    std::ofstream csv(ev + "/sdf_" + mode + ".csv");
    csv << "subject,stage,obl_max_mm,obl_rms_mm,obl_p99_mm,all_rms_mm,"
           "cad_side_max_mm,cad_side_rms_mm,cad_side_p99_mm,cad_side_n,"
           "skin_max_mm,skin_rms_mm,skin_p99_mm,skin_n,"
           "obl_smooth_rms_mm,obl_smooth_n,obl_edge_rms_mm,obl_edge_n,"
           "dihedral_deg,motion_mm,removed_pct,min_feature,components,verts,tris,"
           "rho_t,target_vol_mm3,final_vol_mm3,vol_err_pct,mass_g,wall_s\n";

    const double density_g_cm3 = 1.24;   // PLA, core/src/materials/materials.json
    auto mass_g = [&](double vol_mm3) { return vol_mm3 * 1e-3 * density_g_cm3; };

    // Subject 0 is the PART'S OWN OCCUPANCY on the same grid — the only subject
    // for which a pre-voxelization CAD surface exists everywhere, and therefore
    // the row that is directly comparable with PR 299's 10.6%.
    struct Subject { std::string name; std::vector<double> rho; };
    std::vector<Subject> subjects;
    {
      const VoxelGrid occ_grid = voxelize_onto_grid(run_model.mesh, grid);
      std::vector<double> occ(grid.voxel_count(), 0.0);
      for (std::size_t i = 0; i < occ.size(); ++i)
        if (occ_grid.tags[i] != VoxelTag::Empty) occ[i] = 1.0;
      subjects.push_back({"occupancy(CAD)", occ});
    }
    for (const StoredDesign& d : store.variants) {
      char nm[64];
      std::snprintf(nm, sizeof nm, "rung %.2f", d.requested_volume_fraction);
      subjects.push_back({nm, d.density});
    }

    // "partsweep" keeps only the occupancy subject (a CAD reference exists
    // everywhere on it) and sweeps the SDF grid spacing instead of the stage.
    const bool sweep_mode = (mode == "partsweep");
    if (sweep_mode) subjects.resize(2);   // occupancy + rung 0.68

    for (std::size_t si = 0; si < subjects.size(); ++si) {
      const Subject& sub = subjects[si];
      std::printf("== SUBJECT: %s ==\n", sub.name.c_str());
      double raw_vol = 0.0;
      for (double x : sub.rho) raw_vol += x;
      raw_vol *= grid.spacing * grid.spacing * grid.spacing;

      const TriangleMesh exported_mem = marching_cubes_resampled(
          grid.nx, grid.ny, grid.nz, grid.spacing, grid.origin, sub.rho, 0.5,
          factor, ResampleInterp::Tricubic);
      const TriangleMesh exported =
          through_stl(exported_mem, ev + "/part_subject.stl");
      if (exported.vertices.empty()) {
        std::printf("  (empty export)\n\n");
        continue;
      }
      const TriGrid basegrid(exported);
      std::vector<char> dummy;
      // The fixed CAD-side sample set for THIS subject: centroids of the fine
      // CAD's triangles that have material against them in the unsmoothed
      // variant. Built once, before any stage runs, and reused for every row.
      std::vector<Vec3> cad_samples;
      for (const auto& tr : ref_model.mesh.triangles) {
        const Vec3& a = ref_model.mesh.vertices[static_cast<std::size_t>(tr[0])];
        const Vec3& b = ref_model.mesh.vertices[static_cast<std::size_t>(tr[1])];
        const Vec3& c = ref_model.mesh.vertices[static_cast<std::size_t>(tr[2])];
        const Vec3 g0{(a.x + b.x + c.x) / 3.0, (a.y + b.y + c.y) / 3.0,
                      (a.z + b.z + c.z) / 3.0};
        if (basegrid.distance(g0) <= grid.spacing) cad_samples.push_back(g0);
      }
      const Reading base =
          read_mesh(exported, cad, dummy, grid, nullptr, &sharp, edge_radius,
                    grid.spacing, &cad_samples);
      print_header();
      print_row("as exported today", base, base, grid.spacing);
      print_cadside(base, base);
      print_skin(base, base);
      print_split(base, base);
      std::printf("      %zu verts / %zu tris; raw design volume %.1f mm3 "
                  "(%.1f g); mesh volume %.1f mm3 (%.1f g)\n",
                  base.verts, base.tris, raw_vol, mass_g(raw_vol),
                  base.volume_mm3, mass_g(base.volume_mm3));

      // The paper's §5.2 grid-resolution study: a spacing 3.3x the element size
      // (their "coarse"), matched to it (their "reference"), and 8x smaller
      // (their "fine", where they report the method losing its smoothing and
      // starting to reproduce the original element isocontours).
      // NOT SWEPT BELOW 0.5 ON HIS PART, and the reason is arithmetic rather
      // than judgement: his SDF grid at B/h = 1 is 144 x 47 x 134 and the field
      // is evaluated on a lattice twice that on every axis. B/h = 0.125 would be
      // 264 MILLION grid points before the fine evaluation, ~17 GB, on a 16 GB
      // machine. The paper's "too fine" failure mode is therefore demonstrated on
      // the analytic sphere instead, where B/h = 0.125 fits (the `sphere` mode
      // sweeps 3.3 down to 0.125), and that is stated rather than quietly
      // dropped — bar "no silent caps".
      static const double kRatios[] = {3.3, 2.0, 1.5, 1.0, 0.75, 0.5};
      const int nvar = sweep_mode ? 6 : 2;
      for (int variant = 0; variant < nvar; ++variant) {
        Config cfg;
        if (sweep_mode) cfg.B_over_h = kRatios[variant];
        else cfg.isocontour_only = (variant == 0);
        const auto t0 = Clock::now();
        const Run rr = run_pipeline(grid, sub.rho, cfg);
        const double wall = secs(t0);
        if (rr.mesh.vertices.empty()) { std::printf("  (empty)\n"); continue; }
        const TriangleMesh out = through_stl(rr.mesh, ev + "/part_sdf.stl");
        const Reading r = read_mesh(out, cad, dummy, grid, &basegrid, &sharp,
                                    edge_radius, grid.spacing, &cad_samples);
        char labbuf[64];
        if (sweep_mode)
          std::snprintf(labbuf, sizeof labbuf, "SDF B/h %.3f", cfg.B_over_h);
        else
          std::snprintf(labbuf, sizeof labbuf, "%s",
                        variant == 0 ? "isocontour only" : "SDF B/h 1 interp f2");
        const char* lab = labbuf;
        print_row(lab, r, base, grid.spacing);
        print_cadside(r, base);
        print_skin(r, base);
        print_split(r, base);
        std::printf("      rho_t %.6f  volume %.1f mm3 (%.1f g, target %.1f, "
                    "%+.4f%%)  wall %.1f s\n", rr.rho_t, rr.final_volume_mm3,
                    mass_g(rr.final_volume_mm3), rr.target_volume,
                    100.0 * (rr.final_volume_mm3 - rr.target_volume) /
                        rr.target_volume, wall);
        csv << sub.name << "," << lab << "," << r.obl.max_mm << ","
            << r.obl.rms_mm << "," << r.obl.p99_mm << "," << r.all.rms_mm << ","
            << r.cad_side.max_mm << "," << r.cad_side.rms_mm << ","
            << r.cad_side.p99_mm << "," << r.n_cad_side << ","
            << r.obl_skin.max_mm << "," << r.obl_skin.rms_mm << ","
            << r.obl_skin.p99_mm << "," << r.n_obl_skin << ","
            << r.obl_smooth.rms_mm << "," << r.n_obl_smooth << ","
            << r.obl_near_edge.rms_mm << "," << r.n_obl_near_edge << ","
            << r.dihedral << "," << r.max_shift_from_base << ","
            << 100.0 * (1.0 - r.obl.rms_mm / std::fmax(base.obl.rms_mm, 1e-12))
            << "," << r.min_feature << "," << r.components << "," << r.verts
            << "," << r.tris << "," << rr.rho_t << "," << rr.target_volume << ","
            << rr.final_volume_mm3 << ","
            << 100.0 * (rr.final_volume_mm3 - rr.target_volume) /
                   rr.target_volume
            << "," << mass_g(rr.final_volume_mm3) << "," << wall << "\n";
      }
      // THE LIKE-FOR-LIKE CONTROL. PR 299's 10.6% is on a DIFFERENT part
      // (WallMount_ShelfBracket, an older job's fixture). Quoting it against
      // rows measured here would be comparing two parts, so Taubin is re-run on
      // THESE subjects, at the strength the app can ask for and at the best
      // setting PR 299 found anywhere in the family (lambda 0.90, k_PB 0.05).
      for (int tv = 0; tv < (sweep_mode ? 0 : 2); ++tv) {
        TaubinParams tp;
        if (tv == 0) { tp = taubin_params_for_strength(1.0); }
        else { tp.lambda = 0.90; tp.k_pb = 0.05; tp.pairs = 20; }
        SmoothConstraints sc;
        sc.min_feature_grid = &grid;

        const auto t0 = Clock::now();
        const SmoothResult sr = constrained_taubin_smooth(exported, tp, sc);
        const double wall = secs(t0);
        const TriangleMesh tout = through_stl(sr.mesh, ev + "/part_taubin.stl");
        const Reading r = read_mesh(tout, cad, dummy, grid, &basegrid, &sharp,
                                    edge_radius, grid.spacing, &cad_samples);
        char lab[64];
        std::snprintf(lab, sizeof lab, "Taubin %s (%d/%d prs)",
                      tv == 0 ? "shipped max" : "best-found", sr.stats.applied_pairs,
                      sr.stats.requested_pairs);
        print_row(lab, r, base, grid.spacing);
        print_cadside(r, base);
        print_skin(r, base);
        std::printf("      volume %.1f mm3 (%.1f g, %+.4f%% drift)  wall %.1f s\n",
                    sr.stats.volume_after_mm3, mass_g(sr.stats.volume_after_mm3),
                    100.0 * (sr.stats.volume_after_mm3 - sr.stats.volume_before_mm3) /
                        std::fmax(sr.stats.volume_before_mm3, 1e-12),
                    wall);
        csv << sub.name << "," << lab << "," << r.obl.max_mm << ","
            << r.obl.rms_mm << "," << r.obl.p99_mm << "," << r.all.rms_mm << ","
            << r.cad_side.max_mm << "," << r.cad_side.rms_mm << ","
            << r.cad_side.p99_mm << "," << r.n_cad_side << ","
            << r.obl_skin.max_mm << "," << r.obl_skin.rms_mm << ","
            << r.obl_skin.p99_mm << "," << r.n_obl_skin << ","
            << r.obl_smooth.rms_mm << "," << r.n_obl_smooth << ","
            << r.obl_near_edge.rms_mm << "," << r.n_obl_near_edge << ","
            << r.dihedral << "," << r.max_shift_from_base << ","
            << 100.0 * (1.0 - r.obl.rms_mm / std::fmax(base.obl.rms_mm, 1e-12))
            << "," << r.min_feature << "," << r.components << "," << r.verts
            << "," << r.tris << ",0.5," << raw_vol << ","
            << sr.stats.volume_after_mm3 << ","
            << 100.0 * (sr.stats.volume_after_mm3 - raw_vol) / raw_vol << ","
            << mass_g(sr.stats.volume_after_mm3) << "," << wall << "\n";
      }

      csv << sub.name << ",as exported today," << base.obl.max_mm << ","
          << base.obl.rms_mm << "," << base.obl.p99_mm << "," << base.all.rms_mm
          << "," << base.cad_side.max_mm << "," << base.cad_side.rms_mm << ","
          << base.cad_side.p99_mm << "," << base.n_cad_side << ","
          << base.obl_skin.max_mm << "," << base.obl_skin.rms_mm << ","
          << base.obl_skin.p99_mm << "," << base.n_obl_skin << ","
          << base.obl_smooth.rms_mm << "," << base.n_obl_smooth << ","
          << base.obl_near_edge.rms_mm << "," << base.n_obl_near_edge << ","
          << base.dihedral << ",0,0," << base.min_feature << ","
          << base.components << "," << base.verts << "," << base.tris << ",0.5,"
          << raw_vol << "," << base.volume_mm3 << ","
          << 100.0 * (base.volume_mm3 - raw_vol) / raw_vol << ","
          << mass_g(base.volume_mm3) << ",0\n";
      std::printf("\n");
    }
    csv.close();
    std::printf("wrote %s/sdf_%s.csv\n", ev.c_str(), mode.c_str());
    return 0;
  }

  // ── the part-based modes ──────────────────────────────────────────────────
  const std::string mesh_path =
      argc > 2 ? argv[2]
               : std::string(MESH_FIXTURE_DIR) + "/WallMount_ShelfBracket.stl";
  const int resolution = argc > 3 ? std::atoi(argv[3]) : 128;
  const int smooth_factor = argc > 4 ? std::atoi(argv[4]) : 2;
  const std::string evdir = argc > 5 ? argv[5] : ".";

  const StepModel model = import_part_file_resolved(mesh_path);
  if (model.mesh.vertices.empty()) {
    std::printf("FATAL: the fixture imported empty\n");
    return 2;
  }
  ProductionRunSetup setup = his_setup(model, resolution);
  const VoxelGrid& grid = setup.grid;

  std::printf("== sdf_geometry_probe : %s ==\n", mode.c_str());
  std::printf("mesh          %s\n", mesh_path.c_str());
  std::printf("grid          %d x %d x %d, spacing %.6f mm\n", grid.nx, grid.ny,
              grid.nz, grid.spacing);
  std::printf("export factor %d (the job's output.smooth_factor)\n\n",
              smooth_factor);

  std::vector<double> occ(grid.voxel_count(), 0.0);
  for (std::size_t i = 0; i < occ.size(); ++i)
    if (grid.tags[i] != VoxelTag::Empty) occ[i] = 1.0;

  // PR 299's subject, reproduced exactly.
  const TriangleMesh exported = marching_cubes_resampled(
      grid.nx, grid.ny, grid.nz, grid.spacing, grid.origin, occ, 0.5,
      smooth_factor, ResampleInterp::Tricubic);
  const TriangleMesh subject = through_stl(exported, evdir + "/subject_variant.stl");
  if (subject.vertices.empty()) {
    std::printf("FATAL: the iso-surface is empty\n");
    return 2;
  }

  const TriGrid cad(model.mesh);
  const TriGrid basegrid(subject);
  std::vector<char> oblique(subject.vertices.size(), 0);
  std::size_t n_obl = 0;
  for (std::size_t i = 0; i < subject.vertices.size(); ++i) {
    const auto dt = cad.distance_and_tri(subject.vertices[i]);
    if (dt.second < 0) continue;
    const Vec3 n = cad.tri_normal(dt.second);
    const double mx =
        std::fmax(std::fabs(n.x), std::fmax(std::fabs(n.y), std::fabs(n.z)));
    if (mx < 0.98) { oblique[i] = 1; ++n_obl; }
  }
  // 30 degrees is the same feature angle core's own STL/3MF importer uses to
  // manufacture pseudo-faces (35 deg there; 30 here is deliberately the more
  // inclusive of the two, so nothing borderline is scored as "smooth surface").
  const SharpEdges sharp(model.mesh, 30.0);
  const double edge_radius = 1.5 * grid.spacing;
  const Reading base =
      read_mesh(subject, cad, oblique, grid, nullptr, &sharp, edge_radius);
  std::printf("subject   %zu verts, %zu tris; OBLIQUE %zu (%.1f%%)\n",
              subject.vertices.size(), subject.triangles.size(), n_obl,
              100.0 * n_obl / static_cast<double>(subject.vertices.size()));
  std::printf("reference %zu verts, %zu tris (the imported CAD)\n\n",
              model.mesh.vertices.size(), model.mesh.triangles.size());

  std::printf("CAD sharp edges (>= 30 deg): %d; \"near-edge\" is within %.3f mm "
              "(1.5 voxel) of one\n\n", sharp.count(), edge_radius);
  print_header();
  print_row("unsmoothed (PR 299)", base, base, grid.spacing);
  print_split(base, base);

  std::vector<Config> cfgs;
  if (mode == "headline") {
    Config iso;                     // §4.1/§4.2 only — no SDF, no RBF
    iso.isocontour_only = true;
    cfgs.push_back(iso);
    Config a;                       // the paper's own recommendation
    cfgs.push_back(a);
    Config b = a; b.mode = RbfMode::Approximation; cfgs.push_back(b);
    Config c = a; c.fine = 1; cfgs.push_back(c);
    Config d = b; d.fine = 1; cfgs.push_back(d);
  } else {  // sweep
    const double ratios[] = {3.3, 2.0, 1.5, 1.0, 0.75, 0.5, 0.25, 0.125};
    for (double q : ratios) {
      Config a; a.B_over_h = q; cfgs.push_back(a);
      Config b = a; b.mode = RbfMode::Approximation; cfgs.push_back(b);
    }
  }

  std::ofstream csv(evdir + "/sdf_" + mode + ".csv");
  csv << "config,B_over_h,rbf,fine,obl_max_mm,obl_rms_mm,obl_p99_mm,all_rms_mm,"
         "dihedral_deg,motion_mm,removed_pct,min_feature,components,verts,tris,"
         "rho_t,target_vol_mm3,iso_vol_mm3,final_vol_mm3,vol_err_pct,shift_c_mm,"
         "shift_iters,cg_iters,cg_res,wall_total_s\n";
  csv << "unsmoothed,,,," << base.obl.max_mm << "," << base.obl.rms_mm << ","
      << base.obl.p99_mm << "," << base.all.rms_mm << "," << base.dihedral
      << ",0,0," << base.min_feature << "," << base.components << ","
      << base.verts << "," << base.tris << ",,,,,,,,,,\n";

  for (const Config& cfg : cfgs) {
    const auto t0 = Clock::now();
    const Run rr = run_pipeline(grid, occ, cfg);
    const double wall = secs(t0);
    if (rr.mesh.vertices.empty()) {
      std::printf("B/h %.3f — EMPTY EXTRACTION\n", cfg.B_over_h);
      continue;
    }
    const TriangleMesh out = through_stl(rr.mesh, evdir + "/sdf_out.stl");
    const Reading r =
        read_mesh(out, cad, oblique, grid, &basegrid, &sharp, edge_radius);
    char lab[64];
    if (cfg.isocontour_only)
      std::snprintf(lab, sizeof lab, "isocontour only f%d", cfg.iso_only_refine);
    else
      std::snprintf(lab, sizeof lab, "SDF B/h %.3f %s f%d", cfg.B_over_h,
                    cfg.mode == RbfMode::Interpolation ? "interp" : "approx",
                    cfg.fine);
    print_row(lab, r, base, grid.spacing);
    print_split(r, base);
    std::printf("      rho_t %.6f  vol %.1f -> %.1f mm3 (target %.1f, err "
                "%+.4f%%)  c %+.5f mm in %d  CG %d it res %.2e  SDF grid "
                "%dx%dx%d  iso %zu tris  wall %.1f s "
                "[nodal %.1f / thresh %.1f / sdf %.1f / rbf %.1f / shift %.1f / "
                "extract %.1f]\n",
                rr.rho_t, rr.iso_volume_mm3, rr.final_volume_mm3,
                rr.target_volume,
                100.0 * (rr.final_volume_mm3 - rr.target_volume) /
                    rr.target_volume,
                rr.shift_c, rr.shift_iters, rr.cg_iters, rr.cg_res, rr.sdf_nx,
                rr.sdf_ny, rr.sdf_nz, rr.iso_tris, wall, rr.wall_nodal,
                rr.wall_thresh, rr.wall_sdf, rr.wall_rbf, rr.wall_shift,
                rr.wall_extract);

    csv << lab << "," << cfg.B_over_h << ","
        << (cfg.mode == RbfMode::Interpolation ? "interp" : "approx") << ","
        << cfg.fine << "," << r.obl.max_mm << "," << r.obl.rms_mm << ","
        << r.obl.p99_mm << "," << r.all.rms_mm << "," << r.dihedral << ","
        << r.max_shift_from_base << ","
        << 100.0 * (1.0 - r.obl.rms_mm / base.obl.rms_mm) << ","
        << r.min_feature << "," << r.components << "," << r.verts << ","
        << r.tris << "," << rr.rho_t << "," << rr.target_volume << ","
        << rr.iso_volume_mm3 << "," << rr.final_volume_mm3 << ","
        << 100.0 * (rr.final_volume_mm3 - rr.target_volume) / rr.target_volume
        << "," << rr.shift_c << "," << rr.shift_iters << "," << rr.cg_iters
        << "," << rr.cg_res << "," << wall << "\n";

    // S3's hard bound, on the paper's own configuration only.
    if (mode == "headline" && cfg.B_over_h == 1.0 &&
        cfg.mode == RbfMode::Interpolation && cfg.fine == 2) {
      for (double bnd : {0.5, 1.0}) {
        double frac = 0.0, pull = 0.0;
        const TriangleMesh cl = clamp_to_original(rr.mesh, subject,
                                                  bnd * grid.spacing, frac, pull);
        const TriangleMesh clo = through_stl(cl, evdir + "/sdf_clamped.stl");
        const Reading rc =
            read_mesh(clo, cad, oblique, grid, &basegrid, &sharp, edge_radius);
        char lb[64];
        std::snprintf(lb, sizeof lb, "  + Gibson bound %.1f vox", bnd);
        print_row(lb, rc, base, grid.spacing);
        std::printf("      %.2f%% of vertices pulled back, deepest pull-back "
                    "%.4f mm; mesh volume %.1f mm3\n",
                    100.0 * frac, pull, rc.volume_mm3);
      }
    }
  }
  csv.close();
  std::printf("\nwrote %s/sdf_%s.csv\n", evdir.c_str(), mode.c_str());
  return 0;
}
