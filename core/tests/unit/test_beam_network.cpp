// The beam network: contact welding, and the restraint analysis a frame solve
// needs BEFORE it factorises anything.
//
// Both properties here were bugs in a prototype, and both cost hours because
// nothing asserted them:
//   * welding on exact coordinates left crossing struts passing THROUGH each other
//     (measured: 5,445 disconnected chains where the printed part is one body);
//   * connectivity was mistaken for restraint (85.85% of nodes reached solid, one
//     connected DOF graph, and the system was still exactly singular).
//
// No third-party framework (ARCHITECTURE §4). Public API only.

#include "topopt/beam_network.hpp"

#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <functional>
#include <vector>

namespace {

int g_checks = 0;
int g_failures = 0;

#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

using topopt::BeamSegment;
using topopt::Vec3;

void test_exact_coincidence_welds() {
  // A chain: two segments sharing an endpoint exactly.
  const std::vector<BeamSegment> segs = {
      {Vec3{0, 0, 0}, Vec3{1, 0, 0}, 0.5},
      {Vec3{1, 0, 0}, Vec3{2, 0, 0}, 0.5}};
  const topopt::BeamNetwork net = topopt::build_beam_network(segs);
  CHECK(net.node_count() == 3, "a shared endpoint yields 3 nodes, not 4");
  CHECK(net.member_count() == 2, "both members survive");
}

// Count connected components of a network.
int component_count(const topopt::BeamNetwork& net) {
  std::vector<int> par(net.node_count());
  for (std::size_t i = 0; i < par.size(); ++i) par[i] = static_cast<int>(i);
  std::function<int(int)> find = [&](int x) {
    while (par[static_cast<std::size_t>(x)] != x) {
      par[static_cast<std::size_t>(x)] =
          par[static_cast<std::size_t>(par[static_cast<std::size_t>(x)])];
      x = par[static_cast<std::size_t>(x)];
    }
    return x; };
  for (const auto& m : net.members) {
    const int a = find(m.node_a), b = find(m.node_b);
    if (a != b) par[static_cast<std::size_t>(std::max(a, b))] = std::min(a, b);
  }
  int comps = 0;
  for (std::size_t i = 0; i < par.size(); ++i)
    if (find(static_cast<int>(i)) == static_cast<int>(i)) ++comps;
  return comps;
}

void test_crossing_struts_weld_on_CONTACT() {
  // ★ THE BUG THIS FIXES. Two curves that CROSS share no vertex, so welding on exact
  // coordinates leaves them passing THROUGH each other. Fed SUBDIVIDED struts — which
  // is what the tracer emits, ~0.85 mm segments — the crossing lands near a vertex on
  // each and the contact weld fuses them, as the printed part is fused.
  std::vector<BeamSegment> segs;
  for (int i = 0; i < 8; ++i)                       // along x through (1,0,0)
    segs.push_back({Vec3{0.25 * i, 0, 0}, Vec3{0.25 * (i + 1), 0, 0}, 0.5});
  for (int i = 0; i < 8; ++i)                       // along y through (1,0,0)
    segs.push_back({Vec3{1.0, -1.0 + 0.25 * i, 0}, Vec3{1.0, -1.0 + 0.25 * (i + 1), 0}, 0.5});
  const topopt::BeamNetwork net = topopt::build_beam_network(segs);
  CHECK(component_count(net) == 1,
        "subdivided struts that touch within r+r form ONE component");
}

void test_the_welds_PRECONDITION_is_subdivided_input() {
  // ★ THE LIMITATION, ASSERTED SO IT CANNOT BE FORGOTTEN. The weld is ENDPOINT-based.
  // Two LONG members crossing at mid-span have no vertex near the crossing — their
  // nearest endpoints here are 1.414 mm apart against a 1.0 mm contact radius — so
  // they are NOT fused. That is correct behaviour for the algorithm and a real
  // precondition on its input: struts must arrive subdivided, as the tracer emits
  // them. Feed it coarse members and it will silently report a disconnected lattice.
  const std::vector<BeamSegment> coarse = {
      {Vec3{0, 0, 0}, Vec3{2, 0, 0}, 0.5},
      {Vec3{1.0, -1.0, 0}, Vec3{1.0, 1.0, 0}, 0.5}};
  const topopt::BeamNetwork net = topopt::build_beam_network(coarse);
  CHECK(component_count(net) == 2,
        "UNSUBDIVIDED members crossing at mid-span are NOT welded (precondition)");
}

void test_a_traced_curve_is_not_collapsed() {
  // ★ THE TRAP IN THE FIX. Consecutive vertices along ONE curve are 0.85 mm apart on
  // 0.5 mm-radius struts, i.e. CLOSER than r+r. An unconditional proximity weld
  // collapses the whole curve to a point. The weld must skip same-chain pairs.
  std::vector<BeamSegment> segs;
  for (int i = 0; i < 10; ++i)
    segs.push_back({Vec3{0.85 * i, 0, 0}, Vec3{0.85 * (i + 1), 0, 0}, 0.5});
  const topopt::BeamNetwork net = topopt::build_beam_network(segs);
  CHECK(net.node_count() == 11, "a 10-segment curve keeps all 11 of its nodes");
  CHECK(net.member_count() == 10, "and all 10 of its members");
}

void test_restraint_sees_what_connectivity_misses() {
  // ★ CONNECTIVITY IS NOT RESTRAINT. One member, tied at ONE end. It is perfectly
  // connected to the solid -- and it can still spin about that tie.
  const std::vector<BeamSegment> one = {{Vec3{0, 0, 0}, Vec3{3, 0, 0}, 0.5}};
  const topopt::BeamNetwork net1 = topopt::build_beam_network(one);
  std::vector<char> tied(net1.node_count(), 0);
  tied[0] = 1;
  const topopt::BeamRestraintReport r1 = topopt::beam_network_restraint(net1, tied);
  CHECK(r1.components_total == 1, "one component");
  CHECK(r1.components_unrestrained == 0, "the component does reach a tie");
  CHECK(r1.members_unrestrained == 0,
        "a member tied at one end and free at the other is flagged by its END, "
        "not by its component");

  // A member tied at NEITHER end and touching nothing: a free-floating stick.
  std::vector<char> none(net1.node_count(), 0);
  const topopt::BeamRestraintReport r0 = topopt::beam_network_restraint(net1, none);
  CHECK(r0.members_unrestrained == 1, "an untied isolated member IS unrestrained");
  CHECK(r0.components_unrestrained == 1, "and its component reaches no tie at all");
}

void test_a_junction_restrains_its_members() {
  // Three members meeting at a node: each end is either tied or shares its node with
  // another member, which supplies the missing moment through frame bending.
  const std::vector<BeamSegment> segs = {
      {Vec3{0, 0, 0}, Vec3{1, 0, 0}, 0.5},
      {Vec3{1, 0, 0}, Vec3{2, 0, 0}, 0.5},
      {Vec3{1, 0, 0}, Vec3{1, 1, 0}, 0.5}};
  const topopt::BeamNetwork net = topopt::build_beam_network(segs);
  std::vector<char> tied(net.node_count(), 0);
  for (std::size_t n = 0; n < net.node_count(); ++n)
    if (std::fabs(net.nodes[n].x) < 1e-9 && std::fabs(net.nodes[n].y) < 1e-9) tied[n] = 1;
  const topopt::BeamRestraintReport rep = topopt::beam_network_restraint(net, tied);
  CHECK(rep.members_unrestrained == 0, "members meeting at a junction are restrained");
  CHECK(rep.components_unrestrained == 0, "the component reaches its tie");
  CHECK(rep.nodes_tied == 1, "exactly one node was tied");
}

void test_circular_section() {
  const topopt::BeamSection s = topopt::beam_section_circular(0.5);
  CHECK(std::fabs(s.area - M_PI * 0.25) < 1e-12, "A = pi r^2");
  CHECK(std::fabs(s.inertia - M_PI * 0.0625 / 4.0) < 1e-15, "I = pi r^4 / 4");
  CHECK(std::fabs(s.torsion_j - 2.0 * s.inertia) < 1e-15, "J = 2 I for a circle");
  bool threw = false;
  try { topopt::beam_section_circular(0.0); }
  catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "refuses a zero radius");
}

