// R4 — IS THE EXPORTED ORGANIC MESH WATERTIGHT AND MANIFOLD?
//
// Measured with core's own `check_watertight` (topopt/mesh.hpp): every edge used
// exactly twice, no edge used by three or more triangles. The OCTET generator is run
// on the same fixture through the same check, because the bar is only meaningful
// against what the shipped path already produces — the lattice export has always been
// an INTERPENETRATING SOUP of closed primitives, and a number without that comparison
// would read as a verdict on organic alone.
//
// Build:
//   c++ -std=c++17 -O2 -I core/include evidence/2026-08-21-organic-lattice/manifold_probe.cpp \
//       core/build/libtopopt.a -o /tmp/manifold_probe && /tmp/manifold_probe

#include <array>
#include <cmath>
#include <cstdio>
#include <map>
#include <vector>

#include "topopt/lattice_gen.hpp"
#include "topopt/mesh.hpp"
#include "topopt/organic_lattice.hpp"

using namespace topopt;

namespace {
// ★ WELD BY EXACT POSITION FIRST, OR THE CHECK MEASURES NOTHING. `MeshSink` stores
// three fresh vertices per triangle, so an unwelded soup reports every edge as a
// boundary edge and "watertight NO" regardless of what the geometry is — a green run
// that measures nothing, in reverse. `check_watertight` works on vertex INDICES
// (mesh.hpp says so in its first line: "welded (shared) vertices"), and the swept
// primitives emit their shared ring vertices from IDENTICAL arithmetic, so an exact
// bit-for-bit key is the right one: no tolerance, nothing merged that the generator
// did not intend to be the same point.
TriangleMesh weld(const TriangleMesh& in) {
  TriangleMesh out;
  std::map<std::array<double, 3>, int> seen;
  auto id = [&](const Vec3& v) {
    const std::array<double, 3> k{v.x, v.y, v.z};
    auto it = seen.find(k);
    if (it != seen.end()) return it->second;
    const int idx = static_cast<int>(out.vertices.size());
    out.vertices.push_back(v);
    seen.emplace(k, idx);
    return idx;
  };
  for (const auto& t : in.triangles)
    out.triangles.push_back({id(in.vertices[static_cast<std::size_t>(t[0])]),
                             id(in.vertices[static_cast<std::size_t>(t[1])]),
                             id(in.vertices[static_cast<std::size_t>(t[2])])});
  return out;
}

void report(const char* what, const TriangleMesh& raw) {
  const TriangleMesh m = weld(raw);
  const WatertightReport w = check_watertight(m);
  printf("%-26s tris %8zu  verts %8zu  watertight %s  boundary_edges %d  "
         "non_manifold_edges %d\n",
         what, m.triangles.size(), m.vertices.size(), w.watertight ? "YES" : "NO",
         w.boundary_edges, w.non_manifold_edges);
  printf("%-26s signed volume %.4f mm^3 (>0 = outward-wound)\n", "", signed_volume(m));
}
}  // namespace

