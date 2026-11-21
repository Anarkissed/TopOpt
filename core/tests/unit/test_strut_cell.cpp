// test_strut_cell — THE PRODUCTION CELL IS THE MEASURED CELL (lattice types round 1,
// docs/design/lattice-types/02-core-spec.md §2.1 and go-live item 1).
//
// The tensor rows core certifies with were measured by
// core/tests/harness/tensor_library_nine_probe.cpp on ITS table of struts. The shipped
// "octet" rows were measured on a different geometry from the one the generator builds
// (tensor-library-nine finding 3), and the spec says: don't repeat that. So this test
// does not re-type the probe's table — it COMPILES THE PROBE'S OWN SOURCE (its main
// renamed) and compares its make_lattice() with lattice_strut_cell() element for
// element: same S, same struts in the same order, same phase (both anchor the integer
// grid at the cell's min corner). A future edit to either side fails here.
//
// It also pins what the generator relies on: every strut inside its owner's closed
// box, every node an endpoint, the per-cell counts the family study recorded
// (evidence/2026-07-27-strut-lattice-family/lattices.txt), and the periodic density
// against the landed tensor rows' own rho at their own radius (a row's rho is
// voxelised at vpc48 by the same field).
//
// Self-contained CHECK harness (ARCHITECTURE §4).

#define main tensor_library_nine_probe_main
#include "../harness/tensor_library_nine_probe.cpp"
#undef main

#include <cstdio>
#include <set>
#include <stdexcept>
#include <string>
#include <tuple>

#include "topopt/strut_cell.hpp"

static int g_checks = 0, g_failures = 0;
#define CHECK(cond, msg)                                         \
  do {                                                           \
    ++g_checks;                                                  \
    if (!(cond)) {                                               \
      ++g_failures;                                              \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, msg);  \
    }                                                            \
  } while (0)

int main() {
  struct Case {
    const char* id;
    topopt::LatticeTopology topo;
    std::size_t struts, nodes;  // lattices.txt (family study)
  };
  const Case cases[] = {
      {"sc", topopt::LatticeTopology::SimpleCubic, 3, 1},
      {"bcc", topopt::LatticeTopology::Bcc, 8, 2},
      {"fcc", topopt::LatticeTopology::Fcc, 12, 4},
      {"octet", topopt::LatticeTopology::Octet, 24, 4},
      {"diamond", topopt::LatticeTopology::Diamond, 16, 8},
      {"kelvin", topopt::LatticeTopology::Kelvin, 24, 12},
      {"rhombic", topopt::LatticeTopology::Rhombic, 32, 12},
  };

  // 1. The production table == the probe's, element for element.
  for (const Case& c : cases) {
    const Lattice probe = make_lattice(c.id);
    const topopt::StrutCell& prod = topopt::lattice_strut_cell(c.topo);
    const std::string id = c.id;
    CHECK(prod.S == probe.S, (id + ": S equals the probe's").c_str());
    CHECK(prod.struts.size() == probe.struts.size(),
          (id + ": strut count equals the probe's").c_str());
    bool same = prod.struts.size() == probe.struts.size();
    for (std::size_t i = 0; same && i < prod.struts.size(); ++i) {
      const auto& a = prod.struts[i];
      const auto& b = probe.struts[i];
      same = a.a.x == b.a.x && a.a.y == b.a.y && a.a.z == b.a.z && a.b.x == b.b.x &&
             a.b.y == b.b.y && a.b.z == b.b.z;
    }
    CHECK(same, (id + ": every strut equals the probe's, in order").c_str());
    CHECK(prod.struts.size() == c.struts, (id + ": struts per cell (lattices.txt)").c_str());
    CHECK(prod.nodes.size() == c.nodes, (id + ": nodes per cell (lattices.txt)").c_str());

    // 2. What the generator rests on: closed-box struts, nodes == strut endpoints.
    std::set<std::tuple<int, int, int>> ends, nodes;
    for (const auto& s : topopt::strut_cell_closed_struts(prod)) {
      const bool inside = s.a.x >= 0 && s.a.x <= prod.S && s.a.y >= 0 && s.a.y <= prod.S &&
                          s.a.z >= 0 && s.a.z <= prod.S && s.b.x >= 0 && s.b.x <= prod.S &&
                          s.b.y >= 0 && s.b.y <= prod.S && s.b.z >= 0 && s.b.z <= prod.S;
      CHECK(inside, (id + ": closed-box strut inside [0,S]^3").c_str());
      ends.insert({s.a.x, s.a.y, s.a.z});
      ends.insert({s.b.x, s.b.y, s.b.z});
    }
    for (const auto& n : topopt::strut_cell_closed_nodes(prod)) nodes.insert({n.x, n.y, n.z});
    bool ends_are_nodes = true;
    for (const auto& e : ends) ends_are_nodes = ends_are_nodes && nodes.count(e);
    CHECK(ends_are_nodes, (id + ": every strut end is a node").c_str());
    // ...and every canonical node is the end of a strut of its own cell. (The CLOSED
    // node set may hold more: diamond's corners are reached by no strut of the cell
    // they cap, which is why the generator decides node ownership among the cells
    // that hold one of a node's struts.)
    bool nodes_used = true;
    for (const auto& n : prod.nodes) nodes_used = nodes_used && ends.count({n.x, n.y, n.z});
    CHECK(nodes_used, (id + ": every canonical node ends a strut of its cell").c_str());
  }

  // 3. The density basis: the production voxeliser reproduces the probe's build_cell
  //    voxel for voxel at the radius of a landed row (vpc48, L = 5 mm, the probe's
  //    own defaults). The probe compares in mm^2 and production in unit-cell units, so
  //    a tie could in principle differ by one voxel; it is asserted EXACT here so a
  //    real one is seen.
  for (const Case& c : cases) {
    if (c.topo == topopt::LatticeTopology::Octet) continue;  // octet keeps its own law
    const Lattice probe = make_lattice(c.id);
    const auto fs = periodic_fstruts(probe);
    for (double r_unit : {0.03, 0.06, 0.09}) {
      const VoxelGrid g = build_cell(fs, 5.0, 48, r_unit);
      const double rho_probe = volume_fraction(g);
      const double rho_prod =
          topopt::strut_cell_voxel_density(topopt::lattice_strut_cell(c.topo), r_unit, 48);
      char msg[160];
      std::snprintf(msg, sizeof msg, "%s: voxel density at r/L=%.2f equals the probe's "
                    "(%.6f vs %.6f)", c.id, r_unit, rho_prod, rho_probe);
      CHECK(rho_prod == rho_probe, msg);
    }
  }

  // 4. The tetragonal three refuse by name: no cell, no fallback.
  for (topopt::LatticeTopology t : {topopt::LatticeTopology::Bccz, topopt::LatticeTopology::Fccz,
                                    topopt::LatticeTopology::Reentrant}) {
    CHECK(!topopt::lattice_has_strut_cell(t), "tetragonal: no strut cell");
    bool threw = false;
    try {
      (void)topopt::lattice_strut_cell(t);
    } catch (const std::invalid_argument& e) {
      threw = std::string(e.what()).find(topopt::lattice_topology_name(t)) != std::string::npos;
    }
    CHECK(threw, "tetragonal: refuses, naming the type");
  }

  std::printf("\n%s: %d checks, %d failures\n", g_failures == 0 ? "PASS" : "FAIL", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