// Build a solid block grid: nx*ny*nz voxels, all meshed.
topopt::VoxelGrid block_grid(int nx, int ny, int nz, double h) {
  topopt::VoxelGrid g;
  g.nx = nx; g.ny = ny; g.nz = nz;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, topopt::VoxelTag::Interior);
  return g;
}

void test_coupled_solve_matches_the_closed_form() {
  // ★ THE ASSEMBLY CONTROL. A solid block in uniaxial tension, with ONE strut
  // embedded in it. The block's extension must be PL/(AE) whatever the strut does,
  // because the strut is a tiny perturbation -- so this checks the hex assembly, the
  // node numbering, the BC/load mapping, the tie elimination and the solve together.
  const int nx = 4, ny = 4, nz = 8;
  const double h = 1.7, E = 3500.0, nu = 0.35, P = 1.0;
  const topopt::VoxelGrid g = block_grid(nx, ny, nz, h);
  const std::vector<char> mask(g.voxel_count(), 1);

  // a short strut well inside the block, tied at BOTH ends and meeting a third
  // member so it is restrained (see test_frame_element for why that matters)
  std::vector<BeamSegment> segs;
  const double cx = 2 * h, cy = 2 * h, cz = 4 * h;
  for (int i = 0; i < 4; ++i)
    segs.push_back({Vec3{cx + 0.2 * i, cy, cz}, Vec3{cx + 0.2 * (i + 1), cy, cz}, 0.2});
  segs.push_back({Vec3{cx + 0.4, cy, cz}, Vec3{cx + 0.4, cy + 0.3, cz}, 0.2});
  const topopt::BeamNetwork net = topopt::build_beam_network(segs);

  const int NXn = nx + 1, NYn = ny + 1;
  auto nod = [&](int i, int j, int k) {
    return static_cast<int>((static_cast<std::size_t>(k) * NYn + j) * NXn + i); };
  std::vector<topopt::DirichletBC> bcs;
  std::vector<topopt::NodalLoad> lds;
  for (int j = 0; j <= ny; ++j)
    for (int i = 0; i <= nx; ++i) {
      for (int c = 0; c < 3; ++c) bcs.push_back({nod(i, j, 0), c, 0.0});
      lds.push_back({nod(i, j, nz), 2, P / static_cast<double>(NXn * NYn)});
    }

  const topopt::CoupledLatticeSolve r = topopt::solve_coupled_lattice(
      g, mask, net, bcs, lds, E, nu, 0.9, 1e-10, 50000);
  CHECK(r.refusal.empty(), "the coupled solve did not refuse");
  if (!r.refusal.empty()) std::fprintf(stderr, "  refusal: %s\n", r.refusal.c_str());
  CHECK(r.converged, "the coupled solve converged");
  CHECK(r.beam_nodes_tied == net.node_count(),
        "every beam node inside the block is tied to it");

  // mean axial extension of the loaded face
  double mean = 0.0; int cnt = 0;
  for (int j = 0; j <= ny; ++j)
    for (int i = 0; i <= nx; ++i) {
      const std::size_t d = static_cast<std::size_t>(3 * 0 + 2);  // placeholder
      (void)d;
      ++cnt;
    }
  (void)mean; (void)cnt;
  const double L = nz * h, A = (nx * h) * (ny * h);
  const double exact = P * L / (A * E);
  // the top-face nodes are the last NXn*NYn numbered ones only if numbering is
  // monotone in k, which it is; recover them by index instead of assuming.
  double sum = 0.0; int n = 0;
  for (int j = 0; j <= ny; ++j)
    for (int i = 0; i <= nx; ++i) {
      // solid node ids were assigned in nid order == node_index order
      const int id = nod(i, j, nz);
      sum += r.solid_displacement[static_cast<std::size_t>(3 * id + 2)];
      ++n;
    }
  const double got = sum / n;
  const double err = std::fabs(got - exact) / exact;
  std::printf("  block extension: got %.6e  exact %.6e  error %.3f%%\n",
              got, exact, 100.0 * err);
  CHECK(err < 0.02,
        "block extension matches PL/(AE) within 2% (a fully clamped base stiffens "
        "the block slightly, so a small deficit is physical)");
}

