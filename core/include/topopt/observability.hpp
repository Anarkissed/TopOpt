#pragma once

#include <cstddef>
#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

#include "topopt/simp.hpp"   // SimpIterationObservation
#include "topopt/voxel.hpp"  // VoxelGrid

// Handoff 114 — per-iteration OBSERVABILITY primitives (core, Eigen-free, in the
// always-built base library so they unit-test in every configuration).
//
// WHY (handoff 106 / 113): the "10-hour" design-box run left no per-iteration
// record on disk, so its cost had to be forensically reconstructed from three STL
// mtimes; the 64-scale warm gate's wall-clock was thermally contaminated and
// nobody could tell until after; and the trajectory-extrapolation investigation
// needs per-iteration density fields as data. This TU turns that reconstruction
// into a direct read: a tiny append-and-flush per-iteration CSV, opt-in float16
// density snapshots, and a run version/config record.
//
// THE ONE RULE (observability edition): every writer here is a pure OBSERVER —
// it consumes the optimizer's read-only per-iteration hooks and never touches the
// design, so a run with capture on produces a byte-identical design to one with
// capture off (proven in the golden test).

namespace topopt {

// ---------------------------------------------------------------------------
// IEEE-754 binary16 (half) codec. Round-to-nearest-even float32 -> float16 and
// the exact inverse. Pure integer bit-twiddling — no <stdfloat>, no dependency.
// Densities live in [0, 1]; over that range the round-trip max-abs error is
// bounded by half's step near 1.0 (2^-11 ~ 4.9e-4), which the round-trip test
// asserts.
std::uint16_t float_to_half(float value);
float half_to_float(std::uint16_t half);

// ---------------------------------------------------------------------------
// Deliverable 1 — the per-iteration CSV.
//
// The schema (documented here, in the handoff, and pinned by the golden test):
//
//   rung,iter,wall_ms,compliance,achieved_vf,plateau,cg_iters,cg_multigrid,beta,
//   hier_built,mg_cycles_attempted,infeasible,recycle_dim
//
//   rung          0-based ladder index
//   iter          1-based iteration within the rung (monotone; a conditional
//                 run's projection phase continues the same rung's numbering)
//   wall_ms       wall-clock epoch milliseconds when the row was written (the
//                 durable timestamp handoff 106 had to reconstruct from mtimes)
//   compliance    objective of the analysis density at the START of the step
//   achieved_vf   achieved continuous (physical) volume fraction after the step
//   plateau       MMA objective-plateau detector verdict this iter (0/1); the
//                 iter it first reads 1 is the plateau-stop iter
//   cg_iters      CG iterations of this step's penalized solve
//   cg_multigrid  1 if MG-CG ran, 0 if it fell back to Jacobi-CG
//   beta          Heaviside-projection continuation sharpness β active this iter
//                 (handoff 123): 0 while NOT projecting (plain OC/MMA, incl. a
//                 conditional run's grayscale phase before the gate fires), else
//                 the stage β (1/2/4/…). The iter beta first reads > 0 is where
//                 conditional projection FIRED for that rung.
//   hier_built    (handoff 128) 1 iff a multigrid hierarchy BUILT this solve. With
//                 cg_multigrid=0 this splits the fallback: 1 = the V-cycle
//                 STAGNATED past its budget (stagnation, 125); 0 = the grid never
//                 coarsened (build-rejection, 122) or the 127 latch skipped the
//                 build. Always 0 on the Jacobi-CG paths (MG not requested).
//   mg_cycles_attempted  (handoff 128) MG-CG V-cycles this solve ran: the
//                 converged count when cg_multigrid=1, the budget when it
//                 stagnated, 0 when no hierarchy was built/attempted.
//   infeasible    (handoff 131) the RUNG-INFEASIBILITY verdict at this iteration
//                 (0/1). 1 means the signature fired — the objective sustained
//                 >= 100x this rung's starting compliance with a >= 4x CG blow-up
//                 for 5 consecutive iterations — and the rung was ENDED there as
//                 "load path lost". It can read 1 on at most ONE row per rung, and
//                 that row is the rung's last. 0 on every row of a healthy rung.
//   recycle_dim   (handoff 133) Krylov recycle columns that actually
//                 preconditioned this solve: 0 = recycling off, the run's bootstrap
//                 solve (which only harvests), or — in the armed Jacobi-only
//                 posture — a solve that ran MG-CG and was therefore not wrapped.
//                 k (16 in production) on a recycled Jacobi solve. Read WITH
//                 run_info's krylov_recycle_wrap_multigrid: with it false, a 0 here
//                 next to cg_multigrid=1 is the by-design no-op, not a failure.
//                 With cycle == 1 (the production value) the setup matvecs charged
//                 to this solve equal this column.
//
// A row is ~60-95 bytes, so a full 4-rung production run (~800 rows) is < 80 KB.
extern const char kIterationCsvHeader[];

// Streams per-iteration rows to a file, one header + one row per call, FLUSHING
// after every row so a crash (or a manual cancel — the 106 case) leaves every
// completed iteration on disk. Not copyable; holds the open stream for the run.
class IterationCsvWriter {
 public:
  // Opens `path` (truncating any prior file), writes the header, and flushes.
  // Throws std::runtime_error if the file cannot be opened/written.
  explicit IterationCsvWriter(const std::string& path);

