#ifndef TOPOPT_ORGANIC_LATTICE_HPP
#define TOPOPT_ORGANIC_LATTICE_HPP

// ★ THE ORGANIC LATTICE — STRUTS TRACED ALONG THE STRESS FIELD
// (task 2026-08-21-organic-lattice, §1.)
//
// The third lattice algorithm. DOUBLED (cell_plan.hpp) and STEPPED
// (lattice_algorithm.hpp) both start from a CELL and fill the part with it. This one
// has no cell at all: it EIGEN-DECOMPOSES the per-voxel stress tensor, TRACES curves
// along the three principal directions, and SPACES those curves by a field. Cell size
// is not an input here — it is an OUTPUT, read off the achieved spacing.
//
// ── WHY, AND THE EVIDENCE THAT IT IS NOT A SPECULATION ──────────────────────────
// Daynes, Feih, Lu & Wei, "Optimisation of functionally graded lattice structures
// using isostatic lines", Materials & Design 127:215-223 (2017),
// doi:10.1016/j.matdes.2017.04.082, measured +101 % STIFFNESS and +172 % STRENGTH
// against a uniform-cell core OF THE SAME DENSITY by grading cell size, aspect ratio
// AND orientation along isostatic lines. The 3D construction is Daynes et al., CMAME
// 354:689-705 (2019), doi:10.1016/j.cma.2019.05.053.
//
// The SPACING mechanism is Jobard & Lefer, "Creating Evenly-Spaced Streamlines of
// Arbitrary Density" (1997): seed the next curve at `d_sep` from an existing one and
// stop tracing when it comes within `d_test`. The spacing is the INPUT and the layout
// falls out of it. CURVY (arXiv:2102.10013) is the same idea with `d_sep` driven by a
// FIELD rather than a global constant, in a 3D-printing context, and that is the form
// used here: `spacing_mm` is per voxel.
//
// ── ★ PRINTABILITY IS NOT AN OPEN QUESTION ON THIS MACHINE ─────────────────────
// The maintainer printed a traced coupon with a 41.78 mm LONGEST UNSUPPORTED RUN,
// supports off, and it came out clean
// (evidence/2026-08-20-lattice-only-grading/r4b_PRINT_RESULT.md). That is a direct
// refutation of the 45-degree overhang rule as a HARD blocker here, which is why the
// clamp below is a PARAMETER that DEFAULTS TO DISARMED and why the 45-degree figure
// survives only as the counterfactual the report is measured against. Re-arming it by
// default would discard the stress alignment that is the entire justification for the
// method, in the name of a constraint this printer demonstrably does not have.
//
// ── ★ DETERMINISTIC, AND THE ORDERS ARE PART OF THE CONTRACT (§5) ──────────────
// `cell_plan.hpp` and the grading law are byte-identical by design; this joins them.
// Every order below is FIXED and stated, there is no RNG, no thread and no sampled
// estimate anywhere:
//   SEED ORDER   — the FIRST seed of a family is the candidate voxel with the largest
//                  |eigenvalue| for that family, ties broken by ASCENDING VOXEL INDEX.
//                  Every later seed comes off a FIFO queue filled by walking an
//                  accepted curve's points in order and offering, at each seed
//                  station, the four transverse offsets (+e_a, -e_a, +e_b, -e_b) in
//                  that order.
//   TRACE ORDER  — families 0,1,2 in that order, each family traced to exhaustion
//                  before the next starts. Each curve is traced FORWARD from its seed
//                  and then BACKWARD, and the two halves are joined back-to-front.
//   THIN ORDER   — DESCENDING curve length, ties broken by ASCENDING curve index, so
//                  the long load paths survive (§1e).
//   CONNECT ORDER— ascending (curve_a, curve_b) with curve_a < curve_b.
// The density rasteriser is a FIXED-STEP quadrature in a fixed traversal order, never
// a sample.

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "topopt/mesh.hpp"   // Vec3
#include "topopt/voxel.hpp"  // VoxelGrid