int main() {
  VoxelGrid g;
  g.nx = 40; g.ny = 40; g.nz = 40;
  g.spacing = 1.0;
  g.origin = {0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Interior);
  const std::size_t n = g.voxel_count();
  if (n == 0) { printf("EMPTY GRID — the probe would measure nothing\n"); return 1; }

  std::vector<char> cand(n, 1);
  std::vector<double> stress(6 * n, 0.0), sp(n, 0.0), width(n, 40.0);
  for (std::size_t e = 0; e < n; ++e) {
    stress[6 * e + 0] = 3.0;
    stress[6 * e + 1] = 2.0;
    stress[6 * e + 2] = 1.0;
    sp[e] = 5.0;
  }
  OrganicParams P;
  P.min_extrudable_width_mm = 0.45;
  const OrganicLattice L = trace_organic_lattice(g, cand, stress, sp, &width, P);

  MeshSink om;
  const OrganicGenStats os = generate_organic_lattice(L, om, nullptr);
  printf("ORGANIC  curves %zu connectors %zu  struts %llu nodes %llu  vol %.1f mm^3\n",
         L.curves.size(), L.connectors.size(),
         (unsigned long long)os.struts, (unsigned long long)os.nodes, os.volume_mm3);
  report("organic soup", om.mesh);

  LatticeRegion R;
  R.origin = {0.0, 0.0, 0.0};
  R.nx = 8; R.ny = 8; R.nz = 8;
  R.cell_mm = 5.0;
  LatticeRadiusField G;
  G.uniform_mm = 0.225;
  G.nseg = 8;
  MeshSink dm;
  const LatticeGenStats ds = generate_lattice(LatticeGenTopology::Octet, R, G, dm);
  printf("DOUBLED  struts %llu nodes %llu  vol %.1f mm^3\n",
         (unsigned long long)ds.struts, (unsigned long long)ds.nodes,
         ds.interior_volume_mm3);
  report("octet soup (reference)", dm.mesh);

  // ── STEPPED: two independent passes at UNRELATED cells into one sink. This is the
  // generator half of the algorithm exercised directly, because the `analyze` route
  // reports without writing geometry and no stored design of the maintainer's part
  // exists here to drive `lattice-variant`.
  {
    std::vector<LatticeSteppedPass> passes;
    for (double c : {5.0, 3.0}) {
      LatticeSteppedPass sp;
      sp.region.origin = {0.0, 0.0, 0.0};
      sp.region.cell_mm = c;
      sp.region.nx = static_cast<int>(40.0 / c);
      sp.region.ny = sp.region.nx;
      sp.region.nz = sp.region.nx;
      const bool lower = c == 5.0;
      const int half = sp.region.nz / 2;
      sp.region.latticed = [lower, half](int, int, int ck) {
        return lower ? ck < half : ck >= half;   // two abutting blocks, one seam
      };
      sp.radius.uniform_mm = 0.225;
      sp.radius.nseg = 8;
      passes.push_back(std::move(sp));
    }
    MeshSink sm;
    const LatticeGenStats ss =
        generate_lattice_stepped(LatticeGenTopology::Octet, passes, sm);
    printf("STEPPED  two passes at 5.0 and 3.0 mm: struts %llu nodes %llu vol %.1f mm^3\n",
           (unsigned long long)ss.struts, (unsigned long long)ss.nodes,
           ss.interior_volume_mm3);
    report("stepped soup", sm.mesh);
    MeshSink sm2;
    generate_lattice_stepped(LatticeGenTopology::Octet, passes, sm2);
    bool same = sm2.mesh.triangles.size() == sm.mesh.triangles.size();
    for (std::size_t i = 0; i < sm.mesh.vertices.size() && same; ++i)
      same = sm.mesh.vertices[i].x == sm2.mesh.vertices[i].x &&
             sm.mesh.vertices[i].y == sm2.mesh.vertices[i].y &&
             sm.mesh.vertices[i].z == sm2.mesh.vertices[i].z;
    printf("stepped emission determinism (exact doubles): %s\n", same ? "PASS" : "FAIL");
  }

  // The DETERMINISM of the emitted stream (R9, geometry half): the same lattice
  // emitted twice must produce identical triangles in identical order.
  MeshSink om2;
  generate_organic_lattice(L, om2, nullptr);
  bool same = om2.mesh.triangles.size() == om.mesh.triangles.size() &&
              om2.mesh.vertices.size() == om.mesh.vertices.size();
  for (std::size_t i = 0; i < om.mesh.vertices.size() && same; ++i)
    same = om.mesh.vertices[i].x == om2.mesh.vertices[i].x &&
           om.mesh.vertices[i].y == om2.mesh.vertices[i].y &&
           om.mesh.vertices[i].z == om2.mesh.vertices[i].z;
  printf("emission determinism (same lattice twice, exact doubles): %s\n",
         same ? "PASS" : "FAIL");
  return 0;
}
