// skin_conn: is each type's Diagrid skin CONNECTED on a flat face normal to a cell axis?
// A 6x6x6 block of 8 mm cells clipped by a box whose x-min face sits at c cells; every
// anchor ball on that face and every skin fragment near it go into a union-find (points
// keyed to 1 um); report the anchor components on the face's interior (1 cell in from its
// edges, so the rim/corner behaviour does not count).
#include <cmath>
#include <cstdio>
#include <map>
#include <numeric>
#include <string>
#include <tuple>
#include <vector>
#include "topopt/lattice.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
using namespace topopt;
struct Null : TriangleSink { void add_triangle(const Vec3&, const Vec3&, const Vec3&) override {} };
struct UF { std::vector<int> p; int f(int x){ while(p[x]!=x) x=p[x]=p[p[x]]; return x; } void u(int a,int b){ p[f(a)]=f(b);} };
int main(int argc, char** argv) {
  std::vector<std::string> ids = {"octet","fcc","kelvin","rhombic","diamond","bcc","sc"};
  if (argc > 1) ids = {argv[1]};
  const double L = 8.0;
  for (const std::string& id : ids) {
    const LatticeGenTopology gt = lattice_gen_topology_from_id(id);
    const LatticeTopology t = lattice_topology_from_id(id);
    const double rho = 0.5 * (lattice_rho_min(t) + lattice_rho_max(t));
    const double r = id == "octet" ? 0.6 : 0.5 * lattice_strut_diameter_mm(t, rho, L);
    int worst = 0; double worst_c = 0;
    std::printf("%s (r %.3f mm):", id.c_str(), r);
    for (int ci = 1; ci < 20; ++ci) {
      const double c = 0.05 * ci;
      const double x0 = c * L;
      LatticeBoundary B; B.add_box({x0, 0.3, 0.3}, {47.7, 47.7, 47.7});
      LatticeRegion R; R.nx = R.ny = R.nz = 6; R.cell_mm = L; R.boundary = &B;
      LatticeRadiusField G; G.uniform_mm = r;
      LatticeSkinSpec skin; skin.mode = LatticeSkinMode::Diagrid;
      skin.min_radius_mm = lattice_skin_min_radius_mm(0.42);
      std::map<std::tuple<long,long,long>, int> key;
      std::vector<int> anchors; UF uf;
      auto id_of = [&](const Vec3& p) {
        auto k = std::make_tuple(std::lround(p.x*1000), std::lround(p.y*1000), std::lround(p.z*1000));
        auto it = key.find(k); if (it != key.end()) return it->second;
        int n = (int)uf.p.size(); uf.p.push_back(n); key[k] = n; return n; };
      auto on_face = [&](const Vec3& p) { return p.x < x0 + 3.0; };
      auto interior = [&](const Vec3& p) { return p.y > L && p.y < 47.7 - L && p.z > L && p.z < 47.7 - L; };
      LatticeGenObserver obs;
      obs.on_element = [&](LatticeGenElement k, const Vec3& a, const Vec3& b, double) {
        if (k == LatticeGenElement::AnchorNode && on_face(a)) { int n = id_of(a); if (interior(a)) anchors.push_back(n); }
        if (k == LatticeGenElement::SkinStrut && on_face(a) && on_face(b)) uf.u(id_of(a), id_of(b));
      };
      Null sink;
      (void)generate_lattice(gt, R, G, sink, skin, &obs);
      std::map<int,int> comp;
      for (int n : anchors) comp[uf.f(n)]++;
      int largest = 0; for (auto& kv : comp) largest = std::max(largest, kv.second);
      std::printf(" c%.2f:%zu/%zu", c, comp.size(), anchors.size());
      if ((int)comp.size() > worst) { worst = (int)comp.size(); worst_c = c; }
    }
    std::printf("\n  -> worst %d components (at c %.2f)\n", worst, worst_c);
  }
}
