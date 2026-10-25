#ifndef TOPOPT_LATTICE_ALGORITHM_HPP
#define TOPOPT_LATTICE_ALGORITHM_HPP

// ★ THE LATTICE ALGORITHM SELECTOR (task 2026-08-21-organic-lattice, §4).
//
// THREE ALGORITHMS, ALL CALLABLE, so a UI can be built against them separately. This
// enum is ORTHOGONAL to `CellSizeMode` (cell_plan.hpp): the mode says HOW THE CELL IS
// CHOSEN (fixed / auto / swept / fit), this says WHAT KIND OF LATTICE IS LAID DOWN.
//
//   DOUBLED — the DYADIC LADDER. cell_plan.hpp. Cells of different size meet at SHARED
//             NODES because the admissible sizes are S0 * 2^L on an aligned, 2:1
//             balanced octree, so a coarse cell's nodes nest in the fine grid. That
//             nesting IS the transition handling, and it is why the two alternatives
//             (conformal warp, banded regions) were measured and rejected in PR 235.
//             ★ THE DEFAULT, so every existing job is byte-identical.
//   STEPPED — ONE CELL PER DECLARED REGION, taken from the derivation VERBATIM, with
//             NO TRANSITION HANDLING: regions abut at whatever cells they each derived
//             and the nodes do not line up. It is `Fit` WITHOUT THE DYADIC SNAP.
//             ★ THE COST OF THAT IS A REAL NUMBER AND THIS ALGORITHM MEASURES IT —
//             see `LatticeSteppedStats::floating_ends`. PR 235 rejected banded regions
//             precisely because an unshared node is a floating strut end; STEPPED does
//             not pretend otherwise, it counts them.
//   ORGANIC — struts TRACED along the stress field, spacing as the input, cell size
//             derived from the spacing. topopt/organic_lattice.hpp.
//             ★ AESTHETIC INTENT ONLY — see that header's `tensor_out_of_regime`.
//
// ★ WHAT ALL THREE SHARE, AND IT IS NOT NEGOTIABLE (§4a): every one of them emits a
// PER-VOXEL RELATIVE DENSITY. Certification, min-feature, the frozen and protect masks,
// the clearance keep-outs and every exporter read one and only one. That contract is
// what makes the selector cheap: nothing downstream branches on the algorithm.

#include <string>
#include <vector>

namespace topopt {

enum class LatticeAlgorithm { Doubled, Stepped, Organic };

// ── ★ WHICH CERTIFICATE A RUN ACTUALLY USES (task 2026-09-28-lattice-types-core) ──
// Two instruments, and until now the choice was implicit in one `if` in run_job.cpp's
// anonymous namespace, which is why a Stepped job could be FORCED to name
// `structural_certification: "beam_network"` and then be certified by the tensor
// anyway -- the key named an instrument core did not run.
//
//   BeamNetwork        solves the struts as a frame. It welds ON CONTACT, so a strut
//                      ending mid-member is fused as the print fuses it, and a seam is
//                      just geometry being solved.
//   HomogenisedTensor  the cubic tensor at the emitted density. It ASSUMES SHARED
//                      NODES, so it over-claims wherever cells of different families
//                      abut -- a 9 mm cell's face centre lands mid-strut on an 8 mm
//                      neighbour, and there are thousands of such seams in a plan.
//
// `any_step_plan` is "the job carries lattice.stepped_cells". It is the bit that
// separates ANY-STEP Stepped (families interleaved, nodes unshared, seams everywhere)
// from LEGACY Stepped (one cell per region, no plan), which keeps the tensor.
//
// Pure, and takes the bit rather than reading a job, so every combination is reachable
// by test -- including the ones no job can produce today.
enum class LatticeCertificateKind { BeamNetwork, HomogenisedTensor };

LatticeCertificateKind lattice_certificate_kind(LatticeAlgorithm alg,
                                                bool any_step_plan);

// The algorithms the run certifies with the BEAM NETWORK, for the app's Structural
// preview floor: it keys on what core ACTUALLY runs, never on what the schema accepts.
// "stepped" appears here because any-step Stepped is certified that way; legacy
// Stepped (no plan) is not, and the names cannot express that distinction -- callers
// that need it ask `lattice_certificate_kind`.
std::vector<std::string> lattice_beam_network_certified_algorithms();

// "doubled" | "stepped" | "organic". Throws std::logic_error for an enum value with no
// name — a new case must be named here before anything can serialize it, never a
// silent fallback (the same posture cell_size_mode_name takes).
const char* lattice_algorithm_name(LatticeAlgorithm a);

// Parse an algorithm name; false (and `out` untouched) for anything else — a job
// schema never silently falls back to an algorithm the user did not ask for.
bool lattice_algorithm_from_name(const char* name, LatticeAlgorithm& out);

// Every algorithm name, in enum order — the one source a picker reads, so a UI set can
// never drift from this enum.
std::vector<std::string> lattice_algorithm_names();

}  // namespace topopt

#endif  // TOPOPT_LATTICE_ALGORITHM_HPP
