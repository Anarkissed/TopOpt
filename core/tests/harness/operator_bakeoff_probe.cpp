// operator_bakeoff_probe — S1/S3 of task 2026-08-06-smoothing-operator-bakeoff.
//
// THE QUESTION. Two candidate operators for the optimizer-cut surfaces — A,
// mean-curvature flow, and B, ramp reconstruction — measured against each other
// and against the two figures already on the board, under the S2 constraints.
//
// WHAT THIS PROBE CAN AND CANNOT DECIDE. The task's own headline metric is
// stair-step amplitude removed ON THE CUT POPULATION, and the CAD-versus-cut
// classifier that names that population is produced by task `cad-face-projection`,
// which has not landed. So the bake-off here is run on the ANALYTIC SPHERE, and
// only on it:
//
//   * a sphere has no CAD faces and no cut/CAD split at all, so "the cut
//     population" is the whole surface and needs no classifier;
//   * its exact surface is known in closed form, so the deviation |‖v−c‖ − R| is
//     the voxelization error and nothing else — not the reference tessellation's
//     own faceting;
//   * PR 299 and PR 303 both scored this same fixture at this same voxel size,
//     so the numbers below land straight into an existing table.
//
// What is NOT here, and is owed to the classifier: the §0 re-baselining of
// Taubin and the SDF route on the cut population, the per-rung comparison on his
// own part, and C4 (CAD faces do not move) which cannot even be asserted without
// knowing which faces those are.
//
// THE METRIC, unchanged from PR 299 §S1(d) and PR 303: RMS of |‖v−c‖ − R| over
// the exported mesh's vertices, reported as a percentage of the unsmoothed
// baseline's RMS, and as the complement of that — the amplitude REMOVED. The
// voxel spacing is 1.620040 mm, the value his part's grid takes at resolution
// 128, so the staircase is the same physical size the two prior measurements saw.
//
// A HARNESS, not a ctest: it prints tables and writes evidence. It asserts only
// the preconditions that would make its own numbers meaningless, and it uses
// nothing from OCCT so it builds in every configuration.
//
//   cmake --build build --target operator_bakeoff_probe
//   ./build/operator_bakeoff_probe [evidence_dir] [bracket.stl]

#include "topopt/mesh.hpp"
#include "topopt/smooth.hpp"
#include "topopt/stl.hpp"
#include "topopt/surface_operator.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;