namespace topopt {

// ── the constants, named so they can be argued with ─────────────────────────────

// Jobard-Lefer's `d_test` as a multiple of `d_sep`: tracing STOPS when the curve comes
// within this fraction of the local separation of another curve of the same family.
// 0.5 is the value Jobard & Lefer report as their default.
inline constexpr double kOrganicTestRatio = 0.5;
// A new seed is offered at this multiple of the local `d_sep`, transverse to the
// parent curve — the "seed at d_sep" half of the same rule.
inline constexpr double kOrganicSeedRatio = 1.0;
// Two curves of DIFFERENT families are joined when their nearest approach is within
// this multiple of the local `d_sep` (§1d). At 1.0 a connector is never longer than
// one separation, which is what keeps the connector population the same scale as the
// curve population rather than a quadratic blow-up.
inline constexpr double kOrganicConnectRatio = 1.0;
// The RK4 step, as a fraction of the local `d_sep`. Small enough that the polyline's
// vertex spacing is well under `d_test` (so a vertex-based proximity query cannot miss
// a crossing by more than half a step), large enough that a curve across a 200 mm part
// is a few hundred points.
inline constexpr double kOrganicStepRatio = 0.35;
// A traced curve shorter than this multiple of the local `d_sep` is discarded as a
// stub: below one separation it is shorter than the gap to its own neighbour and
// carries no span.
// ★ IT IS 1.0 AND NOT 2.0, AND THAT IS MEASURED. At 2.0 a curve had to be twice the
// separation long to survive — and the maintainer's lattice regions are 4 mm-deep face
// slabs, so the family pointing THROUGH the slab produces ~4 mm curves against a ~5.5
// mm threshold and every one of them was discarded. Measured on his part at 2.0:
// curves_per_family = [28, 534, 0]. The third family is exactly the one that braces
// the other two through the thickness, so discarding it is what left 469 of 562 curves
// with no connection at all.
inline constexpr double kOrganicMinLengthRatio = 1.0;

// ★ LOOP AND SPIRAL DETECTION — THE PART OF THE PUBLISHED ALGORITHM I OMITTED.
// vtkEvenlySpacedStreamlines2D carries `LoopAngle` (20 degrees) and a
// `ClosedLoopMaximumDistance`, and stops a streamline that closes on itself. Without
// them a curve in a swirling field integrates round and round: measured on a 40 mm
// cube, the kept curves averaged 181 mm each — longer than the cube's 69 mm body
// diagonal — and the result was a tangle of noodles rather than a lattice.
//
// Two independent stops, both cheap and both local to the curve being traced:
//   TURNING  — accumulate the unsigned turn angle between consecutive steps. Past a
//              FULL REVOLUTION the curve is orbiting, not following a load path.
//   RE-VISIT — the curve comes back within `d_test` of one of its OWN earlier points,
//              far enough back that it is not just the previous step. That is
//              Jobard-Lefer's separation test turned on the curve itself, which is
//              what "closed loop" means here.
inline constexpr double kOrganicMaxTurnRevolutions = 1.0;
// How far back along its own trail a point must be before a re-visit counts, as a
// multiple of the local separation. Below this the "loop" is just the integrator's
// own footprint.
inline constexpr double kOrganicSelfRevisitLag = 2.0;

// ★ THE TEXTBOOK OVERHANG GATE, KEPT ONLY AS THE COUNTERFACTUAL. It is NOT the
// default and it is NOT applied unless a caller asks for it: the maintainer's coupon
// printed a 41.78 mm unsupported run clean with supports off, so on this machine the
// 45-degree rule is not the binding limit. Reported against, never imposed.
inline constexpr double kOrganicTextbookOverhangDeg = 45.0;

// ★ THE PERCOLATION FLOOR ON CURVES-PER-MEMBER (§3a/§3b). `cells_per_member` counts
// CELLS across a wall and an organic lattice has no cells; the equivalent is the count
// of CURVES crossing the thinnest section. Below 2 a member is spanned by at most one
// curve of each family, which is a line of struts and not a lattice — nothing crosses
// it, so nothing braces it. This is a BUILDABILITY floor, in the same sense
// `lattice_percolation_cells_per_member_min` is, and NOT an accuracy floor: there is
// no homogenised tensor for a traced lattice, so there is no accuracy claim to floor.
// Material below it is COUNTED and reported OUT OF REGIME, never hidden (§3b).
inline constexpr double kOrganicCurvesPerMemberFloor = 2.0;

// How many times the ground-tie repair may re-flood before giving up. The coupon uses
// 12; a leg can itself land on another floating component, so one round is not enough,
// and a bound is needed because a component wholly outside the region can never tie.
inline constexpr int kOrganicRepairRounds = 12;

// How many times the dangling-end trim may cascade. Trimming one curve can orphan the
// next, so one pass is not enough; a bound is needed because a pathological cluster
// could otherwise consume itself one end at a time.
inline constexpr int kOrganicTrimRounds = 8;
// ★★ THE PRUNE. Iterative erosion of unsupported tips, run to a FIXED POINT on the
// FINAL post-clip span list. A span dies when a tip of it lies in no OTHER live span's
// solid; killing it can expose the tip that met its other end, so the pass repeats.
// This is the only construction that can GUARANTEE zero free ends: tying can fail (the
// tie is itself clipped, or there is nothing in reach), cutting cannot. 64 rounds is a
// runaway guard, not a budget — the fixed point is reached in far fewer.
inline constexpr int kOrganicPruneRounds = 64;
// ★★ HOW MANY TIMES THE MID-AIR-START REPAIR MAY RUN.
// Both remedies CASCADE. A leg adds material that may itself need support beneath it,
// and CUTTING a span removes support from whatever was resting on it — so one round's
// fix is the next round's defect. At 8 the pass was still making progress when it ran
// out (7 regions -> 4 across the last two rounds), which is a budget, not a fixed
// point. This is a runaway guard; the loop also stops the moment a round can neither
// support nor cut anything, and reports which of the two happened.
inline constexpr int kOrganicSupportRounds = 64;
// ★★ HOW MANY TIMES THE WHOLE REPAIR SET MAY ITERATE. The repairs form a CYCLE — each
// one's fix is the next one's defect — so they run together until a full round changes
// nothing. A runaway guard, not a budget: `fixed_point_converged` reports which it was.
inline constexpr int kOrganicFixedPointRounds = 24;

// ★★ WHERE THE PART ACTUALLY STARTS, AND WHY EVERYTHING BELOW IT IS SCRAP.
// The maintainer sliced a cube and read the layers off the preview: layer 1 printed a
// handful of dots, layer 3 was already extruding overhangs, and only at layer 5 did the
// "swirl" appear — one continuous ring that the whole cube is then built on. His words:
// "this should be the first layer... everything is built from it."
//
// Those dots are REAL and they TOUCH THE PLATE, which is exactly why the mid-air check
// passes them: they are the tips of struts grazing the bottom face. But a speck of
// plastic with no neighbours does not adhere — it gets dragged by the nozzle, and takes
// the layer above with it. Measured on his cube at a 0.1 mm layer height:
//
//     layer   z(mm)   cells   islands   largest   largest/cells
//       0     0.018     173      79        26        15 %
//       4     0.418    4571      77       671        15 %
//       5     0.518    8007      66      1996        25 %
//       6     0.618   12812      46      8854        69 %   <- the swirl closes
//
// The signature is unmistakable: below the base the layer is SCATTER (dozens of islands,
// none of them dominant); at the base one region takes most of the layer. So the base is
// the lowest layer whose largest connected region holds at least this fraction of that
// layer's own material, and everything below it is cut.
inline constexpr double kOrganicBaseDominanceFraction = 0.5;
// ★★ AND THE RULE THAT ACTUALLY MAKES THE BOTTOM FLAT: AREA, NOT CONNECTEDNESS.
// The dominance test above asks whether ONE connected region owns a layer. On a sparse
// lattice that identified the base correctly, but on a dense one even a layer holding
// nothing but STILTS is internally connected, so it fires at layer 0 and trims nothing
// — the maintainer's render showed the cube standing on a handful of legs.
//
// "Flat" is a statement about how much material a layer has, not how it is joined. The
// base is the lowest layer whose cross-section reaches this fraction of the LARGEST
// cross-section in the bottom band. Stilts are a percent or two of it; the real first
// layer of the body is most of it.
inline constexpr double kOrganicBaseAreaFraction = 0.5;

// ══ ★★★ THE BASE MAT — BUILD A FOUNDATION, DO NOT TRIM DOWN TO ONE ★★★ ══════════
// The maintainer's observation, and it turns the problem the right way up: when the
// "swirl" happened to land as the first layer the print started beautifully, because
// that layer was ONE CONTINUOUS REGION SPANNING THE FOOTPRINT — a foundation the rest
// of the lattice could stand on. Everything since has been an attempt to FIND such a
// layer by trimming, which only works when the trace happens to produce one. Twice it
// did not, and the cube came out on stilts.
//
// So the mat is EMITTED, not discovered: a planar grid of struts at the base plane,
// covering the part's cross-section there, at the local separation. Then it is simply
// existing material, and every pass that follows anchors to it for free — the branch
// support finds it beneath any island, the tie pass reaches it, the mid-air census
// treats it as ground.
//
// ★ IT IS TWO FAMILIES, NOT ONE. A single direction is a comb, not a mat: it has no
// in-plane stiffness across the strands and nothing stops them separating on the bed.
// Crossed at the local separation it is a grid, and the crossings are what make the
// first layer stick.
// ★★ THE MAT IS A GRID, AND MUST NOT FUSE INTO A SLAB. Its pitch is a multiple of the
// mat strut's DIAMETER, and the multiple must exceed 1 — this is exact geometry, not a
// taste call. A capsule of radius r centred at height zc has half-width
// sqrt(r^2 - (z-zc)^2), which peaks at r, so adjacent lines MERGE at the widest layer
// whenever pitch <= 2r. Keyed to the lattice cell the pitch was 4-6 mm and the mat
// sliced as scattered fragments; set to 0.9 diameters it was 1.8r < 2r and the third
// layer came out as one solid square under the whole part. Above 1 diameter a gap
// survives at every height.
inline constexpr double kOrganicBaseMatPitchPerDiameter = 1.35;

// ★★ HOW FAR A MAT PAD REACHES AROUND A TOUCHDOWN, in mat pitches. The mat used to be
// laid across the ENTIRE footprint whether or not anything landed on it: on the 40 mm
// cube the first seven layers printed a full 40x40 square of which only a part was ever
// built upon. A foundation is for the things standing on it, so the mat is emitted only
// within this reach of a point where the lattice actually meets the base plane.
// Generous enough that neighbouring touchdowns merge into one pad rather than leaving a
// field of isolated islands.
inline constexpr double kOrganicBaseMatPadPitches = 3.0;

// How close to the base plane a strut end must be to COUNT as a touchdown, in mat
// radii. A leg that stops a whisker above the plane is not standing on it.
inline constexpr double kOrganicBaseMatContactRadii = 1.5;

// ★★ HOW THICK THE MAT'S STRUTS ARE, as a multiple of the local strut radius — and
// with the centreline ON the cut plane, this is also the mat's HEIGHT, since the weld
// takes its lower half.
//
// ★ IT CANNOT BE THINNED AT THE CURRENT WELD PITCH, and that is a RASTER limit rather
// than a design one. Halving it to 0.5 was tried on the measured grounds that the mat
// only carries 4 supported cells and does not hold the part together (running the real
// weld with and without it left the part at ONE component either way). The result was
// that the mat DISAPPEARED from the slice entirely: at ratio 0.5 its height came to
// 0.273 mm against a `welded_pitch_mm` of 0.28, so the whole mat was thinner than a
// single voxel of the raster that builds the mesh and was erased by it.
//
// At 1.0 the height is ~0.545 mm, about two voxels — already close to the floor. Any
// future thinning has to come with a finer weld pitch, or by giving the mat its own.
inline constexpr double kOrganicBaseMatRadiusRatio = 1.0;

// ══ ★★★ THE FILL MAT — COVERAGE IN THE LOW-STRESS INTERIOR ★★★ ═══════════════════
// The base mat solved the FLOOR by emitting a foundation instead of hoping the trace
// left one. The same argument applies to the BODY: where the stress field is weakest —
// the corner of a cube furthest from the load path — no curve survives tracing, and an
// 8 x 8 mm column comes out with NO MATERIAL AT ALL. Measured on the maintainer's cube:
// 117 of 1000 4 mm cells completely empty, in one persistent corner.
//
// ★ WHY THE OBVIOUS FIX FAILED, AND WHY THIS ONE IS DIFFERENT. Keeping the short curves
// the tracer discards there does NOT work: a stub alone in an empty region is
// unsupported by construction, so the free-end prune and the mid-air pass delete it
// again (658 kept, empty cells 117 -> 125, worse than doing nothing). Coverage cannot
// be bought with material the printability rules exist to remove.
//
// The fill mat is emitted as STRUCTURE and, crucially, EXTENDS PAST the empty region
// into the material around it, so it is anchored at both ends the moment it exists and
// nothing downstream can call it loose. Same reason the base mat survived.
//
// ★ IT IS AN OVERRIDE OF THE GRADE AND IT IS REPORTED AS ONE. The stress field says
// there is nothing to carry here; this puts material there anyway because a part with
// a hole in it is not what anyone asked for. That is a legitimate choice and it costs
// mass, so `fill_mat_struts` and `fill_mat_length_mm` are on the receipt.
// How far an arm may search for material to land on, in cells. Beyond this the void is
// too wide to bridge with one strut and the cell is left alone rather than sprouting a
// free end into it.
// ★★ HOW FAR SHAPE FIT MAY SHRINK A CELL, as a fraction of the size the stress asked
// for. Used only when the job states no cell window; with one, the user's own
// `cell_min_mm` is the floor and this is not consulted. Unbounded, the boundary cap
// (2 x distance) drives the outermost voxels to two voxels — far below any stated cell
// — which slams the whole shell into the tracer's resolution floor: seeds multiply,
// the trace ran 10x longer than its twin without finishing, and the part would come
// back with a solid skin rather than a graded one.
inline constexpr double kOrganicShapeFitMinCellRatio = 0.5;

// ★ 4 -> 2 (2026-09-05): at 4 the fill laid 20-32 mm straight horizontal bridges
// across every empty stretch of a grown lattice (306 of them on the STAND), which
// read as scaffolding, not growth. A taste call, flagged as such in the handoff.
inline constexpr int kOrganicFillMaxReachCells = 2;
inline constexpr int kOrganicFillMaxCells = 400000;

// ★★ THE VDI 3405-3-4:2019 DENSITY FLOOR, AND IT IS DERIVED, NOT CHOSEN.
// The standard limits a bar's SLENDERNESS, not its angle alone: at or above the
// critical downskin angle (45 deg) it requires l/D <= 5, and for a vertical bar
// l/D <= 10, where l is the bar length and D its outer diameter. Reintjes & Lorenz
// (PAMM 2021, doi:10.1002/pamm.202000204) encode exactly this as the linear
// constraints of a support-free lattice MIP.
//
// For a traced lattice the bar length IS the local separation d, and the mass coupling
// fixes the diameter: t = 2 d sqrt(rho / 3pi). So
//
//     l/D = d / (2 d sqrt(rho/3pi)) = sqrt(3pi) / (2 sqrt(rho))
//
// ★ THE SEPARATION CANCELS. Slenderness is a function of DENSITY ALONE, and the rule
// becomes a floor on rho:  l/D <= 5  <=>  rho >= 3pi/100 = 0.0942.
//
// ★ WHY IT IS NEEDED SEPARATELY FROM THE AESTHETIC BAND: the per-voxel density is
// clamped to the LIBRARY band, whose floor is 0.05047 — below this. Measured on the
// maintainer's cube with an aesthetic band of [0.25, 0.45], 558 voxels still landed on
// 0.05047, giving l/D = 6.8 and a 0.44 mm strut. Those are the specks his slicer
// printed in layer 1 and the reason three cubes failed on the bed.
inline constexpr double kOrganicVdiSlendernessMax = 5.0;

// ★★ THE HORIZONTAL-BAR LIMIT, VDI 3405-3-4:2019. The 5.0 above applies to a bar at the
// critical overhang angle; a bar at delta = 90 deg (flat, bridging) is allowed l/D <= 10.
// The two together are the rule that actually governs a STRUT, as against the 45 deg
// SURFACE rule a slicer paints with — which on the maintainer's cube called 64.3 % of
// struts overhanging while only 2.1 % violated the standard for bars.
inline constexpr double kOrganicVdiSlendernessFlatMax = 10.0;

// The angle from the build plate, in degrees, below which a strut is treated as FLAT
// and judged against the flat limit. VDI states the two endpoints; this is where the
// generator switches between them.
inline constexpr double kOrganicVdiFlatAngleDeg = 45.0;

// How many pieces an over-slender strut may be divided into by propping it. A 38.88 mm
// flat bar at 1.12 mm across is l/D 34.7 and needs four pieces to clear 10; beyond this
// the strut is left alone and COUNTED rather than propped into a thicket.
inline constexpr int kOrganicSlendernessMaxProps = 4;

// ★★ HOW FAR A LAYER'S ISLAND MAY REACH BEYOND ITS OWN SUPPORT, in mm. Beyond this the
// leading edge is being laid over open air for long enough to droop — the round strut
// section means a diagonal arrives at its far node several layers after it leaves the
// near one, and in between the arm is a cantilever whatever the island-level support
// flag says. Reported first and acted on second: the flag has been reporting 0 while
// the geometry carried exactly this.
inline constexpr double kOrganicMaxCantileverMm = 3.0;

// ══ ★★★ ARCHING — A SHALLOW SPAN IS BOWED INTO AN ARCH ★★★ ═══════════════════════
//
// ★ THE MECHANISM, IN ONE LINE. A strut at angle theta from the plate advances
// layer_height / tan(theta) along its own length per layer. At 5 degrees and a 0.2 mm
// layer that is 2.3 mm of new material laid in one pass — the span appears almost at
// once, and only whichever end happens to sit over material is holding it. The round
// section is what makes this invisible to an endpoint test: the strut leaves its near
// node many layers before it arrives at the far one.
//
// ★ WHY UP AND NOT DOWN. Bowed UP, each half rises steeply from its own node, every
// layer lands on the previous layer OF THE SAME STRUT, and the halves close at the
// apex last — an arch, printed the way arches are built. Sagged DOWN the middle is
// lowest, so it prints FIRST, over nothing at all.
//
// Below this angle from the build plate a span is shallow enough to be worth arching.
inline constexpr double kOrganicArchMinAngleDeg = 20.0;

// ...but only if it is actually unsupported for this far along its length. A shallow
// bar lying on the weave is held every few millimetres and needs no arch; the measured
// part had 610 islands reaching past their own support, the worst by 11.79 mm.
inline constexpr double kOrganicArchMinUnsupportedMm = 0.01;

// How steep each half of the arch is made, as a multiple of the shallow-angle
// threshold. 1.0 puts both legs exactly at kOrganicArchMinAngleDeg, which is the
// least material that clears the rule the arch exists to satisfy.
inline constexpr double kOrganicArchLegSteepness = 1.0;

// ══ ★★★ THE FILLET — THE STRUT'S OWN UNDERSIDE IS THE ARCH ★★★ ═══════════════════
//
// ★ WHY ARCHING THE CENTRELINE WAS THE WRONG FIX, in the maintainer's words: "instead
// of a cylinder connected to a cylinder, there needs to be a fillet at its edges that
// meet at the center". A strut is a CAPSULE. Its lowest layer is a zero-width sliver
// running the WHOLE length of the span with nothing under it, touching down only where
// an end happens to land on something. Bowing the centreline moves that sliver; it does
// not remove it, because the bowed strut is still a cylinder with the same underside.
// A one-legged span of this kind is not a hard bridge, it is an impossible one.
//
// ★ THE FILLET. Flare the radius at the ends and taper to nominal at the middle. The
// UNDERSIDE then rises from each support at kOrganicFilletAngleDeg and the two flares
// meet at the centre, so every layer of the strut lands on the layer below it — the
// arch is the strut's own surface, not its path.
//
// The angle the underside climbs away from each support.
// ══ ★★★ GROWTH — PRINTABILITY AS A CONSTRUCTION RULE, NOT A REPAIR ★★★ ═══════════
//
// ★ WHY THE TRACE-THEN-REPAIR ARCHITECTURE CANNOT BE PATCHED. `trace_organic_lattice`
// draws curves through 3D space along the stress field, and SIX passes then try to make
// the result printable: tie, prune, stranded drop, ground tie, branch support, fillet.
// Each fixes a defect another has already fixed, which is why they need a joint fixed
// point to terminate at all. A day of work on those passes ended with the maintainer
// pointing at a slice and saying "there's a whole complete mid-air print here" — the
// repairs cannot reach what the generator was free to create.
//
// ★ THE GROWTH RULE. Build in LAYER ORDER from the base plate, the way the machine
// does, and never emit material whose underside is unsupported. Mid-air then is not
// repaired, it is INEXPRESSIBLE. Free ends likewise: a curve only ever extends from
// material that is already held, so a tip in open space cannot be produced.
//
// ★ THE FIELD BECOMES A PREFERENCE, NOT AN INSTRUCTION. The stress direction still
// steers — organic stays organic — but only within the cone that will print. Where the
// field points below the cone the growth climbs at the cone limit toward it, or waits
// for a neighbour to rise and support that direction. 56 % of the spans on the
// maintainer's cube sit below 20 degrees from the plate; the field genuinely wants
// horizontal members, and the honest resolution is that it does not always get them.
//
// The steepest departure from vertical a growing tip may take. VDI's surface rule is
// 45, but the measured limit for a STRUT on FFF is shallower: struts print with ~10 %
// dimensional deviation and < 1 mm shape deviation at 30 degrees from the plate, and
// the threshold moves with extrusion temperature, speed and cooling — so this is a
// property of the profile, not a constant of the geometry.
inline constexpr double kOrganicGrowthMinAngleDeg = 30.0;

// How far a tip advances per growth step, as a multiple of the layer height. One layer
// per step is the finest the machine can resolve and the most faithful to "what the
// printer will do"; larger is faster and coarser.
inline constexpr double kOrganicGrowthStepLayers = 1.0;

// A growing tip is supported when material exists within this many strut radii beneath
// its underside. Slightly over 1 so a tip resting exactly on the layer below counts.
inline constexpr double kOrganicGrowthSupportRadii = 1.25;

// ★★ BRANCHING IS WHAT MAKES IT A LATTICE RATHER THAN A COMB. Seeded only on the floor,
// growth gave 121 parallel columns: each seed climbs, none ever meets another, and a
// diagrid finish had nothing to dress. A 3D lattice needs LATERAL connection, and a
// lateral connection is a horizontal strut — precisely what will not print. The
// resolution self-supporting lattices use is that laterals are DIAGONAL: a curve
// branches off material that already exists and departs at the cone limit, and branches
// from neighbouring columns cross and meet. Every branch is therefore supported at its
// root by construction, exactly like the trunk it left.
//
// How far a tip climbs between offering a branch, as a multiple of the local separation.
// 0.75 gave a printable but sparse weave — the maintainer checked every layer and
// found only a couple of floating strays, wanting "more nodes to hold up those floating
// regions". Branching more often is what puts a node within reach of a stray tip.
inline constexpr double kOrganicGrowthBranchEverySep = 0.5;

// The most tips alive at once. Branching is exponential if unbounded; this is the
// budget, and the receipt reports when it binds rather than silently truncating.
inline constexpr std::size_t kOrganicGrowthMaxTips = 20000;

// ★★ GROW FINELY, RECORD COARSELY. The support question is a question about LAYERS, so
// a tip must advance one layer at a time to be asked it honestly. But a recorded point
// every 0.1 mm on a 0.66 mm strut is far inside the node merge's one-bead radius, so
// the merge collapses an entire curve into a single node: growth emitted 84,232 spans
// and the repairs deleted essentially all of them. Points are therefore RECORDED only
// once the tip has travelled this many strut radii, while the walk itself stays at the
// layer pitch.
// ★ AND IT MUST CLEAR THE MERGE DISTANCE, NOT JUST THE BEAD. The node merge joins
// endpoints within kOrganicNodeMergeRatio BEADS (= 2 x that many radii), so recording
// every 3 radii was still inside it: each grown curve collapsed to ONE straight span
// from base to tip, 20 mm long, and the cube came out as fifteen sticks. 6 radii is
// safely clear and lands near d_sep, which is the polyline resolution the traced path
// uses anyway.
inline constexpr double kOrganicGrowthRecordRadii = 6.0;

// ★★ HOW MANY TIMES ONE TIP MAY JOIN AND CARRY ON. A tip that joins a neighbour used to
// STOP there, and since crowding grows more likely with height the tip population died
// out as it rose: the maintainer's cube came out dense at the base and with "the top
// almost non-existent". Deflecting after a join and continuing keeps strands alive all
// the way up. Bounded so a tip cannot ping-pong between two neighbours forever.
inline constexpr int kOrganicGrowthMaxJoins = 6;

// ★★ THE UPWARD BIAS -- "REACH FOR THE LIGHT". The maintainer's idea, and it answers a
// real defect rather than adding a flourish. A grown curve that stops INSIDE the
// material is a free end, and the dangling-end prune does not trim it, it UNRAVELS the
// whole strand: remove the free span, the one below it becomes free, and so on to the
// base. Measured on the STAND: 27,326 mm reached the prune and 374 mm survived it. A
// curve that instead runs out of REGION reaches the part surface and is ANCHORED there
// by the boundary clip -- so height is not decoration, it is how a curve earns its
// attachment.
//
// A blunt version of this was tried first and REJECTED: a tip out of joins sprinting
// straight up for the boundary. It attached (written length 374 -> 9483 mm) and
// destroyed the weave -- 7,086 vertical columns, ~5 mm per span against the traced
// path's 0.87 mm, a skeleton of long straight members instead of fabric. A plant does
// not bolt for the ceiling when it stops branching; it drifts upward while still
// growing sideways.
//
// So this is a constant preference blended into EVERY step alongside the field, not a
// terminal mode. Tips keep following the stress, keep branching, keep weaving, and
// gain height as they go.
inline constexpr double kOrganicGrowthUpwardBias = 0.25;

inline constexpr double kOrganicFilletAngleDeg = 45.0;

// ★ AND A CAP, because the honest arithmetic is expensive: fully filleting a span of
// length L needs an end radius of r + (L/2)*tan(theta), which at L = 8 mm and r =
// 0.5 mm is 4.5 mm — a blob nine times the strut. Capped, the fillet does not reach
// the middle and the span is IMPROVED rather than solved; the receipt reports the
// residual so a partial fix is never read as a complete one.
// ★ AND THE CAP IS WHAT KEEPS IT A FILLET RATHER THAN A BALL. At 6.0 the widest end
// radius on the maintainer's cube came to 4.87 mm on a ~1.3 mm strut — a 10 mm sphere
// big enough that the slicer put INFILL inside it, which he spotted immediately. The
// flare is meant to be a gusset at a junction, not a node the size of a cell. 2.5 keeps
// the widest end near 1.6 mm; spans needing more than that are counted unresolved.
inline constexpr double kOrganicFilletMaxRadiusRatio = 2.5;

// How many segments a filleted span is emitted as. The taper is piecewise-constant in
// radius, so this is the resolution of the underside's slope.
inline constexpr int kOrganicFilletSegments = 12;

// ★ TRANSFER TIES (2026-09-05). A grown lattice follows the MAJOR principal
// direction only, so where the load has to turn it has no member to turn along and
// the printability repairs (fill rows, mat stitches) become the load path: measured
// on the STAND, every strut over p99 was one of those, one 0.27 mm stitch at 235 MPa
// carrying the whole 44 N. Michell / Daynes: the orthogonal family IS the transfer
// path. So, with `transfer_ties`, every pillar is walked at the local separation and
// a short curve is launched along the SECOND principal direction, both ways; it is
// kept only where it lands on another curve within `kOrganicXferTieReachRatio`
// separations, and only where the minor principal stress is at least
// `kOrganicXferTieMinorRatio` of the major -- where the load actually turns. Where the
// field is straight and uniaxial no tie is placed, so the grove stays a grove.
inline constexpr double kOrganicXferTieMinorRatio = 0.10;
inline constexpr double kOrganicXferTieReachRatio = 1.5;
// ★ ISOSTATIC TIES, NOT STUBS (maintainer, 2026-09-05: "much less geometric, more
// fluid"). A tie that stops at the first pillar it touches is a few millimetres long
// and cannot show a bend. Daynes' second family are isostatic LINES: they follow
// the minor principal direction across every pillar, and their spacing is the
// stress-driven separation -- his "spatial grading". So a tie now welds at each
// pillar it crosses and keeps going, up to kOrganicXferTieMaxReachRatio separations,
// until it leaves the region or comes within kOrganicTestRatio of another tie (the
// same Jobard-Lefer rule the pillars obey). The minor-stress gate still decides
// where a tie is SEEDED; the field decides where it goes.
inline constexpr double kOrganicXferTieMaxReachRatio = 8.0;
// ★ THE SWIRL (maintainer, 2026-09-05: "bending as organically as possible"). A tie
// that follows the field exactly bends only where the stress bends, and in a smooth
// field that is a smooth arc, which reads as drawn. What reads as GROWN is coherent
// variation: neighbours lean together, wander a little, never repeat. This is the
// coupon harness's swirl brought to the ties: the heading is rotated about the local
// normal by an angle that varies smoothly with position (products of sines, NO
// randomness -- two runs give the same part), amplitude kOrganicXferTieSwirlDeg at
// a wavelength of kOrganicXferTieSwirlWavelengthRatio separations. Welds stay exact;
// the swirl is a look, and it is bounded so the tie still reaches its neighbours.
// grading.organic_tie_swirl scales it (0 = off, 1 = this amplitude).
inline constexpr double kOrganicXferTieSwirlDeg = 28.0;
inline constexpr double kOrganicXferTieSwirlWavelengthRatio = 3.5;
// ★ VOID RE-SEEDING (maintainer, 2026-09-05: "seeds cannot grow to these thinnest
// of areas"). Growth seeds only the region's FLOOR, so a tall thin neck far above it
// fills only if a pillar happens to climb that far without dying to crowding or the
// region edge -- and nothing re-seeds above a dead pillar. A seed placed high up
// cannot stand (that is why farthest-point seeding once placed 0 seeds); so a void is
// entered FROM BELOW: at a candidate voxel with no curve within
// kOrganicReseedVoidRatio separations, a stub first grows DOWN along the field
// until it lands on existing lattice or the plate. Only a stub that lands becomes a
// seed; its climb is then an ordinary tip. Bounded by kOrganicReseedMaxSeeds per run
// and kOrganicReseedRounds passes.
inline constexpr double kOrganicReseedVoidRatio = 1.5;
inline constexpr int kOrganicReseedMaxSeeds = 800;
inline constexpr int kOrganicReseedRounds = 2;
inline constexpr double kOrganicVdiDensityFloor =
    3.0 * 3.14159265358979323846 / (kOrganicVdiSlendernessMax *
                                    kOrganicVdiSlendernessMax * 4.0);
// The standard's other hard number: no bar thinner than 1 mm for material extrusion.
inline constexpr double kOrganicVdiMinBarDiameterMm = 1.0;

// ── ★★ BRANCHED SUPPORT, AFTER TREE SUPPORTS ────────────────────────────────────
// The maintainer's suggestion, and it is the right one: "having everything come back
// to original base struts". A vertical pillar per unsupported island is the naive
// scheme tree supports were invented to replace — 448 of them on his cube, each
// demanding an anchor directly beneath it and ignoring perfectly good material a
// millimetre to one side.
//
// THREE MECHANISMS ARE TAKEN, ONE IS NOT:
//   MERGE      branches whose tips come within this radius COALESCE into one trunk
//              and descend together. This is the mechanism that makes the support
//              converge on a few base struts instead of raining pillars.
//   TILT       a branch may step sideways as it descends, within an angle of
//              vertical, so it can REACH an anchor rather than demand one below.
//   ANCHOR ON  a branch stops the instant it meets existing lattice — it does not
//   THE MODEL  insist on the plate. In a lattice this is most of the win.
//   (not taken) RADIUS GROWTH with carried load. Tree supports thicken a trunk as it
//              gathers branches; here the branches ARE lattice, and varying their
//              diameter would fight the mass coupling that sets strut thickness from
//              density (organic_strut_diameter_for). Constant radius, stated.
inline constexpr double kOrganicBranchMergeRadiusRatio = 2.5;   // x the strut radius
inline constexpr double kOrganicBranchMaxTiltDeg = 40.0;
inline constexpr int kOrganicBranchMaxSteps = 4000;
// A connected piece smaller than this fraction of the lattice's total length is
// DELETED rather than tied down to the plate. Propping a crumb up on a tall thin leg
// is neither printable nor useful; below this size there is nothing worth saving.
inline constexpr double kOrganicStrandedKeepFraction = 0.02;
// How far the surface normal must swing across a point for it to count as an EDGE of
// the part, for the RIM finish. A flat face reads 0 degrees; a cube edge reads 90.
inline constexpr double kOrganicRimEdgeAngleDeg = 35.0;
// When a tip meets ANOTHER SPAN'S TIP rather than its body, that span counts as support
// only if it leads away rather than folding back along the same line. cos(105 deg): a
// polyline continuing (+1) and a tie heading off sideways (0) both pass; a sibling
// doubling back the way the strut came (-1) does not. Bundles of co-terminating
// near-parallel struts are exactly the -1 case, and they were 100 % of what survived.
inline constexpr double kOrganicFoldBackCos = -0.2588;
// ★ NODE MERGING — the OTHER half of the treatment Daynes et al. name.
// "At the core boundary very small cells are generated, and in such cases nodes are
// either merged or deleted to avoid formation of excessively small cells"
// (Materials & Design 127:215-223). Deleting is the prune. THIS is the merge: two span
// endpoints closer together than one bead are the same node, and leaving them apart is
// what produced the bundles of six co-terminating struts the dump found at every
// surviving dead end. As a multiple of the strut RADIUS, so 2.0 is one full bead.
inline constexpr double kOrganicNodeMergeRatio = 2.0;
// ★ HOW DEEP THE FINISH REACHES, as a fraction of the local separation.
// A finish must describe the lattice it is dressing, so it selects the SURFACE NODES
// of the FINISHED structure — every node within this band of the part's surface —
// rather than the clipped ends left over from trimming. Keying on leftovers made the
// finish depend on how much the prune had removed: 661 candidates before the passes
// were ordered correctly, 121 after, for the same part and the same look asked for.
inline constexpr double kOrganicFinishBandRatio = 0.5;
// ★ A FINISH JOIN MUST BE A NEW MEMBER, NOT A REDRAWN ONE.
// Measured on the cube: joining each surface node to its nearest neighbours produced
// 2,615 joins of which 1,889 (72 %) duplicated an existing strut endpoint for
// endpoint, and 83 % of a sample lay entirely INSIDE existing material — mean join
// length 1.23 mm against a 3.10 mm separation. The finish was drawing the lattice on
// top of itself, which is why `clean`, `rim` and `skin` rendered identically. A net
// edge spans the GAP BETWEEN neighbouring curves, so it is at least this fraction of
// the local separation, and never between two nodes a strut already joins.
inline constexpr double kOrganicFinishMinSpanRatio = 0.55;
// Both ends of a surface join must be looking the same way, or the "surface" net cuts
// the corner and dives through the interior. cos(50 deg).
inline constexpr double kOrganicFinishCoplanarCos = 0.6428;

// How far a free tip may reach for something to tie to, as a multiple of the local
// separation. Beyond about one separation the tie stops being a lattice member and
// becomes a wire across a void, so a tip that finds nothing inside this is REPORTED
// rather than tied to something arbitrary.
inline constexpr double kOrganicTieReachRatio = 1.25;

// ★ THE DENSITY OF THREE ORTHOGONAL FAMILIES AT SEPARATION d, STRUT DIAMETER t.
// A box of edge d carries one strut of each family through it, so the solid fraction
// is 3 * pi * (t/2)^2 * d / d^3 = 3*pi*t^2 / (4 d^2). Overlaps at the crossings are
// NOT deducted — the same soup basis the generator's volume accounting uses, and it is
// stated at every site that reports a number derived from it.
//
// This is the ONE definition of the spacing/thickness/mass coupling (§2d) and both
// directions of it are here so no caller re-derives half of it. The strut-diameter law
// has already drifted 1.4-1.7x by being re-derived elsewhere.
inline double organic_density_at(double spacing_mm, double strut_diameter_mm) {
  if (!(spacing_mm > 0.0)) return 0.0;
  const double t = strut_diameter_mm;
  return 3.0 * 3.14159265358979323846 * t * t / (4.0 * spacing_mm * spacing_mm);
}
// The inverse: the separation that yields `rho` at strut diameter `t`. This is the law
// that turns the grading field into a SPACING FIELD — tighter where the part works
// harder — which is the CURVY posture: the pattern is expressed by spacing at a
// constant bead, not by thinning struts below what the nozzle can lay.
inline double organic_spacing_for(double rho, double strut_diameter_mm) {
  if (!(rho > 0.0) || !(strut_diameter_mm > 0.0)) return 0.0;
  return 0.5 * strut_diameter_mm *
         std::sqrt(3.0 * 3.14159265358979323846 / rho);
}
// ★ AND THE THIRD ARRANGEMENT OF THE SAME COUPLING — THE ONE PRODUCTION USES.
// Given the SPACING (the user's swept window) and the density the grading law chose,
// what bead carries that mass?  t = 2 d sqrt(rho / (3 pi)).
//
// ★ THE WINDOW IS THE CONTROL. rho says how much material there is, d says how far
// apart to put it, and the bead is then not a free choice at all. Reading the coupling
// in THIS direction is what lets `cell_min_mm` / `cell_max_mm` mean the same thing for
// organic that they mean for doubled — a range of spacings the user asked for —
// instead of being silently ignored while the bead sets the spacing behind their back.
inline double organic_strut_diameter_for(double spacing_mm, double rho) {
  if (!(spacing_mm > 0.0) || !(rho > 0.0)) return 0.0;
  return 2.0 * spacing_mm * std::sqrt(rho / (3.0 * 3.14159265358979323846));
}

// ★ THE STRUT DIAMETER A GIVEN GRID CAN ACTUALLY EXPRESS A GRADE AT.
//
// The obvious default — "the thinnest bead the machine lays" — is the WRONG one, and
// measurably so. Spacing and thickness are coupled through mass (§2d):
// d = (t/2) * sqrt(3 pi / rho). At a 0.42 mm bead the whole certifiable band lands at
// d = 0.68 .. 2.87 mm, and on the maintainer's part the grid spacing is ~1.56 mm — so
// the DENSE half of the band asks for curves closer together than the direction field
// is sampled. Everything there is raised to the resolution floor, the spacing stops
// varying, and the grade disappears: a uniform lattice wearing a graded density.
//
// So the default is derived the other way round: pick t such that the DENSEST lattice
// in the band sits exactly ON the resolution floor — the finest separation this grid
// can express — and let everything lighter open out from there. That is the widest
// achievable window the grid permits, and it is never below the stated minimum
// extrudable width, because printability is user input and outranks it.
inline double organic_default_strut_diameter_mm(double grid_spacing_mm,
                                                double resolution_floor_voxels,
                                                double rho_max,
                                                double min_extrudable_width_mm) {
  const double d_res = std::max(0.0, resolution_floor_voxels) * grid_spacing_mm;
  if (!(d_res > 0.0) || !(rho_max > 0.0)) return min_extrudable_width_mm;
  const double t =
      2.0 * d_res * std::sqrt(rho_max / (3.0 * 3.14159265358979323846));
  return std::max(t, min_extrudable_width_mm);
}

// ── the parameters ──────────────────────────────────────────────────────────────
struct OrganicParams {
  // The machine's layer height. The GROWTH rule advances a tip one layer at a time and
  // asks its support question in that discretisation, because "will this print" is a
  // question about LAYERS, not about model units. 0 = not stated.
  double layer_hint_mm = 0.0;
  // The build direction (unit, model frame) the overhang cone is measured from.
  Vec3 build_dir{0.0, 0.0, 1.0};

