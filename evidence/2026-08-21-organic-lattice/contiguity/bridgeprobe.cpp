// The FAST GATE: contiguity and redundancy of a lattice, with no FEA and no mask.
// Components say whether it is one piece; the BRIDGE fraction says whether it is a
// network or a tree -- and a tree can neither share load nor be pruned.
#include "topopt/beam_network.hpp"
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <functional>
#include <map>
int main(int argc, char** argv) {
  std::printf("%-10s %10s %10s %12s %10s   %s\n", "cell", "segments", "nodes",
              "components", "bridges", "verdict");
  for (int a = 1; a < argc; a += 2) {
    const std::string label = argv[a], path = argv[a + 1];
    std::vector<topopt::BeamSegment> segs;
    { std::ifstream f(path); std::string ln;
      while (std::getline(f, ln)) {
        std::istringstream is(ln); std::string t; is >> t;
        if (t != "SEG") continue;
        topopt::BeamSegment s; double r;
        is >> s.a.x >> s.a.y >> s.a.z >> s.b.x >> s.b.y >> s.b.z >> r;
        s.radius_mm = r; segs.push_back(s);
      } }
    if (segs.empty()) { std::printf("%-10s  (no segments)\n", label.c_str()); continue; }
    const topopt::BeamNetwork net = topopt::build_beam_network(segs);
    // connected components over members
    std::vector<int> par(net.node_count());
    for (std::size_t i = 0; i < par.size(); ++i) par[i] = int(i);
    std::function<int(int)> find = [&](int x) {
      while (par[x] != x) { par[x] = par[par[x]]; x = par[x]; } return x; };
    for (const auto& m : net.members) {
      const int x = find(m.node_a), y = find(m.node_b);
      if (x != y) par[x > y ? x : y] = x < y ? x : y;
    }
    std::map<int,int> comp;
    for (const auto& m : net.members) ++comp[find(m.node_a)];
    const std::vector<char> br = topopt::beam_network_bridges(net);
    std::size_t nb = 0; for (char c : br) nb += c ? 1u : 0u;
    const double frac = 100.0 * double(nb) / double(br.size());
    std::printf("%-10s %10zu %10zu %12zu %9.1f%%   %s\n", label.c_str(),
                net.member_count(), net.node_count(), comp.size(), frac,
                comp.size() == 1
                    ? (frac > 70 ? "ONE PIECE but a TREE: no redundancy"
                                 : "ONE PIECE and a network")
                    : (frac > 70 ? "MANY PIECES and a TREE"
                                 : "MANY PIECES but locally networked"));
  }
  return 0;
}
