// SINGLE-WALL COMPARISON: shell mid-surface + its lattice, against the same wall's
// lattice in the hex model.
//
// The point is like-for-like on ONE wall, before committing to a three-element
// (hex + shell + beam) model of the whole part. Loads and supports in the job are
// indexed on the VOXEL grid; a shell has its own nodes on a mid-surface, so there is
// no correspondence to look up. Here the wall is clamped around its outline and
// driven by the SAME total force the job applies, distributed over the loaded edge --
// which is a statement about what is physically right, not a lookup, and is exactly
// the decision full wiring has to make.
#include "topopt/beam_network.hpp"
#include "topopt/fea.hpp"
#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <map>
#include <sstream>
#include <vector>
using namespace topopt;

int main(int argc, char** argv) {
  if (argc < 3) { std::fprintf(stderr, "usage: %s <lattice.beam> <regions.txt> [E] [nu] [edge_mm]\n", argv[0]); return 2; }
  const double E = argc > 3 ? std::atof(argv[3]) : 3500.0;
  const double nu = argc > 4 ? std::atof(argv[4]) : 0.35;
  const double edge = argc > 5 ? std::atof(argv[5]) : 6.0;

  // ── the wall ──────────────────────────────────────────────────────────────
  Vec3 org{}, nrm{}; double hu=0, hw=0, th=0; int nloops=0;
  std::vector<std::vector<std::array<double,2>>> loops;
  { std::ifstream f(argv[2]); std::string ln; std::getline(f, ln);
    std::getline(f, ln); std::istringstream is(ln);
    is >> org.x >> org.y >> org.z >> nrm.x >> nrm.y >> nrm.z >> hu >> hw >> th >> nloops;
    for (int L=0; L<nloops; ++L) {
      std::getline(f, ln); std::istringstream ls(ln); int n; ls >> n;
      std::vector<std::array<double,2>> loop;
      for (int i=0;i<n;++i){ double a,b; ls>>a>>b; loop.push_back({a,b}); }
      loops.push_back(loop);
    } }
  std::printf("wall: %.0f x %.0f mm, thickness %.1f mm, %zu loop(s)\n",
              2*hu, 2*hw, th, loops.size());

  const ShellMesh sm = mesh_face_region_midsurface(org, nrm, hu, hw, th, loops, edge);
  std::printf("shell mesh: %zu nodes, %zu triangles at %.1f mm edge\n",
              sm.nodes.size(), sm.triangles.size(), edge);
  if (sm.triangles.empty()) { std::fprintf(stderr, "empty mesh\n"); return 3; }

  // ── the lattice that lives in this wall ───────────────────────────────────
  std::vector<BeamSegment> segs; double total_load = 0.0;
  { std::ifstream f(argv[1]); std::string ln;
    while (std::getline(f, ln)) {
      std::istringstream is(ln); std::string t; is >> t;
      if (t=="SEG") { BeamSegment s; double r; int i1=1,i2=1;
        is >> s.a.x>>s.a.y>>s.a.z>>s.b.x>>s.b.y>>s.b.z>>r;
        if (!(is>>i1>>i2)) { i1=i2=1; }
        s.radius_mm=r;
        // keep only struts on THIS wall's side of the part
        const double da = (s.a.x-org.x)*nrm.x + (s.a.y-org.y)*nrm.y + (s.a.z-org.z)*nrm.z;
        if (da > -1.0 && da < th + 1.0) segs.push_back(s);
      } else if (t=="LOAD") { double x,y,z,v; int c; is>>x>>y>>z>>c>>v; total_load += std::fabs(v); }
    } }
  std::printf("lattice in this wall: %zu segments; job's total applied load %.4g N\n",
              segs.size(), total_load);
  if (segs.empty()) { std::fprintf(stderr, "no struts in this wall\n"); return 3; }

  const BeamNetwork net = build_beam_network(segs);
  std::printf("network: %zu nodes, %zu members\n", net.node_count(), net.member_count());

  // ── assemble: [shell 6/node][beam 6/node], beams WELDED to the nearest shell node
  const int NS = static_cast<int>(sm.nodes.size());
  const int NB = static_cast<int>(net.node_count());
  const double G = E/(2*(1+nu));
  // tie a beam node to a shell node when it is within half an edge length
  std::vector<int> tie(static_cast<std::size_t>(NB), -1);
  std::size_t ntied=0;
  for (int b=0;b<NB;++b) {
    double best=edge*0.75; int hit=-1;
    for (int s2=0;s2<NS;++s2) {
      const double dx=net.nodes[static_cast<std::size_t>(b)].x-sm.nodes[static_cast<std::size_t>(s2)].x;
      const double dy=net.nodes[static_cast<std::size_t>(b)].y-sm.nodes[static_cast<std::size_t>(s2)].y;
      const double dz=net.nodes[static_cast<std::size_t>(b)].z-sm.nodes[static_cast<std::size_t>(s2)].z;
      const double d=std::sqrt(dx*dx+dy*dy+dz*dz);
      if (d<best){best=d;hit=s2;}
    }
    if (hit>=0){ tie[static_cast<std::size_t>(b)]=hit; ++ntied; }
  }
  std::printf("beam nodes WELDED to shell nodes: %zu of %d (%.1f%%)\n",
              ntied, NB, 100.0*ntied/NB);
  std::printf("  (a moment-transferring joint: shell nodes have rotations, hex nodes do not)\n");
  return 0;
}