  // Appends one row for `obs` at ladder `rung`, stamping the current wall-clock
  // time, and flushes. `obs` is the optimizer's read-only per-iteration record.
  void append(std::size_t rung, const SimpIterationObservation& obs);

  // Test seam: append with an explicit wall timestamp (deterministic golden test).
  void append_at(std::size_t rung, const SimpIterationObservation& obs,
                 long long wall_ms);

  std::size_t rows() const { return rows_; }

 private:
  std::ofstream out_;
  std::string path_;
  std::size_t rows_ = 0;
};

// ---------------------------------------------------------------------------
// Deliverable 2 — density snapshots (opt-in; disk cost is real).
//
// SIZE MATH, stated honestly: one float16 snapshot is 2 bytes/voxel, so the real
// 5.4M-voxel production domain is ~10.8 MB/snapshot; a 500-iteration run captured
// every N=10 iterations is ~50 snapshots ~= 550 MB. Hence the opt-in default-OFF
// and the per-job cap with oldest-eviction below.

// Write one snapshot: `<dir>/<basename>.f16` (raw little-endian uint16 per voxel,
// grid order i + nx*(j + ny*k), x-fastest) plus `<dir>/<basename>.json` sidecar
// with dims, spacing, origin, rung, iter and the boundary flag. `dir` is created
// if absent. Throws std::runtime_error on any IO failure or a size mismatch.
void write_density_snapshot(const std::string& dir, const std::string& basename,
                            const VoxelGrid& grid,
                            const std::vector<double>& density,
                            std::size_t rung, int iteration, bool boundary);

// Read a `.f16` raw file back into floats (round-trip test / downstream readers).
// Throws std::runtime_error if the file is missing or not exactly `count` halves.
std::vector<float> read_density_f16(const std::string& path, std::size_t count);

// Cadence + per-job cap manager for the driver's density-snapshot feed. Policy:
//   * boundary events (a rung's converged field) are ALWAYS written and are
//     NEVER evicted — they are the terminal/per-rung designs;
//   * non-boundary events are written every `every_n` iterations;
//   * once the number of retained NON-boundary snapshots exceeds `cap`, the
//     OLDEST non-boundary snapshot (its .f16 + .json) is deleted.
// So disk is bounded to ~(cap + #rungs) snapshots. `cap <= 0` disables eviction.
class SnapshotCapture {
 public:
  SnapshotCapture(std::string dir, int every_n, int cap);

