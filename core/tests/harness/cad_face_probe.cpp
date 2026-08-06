// cad_face_probe — S1 + S2 of task 2026-08-06-cad-face-projection.
//
// THE QUESTION. On an exported optimizer variant, how much of the surface came
// from the maintainer's CAD (where the true surface is KNOWN EXACTLY and can be
// restored by projection) and how much was CUT BY THE OPTIMIZER (where no ground
// truth exists at all)? That single ratio decides what projection is worth.
//
// THE METRIC IS PR 299's, UNCHANGED. For every vertex of the exported iso-surface
// the unsigned distance to the nearest point on the ORIGINAL imported CAD
// triangle mesh (the pre-voxelization surface), computed with the same
// point-to-triangle routine and the same uniform-grid accelerator that
// stairstep_probe.cpp uses. Nothing about the deviation reading is new here; what
// is new is that each vertex is ALSO told WHICH CAD face carried the nearest
// point, and whether it is close enough to that face to have come from it.
//
// THE SPLIT (S1a). A vertex is ON A CAD FACE iff its distance to the CAD surface
// is <= `tol`. The default tol is ONE VOXEL, and the justification is measured
// rather than asserted: the histogram of distance-to-CAD is printed, and the
// split is re-reported at 0.5, 1.0 and 1.5 voxels so a reader can see whether the
// threshold sits on a knife edge or in an empty valley. An unattributed vertex is
// treated as OPTIMIZER-CUT, which is the SAFE direction — it is left alone.
//
// TWO PARTITIONS, AND THEY ARE NOT THE SAME (S1d). PR 299 classifies a vertex
// AXIS-ALIGNED / OBLIQUE by the normal of the NEAREST CAD TRIANGLE. A reviewer
// measured the same variant by the exported MESH's OWN triangle normals. Both are
// printed side by side, plus the cross-tabulation, because they answer different
// questions: the CAD normal says "what surface was this supposed to be", the mesh
// normal says "which way does the facet the slicer sees actually point".
//
// A HARNESS, not a ctest: it prints tables and writes CSV evidence. It asserts
// only the preconditions that would make its own numbers meaningless.
//
//   cmake --build core/build --target cad_face_probe
//   ./core/build/cad_face_probe <part.step> <res> <evidence_dir> <variant.stl>...

#include "topopt/cad_project.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
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

// ── point-to-triangle distance + uniform-grid accelerator ────────────────────
// Lifted VERBATIM from core/tests/harness/stairstep_probe.cpp (PR 299's metric).
// Kept as a copy rather than shared so that PR 299's harness is not touched by
// this task at all and its output stays reproducible byte for byte.

