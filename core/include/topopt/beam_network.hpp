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

// `node_welded` (optional, same length as the nodes) marks nodes joined by a
// MOMENT-TRANSFERRING tie -- to a shell, which has rotational dof. One such tie
// fully restrains a component, so the three-non-collinear-points rule does not apply
// to it: that rule exists only because a PINNED tie cannot carry moment.
BeamRestraintReport beam_network_restraint(
    const BeamNetwork& net, const std::vector<char>& node_tied,
    const std::vector<char>* node_welded = nullptr);

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

// ── ★ WHICH STRUTS HOLD THE LATTICE TOGETHER ─────────────────────────────────
// One flag per member: 1 when removing that member alone would split the network
// into more pieces than it already has -- a BRIDGE, in the graph sense.
//
// This exists to make pruning safe. The stress field says which struts carry load,
// and on a coarse lattice most of them carry almost none: measured on the M2 part,
// max/p50 is 611x at a 3 mm cell and 58,340x at 6 mm. The temptation is to delete
// everything idle. But an idle strut can be the ONLY thing connecting a loaded
// region to the rest, and deleting it does not redistribute the load -- it
// disconnects the part. Idle AND not a bridge is disposable; idle AND a bridge is
// structure, whatever its stress says.
//
// It is a graph property, so it costs one pass and no solve, which makes it usable
// as a gate BEFORE deciding whether a cell size is prunable at all. Parallel members
// between the same pair of nodes are handled: neither is a bridge, because removing
// one leaves the other.
std::vector<char> beam_network_bridges(const BeamNetwork& net);

// ── ★ NOT `cells_per_member_floor`. TWO DIFFERENT NUMBERS, TWO DIFFERENT QUESTIONS ──
// A contiguity rule of the form "N cells across the region's thinnest dimension" will
// be read as the same thing as `cell_plan.hpp`'s `cells_per_member_floor` (= 5 for
// octet). It is not, and confusing them would apply one's threshold to the other's
// question:
//
//   cells_per_member_floor  — HOMOGENIZATION ACCURACY. How many cells a member needs
//                             across it before the homogenised stiffness of the
//                             lattice is a usable stand-in for the real thing. It
//                             comes from PR 235's bending convergence study and it
//                             governs whether a SOLVE about the lattice can be
//                             believed.
//
//   contiguity cells-across — GEOMETRIC CONNECTEDNESS. How many cells fit across the
//                             region before the traced curves stop having room to
//                             route around one another, at which point almost every
//                             strut becomes the only path to what is past it (93.7%
//                             bridges at 2.0 cells across on the M2). It governs
//                             whether the geometry is a LATTICE at all, and it says
//                             nothing about homogenization.
//
// They are not interchangeable and neither bounds the other. A plan can satisfy the
// homogenization floor and still be geometrically shattered, and vice versa.
//
// ── ★ AND CELLS-ACROSS IS UNIFORM-ONLY. IT READS MATERIAL, NOT GEOMETRY ──────────
// Across a UNIFORM sweep, cells-across and total strut length fall together
// monotonically, so that sweep cannot say which quantity the rule is actually
// reading. GRADED plans separate them, and there the cells-across form breaks.
// Scored against the four measured graded rows on the M2 (top-2 share):
//
//   candidate input          3->4     3->5     3->6     3->8    verdict
//   measured top-2          98.17%   96.91%   94.63%   91.20%
//   cells-across, COARSE end   3.0      2.4      2.0      1.5    refuses 3 of 4
//   cells-across, FINE end     4.0      4.0      4.0      4.0    accepts everything,
//                                                               including 3->50
//   total LENGTH (interp.)   96.25%   93.92%   92.57%   90.63%   within 0.6-3.0 pts
//   segment COUNT (interp.)  96.55%   94.28%   92.78%   90.39%   within 0.8-2.6 pts
//
// So the gate reads TOTAL MATERIAL. Cells-across is a proxy that happens to track it
// when the cell is constant, and it must not be applied to a graded plan: score a
// grade by its length (or by the effective uniform cell that length implies), never
// by either end of its range.

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
  // ★ OPTIONAL PER-FACET THICKNESS, one entry per triangle. Empty means every facet
  // uses the patch thickness. A skin meshed from voxels is one or two cells deep
  // depending where you stand, so it needs this; a flat analytic patch does not.
  // The mesh no longer has to be PLANAR either -- the assembly takes each facet's
  // frame from its own three nodes, so a patch may be a folded or curved surface.
  std::vector<double> tri_thickness;
};

