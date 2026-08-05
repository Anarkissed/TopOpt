// stairstep_probe — S1 of task 2026-08-05-smoothing-must-actually-smooth.
//
// THE GO/NO-GO QUESTION, MEASURED: can `constrained_taubin_smooth` remove the
// stair-stepping a voxelized design carries, and at what cost?
//
// THE REPORT. The maintainer brushed a variant, waited minutes, and saw NO
// DISCERNIBLE DIFFERENCE between Original and Smoothed. The page's own copy said
// the deepest displacement was 0.29-0.49 mm. The task brief put his part at
// 218.28 mm across with a ~1.705 mm voxel; MEASURED, the longest bounding-box
// axis is 207.365 mm and the voxel is 1.620040 mm (the ARITHMETIC block prints
// both). The framing survives the correction: 0.29-0.49 mm is 17.9%-30.2% of ONE
// step, a fifth to a quarter of a single terrace.
//
// THE METRIC (bar R3). SURFACE DEVIATION FROM THE PRE-VOXELIZATION CAD, in mm:
// for every vertex of the exported iso-surface, the unsigned distance to the
// nearest point on the ORIGINAL imported triangle mesh. Justification: the
// staircase is not an intrinsic property of the exported mesh — it is the
// difference between that mesh and the smooth surface it was supposed to
// represent, and the only object that knows the smooth surface is the CAD the
// voxelizer consumed. An intrinsic roughness number (dihedral angles, normal
// variation) cannot tell "the steps were removed" from "the part was melted into
// a blob": both reduce it. Deviation-from-CAD cannot be fooled that way — melting
// the part RAISES it. So it is a metric with a floor (0, the surface is exactly
// the CAD) that a cheat cannot reach. It is reported as max, RMS and p99, both in
// mm and as a fraction of the voxel spacing, and it is why the subject below has
// to be the part's own voxelization rather than an optimizer variant: an
// optimizer variant has no pre-voxelization surface to be measured against.
//
// The dihedral-angle roughness of the mesh itself is printed BESIDE it as
// corroboration (the two must move together for the reading to mean what it
// says), never as the headline.
//
// THE SUBJECT is what the app actually smooths: the variant STL the run wrote,
// which is `marching_cubes_resampled(..., factor = job.output.smooth_factor,
// Tricubic)` of the design field — his job.json carries smooth_factor 2 — welded
// by core's own importer. Here the design field is the part's own occupancy at
// the job's resolution, so the CAD reference exists.
//
// A HARNESS, not a ctest: it prints tables and writes evidence. It asserts only
// the preconditions that would make its own numbers meaningless.
//
//   cmake --build core/build --target stairstep_probe
//   ./core/build/stairstep_probe [mesh] [res] [smooth_factor] [evidence_dir]

#include "topopt/face_overrides.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/mesh.hpp"
#include "topopt/production.hpp"
#include "topopt/smooth.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <map>
#include <string>
#include <vector>

using namespace topopt;

namespace {

using Clock = std::chrono::steady_clock;
double secs_since(const Clock::time_point& t) {
  return std::chrono::duration<double>(Clock::now() - t).count();
}

// ── point-to-triangle distance, and a uniform grid to make it affordable ─────

double dist2_point_triangle(const Vec3& p, const Vec3& a, const Vec3& b,
                            const Vec3& c) {
  // Ericson, Real-Time Collision Detection §5.1.5 — closest point on a triangle.
  const Vec3 ab{b.x - a.x, b.y - a.y, b.z - a.z};
  const Vec3 ac{c.x - a.x, c.y - a.y, c.z - a.z};
  const Vec3 ap{p.x - a.x, p.y - a.y, p.z - a.z};
  const double d1 = ab.x * ap.x + ab.y * ap.y + ab.z * ap.z;
  const double d2 = ac.x * ap.x + ac.y * ap.y + ac.z * ap.z;
  auto d2_to = [&](const Vec3& q) {
    const double dx = p.x - q.x, dy = p.y - q.y, dz = p.z - q.z;
    return dx * dx + dy * dy + dz * dz;
  };
  if (d1 <= 0.0 && d2 <= 0.0) return d2_to(a);

  const Vec3 bp{p.x - b.x, p.y - b.y, p.z - b.z};
  const double d3 = ab.x * bp.x + ab.y * bp.y + ab.z * bp.z;
  const double d4 = ac.x * bp.x + ac.y * bp.y + ac.z * bp.z;
  if (d3 >= 0.0 && d4 <= d3) return d2_to(b);

  const double vc = d1 * d4 - d3 * d2;
  if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
    const double v = d1 / (d1 - d3);
    return d2_to(Vec3{a.x + v * ab.x, a.y + v * ab.y, a.z + v * ab.z});
  }

  const Vec3 cp{p.x - c.x, p.y - c.y, p.z - c.z};
  const double d5 = ab.x * cp.x + ab.y * cp.y + ab.z * cp.z;
  const double d6 = ac.x * cp.x + ac.y * cp.y + ac.z * cp.z;
  if (d6 >= 0.0 && d5 <= d6) return d2_to(c);

  const double vb = d5 * d2 - d1 * d6;
  if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
    const double w = d2 / (d2 - d6);
    return d2_to(Vec3{a.x + w * ac.x, a.y + w * ac.y, a.z + w * ac.z});
  }

  const double va = d3 * d6 - d5 * d4;
  if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
    const double w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
    return d2_to(Vec3{b.x + w * (c.x - b.x), b.y + w * (c.y - b.y),
                      b.z + w * (c.z - b.z)});
  }

  const double denom = 1.0 / (va + vb + vc);
  const double v = vb * denom, w = vc * denom;
  return d2_to(Vec3{a.x + ab.x * v + ac.x * w, a.y + ab.y * v + ac.y * w,
                    a.z + ab.z * v + ac.z * w});
}

