// Organic cut 2 (brief E1): the print file as the carved solid plus unmerged closed tubes.
//   OF1  the layer check's NonZero fill: overlapping closed shells read as their union.
// Needs the Manifold library (the test makes its reference unions with it).
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <vector>

#include <manifold/manifold.h>

#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_mesh.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                              \
  do {                                                                           \
    ++g_checks;                                                                  \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

static TriangleMesh box_at(Vec3 lo, Vec3 hi) {
  TriangleMesh m;
  const Vec3 p[8] = {{lo.x, lo.y, lo.z}, {hi.x, lo.y, lo.z}, {hi.x, hi.y, lo.z}, {lo.x, hi.y, lo.z},
                     {lo.x, lo.y, hi.z}, {hi.x, lo.y, hi.z}, {hi.x, hi.y, hi.z}, {lo.x, hi.y, hi.z}};
  for (const Vec3& v : p) m.vertices.push_back(v);
  const int q[6][4] = {{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}};
  for (const auto& f : q) {
    m.triangles.push_back({f[0], f[1], f[2]});
    m.triangles.push_back({f[0], f[2], f[3]});
  }
  return m;
}
// Shells side by side in one triangle list, each on its own vertices.
static void append(TriangleMesh& to, const TriangleMesh& m) {
  const int base = static_cast<int>(to.vertices.size());
  to.vertices.insert(to.vertices.end(), m.vertices.begin(), m.vertices.end());
  for (const auto& t : m.triangles) to.triangles.push_back({t[0] + base, t[1] + base, t[2] + base});
}
static manifold::Manifold to_manifold(const TriangleMesh& m) {
  manifold::MeshGL64 g;
  g.numProp = 3;
  for (const Vec3& v : m.vertices) { g.vertProperties.push_back(v.x); g.vertProperties.push_back(v.y); g.vertProperties.push_back(v.z); }
  for (const auto& t : m.triangles)
    for (int k = 0; k < 3; ++k) g.triVerts.push_back(static_cast<std::uint64_t>(t[static_cast<std::size_t>(k)]));
  return manifold::Manifold(g);
}
static TriangleMesh from_manifold(const manifold::Manifold& m) {
  const manifold::MeshGL64 g = m.GetMeshGL64();
  TriangleMesh out;
  for (std::size_t v = 0; v < g.NumVert(); ++v)
    out.vertices.push_back({g.vertProperties[v * g.numProp], g.vertProperties[v * g.numProp + 1], g.vertProperties[v * g.numProp + 2]});
  for (std::size_t t = 0; t < g.NumTri(); ++t)
    out.triangles.push_back({static_cast<int>(g.triVerts[3 * t]), static_cast<int>(g.triVerts[3 * t + 1]), static_cast<int>(g.triVerts[3 * t + 2])});
  return out;
}
static bool same_findings(const LayerReport& a, const LayerReport& b) {
  if (a.mid_air.size() != b.mid_air.size() || a.one_ended.size() != b.one_ended.size() ||
      a.long_bridges.size() != b.long_bridges.size())
    return false;
  for (std::size_t i = 0; i < a.mid_air.size(); ++i)
    if (a.mid_air[i].x != b.mid_air[i].x || a.mid_air[i].y != b.mid_air[i].y || a.mid_air[i].z != b.mid_air[i].z ||
        a.mid_air[i].mm2 != b.mid_air[i].mm2)
      return false;
  for (std::size_t i = 0; i < a.one_ended.size(); ++i)
    if (a.one_ended[i].x != b.one_ended[i].x || a.one_ended[i].y != b.one_ended[i].y || a.one_ended[i].z != b.one_ended[i].z ||
        a.one_ended[i].reach_mm != b.one_ended[i].reach_mm)
      return false;
  return a.longest_reach_mm == b.longest_reach_mm && a.thin_islands == b.thin_islands && a.layers == b.layers &&
         a.first_layer_mm2 == b.first_layer_mm2;
}

// OF1: two overlapping closed cubes as two shells, under NonZero, give the same filled pixels (every layer's area) and
// the same findings as their true union as one mesh; under EvenOdd they do not.
static void test_nonzero_fill() {
  const TriangleMesh a = box_at({0.0, 0.0, 0.0}, {6.02, 4.03, 6.01});
  const TriangleMesh b = box_at({3.01, 0.0, 4.11}, {11.03, 4.03, 6.01});   // runs 5 mm out past a: held at one end
  TriangleMesh two;
  append(two, a);
  append(two, b);
  const TriangleMesh one = from_manifold(to_manifold(a) + to_manifold(b));
  CHECK(one.triangles.size() > 12);
  LayerSpec nz;
  nz.fill = LayerSpec::Fill::NonZero;
  nz.layer_areas = true;
  LayerSpec eo;
  eo.layer_areas = true;
  const LayerReport two_nz = check_layers(two, nz), one_nz = check_layers(one, nz);
  const LayerReport two_eo = check_layers(two, eo), one_eo = check_layers(one, eo);
  CHECK(!one_nz.layer_mm2.empty() && one_nz.layer_mm2 == two_nz.layer_mm2);
  CHECK(same_findings(one_nz, two_nz));
  CHECK(!one_nz.one_ended.empty());   // the overhang is found, in both
  // One closed shell reads the same under either rule.
  CHECK(one_eo.layer_mm2 == one_nz.layer_mm2 && same_findings(one_eo, one_nz));
  // Under EvenOdd the overlap cancels: the layers through it read less.
  CHECK(two_eo.layer_mm2 != one_eo.layer_mm2);
  double lost = 0.0;
  for (std::size_t k = 0; k < one_eo.layer_mm2.size(); ++k) lost += one_eo.layer_mm2[k] - two_eo.layer_mm2[k];
  CHECK(lost > 1.0);
  // The default is EvenOdd, and it reports no areas unless asked.
  CHECK(LayerSpec{}.fill == LayerSpec::Fill::EvenOdd && check_layers(two).layer_mm2.empty());
  // A shell inside out under NonZero adds nothing (its crossings count down).
  TriangleMesh inv = a;
  for (auto& t : inv.triangles) std::swap(t[1], t[2]);
  TriangleMesh with_inv;
  append(with_inv, b);
  append(with_inv, inv);
  const LayerReport r_inv = check_layers(with_inv, nz);
  CHECK(r_inv.layer_mm2.size() > 25 && r_inv.layer_mm2[25] > 1.0 && r_inv.layer_mm2[25] < one_nz.layer_mm2[25] - 10.0);
}

int main() {
  if (!mesh_available()) {
    std::printf("no mesh library in this build (%d checks, %d failed)\n", g_checks, g_fail);
    return 0;
  }
  test_nonzero_fill();
  std::printf("weave tubes: %d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