  // ★ §2(a)/§2(b) — THE OVERHANG CONE, APPLIED IN THE TRACING LOOP. The half-angle
  // of the printable cone about +/-build_dir, in DEGREES FROM THE BUILD DIRECTION: a
  // direction is in-cone when |dot(dir, build_dir)| >= cos(angle). When a traced
  // direction leaves the cone it is PROJECTED ONTO THE NEAREST IN-CONE DIRECTION
  // there and then, never re-angled afterwards — a repair pass would discard exactly
  // the stress alignment the method exists for.
  //
  // ★ 0 (THE DEFAULT) DISARMS THE CLAMP, and the reason is measured, not assumed:
  // see the coupon note at the top of this header. 90 also disarms it (the whole
  // sphere is in-cone). Set 45 to reproduce the textbook gate.
  double overhang_angle_deg = 0.0;

  // ★ §2(c) — THE STRUT FLOOR BINDS. The stated minimum extrudable width (mm).
  // ★ 0 MEANS UNSET AND IS REFUSED: printability is USER INPUT, never a default.
  double min_extrudable_width_mm = 0.0;

  // The strut diameter the whole lattice is traced at (mm). 0 => the floor above,
  // i.e. the thinnest bead the user says the machine lays. Used only when
  // `strut_diameter_field` is null.
  double strut_diameter_mm = 0.0;