double dist2_point_triangle(const Vec3& p, const Vec3& a, const Vec3& b,
                            const Vec3& c) {
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

class TriGrid {
 public:
  explicit TriGrid(const TriangleMesh& mesh) : mesh_(&mesh) {
    if (mesh.triangles.empty()) return;
    Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
    for (const Vec3& v : mesh.vertices) {
      lo.x = std::fmin(lo.x, v.x); hi.x = std::fmax(hi.x, v.x);
      lo.y = std::fmin(lo.y, v.y); hi.y = std::fmax(hi.y, v.y);
      lo.z = std::fmin(lo.z, v.z); hi.z = std::fmax(hi.z, v.z);
    }
    origin_ = lo;
    const double ex = std::fmax(hi.x - lo.x, 1e-9);
    const double ey = std::fmax(hi.y - lo.y, 1e-9);
    const double ez = std::fmax(hi.z - lo.z, 1e-9);
    const double vol = ex * ey * ez;
    const double target =
        std::cbrt(vol / std::fmax(1.0, static_cast<double>(mesh.triangles.size())));
    cell_ = std::fmax(target, 1e-6);
    nx_ = std::max(1, static_cast<int>(ex / cell_) + 1);
    ny_ = std::max(1, static_cast<int>(ey / cell_) + 1);
    nz_ = std::max(1, static_cast<int>(ez / cell_) + 1);
    bins_.assign(static_cast<std::size_t>(nx_) * ny_ * nz_, {});
    for (std::size_t t = 0; t < mesh.triangles.size(); ++t) {
      const auto& tr = mesh.triangles[t];
      Vec3 tlo{1e300, 1e300, 1e300}, thi{-1e300, -1e300, -1e300};
      for (int k = 0; k < 3; ++k) {
        const Vec3& v = mesh.vertices[static_cast<std::size_t>(tr[k])];
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
      if (best2 <= r * r) break;
      r *= 2.0;
    }
    return {std::sqrt(best2), best_t};
  }

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
  Vec3 origin_{0, 0, 0};
  double cell_ = 1.0;
  int nx_ = 1, ny_ = 1, nz_ = 1;
  std::vector<std::vector<int>> bins_;
};

double tri_area(const TriangleMesh& m, std::size_t t) {
  const auto& tr = m.triangles[t];
  const Vec3& a = m.vertices[static_cast<std::size_t>(tr[0])];
  const Vec3& b = m.vertices[static_cast<std::size_t>(tr[1])];
  const Vec3& c = m.vertices[static_cast<std::size_t>(tr[2])];
  const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z};
  const Vec3 v{c.x - a.x, c.y - a.y, c.z - a.z};
  const Vec3 n{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z,
               u.x * v.y - u.y * v.x};
  return 0.5 * std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
}

Vec3 mesh_tri_normal(const TriangleMesh& m, std::size_t t) {
  const auto& tr = m.triangles[t];
  const Vec3& a = m.vertices[static_cast<std::size_t>(tr[0])];
  const Vec3& b = m.vertices[static_cast<std::size_t>(tr[1])];
  const Vec3& c = m.vertices[static_cast<std::size_t>(tr[2])];
  const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z};
  const Vec3 v{c.x - a.x, c.y - a.y, c.z - a.z};
  Vec3 n{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x};
  const double L = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
  if (L > 0.0) { n.x /= L; n.y /= L; n.z /= L; }
  return n;
}

struct Deviation {
  double max_mm = 0.0, rms_mm = 0.0, p99_mm = 0.0, mean_mm = 0.0;
  std::size_t n = 0;
};

Deviation stats_of(std::vector<double> v) {
  Deviation d;
  if (v.empty()) return d;
  double s2 = 0.0, s = 0.0;
  for (const double x : v) {
    s2 += x * x; s += x;
    if (x > d.max_mm) d.max_mm = x;
  }
  d.n = v.size();
  const double n = static_cast<double>(v.size());
  d.rms_mm = std::sqrt(s2 / n);
  d.mean_mm = s / n;
  const std::size_t k = static_cast<std::size_t>(0.99 * (n - 1.0));
  std::nth_element(v.begin(), v.begin() + static_cast<long>(k), v.end());
  d.p99_mm = v[k];
  return d;
}

const char* kind_name(StepSurfaceKind k) {
  switch (k) {
    case StepSurfaceKind::Plane: return "Plane";
    case StepSurfaceKind::Cylinder: return "Cylinder";
    default: return "Other";
  }
}

std::string base_name(const std::string& p) {
  const std::size_t s = p.find_last_of("/\\");
  return s == std::string::npos ? p : p.substr(s + 1);
}

long long file_size_bytes(const std::string& p) {
  std::ifstream in(p, std::ios::binary | std::ios::ate);
  return in ? static_cast<long long>(in.tellg()) : -1;
}