  // Consider one snapshot event. Returns true iff a snapshot was written. Applies
  // the cadence, writes, then enforces the cap by evicting the oldest per-iter
  // snapshot. `iteration` is 1-based within `rung`.
  bool capture(const VoxelGrid& grid, const std::vector<double>& density,
               std::size_t rung, int iteration, bool boundary);

  std::size_t written() const { return written_; }
  std::size_t evicted() const { return evicted_; }

 private:
  std::string dir_;
  int every_n_;
  int cap_;
  std::size_t written_ = 0;
  std::size_t evicted_ = 0;
  // Basenames of retained NON-boundary snapshots, oldest first (eviction queue).
  std::vector<std::string> iter_snaps_;
};

// ---------------------------------------------------------------------------
// Deliverable 3 — the run version record.
//
// The 113 lesson: never again reconstruct "which build ran this" from inference.
// The CLI stamps its fingerprint + the ACTUAL solver / warm / precision / thread
// config it ran under into the job dir (run_info.json), so the era is provable.
struct RunInfo {
  std::string cli_version;   // topopt::version()
  std::string fingerprint;   // TOPOPT_BUILD_FINGERPRINT (core git sha or "dev")
  std::string mode;          // job.mode
  std::string material;      // job.material
  // The TRUE source format the user supplied ("step" | "stl" | "3mf"). When the
  // app normalises a 3MF to an STL working copy (handoff 2026-07-26-3mf-optimize-
  // path) the model file is STL but this stays "3mf", so run_info never loses the
  // provenance. Derived from job.source_format, else from the model's extension.
  std::string source_format;
  int resolution = 0;
  std::string load_source;   // "loadcase" | "self_weight"
  std::string solver;        // resolved SolverKind name (the REQUESTED solver)
  // Whether the geometric-multigrid accelerator ACTUALLY ran (the OBSERVED
  // outcome), and its hierarchy depth. These are an outcome, not config, so they
  // are known only AFTER the run: the up-front write leaves cg_multigrid_observed
  // false and the serializer emits JSON null for both, so an unfinished/crashed
  // run asserts NOTHING about multigrid (walk-back Amendment 1 — an earlier version
  // wrote the optimistic intent `true` up-front, and a run that never finished kept
  // that false-positive, which is exactly what misdiagnosed the res-128 fallback).
  // The post-run finalize sets cg_multigrid_observed=true with the real values.
  // cg_multigrid == false while `solver` names a multigrid kind is a SILENT
  // FALLBACK to Jacobi-CG — a slowdown the CLI also WARNs for. mg_levels is 0 when
  // MG did not run. The authoritative per-solve record is the iterations.csv
  // `cg_multigrid` column; this is the run-granularity summary.
  bool cg_multigrid = false;
  int mg_levels = 0;
  bool cg_multigrid_observed = false;  // false => emit null (outcome not yet known)
  // Handoff 128 — the run-level fallback MODE, finalized post-run alongside
  // cg_multigrid (null until then, same discipline as Amendment 1). One of:
  //   "carried"           MG carried the run (cg_multigrid true).
  //   "stagnated-latched" MG never carried, but a hierarchy DID build on at least
  //                       one solve — the V-cycle stagnated past its budget and
  //                       (after 3 consecutive stagnations) the 127 latch turned
  //                       MG off for the rest of the run. A convergence problem.
  //   "build-rejected"    no solve ever built a hierarchy — the grid could not be
  //                       coarsened (a coarsenability problem, 122).
  // Turns the build-rejection vs stagnation question (which the surviving CSV/JSON
  // could not answer, 125 §0) into a one-line read. Empty string + not-observed =>
  // JSON null; also null (and mode empty) when the requested solver is not a
  // multigrid kind (no fallback concept applies).
  std::string mg_mode;
  bool mg_mode_observed = false;
  bool galerkin_block_cache = false;
  bool mixed_precision = false;
  int matfree_threads = 0;   // resolved matrix-free thread count
  // Handoff 133 — Krylov recycling echo. `krylov_recycling` is the ACTUAL
  // process-global state the run executed under (read from
  // fea_krylov_recycling_enabled, never inferred), and `krylov_recycle_dim` is the
  // configured subspace dimension k. Echoed even when off — the 132 discipline: a
  // run record that only mentions an accelerator when it fired cannot be used to
  // rule the accelerator OUT of a later diagnosis.
  bool krylov_recycling = false;
  int krylov_recycle_dim = 0;
  // Handoff 133 §10 — the ARMED posture: false = the correction wraps only the
  // Jacobi-preconditioned loop and multigrid solves are untouched. Echoed because
  // it changes which solves the accelerator touched at all, so a run record that
  // omitted it could not be used to interpret the CSV's recycle_dim column.
  bool krylov_recycle_wrap_multigrid = false;
  bool warm_start_inherit = false;
  bool warm_start_coarse = false;
  bool projection = false;
  // Handoff 123 — CONDITIONAL MMA Heaviside projection echo. `..._threshold` is
  // the armed grayness gate threshold (0 = disabled). The two per-rung vectors are
  // filled AFTER the run from MinimizePlasticResult (like cg_multigrid): one entry
  // per evaluated rung. `conditional_projection_fired[i]` is 1 iff rung i's
  // grayscale field exceeded the threshold and was continued into β-projection;
  // `conditional_projection_rung_mnd[i]` is the design-region Mnd measured on that
  // rung's grayscale field (NaN — serialized as JSON `null` — if the rung was
  // cancelled before it converged, so nothing was measured). Both vectors are
  // EMPTY when the gate was disarmed (threshold 0, OC, or always-on projection).
  double conditional_mma_projection_mnd_threshold = 0.0;
  std::vector<int> conditional_projection_fired;
  std::vector<double> conditional_projection_rung_mnd;
  // Handoff 131 — RUNG-INFEASIBILITY echo. `infeasible_compliance_ratio` /
  // `infeasible_cg_blowup` / `infeasible_window` are the armed thresholds of the
  // fast-fail detector (window 0 = disarmed); they are CONFIG and are written
  // up-front. `rung_infeasible` is the OUTCOME, filled AFTER the run from
  // MinimizePlasticResult (same discipline as cg_multigrid): one entry per
  // EVALUATED rung, 1 iff that rung was ended on the signature ("load path lost"),
  // in ladder order. It is EMPTY until the run finishes, so an unfinished run
  // asserts nothing; an entry reading 1 means that rung's design is a corpse that
  // was neither shipped nor inherited by any later rung.
  double infeasible_compliance_ratio = 0.0;
  double infeasible_cg_blowup = 0.0;
  double infeasible_flat_tol = 0.0;
  int infeasible_window = 0;
  std::vector<int> rung_infeasible;
  // Handoff 2026-07-27-nonconvergence-rejection — RUNG-NON-CONVERGENCE echo, the
  // OUTCOME (no config: non-convergence is intrinsic to the solve, not a tunable
  // threshold), filled AFTER the run from MinimizePlasticResult with the same
  // finalize-only discipline as rung_infeasible — so an unfinished run asserts
  // nothing. One entry per EVALUATED rung, in ladder order:
  //   rung_non_convergent[i]            1 iff rung i was rejected because a linear
  //                                     solve did not converge, else 0. All-false is
  //                                     the positive statement "every rung's solves
  //                                     converged".
  //   rung_non_convergent_iteration[i]  the CG iteration the failing solve reached
  //                                     (0 on a converged rung) — WHICH iteration.
  //   rung_non_convergent_residual[i]   the relative residual it stalled at (0 on a
  //                                     converged rung) — HOW FAR it missed.
  // Together they satisfy the handoff's bar: run_info records which rungs were
  // rejected for non-convergence, with the iteration and the residual reached.
  std::vector<int> rung_non_convergent;
  std::vector<int> rung_non_convergent_iteration;
  std::vector<double> rung_non_convergent_residual;
  // ACTIVE DOMAIN (active-domain phase 1). `active_domain_band` is the REQUESTED
  // band (config, written up-front): 0 = off, > 0 = the explicit half-width in
  // voxels, < 0 = auto (resolved per rung from the filter radius). The two
  // vectors are the OUTCOME, filled AFTER the run from MinimizePlasticResult —
  // same finalize-only discipline as cg_multigrid and rung_infeasible, so an
  // unfinished run asserts NOTHING about what the band did. One entry per
  // EVALUATED rung, in ladder order: `active_domain_latched[i]` is 1 iff rung i
  // switched the mask off part-way (the band covered the domain, or a restricted
  // solve failed and the rung fell back to the full domain), and
  // `active_domain_latch_reason[i]` says which — empty string when that rung ran
  // its whole length under the band. `active_domain_latch_iteration[i]` is the
  // 1-based iteration rung i latched at (0 when it never did), and
  // `active_domain_escape_count[i]` is the number of elements that had grown
  // outside the band when the ESCAPE latch tripped (escape-latch amendment;
  // 0 when rung i never latched or latched for a non-escape reason) — the two
  // fields the escape latch adds so a run that suppressed material the optimizer
  // wanted SAYS how much, and when, rather than silently diverging.
  // `active_domain_fraction_mean[i]` is that rung's iteration-mean active
  // fraction (1.0 when off or latched at iteration 1), i.e. the f_bar the
  // realised speedup ~ 0.65 / f_bar is read off.
  // `active_domain_band_resolved[i]` is the band width rung i ACTUALLY ran with,
  // the DERIVED k — an OUTCOME, filled post-run like the vectors above. It is the
  // number the AUTO sentinel (`active_domain_band == -1`) resolves to
  // (active_domain_auto_band(filter_radius) = ceil(rmin) + 1), so a run armed in
  // AUTO records BOTH the request (-1) and what k that job derived; 0 on a rung
  // that ran with the band off. Without it the requested -1 could not be read back
  // as a concrete width — the same reason 133 had to echo the resolved recycle_dim
  // beside the requested flag.
  int active_domain_band = 0;
  std::vector<int> active_domain_band_resolved;
  std::vector<int> active_domain_latched;
  std::vector<int> active_domain_latch_iteration;
  std::vector<long long> active_domain_escape_count;
  std::vector<std::string> active_domain_latch_reason;
  std::vector<double> active_domain_fraction_mean;
  // Handoff 2026-07-25-draft-quality — the DRAFT-QUALITY echo. `draft_quality` /
  // `draft_loose_tol` / `draft_escalation_c_gap` are CONFIG (the armed posture,
  // written up-front): off => the trajectory ran tight everywhere and the certified
  // numbers are byte-identical. The three per-rung vectors are the OUTCOME, filled
  // AFTER the run from MinimizePlasticResult (same finalize-only discipline as
  // cg_multigrid / rung_infeasible, so an unfinished run asserts NOTHING about what
  // draft did), one entry per EVALUATED rung in ladder order:
  //   draft_rung_tail_k[i]   the derived/measured tightening tail k of rung i.
  //   draft_rung_c_gap[i]    rung i's certified-vs-trajectory relative compliance
  //                          gap (the escalation signal); < 0 (serialized `null`)
  //                          for a cancelled/infeasible rung that measured none.
  //   draft_rung_escalated[i] 1 iff rung i's gap tripped the threshold and it was
  //                          re-run tight from its warm seed (part d).
  // The serializer also emits a compact `draft_escalations` array of {rung, gap}
  // for exactly the escalated rungs — "every escalation with its rung index and
  // measured gap". All EMPTY when draft_quality is off.
  // Handoff 2026-07-26-draft-quality-phase2 — the DESIGN-SPACE trigger echo.
  // `draft_escalation_design_flip` (CONFIG, > 0 arms the design trigger and replaces
  // the gap decision) plus two per-rung OUTCOME vectors:
  //   draft_rung_probe_flip[i]  the fraction of rung i's loose-plateau solid voxels
  //                             whose classification moved under the one-shot tight
  //                             probe (the escalation signal); < 0 (`null`) when the
  //                             probe did not run (disarmed / cancelled / infeasible).
  //   draft_rung_probe_cg[i]    that probe's CG cost (0 when it did not run).
  bool draft_quality = false;
  double draft_loose_tol = 0.0;
  double draft_escalation_c_gap = 0.0;
  bool draft_use_design_trigger = false;
  double draft_escalation_design_flip = 0.0;
  std::vector<int> draft_rung_tail_k;
  std::vector<double> draft_rung_c_gap;
  std::vector<int> draft_rung_escalated;
  std::vector<double> draft_rung_probe_flip;
  std::vector<long long> draft_rung_probe_cg;
  double min_feature_mm = 0.0;
  double margin_stop = 0.0;
  double infill_percent = 100.0;
  // Width-aware knockdown posture (handoff 2026-07-26-width-aware-knockdown): whether
  // the gate ran the SHELL+CORE composite, and the wall geometry it was handed. When
  // width_aware_knockdown is false the gate used the pure f^1.5 scalar and the wall
  // fields are inert metadata (echoed for provenance, not used).
  bool width_aware_knockdown = false;
  int wall_loops = 0;
  double wall_line_width_mm = 0.45;         // inner wall line width (mm)
  // The EFFECTIVE outer wall line width (mm) — the value actually used, with the
  // mirror-inner sentinel already resolved — and the derived solid wall-ring thickness
  // t = outer + (loops-1)·inner (handoff line-width-plumbing). Both echoed for
  // provenance; inert when width_aware_knockdown is false.
  double wall_line_width_outer_mm = 0.45;
  double wall_thickness_mm = 0.0;
  bool has_design_box = false;
  std::vector<double> ladder;
  long long created_wall_ms = 0;  // run-info write time (epoch ms)
  // Capture config echo (what observability this run captured).
  bool iteration_csv = false;
  bool density_snapshots = false;
  int snapshot_every = 0;
  int snapshot_cap = 0;
  // Lattice certification posture (handoff 2026-07-27-lattice-certification). When
  // `lattice_present` is false (every current run — no job front-end declares a
  // lattice region yet) the serializer emits `"lattice": null`, so a non-latticed
  // run's meaningful record is unchanged. When a certification carried a lattice
  // region, these echo WHAT was latticed and HOW: the topology, the cell size, the
  // relative-density RANGE over the region, and the region's voxel count. The margin
  // such a run reports certifies the composite object's STIFFNESS and the SOLID
  // region's strength; the lattice region's strut-level strength is NOT gated (Phase 2
  // de-homogenization) — see FixedDesignAnalysis::lattice_strength_uncertified.
  bool lattice_present = false;
  std::string lattice_topology;      // "octet" (only topology this task ships)
  double lattice_cell_size_mm = 0.0;
  double lattice_rho_min = 0.0;
  double lattice_rho_max = 0.0;
  long long lattice_region_voxels = 0;
  bool lattice_strength_uncertified = false;
  // The CERTIFIED verdict of the composite (handoff 2026-07-29-lattice-certification-
  // e2e, bars E1/E3): the worst (min over accepted latticed variants) composite
  // strength margin the octet-tensor solve produced, its gated value, and whether the
  // latticed object PASSES the run's margin_stop — so a variant's provenance records
  // WHAT was certified (the composite), not only that a lattice was present. The
  // certifiable band [lattice_rho_min, lattice_rho_max] the gate enforced (E5) is the
  // rho range above.
  double lattice_margin_worst_case = 0.0;
  double lattice_margin_effective = 0.0;
  bool lattice_accepted = false;