  // ★ PER-VOXEL BEAD (task 2026-08-21, follow-up). Grid-indexed, mm; null => the
  // scalar above everywhere.
  //
  // ★ WHY THIS EXISTS. The first version held the bead CONSTANT and let the spacing
  // fall out of the mass coupling — CURVY's posture, and defensible on its own terms.
  // But it meant the JOB'S OWN SWEPT WINDOW (`cell_min_mm`/`cell_max_mm`) never
  // reached the tracer at all: a job asking for 5-10 mm cells got 0.6-2 mm spacing,
  // which on a 40 mm cube emitted a 2.76 GB mesh carrying 27x the part's own volume
  // in overlapping struts. The user had asked for a spacing range and been given a
  // different one. So the window is now the SPACING control (the caller maps demand
  // onto it) and the BEAD is what falls out of the mass coupling instead — floored,
  // always, at the stated minimum extrudable width.
  const std::vector<double>* strut_diameter_field = nullptr;

  // The Jobard-Lefer ratios and the integrator step. See the constants above.
  double test_ratio = kOrganicTestRatio;
  double seed_ratio = kOrganicSeedRatio;
  double connect_ratio = kOrganicConnectRatio;
  double step_ratio = kOrganicStepRatio;
  double thin_ratio = kOrganicTestRatio;
  double min_length_ratio = kOrganicMinLengthRatio;

  // How many principal directions to trace. 3 = the full orthogonal set (Daynes).
  int families = 3;

  // ★ grown only: launch transfer ties along the second principal direction from
  // every pillar (see kOrganicXferTieMinorRatio). Job key grading.organic_transfer_ties.
  bool transfer_ties = false;
  double tie_swirl = 1.0;   // 0..1, scales kOrganicXferTieSwirlDeg
  bool reseed_voids = true; // grown only: enter voids from below (kOrganicReseedVoidRatio)

  // Hard bounds so a degenerate field cannot run away. Exceeding either is REPORTED,
  // never silent (`seed_budget_exhausted` / `step_budget_hits`).
  int max_curves = 400000;
  int max_steps_per_curve = 100000;

  // ★ §2(d) — THE SECOND FLOOR ON THE SEPARATION, AND ON A REAL PART IT IS THE ONE
  // THAT BINDS. The tracer integrates a direction field that is only sampled at the
  // VOXEL GRID, so it cannot place curves closer together than the grid can resolve
  // the field they are meant to follow. This is the separation floor as a multiple of
  // the grid spacing; 1.0 (the default) is one voxel. Voxels raised by it are counted
  // in `spacing_raised_for_resolution_voxels`, so the ACHIEVED window R5 reports says
  // WHICH bound bit — printability or resolution — rather than merely how wide it is.
  double resolution_floor_voxels = 1.0;

  // ★ IS THE REGION BOUNDARY AN ANCHOR? (§1e2.)
  // A curve end that ran out of REGION reaches the part surface. When the export
  // WRITES A SHELL, the boundary clip lands that end on the shell and it is genuinely
  // held — so it must not be trimmed. When the export writes the BARE LATTICE
  // (`outer_finish: "skin"`), there is no shell there and the same end is a cantilever
  // sticking out into air, attached at one side only.
  //
  // ★ THE MAINTAINER FOUND EXACTLY THOSE, at the right-hand face of a bare cube:
  // "sections that are horizontal and literally only attach to a singular vertical
  // strut". They survived the first trim because this defaulted to true.
  //
  // The CALLER knows which file it is writing, so the caller states it. True (the
  // default) is the shell case, which is the shipped default outer finish.
  bool anchor_at_region_boundary = true;

  // The certifiable density band the emitted per-voxel density is clamped into. Both
  // 0 => no clamp (the raw measured density is returned, which is what a probe wants).
  double rho_min = 0.0;
  double rho_max = 0.0;
};

// ── what one traced curve is ────────────────────────────────────────────────────
struct OrganicCurve {
  int family = 0;                // 0,1,2 = principal direction rank (|lambda| desc)
  std::vector<Vec3> points;      // the polyline, model mm, in trace order
  double length_mm = 0.0;
  double radius_mm = 0.0;        // half the strut diameter
  long long steps = 0;           // RK4 steps taken
  long long clamped_steps = 0;   // ...of which the overhang cone moved
  int connections = 0;           // connectors attached (§1d) — R3's measurement
  // ★ Did this curve END by leaving the candidate set? An end that ran out of REGION
  // reaches the part surface and is anchored there by the boundary clip. An end that
  // stopped INSIDE the material (d_test, a turn, a dead field) is a FREE END hanging
  // in mid-material, and §1(e2) trims it.
  bool start_at_boundary = false;
  // ★★ WHAT KIND OF SEGMENT IS THIS? Parallel to the SEGMENTS of `points`, so
  // `seg_kind[i]` describes points[i] -> points[i+1]; size is points.size() - 1 when
  // growth wrote it and EMPTY on the traced path, which has no such distinction.
  //
  // It exists because the printability bar differs by kind and a blended bar means
  // nothing. A CLIMB is cone-clamped and must obey the cone with no tolerance. A JOIN
  // or DEFLECT lands on material that is already there and may arrive at any angle —
  // what bounds it is the horizontal RUN of the span, not its slope.
  enum class Seg : unsigned char { Climb = 0, Join = 1, Deflect = 2 };
  std::vector<unsigned char> seg_kind;
  bool end_at_boundary = false;
};

// One connector (§1d / Daynes step 5). Its direction is the CROSS PRODUCT of the two
// curves' tangents at their nearest points BY CONSTRUCTION: the shortest segment
// between two curves is perpendicular to both tangents, which is what the cross
// product is. `cross_deviation_deg` MEASURES that rather than asserting it.
struct OrganicConnector {
  int curve_a = -1, curve_b = -1;  // curve_a < curve_b, indices into `curves`
  int pt_a = 0, pt_b = 0;          // the attachment point index on each curve
  Vec3 a{0, 0, 0}, b{0, 0, 0};
  double radius_mm = 0.0;
  double length_mm = 0.0;
  double cross_deviation_deg = 0.0;
};

// ── the report: every number the bars ask for, measured, never predicted ────────
struct OrganicReport {
  // §1(a) the field
  std::size_t candidate_voxels = 0;
  std::size_t degenerate_voxels = 0;   // eigenvalues too close to rank the directions
  double degenerate_fraction = 0.0;
  // ★ §6(d) — THE SWIRL. Where the top two |eigenvalues| are within
  // `kOrganicDegenerateRatio` of each other the principal FRAME is not determined and
  // the eigenvector order can swap between neighbouring voxels. NAMED AND COUNTED
  // here; no combing pass is built (that is a separate question).
  double max_frame_swap_fraction = 0.0;  // fraction of RK4 steps that saw a flip