// The triangle count in a binary STL's own 4-byte header, i.e. how many facets
// the file claims before any welding or repair. Printed beside the imported
// count so "the importer dropped some" and "the file has fewer" are separable.
long long stl_header_triangles(const std::string& p) {
  std::ifstream in(p, std::ios::binary);
  if (!in) return -1;
  char hdr[80];
  in.read(hdr, 80);
  unsigned char n[4];
  in.read(reinterpret_cast<char*>(n), 4);
  if (!in) return -1;
  return static_cast<long long>(n[0]) | (static_cast<long long>(n[1]) << 8) |
         (static_cast<long long>(n[2]) << 16) |
         (static_cast<long long>(n[3]) << 24);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 5) {
    std::printf("usage: cad_face_probe <part.step> <res> <evidence_dir> "
                "<variant.stl>...\n");
    return 2;
  }
  const std::string step_path = argv[1];
  const int res = std::atoi(argv[2]);
  const std::string ev = argv[3];

  StepModel model;
  try {
    model = import_part_file_resolved(step_path);
  } catch (const std::exception& e) {
    std::printf("FATAL: cannot import %s: %s\n", step_path.c_str(), e.what());
    return 2;
  }
  const VoxelGrid grid = voxelize(model.mesh, res);

  std::printf("== cad_face_probe — S1/S2 of 2026-08-06-cad-face-projection ==\n\n");
  std::printf("-- ARITHMETIC, MEASURED --------------------------------------\n");
  Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
  for (const Vec3& v : model.mesh.vertices) {
    lo.x = std::fmin(lo.x, v.x); hi.x = std::fmax(hi.x, v.x);
    lo.y = std::fmin(lo.y, v.y); hi.y = std::fmax(hi.y, v.y);
    lo.z = std::fmin(lo.z, v.z); hi.z = std::fmax(hi.z, v.z);
  }
  std::printf("part            %s\n", base_name(step_path).c_str());
  std::printf("bbox            %.3f x %.3f x %.3f mm\n", hi.x - lo.x,
              hi.y - lo.y, hi.z - lo.z);
  std::printf("grid            %d x %d x %d @ resolution %d\n", grid.nx, grid.ny,
              grid.nz, res);
  std::printf("ONE VOXEL       %.6f mm   <- every tolerance below is stated in "
              "these units\n", grid.spacing);
  std::printf("CAD mesh        %zu verts, %zu tris, %d B-rep faces\n",
              model.mesh.vertices.size(), model.mesh.triangles.size(),
              model.face_count);

  // ── the CAD faces, by kind and by area ────────────────────────────────────
  std::vector<double> face_area(static_cast<std::size_t>(model.face_count), 0.0);
  double cad_area_total = 0.0;
  double cad_area_by_kind[3] = {0.0, 0.0, 0.0};
  int face_n_by_kind[3] = {0, 0, 0};
  for (std::size_t t = 0; t < model.mesh.triangles.size(); ++t) {
    const int f = model.triangle_face[t];
    const double a = tri_area(model.mesh, t);
    cad_area_total += a;
    if (f >= 0 && f < model.face_count) {
      face_area[static_cast<std::size_t>(f)] += a;
      cad_area_by_kind[static_cast<int>(model.faces[static_cast<std::size_t>(f)].kind)] += a;
    }
  }
  for (int f = 0; f < model.face_count; ++f)
    face_n_by_kind[static_cast<int>(model.faces[static_cast<std::size_t>(f)].kind)]++;
  std::printf("CAD surface     %.1f mm^2 total; by kind — Plane %d faces "
              "(%.1f%% of area), Cylinder %d (%.1f%%), Other %d (%.1f%%)\n\n",
              cad_area_total, face_n_by_kind[0],
              100.0 * cad_area_by_kind[0] / cad_area_total, face_n_by_kind[1],
              100.0 * cad_area_by_kind[1] / cad_area_total, face_n_by_kind[2],
              100.0 * cad_area_by_kind[2] / cad_area_total);

  const TriGrid ref(model.mesh);

  std::ofstream csv(ev + "/s1_split.csv");
  csv << "variant,tol_voxel,tol_mm,verts,verts_cad,verts_cut,frac_verts_cad,"
         "area_mm2,area_cad,area_cut,area_seam,frac_area_cad,"
         "cad_area_plane,cad_area_cyl,cad_area_other\n";
  std::ofstream csv2(ev + "/s1_deviation.csv");
  csv2 << "variant,population,n,max_mm,rms_mm,p99_mm,mean_mm,max_voxel,rms_voxel\n";
  std::ofstream csvh(ev + "/s1_histogram.csv");
  csvh << "variant,bin_lo_voxel,bin_hi_voxel,vertices\n";

  for (int ai = 4; ai < argc; ++ai) {
    const std::string vpath = argv[ai];
    TriangleMesh sub;
    try {
      sub = import_part_file_resolved(vpath).mesh;
    } catch (const std::exception& e) {
      std::printf("FATAL: cannot import %s: %s\n", vpath.c_str(), e.what());
      return 2;
    }
    const std::string vname = base_name(vpath);
    std::printf("==============================================================\n");
    std::printf("VARIANT %s — %zu verts, %zu tris (as core's importer welds it)\n",
                vname.c_str(), sub.vertices.size(), sub.triangles.size());

    // per-vertex nearest CAD triangle + face
    const std::size_t nv = sub.vertices.size();
    std::vector<double> dist(nv, 0.0);
    std::vector<int> near_face(nv, -1);
    std::vector<char> obl_cad(nv, 0);  // PR 299's rule, by nearest CAD normal
    for (std::size_t i = 0; i < nv; ++i) {
      const auto dt = ref.distance_and_tri(sub.vertices[i]);
      dist[i] = dt.first;
      if (dt.second < 0) continue;
      near_face[i] = model.triangle_face[static_cast<std::size_t>(dt.second)];
      const Vec3 n = ref.tri_normal(dt.second);
      const double m = std::fmax(std::fabs(n.x),
                                 std::fmax(std::fabs(n.y), std::fabs(n.z)));
      if (m < 0.98) obl_cad[i] = 1;
    }

    // S1(a) — the split, at three tolerances
    std::printf("\n-- S1(a) THE SPLIT, by vertex, at three tolerances ---------\n");
    std::printf("A vertex is ON A CAD FACE iff its distance to the CAD surface "
                "<= tol.\n");
    std::printf("%-14s %10s %12s %12s %10s\n", "tol", "tol (mm)", "on CAD face",
                "optimizer-cut", "%% on CAD");
    const double tol_mult[3] = {0.5, 1.0, 1.5};
    for (int ti = 0; ti < 3; ++ti) {
      const double tol = tol_mult[ti] * grid.spacing;
      std::size_t on = 0;
      for (std::size_t i = 0; i < nv; ++i)
        if (near_face[i] >= 0 && dist[i] <= tol) ++on;
      std::printf("%-14s %10.4f %12zu %12zu %9.2f%%\n",
                  (ti == 0 ? "0.5 voxel" : ti == 1 ? "1.0 voxel (default)"
                                                   : "1.5 voxel"),
                  tol, on, nv - on, 100.0 * static_cast<double>(on) /
                                        static_cast<double>(nv));
    }

    // the histogram behind that choice
    std::printf("\n-- distance-to-CAD histogram (in voxels) — is the threshold "
                "on a knife edge? --\n");
    const int NB = 16;
    std::vector<std::size_t> hist(static_cast<std::size_t>(NB) + 1, 0);
    for (std::size_t i = 0; i < nv; ++i) {
      const double u = dist[i] / grid.spacing;
      const int b = static_cast<int>(std::floor(u * 4.0));  // 0.25-voxel bins
      hist[static_cast<std::size_t>(b >= NB ? NB : b)]++;
    }
    for (int b = 0; b <= NB; ++b) {
      const double blo = 0.25 * b, bhi = 0.25 * (b + 1);
      const double pct = 100.0 * static_cast<double>(hist[static_cast<std::size_t>(b)]) /
                         static_cast<double>(nv);
      std::printf("  [%4.2f,%4.2f)%s %9zu  %6.2f%%  %s\n", blo,
                  b == NB ? 99.0 : bhi, b == NB ? "+" : " ",
                  hist[static_cast<std::size_t>(b)], pct,
                  std::string(static_cast<std::size_t>(pct * 1.2), '#').c_str());
      csvh << vname << "," << blo << "," << (b == NB ? 99.0 : bhi) << ","
           << hist[static_cast<std::size_t>(b)] << "\n";
    }

    // the default tolerance, and everything below uses it
    const double tol = grid.spacing;
    std::vector<char> on_cad(nv, 0);
    std::size_t n_on = 0, n_unattrib = 0;
    for (std::size_t i = 0; i < nv; ++i) {
      if (near_face[i] >= 0 && dist[i] <= tol) { on_cad[i] = 1; ++n_on; }
      else ++n_unattrib;
    }

    // S1(a) by AREA. A triangle is CAD if all three vertices are, CUT if none
    // is, SEAM otherwise — the seam is S4's subject and is never silently
    // folded into either side.
    double area_all = 0.0, area_cad = 0.0, area_cut = 0.0, area_seam = 0.0;
    double area_cad_kind[3] = {0.0, 0.0, 0.0};
    double area_axis_mesh = 0.0;   // by MESH normal (the reviewer's partition)
    double area_obl_mesh = 0.0;
    for (std::size_t t = 0; t < sub.triangles.size(); ++t) {
      const double a = tri_area(sub, t);
      area_all += a;
      int c = 0;
      for (int k = 0; k < 3; ++k)
        c += on_cad[static_cast<std::size_t>(sub.triangles[t][k])] ? 1 : 0;
      if (c == 3) {
        area_cad += a;
        // kind of the face the triangle's first vertex sits on
        const int f = near_face[static_cast<std::size_t>(sub.triangles[t][0])];
        if (f >= 0)
          area_cad_kind[static_cast<int>(model.faces[static_cast<std::size_t>(f)].kind)] += a;
      } else if (c == 0) {
        area_cut += a;
      } else {
        area_seam += a;
      }
      const Vec3 n = mesh_tri_normal(sub, t);
      const double m = std::fmax(std::fabs(n.x),
                                 std::fmax(std::fabs(n.y), std::fabs(n.z)));
      if (m >= 0.98) area_axis_mesh += a; else area_obl_mesh += a;
    }

    std::printf("\n-- S1(a) THE SPLIT, by AREA, at tol = 1.000 voxel (%.4f mm) --\n",
                tol);
    std::printf("total exported surface   %.1f mm^2 over %zu triangles\n",
                area_all, sub.triangles.size());
    std::printf("  on a CAD face          %10.1f mm^2  %6.2f%%   <- has a "
                "correct answer\n", area_cad, 100.0 * area_cad / area_all);
    std::printf("  optimizer-cut          %10.1f mm^2  %6.2f%%   <- no ground "
                "truth exists\n", area_cut, 100.0 * area_cut / area_all);
    std::printf("  seam (mixed triangle)  %10.1f mm^2  %6.2f%%   <- S4's "
                "subject\n", area_seam, 100.0 * area_seam / area_all);
    std::printf("by VERTEX                on CAD %zu / %zu (%.2f%%), "
                "unattributed %zu (%.2f%%)\n", n_on, nv,
                100.0 * static_cast<double>(n_on) / static_cast<double>(nv),
                n_unattrib,
                100.0 * static_cast<double>(n_unattrib) / static_cast<double>(nv));

    std::printf("\n-- S1(b) THE CAD-FACE AREA, BY SURFACE KIND ----------------\n");
    for (int k = 0; k < 3; ++k)
      std::printf("  %-9s %10.1f mm^2  %6.2f%% of the CAD-face area  "
                  "%6.2f%% of the whole part\n",
                  kind_name(static_cast<StepSurfaceKind>(k)), area_cad_kind[k],
                  area_cad > 0.0 ? 100.0 * area_cad_kind[k] / area_cad : 0.0,
                  100.0 * area_cad_kind[k] / area_all);

    // S1(c) — deviation of each population, SEPARATELY
    std::vector<double> dev_cad, dev_cut, dev_cad_obl, dev_cut_obl, dev_obl_all;
    for (std::size_t i = 0; i < nv; ++i) {
      if (on_cad[i]) {
        dev_cad.push_back(dist[i]);
        if (obl_cad[i]) dev_cad_obl.push_back(dist[i]);
      } else {
        dev_cut.push_back(dist[i]);
        if (obl_cad[i]) dev_cut_obl.push_back(dist[i]);
      }
      if (obl_cad[i]) dev_obl_all.push_back(dist[i]);
    }
    struct Pop { const char* name; Deviation d; };
    const Pop pops[] = {
        {"CAD-face, all", stats_of(dev_cad)},
        {"CAD-face, OBLIQUE", stats_of(dev_cad_obl)},
        {"optimizer-cut, all", stats_of(dev_cut)},
        {"optimizer-cut, OBL", stats_of(dev_cut_obl)},
        {"OBLIQUE, both (PR 299's headline population)", stats_of(dev_obl_all)},
    };
    std::printf("\n-- S1(c) DEVIATION FROM THE CAD, EACH POPULATION SEPARATELY -\n");
    std::printf("Reference: the pre-voxelization imported CAD tessellation "
                "(%zu tris,\nlinear deflection %.3f mm — the importer default). "
                "Unsigned point-to-surface\ndistance, PR 299's metric unchanged. "
                "Voxel = %.6f mm.\n\n", model.mesh.triangles.size(), 0.1,
                grid.spacing);
    std::printf("%-46s %9s %9s %9s %9s %9s\n", "population", "n", "max mm",
                "rms mm", "p99 mm", "rms vox");
    for (const Pop& p : pops) {
      std::printf("%-46s %9zu %9.4f %9.4f %9.4f %9.3f\n", p.name, p.d.n,
                  p.d.max_mm, p.d.rms_mm, p.d.p99_mm, p.d.rms_mm / grid.spacing);
      csv2 << vname << ",\"" << p.name << "\"," << p.d.n << "," << p.d.max_mm
           << "," << p.d.rms_mm << "," << p.d.p99_mm << "," << p.d.mean_mm << ","
           << p.d.max_mm / grid.spacing << "," << p.d.rms_mm / grid.spacing << "\n";
    }
    std::printf("\nNOTE the optimizer-cut rows are NOT an error reading. That "
                "surface was never\nmeant to lie on the CAD; its distance to the "
                "CAD is how deep into the part the\noptimizer cut. It is printed "
                "so the two halves are never averaged together.\n");

    // S1(d) — the reviewer's partition, and how it relates to PR 299's
    std::printf("\n-- S1(d) TWO PARTITIONS, CROSS-TABULATED -------------------\n");
    std::printf("MEASURED on %s (%lld bytes on disk):\n  %zu triangles, "
                "%.1f mm^2 total, %.2f%% of area axis-aligned by MESH normal\n"
                "  (max|n| >= 0.98), %.2f%% oblique.\n", vpath.c_str(),
                file_size_bytes(vpath), sub.triangles.size(), area_all,
                100.0 * area_axis_mesh / area_all,
                100.0 * area_obl_mesh / area_all);
    std::printf("  raw file header triangle count (unwelded, as written): "
                "%lld\n", stl_header_triangles(vpath));
    // Area does not depend on the alignment threshold, so a threshold sweep can
    // only ever explain the PERCENTAGE. Print it so a mismatch can be attributed
    // to the threshold or ruled out.
    // The candidate explanations for a triangle-count / area mismatch, tested
    // rather than speculated about: does the mesh have stray components a
    // reviewer's tool might have dropped, and how much area do they carry?
    {
      const int comps = count_components(sub);
      const TriangleMesh largest = keep_largest_component(sub);
      double a_lg = 0.0;
      for (std::size_t t = 0; t < largest.triangles.size(); ++t)
        a_lg += tri_area(largest, t);
      std::printf("  connected components %d; largest component alone: %zu "
                  "triangles, %.1f mm^2\n", comps, largest.triangles.size(),
                  a_lg);
    }
    std::printf("  axis-aligned %% by threshold: ");
    for (const double thr : {0.9, 0.95, 0.98, 0.999, 0.999999}) {
      double a_ax = 0.0;
      for (std::size_t t = 0; t < sub.triangles.size(); ++t) {
        const Vec3 n = mesh_tri_normal(sub, t);
        const double m = std::fmax(std::fabs(n.x),
                                   std::fmax(std::fabs(n.y), std::fabs(n.z)));
        if (m >= thr) a_ax += tri_area(sub, t);
      }
      std::printf("%.4g->%.2f%%  ", thr, 100.0 * a_ax / area_all);
    }
    std::printf("\n");
    std::size_t xt[2][2] = {{0, 0}, {0, 0}};  // [obl by CAD][obl by mesh-of-vertex]
    // a vertex's mesh-normal class = area-weighted majority of its incident tris
    std::vector<double> vt_axis(nv, 0.0), vt_obl(nv, 0.0);
    for (std::size_t t = 0; t < sub.triangles.size(); ++t) {
      const double a = tri_area(sub, t);
      const Vec3 n = mesh_tri_normal(sub, t);
      const double m = std::fmax(std::fabs(n.x),
                                 std::fmax(std::fabs(n.y), std::fabs(n.z)));
      for (int k = 0; k < 3; ++k) {
        const std::size_t v = static_cast<std::size_t>(sub.triangles[t][k]);
        if (m >= 0.98) vt_axis[v] += a; else vt_obl[v] += a;
      }
    }
    for (std::size_t i = 0; i < nv; ++i) {
      const int a = obl_cad[i] ? 1 : 0;
      const int b = (vt_obl[i] > vt_axis[i]) ? 1 : 0;
      xt[a][b]++;
    }
    std::printf("\n%-34s %14s %14s\n", "vertices", "mesh: AXIS", "mesh: OBLIQUE");
    std::printf("%-34s %14zu %14zu\n", "nearest CAD normal: AXIS", xt[0][0],
                xt[0][1]);
    std::printf("%-34s %14zu %14zu\n", "nearest CAD normal: OBLIQUE", xt[1][0],
                xt[1][1]);
    const double agree = 100.0 * static_cast<double>(xt[0][0] + xt[1][1]) /
                         static_cast<double>(nv);
    std::printf("the two partitions agree on %.1f%% of vertices.\n", agree);

    csv << vname << "," << 1.0 << "," << tol << "," << nv << "," << n_on << ","
        << (nv - n_on) << ","
        << static_cast<double>(n_on) / static_cast<double>(nv) << "," << area_all
        << "," << area_cad << "," << area_cut << "," << area_seam << ","
        << area_cad / area_all << "," << area_cad_kind[0] << ","
        << area_cad_kind[1] << "," << area_cad_kind[2] << "\n";

    // ── S2 — the ATTRIBUTION the production path will use ────────────────────
    // Re-run the SAME question through the SHIPPED attributor, so the numbers
    // above and the code that projects cannot drift apart.
    CadProjectOptions opt = cad_project_options_for_grid(grid.spacing);
    opt.enabled = true;
    const CadAttribution att = attribute_to_cad_faces(sub, model, opt);
    std::printf("\n-- S2 THE SHIPPED ATTRIBUTOR, ON THE SAME MESH -------------\n");
    std::printf("attributed   %zu   unattributed %zu   ambiguous %zu\n",
                att.attributed, att.unattributed, att.ambiguous);
    std::printf("by kind:  Plane %zu   Cylinder %zu   Other(left alone) %zu\n",
                att.n_plane, att.n_cylinder, att.n_other);
    // CROSS-CHECK. The harness's own "within tol of the CAD" reading and the
    // shipped attributor must partition the SAME population: everything the
    // harness calls on-CAD is either attributed, or WITHHELD for a named reason.
    // Withholding is a refusal to pick a face, not a claim the vertex is off the
    // CAD. If the two ever fail to add up, every split number above is suspect.
    const std::size_t ship_total =
        att.attributed + att.ambiguous + att.off_analytic_surface;
    std::printf("attributed %zu + ambiguous %zu + off-analytic %zu = %zu, "
                "vs the harness's %zu on-CAD (must match)\n", att.attributed,
                att.ambiguous, att.off_analytic_surface, ship_total, n_on);
    if (ship_total != n_on) {
      std::printf("FATAL: the harness and the shipped attributor do not agree; "
                  "every number above is suspect.\n");
      return 3;
    }
    std::printf("WITHHELD, by reason, as %% of ALL vertices:\n"
                "  ambiguous (a second CAD face of a DIFFERENT kind within "
                "%.4f mm = 0.10 voxel)  %.4f%%\n"
                "  off the ANALYTIC surface though near the face's patch"
                "                     %.4f%%\n",
                opt.ambiguity_band_mm,
                100.0 * static_cast<double>(att.ambiguous) /
                    static_cast<double>(nv),
                100.0 * static_cast<double>(att.off_analytic_surface) /
                    static_cast<double>(nv));
    std::fflush(stdout);
  }

  std::printf("\nevidence written to %s/s1_split.csv, s1_deviation.csv, "
              "s1_histogram.csv\n", ev.c_str());
  return 0;
}