namespace {

using Clock = std::chrono::steady_clock;
double secs_since(const Clock::time_point& t) {
  return std::chrono::duration<double>(Clock::now() - t).count();
}

// The voxel spacing his part's grid takes at resolution 128. PR 299 printed
// 1.6200 and PR 303 1.620040 for the same setup; the sphere is run at it so the
// staircase here is the same physical size as the staircase there.
constexpr double kHisSpacing = 1.620040;
constexpr double kSphereR = 20.0;
constexpr int kExportFactor = 2;

// ── the analytic sphere fixture, identical to stairstep_probe §S1(d) ─────────

VoxelGrid sphere_grid(double R, double spacing, Vec3& centre_out) {
  const int n = static_cast<int>(std::ceil(2.4 * R / spacing));
  VoxelGrid g;
  g.nx = g.ny = g.nz = n;
  g.spacing = spacing;
  g.origin = Vec3{0.0, 0.0, 0.0};
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

std::vector<double> occupancy(const VoxelGrid& g) {
  std::vector<double> d(g.voxel_count(), 0.0);
  for (std::size_t i = 0; i < d.size(); ++i)
    if (g.tags[i] != VoxelTag::Empty) d[i] = 1.0;
  return d;
}

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

// Corroboration only, never the headline: the RMS dihedral angle across edges.
// It must move WITH the deviation for a reading to mean what it says — a number
// that falls while the deviation rises is a melt, not a smoothing.
double dihedral_rms_deg(const TriangleMesh& m) {
  std::vector<std::pair<int, int>> edges = mesh_edges(m);
  std::vector<std::pair<int, int>> owner(edges.size(), {-1, -1});
  std::vector<Vec3> fn(m.triangles.size());
  for (std::size_t f = 0; f < m.triangles.size(); ++f) {
    const auto& t = m.triangles[f];
    const Vec3& p0 = m.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& p1 = m.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& p2 = m.vertices[static_cast<std::size_t>(t[2])];
    const Vec3 u{p1.x - p0.x, p1.y - p0.y, p1.z - p0.z};
    const Vec3 w{p2.x - p0.x, p2.y - p0.y, p2.z - p0.z};
    Vec3 c{u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x};
    const double n = std::sqrt(c.x * c.x + c.y * c.y + c.z * c.z);
    if (n > 0.0) { c.x /= n; c.y /= n; c.z /= n; }
    fn[f] = c;
    for (int e = 0; e < 3; ++e) {
      int a = t[e], b = t[(e + 1) % 3];
      if (a > b) std::swap(a, b);
      const auto it = std::lower_bound(edges.begin(), edges.end(), std::make_pair(a, b));
      const std::size_t ei = static_cast<std::size_t>(it - edges.begin());
      if (owner[ei].first < 0) owner[ei].first = static_cast<int>(f);
      else if (owner[ei].second < 0) owner[ei].second = static_cast<int>(f);
    }
  }
  double sum2 = 0.0;
  std::size_t n = 0;
  for (const auto& o : owner) {
    if (o.first < 0 || o.second < 0) continue;
    const Vec3& a = fn[static_cast<std::size_t>(o.first)];
    const Vec3& b = fn[static_cast<std::size_t>(o.second)];
    double d = a.x * b.x + a.y * b.y + a.z * b.z;
    d = std::fmax(-1.0, std::fmin(1.0, d));
    const double deg = std::acos(d) * 180.0 / 3.14159265358979323846;
    sum2 += deg * deg;
    ++n;
  }
  return n > 0 ? std::sqrt(sum2 / static_cast<double>(n)) : 0.0;
}

// ── S3 INSTRUMENT 1: MINIMUM CROSS-SECTION OF EVERY TENDRIL ─────────────────
//
// AVERAGES HIDE THE FAILURE MODE. A mean cross-section can hold perfectly steady
// while one strut necks to nothing, and the necking strut is the whole objection.
// So this is a MINIMUM over the printed set, never a mean.
//
// The measure is `local_member_thickness_mm` — the Hildebrand inscribed-sphere
// diameter core already computes for the width-aware knockdown gate. It assigns
// every voxel of a member the member's FULL width, so a surface voxel of a rib
// reads the rib, not its own distance to the void. The mesh is re-voxelized onto
// a fixed reference grid first, so before and after are measured on the same
// lattice and a change in the reading is a change in the GEOMETRY.
struct CrossSection {
  double min_mm = 0.0;         // the thinnest member of the part proper
  double p01_mm = 0.0;         // 1st percentile, to show the minimum is not a fluke
  double global_min_mm = 0.0;  // including detached slivers (see below)
  std::size_t solid_voxels = 0;
  std::size_t components = 0;      // connected components of the printed set
  std::size_t dropped_voxels = 0;  // voxels outside the largest component
  bool valid = false;
};

// 6-connected component labels over the solid set; -1 on void.
std::vector<int> solid_components(const VoxelGrid& g, const std::vector<double>& d,
                                  double iso, std::size_t& out_count) {
  std::vector<int> lab(d.size(), -1);
  std::vector<int> stack;
  int next = 0;
  for (int k0 = 0; k0 < g.nz; ++k0)
    for (int j0 = 0; j0 < g.ny; ++j0)
      for (int i0 = 0; i0 < g.nx; ++i0) {
        const std::size_t s0 = g.index(i0, j0, k0);
        if (d[s0] <= iso || lab[s0] >= 0) continue;
        lab[s0] = next;
        stack.assign(1, static_cast<int>(s0));
        while (!stack.empty()) {
          const int cur = stack.back();
          stack.pop_back();
          const int i = cur % g.nx;
          const int j = (cur / g.nx) % g.ny;
          const int k = cur / (g.nx * g.ny);
          const int off[6][3] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
          for (const auto& o : off) {
            const int a = i + o[0], b = j + o[1], c = k + o[2];
            if (a < 0 || b < 0 || c < 0 || a >= g.nx || b >= g.ny || c >= g.nz) continue;
            const std::size_t s1 = g.index(a, b, c);
            if (d[s1] <= iso || lab[s1] >= 0) continue;
            lab[s1] = next;
            stack.push_back(static_cast<int>(s1));
          }
        }
        ++next;
      }
  out_count = static_cast<std::size_t>(next);
  return lab;
}

// THE INSTRUMENT, AND TWO THINGS IT CANNOT DO, both measured rather than assumed.
//
// (1) IT HAS A TWO-VOXEL QUANTUM. local_member_thickness_mm reports 2*r*spacing
//     for an INTEGER radius r, so its readings are 2, 4, 6, ... voxels and nothing
//     between. A 3-voxel neck reads 2.000, not 3.000. It can therefore see a
//     member cross a whole even step, and cannot see anything finer. Every
//     conclusion drawn from it below is stated at that resolution.
//
// (2) RE-VOXELIZING THE MESH MANUFACTURES DETACHED SLIVERS. Measured on the
//     dumbbell: the source occupancy's thickness histogram is {4:16, 6:200,
//     8:824} — minimum 4 — while the same solid put through marching cubes and
//     voxelize_onto_grid reads {2:36, 4:16, 6:200, 8:824}, and the 36 new
//     two-voxel entries sit at (10..13, 9|14, 0..1): at k = 0, nowhere near the
//     part, which lives at k >= 8. They are a voxelization artefact of the round
//     trip, they are present identically before AND after any operator runs, and
//     because this statistic is a MINIMUM they would pin it at 2.000 forever —
//     an instrument that cannot move is exactly the instrument this task warns
//     about. So the minimum is taken over the LARGEST CONNECTED COMPONENT, and
//     the component count and dropped-voxel count are reported beside it: if an
//     operator ever severs a real tendril, the component count moves and that is
//     visible rather than silently discarded.
CrossSection min_cross_section(const TriangleMesh& mesh, const VoxelGrid& ref,
                               int cap_voxels = 12) {
  CrossSection c;
  VoxelGrid g;
  try {
    g = voxelize_onto_grid(mesh, ref);
  } catch (const std::exception&) {
    return c;
  }
  std::vector<double> density(g.voxel_count(), 0.0);
  for (std::size_t i = 0; i < density.size(); ++i)
    if (g.tags[i] != VoxelTag::Empty) density[i] = 1.0;
  const std::vector<double> w = local_member_thickness_mm(g, density, 0.5, cap_voxels);

  std::size_t ncomp = 0;
  const std::vector<int> lab = solid_components(g, density, 0.5, ncomp);
  std::vector<std::size_t> size(ncomp, 0);
  for (const int l : lab)
    if (l >= 0) size[static_cast<std::size_t>(l)]++;
  int biggest = -1;
  std::size_t best = 0;
  for (std::size_t i = 0; i < ncomp; ++i)
    if (size[i] > best) { best = size[i]; biggest = static_cast<int>(i); }

  std::vector<double> solid;
  solid.reserve(w.size());
  double gmin = 0.0;
  bool first = true;
  for (std::size_t i = 0; i < w.size(); ++i) {
    if (!(w[i] > 0.0) || !std::isfinite(w[i])) continue;
    if (first) { gmin = w[i]; first = false; }
    else gmin = std::fmin(gmin, w[i]);
    if (lab[i] == biggest) solid.push_back(w[i]);
    else c.dropped_voxels++;
  }
  if (solid.empty()) return c;
  std::sort(solid.begin(), solid.end());
  c.min_mm = solid.front();
  c.p01_mm = solid[static_cast<std::size_t>(0.01 * (solid.size() - 1))];
  c.global_min_mm = gmin;
  c.solid_voxels = solid.size();
  c.components = ncomp;
  c.valid = true;
  return c;
}

// ── S3 INSTRUMENT 1b: MINIMUM CROSS-SECTION, MEASURED AS A CROSS-SECTION ────
//
// WHY A SECOND ONE. The Hildebrand measure above is the project's own width
// field and belongs in the table, but it is an INSCRIBED-SPHERE diameter and
// that is not what "cross-section" means for a rectangular member: on the
// dumbbell's own source occupancy, a bridge 6 voxels wide reads 4, because the
// largest sphere that fits inside a 6x6 section and still contains one of its
// CORNER voxels has diameter 4. The number is correct for what it measures and
// wrong for what this task asks. It also carries a 2-voxel quantum.
//
// So the deciding column is the plain engineering one: the solid AREA of the
// thinnest slice, minimised over slices and over the three axes. On a member of
// constructed width n voxels this reads exactly n^2 * spacing^2, which is what
// makes it a positive control rather than a plausibility check. Reported as an
// area and as its square root, an equivalent width, so it can be read against a
// voxel size.
struct SliceSection {
  double min_area_mm2 = 0.0;
  double equiv_width_mm = 0.0;
  std::size_t solid_voxels = 0;  // total, so a change in the fill is visible
  int axis = -1;
  int index = -1;
  bool valid = false;
};

SliceSection min_slice_section(const VoxelGrid& g, const std::vector<double>& d,
                               double iso) {
  SliceSection s;
  const double a = g.spacing * g.spacing;
  const int dim[3] = {g.nx, g.ny, g.nz};
  for (const double x : d)
    if (x > iso) s.solid_voxels++;
  if (s.solid_voxels == 0) return s;
  for (int ax = 0; ax < 3; ++ax)
    for (int t = 0; t < dim[ax]; ++t) {
      std::size_t count = 0;
      for (int u = 0; u < dim[(ax + 1) % 3]; ++u)
        for (int v = 0; v < dim[(ax + 2) % 3]; ++v) {
          int c[3];
          c[ax] = t;
          c[(ax + 1) % 3] = u;
          c[(ax + 2) % 3] = v;
          if (d[g.index(c[0], c[1], c[2])] > iso) ++count;
        }
      if (count == 0) continue;  // a slice clear of the part is not a section
      const double area = static_cast<double>(count) * a;
      if (!s.valid || area < s.min_area_mm2) {
        s.min_area_mm2 = area;
        s.axis = ax;
        s.index = t;
        s.valid = true;
      }
    }
  s.equiv_width_mm = std::sqrt(s.min_area_mm2);
  return s;
}

// The same statistic restricted to one axis and one index range: the minimum
// cross-section OF A NAMED MEMBER rather than of the whole grid. This is what
// answers "what did the thinnest tendril do" without the answer being hostage to
// an artefact somewhere else in the volume.
SliceSection min_slice_section_range(const VoxelGrid& g, const std::vector<double>& d,
                                     int axis, int lo, int hi, double iso) {
  SliceSection s;
  const double a = g.spacing * g.spacing;
  const int dim[3] = {g.nx, g.ny, g.nz};
  for (int t = lo; t < hi && t < dim[axis]; ++t) {
    if (t < 0) continue;
    std::size_t count = 0;
    for (int u = 0; u < dim[(axis + 1) % 3]; ++u)
      for (int v = 0; v < dim[(axis + 2) % 3]; ++v) {
        int c[3];
        c[axis] = t;
        c[(axis + 1) % 3] = u;
        c[(axis + 2) % 3] = v;
        if (d[g.index(c[0], c[1], c[2])] > iso) ++count;
      }
    const double area = static_cast<double>(count) * a;
    if (!s.valid || area < s.min_area_mm2) {
      s.min_area_mm2 = area;
      s.axis = axis;
      s.index = t;
      s.valid = true;
    }
  }
  s.equiv_width_mm = std::sqrt(s.min_area_mm2);
  return s;
}

SliceSection min_slice_section_range_of(const TriangleMesh& m, const VoxelGrid& ref,
                                        int axis, int lo, int hi) {
  SliceSection s;
  VoxelGrid g;
  try {
    g = voxelize_onto_grid(m, ref);
  } catch (const std::exception&) {
    return s;
  }
  std::vector<double> d(g.voxel_count(), 0.0);
  for (std::size_t i = 0; i < d.size(); ++i)
    if (g.tags[i] != VoxelTag::Empty) d[i] = 1.0;
  return min_slice_section_range(g, d, axis, lo, hi, 0.5);
}

SliceSection min_slice_section_of(const TriangleMesh& m, const VoxelGrid& ref) {
  SliceSection s;
  VoxelGrid g;
  try {
    g = voxelize_onto_grid(m, ref);
  } catch (const std::exception&) {
    return s;
  }
  std::vector<double> d(g.voxel_count(), 0.0);
  for (std::size_t i = 0; i < d.size(); ++i)
    if (g.tags[i] != VoxelTag::Empty) d[i] = 1.0;
  return min_slice_section(g, d, 0.5);
}

// ── S3 INSTRUMENT 2: MAXIMUM OUTWARD EXCURSION AGAINST THE DESIGN BOX ────────
//
// Positive means a vertex is OUTSIDE the box. The bar is "must be <= 0", so the
// instrument reports the signed worst case rather than a count: a count of zero
// tells you nothing about how close the run came.
double max_outward_excursion(const TriangleMesh& m, const Vec3& lo, const Vec3& hi) {
  double worst = -1e300;
  for (const Vec3& v : m.vertices) {
    const double e = std::fmax(
        std::fmax(v.x - hi.x, lo.x - v.x),
        std::fmax(std::fmax(v.y - hi.y, lo.y - v.y), std::fmax(v.z - hi.z, lo.z - v.z)));
    worst = std::fmax(worst, e);
  }
  return worst;
}

// A dumbbell: two blocks joined by a neck `neck` voxels wide. The neck width is
// known by construction, which is what makes it a POSITIVE CONTROL for the
// cross-section instrument rather than a plausibility check.
VoxelGrid dumbbell_grid(int neck_voxels, double spacing, int& out_n) {
  const int n = 28;
  out_n = n;
  VoxelGrid g;
  g.nx = g.ny = g.nz = n;
  g.spacing = spacing;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Empty);
  const int c = n / 2;
  const int half = neck_voxels / 2;
  const int lo = c - half, hi = lo + neck_voxels;  // exactly neck_voxels wide
  // The BRIDGE IS 8 VOXELS LONG, longer than any neck swept below. Hildebrand
  // thickness is an inscribed-sphere diameter, so it is limited by the SHORTEST
  // dimension of the member: a 4-long bridge would read 4 no matter how wide the
  // neck, and the sweep would measure the bridge's length instead of its width.
  for (int k = 0; k < n; ++k)
    for (int j = 0; j < n; ++j)
      for (int i = 0; i < n; ++i) {
        const bool blockA = i >= 2 && i < 10 && j >= 9 && j < 19 && k >= 9 && k < 19;
        const bool blockB = i >= 18 && i < 26 && j >= 9 && j < 19 && k >= 9 && k < 19;
        const bool bridge = i >= 10 && i < 18 && j >= lo && j < hi && k >= lo && k < hi;
        if (blockA || blockB || bridge) g.tags[g.index(i, j, k)] = VoxelTag::Interior;
      }
  return g;
}

// ── the shared row printer ───────────────────────────────────────────────────

struct Row {
  std::string label;
  SphereReading dev;
  double dihed = 0.0;
  double max_motion = 0.0;
  double vol_drift_pct = 0.0;
  std::size_t verts = 0;
  std::size_t tris = 0;
  std::size_t c1_clamped = 0;
  int iterations = 0;
  double wall_s = 0.0;
};

void print_header() {
  std::printf("%-28s %8s %8s %7s %8s %7s %9s %8s %8s %7s %8s\n", "configuration",
              "max mm", "rms mm", "%ofbase", "REMOVED", "dihed", "maxmove", "vol%",
              "verts", "iters", "wall s");
}

void print_row(const Row& r, double base_rms) {
  const double pct = base_rms > 0.0 ? 100.0 * r.dev.rms_mm / base_rms : 0.0;
  std::printf("%-28s %8.4f %8.4f %7.1f %7.1f%% %7.2f %9.4f %8.4f %8zu %7d %8.3f\n",
              r.label.c_str(), r.dev.max_mm, r.dev.rms_mm, pct, 100.0 - pct, r.dihed,
              r.max_motion, r.vol_drift_pct, r.verts, r.iterations, r.wall_s);
}

void csv_row(std::ofstream& f, const Row& r, double base_rms) {
  const double pct = base_rms > 0.0 ? 100.0 * r.dev.rms_mm / base_rms : 0.0;
  f << r.label << "," << r.dev.max_mm << "," << r.dev.rms_mm << "," << pct << ","
    << (100.0 - pct) << "," << r.dihed << "," << r.max_motion << ","
    << r.vol_drift_pct << "," << r.verts << "," << r.tris << "," << r.c1_clamped
    << "," << r.iterations << "," << r.wall_s << "\n";
}

}  // namespace