// ── ★ THE SKIN AS THE GENERATOR ACTUALLY BUILT IT ────────────────────────────
// Build the grade-to-solid skin's mid-surface from the voxels the lattice generator
// FLAGGED as skin, rather than from the lattice region's outline.
//
// This exists because deriving it from the region outline was measured wrong on the
// real part: it laid a full sheet across the region's OPEN outer face (the part ends
// at y=3.10 mm, the sheet was placed at y=3.68), made the far sheet 2.8x larger than
// the skin actually there (13,920 mm^2 against 5,013), and omitted the side walls
// entirely -- about 60% of the real skin. The result carried 92,470 mm^3 of plate
// against 42,225 mm^3 of real skin (219%), which stiffens the part, unloads the
// struts, and put peak strut stress at 0.31 MPa where the same geometry meshed as
// hex gives 3.40 MPa.
//
// The generator knows exactly where the skin is -- it decided it -- so read that
// instead of re-deriving it. `skin_mask` is one flag per voxel. Each run of skin
// cells through its own thinnest direction becomes one facet at the run's centre,
// carrying that run's depth as its thickness, so the mesh has the skin's real shape
// AND its real mass. Facets are welded within `weld_tol_mm` (default 0.75 cells) so
// the surface comes out as ONE connected shell across its folds rather than a pile
// of disconnected plates; the returned mesh is NOT planar, which is why the assembly
// takes each facet's frame from its own nodes.
// ★ GRADE-TO-SOLID IS ALWAYS A PLATE. His rule, and it is a RULE, not a property of
// one part: the grade-to-solid wraps every side that outlines the lattice region's
// shape. Where the model continues beyond such a face, it is a plate AND THEN hex --
// the plate bonded to the solid behind it -- not hex instead of a plate. The only
// face with no plate is one where the lattice is genuinely exposed, which is the
// face you look at; skinning that would make the aesthetics worthless.
//
// I briefly special-cased the DEPTH face of this part to hex because its skin cells
// are thin along the region normal. That fitted one model and would have been wrong
// on the next: a front or back that is partially covered still grades to shape.
// `design_thickness_mm`, when positive, is the thickness the skin was DESIGNED to
// have, and every facet takes it. Without it a facet is as thick as the run of cells
// it stands for, which is quantised to whole voxels: on a 1.705 mm grid a 2.0 mm rim
// comes out 1.705 mm or 3.41 mm and never 2.0. Plate bending goes as t^3, so that is
// 0.62x too floppy or 4.9x too stiff -- wrong in both directions, on the property a
// stiffening skin exists for. The MASS still matches the cells either way, which is
// why a volume check does not catch it.
ShellMesh mesh_skin_midsurface(const VoxelGrid& grid, const std::vector<char>& skin_mask,
                               double weld_tol_mm = -1.0,
                               double design_thickness_mm = -1.0);

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
  // ★ COMPLIANCE F.u -- the work the load does on the WHOLE assembly, and the only
  // honest single-number stiffness for this model. A peak deflection is a MAX over
  // nodes, so one floppy tongue of skin dominates it: measured, that made an all-hex
  // skin look 14x SOFTER than no skin at all, which cannot happen. Lower is stiffer.
  double compliance = 0.0;
  // ★ WHAT LANDED, AND WHAT DID NOT. A support or a load whose node is not part of
  // the meshed solid used to be skipped in silence. That is how a model gets solved
  // with its load missing and still reports "converged": meshing the skin as plates
  // takes those voxels OUT of the hex mesh, so every load that lands on the skin --
  // and the loaded face IS skin -- simply disappeared. Counted here, and refused
  // above kLoadDropRefuseFraction of the applied force.
  std::size_t bcs_applied = 0, bcs_dropped = 0;
  std::size_t loads_applied = 0, loads_dropped = 0;
  double load_dropped_fraction = 0.0;
  std::size_t loads_on_shell = 0, loads_on_beam = 0;  // re-homed off the solid
  // ★ HOW FAR A LOAD ACTUALLY HAD TO REACH to find material, in mm. `load_reach_mm`
  // is a single number and a GRADED lattice has no single cell, so the safe choice
  // is to pass the COARSEST cell -- the nearest material is always taken, so a
  // generous cap costs nothing where cells are fine. This reports what the cap was
  // actually used for: if it approaches the cap, loads are being attached across
  // pores and the number deserves a look rather than a shrug.
  double load_reach_used_max = 0.0;   // by |force|, not by count
  int peak_member = -1;
  std::size_t beam_nodes_tied = 0;
  std::size_t beam_nodes_welded_to_shell = 0;   // moment-transferring joints
  std::size_t shell_nodes = 0, shell_triangles = 0;
  std::size_t shell_nodes_tied = 0;   // skin nodes bonded into the solid mesh
  std::size_t floating_dof = 0;       // free dof reaching no support at all
  // ★ SOLID ISLANDS HANGING ON A CORNER. Voxels that touch only at an edge or a
  // corner share a line or a point: connected to a union-find over shared nodes,
  // a HINGE in the physics. Those pieces are the null space that made every
  // preconditioner stall at the same floor and then diverge. They are dropped
  // (they reach no support, so they carry no load) and counted here.
  std::size_t solid_islands_dropped = 0;    // face-connected pieces removed
  std::size_t solid_islands_elements = 0;   // hex elements in them
  double solid_islands_fraction = 0.0;      // of the meshed solid, by element count
  std::string preconditioner;         // which one actually ran
  // Where the residual lives when the solve stops: the share carried by each
  // element family, and the single worst dof. A mechanism shows as one family
  // holding nearly all of it.
  double residual_share_solid = 0.0, residual_share_shell = 0.0, residual_share_beam = 0.0;
  int worst_residual_dof = -1, worst_residual_node = -1, worst_residual_component = -1;
  std::string worst_residual_family;
  double matrix_asymmetry = 0.0;      // max |K_ij - K_ji| / max|K|; CG needs ~0
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