// Uniform grid over the reference triangles. Exact (not approximate): the query
// grows a Chebyshev box until the best distance found is no larger than the box
// half-width, at which point no triangle outside the box can beat it.
class TriGrid {
 public:
  explicit TriGrid(const TriangleMesh& m) : mesh_(&m) {
    if (m.triangles.empty()) return;
    Vec3 lo = m.vertices[0], hi = m.vertices[0];
    for (const Vec3& v : m.vertices) {
      lo.x = std::fmin(lo.x, v.x); hi.x = std::fmax(hi.x, v.x);
      lo.y = std::fmin(lo.y, v.y); hi.y = std::fmax(hi.y, v.y);
      lo.z = std::fmin(lo.z, v.z); hi.z = std::fmax(hi.z, v.z);
    }
    origin_ = lo;
    const double ex = hi.x - lo.x, ey = hi.y - lo.y, ez = hi.z - lo.z;
    const double vol = std::fmax(ex * ey * ez, 1e-12);
    // ~1 triangle per cell on average, clamped so the grid stays sane.
    cell_ = std::cbrt(vol / static_cast<double>(m.triangles.size()));
    cell_ = std::fmax(cell_, 1e-6);
    nx_ = std::clamp(static_cast<int>(ex / cell_) + 1, 1, 256);
    ny_ = std::clamp(static_cast<int>(ey / cell_) + 1, 1, 256);
    nz_ = std::clamp(static_cast<int>(ez / cell_) + 1, 1, 256);
    cell_ = std::fmax(std::fmax(ex / nx_, ey / ny_), ez / nz_);
    cell_ = std::fmax(cell_, 1e-6);
    bins_.assign(static_cast<std::size_t>(nx_) * ny_ * nz_, {});
    for (std::size_t t = 0; t < m.triangles.size(); ++t) {
      const auto& tr = m.triangles[t];
      Vec3 tlo = m.vertices[static_cast<std::size_t>(tr[0])], thi = tlo;
      for (int k = 1; k < 3; ++k) {
        const Vec3& v = m.vertices[static_cast<std::size_t>(tr[k])];
        tlo.x = std::fmin(tlo.x, v.x); thi.x = std::fmax(thi.x, v.x);
        tlo.y = std::fmin(tlo.y, v.y); thi.y = std::fmax(thi.y, v.y);
        tlo.z = std::fmin(tlo.z, v.z); thi.z = std::fmax(thi.z, v.z);
      }
      const int i0 = clampi(cellof(tlo.x - origin_.x), nx_);
      const int i1 = clampi(cellof(thi.x - origin_.x), nx_);
      const int j0 = clampi(cellof(tlo.y - origin_.y), ny_);
      const int j1 = clampi(cellof(thi.y - origin_.y), ny_);
      const int k0 = clampi(cellof(tlo.z - origin_.z), nz_);
      const int k1 = clampi(cellof(thi.z - origin_.z), nz_);
      for (int k = k0; k <= k1; ++k)
        for (int j = j0; j <= j1; ++j)
          for (int i = i0; i <= i1; ++i)
            bins_[idx(i, j, k)].push_back(static_cast<int>(t));
    }
  }

  // Unsigned distance from `p` to the nearest point on the reference surface.
  double distance(const Vec3& p) const { return distance_and_tri(p).first; }

  // The distance AND the index of the reference triangle that carried it, so a
  // caller can ask what KIND of surface this vertex was supposed to sit on.
  std::pair<double, int> distance_and_tri(const Vec3& p) const {
    if (!mesh_ || mesh_->triangles.empty()) return {0.0, -1};
    int best_t = -1;
    double best2 = std::numeric_limits<double>::infinity();
    double r = cell_;
    for (int iter = 0; iter < 64; ++iter) {
      const int i0 = clampi(cellof(p.x - r - origin_.x), nx_);
      const int i1 = clampi(cellof(p.x + r - origin_.x), nx_);
      const int j0 = clampi(cellof(p.y - r - origin_.y), ny_);
      const int j1 = clampi(cellof(p.y + r - origin_.y), ny_);
      const int k0 = clampi(cellof(p.z - r - origin_.z), nz_);
      const int k1 = clampi(cellof(p.z + r - origin_.z), nz_);
      for (int k = k0; k <= k1; ++k)
        for (int j = j0; j <= j1; ++j)
          for (int i = i0; i <= i1; ++i)
            for (const int t : bins_[idx(i, j, k)]) {
              const auto& tr = mesh_->triangles[static_cast<std::size_t>(t)];
              const double d2 = dist2_point_triangle(
                  p, mesh_->vertices[static_cast<std::size_t>(tr[0])],
                  mesh_->vertices[static_cast<std::size_t>(tr[1])],
                  mesh_->vertices[static_cast<std::size_t>(tr[2])]);
              if (d2 < best2) { best2 = d2; best_t = t; }
            }
      if (best2 <= r * r) break;  // nothing outside the box can beat it
      r *= 2.0;
    }
    return {std::sqrt(best2), best_t};
  }

  // Unit normal of reference triangle `t`.
  Vec3 tri_normal(int t) const {
    const auto& tr = mesh_->triangles[static_cast<std::size_t>(t)];
    const Vec3& a = mesh_->vertices[static_cast<std::size_t>(tr[0])];
    const Vec3& b = mesh_->vertices[static_cast<std::size_t>(tr[1])];
    const Vec3& c = mesh_->vertices[static_cast<std::size_t>(tr[2])];
    const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z};
    const Vec3 v{c.x - a.x, c.y - a.y, c.z - a.z};
    Vec3 n{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x};
    const double L = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (L > 0.0) { n.x /= L; n.y /= L; n.z /= L; }
    return n;
  }

 private:
  int cellof(double d) const { return static_cast<int>(std::floor(d / cell_)); }
  static int clampi(int v, int n) { return v < 0 ? 0 : (v >= n ? n - 1 : v); }
  std::size_t idx(int i, int j, int k) const {
    return static_cast<std::size_t>(k) * ny_ * nx_ +
           static_cast<std::size_t>(j) * nx_ + static_cast<std::size_t>(i);
  }
  const TriangleMesh* mesh_ = nullptr;
  Vec3 origin_;
  double cell_ = 1.0;
  int nx_ = 1, ny_ = 1, nz_ = 1;
  std::vector<std::vector<int>> bins_;
};

