// flexible_lattice.cpp — the Flexible lattice's C++ copy and its streaming STL exporter
// (task 2026-09-29-flexible-screens). See FlexibleLattice.hpp.
//
// ★ THE FIELD IS DEFINED IN SWIFT (FlexibleLatticeField.swift) and ported here line for
// line: same float math, same trilinear rule and clamps, same order of operations.
// FlexibleLatticeExportTests evaluates both at the same points; a change to one without
// the other fails there.
//
// ★ THE EXPORTER STREAMS. Two sample layers live in memory (the octet writer's rule,
// 03-generators §7), triangles go straight into a 1 MiB write buffer and on to the
// file, and the triangle count is patched into the header at the end. There is NO
// vertex cache: an edge's vertex is computed from its two corner samples only, in one
// canonical direction, so the two (or four) cubes that share an edge — in the same
// slab or across slabs — compute it BIT-IDENTICALLY, and an exact-coordinate weld
// of the file closes every edge.

#include "FlexibleLattice.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>
#if defined(__APPLE__)
#include <simd/simd.h>
#endif

#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#endif

// ★ NO FUSED MULTIPLY-ADD. Swift never contracts `a * b + c` into an fma; clang may,
// within an expression, by default. The Swift reference is the definition, so this copy
// rounds every product on its own exactly as Swift does.
#if defined(__clang__)
#pragma clang fp contract(off)
#endif