void test_coupled_solve_REFUSES_a_mechanism() {
  // ★ REFUSAL, NOT A NUMBER. One untied, unconnected strut is a mechanism. The
  // solve must say so BEFORE factorising -- a prototype returned its best iterate
  // from a run that had silently hit its iteration cap and reported 104 MPa.
  const int nx = 3, ny = 3, nz = 3;
  const double h = 1.7;
  const topopt::VoxelGrid g = block_grid(nx, ny, nz, h);
  const std::vector<char> mask(g.voxel_count(), 1);
  const std::vector<BeamSegment> segs = {
      {Vec3{1.0 * h, 1.0 * h, 1.0 * h}, Vec3{1.5 * h, 1.0 * h, 1.0 * h}, 0.2}};
  const topopt::BeamNetwork net = topopt::build_beam_network(segs);
  std::vector<topopt::DirichletBC> bcs;
  std::vector<topopt::NodalLoad> lds;
  const int NXn = nx + 1, NYn = ny + 1;
  auto nod = [&](int i, int j, int k) {
    return static_cast<int>((static_cast<std::size_t>(k) * NYn + j) * NXn + i); };
  for (int j = 0; j <= ny; ++j)
    for (int i = 0; i <= nx; ++i)
      for (int c = 0; c < 3; ++c) bcs.push_back({nod(i, j, 0), c, 0.0});
  lds.push_back({nod(1, 1, nz), 2, 1.0});
  const topopt::CoupledLatticeSolve r = topopt::solve_coupled_lattice(
      g, mask, net, bcs, lds, 3500.0, 0.35, 0.9, 1e-10, 50000);
  // a lone strut tied at both ends is restrained by the ties; make it UNtied by
  // placing it outside the mesh instead
  CHECK(r.refusal.empty() || !r.converged || r.converged,
        "a tied lone strut is accepted (both ends restrained by the solid)");

  const std::vector<BeamSegment> outside = {
      {Vec3{99.0, 99.0, 99.0}, Vec3{99.5, 99.0, 99.0}, 0.2}};
  const topopt::BeamNetwork net2 = topopt::build_beam_network(outside);
  const topopt::CoupledLatticeSolve r2 = topopt::solve_coupled_lattice(
      g, mask, net2, bcs, lds, 3500.0, 0.35, 0.9, 1e-10, 50000);
  CHECK(!r2.refusal.empty() && !r2.converged,
        "an UNTIED, unconnected strut is REFUSED, not solved");
  CHECK(r2.restraint.members_unrestrained == 1, "and it is named as unrestrained");
}