  // §1(b)/(c) the curves
  std::size_t curves_traced = 0;       // before thinning
  std::size_t curves_kept = 0;         // after thinning
  std::size_t curves_thinned = 0;      // §1(e)
  std::size_t curves_too_short = 0;
  // ★ Stubs KEPT because nothing else covered their patch. A grade may make a region
  // sparse; it may never make it absent.
  std::size_t curves_kept_for_coverage = 0;    // stubs discarded
  // ── ★ §1(e2) — DANGLING ENDS, TRIMMED ──────────────────────────────────────
  // ★ A CURVE'S TAIL BEYOND ITS OUTERMOST CONNECTOR CARRIES NOTHING. It is attached at
  // one end only, so no load can cross it — and if it runs horizontally it is also an
  // unsupported overhang the printer has to bridge to nowhere. The maintainer found
  // these by eye on a cube this task had already called 99.99 % connected: "sections
  // that are horizontal and literally only attach to a singular vertical strut —
  // making them absolutely pointless and impossible to print."
  //
  // So each curve is cut back to its outermost connector. ★ ENDS THAT LEFT THE REGION
  // ARE KEPT: those reach the part surface, where the boundary clip lands them on the
  // shell, and that IS an anchor. Only ends that stopped inside the material are free.
  //
  // Iterated, because trimming a curve can remove the only connector holding a
  // neighbour, which makes that neighbour dangling in turn.
  std::size_t dangling_ends_trimmed = 0;
  std::size_t curves_dropped_dangling = 0;
  double dangling_length_removed_mm = 0.0;
  int dangling_rounds = 0;
  std::size_t curves_per_family[3] = {0, 0, 0};
  double curve_length_per_family_mm[3] = {0.0, 0.0, 0.0};
  // ── ★ WHY THE TRACER STOPPED AND WHY A SEED WAS REFUSED ────────────────────
  // Without these a thin lattice is unattributable: "562 curves" says nothing about
  // whether the field ran out, the region ran out, or the separation rule closed the
  // part off. Every half-trace ends for exactly one of these reasons and every seed
  // offered is accounted for, so the two ledgers each sum to their total.
  long long stop_left_region = 0;    // the curve walked out of the candidate set
  long long stop_hit_d_test = 0;     // came within d_test of a same-family curve
  long long stop_no_direction = 0;   // the field had no direction there
  long long stop_step_budget = 0;
  long long stop_turned_too_far = 0; // orbiting: past a full revolution of turning
  long long stop_self_revisit = 0;   // came back onto its own trail (a closed loop)
  long long seeds_offered = 0;
  long long seeds_outside_region = 0;
  long long seeds_too_close = 0;     // within d_sep of an existing same-family curve
  long long seeds_traced = 0;
  long long total_steps = 0;
  long long step_budget_hits = 0;
  bool seed_budget_exhausted = false;
  double total_curve_length_mm = 0.0;

  // §1(d) the connectors — and R3's answer
  std::size_t connectors = 0;
  double connector_min_length_mm = 0.0;
  double connector_median_length_mm = 0.0;   // full sort, never a sample
  double connector_max_length_mm = 0.0;
  // ★ WHEN THE CROSS-PRODUCT STATEMENT IS VACUOUS, AND IT OFTEN IS. Daynes step 5
  // says the connector runs along the cross product of the two tangents, and for two
  // SKEW curves that is exactly what the shortest segment between them is. But two
  // curves that nearly INTERSECT have no well-defined shortest direction — the
  // separation collapses and any transverse direction is as short as any other. On
  // the axis-aligned probe fixture the two families are coplanar, and the measured
  // deviation is 90 degrees for precisely that reason, not because the connector is
  // wrong: those two curves are already welded by their own strut solids.
  //
  // So the deviation is reported over the connectors where it MEANS something —
  // those longer than the polyline's OWN sampling step, i.e. where the two curves are
  // further apart than the tracer can resolve — and the degenerate population is
  // counted beside it rather than averaged into it.
  std::size_t connectors_shorter_than_strut = 0;  // below the resolution threshold
  std::size_t connectors_cross_measured = 0;
  double max_connector_cross_deviation_deg = 0.0;
  double mean_connector_cross_deviation_deg = 0.0;
  // ── ★ R3, AND THE FIRST VERSION OF IT MEASURED THE WRONG OBJECT ────────────
  // These four count components of the CURVE GRAPH — curves as nodes, connectors as
  // edges. That graph is an abstraction I built, and it agreed with itself: on a
  // 40 mm cube it reported ONE component holding 100 % of the curves while the
  // EMITTED SOLIDS were 5,414 separate pieces with 90 % of the material floating
  // free. A connector being recorded as an edge does not make two strut solids
  // touch. Kept because they still say something about the connection PASS, but they
  // are NOT the connectivity bar and must never again be reported as if they were.
  std::size_t curves_with_fewer_than_two_connections = 0;
  std::size_t curves_with_no_connection = 0;
  std::size_t connected_components = 0;      // over the curve/connector GRAPH
  std::size_t largest_component_curves = 0;
  double largest_component_fraction = 0.0;

  // ── ★★ THE REAL ONE: PHYSICAL CONNECTEDNESS OF THE EMITTED SOLIDS ──────────
  // Union-find over every emitted segment (curve spans AND connectors), joined when
  // their swept solids actually OVERLAP — segment-to-segment distance < r_a + r_b.
  // That is the question a slicer asks and the question a printed part answers, and
  // it is the only connectivity number this header is willing to call R3.
  //
  // Weighted by LENGTH, not by count: one 40 mm curve adrift matters more than a
  // 2 mm stub, and a count would hide that.
  std::size_t solid_components = 0;
  double solid_largest_component_length_fraction = 0.0;
  double solid_stranded_length_mm = 0.0;   // everything outside the largest component
  std::size_t solid_segments = 0;

  // §2(b) the overhang clamp — R6
  double overhang_angle_deg_used = 0.0;      // 0 => the clamp was DISARMED
  bool overhang_clamp_armed = false;
  long long clamped_steps = 0;
  double clamped_step_fraction = 0.0;
  std::size_t curves_touched_by_clamp = 0;
  double curves_touched_fraction = 0.0;
  // The counterfactual, measured on the SAME traced geometry: what fraction of the
  // emitted segments sit outside a 45-degree cone. This is what R6 reports "at 45"
  // when the clamp itself is disarmed, and it costs no second run.
  double segments_outside_45_fraction = 0.0;
  double segments_outside_default_fraction = 0.0;
  // ★ SPLIT, because the clamp can only reach one of them. A traced step is clamped
  // IN THE LOOP (§2a); a CONNECTOR is the shortest join between two curves and
  // re-angling it would break the join, which is the one thing R3 exists to protect.
  // So a connector is never clamped, and with the clamp armed the residual
  // out-of-cone population is exactly the connectors. Reported separately so that
  // residual is never mistaken for a leaky clamp.
  double curve_segments_outside_45_fraction = 0.0;
  double connectors_outside_45_fraction = 0.0;

  // §2(d) the ACHIEVED spacing window — R5
  double requested_spacing_min_mm = 0.0;
  double requested_spacing_max_mm = 0.0;
  double achieved_spacing_min_mm = 0.0;   // measured nearest-neighbour separation
  double achieved_spacing_max_mm = 0.0;
  double achieved_spacing_median_mm = 0.0;  // full sort, never a sample
  double strut_diameter_mm = 0.0;
  // ★ The factor the bead was scaled by to match the density the grading law asked
  // for, once the ACTUAL traced length was known (the idealised three-orthogonal-
  // families model over-estimates the bead). 1.0 = the model was right.
  double bead_calibration = 1.0;
  bool bead_calibration_floored = false;  // the minimum extrudable width won
  double min_extrudable_width_mm = 0.0;
  std::size_t spacing_raised_for_print_voxels = 0;       // d below the printable floor
  std::size_t spacing_raised_for_resolution_voxels = 0;  // d below one voxel
  double spacing_print_floor_mm = 0.0;       // t * sqrt(3 pi) / 2
  double spacing_resolution_floor_mm = 0.0;  // resolution_floor_voxels * grid spacing

  // §3(a) the CURVE-CROSSING COUNT — R7. Defined as
  //   curves_per_member(x) = member_width_mm(x) / spacing_mm(x)
  // the exact analogue of cells_per_member = W / S, reported under its OWN name.
  double min_curves_per_member = 0.0;
  double median_curves_per_member = 0.0;
  double curves_per_member_floor = kOrganicCurvesPerMemberFloor;
  std::size_t below_curves_per_member_floor_voxels = 0;  // counted OUT OF REGIME
  bool curves_per_member_measured = false;  // false when no width field was supplied

  // the emitted density
  std::size_t latticed_voxels = 0;
  double rho_min_emitted = 0.0;
  double rho_max_emitted = 0.0;
  double rho_median_emitted = 0.0;
  std::size_t rho_clamped_lo_voxels = 0;
  std::size_t rho_clamped_hi_voxels = 0;
  double emitted_volume_mm3 = 0.0;   // soup basis: crossings NOT deducted

  // ★ §3(c) — ORGANIC IS AESTHETIC-FIRST, AND THIS SAYS SO ON EVERY RUN.
  // A traced lattice is ANISOTROPIC BY CONSTRUCTION — aligning struts with the
  // principal directions is the whole point, and it is where Daynes' +101 % comes
  // from. The certification library carries exactly ONE CUBIC tensor per topology,
  // as a function of relative density alone. There is no measured tensor for this
  // geometry, so there is nothing to state a structural claim AGAINST. The
  // certificate still RUNS (§3d) — what it certifies is the octet tensor at the
  // emitted density, which does not describe this geometry, and that is exactly what
  // this flag is for.
  bool tensor_out_of_regime = true;
};

struct OrganicLattice {
  std::vector<OrganicCurve> curves;          // KEPT curves only, in trace order
  std::vector<OrganicConnector> connectors;
  // Grid-indexed (grid.voxel_count()). `mask[e] != 0` where the traced geometry put
  // solid into voxel e; `relative_density[e]` is the MEASURED fraction there, clamped
  // into the band when one was supplied.
  std::vector<char> mask;
  std::vector<double> relative_density;
  // Grid-indexed: the separation the tracer actually used at each candidate voxel
  // (mm), i.e. the derived "cell size". 0 off the candidate set.
  std::vector<double> spacing_used_mm;
  // ★ THE GEOMETRY THAT INDEXES THE THREE VECTORS ABOVE. Without it the emission stage
  // could not ask "is this point in the lattice REGION" -- only "is it in the part" --
  // and the fill pass laid struts through the solid gap between two regions 30 mm
  // apart, joining them into one body. Set by trace and grow; read by generate.
  Vec3 grid_origin{0, 0, 0};
  double grid_h = 0.0;
  int grid_nx = 0, grid_ny = 0, grid_nz = 0;
  // ★ THE PART'S OWN SOLID, grid-indexed: voxels that are solid material OUTSIDE the
  // lattice region. The support pass rasterises lattice only, so a column standing on
  // the part's solid floor -- the arch underside, a wall top, anything above the build
  // plate -- had NOTHING beneath it in the raster and was an island at its own base.
  // MEASURED: the middle of one region (x 72-150 mm, on the arch) held 7,361 mm at
  // node_merge and 0 mm after the support pass. Solid beneath a strut is support.
  std::vector<char> part_solid;
  OrganicReport report;