namespace topoptbridge {

FlexFloats flex_floats_from(const float* values, std::size_t n) {
  if (values == nullptr || n == 0) return {};
  return FlexFloats(values, values + n);
}

namespace {

// ── THE FIELD (FlexibleLatticeField.swift) ────────────────────────────────────────────

inline float grid_at(const FlexScalarGrid& g, int i, int j, int k) {
  return g.values[(static_cast<std::size_t>(k) * static_cast<std::size_t>(g.ny) +
                   static_cast<std::size_t>(j)) *
                      static_cast<std::size_t>(g.nx) +
                  static_cast<std::size_t>(i)];
}

// Swift's `Swift.min` / `Swift.max` on Float, for identical tie and NaN behaviour.
inline float smin(float x, float y) { return y < x ? y : x; }
inline float smax(float x, float y) { return y >= x ? y : x; }

// The continuous index clamped to [0, n−1]. (Swift traps on a NaN here; C++ would be
// undefined, so a NaN reads voxel 0.)
inline float clamp_index(float u, int n) {
  float c = smin(smax(u, 0.0f), static_cast<float>(n - 1));
  return c >= 0.0f ? c : 0.0f;
}

// FlexGrid.sample, line for line.
float sample(const FlexScalarGrid& g, float px, float py, float pz) {
  const float ux = clamp_index((px - g.c0[0]) / g.spacing, g.nx);
  const float uy = clamp_index((py - g.c0[1]) / g.spacing, g.ny);
  const float uz = clamp_index((pz - g.c0[2]) / g.spacing, g.nz);
  const int i0 = std::min(static_cast<int>(ux), std::max(0, g.nx - 2));
  const int j0 = std::min(static_cast<int>(uy), std::max(0, g.ny - 2));
  const int k0 = std::min(static_cast<int>(uz), std::max(0, g.nz - 2));
  const int i1 = std::min(i0 + 1, g.nx - 1), j1 = std::min(j0 + 1, g.ny - 1);
  const int k1 = std::min(k0 + 1, g.nz - 1);
  const float fx = ux - static_cast<float>(i0), fy = uy - static_cast<float>(j0),
              fz = uz - static_cast<float>(k0);
  const float c00 = grid_at(g, i0, j0, k0) * (1 - fx) + grid_at(g, i1, j0, k0) * fx;
  const float c10 = grid_at(g, i0, j1, k0) * (1 - fx) + grid_at(g, i1, j1, k0) * fx;
  const float c01 = grid_at(g, i0, j0, k1) * (1 - fx) + grid_at(g, i1, j0, k1) * fx;
  const float c11 = grid_at(g, i0, j1, k1) * (1 - fx) + grid_at(g, i1, j1, k1) * fx;
  const float c0v = c00 * (1 - fy) + c10 * fy, c1v = c01 * (1 - fy) + c11 * fy;
  return c0v * (1 - fz) + c1v * fz;
}

// `x − y·floor(x/y)` — FlexibleLatticeField.fmod (NOT std::fmod, which truncates).
inline float flx_mod(float x, float y) { return x - y * std::floor(x / y); }

// FlexibleLatticeField.wall.
float wall(const FlexLatticeGrids& f, float px, float py, float pz) {
  const float t = f.wall_mm;
  if (f.topology == 0) {  // gyroid
    const float rho = smin(smax(sample(f.rho, px, py, pz), 0.05f), 0.9f);
    const float L = smin(smax(3.0915f * t / rho, f.l_min_mm), f.l_max_mm);
    // ★ Swift's Float.pi is π rounded TOWARD ZERO (0x40490FDA); (float)M_PI rounds to
    // nearest (…FDB). One ulp in k moved 8 968 of 20 000 graded samples by up to 2.3 µm
    // (exporter verifier, 2026-09-29), so the constant is Swift's, spelled out.
    const float k = 2 * 0x1.921fb4p1f / L;
    const float qx = px * k, qy = py * k, qz = pz * k;
    const float sx = std::sin(qx), sy = std::sin(qy), sz = std::sin(qz);
    const float cx = std::cos(qx), cy = std::cos(qy), cz = std::cos(qz);
    const float g = sx * cy + sy * cz + sz * cx;
    const float gx = k * (cx * cy - sz * sx), gy = k * (cy * cz - sx * sy),
                gz = k * (cz * cx - sy * sz);
    const float glen = std::sqrt(gx * gx + gy * gy + gz * gz);
    return std::fabs(g) / smax(glen, 0.05f * k) - 0.5f * t;
  }
  // honeycomb
  // ★ Swift normalises with simd_normalize (simd_precise_rsqrt), which can round
  // differently from 1/sqrt on a tilted build direction; on Apple the port uses the same
  // call so the two are bit-identical (exporter verifier, 2026-09-29).
#if defined(__APPLE__)
  const simd_float3 bn = simd_normalize(simd_make_float3(f.build_dir[0], f.build_dir[1], f.build_dir[2]));
  const float bx = bn.x, by = bn.y, bz = bn.z;
#else
  const float bl = std::sqrt(f.build_dir[0] * f.build_dir[0] + f.build_dir[1] * f.build_dir[1] +
                             f.build_dir[2] * f.build_dir[2]);
  const float bs = 1.0f / bl;
  const float bx = f.build_dir[0] * bs, by = f.build_dir[1] * bs, bz = f.build_dir[2] * bs;
#endif
  const bool use_x = std::fabs(bx) < 0.9f;
  const float rx = use_x ? 1.0f : 0.0f, ry = use_x ? 0.0f : 1.0f, rz = 0.0f;
  // e1 = normalize(b × ref), e2 = b × e1
  float e1x = by * rz - bz * ry, e1y = bz * rx - bx * rz, e1z = bx * ry - by * rx;
#if defined(__APPLE__)
  {
    const simd_float3 e1 = simd_normalize(simd_make_float3(e1x, e1y, e1z));
    e1x = e1.x;
    e1y = e1.y;
    e1z = e1.z;
  }
#else
  const float e1s = 1.0f / std::sqrt(e1x * e1x + e1y * e1y + e1z * e1z);
  e1x *= e1s;
  e1y *= e1s;
  e1z *= e1s;
#endif
  const float e2x = by * e1z - bz * e1y, e2y = bz * e1x - bx * e1z, e2z = bx * e1y - by * e1x;
  const float vx = px * e1x + py * e1y + pz * e1z;
  const float vy = px * e2x + py * e2y + pz * e2z;
  const float d = f.honeycomb_cell_mm;
  const float rrx = d, rry = 1.7320508f * d;
  const float hx = rrx * 0.5f, hy = rry * 0.5f;
  const float ax = flx_mod(vx, rrx) - hx, ay = flx_mod(vy, rry) - hy;
  const float bbx = flx_mod(vx - hx, rrx) - hx, bby = flx_mod(vy - hy, rry) - hy;
  const bool pick_a = (ax * ax + ay * ay) < (bbx * bbx + bby * bby);
  const float qx = pick_a ? ax : bbx, qy = pick_a ? ay : bby;
  const float n = smax(std::fabs(qx), smax(std::fabs(0.5f * qx + 0.8660254f * qy),
                                           std::fabs(-0.5f * qx + 0.8660254f * qy)));
  return std::fabs(0.5f * d - n) - 0.5f * t;
}

inline float d_region(const FlexLatticeGrids& f, float x, float y, float z) {
  return (0.5f - sample(f.mask, x, y, z)) * 2 * f.mask.spacing;
}
inline float d_skin(const FlexLatticeGrids& f, float x, float y, float z) {
  return f.skin_mm - sample(f.skin_dist, x, y, z);
}

// .lattice with the three shared terms passed in (so .solid samples each grid once).
inline float lattice_from(const FlexLatticeGrids& f, float x, float y, float z, float region,
                          float part, float skin) {
  return smax(smax(wall(f, x, y, z), region), smax(part, skin));
}

std::string grid_error(const FlexScalarGrid& g, const char* name) {
  if (g.nx < 1 || g.ny < 1 || g.nz < 1) return std::string(name) + " grid is empty";
  if (!(g.spacing > 0.0f) || !std::isfinite(g.spacing))
    return std::string(name) + " grid spacing must be > 0";
  if (!std::isfinite(g.c0[0]) || !std::isfinite(g.c0[1]) || !std::isfinite(g.c0[2]))
    return std::string(name) + " grid origin is not finite";
  const std::size_t n = static_cast<std::size_t>(g.nx) * static_cast<std::size_t>(g.ny) *
                        static_cast<std::size_t>(g.nz);
  if (g.values.size() != n)
    return std::string(name) + " grid holds " + std::to_string(g.values.size()) +
           " values, not nx·ny·nz = " + std::to_string(n);
  return "";
}

}  // namespace

std::string flexible_lattice_grids_error(const FlexLatticeGrids& f) {
  if (f.topology != 0 && f.topology != 1) return "topology must be 0 (gyroid) or 1 (honeycomb)";
  if (!(f.wall_mm > 0.0f) || !std::isfinite(f.wall_mm)) return "wall thickness must be > 0";
  if (f.topology == 0 && !(f.l_min_mm > 0.0f && f.l_max_mm >= f.l_min_mm))
    return "gyroid cell clamp must satisfy 0 < l_min <= l_max";
  if (f.topology == 1) {
    if (!(f.honeycomb_cell_mm > 0.0f) || !std::isfinite(f.honeycomb_cell_mm))
      return "honeycomb cell must be > 0";
    const float b2 = f.build_dir[0] * f.build_dir[0] + f.build_dir[1] * f.build_dir[1] +
                     f.build_dir[2] * f.build_dir[2];
    if (!(b2 > 0.0f) || !std::isfinite(b2)) return "build direction must be non-zero";
  }
  for (const auto& [g, name] : {std::make_pair(&f.rho, "rho"), std::make_pair(&f.mask, "mask"),
                                std::make_pair(&f.part_sdf, "part SDF"),
                                std::make_pair(&f.skin_dist, "skin distance")}) {
    std::string e = grid_error(*g, name);
    if (!e.empty()) return e;
  }
  for (int a = 0; a < 3; ++a)
    if (!std::isfinite(f.bounds_min[a]) || !std::isfinite(f.bounds_max[a]) ||
        f.bounds_max[a] < f.bounds_min[a])
      return "part bounds are empty or not finite";
  return "";
}

float flx_field_lattice(const FlexLatticeGrids& f, float x, float y, float z) {
  return lattice_from(f, x, y, z, d_region(f, x, y, z), sample(f.part_sdf, x, y, z),
                      d_skin(f, x, y, z));
}

float flx_field_solid(const FlexLatticeGrids& f, float x, float y, float z) {
  const float region = d_region(f, x, y, z), skin = d_skin(f, x, y, z);
  const float part = sample(f.part_sdf, x, y, z);
  // ≤ 0 where the lattice may be: in the region AND deeper than the skin (MAX — see the
  // ★ note on EXPORT in FlexibleLatticeField.swift; min made every skin air).
  const float open = smax(region, skin);
  return smin(smax(part, -open), lattice_from(f, x, y, z, region, part, skin));
}

std::vector<float> flexible_lattice_field_values(const FlexLatticeGrids& f,
                                                 const std::vector<float>& xyz, int32_t which) {
  if (!flexible_lattice_grids_error(f).empty()) return {};
  std::vector<float> out(xyz.size() / 3);
  for (std::size_t p = 0; p < out.size(); ++p) {
    const float x = xyz[3 * p], y = xyz[3 * p + 1], z = xyz[3 * p + 2];
    out[p] = which == 1 ? flx_field_solid(f, x, y, z) : flx_field_lattice(f, x, y, z);
  }
  return out;
}

// ── MARCHING CUBES ───────────────────────────────────────────────────────────────────
namespace {

// Corners in the Lorensen–Cline numbering (core/src/mesh/mesh.cpp's kCorner): bottom
// face (z = 0) 0..3 counter-clockwise, top face 4..7.
constexpr int kCorner[8][3] = {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0},
                               {0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}};

// The twelve edges, each written LOWER CORNER FIRST (core's kEdge has 2→3, 6→7, 3→0
// and 7→4, which run toward −x / −y). ★ The canonical direction is what makes a shared
// edge's vertex bit-identical in every cube that meets it: t is always measured from
// the lower grid point.
constexpr int kEdgeLow[12][2] = {{0, 1}, {1, 2}, {3, 2}, {0, 3}, {4, 5}, {5, 6},
                                 {7, 6}, {4, 7}, {0, 4}, {1, 5}, {2, 6}, {3, 7}};

// The classic Lorensen/Bourke triangle table, copied verbatim from core's
// core/src/mesh/mesh.cpp (kTriTable). Bit c of the case is set iff corner c is INSIDE
// (field < 0 here; field > iso in core). As core documents (the 2026-08-09 winding
// fix), the table's own order winds INTO the inside, so every triangle is emitted
// (e0, e2, e1): normal toward increasing field, i.e. outward.
constexpr int kTriTable[256][16] = {
    {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {0, 8, 3, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {0, 1, 9, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {1, 8, 3, 9, 8, 1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {1, 2, 10, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {0, 8, 3, 1, 2, 10, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {9, 2, 10, 0, 2, 9, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {2, 8, 3, 2, 10, 8, 10, 9, 8, -1, -1, -1, -1, -1, -1, -1},
    {3, 11, 2, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {0, 11, 2, 8, 11, 0, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {1, 9, 0, 2, 3, 11, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {1, 11, 2, 1, 9, 11, 9, 8, 11, -1, -1, -1, -1, -1, -1, -1},
    {3, 10, 1, 11, 10, 3, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {0, 10, 1, 0, 8, 10, 8, 11, 10, -1, -1, -1, -1, -1, -1, -1},
    {3, 9, 0, 3, 11, 9, 11, 10, 9, -1, -1, -1, -1, -1, -1, -1},
    {9, 8, 10, 10, 8, 11, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {4, 7, 8, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {4, 3, 0, 7, 3, 4, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {0, 1, 9, 8, 4, 7, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {4, 1, 9, 4, 7, 1, 7, 3, 1, -1, -1, -1, -1, -1, -1, -1},
    {1, 2, 10, 8, 4, 7, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {3, 4, 7, 3, 0, 4, 1, 2, 10, -1, -1, -1, -1, -1, -1, -1},
    {9, 2, 10, 9, 0, 2, 8, 4, 7, -1, -1, -1, -1, -1, -1, -1},
    {2, 10, 9, 2, 9, 7, 2, 7, 3, 7, 9, 4, -1, -1, -1, -1},
    {8, 4, 7, 3, 11, 2, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {11, 4, 7, 11, 2, 4, 2, 0, 4, -1, -1, -1, -1, -1, -1, -1},
    {9, 0, 1, 8, 4, 7, 2, 3, 11, -1, -1, -1, -1, -1, -1, -1},
    {4, 7, 11, 9, 4, 11, 9, 11, 2, 9, 2, 1, -1, -1, -1, -1},
    {3, 10, 1, 3, 11, 10, 7, 8, 4, -1, -1, -1, -1, -1, -1, -1},
    {1, 11, 10, 1, 4, 11, 1, 0, 4, 7, 11, 4, -1, -1, -1, -1},
    {4, 7, 8, 9, 0, 11, 9, 11, 10, 11, 0, 3, -1, -1, -1, -1},
    {4, 7, 11, 4, 11, 9, 9, 11, 10, -1, -1, -1, -1, -1, -1, -1},
    {9, 5, 4, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {9, 5, 4, 0, 8, 3, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {0, 5, 4, 1, 5, 0, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {8, 5, 4, 8, 3, 5, 3, 1, 5, -1, -1, -1, -1, -1, -1, -1},
    {1, 2, 10, 9, 5, 4, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {3, 0, 8, 1, 2, 10, 4, 9, 5, -1, -1, -1, -1, -1, -1, -1},
    {5, 2, 10, 5, 4, 2, 4, 0, 2, -1, -1, -1, -1, -1, -1, -1},
    {2, 10, 5, 3, 2, 5, 3, 5, 4, 3, 4, 8, -1, -1, -1, -1},
    {9, 5, 4, 2, 3, 11, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {0, 11, 2, 0, 8, 11, 4, 9, 5, -1, -1, -1, -1, -1, -1, -1},
    {0, 5, 4, 0, 1, 5, 2, 3, 11, -1, -1, -1, -1, -1, -1, -1},
    {2, 1, 5, 2, 5, 8, 2, 8, 11, 4, 8, 5, -1, -1, -1, -1},
    {10, 3, 11, 10, 1, 3, 9, 5, 4, -1, -1, -1, -1, -1, -1, -1},
    {4, 9, 5, 0, 8, 1, 8, 10, 1, 8, 11, 10, -1, -1, -1, -1},
    {5, 4, 0, 5, 0, 11, 5, 11, 10, 11, 0, 3, -1, -1, -1, -1},
    {5, 4, 8, 5, 8, 10, 10, 8, 11, -1, -1, -1, -1, -1, -1, -1},
    {9, 7, 8, 5, 7, 9, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {9, 3, 0, 9, 5, 3, 5, 7, 3, -1, -1, -1, -1, -1, -1, -1},
    {0, 7, 8, 0, 1, 7, 1, 5, 7, -1, -1, -1, -1, -1, -1, -1},
    {1, 5, 3, 3, 5, 7, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {9, 7, 8, 9, 5, 7, 10, 1, 2, -1, -1, -1, -1, -1, -1, -1},
    {10, 1, 2, 9, 5, 0, 5, 3, 0, 5, 7, 3, -1, -1, -1, -1},
    {8, 0, 2, 8, 2, 5, 8, 5, 7, 10, 5, 2, -1, -1, -1, -1},
    {2, 10, 5, 2, 5, 3, 3, 5, 7, -1, -1, -1, -1, -1, -1, -1},
    {7, 9, 5, 7, 8, 9, 3, 11, 2, -1, -1, -1, -1, -1, -1, -1},
    {9, 5, 7, 9, 7, 2, 9, 2, 0, 2, 7, 11, -1, -1, -1, -1},
    {2, 3, 11, 0, 1, 8, 1, 7, 8, 1, 5, 7, -1, -1, -1, -1},
    {11, 2, 1, 11, 1, 7, 7, 1, 5, -1, -1, -1, -1, -1, -1, -1},
    {9, 5, 8, 8, 5, 7, 10, 1, 3, 10, 3, 11, -1, -1, -1, -1},
    {5, 7, 0, 5, 0, 9, 7, 11, 0, 1, 0, 10, 11, 10, 0, -1},
    {11, 10, 0, 11, 0, 3, 10, 5, 0, 8, 0, 7, 5, 7, 0, -1},
    {11, 10, 5, 7, 11, 5, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {10, 6, 5, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {0, 8, 3, 5, 10, 6, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {9, 0, 1, 5, 10, 6, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {1, 8, 3, 1, 9, 8, 5, 10, 6, -1, -1, -1, -1, -1, -1, -1},
    {1, 6, 5, 2, 6, 1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {1, 6, 5, 1, 2, 6, 3, 0, 8, -1, -1, -1, -1, -1, -1, -1},
    {9, 6, 5, 9, 0, 6, 0, 2, 6, -1, -1, -1, -1, -1, -1, -1},
    {5, 9, 8, 5, 8, 2, 5, 2, 6, 3, 2, 8, -1, -1, -1, -1},
    {2, 3, 11, 10, 6, 5, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {11, 0, 8, 11, 2, 0, 10, 6, 5, -1, -1, -1, -1, -1, -1, -1},
    {0, 1, 9, 2, 3, 11, 5, 10, 6, -1, -1, -1, -1, -1, -1, -1},
    {5, 10, 6, 1, 9, 2, 9, 11, 2, 9, 8, 11, -1, -1, -1, -1},
    {6, 3, 11, 6, 5, 3, 5, 1, 3, -1, -1, -1, -1, -1, -1, -1},
    {0, 8, 11, 0, 11, 5, 0, 5, 1, 5, 11, 6, -1, -1, -1, -1},
    {3, 11, 6, 0, 3, 6, 0, 6, 5, 0, 5, 9, -1, -1, -1, -1},
    {6, 5, 9, 6, 9, 11, 11, 9, 8, -1, -1, -1, -1, -1, -1, -1},
    {5, 10, 6, 4, 7, 8, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {4, 3, 0, 4, 7, 3, 6, 5, 10, -1, -1, -1, -1, -1, -1, -1},
    {1, 9, 0, 5, 10, 6, 8, 4, 7, -1, -1, -1, -1, -1, -1, -1},
    {10, 6, 5, 1, 9, 7, 1, 7, 3, 7, 9, 4, -1, -1, -1, -1},
    {6, 1, 2, 6, 5, 1, 4, 7, 8, -1, -1, -1, -1, -1, -1, -1},
    {1, 2, 5, 5, 2, 6, 3, 0, 4, 3, 4, 7, -1, -1, -1, -1},
    {8, 4, 7, 9, 0, 5, 0, 6, 5, 0, 2, 6, -1, -1, -1, -1},
    {7, 3, 9, 7, 9, 4, 3, 2, 9, 5, 9, 6, 2, 6, 9, -1},
    {3, 11, 2, 7, 8, 4, 10, 6, 5, -1, -1, -1, -1, -1, -1, -1},
    {5, 10, 6, 4, 7, 2, 4, 2, 0, 2, 7, 11, -1, -1, -1, -1},
    {0, 1, 9, 4, 7, 8, 2, 3, 11, 5, 10, 6, -1, -1, -1, -1},
    {9, 2, 1, 9, 11, 2, 9, 4, 11, 7, 11, 4, 5, 10, 6, -1},
    {8, 4, 7, 3, 11, 5, 3, 5, 1, 5, 11, 6, -1, -1, -1, -1},
    {5, 1, 11, 5, 11, 6, 1, 0, 11, 7, 11, 4, 0, 4, 11, -1},
    {0, 5, 9, 0, 6, 5, 0, 3, 6, 11, 6, 3, 8, 4, 7, -1},
    {6, 5, 9, 6, 9, 11, 4, 7, 9, 7, 11, 9, -1, -1, -1, -1},
    {10, 4, 9, 6, 4, 10, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {4, 10, 6, 4, 9, 10, 0, 8, 3, -1, -1, -1, -1, -1, -1, -1},
    {10, 0, 1, 10, 6, 0, 6, 4, 0, -1, -1, -1, -1, -1, -1, -1},
    {8, 3, 1, 8, 1, 6, 8, 6, 4, 6, 1, 10, -1, -1, -1, -1},
    {1, 4, 9, 1, 2, 4, 2, 6, 4, -1, -1, -1, -1, -1, -1, -1},
    {3, 0, 8, 1, 2, 9, 2, 4, 9, 2, 6, 4, -1, -1, -1, -1},
    {0, 2, 4, 4, 2, 6, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {8, 3, 2, 8, 2, 4, 4, 2, 6, -1, -1, -1, -1, -1, -1, -1},
    {10, 4, 9, 10, 6, 4, 11, 2, 3, -1, -1, -1, -1, -1, -1, -1},
    {0, 8, 2, 2, 8, 11, 4, 9, 10, 4, 10, 6, -1, -1, -1, -1},
    {3, 11, 2, 0, 1, 6, 0, 6, 4, 6, 1, 10, -1, -1, -1, -1},
    {6, 4, 1, 6, 1, 10, 4, 8, 1, 2, 1, 11, 8, 11, 1, -1},
    {9, 6, 4, 9, 3, 6, 9, 1, 3, 11, 6, 3, -1, -1, -1, -1},
    {8, 11, 1, 8, 1, 0, 11, 6, 1, 9, 1, 4, 6, 4, 1, -1},
    {3, 11, 6, 3, 6, 0, 0, 6, 4, -1, -1, -1, -1, -1, -1, -1},
    {6, 4, 8, 11, 6, 8, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {7, 10, 6, 7, 8, 10, 8, 9, 10, -1, -1, -1, -1, -1, -1, -1},
    {0, 7, 3, 0, 10, 7, 0, 9, 10, 6, 7, 10, -1, -1, -1, -1},
    {10, 6, 7, 1, 10, 7, 1, 7, 8, 1, 8, 0, -1, -1, -1, -1},
    {10, 6, 7, 10, 7, 1, 1, 7, 3, -1, -1, -1, -1, -1, -1, -1},
    {1, 2, 6, 1, 6, 8, 1, 8, 9, 8, 6, 7, -1, -1, -1, -1},
    {2, 6, 9, 2, 9, 1, 6, 7, 9, 0, 9, 3, 7, 3, 9, -1},
    {7, 8, 0, 7, 0, 6, 6, 0, 2, -1, -1, -1, -1, -1, -1, -1},
    {7, 3, 2, 6, 7, 2, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {2, 3, 11, 10, 6, 8, 10, 8, 9, 8, 6, 7, -1, -1, -1, -1},
    {2, 0, 7, 2, 7, 11, 0, 9, 7, 6, 7, 10, 9, 10, 7, -1},
    {1, 8, 0, 1, 7, 8, 1, 10, 7, 6, 7, 10, 2, 3, 11, -1},
    {11, 2, 1, 11, 1, 7, 10, 6, 1, 6, 7, 1, -1, -1, -1, -1},
    {8, 9, 6, 8, 6, 7, 9, 1, 6, 11, 6, 3, 1, 3, 6, -1},
    {0, 9, 1, 11, 6, 7, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {7, 8, 0, 7, 0, 6, 3, 11, 0, 11, 6, 0, -1, -1, -1, -1},
    {7, 11, 6, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {7, 6, 11, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {3, 0, 8, 11, 7, 6, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {0, 1, 9, 11, 7, 6, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {8, 1, 9, 8, 3, 1, 11, 7, 6, -1, -1, -1, -1, -1, -1, -1},
    {10, 1, 2, 6, 11, 7, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {1, 2, 10, 3, 0, 8, 6, 11, 7, -1, -1, -1, -1, -1, -1, -1},
    {2, 9, 0, 2, 10, 9, 6, 11, 7, -1, -1, -1, -1, -1, -1, -1},
    {6, 11, 7, 2, 10, 3, 10, 8, 3, 10, 9, 8, -1, -1, -1, -1},
    {7, 2, 3, 6, 2, 7, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {7, 0, 8, 7, 6, 0, 6, 2, 0, -1, -1, -1, -1, -1, -1, -1},
    {2, 7, 6, 2, 3, 7, 0, 1, 9, -1, -1, -1, -1, -1, -1, -1},
    {1, 6, 2, 1, 8, 6, 1, 9, 8, 8, 7, 6, -1, -1, -1, -1},
    {10, 7, 6, 10, 1, 7, 1, 3, 7, -1, -1, -1, -1, -1, -1, -1},
    {10, 7, 6, 1, 7, 10, 1, 8, 7, 1, 0, 8, -1, -1, -1, -1},
    {0, 3, 7, 0, 7, 10, 0, 10, 9, 6, 10, 7, -1, -1, -1, -1},
    {7, 6, 10, 7, 10, 8, 8, 10, 9, -1, -1, -1, -1, -1, -1, -1},
    {6, 8, 4, 11, 8, 6, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {3, 6, 11, 3, 0, 6, 0, 4, 6, -1, -1, -1, -1, -1, -1, -1},
    {8, 6, 11, 8, 4, 6, 9, 0, 1, -1, -1, -1, -1, -1, -1, -1},
    {9, 4, 6, 9, 6, 3, 9, 3, 1, 11, 3, 6, -1, -1, -1, -1},
    {6, 8, 4, 6, 11, 8, 2, 10, 1, -1, -1, -1, -1, -1, -1, -1},
    {1, 2, 10, 3, 0, 11, 0, 6, 11, 0, 4, 6, -1, -1, -1, -1},
    {4, 11, 8, 4, 6, 11, 0, 2, 9, 2, 10, 9, -1, -1, -1, -1},
    {10, 9, 3, 10, 3, 2, 9, 4, 3, 11, 3, 6, 4, 6, 3, -1},
    {8, 2, 3, 8, 4, 2, 4, 6, 2, -1, -1, -1, -1, -1, -1, -1},
    {0, 4, 2, 4, 6, 2, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {1, 9, 0, 2, 3, 4, 2, 4, 6, 4, 3, 8, -1, -1, -1, -1},
    {1, 9, 4, 1, 4, 2, 2, 4, 6, -1, -1, -1, -1, -1, -1, -1},
    {8, 1, 3, 8, 6, 1, 8, 4, 6, 6, 10, 1, -1, -1, -1, -1},
    {10, 1, 0, 10, 0, 6, 6, 0, 4, -1, -1, -1, -1, -1, -1, -1},
    {4, 6, 3, 4, 3, 8, 6, 10, 3, 0, 3, 9, 10, 9, 3, -1},
    {10, 9, 4, 6, 10, 4, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {4, 9, 5, 7, 6, 11, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {0, 8, 3, 4, 9, 5, 11, 7, 6, -1, -1, -1, -1, -1, -1, -1},
    {5, 0, 1, 5, 4, 0, 7, 6, 11, -1, -1, -1, -1, -1, -1, -1},
    {11, 7, 6, 8, 3, 4, 3, 5, 4, 3, 1, 5, -1, -1, -1, -1},
    {9, 5, 4, 10, 1, 2, 7, 6, 11, -1, -1, -1, -1, -1, -1, -1},
    {6, 11, 7, 1, 2, 10, 0, 8, 3, 4, 9, 5, -1, -1, -1, -1},
    {7, 6, 11, 5, 4, 10, 4, 2, 10, 4, 0, 2, -1, -1, -1, -1},
    {3, 4, 8, 3, 5, 4, 3, 2, 5, 10, 5, 2, 11, 7, 6, -1},
    {7, 2, 3, 7, 6, 2, 5, 4, 9, -1, -1, -1, -1, -1, -1, -1},
    {9, 5, 4, 0, 8, 6, 0, 6, 2, 6, 8, 7, -1, -1, -1, -1},
    {3, 6, 2, 3, 7, 6, 1, 5, 0, 5, 4, 0, -1, -1, -1, -1},
    {6, 2, 8, 6, 8, 7, 2, 1, 8, 4, 8, 5, 1, 5, 8, -1},
    {9, 5, 4, 10, 1, 6, 1, 7, 6, 1, 3, 7, -1, -1, -1, -1},
    {1, 6, 10, 1, 7, 6, 1, 0, 7, 8, 7, 0, 9, 5, 4, -1},
    {4, 0, 10, 4, 10, 5, 0, 3, 10, 6, 10, 7, 3, 7, 10, -1},
    {7, 6, 10, 7, 10, 8, 5, 4, 10, 4, 8, 10, -1, -1, -1, -1},
    {6, 9, 5, 6, 11, 9, 11, 8, 9, -1, -1, -1, -1, -1, -1, -1},
    {3, 6, 11, 0, 6, 3, 0, 5, 6, 0, 9, 5, -1, -1, -1, -1},
    {0, 11, 8, 0, 5, 11, 0, 1, 5, 5, 6, 11, -1, -1, -1, -1},
    {6, 11, 3, 6, 3, 5, 5, 3, 1, -1, -1, -1, -1, -1, -1, -1},
    {1, 2, 10, 9, 5, 11, 9, 11, 8, 11, 5, 6, -1, -1, -1, -1},
    {0, 11, 3, 0, 6, 11, 0, 9, 6, 5, 6, 9, 1, 2, 10, -1},
    {11, 8, 5, 11, 5, 6, 8, 0, 5, 10, 5, 2, 0, 2, 5, -1},
    {6, 11, 3, 6, 3, 5, 2, 10, 3, 10, 5, 3, -1, -1, -1, -1},
    {5, 8, 9, 5, 2, 8, 5, 6, 2, 3, 8, 2, -1, -1, -1, -1},
    {9, 5, 6, 9, 6, 0, 0, 6, 2, -1, -1, -1, -1, -1, -1, -1},
    {1, 5, 8, 1, 8, 0, 5, 6, 8, 3, 8, 2, 6, 2, 8, -1},
    {1, 5, 6, 2, 1, 6, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {1, 3, 6, 1, 6, 10, 3, 8, 6, 5, 6, 9, 8, 9, 6, -1},
    {10, 1, 0, 10, 0, 6, 9, 5, 0, 5, 6, 0, -1, -1, -1, -1},
    {0, 3, 8, 5, 6, 10, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {10, 5, 6, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {11, 5, 10, 7, 5, 11, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {11, 5, 10, 11, 7, 5, 8, 3, 0, -1, -1, -1, -1, -1, -1, -1},
    {5, 11, 7, 5, 10, 11, 1, 9, 0, -1, -1, -1, -1, -1, -1, -1},
    {10, 7, 5, 10, 11, 7, 9, 8, 1, 8, 3, 1, -1, -1, -1, -1},
    {11, 1, 2, 11, 7, 1, 7, 5, 1, -1, -1, -1, -1, -1, -1, -1},
    {0, 8, 3, 1, 2, 7, 1, 7, 5, 7, 2, 11, -1, -1, -1, -1},
    {9, 7, 5, 9, 2, 7, 9, 0, 2, 2, 11, 7, -1, -1, -1, -1},
    {7, 5, 2, 7, 2, 11, 5, 9, 2, 3, 2, 8, 9, 8, 2, -1},
    {2, 5, 10, 2, 3, 5, 3, 7, 5, -1, -1, -1, -1, -1, -1, -1},
    {8, 2, 0, 8, 5, 2, 8, 7, 5, 10, 2, 5, -1, -1, -1, -1},
    {9, 0, 1, 5, 10, 3, 5, 3, 7, 3, 10, 2, -1, -1, -1, -1},
    {9, 8, 2, 9, 2, 1, 8, 7, 2, 10, 2, 5, 7, 5, 2, -1},
    {1, 3, 5, 3, 7, 5, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {0, 8, 7, 0, 7, 1, 1, 7, 5, -1, -1, -1, -1, -1, -1, -1},
    {9, 0, 3, 9, 3, 5, 5, 3, 7, -1, -1, -1, -1, -1, -1, -1},
    {9, 8, 7, 5, 9, 7, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {5, 8, 4, 5, 10, 8, 10, 11, 8, -1, -1, -1, -1, -1, -1, -1},
    {5, 0, 4, 5, 11, 0, 5, 10, 11, 11, 3, 0, -1, -1, -1, -1},
    {0, 1, 9, 8, 4, 10, 8, 10, 11, 10, 4, 5, -1, -1, -1, -1},
    {10, 11, 4, 10, 4, 5, 11, 3, 4, 9, 4, 1, 3, 1, 4, -1},
    {2, 5, 1, 2, 8, 5, 2, 11, 8, 4, 5, 8, -1, -1, -1, -1},
    {0, 4, 11, 0, 11, 3, 4, 5, 11, 2, 11, 1, 5, 1, 11, -1},
    {0, 2, 5, 0, 5, 9, 2, 11, 5, 4, 5, 8, 11, 8, 5, -1},
    {9, 4, 5, 2, 11, 3, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {2, 5, 10, 3, 5, 2, 3, 4, 5, 3, 8, 4, -1, -1, -1, -1},
    {5, 10, 2, 5, 2, 4, 4, 2, 0, -1, -1, -1, -1, -1, -1, -1},
    {3, 10, 2, 3, 5, 10, 3, 8, 5, 4, 5, 8, 0, 1, 9, -1},
    {5, 10, 2, 5, 2, 4, 1, 9, 2, 9, 4, 2, -1, -1, -1, -1},
    {8, 4, 5, 8, 5, 3, 3, 5, 1, -1, -1, -1, -1, -1, -1, -1},
    {0, 4, 5, 1, 0, 5, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {8, 4, 5, 8, 5, 3, 9, 0, 5, 0, 3, 5, -1, -1, -1, -1},
    {9, 4, 5, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {4, 11, 7, 4, 9, 11, 9, 10, 11, -1, -1, -1, -1, -1, -1, -1},
    {0, 8, 3, 4, 9, 7, 9, 11, 7, 9, 10, 11, -1, -1, -1, -1},
    {1, 10, 11, 1, 11, 4, 1, 4, 0, 7, 4, 11, -1, -1, -1, -1},
    {3, 1, 4, 3, 4, 8, 1, 10, 4, 7, 4, 11, 10, 11, 4, -1},
    {4, 11, 7, 9, 11, 4, 9, 2, 11, 9, 1, 2, -1, -1, -1, -1},
    {9, 7, 4, 9, 11, 7, 9, 1, 11, 2, 11, 1, 0, 8, 3, -1},
    {11, 7, 4, 11, 4, 2, 2, 4, 0, -1, -1, -1, -1, -1, -1, -1},
    {11, 7, 4, 11, 4, 2, 8, 3, 4, 3, 2, 4, -1, -1, -1, -1},
    {2, 9, 10, 2, 7, 9, 2, 3, 7, 7, 4, 9, -1, -1, -1, -1},
    {9, 10, 7, 9, 7, 4, 10, 2, 7, 8, 7, 0, 2, 0, 7, -1},
    {3, 7, 10, 3, 10, 2, 7, 4, 10, 1, 10, 0, 4, 0, 10, -1},
    {1, 10, 2, 8, 7, 4, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {4, 9, 1, 4, 1, 7, 7, 1, 3, -1, -1, -1, -1, -1, -1, -1},
    {4, 9, 1, 4, 1, 7, 0, 8, 1, 8, 7, 1, -1, -1, -1, -1},
    {4, 0, 3, 7, 4, 3, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {4, 8, 7, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {9, 10, 8, 10, 11, 8, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {3, 0, 9, 3, 9, 11, 11, 9, 10, -1, -1, -1, -1, -1, -1, -1},
    {0, 1, 10, 0, 10, 8, 8, 10, 11, -1, -1, -1, -1, -1, -1, -1},
    {3, 1, 10, 11, 3, 10, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {1, 2, 11, 1, 11, 9, 9, 11, 8, -1, -1, -1, -1, -1, -1, -1},
    {3, 0, 9, 3, 9, 11, 1, 2, 9, 2, 11, 9, -1, -1, -1, -1},
    {0, 2, 11, 8, 0, 11, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {3, 2, 11, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {2, 3, 8, 2, 8, 10, 10, 8, 9, -1, -1, -1, -1, -1, -1, -1},
    {9, 10, 2, 0, 9, 2, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {2, 3, 8, 2, 8, 10, 0, 1, 8, 1, 10, 8, -1, -1, -1, -1},
    {1, 10, 2, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {1, 3, 8, 9, 1, 8, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {0, 9, 1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {0, 3, 8, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1},
    {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1}};

// The classic EDGE table: bit e set iff edge e's two corners differ (= the edges the
// case's triangles use). Built once from the corners rather than transcribed.
struct EdgeTable {
  int mask[256];
  int tri_count[256];
  EdgeTable() {
    for (int c = 0; c < 256; ++c) {
      int m = 0;
      for (int e = 0; e < 12; ++e) {
        const bool a = (c >> kEdgeLow[e][0]) & 1, b = (c >> kEdgeLow[e][1]) & 1;
        if (a != b) m |= 1 << e;
      }
      mask[c] = m;
      int n = 0;
      while (n < 16 && kTriTable[c][n] != -1) ++n;
      tri_count[c] = n / 3;
    }
  }
};
const EdgeTable& edge_table() {
  static const EdgeTable t;
  return t;
}

// The crossing on an edge from a (lower) to b along one axis, from the two corner
// samples ONLY. ★ Nudged strictly inside the edge: a sample that is exactly 0, or a
// t that rounds to an end, would otherwise put two edges' vertices on the same grid
// point, and the weld would fold a triangle onto itself (a non-manifold edge).
inline float crossing(float pa, float pb, float va, float vb) {
  float t = va / (va - vb);
  t = t < 0.0f ? 0.0f : (t > 1.0f ? 1.0f : t);
  float c = pa + t * (pb - pa);
  if (!(c > pa)) c = std::nextafter(pa, pb);
  if (!(c < pb)) c = std::nextafter(pb, pa);
  return c;
}

inline void put_u32(unsigned char* p, uint32_t v) {
  p[0] = static_cast<unsigned char>(v & 0xFFu);
  p[1] = static_cast<unsigned char>((v >> 8) & 0xFFu);
  p[2] = static_cast<unsigned char>((v >> 16) & 0xFFu);
  p[3] = static_cast<unsigned char>((v >> 24) & 0xFFu);
}
inline void put_f32(unsigned char* p, float f) {
  uint32_t u;
  std::memcpy(&u, &f, 4);
  put_u32(p, u);
}

constexpr char kHeader[] = "TopOpt Flexible lattice (app preview geometry)";
constexpr std::size_t kWriteBuffer = std::size_t(1) << 20;  // 1 MiB
constexpr int64_t kMaxLayerSamples = int64_t(64) << 20;      // 64 M samples = 256 MB a layer

// The sample grid for pitch h: bounds − 2h … bounds + 2h, samples AT the grid points.
struct SampleGrid {
  int32_t n[3] = {0, 0, 0};
  std::vector<float> coord[3];  // model coordinate of sample i on each axis
};

SampleGrid sample_grid(const FlexLatticeGrids& f, double h) {
  if (!(h > 0.0) || !std::isfinite(h)) throw std::invalid_argument("pitch h must be > 0");
  SampleGrid s;
  for (int a = 0; a < 3; ++a) {
    const double lo = static_cast<double>(f.bounds_min[a]) - 2.0 * h;
    const double extent = static_cast<double>(f.bounds_max[a]) - static_cast<double>(f.bounds_min[a]) + 4.0 * h;
    const double cells = std::ceil(extent / h - 1e-9);
    if (!(cells < double(1 << 20)))
      throw std::invalid_argument("pitch h = " + std::to_string(h) + " mm gives over a million samples along one axis");
    s.n[a] = static_cast<int32_t>(cells) + 1;
    s.coord[a].resize(static_cast<std::size_t>(s.n[a]));
    // ★ From the index alone, in double, once: every cube reads the same float for the
    // same grid point, which the bit-identical shared vertices depend on.
    for (int32_t i = 0; i < s.n[a]; ++i)
      s.coord[a][static_cast<std::size_t>(i)] = static_cast<float>(lo + static_cast<double>(i) * h);
  }
  const int64_t layer = int64_t(s.n[0]) * int64_t(s.n[1]);
  if (layer > kMaxLayerSamples)
    throw std::invalid_argument(
        "pitch h = " + std::to_string(h) + " mm gives " + std::to_string(s.n[0]) + " × " +
        std::to_string(s.n[1]) + " samples a layer; the exporter holds two layers and keeps each "
        "under 64 M samples — raise h");
  return s;
}

// The sample at grid index (i, j, k): OUTSIDE (+h) on the outermost layer, so the
// surface always closes, and outside for a non-finite field value.
inline float sample_value(const FlexLatticeGrids& f, const SampleGrid& s, float hv, int i, int j,
                          int k) {
  if (i == 0 || j == 0 || k == 0 || i == s.n[0] - 1 || j == s.n[1] - 1 || k == s.n[2] - 1) return hv;
  const float v = flx_field_solid(f, s.coord[0][static_cast<std::size_t>(i)],
                                  s.coord[1][static_cast<std::size_t>(j)],
                                  s.coord[2][static_cast<std::size_t>(k)]);
  return std::isfinite(v) ? v : hv;
}

// ── the exporter ──
class LatticeExporter {
 public:
  LatticeExporter(const FlexLatticeGrids& grids, double h, const std::string& path)
      : f_(grids), h_(h), hv_(static_cast<float>(h)), path_(path) {
    s_ = sample_grid(f_, h_);
    slab_ = static_cast<std::size_t>(s_.n[0]) * static_cast<std::size_t>(s_.n[1]);
    file_ = std::fopen(path_.c_str(), "wb");
    if (!file_) throw std::runtime_error("cannot open " + path_ + " for writing");
    // ★ A constructor that throws never runs the destructor: remove the file here, or a
    // failed begin leaves an empty STL behind.
    try {
      buf_.resize(kWriteBuffer);
      unsigned char head[84];
      std::memset(head, 0, sizeof head);
      std::memcpy(head, kHeader, std::min(sizeof kHeader - 1, std::size_t(80)));
      put_u32(head + 80, 0);  // patched by finish()
      write_raw(head, sizeof head);
      lo_.resize(slab_);
      hi_.resize(slab_);
      note_peak();
      fill(lo_, 0);
    } catch (...) {
      abandon();
      throw;
    }
  }

  ~LatticeExporter() { abandon(); }

  std::mutex mu;

  int32_t slabs_total() const { return s_.n[2] - 1; }
  int32_t slabs_left() const { return slabs_total() - done_; }

  // March up to `slabs` more slabs.
  int32_t step(int32_t slabs) {
    if (!file_) throw std::runtime_error("the export is closed");
    for (int32_t s = 0; s < slabs && done_ < slabs_total(); ++s) {
      fill(hi_, done_ + 1);
      note_peak();
      march(done_);
      std::swap(lo_, hi_);
      ++done_;
      if (triangles_ > int64_t(std::numeric_limits<uint32_t>::max()))
        throw std::runtime_error("over 4 294 967 295 triangles: a binary STL cannot count them — raise h");
    }
    return slabs_left();
  }

  FlexExportStatus status() const {
    FlexExportStatus st;
    st.nx = s_.n[0];
    st.ny = s_.n[1];
    st.nz = s_.n[2];
    st.slabs_total = slabs_total();
    st.slabs_done = done_;
    st.triangles = triangles_;
    st.slab_floats = static_cast<int64_t>(slab_);
    st.sample_floats_allocated = static_cast<int64_t>(lo_.capacity() + hi_.capacity());
    st.sample_floats_peak = peak_;
    st.write_buffer_bytes = static_cast<int64_t>(buf_.capacity());
    return st;
  }

  FlexExportResult finish() {
    step(slabs_left());
    flush();
    unsigned char count[4];
    put_u32(count, static_cast<uint32_t>(triangles_));
    if (std::fseek(file_, 80, SEEK_SET) != 0 || std::fwrite(count, 1, 4, file_) != 4)
      throw std::runtime_error("cannot write the triangle count to " + path_);
    FILE* f = file_;
    file_ = nullptr;
    if (std::fclose(f) != 0) {
      std::remove(path_.c_str());
      throw std::runtime_error("cannot close " + path_);
    }
    FlexExportResult r;
    r.triangles = triangles_;
    r.bytes = 84 + 50 * triangles_;
    r.nx = s_.n[0];
    r.ny = s_.n[1];
    r.nz = s_.n[2];
    return r;
  }

  // Close and delete a partial file (cancel, failure, or a handle never finished).
  void abandon() {
    if (!file_) return;
    std::fclose(file_);
    file_ = nullptr;
    std::remove(path_.c_str());
  }

 private:
  void note_peak() {
    peak_ = std::max(peak_, static_cast<int64_t>(lo_.capacity() + hi_.capacity()));
  }

  // One sample layer. Rows run in parallel where libdispatch is there; each sample is
  // a pure function of its grid point, so the layer is the same either way.
  void fill(std::vector<float>& layer, int32_t k) {
    struct Ctx {
      const LatticeExporter* self;
      float* out;
      int32_t k;
    } ctx{this, layer.data(), k};
    auto row = [](void* p, std::size_t j) {
      const Ctx& c = *static_cast<const Ctx*>(p);
      const int32_t nx = c.self->s_.n[0];
      float* dst = c.out + j * static_cast<std::size_t>(nx);
      for (int32_t i = 0; i < nx; ++i)
        dst[i] = sample_value(c.self->f_, c.self->s_, c.self->hv_, i, static_cast<int>(j), c.k);
    };
#if defined(__APPLE__)
    dispatch_apply_f(static_cast<std::size_t>(s_.n[1]), DISPATCH_APPLY_AUTO, &ctx, row);
#else
    for (std::size_t j = 0; j < static_cast<std::size_t>(s_.n[1]); ++j) row(&ctx, j);
#endif
  }

  // The cubes between sample layers k (lo_) and k + 1 (hi_).
  void march(int32_t k) {
    const EdgeTable& et = edge_table();
    const int32_t nx = s_.n[0], ny = s_.n[1];
    const std::vector<float>& X = s_.coord[0];
    const std::vector<float>& Y = s_.coord[1];
    const std::vector<float>& Z = s_.coord[2];
    for (int32_t j = 0; j + 1 < ny; ++j) {
      const std::size_t r0 = static_cast<std::size_t>(j) * static_cast<std::size_t>(nx);
      const std::size_t r1 = r0 + static_cast<std::size_t>(nx);
      for (int32_t i = 0; i + 1 < nx; ++i) {
        const std::size_t a = r0 + static_cast<std::size_t>(i), b = r1 + static_cast<std::size_t>(i);
        const float v[8] = {lo_[a], lo_[a + 1], lo_[b + 1], lo_[b],
                            hi_[a], hi_[a + 1], hi_[b + 1], hi_[b]};
        int cube = 0;
        for (int c = 0; c < 8; ++c)
          if (v[c] < 0.0f) cube |= 1 << c;
        if (cube == 0 || cube == 255) continue;
        float vert[12][3];
        const int m = et.mask[cube];
        for (int e = 0; e < 12; ++e) {
          if (!(m & (1 << e))) continue;
          const int ca = kEdgeLow[e][0], cb = kEdgeLow[e][1];
          const int oi = kCorner[ca][0], oj = kCorner[ca][1], ok = kCorner[ca][2];
          float px = X[static_cast<std::size_t>(i + oi)], py = Y[static_cast<std::size_t>(j + oj)],
                pz = Z[static_cast<std::size_t>(k + ok)];
          if (kCorner[cb][0] != oi)
            px = crossing(px, X[static_cast<std::size_t>(i + 1)], v[ca], v[cb]);
          else if (kCorner[cb][1] != oj)
            py = crossing(py, Y[static_cast<std::size_t>(j + 1)], v[ca], v[cb]);
          else
            pz = crossing(pz, Z[static_cast<std::size_t>(k + 1)], v[ca], v[cb]);
          vert[e][0] = px;
          vert[e][1] = py;
          vert[e][2] = pz;
        }
        const int* tri = kTriTable[cube];
        for (int t = 0; tri[t] != -1; t += 3)
          emit(vert[tri[t]], vert[tri[t + 2]], vert[tri[t + 1]]);  // outward: (e0, e2, e1)
      }
    }
  }

  // One facet: normal from the winding, normalised, zero when degenerate — the
  // MeshExport.binarySTL rule.
  void emit(const float* p0, const float* p1, const float* p2) {
    const float ux = p1[0] - p0[0], uy = p1[1] - p0[1], uz = p1[2] - p0[2];
    const float wx = p2[0] - p0[0], wy = p2[1] - p0[1], wz = p2[2] - p0[2];
    float nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
    const float len = std::sqrt(nx * nx + ny * ny + nz * nz);
    if (len > 0.0f) {
      nx /= len;
      ny /= len;
      nz /= len;
    } else {
      nx = ny = nz = 0.0f;
    }
    if (used_ + 50 > buf_.size()) flush();
    unsigned char* o = buf_.data() + used_;
    put_f32(o + 0, nx);
    put_f32(o + 4, ny);
    put_f32(o + 8, nz);
    for (int c = 0; c < 3; ++c) {
      put_f32(o + 12 + 4 * c, p0[c]);
      put_f32(o + 24 + 4 * c, p1[c]);
      put_f32(o + 36 + 4 * c, p2[c]);
    }
    o[48] = 0;
    o[49] = 0;
    used_ += 50;
    ++triangles_;
  }

  void write_raw(const unsigned char* p, std::size_t n) {
    if (std::fwrite(p, 1, n, file_) != n) throw std::runtime_error("cannot write to " + path_);
  }
  void flush() {
    if (used_ == 0) return;
    write_raw(buf_.data(), used_);
    used_ = 0;
  }

  FlexLatticeGrids f_;
  double h_;
  float hv_;
  std::string path_;
  SampleGrid s_;
  std::size_t slab_ = 0;
  std::FILE* file_ = nullptr;
  std::vector<unsigned char> buf_;
  std::size_t used_ = 0;
  std::vector<float> lo_, hi_;  // ★ the ONLY sample storage: layers done_ and done_ + 1
  int32_t done_ = 0;
  int64_t triangles_ = 0;
  int64_t peak_ = 0;
};

std::mutex g_exports_mu;
std::map<int64_t, std::shared_ptr<LatticeExporter>> g_exports;
int64_t g_next_export = 1;

std::shared_ptr<LatticeExporter> find_export(int64_t handle) {
  std::lock_guard<std::mutex> lock(g_exports_mu);
  auto it = g_exports.find(handle);
  return it == g_exports.end() ? nullptr : it->second;
}
std::shared_ptr<LatticeExporter> take_export(int64_t handle) {
  std::lock_guard<std::mutex> lock(g_exports_mu);
  auto it = g_exports.find(handle);
  if (it == g_exports.end()) return nullptr;
  auto e = it->second;
  g_exports.erase(it);
  return e;
}

void fail(BridgeError& err, const std::string& message) {
  err.ok = false;
  err.message = message;
}

}  // namespace

FlexExportEstimate flexible_lattice_export_estimate(const FlexLatticeGrids& f, double h_mm) {
  FlexExportEstimate est;
  if (!flexible_lattice_grids_error(f).empty()) return est;
  SampleGrid s;
  try {
    s = sample_grid(f, h_mm);
  } catch (const std::exception&) {
    return est;
  }
  est.nx = s.n[0];
  est.ny = s.n[1];
  est.nz = s.n[2];
  est.samples = int64_t(s.n[0]) * s.n[1] * s.n[2];
  const int64_t cx = s.n[0] - 1, cy = s.n[1] - 1, cz = s.n[2] - 1;
  est.cubes = cx * cy * cz;
  if (est.cubes <= 0) {
    est.bytes = 84;
    return est;
  }
  const EdgeTable& et = edge_table();
  const float hv = static_cast<float>(h_mm);
  auto tris_at = [&](int64_t i, int64_t j, int64_t k) {
    int cube = 0;
    for (int c = 0; c < 8; ++c)
      if (sample_value(f, s, hv, static_cast<int>(i + kCorner[c][0]), static_cast<int>(j + kCorner[c][1]),
                       static_cast<int>(k + kCorner[c][2])) < 0.0f)
        cube |= 1 << c;
    return et.tri_count[cube];
  };
  // ★ A QUASI-RANDOM probe (Roberts' R3 sequence), not a regular sub-grid: a regular
  // stride can alias with the lattice's own period and read every probe on a wall (or
  // none). Small grids are counted exhaustively, which is then exact.
  constexpr int64_t kProbes = 32768;
  int64_t crossed = 0, tris = 0;
  if (est.cubes <= kProbes) {
    for (int64_t k = 0; k < cz; ++k)
      for (int64_t j = 0; j < cy; ++j)
        for (int64_t i = 0; i < cx; ++i) {
          const int t = tris_at(i, j, k);
          crossed += t > 0;
          tris += t;
        }
    est.probed_cubes = est.cubes;
  } else {
    const double g = 1.2207440846057596;  // the plastic number: R3's generator
    const double a1 = 1.0 / g, a2 = 1.0 / (g * g), a3 = 1.0 / (g * g * g);
    for (int64_t n = 0; n < kProbes; ++n) {
      const double u = std::fmod(0.5 + a1 * double(n), 1.0), v = std::fmod(0.5 + a2 * double(n), 1.0),
                   w = std::fmod(0.5 + a3 * double(n), 1.0);
      const int64_t i = std::min(cx - 1, static_cast<int64_t>(u * double(cx)));
      const int64_t j = std::min(cy - 1, static_cast<int64_t>(v * double(cy)));
      const int64_t k = std::min(cz - 1, static_cast<int64_t>(w * double(cz)));
      const int t = tris_at(i, j, k);
      crossed += t > 0;
      tris += t;
    }
    est.probed_cubes = kProbes;
  }
  est.crossing_fraction = double(crossed) / double(est.probed_cubes);
  est.triangles = static_cast<int64_t>(std::llround(double(tris) / double(est.probed_cubes) * double(est.cubes)));
  est.bytes = 84 + 50 * est.triangles;
  return est;
}

int64_t flexible_lattice_export_begin(const FlexLatticeGrids& f, double h_mm, const std::string& path,
                                      BridgeError& err) {
  const std::string bad = flexible_lattice_grids_error(f);
  if (!bad.empty()) {
    fail(err, bad);
    return 0;
  }
  try {
    auto e = std::make_shared<LatticeExporter>(f, h_mm, path);
    std::lock_guard<std::mutex> lock(g_exports_mu);
    const int64_t handle = g_next_export++;
    g_exports[handle] = std::move(e);
    return handle;
  } catch (const std::exception& ex) {
    fail(err, ex.what());
    return 0;
  }
}

int32_t flexible_lattice_export_step(int64_t handle, int32_t slabs, BridgeError& err) {
  auto e = find_export(handle);
  if (!e) {
    fail(err, "unknown export handle " + std::to_string(handle));
    return -1;
  }
  std::lock_guard<std::mutex> lock(e->mu);
  try {
    return e->step(std::max(0, slabs));
  } catch (const std::exception& ex) {
    fail(err, ex.what());
    return -1;
  }
}

FlexExportStatus flexible_lattice_export_status(int64_t handle, BridgeError& err) {
  auto e = find_export(handle);
  if (!e) {
    fail(err, "unknown export handle " + std::to_string(handle));
    return {};
  }
  std::lock_guard<std::mutex> lock(e->mu);
  return e->status();
}

FlexExportResult flexible_lattice_export_finish(int64_t handle, BridgeError& err) {
  auto e = take_export(handle);
  if (!e) {
    fail(err, "unknown export handle " + std::to_string(handle));
    return {};
  }
  std::lock_guard<std::mutex> lock(e->mu);
  try {
    return e->finish();
  } catch (const std::exception& ex) {
    e->abandon();
    fail(err, ex.what());
    return {};
  }
}

void flexible_lattice_export_cancel(int64_t handle) {
  auto e = take_export(handle);
  if (!e) return;
  std::lock_guard<std::mutex> lock(e->mu);
  e->abandon();
}

}  // namespace topoptbridge