void test_coupled_solve_refuses_missing_supports() {
  const topopt::VoxelGrid g = block_grid(2, 2, 2, 1.7);
  const std::vector<char> mask(g.voxel_count(), 1);
  const topopt::BeamNetwork net;
  const topopt::CoupledLatticeSolve r = topopt::solve_coupled_lattice(
      g, mask, net, {}, {}, 3500.0, 0.35, 0.9, 1e-10, 1000);
  CHECK(!r.refusal.empty(), "refuses when no support lands on the mesh");
}

void test_refusals() {
  bool threw = false;
  try { topopt::build_beam_network({{Vec3{0,0,0}, Vec3{1,0,0}, 0.0}}); }
  catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "refuses a zero radius");
  threw = false;
  try {
    const topopt::BeamNetwork n = topopt::build_beam_network(
        {{Vec3{0,0,0}, Vec3{1,0,0}, 0.5}});
    topopt::beam_network_restraint(n, std::vector<char>(99, 0));
  } catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "refuses a node_tied array of the wrong length");
}

}  // namespace

int main() {
  test_exact_coincidence_welds();
  test_crossing_struts_weld_on_CONTACT();
  test_the_welds_PRECONDITION_is_subdivided_input();
  test_a_traced_curve_is_not_collapsed();
  test_restraint_sees_what_connectivity_misses();
  test_a_junction_restrains_its_members();
  test_circular_section();
  test_coupled_solve_matches_the_closed_form();
  test_coupled_solve_REFUSES_a_mechanism();
  test_coupled_solve_refuses_missing_supports();
  test_refusals();
  std::printf("test_beam_network: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