  // ── ★★ THE NET-SKIN (organic's diagrid) ─────────────────────────────────────
  // Trimming a lattice to a surface leaves every crossing strut ENDING on that
  // surface with nothing joining it — the literature calls these "hanging" struts,
  // and joining them into an external two-dimensional lattice is Aremu et al.'s
  // NET-SKIN (Additive Manufacturing, 2017). It is the alternative to a full skin:
  // it braces the incomplete boundary cells, it weighs far less, and it leaves the
  // surface open. It is also the only "rim"-shaped finish available on a part with
  // no analytic faces, which is every voxel or mesh part — `lattice_boundary_for`
  // creates half-spaces only for CAD faces and bolt bores, so the octet path's rim
  // emits nothing at all here.
  //
  // 0 disables it. Otherwise each landing joins its nearest neighbouring landings
  // out to this distance, MUTUALLY (both must want the other), which is what stops
  // one crowded corner growing a hairball.
  // The layer height the part will be PRINTED at. The mid-air-start check rasters Z
  // at this pitch, because a lowest point can clear a strut-radius layer test and
  // still float for two real layers. 0 falls back to the strut radius and the check
  // is then coarser than the machine.
  double layer_height_mm = 0.0;
  // ★ CUT THE SCATTER BELOW THE BASE (kOrganicBaseDominanceFraction). Needs a layer
  // height — without one there is no layer to test, and it does nothing rather than
  // guessing a pitch.
  bool trim_below_base = true;
  // The overhang fillet (job key grading.organic_overhang_fillet). Off = spans over
  // open air are left as drawn; the count of spans that WOULD have flared is kept.
  bool overhang_fillet = true;
  // ★ EMIT A BASE MAT at the trimmed base plane — a crossed planar grid spanning the
  // footprint, so the first layer is a foundation rather than whatever the trace
  // happened to leave there. Needs a layer height and a boundary.
  // ★★ GROW INSTEAD OF TRACE-THEN-REPAIR. See kOrganicGrowthMinAngleDeg. Off by
  // default: the existing path stays byte-identical until a job asks for this.
  bool growth = false;
  bool base_mat = true;
  // The pitch the WELD will raster at. The generator refuses to emit a base mat too
  // thin for that raster to keep — a mat below one voxel is erased outright, which is
  // how a deliberately thinned one vanished from the slice. 0 = unknown, check skipped.
  double weld_pitch_hint_mm = 0.0;
  // ★ FILL the low-stress interior where the tracer left holes. An override of the
  // grade, reported as one.
  bool fill_mat = true;
  double net_skin_reach_mm = 0.0;
  int net_skin_degree = 3;         // at most this many joins per landing

  // ── ★★ WHICH BOUNDARY FINISH ───────────────────────────────────────────────
  //   Clean — nothing. The bare trimmed lattice: every crossing strut simply ends
  //           on the surface. This is what organic did before.
  //   Rim   — join ONLY the landings that sit on an EDGE of the part, into a frame
  //           that follows those edges. This is the nearest honest equivalent of the
  //           octet path's rim on a part with no analytic faces: `lattice_boundary_for`
  //           builds half-spaces for CAD faces and bolt bores only, so on a voxel or
  //           mesh part the octet rim emits nothing at all. Edges are found from the
  //           BOUNDARY ITSELF — a landing is on an edge when the surface normal swings
  //           by more than kOrganicRimEdgeAngleDeg across it.
  //   Skin  — Aremu et al.'s NET-SKIN: join every landing to its neighbours, over the
  //           whole surface. Braces every hanging strut; heavier than the rim.
  enum class Finish { Clean, Rim, Skin };
  Finish net_skin_finish = Finish::Skin;
};

// ★ THE TRACER (§1). Pure: grid + candidate set + stress tensor + spacing field in,
// curves + connectors + per-voxel density out. It reads no job, writes no file and
// makes no decision the caller did not hand it.
//
//   grid       — the design grid.
//   candidate  — grid-indexed; candidate[e] != 0 marks voxel e traceable. Tracing
//                stops at the boundary of this set (§1b).
//   stress     — flattened grid-indexed (6 * voxel_count), Voigt
//                [xx,yy,zz,xy,yz,zx], TRUE shear, MPa —
//                FixedDesignAnalysis::stress_tensor_field verbatim.
//   spacing_mm — grid-indexed d_sep FIELD (mm). ★ THIS IS THE INPUT the whole method
//                turns on (§1c): cell size is derived from it, not the other way
//                round. Must be > 0 on the candidate set.
//   width_mm   — OPTIONAL grid-indexed local member width (mm), the same field the
//                grading law reads. Null => the curve-crossing count is not measured
//                and `curves_per_member_measured` says so.
//
// Throws std::invalid_argument on a size mismatch, a non-positive spacing on the
// candidate set, `min_extrudable_width_mm` <= 0 (the UNSET refusal, §2c), or a
// non-finite / degenerate build direction.
// ── ★ SYNTHETIC FOCAL STRESS FOR A DEAD WALL ───────────────────────────────────
// A region whose von Mises is ~2 % of the part's peak has no principal directions --
// they are rounding noise, and the tracer faithfully follows garbage. This stands in
// a synthetic tensor there: `foci` points on the 80 % ellipse of the region's two
// largest extents, weights alternating +1/-1 (half pull, half push, so the major
// family arcs BETWEEN foci instead of starbursting), each contributing
// w / (L^2 + soft^2) * (r (x) r). It is a TENSOR sum, so opposing foci make the
// saddle between them rather than cancelling, and the saddle is the sweep. Blended by
// a smoothstep of the real magnitude between 0.25*thr and thr (thr = `dead_fraction`
// of the peak over all candidates), so a live wall is untouched and a dead one is
// entirely synthetic; the synthetic tensor is scaled to magnitude thr so downstream
// laws see "low stress", not zero. Voigt [xx,yy,zz,xy,yz,zx], the tracer's order.
// Measured on the M2 stand (2026-08): back wall median vM 0.000422 MPa, 1.8 % of
// peak, DEAD; the focal field gave it a coherent weave a swirl could not.
struct SyntheticStressRegion {
  int region_id = 0;        // 1-based declared include-region id (voxel_region_id)
  int face_id = -1;         // the B-rep face the region was spawned from, for the receipt
  int foci = 4;             // 1..5
  double soft_mm = 0.0;     // 0 = a quarter of the region's largest extent
};
// ★ PER REGION, KEYED BY FACE (maintainer, 2026-09-05: "face ID is best"). The UI
// addresses a wall by the face it came from, so the receipt says what happened to
// THAT wall rather than summing every wall into one number.
struct SyntheticStressRegionReport {
  int region_id = 0;
  int face_id = -1;
  int foci = 0;
  double soft_mm = 0.0;           // the softening actually used (resolved from 0)
  std::size_t voxels = 0;
  std::size_t fully_synthetic = 0;
  std::size_t blended = 0;
};
struct SyntheticStressReport {
  std::vector<SyntheticStressRegionReport> per_region;
  std::size_t regions = 0;
  std::size_t voxels_in_regions = 0;
  std::size_t voxels_fully_synthetic = 0;   // blend weight < 0.05 real
  std::size_t voxels_blended = 0;
  double dead_threshold = 0.0;              // thr, in the tensor's units
  double peak_von_mises = 0.0;
};
// Modifies `stress` (6 per voxel) in place for candidate voxels whose
// `voxel_region_id` names a configured region. `dead_fraction` is the fraction of
// the peak below which a voxel counts as dead (0.02 is the measured noise floor).
SyntheticStressReport synthesize_focal_stress(
    const VoxelGrid& grid, const std::vector<char>& candidate,
    const std::vector<int>& voxel_region_id,
    const std::vector<SyntheticStressRegion>& regions, double dead_fraction,
    std::vector<double>& stress);

// ── ★ THE CELL-SIZE PROBE'S MEASURE: how much of the traced length reaches the part
// Curves are welded by node contact within r+r (the solver's rule) plus their own
// polyline, union-find over vertices; a component is ROOTED when any vertex touches
// part solid (`part_solid` on the lattice, grid geometry on the lattice). Reported
// per include region (the region of a curve's first vertex) and in total. This is a
// measurement of the TRACE, before emission, the support pass and the certificate;
// its agreement with the certificate's untied fraction is what calibrates it.
struct OrganicProbeRegion {
  int region_id = 0;
  std::size_t curves = 0;
  std::size_t curves_per_family[3] = {0, 0, 0};
  std::size_t components = 0;
  double traced_mm = 0.0;
  double rooted_mm = 0.0;
};
struct OrganicProbeResult {
  std::vector<OrganicProbeRegion> regions;   // region_id 0 = outside every include region
  std::size_t curves = 0;
  std::size_t components = 0;
  double traced_mm = 0.0;
  double rooted_mm = 0.0;
};
// ★ WELD THE CROSSINGS. Streamlines of different families cross mid-segment and
// share no vertex; the emission's node merge and tie pass make those junctions in
// the run, but a probe of the RAW trace has none -- measured: traced 3-5 read 50-77 %
// rooted and the certificate refused for disconnection before solving, where the
// run certifies at 3.9. For every vertex, the nearest segment of another curve
// within the two radii gets that vertex's foot inserted as a vertex of its own, so
// both the contact weld and the beam network see the junction. Returns the number
// of vertices inserted.
std::size_t weld_curve_crossings(std::vector<OrganicCurve>& curves);
// ★ TIE THE FREE ENDS, as the emission's tie pass does (kOrganicTieReachRatio x the
// separation): a curve end with no foreign vertex within its two radii reaches for
// the nearest foreign segment within `reach_mm`; the foot is inserted on that curve
// and a straight two-point tie (family 1, the end's radius) is appended. Without
// this a probe of a TRACED lattice reads 17-26 % untied and the certificate refuses
// before solving, where the run certifies. Returns the number of ties added.
std::size_t tie_curve_free_ends(std::vector<OrganicCurve>& curves, double reach_mm);
// ★ DROP THE LEGS, as the support pass does: from every curve end a vertical ray
// downward; the first foreign segment it passes within the two radii, up to
// `reach_mm` below, gets the foot inserted and a straight vertical leg appended.
// The emission adds thousands of these (12,402 on traced 3-5, 8,768 on grown), and
// a probe without them predicted margins 2.7-5x under the run's. Returns legs added.
std::size_t drop_curve_legs(std::vector<OrganicCurve>& curves, double reach_mm);
OrganicProbeResult probe_organic_rooting(const OrganicLattice& lat,
                                         const std::vector<int>& voxel_region_id);

OrganicLattice trace_organic_lattice(const VoxelGrid& grid,
                                     const std::vector<char>& candidate,
                                     const std::vector<double>& stress,
                                     const std::vector<double>& spacing_mm,
                                     const std::vector<double>* width_mm,
                                     const OrganicParams& params);

// ── the geometry ────────────────────────────────────────────────────────────────
// Emit the traced lattice as swept solids into `sink`, in a FIXED order (curves in
// index order, each polyline segment in order, then connectors in index order), so a
// streaming sink writes a byte-identical file for identical inputs — the same
// discipline generate_lattice holds. Node balls are emitted at every polyline vertex
// and at both ends of every connector, which is what makes the soup a single solid at
// each join.
//
// `boundary`, when non-null, CLIPS every centreline to the allowed region eroded by
// that strut's own radius, exactly as the octet generator does, so the swept SOLID
// stays inside the part rather than just the centreline.
struct OrganicGenStats {
  std::uint64_t triangles = 0;
  std::uint64_t struts = 0;      // emitted segment solids (curve spans + connectors)
  std::uint64_t nodes = 0;
  std::uint64_t clipped_segments = 0;
  std::uint64_t dropped_segments = 0;   // entirely outside the eroded region
  // Node balls whose SOLID would have breached the eroded region. The octet generator
  // drops these too, for the same reason: the clip certificate covers the swept strut,
  // not a sphere about its cut end. Counted, never silent.
  std::uint64_t dropped_nodes = 0;
  long long uncertified_spans_dropped = 0;  // clip slivers conservatively dropped
  double volume_mm3 = 0.0;              // soup basis; overlaps NOT deducted
  double min_strut_diameter_mm = 0.0;
  double max_strut_diameter_mm = 0.0;
  // ★ ANCHOR BALLS at clipped ends — the octet generator's own discipline (bar B6:
  // "no clipped end is left floating"), and organic had none. They are also what
  // makes `outer_finish: "skin"` legal for organic at all: the M4 guard refuses a
  // finish that emitted no geometry, and before this organic emitted none.
  std::uint64_t anchor_nodes = 0;
  std::uint64_t skin_triangles = 0;
  // ── ★★ THE NET-SKIN, MEASURED ──────────────────────────────────────────────
  std::size_t net_skin_landings = 0;      // clipped ends that sit on the surface
  std::size_t net_skin_members = 0;       // joins actually emitted
  double net_skin_length_mm = 0.0;
  std::size_t net_skin_landings_joined = 0;   // landings that got at least one join
  std::size_t net_skin_fallback_members = 0;  // joins the MUTUAL pass would not make
  std::size_t net_skin_edge_landings = 0;     // landings the RIM finish kept
  std::size_t net_skin_members_pruned = 0;    // finish joins the clip left as stubs
  std::size_t net_skin_degree_one = 0;        // ★ net nodes still carrying ONE join
  // ── ★★ THE GROUND-TIE REPAIR (the maintainer's own coupon method) ──────────
  // ★ WHY CONNECTEDNESS IS NOT PRINTABILITY, AND THIS IS THE DIFFERENCE.
  // `emitted_components` says the solids touch each other. It does NOT say the
  // material can be BUILT: a piece can be welded to the lattice and still begin in
  // mid-air, and a printer lays material bottom-up. The maintainer printed a cube
  // whose emitted geometry was 99.99 % one component and still had struts starting
  // above the plate.
  //
  // So the emitted solids are rasterised, flooded from the LOWEST OCCUPIED LAYER, and
  // every component the flood does not reach is tied down with a VERTICAL LEG dropped
  // from its own lowest voxel — then re-flooded, up to `kOrganicRepairRounds` times.
  // That is exactly the repair `graded_coupon.cpp` runs, and the coupon it produced
  // printed clean with supports off.
  //
  // ★ FLOODING FROM THE LATTICE'S OWN BASE IS CONSERVATIVE. In a real part the lattice
  // also meets the solid shell, which is ground too but is not in this span list — so
  // this may add a leg that the shell would have made unnecessary. It never omits one.
  long long floating_voxels_before = 0;
  long long floating_voxels_after = 0;   // ★ NON-ZERO IS A REFUSAL AT THE CALLER
  long long repair_legs_added = 0;
  int repair_rounds = 0;

