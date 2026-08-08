// field_information_probe — S2 of task 2026-08-08-closing-flow-and-the-field.
//
// ── THE QUESTION ─────────────────────────────────────────────────────────────
//
// Wedekind et al. (TU Braunschweig, 2021) remove CT stair-step artefacts by
// optimising VERTEX POSITIONS against the ORIGINAL PROJECTIONS rather than
// against the voxel grid, and report the artefact removed "almost entirely" at
// little extra cost. The analogue here is the PRE-BINARIZATION DENSITY FIELD,
// which this project HAS: `design.bin` stores the optimizer's converged physical
// density as f64, deliberately un-narrowed.
//
// So: does that field still carry sub-voxel information the mesh threw away?
//
// ── WHY THE ANSWER IS NOT OBVIOUS EITHER WAY ─────────────────────────────────
//
// Marching cubes ALREADY uses the grayscale. `mesh.cpp:549` places each vertex at
//     frac = (iso - va) / (vb - va)
// along the lattice edge, so a field with a real gradient across a step yields a
// sub-voxel placement for free — and PR 299 still measured a stair-step
// amplitude of rms 0.3424 mm on the extracted surface. Two things could explain
// that, and they have opposite consequences:
//
//   (i)  the field is NEAR-BINARY at the boundary, so `frac` is pinned near 0.5
//        on every crossing and the placement carries no information. Then the
//        staircase is grid combinatorics, the information is genuinely gone, and
//        resolution is the only lever. ★ THAT ANSWER IS WORTH THE DAY ON ITS OWN.
//
//   (ii) the field is grayscale, `frac` varies, and the per-cell placement is
//        merely NOISY — in which case a GLOBAL fit of all vertex positions
//        against the field (smooth, but stay on the level set) recovers what the
//        per-cell interpolation could not. That is the Wedekind analogue, and it
//        is a FITTING operator, not a fourth filter.
//
// This probe measures which, and then — only if the field turns out to carry
// something — measures what the fit recovers on one rung.
//
// ── WHAT IS MEASURED ─────────────────────────────────────────────────────────
//
// S2.b(1) The density histogram of the whole grid, and of the BOUNDARY voxels
//         specifically (a voxel with a 6-neighbour on the other side of iso, the
//         same neighbourhood and the same out-of-grid background 0.0 that
//         `SampleField::value` uses, so "boundary" means what marching cubes
//         means by it).
//
// S2.b(2) ★ THE DECIDING READING: the distribution of `frac` itself, computed by
//         replicating `mesh.cpp`'s edge loop on the SAME lattice the shipped
//         export runs on (tricubic resample to factor 2). A binary field gives
//         frac == 0.5 on every crossing — every vertex at an edge midpoint,
//         which IS a staircase. The spread of frac is the sub-voxel information,
//         and rms|frac - 0.5| * cell converts it into millimetres so it can be
//         read directly against the staircase's own 0.3424 mm.
//
// S2.b(3) The same, split CAD / optimizer-cut, because the cut population is the
//         one the brush and the three failed operators are aimed at. THE SPLIT IS
//         AN APPROXIMATION of PR 307's classifier and says so where it is defined
//         — a lattice crossing is not a mesh vertex, so the classifier cannot be
//         called on one. It is a secondary reading; nothing decisive rests on it.
//
// S2.d    IF the field carries something: a vertex-position optimisation against
//         it — alternate (a) an umbrella-Laplacian fairing step with (b) a
//         Newton projection back onto the field's 0.5 level set — under C1 (half
//         a cell) and C4 (CAD vertices frozen). Reported against Taubin at the
//         same freeze, and against the SAME operator with the field term removed,
//         which is the positive control that says whether the field did the work
//         or the fairing did.
//
//   cmake --build core/build --target field_information_probe
//   ./core/build/field_information_probe <design.bin> <part.step> [evidence_dir]

#include "topopt/cad_project.hpp"
#include "topopt/design_store.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/mesh.hpp"
#include "topopt/smooth.hpp"
#include "topopt/step.hpp"
#include "topopt/surface_operator.hpp"
#include "topopt/voxel.hpp"

#include "stairstep_metric.hpp"
#include "surface_instruments.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;
using namespace topopt::stairstep;
using namespace topopt::surface_instruments;

namespace {

constexpr int kShippedFactor = 2;
constexpr double kIso = 0.5;

// PR 299's measured stair-step amplitude on the oblique surface, the number every
// sub-voxel reading below has to be read against.
constexpr double kStaircaseRmsMm = 0.3424;

TriangleMesh extract(const VoxelGrid& g, const std::vector<double>& rho,
                     int factor) {
  return keep_largest_component(marching_cubes_resampled(
      g.nx, g.ny, g.nz, g.spacing, g.origin, rho, kIso, factor,
      ResampleInterp::Tricubic));
}

// ─────────────────────────────────────────────────────────────────────────────
// A LATTICE, SAMPLED THE WAY marching_cubes SAMPLES IT
// ─────────────────────────────────────────────────────────────────────────────
//
// `SampleField` in mesh.cpp is file-local, so its two rules are reproduced here
// and named: out-of-grid reads background 0.0 (the one-layer zero pad that closes
// a solid touching the boundary), and sample (i,j,k) sits at
// origin + (i+0.5)*spacing. Anything that disagrees with those two would be
// measuring a different surface from the one that ships.
struct Lattice {
  int nx = 0, ny = 0, nz = 0;
  double spacing = 0.0;
  Vec3 origin;
  const std::vector<double>* f = nullptr;