// ★ THE THREE-WAY MODEL. A face prism cuts the part into two pieces, and each
// piece wants a different element:
//
//   OUTSIDE the prism   the original model, CHUNKY -- median 27 mm thick on the M2
//                       stand, t/span about 1/7. Solid hex, and the job's own
//                       resolution is ample.
//   THE GRADE-TO-SOLID  a thin plate bounding the lattice: 2 mm on a 194 mm span,
//                       t/span 1/97. It is only 1.17 VOXELS thick, and a single hex
//                       through the thickness is a famously poor bending element --
//                       so the one part of the structure that actually flexes was
//                       being represented by the element least able to represent it.
//                       SHELL.
//   THE LATTICE         struts. BEAMS, exact at any resolution because they are
//                       never meshed.
//
// AND THE SKIN IS WHERE THE LATTICE ATTACHES, which is the second reason it must be
// a shell: a hex node has no rotational dof, so a beam tied to it can only be PINNED
// (measured nullity 10 for one tie, and the "three non-collinear ties per component"
// rule this file enforces exists only because of that). A shell node HAS rotations,
// so the joint is properly welded -- nullity 6 from a SINGLE point.
//
// `shells` may be empty, which is the pure hex+beam path, byte-identical to before.
// ★ STAGE CHECKPOINTS. The CG is only the last phase; assembly, tie construction,
// reordering and the preconditioner all precede it, and a run that is slow or wrong
// there looks the same from outside as one that is slow in the solve. Each stage
// reports its elapsed time AND a size, because "slow" is only meaningful next to
// "how much" -- 2 s to weld 22 k nodes is fine, 2 s to weld 200 is not.
struct SolveStage {
  void (*fn)(const char* stage, double seconds, double size, void* user) = nullptr;
  void* user = nullptr;
};

// ★ PROGRESS. A solve that runs for tens of minutes and prints nothing until it
// exits is indistinguishable, while running, from one that has stalled. Every long
// run in this codebase's history has been opaque in exactly that way, and the failed
// ones cost the most because a stall looked identical to slow progress until the
// hour was up. Set a callback and the CG reports its iteration and RELATIVE residual
// as it goes; return false from it to abort the solve cleanly (reported as a
// refusal, never as a converged answer).
struct CgProgress {
  // called every `every` iterations, and once on the final iteration
  bool (*fn)(int iteration, double relative_residual, void* user) = nullptr;
  void* user = nullptr;
  int every = 100;
};

struct ShellPatch {
  ShellMesh mesh;
  double thickness_mm = 0.0;   // overrides mesh.thickness_mm when > 0
};

CoupledLatticeSolve solve_coupled_lattice(
    const VoxelGrid& grid, const std::vector<char>& hex_mask,
    const BeamNetwork& net, const std::vector<DirichletBC>& bcs,
    const std::vector<NodalLoad>& loads, double youngs_modulus, double poisson,
    double shear_k, double cg_tolerance, int cg_max_iterations,
    const std::vector<double>* hex_solid_fraction = nullptr,
    const std::vector<ShellPatch>* shells = nullptr,
    // ★ HOW FAR A LOAD MAY REACH TO FIND MATERIAL. A load is declared on a GRID
    // NODE, but where the model carries a lattice the material under that node is a
    // STRUT, and the nearest strut can be most of a lattice cell away -- a surface
    // node can sit over a pore. Default is one voxel, which is right for a solid or
    // a plate and far too tight for a 6 mm lattice on a 1.7 mm grid: measured, 34.9%
    // of the applied force still had nowhere to go. Pass the lattice CELL size; the
    // caller knows it and this function must not guess. Loads that find nothing
    // within it are counted and refused, never silently dropped.
    double load_reach_mm = -1.0,
    const CgProgress* progress = nullptr,
    const SolveStage* stage = nullptr);

}  // namespace topopt

#endif  // TOPOPT_BEAM_NETWORK_HPP