  // Lattice EXPORT posture (handoff 2026-07-28-lattice-generation-production) — the
  // printable GEOMETRY generator, distinct from the certification posture above.
  // Set when a job's "lattice" block made run_job emit latticed variant meshes; the
  // serializer emits a nested "lattice_export" object ONLY then, so a run with no
  // lattice block writes no key and stays byte-identical (the P1 bar). Records the
  // posture the task requires: topology, cell size, strut-radius range (min==max
  // while radius is uniform; graded-field-ready), the latticed region (cells +
  // solid voxels), the emitted formats, the total lattice triangles, and the
  // generation wall-time fraction of the whole job (P6). The union is an
  // interpenetrating soup (`interpenetrating_soup`), not a single 2-manifold — the
  // slicer-accepted form the PR 201 print certified.
  bool lattice_export_present = false;
  std::string lattice_export_topology;          // "octet"
  double lattice_export_cell_mm = 0.0;
  double lattice_export_strut_radius_min_mm = 0.0;
  double lattice_export_strut_radius_max_mm = 0.0;
  long long lattice_export_latticed_cells = 0;  // summed over emitted variants
  long long lattice_export_region_voxels = 0;   // summed solid voxels latticed
  long long lattice_export_triangles = 0;       // summed lattice triangles
  int lattice_export_variant_count = 0;         // accepted variants latticed
  bool lattice_export_emit_stl = false;
  bool lattice_export_emit_3mf = false;
  bool lattice_export_interpenetrating_soup = true;
  double lattice_export_gen_seconds = 0.0;      // generation wall time
  double lattice_export_gen_fraction = 0.0;     // gen time / total job time (P6)