  double at(int i, int j, int k) const {
    if (i < 0 || i >= nx || j < 0 || j >= ny || k < 0 || k >= nz) return 0.0;
    return (*f)[(static_cast<std::size_t>(k) * ny + j) * nx + i];
  }
  Vec3 pos(int i, int j, int k) const {
    return Vec3{origin.x + (i + 0.5) * spacing, origin.y + (j + 0.5) * spacing,
                origin.z + (k + 0.5) * spacing};
  }
  // Trilinear value at a model-space point, in the same lattice-centre frame.
  // Along a lattice edge this is EXACTLY marching cubes' linear interpolation,
  // which is what makes "the level set this returns" and "the surface that
  // shipped" the same object rather than two nearby ones.
  double sample(const Vec3& p) const {
    const double u = (p.x - origin.x) / spacing - 0.5;
    const double v = (p.y - origin.y) / spacing - 0.5;
    const double w = (p.z - origin.z) / spacing - 0.5;
    const int i = static_cast<int>(std::floor(u));
    const int j = static_cast<int>(std::floor(v));
    const int k = static_cast<int>(std::floor(w));
    const double fx = u - i, fy = v - j, fz = w - k;
    double acc = 0.0;
    for (int dk = 0; dk < 2; ++dk)
      for (int dj = 0; dj < 2; ++dj)
        for (int di = 0; di < 2; ++di) {
          const double wt = (di ? fx : 1.0 - fx) * (dj ? fy : 1.0 - fy) *
                            (dk ? fz : 1.0 - fz);
          acc += wt * at(i + di, j + dj, k + dk);
        }
    return acc;
  }
  Vec3 gradient(const Vec3& p) const {
    const double h = 0.25 * spacing;
    return Vec3{
        (sample(Vec3{p.x + h, p.y, p.z}) - sample(Vec3{p.x - h, p.y, p.z})) / (2 * h),
        (sample(Vec3{p.x, p.y + h, p.z}) - sample(Vec3{p.x, p.y - h, p.z})) / (2 * h),
        (sample(Vec3{p.x, p.y, p.z + h}) - sample(Vec3{p.x, p.y, p.z - h})) / (2 * h)};
  }
};

struct Histogram {
  std::size_t n = 0;
  std::size_t bins[10] = {0};
  std::size_t at_or_below_lo = 0, at_or_above_hi = 0, strictly_between = 0;
  double lo = 0.0, hi = 1.0;
};

Histogram histogram(const std::vector<double>& v, const std::vector<char>& only,
                    double lo, double hi) {
  Histogram h;
  h.lo = lo;
  h.hi = hi;
  for (std::size_t i = 0; i < v.size(); ++i) {
    if (!only.empty() && !only[i]) continue;
    const double x = v[i];
    ++h.n;
    int b = static_cast<int>(x * 10.0);
    b = std::max(0, std::min(9, b));
    ++h.bins[b];
    if (x <= lo) ++h.at_or_below_lo;
    else if (x >= hi) ++h.at_or_above_hi;
    else ++h.strictly_between;
  }
  return h;
}

void print_histogram(const char* title, const Histogram& h) {
  std::printf("  %s  (n = %zu)\n", title, h.n);
  if (h.n == 0) return;
  for (int b = 0; b < 10; ++b)
    std::printf("      rho [%.1f,%.1f)  %10zu  %6.2f%%\n", 0.1 * b, 0.1 * (b + 1),
                h.bins[b], 100.0 * h.bins[b] / h.n);
  std::printf("      <= %.5f : %10zu (%6.3f%%)   >= %.5f : %10zu (%6.3f%%)"
              "   STRICTLY BETWEEN : %zu (%.3f%%)\n",
              h.lo, h.at_or_below_lo, 100.0 * h.at_or_below_lo / h.n, h.hi,
              h.at_or_above_hi, 100.0 * h.at_or_above_hi / h.n,
              h.strictly_between, 100.0 * h.strictly_between / h.n);
}

// ─────────────────────────────────────────────────────────────────────────────
// THE CROSSING STATISTIC
// ─────────────────────────────────────────────────────────────────────────────
struct Crossings {
  std::size_t n = 0;
  std::size_t bins[10] = {0};       // frac in [0,1), 10 bins
  double mean = 0.0;
  double rms_offset = 0.0;          // rms |frac - 0.5|, dimensionless
  double rms_offset_mm = 0.0;       // ... times the lattice spacing
  double max_offset = 0.0;
  std::size_t within_1pct = 0;      // |frac - 0.5| <= 0.01 — no information
  std::size_t beyond_10pct = 0;     // |frac - 0.5| >  0.10 — real placement
};

// Replicates the crossing half of `marching_cubes`: every lattice edge whose two
// endpoints straddle the iso value, over the SAME padded index range (-1 .. n).
// `classify`, when non-null, is called with the crossing's model-space position
// and returns true if it should be counted into `sel`.
void collect_crossings(const Lattice& L, Crossings& all, Crossings* sel,
                       bool (*classify)(const Vec3&, void*), void* ctx) {
  double s2 = 0.0, s2sel = 0.0, sum = 0.0, sumsel = 0.0;
  for (int k = -1; k <= L.nz; ++k)
    for (int j = -1; j <= L.ny; ++j)
      for (int i = -1; i <= L.nx; ++i) {
        const double va = L.at(i, j, k);
        const int off[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
        for (const auto& o : off) {
          const int bi = i + o[0], bj = j + o[1], bk = k + o[2];
          if (bi > L.nx || bj > L.ny || bk > L.nz) continue;
          const double vb = L.at(bi, bj, bk);
          const bool ain = va > kIso, bin = vb > kIso;
          if (ain == bin) continue;
          const double denom = vb - va;
          const double frac = denom != 0.0 ? (kIso - va) / denom : 0.5;
          const Vec3 pa = L.pos(i, j, k), pb = L.pos(bi, bj, bk);
          const Vec3 p{pa.x + frac * (pb.x - pa.x), pa.y + frac * (pb.y - pa.y),
                       pa.z + frac * (pb.z - pa.z)};
          const double d = std::fabs(frac - 0.5);
          ++all.n;
          sum += frac;
          s2 += d * d;
          int b = static_cast<int>(frac * 10.0);
          b = std::max(0, std::min(9, b));
          ++all.bins[b];
          all.max_offset = std::fmax(all.max_offset, d);
          if (d <= 0.01) ++all.within_1pct;
          if (d > 0.10) ++all.beyond_10pct;
          if (sel && classify && classify(p, ctx)) {
            ++sel->n;
            sumsel += frac;
            s2sel += d * d;
            ++sel->bins[b];
            sel->max_offset = std::fmax(sel->max_offset, d);
            if (d <= 0.01) ++sel->within_1pct;
            if (d > 0.10) ++sel->beyond_10pct;
          }
        }
      }
  if (all.n) {
    all.mean = sum / static_cast<double>(all.n);
    all.rms_offset = std::sqrt(s2 / static_cast<double>(all.n));
    all.rms_offset_mm = all.rms_offset * L.spacing;
  }
  if (sel && sel->n) {
    sel->mean = sumsel / static_cast<double>(sel->n);
    sel->rms_offset = std::sqrt(s2sel / static_cast<double>(sel->n));
    sel->rms_offset_mm = sel->rms_offset * L.spacing;
  }
}

void print_crossings(const char* title, const Crossings& c, double cell_mm) {
  std::printf("  %s\n", title);
  if (c.n == 0) { std::printf("      (none)\n"); return; }
  std::printf("      crossings %zu   mean frac %.5f\n", c.n, c.mean);
  for (int b = 0; b < 10; ++b)
    std::printf("        frac [%.1f,%.1f)  %10zu  %6.2f%%\n", 0.1 * b,
                0.1 * (b + 1), c.bins[b], 100.0 * c.bins[b] / c.n);
  std::printf("      |frac-0.5| <= 0.01 (NO sub-voxel information): %zu (%.2f%%)\n",
              c.within_1pct, 100.0 * c.within_1pct / c.n);
  std::printf("      |frac-0.5| >  0.10 (real sub-voxel placement): %zu (%.2f%%)\n",
              c.beyond_10pct, 100.0 * c.beyond_10pct / c.n);
  std::printf("      rms |frac-0.5| = %.5f  =>  %.4f mm on a %.4f mm cell"
              "   (staircase is %.4f mm)\n",
              c.rms_offset, c.rms_offset_mm, cell_mm, kStaircaseRmsMm);
  std::printf("      max |frac-0.5| = %.5f  =>  %.4f mm\n", c.max_offset,
              c.max_offset * cell_mm);
}

// ─────────────────────────────────────────────────────────────────────────────
// S2.d — THE VERTEX-POSITION OPTIMISATION
// ─────────────────────────────────────────────────────────────────────────────
//
// Alternates a fairing step with a projection back onto the field's own level
// set, under C1 and C4. `field_weight == 0` removes the projection and is the
// POSITIVE CONTROL: it is the same fairing with no field term, so any difference
// between the two rows is what the field contributed and nothing else.
struct FitParams {
  int iterations = 50;
  double fair = 0.5;         // umbrella-Laplacian step
  double field_weight = 1.0; // 0 disables the projection (the control)
  int newton_steps = 2;
  double trust_mm = 0.0;     // C1 half-width about the ORIGINAL position
};

struct FitStats {
  std::size_t projected = 0;
  std::size_t c1_clamped = 0;
  double max_residual_before = 0.0;  // |phi - 0.5| / |grad phi|, mm
  double max_residual_after = 0.0;
  double rms_residual_before = 0.0;
  double rms_residual_after = 0.0;
  double wall_s = 0.0;
};

double level_set_residual_mm(const Lattice& L, const Vec3& p) {
  const Vec3 g = L.gradient(p);
  const double gl = std::sqrt(g.x * g.x + g.y * g.y + g.z * g.z);
  if (!(gl > 1e-12)) return 0.0;
  return (L.sample(p) - kIso) / gl;
}

TriangleMesh field_fit(const TriangleMesh& in, const Lattice& L,
                       const FitParams& fp, const std::vector<char>& frozen,
                       FitStats& st) {
  const Clock::time_point t0 = Clock::now();
  TriangleMesh m = in;
  const std::size_t nv = in.vertices.size();

  // One-ring adjacency, built once.
  std::vector<std::vector<int>> ring(nv);
  for (const auto& tr : in.triangles)
    for (int e = 0; e < 3; ++e) {
      ring[static_cast<std::size_t>(tr[e])].push_back(tr[(e + 1) % 3]);
      ring[static_cast<std::size_t>(tr[(e + 1) % 3])].push_back(tr[e]);
    }
  for (auto& r : ring) {
    std::sort(r.begin(), r.end());
    r.erase(std::unique(r.begin(), r.end()), r.end());
  }

  {
    double s2 = 0.0;
    std::size_t n = 0;
    for (std::size_t v = 0; v < nv; ++v) {
      if (v < frozen.size() && frozen[v]) continue;
      const double d = std::fabs(level_set_residual_mm(L, in.vertices[v]));
      st.max_residual_before = std::fmax(st.max_residual_before, d);
      s2 += d * d;
      ++n;
    }
    if (n) st.rms_residual_before = std::sqrt(s2 / static_cast<double>(n));
  }

  std::vector<Vec3> next(nv);
  for (int it = 0; it < fp.iterations; ++it) {
    next = m.vertices;
    // (a) fairing
    for (std::size_t v = 0; v < nv; ++v) {
      if (v < frozen.size() && frozen[v]) continue;
      if (ring[v].empty()) continue;
      Vec3 c{0, 0, 0};
      for (const int u : ring[v]) {
        c.x += m.vertices[static_cast<std::size_t>(u)].x;
        c.y += m.vertices[static_cast<std::size_t>(u)].y;
        c.z += m.vertices[static_cast<std::size_t>(u)].z;
      }
      const double k = 1.0 / static_cast<double>(ring[v].size());
      next[v].x += fp.fair * (c.x * k - m.vertices[v].x);
      next[v].y += fp.fair * (c.y * k - m.vertices[v].y);
      next[v].z += fp.fair * (c.z * k - m.vertices[v].z);
    }
    // (b) projection back onto the field's level set
    if (fp.field_weight > 0.0) {
      for (std::size_t v = 0; v < nv; ++v) {
        if (v < frozen.size() && frozen[v]) continue;
        for (int s = 0; s < fp.newton_steps; ++s) {
          const Vec3 g = L.gradient(next[v]);
          const double gl2 = g.x * g.x + g.y * g.y + g.z * g.z;
          if (!(gl2 > 1e-24)) break;
          const double phi = L.sample(next[v]) - kIso;
          const double t = fp.field_weight * phi / gl2;
          next[v].x -= t * g.x;
          next[v].y -= t * g.y;
          next[v].z -= t * g.z;
        }
        ++st.projected;
      }
    }
    // (c) C1, about the ORIGINAL position
    if (fp.trust_mm > 0.0) {
      for (std::size_t v = 0; v < nv; ++v) {
        if (v < frozen.size() && frozen[v]) continue;
        const Vec3& o = in.vertices[v];
        double dx = next[v].x - o.x, dy = next[v].y - o.y, dz = next[v].z - o.z;
        const double d = std::sqrt(dx * dx + dy * dy + dz * dz);
        if (d > fp.trust_mm) {
          const double s = fp.trust_mm / d;
          next[v] = Vec3{o.x + dx * s, o.y + dy * s, o.z + dz * s};
          ++st.c1_clamped;
        }
      }
    }
    // C4 is a BRANCH, never a scaled write: a frozen vertex is never assigned,
    // so it stays byte-for-byte where it started.
    for (std::size_t v = 0; v < nv; ++v)
      if (!(v < frozen.size() && frozen[v])) m.vertices[v] = next[v];
  }

  {
    double s2 = 0.0;
    std::size_t n = 0;
    for (std::size_t v = 0; v < nv; ++v) {
      if (v < frozen.size() && frozen[v]) continue;
      const double d = std::fabs(level_set_residual_mm(L, m.vertices[v]));
      st.max_residual_after = std::fmax(st.max_residual_after, d);
      s2 += d * d;
      ++n;
    }
    if (n) st.rms_residual_after = std::sqrt(s2 / static_cast<double>(n));
  }
  st.wall_s = secs_since(t0);
  return m;
}

struct Population {
  std::vector<char> cad, cut;
  std::size_t n_cad = 0, n_cut = 0, n_ambiguous = 0;
};

Population split(const CadAttribution& att, std::size_t nverts) {
  Population p;
  p.cad.assign(nverts, 0);
  p.cut.assign(nverts, 0);
  for (std::size_t v = 0; v < nverts; ++v) {
    if (att.face_of_vertex[v] >= 0) { p.cad[v] = 1; ++p.n_cad; }
    else if (att.ambiguous_at(v))   { ++p.n_ambiguous; }
    else                            { p.cut[v] = 1; ++p.n_cut; }
  }
  return p;
}

struct Motion { double max_mm = 0.0, rms_mm = 0.0; std::size_t moved = 0; };

Motion motion(const TriangleMesh& a, const TriangleMesh& b,
              const std::vector<char>& only) {
  Motion m;
  double s2 = 0.0;
  std::size_t n = 0;
  const std::size_t lim = std::min(a.vertices.size(), b.vertices.size());
  for (std::size_t v = 0; v < lim; ++v) {
    if (!only.empty() && !only[v]) continue;
    const double dx = b.vertices[v].x - a.vertices[v].x;
    const double dy = b.vertices[v].y - a.vertices[v].y;
    const double dz = b.vertices[v].z - a.vertices[v].z;
    const double d = std::sqrt(dx * dx + dy * dy + dz * dz);
    if (d > 0.0) ++m.moved;
    if (d > m.max_mm) m.max_mm = d;
    s2 += d * d;
    ++n;
  }
  if (n) m.rms_mm = std::sqrt(s2 / static_cast<double>(n));
  return m;
}

std::size_t cad_vertices_that_moved(const TriangleMesh& a, const TriangleMesh& b,
                                    const std::vector<char>& cad) {
  std::size_t bad = 0;
  const std::size_t lim = std::min(a.vertices.size(), b.vertices.size());
  for (std::size_t v = 0; v < lim; ++v)
    if (cad[v] && std::memcmp(&a.vertices[v], &b.vertices[v], sizeof(Vec3)) != 0)
      ++bad;
  return bad;
}

struct CadCtx { const TriGrid* ref; double tol; };
// ★ THIS IS AN APPROXIMATION OF PR 307's CLASSIFIER, NOT THE CLASSIFIER, and the
// difference is named rather than glossed. `attribute_to_cad_faces` works on a
// MESH and takes a vertex's distance to a face's tessellated patch AND its
// analytic distance to that face's surface — PR 307 found the tessellated test
// alone is not enough, because a point past the end of a partial cylinder sits a
// hair from the patch and a voxel from the surface. A lattice CROSSING is not a
// mesh vertex, so the classifier cannot be called on it; this uses the
// classifier's own tolerance against the CAD tessellation and nothing more.
//
// It is used ONLY to split S2.b(3)'s crossing counts, which are a secondary
// reading. The decisive numbers (S2.b(1) and S2.b(2)) are whole-population and do
// not depend on it, and the vertex-level split in S2.d uses the REAL classifier.
bool is_cad_point(const Vec3& p, void* ctx) {
  const CadCtx* c = static_cast<const CadCtx*>(ctx);
  return c->ref->distance(p) <= c->tol;
}

}  // namespace


int main(int argc, char** argv) {
  if (argc < 3) {
    std::printf("usage: field_information_probe <design.bin> <part.step> [evidence_dir]\n");
    return 2;
  }
  const std::string design_path = argv[1];
  const std::string step_path = argv[2];
  const std::string ev = argc > 3 ? argv[3] : ".";

  DesignStore store = read_design_file(design_path);
  VoxelGrid grid;
  grid.nx = store.nx; grid.ny = store.ny; grid.nz = store.nz;
  grid.spacing = store.spacing; grid.origin = store.origin;
  grid.tags.assign(store.voxel_count(), VoxelTag::Empty);
  const double cell_mm = grid.spacing / kShippedFactor;

  std::printf("== field_information_probe — S2 of closing-flow-and-the-field ==\n\n");
  std::printf("design   %s\n", design_path.c_str());
  std::printf("grid     %d x %d x %d = %zu voxels, spacing %.6f mm\n", grid.nx,
              grid.ny, grid.nz, store.voxel_count(), grid.spacing);
  std::printf("export   factor %d (tricubic) => tessellation cell %.6f mm\n",
              kShippedFactor, cell_mm);
  std::printf("rungs    %zu\n\n", store.variants.size());

  const StepModel model = import_part_file_resolved(step_path);
  if (model.mesh.vertices.empty()) {
    std::printf("FATAL: the STEP imported empty — OCCT is required for this probe\n");
    return 2;
  }
  const CadProjectOptions copts = cad_project_options_for_grid(grid.spacing);
  const TriGrid cad_ref(model.mesh);
  CadCtx cadctx{&cad_ref, copts.tolerance_mm};
  std::printf("CAD      %zu faces, classifier tolerance %.6f mm\n\n",
              model.faces.size(), copts.tolerance_mm);

  // The run's own band ends, from
  // evidence/2026-08-03-multiscale-lattice-to/m2_multiscale_final/run_info.json
  // ("band_rho_min" / "band_rho_max", identical on all four rungs).
  const double band_lo = 0.05047, band_hi = 0.89988;

  std::ofstream csv(ev + "/s2_field_information.csv");
  // ★ EVERY CROSSING COLUMN NAMES ITS LATTICE. The design lattice and the
  // shipped (tricubic factor-2) lattice give OPPOSITE-LOOKING answers — see
  // S2.3 — and a column called `frac_rms_offset` would be read as whichever the
  // reader assumed. `design_` is the field's own information; `shipped_` is that
  // plus whatever the resample interpolated into being.
  csv << "rung,voxels,solid_voxels,boundary_voxels,boundary_strictly_between,"
         "boundary_gray_pct,"
         "design_crossings,design_frac_mean,design_frac_rms_offset,"
         "design_frac_rms_offset_mm,design_frac_within_1pct_pct,"
         "design_frac_beyond_10pct_pct,"
         "shipped_crossings,shipped_frac_mean,shipped_frac_rms_offset,"
         "shipped_frac_rms_offset_mm,shipped_frac_within_1pct_pct,"
         "shipped_frac_beyond_10pct_pct,"
         "shipped_cut_crossings,shipped_cut_frac_rms_offset_mm\n";

  for (std::size_t r = 0; r < store.variants.size(); ++r) {
    const StoredDesign& d = store.variants[r];
    char rung[64];
    std::snprintf(rung, sizeof rung, "%.2f", d.requested_volume_fraction);

    std::printf("=====================================================================\n");
    std::printf("RUNG %s   (achieved vf %.4f, accepted %d)\n", rung,
                d.achieved_volume_fraction, d.accepted ? 1 : 0);
    std::printf("=====================================================================\n");

    // ── S2.b(1) the field itself ────────────────────────────────────────────
    std::vector<char> boundary(d.density.size(), 0);
    std::size_t solid = 0;
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          const std::size_t s = grid.index(i, j, k);
          const bool in = d.density[s] > kIso;
          if (in) ++solid;
          const int off[6][3] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
          for (const auto& o : off) {
            const int a = i + o[0], b = j + o[1], c = k + o[2];
            const bool nin =
                (a < 0 || b < 0 || c < 0 || a >= grid.nx || b >= grid.ny ||
                 c >= grid.nz)
                    ? false  // out of grid reads background 0.0, as MC does
                    : d.density[grid.index(a, b, c)] > kIso;
            if (nin != in) { boundary[s] = 1; break; }
          }
        }
    std::size_t nb = 0;
    for (const char c : boundary) if (c) ++nb;

    std::printf("\n-- S2.b(1) THE FIELD ------------------------------------------------\n");
    std::printf("  solid voxels (rho > 0.5): %zu of %zu (%.2f%%)\n", solid,
                d.density.size(), 100.0 * solid / d.density.size());
    std::printf("  BOUNDARY voxels (a 6-neighbour on the other side of iso): %zu (%.2f%%)\n",
                nb, 100.0 * nb / d.density.size());
    const Histogram hall = histogram(d.density, {}, band_lo, band_hi);
    const Histogram hbnd = histogram(d.density, boundary, band_lo, band_hi);
    print_histogram("whole grid", hall);
    print_histogram("BOUNDARY voxels only  <- the brief's reading", hbnd);

    // ── S2.b(2) the crossing statistic ──────────────────────────────────────
    const std::vector<double> fine =
        resample_field(grid.nx, grid.ny, grid.nz, d.density, kShippedFactor,
                       ResampleInterp::Tricubic);
    Lattice Lc{grid.nx, grid.ny, grid.nz, grid.spacing, grid.origin, &d.density};
    Lattice Lf{grid.nx * kShippedFactor, grid.ny * kShippedFactor,
               grid.nz * kShippedFactor, cell_mm, grid.origin, &fine};

    Crossings cc, cf;
    collect_crossings(Lc, cc, nullptr, nullptr, nullptr);
    collect_crossings(Lf, cf, nullptr, nullptr, nullptr);
    // The cut split needs the classifier's tolerance, which costs a distance
    // query per crossing — run it as a second pass so the cheap reading above is
    // never hostage to it.
    Crossings cf2, cf_cad;
    collect_crossings(Lf, cf2, &cf_cad, &is_cad_point, &cadctx);

    std::printf("\n-- ★ S2.b(2) THE DECIDING READING: WHERE MARCHING CUBES PUT THE POINT --\n");
    std::printf("  A binary field gives frac == 0.5 on EVERY crossing — every vertex at an\n");
    std::printf("  edge midpoint, which IS a staircase. The spread of frac is the sub-voxel\n");
    std::printf("  information the field still carries.\n\n");
    print_crossings("on the DESIGN lattice (spacing 1.705 mm)", cc, grid.spacing);
    std::printf("\n");
    print_crossings("on the SHIPPED lattice (tricubic factor 2, cell 0.853 mm)", cf,
                    cell_mm);

    std::printf("\n-- S2.b(3) THE SAME, SPLIT BY POPULATION ---------------------------\n");
    std::printf("  NOTE: a lattice CROSSING is not a mesh vertex, so PR 307's\n");
    std::printf("  classifier cannot be called on it. This split uses the classifier's\n");
    std::printf("  own tolerance against the CAD tessellation and NOT its analytic\n");
    std::printf("  distance test, so it is an approximation. The decisive readings\n");
    std::printf("  above are whole-population and do not depend on it.\n");
    std::printf("  CAD-side crossings (within %.4f mm of a CAD face): %zu of %zu (%.2f%%)\n",
                copts.tolerance_mm, cf_cad.n, cf2.n,
                cf2.n ? 100.0 * cf_cad.n / cf2.n : 0.0);
    std::printf("      rms |frac-0.5| = %.5f => %.4f mm\n", cf_cad.rms_offset,
                cf_cad.rms_offset_mm);
    std::printf("  OPTIMIZER-CUT crossings (the rest): %zu\n", cf2.n - cf_cad.n);
    {
      // The cut reading is the complement, recovered from the two sums rather
      // than measured a third time.
      const double s2all = cf2.rms_offset * cf2.rms_offset * static_cast<double>(cf2.n);
      const double s2cad = cf_cad.rms_offset * cf_cad.rms_offset * static_cast<double>(cf_cad.n);
      const std::size_t ncut = cf2.n - cf_cad.n;
      const double rms_cut = ncut ? std::sqrt(std::fmax(0.0, s2all - s2cad) /
                                              static_cast<double>(ncut))
                                  : 0.0;
      std::printf("      rms |frac-0.5| = %.5f => %.4f mm   (staircase %.4f mm)\n",
                  rms_cut, rms_cut * cell_mm, kStaircaseRmsMm);
      csv << rung << "," << d.density.size() << "," << solid << "," << nb << ","
          << hbnd.strictly_between << ","
          << (hbnd.n ? 100.0 * hbnd.strictly_between / hbnd.n : 0.0) << ","
          << cc.n << "," << cc.mean << "," << cc.rms_offset << ","
          << cc.rms_offset_mm << ","
          << (cc.n ? 100.0 * cc.within_1pct / cc.n : 0.0) << ","
          << (cc.n ? 100.0 * cc.beyond_10pct / cc.n : 0.0) << ","
          << cf.n << "," << cf.mean << "," << cf.rms_offset << ","
          << cf.rms_offset_mm << ","
          << (cf.n ? 100.0 * cf.within_1pct / cf.n : 0.0) << ","
          << (cf.n ? 100.0 * cf.beyond_10pct / cf.n : 0.0) << "," << ncut << ","
          << rms_cut * cell_mm << "\n";
    }
    std::printf("\n");
    std::fflush(stdout);
  }