  // ★★ PHYSICAL CONNECTEDNESS OF WHAT WAS ACTUALLY WRITTEN — i.e. AFTER the boundary
  // clip has trimmed and dropped spans. The tracer's own report measures the lattice
  // it TRACED; this measures the lattice in the file. The two can differ, because
  // clipping cuts spans away from the shared polyline vertex on both sides and leaves
  // a gap there, and that gap is invisible to every graph-level check.
  // ★★ FREE ENDS, MEASURED ON THE EMITTED SOLIDS — the thing the maintainer keeps
  // seeing and every previous metric kept missing. An endpoint of an emitted span is
  // FREE when no OTHER span's solid covers it. That is a strut tip hanging in space:
  // it carries nothing and, if horizontal, the printer bridges to nowhere.
  //
  // ★ WHY THE CURVE-GRAPH COULD NOT SEE THIS. "curves with fewer than two
  // connections" counts CONNECTORS on a curve. A curve can have two connectors and
  // still end in a free tip if the trim's notion of "outermost connector" and the
  // geometry disagree — and the ground-tie LEGS have free lower tips by construction.
  // This counts tips, on the solids, after everything.
  std::size_t free_ends = 0;              // AFTER the tie pass — the bar is ZERO
  double free_end_length_mm = 0.0;        // total length of spans carrying a free tip
  // ── ★★ §1(e3) — THE FREE-END TIE PASS ──────────────────────────────────────
  // ★ A FREE END MUST NOT BE CREATED, NOT PATCHED OVER BY A SURFACE FINISH. Every
  // emitted tip that no other solid covers is tied to the nearest material within
  // reach, as part of building the lattice. The diagrid is a FINISH and belongs to the
  // surface; this is the algorithm refusing to leave a strut tip in the air anywhere.
  //
  // ★ WHY IT IS MEASURED ON THE SOLIDS AND NOT ON THE CURVE GRAPH. Three earlier
  // metrics in this task reported a clean lattice while the geometry had hundreds of
  // hanging tips — the graph counts CONNECTORS on a curve, and a curve trimmed to its
  // outermost connector can still be CLIPPED afterwards into a new free tip that no
  // graph knows about. Ties are placed from what was written.
  std::size_t free_ends_before_tie = 0;
  std::size_t ties_added = 0;
  double tie_length_mm = 0.0;
  // Tips with NO material within `tie_reach` — nothing to tie to. These are the
  // honest remainder and are reported, never hidden.
  std::size_t free_ends_unresolved = 0;
  // ── ★★ §1(e4) — THE PRUNE (kOrganicPruneRounds states why) ─────────────────
  // Every tip a tie could not resolve is CUT, and the cut cascades. `free_ends` above
  // is measured AFTER this, on the same list that reaches the sink, and the bar is
  // exactly zero — excluding `plate_contacts`, which are tips resting on the build
  // plate and are supported by it.
  std::size_t pruned_spans = 0;
  double pruned_length_mm = 0.0;
  int prune_rounds = 0;
  std::size_t plate_contacts = 0;
  std::size_t nodes_merged = 0;          // endpoints snapped onto a shared node
  std::size_t merge_clusters = 0;        // shared nodes created
  std::size_t merge_degenerate_spans = 0;   // spans the merge collapsed to nothing
  // ── ★★ NOTHING STARTS IN MID-AIR ────────────────────────────────────────────
  // A LAYER-LOCAL bar, and it is not the same as `floating_voxels_*` above. That one
  // asks whether every piece is reachable from the plate in the FINISHED solid; this
  // one asks the printer's question — does every island of material in a layer land on
  // material in the layer beneath. A strut can be rigidly connected and still start
  // over open space, held only by struts printed later. THE BAR IS
  // `unsupported_islands_remaining == 0`.
  std::size_t unsupported_islands_found = 0;
  std::size_t unsupported_islands_remaining = 0;   // fragile: see the two below
  // ★ THESE ARE THE BAR, NOT THE ISLAND COUNT. Grouping is unstable — the same spans
  // read as 1 island or 21 depending on the cell size in its fourth decimal, because a
  // diagonal bridge in the flood either happens or does not. The AREA is stable and
  // both an internal census and an outside probe agree on it.
  std::size_t unsupported_cells_remaining = 0;
  double unsupported_volume_mm3 = 0.0;
  std::size_t support_legs_added = 0;
  double support_leg_length_mm = 0.0;
  int support_rounds = 0;
  // ★ DID THE REPAIR FINISH, OR RUN OUT OF BUDGET? `support_rounds == 8` read like
  // "it worked eight times" when it meant "it never converged". A repair that exits on
  // its round cap must say so.
  // ★ RENAMED, BECAUSE IT DESCRIBED AN INTERMEDIATE STATE. This is set inside the
  // support ROUND LOOP the moment a round finds no islands. SEVEN passes then run
  // before the census -- VDI slenderness, arching, the compaction of cuts, the
  // stranded drop, the fill mat, the finish, the net-skin -- several of which move
  // or delete geometry and can create new unsupported cells. A run could therefore
  // report support_converged=true and still be refused by the raster gate, which is
  // a green flag on a state that no longer exists by the time anything is written.
  //
  // The number that describes the SHIPPED geometry is unsupported_cells_remaining,
  // measured at the census after every pass. This one now says only what it means.
  bool support_rounds_converged = false;
  // Islands with no legal centreline anywhere beneath them — a vertical leg cannot
  // reach them without breaching the surface. Counted rather than skipped.
  std::size_t support_legs_impossible = 0;
  std::size_t support_legs_diagonal = 0;    // vertical was illegal; angled in instead
  // ── ★★ BRANCHED SUPPORT ─────────────────────────────────────────────────────
  std::size_t branch_seeds = 0;             // islands needing support
  std::size_t branch_merges = 0;            // ★ tips that coalesced into a trunk
  std::size_t branch_trunks = 0;            // branches that actually reached ground
  std::size_t branch_anchored_on_model = 0; // stopped on lattice, never reached base
  double branch_length_mm = 0.0;
  std::size_t support_post_stranded_dropped = 0;   // fragments the CUTS created
  // ★ THE NO-FRAGMENTATION GUARD. Cutting creates orphans that the size-based drop
  // above preserves; these record what the guard removed, so evisceration is VISIBLE
  // in the receipt instead of surfacing three stages later as a singular solve.
  int support_components_before = -1;    // -1 = the guard did not run
  int support_components_after = -1;
  int support_components_kept = -1;
  std::size_t support_fragments_dropped = 0;
  double support_fragment_length_mm = 0.0;
  // ── ★★ THE JOINT FIXED POINT ────────────────────────────────────────────────
  // Every span added or removed by ANY repair. A round that changes nothing is
  // quiescence, and that is the only state the census may be read in.
  std::size_t mutations = 0;
  int fixed_point_rounds = 0;
  bool fixed_point_converged = false;   // ★ false = ran out of rounds, NOT settled
  std::size_t support_spans_cut = 0;        // could not be held up, so not printed
  // Tips left dangling BY those cuts, eroded afterwards. The mid-air repair must not
  // reintroduce the free ends the prune exists to remove.
  std::size_t support_cleanup_pruned = 0;
  // ★ ENDPOINT CLEARANCE. A capsule ends in a spherical cap that reaches r in every
  // direction, while the clip only certifies the centreline ALONG the segment. These
  // count the ends walked inward to make the cap fit, and the spans dropped because
  // no point on them could.
  std::size_t endpoint_pulled_in = 0;
  std::size_t endpoint_span_dropped = 0;
  // ★ FIX (ii): spans deleted because the census found the cells they occupy hanging
  // in air. Delete-only, so it always terminates; reported so a run cannot lose
  // material silently.
  std::size_t unsupported_spans_cut = 0;
  double unsupported_length_cut_mm = 0.0;
  double endpoint_min_margin_mm = 1e30;   // tightest (boundary_dist - r) over ends
  // ★ HOW CLOSE THE SUPPORT RASTER CAME TO ITS CAP. Whether the pass ran at all is
  // already `support_grid_too_large`, which the caller refuses on; what was missing
  // is the MARGIN. The raster is sized by the thinnest strut in XY and the layer
  // height in Z, so it grows with part size, strut fineness and layer resolution
  // together — and a job one size step away from losing the support check entirely
  // should not look identical to one with room to spare. MEASURED on the M2 stand at
  // 128^3, 5-6 mm cell, 0.2 mm layers: 11.0M cells (427x117x221 at 0.4599 mm xy)
  // against the 120M cap, so ~11x of headroom.
  long long support_raster_cells = 0;      // RX*RY*RZ, whether or not the pass ran
  long long support_raster_cap = 0;        // the cap it was compared against
  // ── ★★ THE BASE TRIM ────────────────────────────────────────────────────────
  double base_trim_z_mm = 0.0;          // the swirl's layer; 0 = nothing was cut
  // ── ★★ VDI 3405-3-4:2019 COMPLIANCE, MEASURED ON WHAT WAS EMITTED ───────────
  std::size_t vdi_slenderness_violations = 0;   // spans with l/D above the limit
  std::size_t vdi_thin_bar_violations = 0;      // spans under the 1 mm minimum
  double vdi_max_slenderness = 0.0;
  double vdi_min_bar_diameter_mm = 0.0;
  double vdi_density_floor_applied = 0.0;       // 0 = the floor was not raised
  std::size_t base_trim_spans_cut = 0;
  std::size_t base_trim_spans_clipped = 0;
  double base_trim_length_mm = 0.0;
  bool base_trim_found = false;         // false = no dominant layer, nothing cut
  // ── ★★ THE BASE MAT ─────────────────────────────────────────────────────────
  std::size_t base_mat_struts = 0;
  double base_mat_length_mm = 0.0;
  // Points where the lattice actually reaches the base plane; the mat is emitted
  // only around these, so "how much foundation" is legible next to "for how many feet".
  std::size_t base_mat_touchdowns = 0;
  // ★ the crosses laid ON the touchdowns so the grid-snapped mat actually reaches the
  // struts standing on it. Without them the mat missed by 0.89-3.54 mm.
  std::size_t base_mat_stitches = 0;
  // ★ how many separate mats were laid: one per cluster of touchdowns. Two lattice
  // regions with nothing landing between them must read 2 here, never 1.
  std::size_t base_mat_clusters = 0;
  // ★ blobs the support pass would have called islands, held up by the PART'S SOLID
  // beneath them (OrganicLattice::part_solid). Zero with a populated part_solid means
  // the islands are not at the base -- look higher.
  std::size_t islands_held_by_solid = 0;
  // spans the fillet would have flared, left as drawn because the job switched it off
  std::size_t fillet_skipped_spans = 0;
  // raster voxels the repair-leg flood seeded from PART SOLID (not the plate)
  std::size_t flood_seeds_on_solid = 0;
  // components spared by the stranded drop because they stand on the plate or solid
  std::size_t stranded_rooted_kept = 0;
  // ★ VDI SLENDERNESS PROPPING. `violating` counts struts over the l/D the standard
  // allows for their angle; `propped` those a leg could be dropped under; `impossible`
  // those with nothing beneath to stand on. Reported separately because a strut that
  // could not be propped is still in the file, and a total would hide it.
  std::size_t slenderness_violating = 0;
  std::size_t slenderness_propped = 0;
  std::size_t slenderness_impossible = 0;
  std::size_t slenderness_props_added = 0;
  // ★★ CANTILEVER REACH. An island is called supported when ONE of its cells sits over
  // material — so an island held only at its centre, with a long arm over nothing,
  // passes. That is what the maintainer found in the slice: a bridge anchored at the
  // middle that does not reach the outside for several layers. These measure the thing
  // the support flag does not: how far, in mm, the furthest cell of an island is from
  // the nearest cell of that island that IS over material.
  double cantilever_max_reach_mm = 0.0;
  std::size_t cantilever_islands = 0;      // islands whose reach exceeds the bridge limit
  std::size_t cantilever_layers = 0;       // layers carrying at least one such island
  // ★★ ARCHING. `arched` counts spans bowed into an arch; `arch_rise_mm` the tallest
  // apex raised. A span that was shallow but already held along its length is not
  // arched and not counted — the bar is "unsupported for long enough to droop", not
  // "shallow".
  std::size_t arched_spans = 0;
  double arch_max_rise_mm = 0.0;
  // ★★ FILLETING. `filleted` counts spans re-emitted with a flared profile;
  // `fillet_unresolved` those whose flare hit the radius cap before the two sides met,
  // so the span is better but not fixed — reported separately, never folded into the
  // success count.
  // ★★ GROWTH REPORTING. `growth_steps` is how many tip advances were taken.
  //
  // `growth_blocked` counts steps that TERMINATED FOR WANT OF SUPPORT: the clamped
  // direction was taken, the candidate point was tested, and nothing held it. It was
  // previously described as "how often the stress field asked for something the
  // machine cannot build", which is the CLAMP's event, not this one — and it reads 0
  // on every crowded fixture because the clamp fires first and the tip's own trail
  // then supports the step. The field's demand is `growth_clamped`.
  std::size_t growth_seeds = 0;
  std::size_t growth_steps = 0;
  std::size_t growth_blocked = 0;
  std::size_t growth_curves = 0;
  // ★★ THE CLAMP IS THE EVENT WORTH COUNTING. `growth_clamped` is the number of steps
  // where the field asked to go flatter than the printable cone and was pulled back to
  // it; `growth_clamp_max_deg` is the largest such departure — how far below the cone
  // the field wanted to go, in degrees, on the worst step. Together they say how much
  // of this lattice is the field's shape and how much is the machine's limit.
  std::size_t growth_clamped = 0;
  double growth_clamp_max_deg = 0.0;
  // Branches offered, and how many were refused for want of support at their root.
  std::size_t growth_branches = 0;
  std::size_t growth_branch_refused = 0;
  // ★ AND WHY, because the three causes want different fixes: outside the region is
  // the shape's doing, unsupported is the printer's, and CROWDED is the seeding and
  // spacing law's. Lumped together they read as a printability problem that the rest
  // of the receipt contradicts.
  std::size_t growth_branch_refused_region = 0;
  std::size_t growth_branch_refused_support = 0;
  std::size_t growth_branch_refused_crowded = 0;
  // ★ ...and how many of those crowded branches became a CONNECTOR instead of nothing.
  std::size_t growth_branch_joined = 0;
  // ★ steps where the upward bias, not the stress field, decided the heading.
  std::size_t growth_lifted = 0;
  // Tips that reached the neighbour they crowded instead of stopping beside it.
  std::size_t growth_joins = 0;
  // ★★ JOINS REFUSED FOR SPAN. A join segment lands on material at both ends, so it is
  // a BRIDGE, not an overhang — but a bridge still has a length limit. Counted here
  // when the horizontal run of the join would exceed kOrganicMaxCantileverMm and the
  // tip was made to stop or deflect instead.
  std::size_t growth_join_refused_span = 0;
  // transfer ties (kOrganicXferTieMinorRatio): launched, landed, and why not
  std::size_t growth_ties_seeded = 0;
  std::size_t growth_ties_landed = 0;
  std::size_t growth_ties_refused_minor = 0;    // field too uniaxial here
  std::size_t growth_ties_refused_reach = 0;    // nothing to land on within reach
  double growth_tie_length_mm = 0.0;
  // void re-seeding (kOrganicReseedVoidRatio): voids found, stubs that landed, length
  std::size_t growth_reseed_voids = 0;
  std::size_t growth_reseed_landed = 0;
  std::size_t growth_reseed_failed = 0;
  double growth_reseed_length_mm = 0.0;
  bool growth_tip_budget_hit = false;
  // ★ THE DISCRETISATION THIS RESULT WAS COMPUTED IN. Growth asks its support question
  // one layer at a time, so the answer is only meaningful alongside the layer height
  // that produced it. Recorded so a receipt can never be ambiguous about which.
  double growth_layer_height_mm = 0.0;