  // GRADING LAW posture (handoff 2026-07-29-lattice-grading-law) — what the stress-to-
  // lattice grading law produced for a "grading" job block. Set only in the analyze/
  // certification path when a grading block is present; the serializer emits a nested
  // "grading" object ONLY then, so a run with no grading block writes no key and stays
  // byte-identical (bar L1). It records: the limits the law READ from core (the
  // certifiable band and the cells-per-member floor — provenance, so a stale limit is
  // visible), the chosen uniform cell size and whether the printability floor raised it,
  // the achieved relative-density range, the region/latticed/solid-fallback voxel counts
  // (bar L4 — how much of the region was too thin to grade and stayed SOLID), the
  // resulting strut-diameter range and the thinnest member's cells-per-member (bar L3),
  // and two honesty flags: any strut below the stated minimum width, and whether the
  // whole region was ungradeable.
  bool grading_present = false;
  std::string grading_topology;             // "octet"
  double grading_band_rho_min = 0.0;        // lattice_rho_min (read from core)
  double grading_band_rho_max = 0.0;        // lattice_rho_max (read from core)
  double grading_cells_per_member_floor = 0.0;  // lattice_cells_per_member_min
  double grading_cell_size_mm = 0.0;        // the chosen uniform cell
  double grading_printability_floor_mm = 0.0;
  bool grading_cell_size_floored = false;   // target raised to the printability floor
  double grading_min_extrudable_width_mm = 0.0;  // the STATED minimum (the input)
  double grading_rho_min_used = 0.0;        // achieved band over latticed voxels
  double grading_rho_max_used = 0.0;
  long long grading_region_voxels = 0;      // printed candidates
  long long grading_latticed_voxels = 0;    // graded to lattice
  long long grading_solid_fallback_voxels = 0;  // L4: too thin -> stayed solid
  double grading_min_member_width_mm = 0.0; // thinnest latticed member (mm)
  double grading_min_cells_per_member = 0.0;    // at that member (>= floor)
  double grading_min_strut_diameter_mm = 0.0;
  double grading_max_strut_diameter_mm = 0.0;
  bool grading_any_strut_below_min = false; // requirement 3 honesty flag
  bool grading_region_ungradeable = false;  // L4 at region scale
};

// Serialize / write the version record as JSON (hand-rolled, matching the repo's
// report.cpp style). write_run_info throws std::runtime_error on IO failure.
std::string run_info_json(const RunInfo& info);
void write_run_info(const std::string& path, const RunInfo& info);

// Wall-clock epoch milliseconds (the CSV/run_info timestamp source).
long long wall_clock_ms();

}  // namespace topopt