int main(int argc, char** argv) {
  const std::string evidence_dir = argc > 1 ? argv[1] : "";
  const std::string bracket_path =
      argc > 2 ? argv[2]
               : std::string(MESH_FIXTURE_DIR) + "/WallMount_ShelfBracket.stl";

  std::printf("== operator_bakeoff_probe ==\n");
  std::printf("sphere R %.3f mm, spacing %.6f mm (%.1f voxels across the radius),\n"
              "export factor %d. The spacing is his part's at resolution 128, so\n"
              "the staircase is the same physical size PR 299 and PR 303 measured.\n\n",
              kSphereR, kHisSpacing, kSphereR / kHisSpacing, kExportFactor);

  // The lattice that PRODUCED the vertices is the FINE one: the export resamples
  // the field `factor`x before running marching cubes, so C1's "the voxel that
  // produced it" is spacing / factor, not spacing.
  const double cell = kHisSpacing / static_cast<double>(kExportFactor);
  std::printf("C1 cell (the lattice that produced the vertices) = %.6f mm = "
              "spacing / factor.\nTrust radius at 0.5 cells = %.6f mm.\n\n",
              cell, 0.5 * cell);

  Vec3 sc;
  const VoxelGrid sg = sphere_grid(kSphereR, kHisSpacing, sc);
  const std::vector<double> socc = occupancy(sg);
  const TriangleMesh raw = marching_cubes_resampled(
      sg.nx, sg.ny, sg.nz, sg.spacing, sg.origin, socc, 0.5, kExportFactor,
      ResampleInterp::Tricubic);
  // Through the same STL round trip the app puts every mesh through — that trip
  // welds, and an unwelded soup has no topology for any of these operators.
  const std::string spath =
      (evidence_dir.empty() ? std::string(".") : evidence_dir) + "/sphere_control.stl";
  write_stl_file(spath, raw);
  const TriangleMesh mesh = read_stl_file(spath).mesh;
  std::remove(spath.c_str());

  if (mesh.vertices.empty()) {
    std::printf("FATAL: the sphere fixture is empty.\n");
    return 1;
  }
  const SphereReading base = sphere_deviation(mesh, sc, kSphereR);
  const double base_vol = std::fabs(signed_volume(mesh));
  std::printf("baseline: %zu verts / %zu tris, rms %.4f mm, max %.4f mm, "
              "volume %.3f mm3\n", mesh.vertices.size(), mesh.triangles.size(),
              base.rms_mm, base.max_mm, base_vol);
  // The precondition that makes every percentage below mean something.
  if (!(base.rms_mm > 0.0)) {
    std::printf("FATAL: the baseline deviation is zero — nothing to remove.\n");
    return 1;
  }

  std::vector<Row> rows;
  auto add_baseline = [&] {
    Row r;
    r.label = "unsmoothed (PR 299 base)";
    r.dev = base;
    r.dihed = dihedral_rms_deg(mesh);
    r.verts = mesh.vertices.size();
    r.tris = mesh.triangles.size();
    rows.push_back(r);
  };

  SurfaceConstraints k;
  k.cell_mm = cell;
  k.trust_voxels = 0.5;

  // ───────────────────────────────────────────────────────────────────────────
  std::printf("\n== S3.1 THE BAKE-OFF ON THE ANALYTIC SPHERE ==\n");
  std::printf("Taubin rows reproduce PR 299 §S1(d) exactly (guard OFF, which is the\n"
              "best the family can do anywhere, not the strength the app ships).\n"
              "A and B rows are under C1 at 0.5 cells and C3 on. C2 is INERT here —\n"
              "a sphere has no load path, no thin section and no design box — which\n"
              "is stated rather than hidden: S3.4 exercises C2 on a fixture that has\n"
              "all three.\n\n");
  print_header();
  add_baseline();
  print_row(rows.back(), base.rms_mm);

  // ── the incumbent, for the same table ──
  for (const int pairs : {5, 20, 80, 160}) {
    TaubinParams tp;
    tp.pairs = pairs;
    SmoothConstraints tc;
    tc.enforce_min_feature = false;  // PR 299's "off" rows: the family's best case
    const Clock::time_point t0 = Clock::now();
    const SmoothResult sr = constrained_taubin_smooth(mesh, tp, tc);
    Row r;
    r.label = "Taubin pairs " + std::to_string(pairs);
    r.wall_s = secs_since(t0);
    r.dev = sphere_deviation(sr.mesh, sc, kSphereR);
    r.dihed = dihedral_rms_deg(sr.mesh);
    r.verts = sr.mesh.vertices.size();
    r.tris = sr.mesh.triangles.size();
    r.iterations = sr.stats.applied_pairs;
    r.vol_drift_pct = 100.0 * sr.stats.volume_drift_fraction;
    for (std::size_t v = 0; v < mesh.vertices.size(); ++v) {
      const Vec3& a = mesh.vertices[v];
      const Vec3& b = sr.mesh.vertices[v];
      r.max_motion = std::fmax(r.max_motion,
                               std::sqrt((a.x - b.x) * (a.x - b.x) +
                                         (a.y - b.y) * (a.y - b.y) +
                                         (a.z - b.z) * (a.z - b.z)));
    }
    rows.push_back(r);
    print_row(r, base.rms_mm);
    std::fflush(stdout);
  }

  // ── OPERATOR A ──
  for (const int steps : {1, 2, 5, 10, 20, 40, 80, 160}) {
    MeanCurvatureParams p;
    p.steps = steps;
    const SurfaceOperatorResult sr = mean_curvature_flow(mesh, p, k);
    Row r;
    r.label = "A mean-curvature x" + std::to_string(steps);
    r.dev = sphere_deviation(sr.mesh, sc, kSphereR);
    r.dihed = dihedral_rms_deg(sr.mesh);
    r.max_motion = sr.stats.max_displacement_mm;
    r.vol_drift_pct = 100.0 * sr.stats.volume_drift_fraction;
    r.verts = sr.stats.vertices_out;
    r.tris = sr.stats.triangles_out;
    r.c1_clamped = sr.stats.c1_clamped;
    r.iterations = sr.stats.applied_steps;
    r.wall_s = sr.stats.wall_seconds;
    rows.push_back(r);
    print_row(r, base.rms_mm);
    std::fflush(stdout);
  }

  // ── OPERATOR B ──
  for (const int rings : {1, 2})
    for (const double edge : {0.0, 0.5})
      for (const int steps : {1, 2, 4, 8}) {
        RampParams p;
        p.steps = steps;
        p.fit_rings = rings;
        p.target_edge_cells = edge;
        const SurfaceOperatorResult sr = ramp_reconstruction(mesh, p, k);
        Row r;
        char buf[64];
        std::snprintf(buf, sizeof(buf), "B ramp r%d e%.1f x%d", rings, edge, steps);
        r.label = buf;
        r.dev = sphere_deviation(sr.mesh, sc, kSphereR);
        r.dihed = dihedral_rms_deg(sr.mesh);
        r.max_motion = sr.stats.max_displacement_mm;
        r.vol_drift_pct = 100.0 * sr.stats.volume_drift_fraction;
        r.verts = sr.stats.vertices_out;
        r.tris = sr.stats.triangles_out;
        r.c1_clamped = sr.stats.c1_clamped;
        r.iterations = sr.stats.applied_steps;
        r.wall_s = sr.stats.wall_seconds;
        rows.push_back(r);
        print_row(r, base.rms_mm);
        std::fflush(stdout);
      }

  if (!evidence_dir.empty()) {
    std::ofstream f(evidence_dir + "/sphere_bakeoff.csv");
    f << "configuration,max_mm,rms_mm,pct_of_base,pct_removed,dihedral_deg,"
         "max_motion_mm,volume_drift_pct,verts,tris,c1_clamped,iterations,wall_s\n";
    for (const Row& r : rows) csv_row(f, r, base.rms_mm);
  }

  // ───────────────────────────────────────────────────────────────────────────
  std::printf("\n== S3.2 DOES OPERATOR B MEET C1 BY CONSTRUCTION? ==\n");
  std::printf("The claim under test: a ramp between a terrace's own extremes lies\n"
              "inside that terrace's envelope, so the trust region is met without\n"
              "clamping. Measured by running B with C1 DISABLED and asking how far\n"
              "outside the box it would have gone, and by counting how often the\n"
              "envelope clamp itself bit.\n\n");
  std::printf("%-24s %10s %12s %14s %10s %14s\n", "configuration", "C1 off:",
              "would exceed", "deepest exc mm", "envelope", "max env mm");
  std::printf("%-24s %10s %12s %14s %10s %14s\n", "", "maxmove", "C1 (verts)", "",
              "clamps", "");
  for (const int rings : {1, 2})
    for (const int steps : {1, 4, 8}) {
      RampParams p;
      p.steps = steps;
      p.fit_rings = rings;
      p.target_edge_cells = 0.5;
      SurfaceConstraints free_k = k;
      free_k.trust_voxels = 0.0;  // C1 off, so the raw construction is visible
      const SurfaceOperatorResult raw_run = ramp_reconstruction(mesh, p, free_k);
      // The C1-armed run's own counters answer the question directly:
      // `c1_would_violate` is the number of vertices whose UNCLAMPED target was
      // already outside the box, and `max_unclamped_excursion_mm` is how far. The
      // refinement is deterministic, so both runs see the same vertex set.
      const SurfaceOperatorResult clamped = ramp_reconstruction(mesh, p, k);
      const double radius = 0.5 * cell;
      const std::size_t would = clamped.stats.c1_would_violate;
      const double deepest = clamped.stats.max_unclamped_excursion_mm;
      char buf[64];
      std::snprintf(buf, sizeof(buf), "B ramp r%d e0.5 x%d", rings, steps);
      std::printf("%-24s %10.4f %12zu %14.4f %10zu %14.4f\n", buf,
                  raw_run.stats.max_displacement_mm, would, deepest,
                  clamped.stats.envelope_clamped, clamped.stats.max_envelope_clamp_mm);
      std::printf("%-24s (trust radius %.4f mm; %zu of %zu vertices)\n", "", radius,
                  would, clamped.stats.vertices_out);
      std::fflush(stdout);
    }

  // ───────────────────────────────────────────────────────────────────────────
  std::printf("\n== S3.3 THE INSTRUMENTS, VALIDATED ==\n");
  std::printf("Every instrument below is checked against a fixture whose answer is\n"
              "known by construction. An instrument that has never been shown to\n"
              "MOVE cannot be trusted to report that something did not.\n\n");

  std::printf("-- minimum cross-section: a dumbbell with a neck of known width --\n");
  std::printf("The measure has a 2-voxel quantum (2*r*spacing, r integer), so the\n"
              "sweep uses EVEN necks it can actually represent. An odd neck reads\n"
              "down to the next even value and that is a property of the instrument,\n"
              "not of the part.\n\n");
  std::printf("%-14s %12s %12s %12s %12s %11s %9s\n", "neck (voxels)", "expected mm",
              "measured min", "global min", "p01 mm", "components", "dropped");
  bool xsec_ok = true;
  for (const int neck : {2, 4, 6}) {
    int n = 0;
    const VoxelGrid dg = dumbbell_grid(neck, 1.0, n);
    const std::vector<double> docc = occupancy(dg);
    const TriangleMesh dm =
        marching_cubes(dg.nx, dg.ny, dg.nz, dg.spacing, dg.origin, docc, 0.5);
    const CrossSection cs = min_cross_section(dm, dg);
    const double expected = static_cast<double>(neck) * dg.spacing;
    const bool hit = std::fabs(cs.min_mm - expected) < 1e-9;
    std::printf("%-14d %12.3f %12.3f %12.3f %12.3f %11zu %9zu%s\n", neck, expected,
                cs.min_mm, cs.global_min_mm, cs.p01_mm, cs.components,
                cs.dropped_voxels, hit ? "" : "   <-- MISMATCH");
    if (!hit) xsec_ok = false;
  }
  std::printf("Hildebrand min tracks the constructed neck width EXACTLY: %s\n",
              xsec_ok ? "YES" : "NO — see the note above; it is corner-limited");

  std::printf("\n-- minimum cross-section, measured as a SLICE AREA --\n");
  std::printf("%-14s %14s %14s %14s %12s %12s\n", "neck (voxels)", "expected mm2",
              "source mm2", "exported mm2", "equiv w mm", "solid vox");
  bool slice_ok = true;
  for (const int neck : {2, 3, 4, 6}) {
    int n = 0;
    const VoxelGrid dg = dumbbell_grid(neck, 1.0, n);
    const std::vector<double> docc = occupancy(dg);
    const SliceSection src = min_slice_section(dg, docc, 0.5);
    const TriangleMesh dm =
        marching_cubes(dg.nx, dg.ny, dg.nz, dg.spacing, dg.origin, docc, 0.5);
    const SliceSection exp_ = min_slice_section_of(dm, dg);
    const double expected =
        static_cast<double>(neck) * static_cast<double>(neck) * dg.spacing * dg.spacing;
    const bool hit = std::fabs(src.min_area_mm2 - expected) < 1e-9;
    std::printf("%-14d %14.3f %14.3f %14.3f %12.3f %12zu%s\n", neck, expected,
                src.min_area_mm2, exp_.min_area_mm2, src.equiv_width_mm,
                src.solid_voxels, hit ? "" : "   <-- MISMATCH");
    if (!hit) slice_ok = false;
  }
  std::printf("slice-area instrument reproduces the constructed neck EXACTLY on the\n"
              "source occupancy: %s\n", slice_ok ? "YES" : "NO");
  std::printf("\nTHE `exported mm2` COLUMN IS NOT THE SAME NUMBER, AND THAT IS A\n"
              "PRE-EXISTING CORE DEFECT, NOT AN OPERATOR EFFECT. Round-tripping the\n"
              "solid through marching_cubes and voxelize_onto_grid (voxel.hpp:121)\n"
              "ADDS solid voxels the source never had: on the neck-6 dumbbell,\n"
              "1888 source voxels become 1932, and the 44 extra ones sit in columns\n"
              "at (10,11,k) and (17,11,k) running from the bridge down to k = 0,\n"
              "through space the source marks VOID. Those columns are the exact\n"
              "corner columns of an axis-aligned bridge, which is the signature of\n"
              "a parity/ray fill flipping on a degenerate edge hit. They are\n"
              "CONNECTED to the part, so a largest-component filter does not remove\n"
              "them, and because this statistic is a minimum they set a floor.\n"
              "Consequence, stated plainly: the ABSOLUTE cross-section readings in\n"
              "S3.4 carry that floor, so only the CHANGE from the exported baseline\n"
              "is read there, and the solid-voxel count is printed beside it so a\n"
              "change in the fill itself cannot masquerade as a change in the part.\n");

  std::printf("\n-- maximum outward excursion: a constructed violation --\n");
  {
    const Vec3 lo{0.0, 0.0, 0.0}, hi{10.0, 10.0, 10.0};
    TriangleMesh inside;
    inside.vertices = {Vec3{1, 1, 1}, Vec3{9, 1, 1}, Vec3{1, 9, 1}};
    inside.triangles = {{0, 1, 2}};
    TriangleMesh outside = inside;
    outside.vertices[1] = Vec3{10.75, 1, 1};  // 0.75 mm past the wall
    const double e_in = max_outward_excursion(inside, lo, hi);
    const double e_out = max_outward_excursion(outside, lo, hi);
    std::printf("  wholly inside the box : %+8.4f mm (must be <= 0)\n", e_in);
    std::printf("  one vertex 0.75 mm out: %+8.4f mm (must read 0.75)\n", e_out);
    std::printf("instrument separates the two: %s\n",
                (e_in <= 0.0 && std::fabs(e_out - 0.75) < 1e-9) ? "YES" : "NO");
  }

  // ───────────────────────────────────────────────────────────────────────────
  std::printf("\n== S3.4 THE NUMBERS THAT DECIDE IT, ON A FIXTURE WITH A TENDRIL ==\n");
  std::printf("The sphere has no tendril, so the minimum cross-section cannot be\n"
              "exercised on it. The dumbbell can: a 2-voxel neck is the thinnest\n"
              "member and is exactly what a smoother necks. That neck also sits ON\n"
              "the 2-voxel floor §7 V3 gates at, so classify_trust_sign reads it as\n"
              "material that matters and C2 makes it OUTWARD-ONLY. The design box\n"
              "clips ONE side only, so the InwardOnly and Both cases are present\n"
              "too rather than the box swallowing the whole part.\n\n");
  {
    int n = 0;
    const VoxelGrid dg = dumbbell_grid(2, 1.0, n);
    const std::vector<double> docc = occupancy(dg);
    const TriangleMesh draw = marching_cubes_resampled(
        dg.nx, dg.ny, dg.nz, dg.spacing, dg.origin, docc, 0.5, kExportFactor,
        ResampleInterp::Tricubic);
    const std::string dpath =
        (evidence_dir.empty() ? std::string(".") : evidence_dir) + "/dumbbell.stl";
    write_stl_file(dpath, draw);
    const TriangleMesh dm = read_stl_file(dpath).mesh;
    std::remove(dpath.c_str());

    const double dcell = dg.spacing / kExportFactor;
    const CrossSection cs0 = min_cross_section(dm, dg);
    Vec3 blo, bhi;
    bounding_box(dm, blo, bhi);
    // The design box CONTAINS the part exactly on its +x face and is generous
    // everywhere else, so the exported mesh starts at excursion 0.0 and only that
    // face reads InwardOnly. A box that already clipped the part would make every
    // row below read "outside the box" for a reason the operator did not cause.
    Vec3 box_lo = blo, box_hi = bhi;
    box_lo.x -= 5.0; box_lo.y -= 5.0; box_lo.z -= 5.0;
    box_hi.y += 5.0; box_hi.z += 5.0;
    const double e0 = max_outward_excursion(dm, box_lo, box_hi);
    const double v0 = std::fabs(signed_volume(dm));

    TrustSignPolicy pol;
    pol.load_path_binds = true;
    pol.has_design_box = true;
    pol.box_min = box_lo;
    pol.box_max = box_hi;
    // THE BIND TOLERANCE MUST COVER THE TRUST REGION'S DIAGONAL. C1 is a CUBE of
    // half-width r, so the furthest a vertex can travel is r*sqrt(3), not r. A
    // vertex sitting between r and r*sqrt(3) inside the wall would be classified
    // `Both` — free to move outward — and could still reach it. Measured here at
    // r = %.4f mm, so the tolerance is set to the diagonal.
    pol.bind_tol_mm = 0.5 * dcell * 1.7320508075688772;
    const std::vector<TrustSign> sign = classify_trust_sign(dm, dg, docc, pol);
    std::size_t n_out = 0, n_in = 0, n_pin = 0, n_both = 0;
    for (const TrustSign s2 : sign) {
      if (s2 == TrustSign::OutwardOnly) ++n_out;
      else if (s2 == TrustSign::InwardOnly) ++n_in;
      else if (s2 == TrustSign::Pinned) ++n_pin;
      else ++n_both;
    }
    std::printf("trust radius %.4f mm (0.5 cell), so the box bind tolerance is its\n"
                "cube diagonal %.4f mm — see the note in the source.\n",
                0.5 * dcell, pol.bind_tol_mm);
    std::printf("C2 classification of %zu vertices: %zu OutwardOnly, %zu InwardOnly,"
                " %zu Pinned, %zu Both\n", sign.size(), n_out, n_in, n_pin, n_both);
    if (n_out == 0)
      std::printf("  !! NO vertex reads as material that matters — C2's outward arm "
                  "is INERT on this fixture and the rows below do not test it.\n");
    // The bridge runs along x over i in [10,18) by construction.
    const int kBridgeLo = 10, kBridgeHi = 18;
    const SliceSection sl0 = min_slice_section_of(dm, dg);
    const SliceSection nk0 =
        min_slice_section_range_of(dm, dg, 0, kBridgeLo, kBridgeHi);
    const char* axname = "xyz";
    std::printf("\n`TENDRIL` is the minimum cross-section OF THE BRIDGE ITSELF "
                "(x-slices over\ni in [%d,%d)) — the number his objection is about. "
                "`whole part` is the same\nstatistic over the entire grid, and its "
                "LOCATION is printed because the fill\ndefect documented in S3.3 "
                "puts an artefact column at z = 0 that can be thinner\nthan any real "
                "member.\n\n", kBridgeLo, kBridgeHi);
    std::printf("%-26s %10s %10s %10s %10s %10s %11s %7s\n", "configuration",
                "TENDRIL", "d TENDRIL", "whole part", "at", "max exc", "volume mm3",
                "wall s");
    std::printf("%-26s %10s %10s %10s %10s %10s %11s %7s\n", "", "mm2", "mm2", "mm2",
                "", "mm", "", "s");
    std::printf("%-26s %10.4f %10s %10.4f %8c=%-2d %+10.4f %11.3f %7s\n",
                "as exported today", nk0.min_area_mm2, "-", sl0.min_area_mm2,
                axname[sl0.axis], sl0.index, e0, v0, "-");

    auto measure = [&](const std::string& label, const TriangleMesh& m, double wall) {
      const CrossSection cs = min_cross_section(m, dg);
      const SliceSection sl = min_slice_section_of(m, dg);
      const SliceSection nk =
          min_slice_section_range_of(m, dg, 0, kBridgeLo, kBridgeHi);
      const double e = max_outward_excursion(m, box_lo, box_hi);
      const double v = std::fabs(signed_volume(m));
      const double dneck = nk.min_area_mm2 - nk0.min_area_mm2;
      const char* flag = "";
      if (dneck < -1e-9) flag = "  <-- THE TENDRIL NECKED";
      else if (e > 1e-12) flag = "  <-- OUTSIDE THE DESIGN BOX";
      else if (cs.components > cs0.components) flag = "  <-- A COMPONENT SPLIT OFF";
      std::printf("%-26s %10.4f %+10.4f %10.4f %8c=%-2d %+10.4f %11.3f %7.3f%s\n",
                  label.c_str(), nk.min_area_mm2, dneck, sl.min_area_mm2,
                  "xyz"[sl.axis < 0 ? 0 : sl.axis], sl.index, e, v, wall, flag);
    };

    SurfaceConstraints dk;
    dk.cell_mm = dcell;
    dk.trust_voxels = 0.5;
    SurfaceConstraints dk2 = dk;
    dk2.sign = sign;

    for (const int steps : {10, 40}) {
      MeanCurvatureParams p;
      p.steps = steps;
      const SurfaceOperatorResult a1 = mean_curvature_flow(dm, p, dk);
      measure("A x" + std::to_string(steps) + "  C2 OFF", a1.mesh, a1.stats.wall_seconds);
      const SurfaceOperatorResult a2 = mean_curvature_flow(dm, p, dk2);
      measure("A x" + std::to_string(steps) + "  C2 ARMED", a2.mesh,
              a2.stats.wall_seconds);
    }
    for (const int steps : {2, 8}) {
      RampParams p;
      p.steps = steps;
      p.target_edge_cells = 0.5;
      const SurfaceOperatorResult b1 = ramp_reconstruction(dm, p, dk);
      measure("B x" + std::to_string(steps) + "  C2 OFF", b1.mesh, b1.stats.wall_seconds);
      const SurfaceOperatorResult b2 = ramp_reconstruction(dm, p, dk2);
      measure("B x" + std::to_string(steps) + "  C2 ARMED", b2.mesh,
              b2.stats.wall_seconds);
    }
    for (const int pairs : {20, 160}) {
      TaubinParams tp;
      tp.pairs = pairs;
      SmoothConstraints tc;
      tc.enforce_min_feature = false;
      const Clock::time_point t0 = Clock::now();
      const SmoothResult sr = constrained_taubin_smooth(dm, tp, tc);
      measure("Taubin pairs " + std::to_string(pairs), sr.mesh, secs_since(t0));
    }
  }

  std::printf("\n== S3.5 WALL TIME PER STROKE AT HIS MESH SIZE ==\n");
  std::printf("The point of all of this is a BRUSH, so the number that matters is\n"
              "one stroke on a mesh the size of his. His part voxelized at 128 and\n"
              "exported at factor %d, through the same weld the app's round trip\n"
              "does.\n\n", kExportFactor);
  {
    const StlMesh bracket = read_stl_file(bracket_path);
    if (bracket.mesh.triangles.empty()) {
      std::printf("SKIPPED: could not read %s\n", bracket_path.c_str());
    } else {
      const VoxelGrid bg = voxelize(bracket.mesh, 128);
      const std::vector<double> bocc = occupancy(bg);
      const TriangleMesh braw = marching_cubes_resampled(
          bg.nx, bg.ny, bg.nz, bg.spacing, bg.origin, bocc, 0.5, kExportFactor,
          ResampleInterp::Tricubic);
      const std::string bpath =
          (evidence_dir.empty() ? std::string(".") : evidence_dir) + "/bracket_export.stl";
      write_stl_file(bpath, braw);
      const TriangleMesh bm = read_stl_file(bpath).mesh;
      std::remove(bpath.c_str());
      const double bcell = bg.spacing / kExportFactor;
      std::printf("his mesh: %zu verts / %zu tris, grid %dx%dx%d spacing %.6f mm, "
                  "cell %.6f mm\n\n", bm.vertices.size(), bm.triangles.size(), bg.nx,
                  bg.ny, bg.nz, bg.spacing, bcell);

      SurfaceConstraints bk;
      bk.cell_mm = bcell;
      bk.trust_voxels = 0.5;
      std::printf("%-30s %10s %10s %14s\n", "one stroke", "iters", "wall s",
                  "ms / iteration");
      for (const int steps : {5, 20}) {
        MeanCurvatureParams p;
        p.steps = steps;
        const SurfaceOperatorResult r = mean_curvature_flow(bm, p, bk);
        std::printf("%-30s %10d %10.3f %14.1f\n",
                    ("A mean-curvature x" + std::to_string(steps)).c_str(),
                    r.stats.applied_steps, r.stats.wall_seconds,
                    1000.0 * r.stats.wall_seconds /
                        std::fmax(1, r.stats.applied_steps));
        std::fflush(stdout);
      }
      for (const int steps : {2, 8}) {
        RampParams p;
        p.steps = steps;
        p.target_edge_cells = 0.5;
        const SurfaceOperatorResult r = ramp_reconstruction(bm, p, bk);
        std::printf("%-30s %10d %10.3f %14.1f  (%zu -> %zu verts)\n",
                    ("B ramp x" + std::to_string(steps)).c_str(), r.stats.applied_steps,
                    r.stats.wall_seconds,
                    1000.0 * r.stats.wall_seconds / std::fmax(1, r.stats.applied_steps),
                    r.stats.vertices_in, r.stats.vertices_out);
        std::fflush(stdout);
      }
      for (const int pairs : {20}) {
        TaubinParams tp;
        tp.pairs = pairs;
        SmoothConstraints tc;
        tc.enforce_min_feature = false;
        const Clock::time_point t0 = Clock::now();
        const SmoothResult sr = constrained_taubin_smooth(bm, tp, tc);
        std::printf("%-30s %10d %10.3f %14.1f\n",
                    ("Taubin pairs " + std::to_string(pairs)).c_str(),
                    sr.stats.applied_pairs, secs_since(t0),
                    1000.0 * secs_since(t0) / std::fmax(1, sr.stats.applied_pairs));
      }
    }
  }

  std::printf("\n== END ==\n");
  return 0;
}