  // ── S2.d — THE FIT, ON ONE RUNG ────────────────────────────────────────────
  //
  // Run unconditionally and reported next to its own positive control, so the
  // "if the field carries something" branch of the brief is answered with a
  // measurement rather than with the decision not to take it.
  {
    const StoredDesign& d = store.variants[0];
    char rung[64];
    std::snprintf(rung, sizeof rung, "%.2f", d.requested_volume_fraction);
    std::printf("=====================================================================\n");
    std::printf("S2.d — A VERTEX-POSITION OPTIMISATION AGAINST THE FIELD, RUNG %s\n", rung);
    std::printf("=====================================================================\n");

    const TriangleMesh subject = extract(grid, d.density, kShippedFactor);
    const std::vector<double> fine =
        resample_field(grid.nx, grid.ny, grid.nz, d.density, kShippedFactor,
                       ResampleInterp::Tricubic);
    Lattice Lf{grid.nx * kShippedFactor, grid.ny * kShippedFactor,
               grid.nz * kShippedFactor, cell_mm, grid.origin, &fine};

    const CadAttribution att = attribute_to_cad_faces(subject, model, copts);
    const Population pop = split(att, subject.vertices.size());
    std::vector<char> frozen(subject.vertices.size(), 0);
    for (std::size_t v = 0; v < subject.vertices.size(); ++v)
      if (pop.cad[v] || att.ambiguous_at(v)) frozen[v] = 1;

    const double vol0 = std::fabs(signed_volume(subject));
    const double dih0 = dihedral_rms_deg(subject);
    const Deviation cad0 = deviation_from_cad(subject, cad_ref, pop.cad);
    const SliceSection sec0 = min_slice_section_of(subject, grid);

    std::printf("  %zu vertices, CAD %zu / ambiguous %zu / CUT %zu\n",
                subject.vertices.size(), pop.n_cad, pop.n_ambiguous, pop.n_cut);
    std::printf("  as exported: dihedral %.2f deg, CAD dev rms %.4f mm,"
                " volume %.0f mm3, min section %.4f mm2\n\n",
                dih0, cad0.rms_mm, vol0, sec0.min_area_mm2);

    std::printf("operator                     iters  wall_s  cutmax  cutrms  cadmoved"
                "  dihed_a  cad_rm%%    vol%%  resid_rms_mm  minsec\n");

    struct Arm { const char* label; int iters; double fair; double fw; };
    const Arm arms[] = {
        {"Fit_field_i20", 20, 0.5, 1.0},
        {"Fit_field_i50", 50, 0.5, 1.0},
        {"Fit_field_i200", 200, 0.5, 1.0},
        {"Fair_only_i20  (control)", 20, 0.5, 0.0},
        {"Fair_only_i50  (control)", 50, 0.5, 0.0},
        {"Fair_only_i200 (control)", 200, 0.5, 0.0},
    };
    for (const Arm& a : arms) {
      FitParams fp;
      fp.iterations = a.iters;
      fp.fair = a.fair;
      fp.field_weight = a.fw;
      fp.trust_mm = 0.5 * cell_mm;
      FitStats st;
      const TriangleMesh out = field_fit(subject, Lf, fp, frozen, st);
      const Motion cm = motion(subject, out, pop.cut);
      const double vol1 = std::fabs(signed_volume(out));
      const Deviation cad1 = deviation_from_cad(out, cad_ref, pop.cad);
      const SliceSection sec1 = min_slice_section_of(out, grid);
      std::printf("%-26s %6d  %6.3f  %6.4f  %6.4f  %8zu  %7.2f  %6.1f%%  %6.3f"
                  "  %12.5f  %8.4f\n",
                  a.label, a.iters, st.wall_s, cm.max_mm, cm.rms_mm,
                  cad_vertices_that_moved(subject, out, pop.cad),
                  dihedral_rms_deg(out),
                  cad0.rms_mm > 0.0 ? 100.0 * (1.0 - cad1.rms_mm / cad0.rms_mm) : 0.0,
                  100.0 * (vol1 - vol0) / vol0, st.rms_residual_after,
                  sec1.min_area_mm2);
    }
    std::printf("\n  level-set residual of the SHIPPED surface, before anything runs:"
                " rms %.6f mm\n",
                [&] {
                  FitParams fp;
                  fp.iterations = 0;
                  fp.trust_mm = 0.5 * cell_mm;
                  FitStats st;
                  field_fit(subject, Lf, fp, frozen, st);
                  return st.rms_residual_before;
                }());
    std::printf("  (a surface already ON the level set has nothing for a projection to\n"
                "   recover — that number is the size of the opportunity.)\n\n");

    // ── C4 OFF: THE ONLY SURFACE WITH A CORRECT ANSWER ──────────────────────
    //
    // With C4 armed the CAD population cannot move, so `cad_rm%` above reads 0.0%
    // by construction. PR 314 §S2.3's unfrozen arm is where "how much stair-step
    // amplitude did this remove" is a truthful question, and it is asked here with
    // PR 299's metric unchanged.
    std::printf("\n  -- C4 OFF: amplitude removed on the surface that HAS an answer --\n");
    std::printf("  as exported: cad_rms %.4f mm\n", cad0.rms_mm);
    std::printf("operator                     iters  wall_s   cad_rms_mm  removed%%"
                "   resid_rms_mm    vol%%\n");
    {
      const std::vector<char> nofreeze(subject.vertices.size(), 0);
      for (const Arm& a : arms) {
        FitParams fp;
        fp.iterations = a.iters;
        fp.fair = a.fair;
        fp.field_weight = a.fw;
        fp.trust_mm = 0.5 * cell_mm;
        FitStats st;
        const TriangleMesh out = field_fit(subject, Lf, fp, nofreeze, st);
        const Deviation da = deviation_from_cad(out, cad_ref, pop.cad);
        const double vol1 = std::fabs(signed_volume(out));
        std::printf("%-26s %6d  %6.3f    %8.4f   %6.1f%%   %12.5f  %6.3f\n",
                    a.label, a.iters, st.wall_s, da.rms_mm,
                    100.0 * (1.0 - da.rms_mm / cad0.rms_mm), st.rms_residual_after,
                    100.0 * (vol1 - vol0) / vol0);
      }
      for (const int pairs : {20, 160}) {
        TaubinParams tp;
        tp.pairs = pairs;
        SmoothConstraints tc;
        tc.enforce_min_feature = false;
        const Clock::time_point t0 = Clock::now();
        const SmoothResult sr = constrained_taubin_smooth(subject, tp, tc);
        const double w = secs_since(t0);
        const Deviation da = deviation_from_cad(sr.mesh, cad_ref, pop.cad);
        const double vol1 = std::fabs(signed_volume(sr.mesh));
        std::printf("Taubin_pairs_%-13d %6d  %6.3f    %8.4f   %6.1f%%   %12s  %6.3f\n",
                    pairs, sr.stats.applied_pairs, w, da.rms_mm,
                    100.0 * (1.0 - da.rms_mm / cad0.rms_mm), "-",
                    100.0 * (vol1 - vol0) / vol0);
      }
    }
    std::printf("\n");

    // Taubin at the same freeze, so the rows are comparable with PR 314's.
    for (const int pairs : {20, 160}) {
      TaubinParams tp;
      tp.pairs = pairs;
      SmoothConstraints tc;
      tc.enforce_min_feature = false;
      tc.vertex_weight.assign(subject.vertices.size(), 1.0);
      for (std::size_t v = 0; v < subject.vertices.size(); ++v)
        if (frozen[v]) tc.vertex_weight[v] = 0.0;
      const Clock::time_point t0 = Clock::now();
      const SmoothResult sr = constrained_taubin_smooth(subject, tp, tc);
      const double w = secs_since(t0);
      const Motion cm = motion(subject, sr.mesh, pop.cut);
      const double vol1 = std::fabs(signed_volume(sr.mesh));
      const Deviation cad1 = deviation_from_cad(sr.mesh, cad_ref, pop.cad);
      std::printf("Taubin_pairs_%-13d %6d  %6.3f  %6.4f  %6.4f  %8zu  %7.2f"
                  "  %6.1f%%  %6.3f  %12s  %8.4f\n",
                  pairs, sr.stats.applied_pairs, w, cm.max_mm, cm.rms_mm,
                  cad_vertices_that_moved(subject, sr.mesh, pop.cad),
                  dihedral_rms_deg(sr.mesh),
                  cad0.rms_mm > 0.0 ? 100.0 * (1.0 - cad1.rms_mm / cad0.rms_mm) : 0.0,
                  100.0 * (vol1 - vol0) / vol0, "-",
                  min_slice_section_of(sr.mesh, grid).min_area_mm2);
    }
  }
  std::printf("\n");
  return 0;
}