  // ── ★★ THE LENGTH CENSUS (task PR-353 third follow-up §1) ───────────────────
  // WHERE THE MILLIMETRES GO. Measured on the maintainer's sweep: growth produces
  // 3300-3900 mm of curve at separation 4.5-5.5 and the file receives 15-495 mm of
  // it. That is not fragmentation, it is DELETION, and no connectivity ratio can see
  // it — separation 7.0 reports ONE component and largest-fraction 1.0000 on 11.3 %
  // of the material, because a ratio is perfect when both its terms are near zero.
  //
  // So: total live span length at each stage of the emission pipeline, in order.
  // Deltas between consecutive stages name the pass that took the material — and
  // because some passes ADD (base mat, ground tie, branch support, fillet), a signed
  // delta is the honest instrument rather than a subtraction count.
  //
  // `census_grown_len_mm` is the INPUT: the summed length of the curves handed to the
  // emitter, so survival = census_len_mm[Written] / census_grown_len_mm is answerable
  // without the caller holding the lattice.
  enum CensusStage {
    CensusEmitted = 0,      // spans laid down from the curves, before any pass
    CensusNodeMerge,
    CensusBaseCut,
    CensusSupportPrune,
    CensusStrandedDrop,
    CensusGroundTie,
    CensusBranchSupport,
    CensusDangling,
    CensusStrandedDrop2,
    CensusFillMat,
    CensusFinish,
    CensusWritten,          // the final list the file is built from
    kCensusStages
  };
  // ★ -1 MEANS "THIS STAGE DID NOT RUN", and it must not be 0. Several passes sit
  // inside conditionals; a zero-initialised array reports an unrun pass as having
  // deleted everything, which is the same unmeasured-zero error this receipt already
  // refuses elsewhere. Readers must test for negative before differencing.
  double census_len_mm[kCensusStages] = {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1};
  // ★ COMPONENT COUNT BESIDE THE LENGTH, AT EVERY STAGE. A LENGTH census is blind to
  // a pass that changes TOPOLOGY without changing material: the node merge welds
  // coincident endpoints, which fuses components and moves no length at all. So
  // "the support prune is the sole deleter" is established in the LENGTH dimension
  // only, and a claim about CONNECTIVITY cannot rest on it.
  //
  // MEASURED at separation 4.5: the emitted spans with the prune ablated give 16
  // components with the largest at 10.69%, while the PRE-EMISSION curve network gives
  // 45 components with its largest at 10.32%. Same largest fraction, nearly three
  // times the component count -- something between the two merges components while
  // preserving length, and only a component census can see it.
  //
  // -1 means the stage did not run.
  int census_components[kCensusStages] = {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1};
  double census_grown_len_mm = 0.0;
  std::size_t filleted_spans = 0;
  std::size_t fillet_unresolved = 0;
  double fillet_max_radius_mm = 0.0;
  bool base_mat_radius_raised_for_raster = false;
  double base_mat_z_mm = 0.0;
  // ── ★★ THE FILL MAT ─────────────────────────────────────────────────────────
  std::size_t fill_mat_cells = 0;      // empty cells the tracer left behind
  std::size_t fill_mat_struts = 0;
  // ★ empty cells fill SKIPPED because they lie outside the lattice region -- inside
  // the part, but between regions or in solid the grading law kept. Measured before
  // the gate: 4,143 mm of fill in a 30 mm gap between two face prisms.
  std::size_t fill_mat_cells_outside_region = 0;
  double fill_mat_length_mm = 0.0;
  double support_cut_length_mm = 0.0;
  std::size_t unsupported_cells_found = 0;  // before any repair
  double support_layer_height_mm = 0.0;     // the Z pitch the check actually used
  bool support_grid_too_large = false;      // ★ CHECK DID NOT RUN — never a pass
  std::size_t stranded_components_dropped = 0;
  std::size_t stranded_spans_dropped = 0;
  double stranded_length_dropped_mm = 0.0;

  std::size_t emitted_components = 0;
  double emitted_largest_length_fraction = 0.0;
  double emitted_stranded_length_mm = 0.0;
};

// One span as it was ACTUALLY EMITTED — after the boundary clip. This is what the
// welded body is built from, so the weld describes the file rather than the intent.
struct OrganicSpan {
  Vec3 a{0, 0, 0}, b{0, 0, 0};
  double r = 0.0;
};

class LatticeBoundary;  // topopt/lattice_boundary.hpp
class MeshDistance;     // topopt/mesh_distance.hpp — the EXPORTED shell's distance

struct LatticeGenObserver;  // topopt/lattice_gen.hpp — the SAME read-only tap

// ★★ GROWN organic: printability as a construction rule. Same inputs as the tracer —
// it calls the tracer first for the field, the spacing floors and the bead law — but
// lays the curves down in LAYER ORDER from the base, refusing any step whose underside
// is unsupported. Mid-air starts and free ends are not repaired but inexpressible.
// `gstats` receives the growth counters; pass nullptr if not wanted.
OrganicLattice grow_organic_lattice(const VoxelGrid& grid,
                                    const std::vector<char>& candidate,
                                    const std::vector<double>& stress,
                                    const std::vector<double>& spacing_mm,
                                    const std::vector<double>* width_mm,
                                    const OrganicParams& params,
                                    OrganicGenStats* gstats = nullptr);

// The census stage names, in enum order. One table, so the receipt and the log can
// never disagree about which pass a number belongs to.
const char* organic_census_stage_name(int stage);

OrganicGenStats generate_organic_lattice(const OrganicLattice& lat,
                                         TriangleSink& sink,
                                         const LatticeBoundary* boundary = nullptr,
                                         int nseg = 8,
                                         // The same tap the octet generator offers, so
                                         // the export's no-protrusion measurement can
                                         // ATTRIBUTE a bad vertex to a pass instead of
                                         // reporting it "unattributed". Observing never
                                         // changes the emitted bytes.
                                         const LatticeGenObserver* observer = nullptr,
                                         // Optional: the POST-CLIP spans, in emission
                                         // order. Non-null to weld them below.
                                         std::vector<OrganicSpan>* emitted_out = nullptr,
                                         // ★★ THE SHELL AS WRITTEN, so the generator
                                         // and the export guard measure ONE surface.
                                         // The clip erodes the analytic boundary; the
                                         // guard measures the MESHED shell, and the
                                         // two disagree — measured, 1.75 um on the M2
                                         // stand, against a 0.1 um allowance. An
                                         // endpoint 27.7 nm inside the boundary put
                                         // its cap 1.73 um outside the shell and the
                                         // export refused the file. Containment in a
                                         // surface the clip never sees cannot be
                                         // guaranteed, so it is handed the same
                                         // MeshDistance the guard reads. Null keeps
                                         // the old behaviour exactly.
                                         const MeshDistance* shell = nullptr);

// ── ★ THE WELDED, SINGLE-BODY VERSION ──────────────────────────────────────────
//
// ★ WHY THIS IS NOT COSMETIC. The soup the generator emits is exactly how the shipped
// octet generator emits a lattice: every strut its own closed prism, every node its own
// icosahedron, interpenetrating. That is fine for a slicer that unions the solid — and
// it is NOT fine for one that analyses the MESH, which sees thousands of separate
// closed shells and flags every one that does not touch the plate as a FLOATING BODY.
// That is precisely what the maintainer saw. The material is connected (the emitted-
// span connectivity report says 99.99 % in one component); the MESH is not one object.
//
// So: rasterise the emitted spans into an occupancy grid, march it, and keep the
// largest component. ONE watertight body, same strut layout, same diameters, same
// spacing — only the surface tessellation differs, and it is faceted at the raster
// pitch. This is the identical recipe the maintainer's own printed coupon was built
// with (evidence/2026-08-20-lattice-only-grading/coupon/graded_coupon.cpp), so the two
// are measurable against each other on the same basis.
//
// ★ THE DROPPED COMPONENTS ARE SEALED CAVITIES, and dropping them FILLS them solid:
// air pockets fully enclosed where struts cross, which marching cubes closes with its
// own inner surface. They are not floating material. They ARE a drainability question
// this codebase already tracks, so the count is reported rather than swallowed.
struct OrganicWeldStats {
  double pitch_mm = 0.0;
  int nx = 0, ny = 0, nz = 0;
  long long occupied_voxels = 0;
  int components_before = 0;      // sealed cavities = this minus 1
  int components_after = 0;
  int sealed_cavities_filled = 0;
  bool watertight = false;
  double volume_mm3 = 0.0;        // ★ the TRUE UNION volume — overlaps deducted
  std::size_t triangles = 0;
};

// `pitch_mm` 0 => derived from the thinnest emitted strut (a quarter of its diameter),
// which is what resolves a strut rather than aliasing it. `max_voxels` caps the raster
// so a fine lattice in a big part cannot allocate without bound; the pitch is coarsened
// to fit and the pitch actually used is reported.
TriangleMesh organic_weld(const std::vector<OrganicSpan>& spans, double pitch_mm,
                          long long max_voxels, OrganicWeldStats& stats,
                          // ★ CUT THE SOLID FLAT AT THIS Z. A centreline trim leaves
                          // each clipped capsule a hemispherical cap a radius below the
                          // plane — the very dots the base trim removes. Only a cut on
                          // the SOLID gives a flat face. -inf = no cut.
                          double floor_z = -1e30);

}  // namespace topopt

#endif  // TOPOPT_ORGANIC_LATTICE_HPP
