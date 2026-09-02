// ★ THE HEADLINE, WHICH IS EASY TO MISS IN THE TABLE BELOW: at separation 4.0 the
// EMITTED grown lattice is ONE component holding 100% of the material at 7.5%
// BRIDGES -- better connected than uniform 2 mm (13.6%), the finest uniform lattice
// measured anywhere in this work. On this fixture growth produces the best-connected
// network of any algorithm here. Caveat and it is a real one: ONE separation, ONE
// 12x12x24 fixture. At 4.5 and above the support prune removes almost everything.
//
// ★ THE BRIDGE FRACTION OF GROWN GEOMETRY, across the separation sweep.
// The grown path (floor-seeded columns stitched by lateral joins) has been measured
// with component counts and largest-fraction only. Bridge fraction is the number that
// says whether it is a NETWORK or a TREE, and a tree can neither be pruned nor share
// load. Reported here for both sides of the support prune.
//
// ★ THE TWO ROWS ARE DIFFERENT OBJECTS, NOT TWO SETTINGS OF ONE SWITCH.
//   PRE-EMISSION : the grown curve network as laid down (curves + connectors),
//                  read off the returned OrganicLattice.
//   EMITTED      : what the emitter writes, after node merge, support prune and the
//                  stranded-piece drop.
// Reading the first off the returned object avoids a switch that would disarm a
// printability rule in a production path, but it is NOT "the emitter with the prune
// turned off": passes between the two change topology. Measured at separation 4.5,
// emitted-with-prune-ablated gives 16 components at largest 10.69% while the
// pre-emission network gives 45 at top-1 10.32% -- same largest fraction, nearly
// three times the components. The node merge welds coincident endpoints and moves no
// length, so a LENGTH census cannot see it; the per-stage COMPONENT census printed
// below can.
#include "topopt/organic_lattice.hpp"
#include "topopt/beam_network.hpp"
#include "topopt/mesh.hpp"
#include <cstdio>
#include <cmath>
#include <vector>
#include <map>
#include <algorithm>
#include <functional>
using namespace topopt;
struct CountingSink : TriangleSink {
  std::uint64_t triangles = 0;
  void add_triangle(const Vec3&, const Vec3&, const Vec3&) override { ++triangles; }
};
struct Stat { std::size_t members=0, comps=0; double top1=0, bridges=0, len=0; };
static Stat analyse(const std::vector<BeamSegment>& segs) {
  Stat s;
  if (segs.empty()) return s;
  const BeamNetwork net = build_beam_network(segs);
  s.members = net.member_count();
  if (!s.members) return s;
  std::vector<int> par(net.node_count());
  for (std::size_t i=0;i<par.size();++i) par[i]=int(i);
  std::function<int(int)> f=[&](int x){while(par[x]!=x){par[x]=par[par[x]];x=par[x];}return x;};
  for (const auto&m:net.members){const int a=f(m.node_a),b=f(m.node_b); if(a!=b)par[a>b?a:b]=a<b?a:b;}
  std::map<int,int> c; for(const auto&m:net.members)++c[f(m.node_a)];
  std::vector<int> v; for(auto&kv:c)v.push_back(kv.second);
  std::sort(v.rbegin(),v.rend());
  s.comps=v.size(); s.top1=100.0*v[0]/double(s.members);
  const std::vector<char> br=beam_network_bridges(net);
  std::size_t nb=0; for(char x:br)nb+=x?1u:0u;
  s.bridges=100.0*double(nb)/double(br.size());
  for(const auto&m:net.members){const auto&p=net.nodes[m.node_a];const auto&q=net.nodes[m.node_b];
    s.len+=std::sqrt((p.x-q.x)*(p.x-q.x)+(p.y-q.y)*(p.y-q.y)+(p.z-q.z)*(p.z-q.z));}
  return s;
}
int main(){
  const double seps[6] = {4.0, 4.5, 5.0, 6.0, 7.0, 8.0};
  std::printf("%-5s %-13s %9s %10s %7s %8s %9s\n",
              "sep","object","members","length_mm","comps","top-1","bridges");
  for (double sep : seps) {
    const int nx=12, ny=12, nz=24; const double h=1.0;
    VoxelGrid grid; grid.nx=nx; grid.ny=ny; grid.nz=nz; grid.spacing=h; grid.origin=Vec3{0,0,0};
    const std::size_t n=std::size_t(nx)*ny*nz;
    grid.tags.assign(n, VoxelTag::Interior);
    std::vector<char> cand(n,1);
    std::vector<double> stress(6*n,0.0), spacing(n,sep);
    for (std::size_t e=0;e<n;++e) stress[6*e+2]=1.0;
    OrganicParams params;
    params.layer_hint_mm=0.2; params.min_extrudable_width_mm=0.4;
    params.strut_diameter_mm=0.8; params.build_dir=Vec3{0,0,1};
    OrganicGenStats gs;
    const OrganicLattice lat =
        grow_organic_lattice(grid, cand, stress, spacing, nullptr, params, &gs);
    // prune OFF: the grown curves and their connectors, as laid down
    std::vector<BeamSegment> raw;
    for (const OrganicCurve& c : lat.curves)
      for (std::size_t i=0;i+1<c.points.size();++i)
        raw.push_back({c.points[i], c.points[i+1], c.radius_mm});
    for (const OrganicConnector& k : lat.connectors)
      raw.push_back({k.a, k.b, k.radius_mm});
    // prune ON: what the emitter writes
    CountingSink sink; std::vector<OrganicSpan> spans;
    OrganicGenStats st = generate_organic_lattice(lat, sink, nullptr, 8, nullptr, &spans);
    std::vector<BeamSegment> kept;
    for (const OrganicSpan& s : spans) kept.push_back({s.a, s.b, s.r});
    const Stat off = analyse(raw), on = analyse(kept);
    std::printf("%-5.1f %-13s %9zu %10.1f %7zu %6.2f%% %8.1f%%\n",
                sep,"pre-emission",off.members,off.len,off.comps,off.top1,off.bridges);
    std::printf("%-5s %-13s %9zu %10.1f %7zu %6.2f%% %8.1f%%\n",
                "","emitted",on.members,on.len,on.comps,on.top1,on.bridges);
    // the per-stage census: length AND components, so a pass that re-wires without
    // deleting cannot hide inside a length-preserving stage
    std::printf("      census (len mm / components) by stage:");
    for (int q = 0; q < OrganicGenStats::kCensusStages; ++q)
      if (st.census_len_mm[q] >= 0.0)
        std::printf("  %s %.0f/%d", organic_census_stage_name(q),
                    st.census_len_mm[q], st.census_components[q]);
    std::printf("\n");
  }
  return 0;
}
