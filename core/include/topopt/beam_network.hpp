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
#include <array>
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
  // ★ A COMPONENT NEEDS THREE NON-COLLINEAR TIES. Pinned ties restrain TRANSLATION
  // only, so a component held at one point spins freely about it, and one held at
  // two (or at any number of COLLINEAR) points still spins about the line joining
  // them -- both proved in test_frame_element. Connectivity does not imply restraint
  // at the component level any more than it does at the member level: a real part
  // reached 0 untied components and still diverged, because many of those components
  // were held at too few points to be rigid.
  std::size_t components_underconstrained = 0;
  // Per-member flags, so a caller can DROP what cannot carry load rather than only
  // being told how much of it there is. A report that counts the problem without
  // naming it leaves the caller unable to act: measured on a real part, 108 of 385
  // components reached no tie and the only available response was to give up.
  std::vector<char> member_unrestrained;    // 1 = free to spin (a mechanism)
  std::vector<char> member_load_free;       // 1 = in a component that reaches no tie
  std::vector<char> member_underconstrained;  // 1 = in a component held at < 3
                                              //     non-collinear tie points
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

// ── ★ A WALL AS A SHELL MESH ────────────────────────────────────────────────
// A lattice region is a DECLARED PLANAR FACE -- origin, unit normal, an orthonormal
// (u, w) basis, half-extents, a thickness, and 2D loops in that basis. So its
// mid-surface is not something to extract from voxels: it IS the declaration, offset
// half a thickness along the normal. Meshing it is triangulating a 2D polygon, not
// meshing a volume.
//
// WHY THIS MATTERS. Filling a wall with solid voxels is the wrong element for a thin
// plate twice over. Solid scales with VOLUME and a shell with AREA -- on the M2
// stand 0.11 M hex against ~11 k triangles, and at 256 the difference between 14.6
// GB (past a 16 GB machine) and well under one. And a hex node has NO rotational
// dof, so a beam tied into solid can only be pinned: measured nullity 10 for one
// tie, against 6 when the same beam is tied to a SHELL node, which has rotations.
//
// THE MESH IS UNIFORM IN THE PLANE. `target_edge_mm` sets the spacing; points
// outside the loops are dropped, so a concave outline is respected. This is a
// structured triangulation, not a Delaunay mesher: it is adequate for a wall whose
// outline the caller already declared, and it has no dependencies.
struct ShellMesh {
  std::vector<Vec3> nodes;                 // on the mid-surface, in world coordinates
  struct Tri { int a = 0, b = 0, c = 0; };
  std::vector<Tri> triangles;
  double thickness_mm = 0.0;
  // The element frame: nodes projected into the face's own (u, w) basis, so a caller
  // can build the element in 2D and rotate with `basis_u` / `basis_w` / `normal`.
  std::vector<double> local_u, local_w;
  Vec3 basis_u{}, basis_w{}, normal{};
};

// `loops` are closed polygons in the face's (u, w) basis; loop 0 is the outline and
// any others are holes. Empty `loops` means the plain half_u x half_w rectangle.
// Throws std::invalid_argument on a non-physical extent, thickness or edge length.
ShellMesh mesh_face_region_midsurface(
    const Vec3& origin, const Vec3& normal, double half_u, double half_w,
    double thickness_mm, const std::vector<std::vector<std::array<double, 2>>>& loops,
    double target_edge_mm);

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
  // IC(0) is OFF unless TOPOPT_BEAM_IC=1: measured 9x SLOWER than Jacobi on a real
  // 6 mm lattice (598 s vs >1 h 29 m, killed unfinished). See beam_network.cpp.
  bool used_incomplete_cholesky = false;  // false = Jacobi (the default)
  double ic_shift = 0.0;                  // diagonal shift IC(0) needed to factor
  std::vector<double> solid_displacement;  // 3 per numbered solid node
  std::vector<double> member_stress_mpa;   // one per network member
  double peak_member_stress_mpa = 0.0;
  int peak_member = -1;
  std::size_t beam_nodes_tied = 0;
  // Of those, how many were NOT inside their host element and had their weights
  // clamped onto it. A clamped tie is a PROJECTION, not an interpolation: it does
  // not reproduce a linear field, and many of them can make the reduced system
  // rank-deficient however well the lattice is restrained.
  std::size_t beam_nodes_tied_by_projection = 0;
  BeamRestraintReport restraint;
};

// ★ PARTIAL FILL. `hex_solid_fraction` (optional, grid-indexed) is the fraction of
// each meshed voxel that is SOLID material — i.e. what is left after subtracting the
// volume the BEAM elements already represent. Pass nullptr for the old behaviour,
// every meshed voxel fully solid.
//
// WHY IT EXISTS. The struts are beams, so the hex mesh only has to carry the SOLID.
// But a strut runs THROUGH voxels, and a binary mask has only two wrong answers for
// those: call the voxel solid and the strut is counted TWICE (once as a beam, once
// as solid — the part reads stiffer than it is), or carve it out and real plastic is
// deleted, which on a 3 mm lattice fragmented the part into free-floating islands.
// Neither is a resolution problem: at the job's 1.705 mm pitch a 1 mm strut is 0.59
// voxels wide, and reaching one voxel per strut needs ~224 (9.7 GB) or 256 (14.6 GB,
// past this machine). A fraction says the true thing at ANY pitch.
//
// The scaling is LINEAR in the fraction (Voigt), which is an UPPER bound on the
// stiffness of a partially filled cell: where the hole sits matters and this ignores
// it. The error is therefore optimistic, but it is small and bounded, against a
// binary mask whose error is a factor of two in stiffness or a broken model.
// Fractions are clamped to [kHexFractionFloor, 1] so a voxel can never be singular.
inline constexpr double kHexFractionFloor = 1e-3;

CoupledLatticeSolve solve_coupled_lattice(
    const VoxelGrid& grid, const std::vector<char>& hex_mask,
    const BeamNetwork& net, const std::vector<DirichletBC>& bcs,
    const std::vector<NodalLoad>& loads, double youngs_modulus, double poisson,
    double shear_k, double cg_tolerance, int cg_max_iterations,
    const std::vector<double>* hex_solid_fraction = nullptr);

}  // namespace topopt

#endif  // TOPOPT_BEAM_NETWORK_HPP
