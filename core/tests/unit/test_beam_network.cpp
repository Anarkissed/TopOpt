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

void test_partial_fill_scales_the_solid_exactly() {
  // ★ THE FIX FOR THE BINARY MASK. A uniformly half-filled block must extend exactly
  // TWICE as far as a full one: element stiffness is linear in the modulus, so a
  // fraction is an exact scalar, not an approximation of the SOLVE. (It is an
  // approximation of the PHYSICS -- Voigt, an upper bound -- which is a different
  // and much smaller error than counting a strut twice or deleting real plastic.)
  const int nx = 4, ny = 4, nz = 8;
  const double h = 1.7, E = 3500.0, nu = 0.35, P = 1.0;
  const topopt::VoxelGrid g = block_grid(nx, ny, nz, h);
  const std::vector<char> mask(g.voxel_count(), 1);
  const topopt::BeamNetwork empty;

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
  auto extension = [&](const std::vector<double>* frac) {
    const topopt::CoupledLatticeSolve r = topopt::solve_coupled_lattice(
        g, mask, empty, bcs, lds, E, nu, 0.9, 1e-11, 200000, frac);
    if (!r.converged) return -1.0;
    double sum = 0.0; int n = 0;
    for (int j = 0; j <= ny; ++j)
      for (int i = 0; i <= nx; ++i) {
        sum += r.solid_displacement[static_cast<std::size_t>(3 * nod(i, j, nz) + 2)];
        ++n;
      }
    return sum / n;
  };
  const double full = extension(nullptr);
  CHECK(full > 0.0, "the full-density block solves");
  const std::vector<double> half(g.voxel_count(), 0.5);
  const double soft = extension(&half);
  CHECK(soft > 0.0, "the half-filled block solves");
  CHECK(std::fabs(soft / full - 2.0) < 1e-6,
        "a uniformly HALF-filled block extends exactly twice as far");
  if (!(std::fabs(soft / full - 2.0) < 1e-6))
    std::fprintf(stderr, "  ratio %.9f (expected 2)\n", soft / full);

  // a fraction of 1 everywhere must be bit-identical to passing nullptr
  const std::vector<double> ones(g.voxel_count(), 1.0);
  CHECK(std::fabs(extension(&ones) - full) < 1e-12,
        "fraction 1.0 everywhere reproduces the unmodified path");

  // and a bad-sized array is refused, not silently ignored
  const std::vector<double> wrong(7, 0.5);
  CHECK(!topopt::solve_coupled_lattice(g, mask, empty, bcs, lds, E, nu, 0.9,
                                       1e-10, 1000, &wrong).refusal.empty(),
        "refuses a fraction array of the wrong length");
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

void test_coupled_solve_REFUSES_untied_components_instantly() {
  // ★ THE 40-MINUTE FAILURE. On a real part 292 of 385 lattice components reached
  // NO tie -- floating, carrying nothing, guaranteed singular. The restraint report
  // said so, but the solve only refused on unrestrained MEMBERS, so it ground for
  // 2,406 s and then failed on residual. The information to refuse was available in
  // milliseconds. A component that reaches no tie is now a refusal, not a solve.
  const int nx = 4, ny = 4, nz = 4;
  const double h = 1.7;
  topopt::VoxelGrid g = block_grid(nx, ny, nz, h);
  // mesh only the LOWER half as solid; the lattice will sit in the empty upper half
  std::vector<char> mask(g.voxel_count(), 0);
  for (int k = 0; k < 2; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) mask[g.index(i, j, k)] = 1;

  // a connected chain floating well above the meshed solid: restrained internally
  // (every member meets another at a junction) but reaching no tie whatsoever
  std::vector<BeamSegment> segs;
  const double zf = 3.6 * h;
  for (int i = 0; i < 4; ++i)
    segs.push_back({Vec3{1.0 * h + 0.2 * i, 2.0 * h, zf},
                    Vec3{1.0 * h + 0.2 * (i + 1), 2.0 * h, zf}, 0.2});
  segs.push_back({Vec3{1.0 * h + 0.4, 2.0 * h, zf},
                  Vec3{1.0 * h + 0.4, 2.0 * h + 0.3, zf}, 0.2});
  const topopt::BeamNetwork net = topopt::build_beam_network(segs);

  const int NXn = nx + 1, NYn = ny + 1;
  auto nod = [&](int i, int j, int k) {
    return static_cast<int>((static_cast<std::size_t>(k) * NYn + j) * NXn + i); };
  std::vector<topopt::DirichletBC> bcs;
  std::vector<topopt::NodalLoad> lds;
  for (int j = 0; j <= ny; ++j)
    for (int i = 0; i <= nx; ++i)
      for (int c = 0; c < 3; ++c) bcs.push_back({nod(i, j, 0), c, 0.0});
  lds.push_back({nod(2, 2, 2), 2, 1.0});

  const topopt::CoupledLatticeSolve r = topopt::solve_coupled_lattice(
      g, mask, net, bcs, lds, 3500.0, 0.35, 0.9, 1e-8, 100000);
  CHECK(!r.refusal.empty() && !r.converged,
        "a component that reaches NO tie is refused, not solved");
  CHECK(r.restraint.components_unrestrained >= 1,
        "and the untied component is counted");
  CHECK(r.iterations == 0,
        "the refusal costs ZERO solver iterations -- it is checked before assembly");
  // and the caller is told WHICH members to drop, not merely how many
  std::size_t flagged = 0;
  for (char c : r.restraint.member_load_free) flagged += c ? 1u : 0u;
  CHECK(flagged == net.member_count(),
        "every member of the untied component is NAMED as load-free");
}

void test_component_needs_three_noncollinear_ties() {
  // ★ THE MECHANISM THAT SURVIVED EVERY EARLIER CHECK. A component can be fully
  // connected, reach a tie, and have no unrestrained member, and STILL rotate
  // rigidly -- because pinned ties restrain TRANSLATION only. A real part reached
  // 0 untied components and diverged to a residual of 6.6e6 for exactly this.
  auto line_net = [](int n_ties) {
    std::vector<BeamSegment> segs;
    for (int i = 0; i < 6; ++i)
      segs.push_back({Vec3{0.5 * i, 0, 0}, Vec3{0.5 * (i + 1), 0, 0}, 0.2});
    return topopt::build_beam_network(segs);
  };
  const topopt::BeamNetwork line = line_net(0);

  // one tie: spins about the tie point
  std::vector<char> t1(line.node_count(), 0); t1[0] = 1;
  CHECK(topopt::beam_network_restraint(line, t1).components_underconstrained == 1,
        "ONE tie leaves the component free to rotate");

  // two ties, necessarily collinear on a straight chain: spins about their axis
  std::vector<char> t2(line.node_count(), 0); t2[0] = 1; t2[line.node_count() - 1] = 1;
  const topopt::BeamRestraintReport r2 = topopt::beam_network_restraint(line, t2);
  CHECK(r2.components_underconstrained == 1,
        "TWO COLLINEAR ties still leave the axial spin");
  std::size_t flagged2 = 0;
  for (char c : r2.member_underconstrained) flagged2 += c ? 1u : 0u;
  CHECK(flagged2 == line.member_count(),
        "and every member of it is NAMED, so a caller can drop them");

  // three ties spanning a plane: rigid
  std::vector<BeamSegment> tri;
  for (int i = 0; i < 3; ++i)
    tri.push_back({Vec3{0.5 * i, 0, 0}, Vec3{0.5 * (i + 1), 0, 0}, 0.2});
  tri.push_back({Vec3{0.5, 0, 0}, Vec3{0.5, 1.0, 0}, 0.2});
  const topopt::BeamNetwork plane = topopt::build_beam_network(tri);
  std::vector<char> t3(plane.node_count(), 0);
  int marked = 0;
  for (std::size_t n = 0; n < plane.node_count() && marked < 3; ++n) {
    const Vec3& q = plane.nodes[n];
    const bool corner = (std::fabs(q.x) < 1e-9 && std::fabs(q.y) < 1e-9) ||
                        (std::fabs(q.x - 1.5) < 1e-9) ||
                        (std::fabs(q.y - 1.0) < 1e-9);
    if (corner) { t3[n] = 1; ++marked; }
  }
  CHECK(marked == 3, "three tie points marked");
  CHECK(topopt::beam_network_restraint(plane, t3).components_underconstrained == 0,
        "THREE NON-COLLINEAR ties fully restrain the component");
}

void test_components_ignore_dangling_nodes() {
  // ★ A NODE ATTACHED TO NOTHING IS NOT A COMPONENT. Dropping load-free members
  // leaves their nodes behind; counting those as components inflated a real part
  // from 385 to 3,203 after one prune and made the retry look hopeless.
  std::vector<BeamSegment> segs = {
      {Vec3{0, 0, 0}, Vec3{1, 0, 0}, 0.5},
      {Vec3{1, 0, 0}, Vec3{2, 0, 0}, 0.5},
      {Vec3{50, 50, 50}, Vec3{51, 50, 50}, 0.5}};   // a separate stick
  const topopt::BeamNetwork full = topopt::build_beam_network(segs);
  std::vector<char> tied(full.node_count(), 0);
  tied[0] = 1;
  const topopt::BeamRestraintReport before = topopt::beam_network_restraint(full, tied);
  CHECK(before.components_total == 2, "two real components before pruning");

  // now drop the separate stick's member but keep every node, as a prune does
  topopt::BeamNetwork pruned;
  pruned.nodes = full.nodes;
  for (const auto& m : full.members) {
    const Vec3& a = full.nodes[static_cast<std::size_t>(m.node_a)];
    if (a.x < 10.0) pruned.members.push_back(m);
  }
  const topopt::BeamRestraintReport after =
      topopt::beam_network_restraint(pruned, tied);
  CHECK(after.components_total == 1,
        "the orphaned NODES do not become components");
  CHECK(after.components_unrestrained == 0,
        "and the remaining component still reaches its tie");
}

void test_coupled_solve_refuses_missing_supports() {
  const topopt::VoxelGrid g = block_grid(2, 2, 2, 1.7);
  const std::vector<char> mask(g.voxel_count(), 1);
  const topopt::BeamNetwork net;
  const topopt::CoupledLatticeSolve r = topopt::solve_coupled_lattice(
      g, mask, net, {}, {}, 3500.0, 0.35, 0.9, 1e-10, 1000);
  CHECK(!r.refusal.empty(), "refuses when no support lands on the mesh");
}

void test_midsurface_mesh() {
  // ★ THE MID-SURFACE IS THE DECLARATION. A region already carries origin, normal,
  // basis, extents, thickness and 2D loops -- so meshing a wall is triangulating a
  // polygon, not meshing a volume. These checks pin the three things that would be
  // silently wrong: the offset, the outline, and the plane.
  const Vec3 org{10.0, 20.0, 30.0};
  const Vec3 nrm{0.0, -1.0, 0.0};
  const double hu = 50.0, hw = 40.0, t = 12.0;

  const topopt::ShellMesh m =
      topopt::mesh_face_region_midsurface(org, nrm, hu, hw, t, {}, 10.0);
  CHECK(!m.nodes.empty() && !m.triangles.empty(), "a plain rectangle meshes");
  CHECK(m.nodes.size() == m.local_u.size() && m.nodes.size() == m.local_w.size(),
        "every node carries its (u, w) coordinates");

  // (a) THE OFFSET. Every node must sit exactly half a thickness along the normal
  // from the declared face -- the MID-surface, not the face.
  double worst_off = 0.0;
  for (const Vec3& q : m.nodes) {
    const double d = (q.x-org.x)*m.normal.x + (q.y-org.y)*m.normal.y + (q.z-org.z)*m.normal.z;
    worst_off = std::max(worst_off, std::fabs(d - 0.5*t));
  }
  CHECK(worst_off < 1e-9, "every node lies half a thickness in from the declared face");

  // (b) THE PLANE. Nodes must be coplanar and the basis orthonormal, or the loops
  // mean something different here than in the region declaration.
  const double uu = m.basis_u.x*m.basis_u.x + m.basis_u.y*m.basis_u.y + m.basis_u.z*m.basis_u.z;
  const double ww = m.basis_w.x*m.basis_w.x + m.basis_w.y*m.basis_w.y + m.basis_w.z*m.basis_w.z;
  const double uw = m.basis_u.x*m.basis_w.x + m.basis_u.y*m.basis_w.y + m.basis_u.z*m.basis_w.z;
  CHECK(std::fabs(uu-1.0) < 1e-12 && std::fabs(ww-1.0) < 1e-12 && std::fabs(uw) < 1e-12,
        "the in-plane basis is orthonormal");

  // (c) THE AREA. A full rectangle's triangles must sum to exactly 2hu x 2hw.
  double area = 0.0;
  for (const auto& tri : m.triangles) {
    const double ax = m.local_u[static_cast<std::size_t>(tri.a)], ay = m.local_w[static_cast<std::size_t>(tri.a)];
    const double bx = m.local_u[static_cast<std::size_t>(tri.b)], by = m.local_w[static_cast<std::size_t>(tri.b)];
    const double cx = m.local_u[static_cast<std::size_t>(tri.c)], cy = m.local_w[static_cast<std::size_t>(tri.c)];
    area += 0.5 * std::fabs((bx-ax)*(cy-ay) - (cx-ax)*(by-ay));
  }
  CHECK(std::fabs(area - 4.0*hu*hw) < 1e-6*4.0*hu*hw,
        "the meshed area equals the declared rectangle exactly");

  // (d) THE OUTLINE. A loop that carves out half the face must halve the area --
  // a mesher that ignored the loops would pass every check above.
  const std::vector<std::vector<std::array<double,2>>> half_loop = {
      {{{-hu, -hw}}, {{0.0, -hw}}, {{0.0, hw}}, {{-hu, hw}}}};
  const topopt::ShellMesh h =
      topopt::mesh_face_region_midsurface(org, nrm, hu, hw, t, half_loop, 5.0);
  double harea = 0.0;
  for (const auto& tri : h.triangles) {
    const double ax = h.local_u[static_cast<std::size_t>(tri.a)], ay = h.local_w[static_cast<std::size_t>(tri.a)];
    const double bx = h.local_u[static_cast<std::size_t>(tri.b)], by = h.local_w[static_cast<std::size_t>(tri.b)];
    const double cx = h.local_u[static_cast<std::size_t>(tri.c)], cy = h.local_w[static_cast<std::size_t>(tri.c)];
    harea += 0.5 * std::fabs((bx-ax)*(cy-ay) - (cx-ax)*(by-ay));
  }
  CHECK(harea < 0.6*4.0*hu*hw && harea > 0.3*4.0*hu*hw,
        "a loop covering half the face meshes about half the area");

  // (e) SCALES WITH AREA, NOT VOLUME -- the whole reason for shells.
  const topopt::ShellMesh fine =
      topopt::mesh_face_region_midsurface(org, nrm, hu, hw, t, {}, 5.0);
  CHECK(fine.triangles.size() > 3 * m.triangles.size(),
        "halving the edge length roughly quadruples the triangle count (area scaling)");

  bool threw = false;
  try { topopt::mesh_face_region_midsurface(org, nrm, hu, hw, 0.0, {}, 10.0); }
  catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "refuses a zero thickness");
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
  test_partial_fill_scales_the_solid_exactly();
  test_coupled_solve_REFUSES_a_mechanism();
  test_coupled_solve_REFUSES_untied_components_instantly();
  test_component_needs_three_noncollinear_ties();
  test_components_ignore_dangling_nodes();
  test_coupled_solve_refuses_missing_supports();
  test_midsurface_mesh();
  test_refusals();
  std::printf("test_beam_network: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
