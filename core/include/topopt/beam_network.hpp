#ifndef TOPOPT_BEAM_NETWORK_HPP
#define TOPOPT_BEAM_NETWORK_HPP

// A lattice as a BEAM NETWORK, plus the restraint analysis a frame solve needs
// before it factorises anything (organic-lattice beam FEA).
//
// WHY THIS EXISTS. A strut lattice analysed with frame elements is ~440x cheaper
// than resolving the struts in solid voxels (measured on the M2 stand: 421 k DOF
// against 184 M at 3 voxels per 1 mm strut), and needs no meshing at all because the
// generator already emits centrelines and radii. But two failure modes will produce
// a singular system, and BOTH were hit by a prototype before either was checked for:
//
//   1. WELDING. Two struts that cross in space essentially never share a polyline
//      vertex, so welding on exact coincidence leaves them passing THROUGH each
//      other. Measured on a real 3 mm lattice: 454 of 111,909 nodes had degree > 2,
//      i.e. 5,445 disconnected chains, while 157,313 node pairs sat within r+r of
//      each other. In the printed part those struts overlap and are fused, so they
//      must share a node here. Weld on CONTACT, not on coordinates.
//      PRECONDITION: the weld is ENDPOINT-based, so struts must arrive SUBDIVIDED.
//      Two long members crossing at mid-span have no vertex near the crossing and
//      are NOT fused (asserted in test_beam_network). The tracer emits ~0.85 mm
//      segments, which satisfies this; coarse input would silently report a
//      disconnected lattice.
//
//   2. RESTRAINT. A pinned tie into solid transmits force but not moment, so a
//      member held at one point spins about it (3 modes) and a member held at two
//      points still spins about the line joining them (1 mode) — both proved in
//      test_frame_element. Connectivity does NOT imply restraint: a prototype had
//      85.85% of nodes "reaching solid" and one connected DOF graph, and was still
//      exactly singular. Ask about ROTATION, not just about load paths.

#include <cstddef>
#include <string>
#include <vector>

#include "topopt/fea.hpp"    // DirichletBC, NodalLoad, FrameStiffness
#include "topopt/mesh.hpp"   // Vec3
#include "topopt/voxel.hpp"  // VoxelGrid

namespace topopt {

// One strut segment as the generator emits it: a centreline pair and a radius.
struct BeamSegment {
  Vec3 a{}, b{};
  double radius_mm = 0.0;
};

struct BeamNetwork {
  struct Member {
    int node_a = 0, node_b = 0;
    double radius_mm = 0.0;
  };
  std::vector<Vec3> nodes;
  std::vector<Member> members;

  std::size_t node_count() const { return nodes.size(); }
  std::size_t member_count() const { return members.size(); }
};

// Build the network, welding endpoints that COINCIDE and endpoints that TOUCH
// (centre distance <= r_a + r_b) but belong to different chains. The different-chain
// rule is load-bearing: consecutive vertices along one traced curve are closer than
// r+r, so an unconditional proximity weld collapses every curve to a point.
// Zero-length members are dropped. Throws std::invalid_argument on a non-positive
// radius.
BeamNetwork build_beam_network(const std::vector<BeamSegment>& segments);

// Per-member restraint verdict. `tie` marks nodes tied to solid (see
// frame_solid_tie); a member is UNRESTRAINED when its own connectivity cannot stop
// it rotating: fewer than two independent attachment points, or two that are
// collinear with nothing else meeting it.
struct BeamRestraintReport {
  std::size_t nodes_tied = 0;
  std::size_t members_total = 0;
  std::size_t members_unrestrained = 0;   // would leave a mechanism in the solve
  std::size_t components_total = 0;
  std::size_t components_unrestrained = 0;  // no tie at all: carries no load
  // Grid-free per-member flag: 0 = restrained, 1 = free to spin.
  std::vector<char> member_unrestrained;
};

BeamRestraintReport beam_network_restraint(const BeamNetwork& net,
                                           const std::vector<char>& node_tied);

// ── ★ WHAT THE SOLVE NEEDS FROM THE NETWORK ─────────────────────────────────
// The coupled system is [solid hex dof][beam frame dof] with the tied beam
// TRANSLATIONS eliminated onto their host element's corners (frame_solid_tie). This
// is the plan the assembly follows, recorded here because the ORDER matters and a
// prototype got it wrong four times:
//
//   1. build_beam_network()          weld on contact, not coordinates
//   2. tie each node                 frame_solid_tie() into the host hex
//   3. beam_network_restraint()      REFUSE or drop mechanisms BEFORE factorising
//   4. assemble + eliminate          hex + frame, slaved translations
//   5. solve, then recover strut stress from END FORCES (f = k u), never from
//      end rotations — that error reads as exact displacement and 150x stress.
//
// Step 3 is not optional and is not an optimisation. A pinned tie leaves a member
// held at one point free to spin (3 modes) and a member held at two collinear points
// free to spin about its axis (1 mode) — both proved in test_frame_element. A
// prototype that skipped this step produced an exactly singular system on a real
// part with 85.85% connectivity and ONE connected DOF graph, and the cause took five
// wrong guesses to find. Connectivity answers "is there a load path"; restraint
// answers "can it rotate". They are different questions.

// The per-member section properties a frame element needs, from a radius. Circular
// solid section: A = pi r^2, I = pi r^4/4, J = 2I.
struct BeamSection {
  double area = 0.0;
  double inertia = 0.0;
  double torsion_j = 0.0;
};

BeamSection beam_section_circular(double radius_mm);

// ── ★ THE COUPLED SOLVE ─────────────────────────────────────────────────────
// Solid hex elements for the part, frame elements for the lattice, tied together.
// No homogenisation anywhere — De Biasi et al. (Mater. Des. 255, 2025) measured
// homogenised lattice models at >15% error in the best case and >50% in many, and
// blind to the topology-induced stress concentration a margin depends on.
//
// `hex_mask` is grid-indexed: non-zero marks a voxel meshed as SOLID. Voxels filled
// by the lattice must be zero there or their material is counted twice. BCs and
// loads are node-indexed on `grid` exactly as fea_solve_cg takes them.
//
// REFUSES rather than returns a number when the model cannot carry load: a mechanism
// survived the restraint check, supports or loads missed the mesh, or the solve did
// not reach `cg_tolerance`. A prototype that returned its best iterate instead
// reported 104 MPa from a run that had silently hit its iteration cap.
struct CoupledLatticeSolve {
  bool converged = false;
  std::string refusal;              // empty on success; why not, otherwise
  double residual = 0.0;
  int iterations = 0;
  std::vector<double> solid_displacement;  // 3 per numbered solid node
  std::vector<double> member_stress_mpa;   // one per network member
  double peak_member_stress_mpa = 0.0;
  int peak_member = -1;
  std::size_t beam_nodes_tied = 0;
  BeamRestraintReport restraint;
};

CoupledLatticeSolve solve_coupled_lattice(
    const VoxelGrid& grid, const std::vector<char>& hex_mask,
    const BeamNetwork& net, const std::vector<DirichletBC>& bcs,
    const std::vector<NodalLoad>& loads, double youngs_modulus, double poisson,
    double shear_k, double cg_tolerance, int cg_max_iterations);

}  // namespace topopt

#endif  // TOPOPT_BEAM_NETWORK_HPP