// ── the two readings ─────────────────────────────────────────────────────────

struct Deviation {
  double max_mm = 0.0;
  double rms_mm = 0.0;
  double p99_mm = 0.0;
  double mean_mm = 0.0;
};

// `only` empty ⇒ every vertex. Otherwise entry v selects vertex v — used to
// restrict the reading to the OBLIQUE surface, where stair-stepping lives.
Deviation deviation_from_cad(const TriangleMesh& m, const TriGrid& ref,
                             const std::vector<char>& only = {}) {
  Deviation d;
  if (m.vertices.empty()) return d;
  std::vector<double> all;
  all.reserve(m.vertices.size());
  double sum2 = 0.0, sum = 0.0;
  for (std::size_t i = 0; i < m.vertices.size(); ++i) {
    if (!only.empty() && !only[i]) continue;
    const double x = ref.distance(m.vertices[i]);
    all.push_back(x);
    sum2 += x * x;
    sum += x;
    if (x > d.max_mm) d.max_mm = x;
  }
  if (all.empty()) return d;
  const double n = static_cast<double>(all.size());
  d.rms_mm = std::sqrt(sum2 / n);
  d.mean_mm = sum / n;
  std::size_t k = static_cast<std::size_t>(0.99 * (n - 1.0));
  std::nth_element(all.begin(), all.begin() + static_cast<long>(k), all.end());
  d.p99_mm = all[k];
  return d;
}

// RMS dihedral angle (degrees) across every shared edge. A voxel staircase is
// 90-degree risers joined by 45-degree marching-cubes chamfers; a smooth surface
// is a few degrees. Corroboration only — see the header note.
double dihedral_rms_deg(const TriangleMesh& m) {
  std::map<std::pair<int, int>, std::vector<std::size_t>> edges;
  for (std::size_t t = 0; t < m.triangles.size(); ++t) {
    const auto& tr = m.triangles[t];
    for (int e = 0; e < 3; ++e) {
      int a = tr[e], b = tr[(e + 1) % 3];
      if (a > b) std::swap(a, b);
      edges[{a, b}].push_back(t);
    }
  }
  std::vector<Vec3> nrm(m.triangles.size());
  for (std::size_t t = 0; t < m.triangles.size(); ++t) {
    const auto& tr = m.triangles[t];
    const Vec3& a = m.vertices[static_cast<std::size_t>(tr[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(tr[1])];
    const Vec3& c = m.vertices[static_cast<std::size_t>(tr[2])];
    const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z};
    const Vec3 v{c.x - a.x, c.y - a.y, c.z - a.z};
    Vec3 n{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x};
    const double L = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (L > 0.0) { n.x /= L; n.y /= L; n.z /= L; }
    nrm[t] = n;
  }
  double sum2 = 0.0;
  std::size_t cnt = 0;
  for (const auto& kv : edges) {
    if (kv.second.size() != 2) continue;
    const Vec3& a = nrm[kv.second[0]];
    const Vec3& b = nrm[kv.second[1]];
    double c = a.x * b.x + a.y * b.y + a.z * b.z;
    c = std::fmax(-1.0, std::fmin(1.0, c));
    const double deg = std::acos(c) * 180.0 / 3.14159265358979323846;
    sum2 += deg * deg;
    ++cnt;
  }
  return cnt ? std::sqrt(sum2 / static_cast<double>(cnt)) : 0.0;
}

double max_shift_mm(const TriangleMesh& a, const TriangleMesh& b) {
  double m = 0.0;
  const std::size_t n = std::min(a.vertices.size(), b.vertices.size());
  for (std::size_t i = 0; i < n; ++i) {
    const double dx = a.vertices[i].x - b.vertices[i].x;
    const double dy = a.vertices[i].y - b.vertices[i].y;
    const double dz = a.vertices[i].z - b.vertices[i].z;
    m = std::fmax(m, std::sqrt(dx * dx + dy * dy + dz * dz));
  }
  return m;
}

int min_feature_now(const TriangleMesh& m, const VoxelGrid& ref) {
  try {
    const VoxelGrid g = voxelize_onto_grid(m, ref);
    std::vector<double> d(g.voxel_count(), 0.0);
    for (std::size_t i = 0; i < d.size(); ++i)
      if (g.tags[i] != VoxelTag::Empty) d[i] = 1.0;
    return min_feature_violations(g, d, 0.5);
  } catch (const std::exception&) {
    return -1;
  }
}

}  // namespace

// ── THE ANALYTIC CONTROL ─────────────────────────────────────────────────────
//
// The bracket's "CAD" is itself a 2224-triangle tessellation, so a slice of the
// deviation measured against it is the REFERENCE's own faceting rather than the
// voxelizer's staircase. A sphere has no such ambiguity: the exact surface is
// known in closed form, so the deviation |‖v−c‖ − R| is the voxelization error
// and nothing else. Run at the SAME voxel spacing as his part, so the staircase
// is the same physical size. This is the fixture the S1 assertion uses.
struct SphereReading {
  double max_mm = 0.0;
  double rms_mm = 0.0;
};

SphereReading sphere_deviation(const TriangleMesh& m, const Vec3& c, double R) {
  SphereReading s;
  if (m.vertices.empty()) return s;
  double sum2 = 0.0;
  for (const Vec3& v : m.vertices) {
    const double dx = v.x - c.x, dy = v.y - c.y, dz = v.z - c.z;
    const double e = std::fabs(std::sqrt(dx * dx + dy * dy + dz * dz) - R);
    sum2 += e * e;
    if (e > s.max_mm) s.max_mm = e;
  }
  s.rms_mm = std::sqrt(sum2 / static_cast<double>(m.vertices.size()));
  return s;
}

// An occupancy grid holding a solid sphere, at `spacing`, sampled at voxel
// centres exactly as the voxelizer decides occupancy.
VoxelGrid sphere_grid(double R, double spacing, Vec3& centre_out) {
  const int n = static_cast<int>(std::ceil(2.4 * R / spacing));
  VoxelGrid g;
  g.nx = g.ny = g.nz = n;
  g.spacing = spacing;
  g.origin = Vec3{0.0, 0.0, 0.0};
  // NOT voxel_count() — that reads tags.size(), which is still 0 here.
  g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Empty);
  const double half = 0.5 * static_cast<double>(n) * spacing;
  centre_out = Vec3{half, half, half};
  for (int k = 0; k < n; ++k)
    for (int j = 0; j < n; ++j)
      for (int i = 0; i < n; ++i) {
        const Vec3 p = g.voxel_center(i, j, k);
        const double dx = p.x - centre_out.x, dy = p.y - centre_out.y,
                     dz = p.z - centre_out.z;
        if (dx * dx + dy * dy + dz * dz <= R * R)
          g.tags[g.index(i, j, k)] = VoxelTag::Interior;
      }
  return g;
}

int main(int argc, char** argv) {
  const std::string mesh_path =
      argc > 1 ? argv[1]
               : std::string(MESH_FIXTURE_DIR) + "/WallMount_ShelfBracket.stl";
  const int resolution = argc > 2 ? std::atoi(argv[2]) : 128;
  const int smooth_factor = argc > 3 ? std::atoi(argv[3]) : 2;
  const std::string evidence_dir = argc > 4 ? argv[4] : "";

  std::printf("== stairstep_probe ==\n");
  std::printf("mesh          %s\n", mesh_path.c_str());
  std::printf("resolution    %d\n", resolution);
  std::printf("smooth_factor %d (the job's output.smooth_factor)\n\n", smooth_factor);

  StepModel model = import_part_file_resolved(mesh_path);
  if (model.mesh.vertices.empty()) {
    std::printf("FATAL: the fixture imported empty\n");
    return 2;
  }

  // HIS LOAD CASE, as the app's smoothing path builds it. This is not decoration:
  // `SmoothBrushKit.bridgeLoadCase` (SmoothBrushKit.swift:119) sets
  // `minimize_plastic = false`, which puts `build_production_loadcase` on the
  // GROWTH path and makes it auto-derive a minimal growth design box — a LARGER
  // grid than the part's own bounding box, with a different origin. The
  // min-feature constraint voxelizes onto THAT grid, and the verdict it reaches
  // is not the same one it reaches on the part-bbox grid. Measuring on the wrong
  // grid answers a question the maintainer did not ask.
  //
  // The numbers below come from his own `job.json`
  // (evidence/2026-08-03-preflight-feasibility-and-divergence/maintainer-job).
  ProductionLoadCase lc;
  lc.anchor_face_ids = {8, 14, 12};
  {
    ProductionLoadCase::LoadGroup g;
    g.face_ids = {0};
    g.force = Vec3{0.0, -155.6879425048828, 0.0};
    lc.load_groups.push_back(g);
  }
  lc.minimize_plastic = false;  // SmoothBrushKit.swift:119 — "a fixed design"
  lc.build_dir = Vec3{0.0, 1.0, 0.0};
  lc.infill_percent = 35.0;
  ProductionRunSetup setup = build_production_loadcase(model, resolution, lc);
  setup.options.bake_build_orientation = BakeBuildOrientation::Off;
  const VoxelGrid& grid = setup.grid;

  // ── THE ARITHMETIC THE TASK ASKED TO CHECK FIRST ────────────────────────────
  Vec3 lo = model.mesh.vertices[0], hi = lo;
  for (const Vec3& v : model.mesh.vertices) {
    lo.x = std::fmin(lo.x, v.x); hi.x = std::fmax(hi.x, v.x);
    lo.y = std::fmin(lo.y, v.y); hi.y = std::fmax(hi.y, v.y);
    lo.z = std::fmin(lo.z, v.z); hi.z = std::fmax(hi.z, v.z);
  }
  const double ex = hi.x - lo.x, ey = hi.y - lo.y, ez = hi.z - lo.z;
  const double longest = std::fmax(ex, std::fmax(ey, ez));
  std::printf("-- ARITHMETIC ------------------------------------------------\n");
  std::printf("part bbox        %.3f x %.3f x %.3f mm (longest %.3f)\n", ex, ey,
              ez, longest);
  std::printf("grid             %d x %d x %d, spacing %.6f mm\n", grid.nx,
              grid.ny, grid.nz, grid.spacing);
  std::printf("ONE VOXEL        %.4f mm  <- the stair-step scale\n", grid.spacing);
  std::printf("reported deepest 0.29 - 0.49 mm  =  %.1f%% - %.1f%% of one voxel\n\n",
              100.0 * 0.29 / grid.spacing, 100.0 * 0.49 / grid.spacing);

  // ── the subject: the exported variant surface ───────────────────────────────
  std::vector<double> occ(grid.voxel_count(), 0.0);
  for (std::size_t i = 0; i < occ.size(); ++i)
    if (grid.tags[i] != VoxelTag::Empty) occ[i] = 1.0;

  const TriangleMesh exported = marching_cubes_resampled(
      grid.nx, grid.ny, grid.nz, grid.spacing, grid.origin, occ, 0.5,
      smooth_factor, ResampleInterp::Tricubic);

  // ── THE SUBJECT GOES THROUGH THE STL ROUND TRIP, BECAUSE THE APP DOES ───────
  //
  // The page never hands core an in-memory mesh. It writes the variant to
  // `variant_N.stl` (WorkspacePlaceholder.swift:1692) and every consumer — the
  // brush, the freeze mask, the smoother, the certification — imports it back.
  // STL stores float32 and core's importer welds by EXACT coordinate.
  //
  // That round trip is NOT cosmetic here. Marching cubes puts a crossing exactly
  // halfway between two samples wherever the field steps 0 -> 1, and at
  // factor 2 that midpoint lands exactly ON a coarse voxel centre — so thousands
  // of voxel-centre inside/outside tests sit on a knife edge. float32 rounding
  // pushes them off it, consistently. Measured below: the SAME 82104 vertices and
  // 164228 triangles read min-feature 2162 in memory and 6 after the round trip.
  // Measuring the in-memory mesh would answer a question about an artefact of
  // double-precision marching cubes, not about the maintainer's part.
  const std::string subject_path =
      (evidence_dir.empty() ? std::string(".") : evidence_dir) +
      "/subject_variant.stl";
  write_stl_file(subject_path, exported);
  const TriangleMesh subject = import_part_file_resolved(subject_path).mesh;
  if (subject.vertices.empty()) {
    std::printf("FATAL: the iso-surface is empty\n");
    return 2;
  }
  std::printf("subject       %zu verts, %zu tris (marching_cubes_resampled "
              "factor %d, Tricubic — the shipped export path)\n",
              subject.vertices.size(), subject.triangles.size(), smooth_factor);
  std::printf("reference     %zu verts, %zu tris (the imported CAD, "
              "pre-voxelization)\n\n",
              model.mesh.vertices.size(), model.mesh.triangles.size());

  std::printf("-- THE STL ROUND TRIP, MEASURED ------------------------------\n");
  std::printf("in memory   %zu verts, %zu tris, min-feature %d\n",
              exported.vertices.size(), exported.triangles.size(),
              min_feature_now(exported, grid));
  std::printf("re-imported %zu verts, %zu tris, min-feature %d  <- THE SUBJECT\n\n",
              subject.vertices.size(), subject.triangles.size(),
              min_feature_now(subject, grid));

  const TriGrid ref(model.mesh);

  // ── WHERE STAIR-STEPPING ACTUALLY IS ────────────────────────────────────────
  //
  // An AXIS-ALIGNED face of this bracket has no staircase at all: the voxel
  // lattice is parallel to it, so the iso-surface is a plane offset from the CAD
  // plane by up to half a voxel. That offset is a rigid translation of a whole
  // patch — a LOW-frequency error, and one no smoother of any kind can remove,
  // because there is nothing locally wrong with the surface to smooth. Averaging
  // it into the headline would make the operator look worse than it is on the
  // surface it is actually asked to fix.
  //
  // So each vertex is classified ONCE, from the UNSMOOTHED subject, by the normal
  // of the CAD triangle nearest to it: |n| within 0.02 of an axis ⇒ AXIS-ALIGNED,
  // otherwise OBLIQUE — the fillets, the bore walls and the angled webs, which
  // are exactly the surfaces a voxel lattice terraces. Smoothing is then judged
  // on the OBLIQUE set. Classification is fixed at t=0 so every row compares the
  // same vertices; the smoother never changes which vertex is which.
  std::vector<char> oblique(subject.vertices.size(), 0);
  std::size_t n_oblique = 0;
  for (std::size_t i = 0; i < subject.vertices.size(); ++i) {
    const auto dt = ref.distance_and_tri(subject.vertices[i]);
    if (dt.second < 0) continue;
    const Vec3 n = ref.tri_normal(dt.second);
    const double m = std::fmax(std::fabs(n.x),
                               std::fmax(std::fabs(n.y), std::fabs(n.z)));
    if (m < 0.98) { oblique[i] = 1; ++n_oblique; }
  }

  auto t_dev0 = Clock::now();
  const Deviation base_dev = deviation_from_cad(subject, ref);
  const double dev_secs = secs_since(t_dev0);
  const Deviation base_obl = deviation_from_cad(subject, ref, oblique);
  const double base_dih = dihedral_rms_deg(subject);
  const int base_mf = min_feature_now(subject, grid);

  std::printf("-- BASELINE (no smoothing) ------------------------------------\n");
  std::printf("OBLIQUE vertices     %zu of %zu (%.1f%%) — the surface that has "
              "a staircase\n",
              n_oblique, subject.vertices.size(),
              100.0 * static_cast<double>(n_oblique) /
                  static_cast<double>(subject.vertices.size()));
  std::printf("deviation, OBLIQUE   max %.4f mm (%.2f voxel)  rms %.4f mm "
              "(%.2f voxel)  p99 %.4f mm\n",
              base_obl.max_mm, base_obl.max_mm / grid.spacing, base_obl.rms_mm,
              base_obl.rms_mm / grid.spacing, base_obl.p99_mm);
  std::printf("deviation, ALL       max %.4f mm (%.2f voxel)  rms %.4f mm "
              "(%.2f voxel)  p99 %.4f mm\n",
              base_dev.max_mm, base_dev.max_mm / grid.spacing, base_dev.rms_mm,
              base_dev.rms_mm / grid.spacing, base_dev.p99_mm);
  std::printf("dihedral rms         %.2f deg\n", base_dih);
  std::printf("min-feature          %d violations\n", base_mf);
  std::printf("(deviation pass took %.2f s over %zu vertices)\n\n", dev_secs,
              subject.vertices.size());

  // ── the sweep ───────────────────────────────────────────────────────────────
  struct Row {
    int pairs_req = 0, pairs_app = 0;
    bool enforce = false;
    double lambda = 0.0, k_pb = 0.0;
    Deviation dev;   // OBLIQUE only — the surface that has a staircase
    Deviation all;   // every vertex, for the record
    double dih = 0.0;
    double max_shift = 0.0;
    double drift = 0.0, drift_bound = 0.0;
    int mf_base = -1, mf_after = -1;
    bool mf_limited = false;
    double smooth_secs = 0.0;
  };
  std::vector<Row> rows;

  const int pair_sweep[] = {1, 2, 3, 5, 8, 12, 20, 40, 80, 160};

  auto run_one = [&](int pairs, bool enforce, double lambda, double k_pb) {
    TaubinParams p;
    p.pairs = pairs;
    p.lambda = lambda;
    p.k_pb = k_pb;
    SmoothConstraints c;
    c.min_feature_grid = &grid;
    c.enforce_min_feature = enforce;
    const auto t0 = Clock::now();
    const SmoothResult sr = constrained_taubin_smooth(subject, p, c);
    const double smooth_secs = secs_since(t0);

    Row r;
    r.pairs_req = sr.stats.requested_pairs;
    r.pairs_app = sr.stats.applied_pairs;
    r.enforce = enforce;
    r.lambda = lambda;
    r.k_pb = k_pb;
    r.dev = deviation_from_cad(sr.mesh, ref, oblique);
    r.all = deviation_from_cad(sr.mesh, ref);
    r.dih = dihedral_rms_deg(sr.mesh);
    r.max_shift = max_shift_mm(subject, sr.mesh);
    r.drift = sr.stats.volume_drift_fraction;
    r.drift_bound = sr.stats.volume_drift_bound;
    r.mf_base = sr.stats.min_feature_baseline;
    r.mf_after = enforce ? sr.stats.min_feature_after
                         : min_feature_now(sr.mesh, grid);
    r.mf_limited = sr.stats.min_feature_limited;
    r.smooth_secs = smooth_secs;
    rows.push_back(r);
    return r;
  };

  std::printf("-- S1(a)/(b)/(c) THE SWEEP -----------------------------------\n");
  std::printf("Every row is one `constrained_taubin_smooth` on the subject. "
              "`enforce` is\n`SmoothConstraints::enforce_min_feature` — the "
              "SHIPPED setting is ON.\n\n");
  std::printf("The three deviation columns are the OBLIQUE surface — where a\n"
              "staircase exists at all. `allrms` is every vertex, for the "
              "record.\n\n");
  std::printf("%-4s %5s %5s %8s %8s %8s %8s %7s %8s %8s %6s %5s %7s\n", "enf",
              "req", "app", "maxdev", "rmsdev", "p99dev", "allrms", "dihed",
              "maxshift", "drift", "mf", "lim", "wall");
  std::printf("%-4s %5s %5s %8s %8s %8s %8s %7s %8s %8s %6s %5s %7s\n", "",
              "prs", "prs", "mm", "mm", "mm", "mm", "deg", "mm", "frac",
              "viol", "", "s");
  std::printf("%-4s %5s %5s %8.4f %8.4f %8.4f %8.4f %7.2f %8s %8s %6d %5s %7s\n",
              "--", "0", "0", base_obl.max_mm, base_obl.rms_mm, base_obl.p99_mm,
              base_dev.rms_mm, base_dih, "-", "-", base_mf, "-", "-");

  for (const bool enforce : {true, false}) {
    for (const int pr : pair_sweep) {
      // The constrained arm cannot get past its first rejection, so once it has
      // stopped early there is nothing more to learn from a larger request.
      if (enforce && !rows.empty() && rows.back().enforce &&
          rows.back().mf_limited && rows.back().pairs_app == 0 && pr > 3)
        continue;
      const Row r = run_one(pr, enforce, 0.33, 0.1);
      std::printf("%-4s %5d %5d %8.4f %8.4f %8.4f %8.4f %7.2f %8.4f %8.5f %6d "
                  "%5s %7.2f\n",
                  enforce ? "ON" : "off", r.pairs_req, r.pairs_app,
                  r.dev.max_mm, r.dev.rms_mm, r.dev.p99_mm, r.all.rms_mm, r.dih,
                  r.max_shift, r.drift, r.mf_after, r.mf_limited ? "yes" : "no",
                  r.smooth_secs);
      std::fflush(stdout);
    }
  }

  // ── S1(c): lambda / k_pb, unconstrained, at a fixed pair count ──────────────
  std::printf("\n-- S1(c) LAMBDA | K_PB, constraint OFF, 20 pairs -------------\n");
  std::printf("%-6s %-6s %5s %8s %8s %7s %8s %8s %6s %7s\n", "lambda", "k_pb",
              "app", "maxdev", "rmsdev", "dihed", "maxshift", "drift", "mf",
              "wall");
  const double lambdas[] = {0.33, 0.50, 0.70, 0.90};
  const double kpbs[] = {0.05, 0.10, 0.20};
  for (const double L : lambdas)
    for (const double K : kpbs) {
      const Row r = run_one(20, false, L, K);
      std::printf("%-6.2f %-6.2f %5d %8.4f %8.4f %7.2f %8.4f %8.5f %6d %7.2f\n",
                  L, K, r.pairs_app, r.dev.max_mm, r.dev.rms_mm, r.dih,
                  r.max_shift, r.drift, r.mf_after, r.smooth_secs);
      std::fflush(stdout);
    }

  // ── S1(d) THE ANALYTIC CONTROL ──────────────────────────────────────────────
  std::printf("\n-- S1(d) ANALYTIC CONTROL: a sphere at the SAME voxel size ---\n");
  std::printf("The reference is exact (|dist to centre - R|), so nothing here is\n"
              "the CAD tessellation's own faceting. R = 20 mm, spacing %.4f mm\n"
              "(%.1f voxels across the radius), export factor %d.\n\n",
              grid.spacing, 20.0 / grid.spacing, smooth_factor);
  {
    Vec3 sc;
    const VoxelGrid sg = sphere_grid(20.0, grid.spacing, sc);
    std::vector<double> socc(sg.voxel_count(), 0.0);
    for (std::size_t i = 0; i < socc.size(); ++i)
      if (sg.tags[i] != VoxelTag::Empty) socc[i] = 1.0;
    const TriangleMesh sraw = marching_cubes_resampled(
        sg.nx, sg.ny, sg.nz, sg.spacing, sg.origin, socc, 0.5, smooth_factor,
        ResampleInterp::Tricubic);
    // Through the same STL round trip the app puts every mesh through.
    const std::string spath =
        (evidence_dir.empty() ? std::string(".") : evidence_dir) +
        "/sphere_control.stl";
    write_stl_file(spath, sraw);
    const TriangleMesh smesh = import_part_file_resolved(spath).mesh;
    std::remove(spath.c_str());  // scratch: the round trip is the point, not the file
    const SphereReading b = sphere_deviation(smesh, sc, 20.0);
    std::printf("%-4s %5s %5s %9s %9s %8s %7s %8s %6s\n", "enf", "req", "app",
                "maxdev", "rmsdev", "%of base", "dihed", "maxshift", "mf");
    std::printf("%-4s %5s %5s %9.4f %9.4f %8s %7.2f %8s %6d\n", "--", "0", "0",
                b.max_mm, b.rms_mm, "100.0", dihedral_rms_deg(smesh),
                "-", min_feature_now(smesh, sg));
    // THE VISUAL (bar R3): the radial profile of an equatorial band. Each row is
    // one vertex within half a voxel of the z = centre plane, as (angle, radius).
    // On a voxelized sphere this traces the staircase directly; a smoother that
    // removed it would flatten the trace onto R.
    auto write_profile = [&](const std::string& name, const TriangleMesh& m) {
      std::ofstream f(evidence_dir + "/sphere_profile_" + name + ".csv");
      f << "angle_deg,radius_mm\n";
      for (const Vec3& v : m.vertices) {
        if (std::fabs(v.z - sc.z) > 0.5 * grid.spacing) continue;
        const double dx = v.x - sc.x, dy = v.y - sc.y;
        f << std::atan2(dy, dx) * 180.0 / 3.14159265358979323846 << ","
          << std::sqrt(dx * dx + dy * dy) << "\n";
      }
    };
    if (!evidence_dir.empty()) write_profile("baseline", smesh);

    for (const bool enforce : {true, false})
      for (const int pr : {1, 5, 20, 80, 160}) {
        TaubinParams p;
        p.pairs = pr;
        SmoothConstraints c;
        c.min_feature_grid = &sg;
        c.enforce_min_feature = enforce;
        const SmoothResult sr = constrained_taubin_smooth(smesh, p, c);
        if (!evidence_dir.empty() && !enforce && (pr == 20 || pr == 160))
          write_profile(std::string("pairs") + std::to_string(pr), sr.mesh);
        const SphereReading a = sphere_deviation(sr.mesh, sc, 20.0);
        std::printf("%-4s %5d %5d %9.4f %9.4f %8.1f %7.2f %8.4f %6d\n",
                    enforce ? "ON" : "off", pr, sr.stats.applied_pairs, a.max_mm,
                    a.rms_mm, 100.0 * a.rms_mm / b.rms_mm,
                    dihedral_rms_deg(sr.mesh), max_shift_mm(smesh, sr.mesh),
                    enforce ? sr.stats.min_feature_after
                            : min_feature_now(sr.mesh, sg));
        std::fflush(stdout);
      }
  }

  // ── S1(e) WHAT DOES CONTROL THE AMPLITUDE ───────────────────────────────────
  std::printf("\n-- S1(e) CONTROL: resolution and export factor, NO smoothing --\n");
  std::printf("Same measurement, same part. This is what the amplitude actually\n"
              "responds to.\n\n");
  std::printf("%-5s %9s %9s %9s %9s %9s\n", "res", "spacing", "obl maxdev",
              "obl rmsdev", "all rmsdev", "dihed");
  for (const int r : {64, 128, 256}) {
    ProductionRunSetup s2 = build_production_loadcase(model, r, lc);
    s2.options.bake_build_orientation = BakeBuildOrientation::Off;
    const VoxelGrid& g2 = s2.grid;
    std::vector<double> o2(g2.voxel_count(), 0.0);
    for (std::size_t i = 0; i < o2.size(); ++i)
      if (g2.tags[i] != VoxelTag::Empty) o2[i] = 1.0;
    const TriangleMesh m2raw = marching_cubes_resampled(
        g2.nx, g2.ny, g2.nz, g2.spacing, g2.origin, o2, 0.5, smooth_factor,
        ResampleInterp::Tricubic);
    const std::string p2 =
        (evidence_dir.empty() ? std::string(".") : evidence_dir) +
        "/res_control.stl";
    write_stl_file(p2, m2raw);
    const TriangleMesh m2 = import_part_file_resolved(p2).mesh;
    std::remove(p2.c_str());  // scratch, and 33 MB at res 256
    std::vector<char> ob2(m2.vertices.size(), 0);
    for (std::size_t i = 0; i < m2.vertices.size(); ++i) {
      const auto dt = ref.distance_and_tri(m2.vertices[i]);
      if (dt.second < 0) continue;
      const Vec3 n = ref.tri_normal(dt.second);
      const double mx = std::fmax(std::fabs(n.x),
                                  std::fmax(std::fabs(n.y), std::fabs(n.z)));
      if (mx < 0.98) ob2[i] = 1;
    }
    const Deviation d_ob = deviation_from_cad(m2, ref, ob2);
    const Deviation d_all = deviation_from_cad(m2, ref);
    std::printf("%-5d %9.4f %9.4f %9.4f %9.4f %9.2f\n", r, g2.spacing,
                d_ob.max_mm, d_ob.rms_mm, d_all.rms_mm, dihedral_rms_deg(m2));
    std::fflush(stdout);
  }

  // ── S1(f) THE OTHER KNOB, AND WHY IT IS NOT ONE ─────────────────────────────
  //
  // Export tessellation is much cheaper than optimize resolution, so "resample
  // the SAME field finer at export" is the obvious cheap version of S1(e). It
  // does not work, and this is the control that says so: the field's resolution
  // is fixed, only `smooth_factor` moves.
  //
  // Note the dihedral column while reading it. It falls by more than half across
  // this sweep while the deviation does not move — the same surface, tessellated
  // more finely, in the same wrong place. An intrinsic roughness metric would
  // have called that an improvement. That is the whole reason the headline metric
  // is deviation from the CAD (bar R3).
  std::printf("\n-- S1(f) CONTROL: export smooth_factor at FIXED resolution ----\n");
  std::printf("%-7s %9s %9s %11s %11s %9s\n", "factor", "verts", "tris",
              "obl maxdev", "obl rmsdev", "dihed");
  for (const int f : {1, 2, 4}) {
    const TriangleMesh raw = marching_cubes_resampled(
        grid.nx, grid.ny, grid.nz, grid.spacing, grid.origin, occ, 0.5, f,
        ResampleInterp::Tricubic);
    const std::string fp =
        (evidence_dir.empty() ? std::string(".") : evidence_dir) +
        "/factor_control.stl";
    write_stl_file(fp, raw);
    const TriangleMesh m = import_part_file_resolved(fp).mesh;
    std::remove(fp.c_str());
    std::vector<char> ob(m.vertices.size(), 0);
    for (std::size_t i = 0; i < m.vertices.size(); ++i) {
      const auto dt = ref.distance_and_tri(m.vertices[i]);
      if (dt.second < 0) continue;
      const Vec3 n = ref.tri_normal(dt.second);
      const double mx = std::fmax(std::fabs(n.x),
                                  std::fmax(std::fabs(n.y), std::fabs(n.z)));
      if (mx < 0.98) ob[i] = 1;
    }
    const Deviation d = deviation_from_cad(m, ref, ob);
    std::printf("%-7d %9zu %9zu %11.4f %11.4f %9.2f\n", f, m.vertices.size(),
                m.triangles.size(), d.max_mm, d.rms_mm, dihedral_rms_deg(m));
    std::fflush(stdout);
  }

  // ── S2(a): where the wall time goes ─────────────────────────────────────────
  std::printf("\n-- S2(a) COST BREAKDOWN --------------------------------------\n");
  {
    TaubinParams p;
    p.pairs = 20;
    SmoothConstraints off;
    off.min_feature_grid = &grid;
    off.enforce_min_feature = false;
    auto t0 = Clock::now();
    const SmoothResult s_off = constrained_taubin_smooth(subject, p, off);
    const double t_passes = secs_since(t0);

    t0 = Clock::now();
    const int mf = min_feature_now(subject, grid);
    const double t_revox = secs_since(t0);

    SmoothConstraints on = off;
    on.enforce_min_feature = true;
    t0 = Clock::now();
    const SmoothResult s_on = constrained_taubin_smooth(subject, p, on);
    const double t_on = secs_since(t0);

    std::printf("20 Taubin pairs, constraint OFF          %8.3f s  "
                "(%.4f s / pair, %zu vertices)\n",
                t_passes, t_passes / 20.0, subject.vertices.size());
    std::printf("ONE min-feature re-voxelization          %8.3f s  "
                "(voxelize_onto_grid + min_feature_violations, %d violations)\n",
                t_revox, mf);
    std::printf("20 Taubin pairs, constraint ON           %8.3f s  "
                "(%d pairs actually applied)\n",
                t_on, s_on.stats.applied_pairs);
    std::printf("=> the re-voxelization is %.1fx the cost of the pass it "
                "guards\n",
                t_revox / std::fmax(t_passes / 20.0, 1e-9));
    (void)s_off;

    // S2(b): the PREVIEW seam as shipped. `smooth_brush_preview`
    // (bridge.cpp:1373) re-imports the variant STL on EVERY call, then smooths
    // unconstrained. Both halves timed, because the import is the larger one and
    // it is the half that does not have to happen.
    auto t1 = Clock::now();
    const TriangleMesh reimported = import_part_file_resolved(subject_path).mesh;
    const double t_import = secs_since(t1);
    SmoothConstraints prev;
    prev.enforce_min_feature = false;
    prev.min_feature_grid = nullptr;
    t1 = Clock::now();
    const SmoothResult pr = constrained_taubin_smooth(reimported, p, prev);
    const double t_prev = secs_since(t1);
    std::printf("\nTHE PREVIEW SEAM (smooth_brush_preview), per call:\n");
    std::printf("  STL re-import (every stroke)           %8.3f s\n", t_import);
    std::printf("  20 unconstrained Taubin pairs          %8.3f s  "
                "(%.1f fps if this were the only work)\n",
                t_prev, 1.0 / std::fmax(t_prev, 1e-9));
    std::printf("  total as shipped                       %8.3f s  (%.1f fps)\n",
                t_import + t_prev, 1.0 / std::fmax(t_import + t_prev, 1e-9));
    std::printf("  max displacement                       %8.4f mm\n",
                max_shift_mm(reimported, pr.mesh));
  }

  // ── evidence ────────────────────────────────────────────────────────────────
  if (!evidence_dir.empty()) {
    std::ofstream f(evidence_dir + "/stairstep_sweep.csv");
    f << "enforce,pairs_requested,pairs_applied,lambda,k_pb,"
         "oblique_max_dev_mm,oblique_rms_dev_mm,oblique_p99_dev_mm,"
         "all_max_dev_mm,all_rms_dev_mm,dihedral_rms_deg,max_shift_mm,"
         "volume_drift,volume_drift_bound,min_feature_baseline,"
         "min_feature_after,min_feature_limited,wall_s\n";
    f << "baseline,0,0,,," << base_obl.max_mm << "," << base_obl.rms_mm << ","
      << base_obl.p99_mm << "," << base_dev.max_mm << "," << base_dev.rms_mm
      << "," << base_dih << ",,,," << base_mf << "," << base_mf << ",,\n";
    for (const Row& r : rows)
      f << (r.enforce ? "on" : "off") << "," << r.pairs_req << ","
        << r.pairs_app << "," << r.lambda << "," << r.k_pb << ","
        << r.dev.max_mm << "," << r.dev.rms_mm << "," << r.dev.p99_mm << ","
        << r.all.max_mm << "," << r.all.rms_mm << ","
        << r.dih << "," << r.max_shift << "," << r.drift << ","
        << r.drift_bound << "," << r.mf_base << "," << r.mf_after << ","
        << (r.mf_limited ? "yes" : "no") << "," << r.smooth_secs << "\n";
    std::printf("\nwrote %s/stairstep_sweep.csv\n", evidence_dir.c_str());
  }
  return 0;
}
