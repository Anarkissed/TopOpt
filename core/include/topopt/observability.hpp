#pragma once

#include <cstddef>
#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

#include "topopt/fea.hpp"    // GeneoDecisionRecord
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
// PROCESS MEMORY (task 2026-08-02-iteration-phase-timing).
//
// WHY: the leading hypothesis for the maintainer's 449 s/iteration rung was
// memory pressure — a 14x slowdown at identical measured arithmetic is what
// swapping looks like. An argument cannot settle that; a number can. So a run
// samples its own footprint once per design iteration and the CSV carries it,
// next to the phase times, on the SAME row.
//
// Fields that a platform cannot answer are NEGATIVE, never 0 — "unavailable"
// and "measured zero" are different facts and the CSV must not conflate them.
struct ProcessMemory {
  double rss_mb = -1.0;         // resident now (macOS: phys_footprint)
  double peak_rss_mb = -1.0;    // process high-water resident (getrusage)
  double compressed_mb = -1.0;  // macOS memory compressor holdings
  long long major_faults = -1;  // getrusage ru_majflt — faults that hit DISK
  long long swapins = -1;       // task-level swapins (macOS task_vm_info)
  double available_mb = -1.0;   // host free + inactive + speculative
};

// Sample this process's memory. Cheap (two syscalls); safe to call per design
// iteration. Pure observation — nothing reads it back.
ProcessMemory process_memory();

// Monotonic wall clock in milliseconds (steady_clock). The phase-timing source:
// a phase duration must not be perturbable by an NTP step, and only differences
// of two samples are ever read. Distinct from wall_clock_ms() below, which is
// the CSV's absolute epoch timestamp and is deliberately system_clock.
double steady_clock_ms();

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
// ── PER-PHASE WALL TIMING (task 2026-08-02-iteration-phase-timing) ──────────
// Everything above describes WHAT the iteration did; nothing described HOW LONG
// any part of it took. `wall_ms` is an epoch TIMESTAMP, not a duration — a name
// that predates any duration on this row — so a run whose iterations took 449 s
// each while reporting 215 CG iterations could not be diagnosed from this file
// at all. These columns are that missing measurement (see IterationPhaseTimes
// in simp.hpp for the full contract):
//
//   total_ms       this iteration's DURATION: top of the optimizer's loop body
//                  to the moment this row's record was handed to the sink.
//   tail_prev_ms   the PREVIOUS iteration's post-observation tail (keyframe,
//                  density snapshot, plateau/continuation logic, and the write
//                  of the previous row). Carried here because the previous row
//                  was already on disk when it was spent; sum(total_ms +
//                  tail_prev_ms) over a rung is that rung's wall.
//   filter_ms      every density-filter call this iteration
//   project_ms     Heaviside projection + the mask pins
//   solve_ms       the penalized solve call, entry to exit
//   fea_ms/sens_ms solve_ms split into the LINEAR SOLVE and the self-adjoint
//                  SENSITIVITY sweep (a SUB-split: do not add to the sum)
//   update_ms      the OC/MMA update: sensitivity filter + volume bisection
//   analysis_ms    change, achieved vf, plateau + infeasibility detectors
//   observe_ms     the progress hook + building this record
//   residual_ms    total_ms MINUS (filter+project+solve+update+analysis+observe)
//                  — the UNATTRIBUTED time. This column is the point: time going
//                  somewhere unnamed is visible rather than inferred.
//   solver_build_ms / mg_build_ms / mg_ms / cg_ms / geneo_setup_ms /
//   geneo_apply_ms / recycle_ms
//                  a SUB-SPLIT of solve_ms from CgInfo (again, not extra terms):
//                  the reduced-system build, the multigrid hierarchy build, the
//                  V-cycle loop, the Jacobi-CG recurrence, the GenEO basis build
//                  + coarse-operator refresh, the GenEO correction summed over
//                  iterations, and the Krylov recycle overhead. geneo_setup_ms is
//                  the one that answers the 128³ anomaly: it costs N_t operator
//                  applies and moves NO iteration counter.
//   fea_solves     penalized FEA solves this design iteration. It is 1 on every
//                  trajectory iteration; anything else is itself a finding.
//   matvecs        matrix-free operator applies charged to this iteration — the
//                  honest work unit when cg_iters is not.
//   geneo_dim      N_t, the GenEO coarse-space dimension that preconditioned the
//                  solve. 0 = no basis existed; on geneo_action 5 it is non-zero
//                  and names the basis the gate chose NOT to engage, so
//                  geneo_action is what says whether the deflation applied
//   geneo_action   0 none / 1 reused / 2 coarse operator REFRESHED / 3 basis
//                  (re)BUILT / 4 build refused by the memory cap / 5 DECLINED
//                  by the ENGAGEMENT GATE (a basis was held and this solve was
//                  cheaper to finish plain — handoff 2026-08-02-geneo-disarm)
//   geneo_burn     plain iterations this solve burned before the gate decided.
//                  On action 5 it is the whole solve; on 1/2/3 it is the burn
//                  that preceded engagement.
//   geneo_threshold what that burn had to reach for the deflation to engage, in
//                  plain-iteration equivalents. 0 when no basis was held, i.e.
//                  when the kGeneoTriggerIters stagnation trigger governed. The
//                  pair (geneo_burn, geneo_threshold) IS the decision, so a
//                  later reader grades it without re-instrumenting for it.
//   rss_mb, peak_rss_mb, compressed_mb, available_mb, major_faults, swapins
//                  the process's memory at this iteration. NEGATIVE means the
//                  platform could not answer — never a fabricated zero, because
//                  "unavailable" and "no swapping" are different facts and the
//                  paging question turns on exactly that distinction.
//
// A row is ~330-380 bytes, so a full 4-rung production run (~800 rows) is
// < 300 KB — the append-and-flush cost stays a rounding error against a solve.
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
  // Task algebraic-level1-coarsening — the ALGEBRAIC LEVEL-1 coarse space echo.
  // `mg_algebraic_level1` is the ACTUAL process state the run executed under
  // (read from fea_mg_algebraic_level1_enabled, never inferred — the 132
  // discipline), and the rest describe the LAST hierarchy the path built:
  // aggregate count, level-1 coarse dimension, total levels and the bytes the
  // path ADDED. `mg_algebraic_level1_refused` with a reason is the honest record
  // of a build that DECLINED and fell back to the geometric hierarchy — a run
  // record that only mentioned the accelerator when it fired could not be used
  // to rule it out of a later diagnosis. All 0 / false when the path is off
  // (the library default), which is what every reference run records.
  bool mg_algebraic_level1 = false;
  int mg_algebraic_aggregates = 0;
  int mg_algebraic_coarse_dim = 0;
  int mg_algebraic_levels = 0;
  double mg_algebraic_added_mb = 0.0;
  bool mg_algebraic_level1_refused = false;
  std::string mg_algebraic_refuse_reason;
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
  // Handoff 2026-07-29-geneo-arming — GenEO two-level deflation echo.
  // `geneo_twolevel` is the ACTUAL process-global state the run executed under
  // (read from fea_geneo_twolevel_enabled, never inferred — the 132 discipline);
  // `geneo_trigger_iters` / `geneo_rebuild_factor` echo the named recipe
  // constants (the stagnation-trigger budget and the degradation rebuild
  // factor), so a run record names the policy it ran, not just the on/off bit.
  // The lifecycle counters are filled post-run (finalize): how many times the
  // eigensolve basis was BUILT, how many cheap coarse-operator REFRESHES were
  // paid, how many fallback solves the deflation actually preconditioned, and
  // the held coarse dimension N_t / stored basis MB at run end. All 0 / false
  // when the feature is off (the library default).
  bool geneo_twolevel = false;
  int geneo_trigger_iters = 0;
  double geneo_rebuild_factor = 0.0;
  long long geneo_basis_builds = 0;
  long long geneo_coarse_refreshes = 0;
  long long geneo_armed_solves = 0;
  int geneo_basis_dim = 0;
  double geneo_basis_mb = 0.0;
  // THE ENGAGEMENT GATE (handoff 2026-08-02-geneo-disarm). `geneo_declined_solves`
  // counts fallback solves a HELD basis was offered to and the gate kept plain,
  // so `geneo_armed_solves + geneo_declined_solves` is how many decisions were
  // taken and their ratio is how often the accelerator was worth its price. The
  // two cost constants are echoed like the trigger and rebuild factor (the
  // 114/132 discipline: run_info states what the run executed under). The
  // decision log records every arm/disarm TRANSITION with the numbers it fired
  // on — bar AA5 — and `geneo_decisions_dropped` reports what the log cap
  // swallowed rather than letting the array lie by omission.
  long long geneo_declined_solves = 0;
  double geneo_refresh_cost_per_column = 0.0;
  double geneo_deflated_iter_cost = 0.0;
  std::vector<GeneoDecisionRecord> geneo_decisions;
  long long geneo_decisions_dropped = 0;
  bool warm_start_inherit = false;
  bool warm_start_coarse = false;
  // Handoff 2026-08-02-warm-start-coarse-experiment — the coarse pre-solve's OWN
  // COST, both currencies. CONFIG above (warm_start_coarse) says it was armed;
  // these two say what it charged. OUTCOME, so filled post-run from
  // MinimizePlasticResult with the same finalize-only discipline as
  // cg_multigrid — an unfinished run asserts nothing. Both 0 when the feature is
  // off. They are reported SEPARATELY and never folded into a rung total: a
  // cascade that saves fine-grid wall must save more than it spends here, and
  // handoff 2026-08-02-iteration-phase-timing is the standing proof that an
  // iteration count alone cannot settle that.
  int warm_start_coarse_iterations = 0;
  double warm_start_coarse_ms = 0.0;
  long long warm_start_coarse_matvecs = 0;
  // The DOF-WEIGHTED cost — THE PRIMARY UNIT. Raw matvecs above are NOT
  // comparable across the pre-solve's res/2 grid and the ladder's fine grid; a
  // coarse apply touches ~1/8 the DOFs. `..._grid_dofs` and `solved_grid_dofs`
  // are the two denominators, recorded so the weighting can be re-derived from
  // the run record rather than trusted.
  long long warm_start_coarse_dof_touches = 0;
  long long warm_start_coarse_grid_dofs = 0;
  long long solved_grid_dofs = 0;
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
  // Task 2026-08-03-preflight-feasibility-and-divergence — THE GUARDS ARE
  // OBSERVABLE (bar P6). Three guards, all three recorded here with the numbers
  // they fired on, so the next investigation of a job that stopped early does
  // not need another instrumentation task.
  //
  // GUARD 1, the PRE-FLIGHT (config-free: it is a measurement, not a threshold).
  // Written BEFORE the solve — this is the one part of run_info that is
  // meaningful on an unfinished run, which is the point of a pre-flight.
  // `preflight_decidable` false means the grid carried no Load or no Fixture
  // voxels, so `preflight_connected` is vacuous and asserts nothing.
  // `preflight_narrowest_*` are the marginality reading: the narrowest BFS level
  // set separating the anchors from the nearest load, an UPPER BOUND on the
  // minimum cut of the surviving path — INFORMATION, never a refusal.
  bool preflight_ran = false;
  bool preflight_decidable = false;
  bool preflight_connected = false;
  double preflight_ms = 0.0;
  long long preflight_load_voxels = 0;
  long long preflight_anchor_voxels = 0;
  long long preflight_unreached_load_voxels = 0;
  long long preflight_allowed_voxels = 0;    // may hold material
  long long preflight_forbidden_voxels = 0;  // FrozenVoid: may never
  int preflight_narrowest_separator_voxels = -1;
  double preflight_narrowest_separator_mm2 = -1.0;
  int preflight_geodesic_levels = -1;
  // GUARDS 2 and 3 — the armed thresholds (CONFIG, up-front) and the per-rung
  // OUTCOME (filled AFTER the run from MinimizePlasticResult, the same
  // finalize-only discipline as rung_infeasible, so an unfinished run asserts
  // nothing). All-false outcome vectors are the positive statement "no guard
  // fired". See MinimizePlasticResult for the per-field meanings.
  double infeasible_immediate_ratio = 0.0;
  double infeasible_immediate_wall_ratio = 0.0;
  double iteration_time_ratio = 0.0;
  double iteration_time_floor_ms = 0.0;
  std::vector<int> rung_diverged;
  std::vector<int> rung_diverged_iteration;
  std::vector<double> rung_diverged_c_ratio;
  std::vector<double> rung_diverged_cg_ratio;
  std::vector<double> rung_diverged_wall_ratio;
  std::vector<int> rung_time_budget;
  std::vector<int> rung_time_budget_iteration;
  std::vector<double> rung_time_budget_ms;
  std::vector<double> rung_time_budget_elapsed_ms;
  std::vector<double> rung_time_budget_baseline_ms;
  std::vector<std::string> rung_time_budget_phase;
  std::vector<double> rung_time_budget_phase_ms;
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
  // Task 2026-08-08-semdot-does-it-come-out-smoother — the SEMDOT echo.
  // `semdot` / `semdot_grid_points` are CONFIG (the armed mode, written
  // up-front): off => the run is the SIMP path byte-for-byte. The per-rung
  // vectors are OUTCOME, filled AFTER the run from MinimizePlasticResult (the
  // same finalize-only discipline as cg_multigrid / rung_infeasible), one entry
  // per EVALUATED rung in ladder order:
  //   semdot_rung_level_set[i]           the level-set value rung i's volume
  //                                      target selected on its FINAL field.
  //   semdot_rung_fractional_voxels[i]   design voxels that came out strictly
  //                                      between 0 and 1 — the boundary layer,
  //                                      and the only population that can carry
  //                                      sub-voxel content. A zero here says the
  //                                      mode produced a binary field and cannot
  //                                      have moved a surface, which is a thing a
  //                                      run must be able to say about itself.
  //   semdot_rung_design_voxels[i]       the Active set it was measured against.
  // All EMPTY when semdot is off.
  bool semdot = false;
  int semdot_grid_points = 0;
  std::vector<double> semdot_rung_level_set;
  std::vector<long long> semdot_rung_fractional_voxels;
  std::vector<long long> semdot_rung_design_voxels;

  // ── THE PARAMETRIC LEVEL SET (task 2026-08-10-plsm-production) ────────────
  // ★ AN ARMED RUN MUST SAY IT WAS ARMED, and must say WHAT IT WAS ARMED WITH.
  // The knot spacing is the feature-scale control on this path, so a run whose
  // record did not carry it would be unreadable a week later. THREE numbers, per
  // axis, in voxels — a receipt that collapsed them to one would have thrown away
  // the fact R4 exists to protect.
  //
  // `plsm_frozen_floor_occupancy` is the LOAD-PATH GUARANTEE, measured on this
  // run: the smallest ersatz occupancy any FrozenSolid voxel took under the
  // smooth boolean. Above 0.5 is the guarantee (plsm_optimize refuses to run
  // below it), and it is recorded because PR 324 measured that 40 leaked frozen
  // voxels of 40,216 reject every certification on the LOAD PATH.
  //
  // All zero / false when the mode is Off, which is every existing run.
  bool plsm = false;
  std::string plsm_basis;
  double plsm_knots_vox[3] = {0.0, 0.0, 0.0};
  double plsm_support = 0.0;
  double plsm_eta_voxels = 0.0;
  int plsm_max_iterations = 0;
  std::string plsm_seed;
  int plsm_refit_every = 0;
  double plsm_cg_tolerance_loose = 0.0;
  bool plsm_warm_start = false;
  long long plsm_coefficients = 0;
  double plsm_frozen_floor_occupancy = 0.0;
  // ── ★ THE ERSATZ AND THE STOPPING RULE (task 2026-08-13) ─────────────────
  // "fraction" | "heaviside" — WHICH DENSITY the solver saw. The two are
  // different objects and a receipt that did not say which would make every
  // number beside it unreadable.
  std::string plsm_ersatz;
  // "discrete" | "continuum" — WHICH compliance weight the trajectory used.
  std::string plsm_sens_weight;
  int plsm_frac_samples = 0;
  double plsm_frac_eps_mult = 0.0;
  bool plsm_frac_mollified = false;
  bool plsm_frac_sens_exact = false;
  bool plsm_frac_eps_l1 = false;
  long long plsm_frac_cut_cells = 0;
  double plsm_frac_sample_wall_s = 0.0;
  double plsm_frac_sens_wall_s = 0.0;
  // ★ WHY THE RUN STOPPED, on the FIRST rung. "iteration-ceiling" and
  // "margin-plateau" are different runs and must not read alike.
  int plsm_margin_probe_every = 0;
  int plsm_margin_plateau_probes = 0;
  double plsm_margin_plateau_tol = 0.0;
  std::string plsm_stop_reason;
  int plsm_margin_peak_iteration = 0;
  double plsm_margin_peak = 0.0;
  double plsm_margin_probe_wall_s = 0.0;
  // ── ★ THE TOPOLOGY COUNTERS. The constraint that produced them does not
  // ship; these do, because they made every other finding legible.
  long long plsm_void_components = 0;
  long long plsm_void_chi = 0;
  long long plsm_void_enclosed_solid = 0;
  long long plsm_void_sealed_pockets = 0;
  long long plsm_void_tunnels = 0;
  long long plsm_void_sealed_voxels = 0;
  double plsm_void_sealed_volume_mm3 = 0.0;

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
  // WHICH LADDER THIS RUN WALKED (task 2026-08-03-growth-ladder): "reduction"
  // (every rung <= 1.0 — remove as much plastic as possible while holding the
  // required margin) or "growth" (every rung > 1.0 — add as little plastic as
  // possible to reach it). Derived from `ladder` itself, so it can never disagree
  // with the rungs beside it, and recorded because a run record that carries the
  // numbers but not what they MEAN leaves the reader to infer the mode — which is
  // exactly the silence bar G7 closes.
  std::string ladder_mode = "reduction";
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
  // Strut-strength REPORT (task 2026-07-31-lattice-strut-strength-report) — the
  // run-level worst (min over latticed variants) of the REPORT-ONLY de-homogenized
  // strut margins (PR 259's measured law; see strut_strength.hpp). Emitted inside
  // the "lattice" object ONLY when `lattice_strut_report_present` (octet law
  // applied to >= 1 variant), so pre-existing records are unchanged. These numbers
  // do NOT feed `lattice_accepted` — the verdict logic is untouched; the app shows
  // in-plane and interlayer SEPARATELY (the interlayer margin divides by the
  // UNSOURCED z_knockdown recorded here; the receipts carry the z-free bounds).
  bool lattice_strut_report_present = false;
  double lattice_strut_margin_in_plane = 0.0;
  double lattice_strut_margin_interlayer = 0.0;
  double lattice_strut_margin_worst_case = 0.0;
  double lattice_strut_z_knockdown = 0.0;
  double lattice_strut_min_cells_per_member = 0.0;  // vs the homogenization floor
  bool lattice_strut_out_of_regime = false;  // below the cells-per-member floor
  long long lattice_strut_rho_clamped_voxels = 0;   // law-span clamps (bar L5)

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
  // Rungs the grading law could lattice NOTHING of, so no lattice file was
  // written for them and none of their (all-zero) figures entered the aggregates
  // above (task 2026-08-04-variant-volume-fraction-mismatch, bar B3 / L3). Carried
  // so "3 of 4 rungs latticed" is a stated fact rather than a missing file.
  int lattice_export_ungradeable_variants = 0;
  // THE ENCLOSED-VOID RULE (task 2026-08-05-lattice-void-reaches-exterior). The
  // serializer emits a nested "void_escape" object ONLY when
  // `lattice_void_check_ran`, i.e. only when the job armed
  // `lattice.require_lattice_void_reaches_exterior`, so a run that did not arm
  // it writes a byte-identical record (bar R1).
  //
  // BOTH VERDICTS ARE RECORDED. `sealed_variants` is the refusal count; the
  // reached / reachable / escape-depth / face fields are what a PASS says, and
  // they exist because a silent pass is indistinguishable from a check that did
  // not run. `bfs_visits` and `wall_seconds` are the check's OWN cost, separate
  // from `gen_seconds` (generation) — the R5 bar.
  bool lattice_void_check_ran = false;
  int lattice_void_sealed_variants = 0;
  long long lattice_void_sealed_cells = 0;
  long long lattice_void_sealed_voxels = 0;
  double lattice_void_sealed_volume_mm3 = 0.0;
  long long lattice_void_latticed_reached = 0;
  long long lattice_void_latticed_cells = 0;
  double lattice_void_reachable_volume_mm3 = 0.0;
  long long lattice_void_bfs_visits = 0;
  int lattice_void_escape_depth_max = -1;
  // "-x,+x,-y,+y,-z,+z" — the grid faces the OPEN lattice's own escape network
  // touched, joined by commas. Empty when no latticed voxel was reached.
  std::string lattice_void_escape_faces;
  // Sealed cavities holding NO lattice: pre-existing enclosed voids in the
  // design. REPORTED, never a refusal — this rule is about lattice.
  long long lattice_void_sealed_pockets_without_lattice = 0;
  double lattice_void_wall_seconds = 0.0;
  bool lattice_export_emit_stl = false;
  bool lattice_export_emit_3mf = false;
  bool lattice_export_interpenetrating_soup = true;
  // Lattice ROLE regions + solid companion (task lattice-page-core-hookup,
  // stage 1). Keys are serialized ONLY when role_regions_present, so a job with
  // no lattice.regions (and no grading) writes a byte-identical lattice_export
  // object. solid_region_* is the material kept SOLID by roles / the grading
  // law's fallback, exported as a closed body and accounted separately from
  // interior/skin/rim (H1c; voxel basis, count × spacing³).
  bool lattice_export_role_regions_present = false;
  long long lattice_export_include_regions = 0;
  long long lattice_export_exclude_regions = 0;
  long long lattice_export_solid_region_voxels = 0;
  double lattice_export_solid_region_volume_mm3 = 0.0;
  long long lattice_export_solid_region_triangles = 0;
  long long lattice_export_include_void_voxels = 0;  // include over optimizer
                                                     // void: the reported no-op
  // Of those, the ones a declared keep-clear caused (task 2026-08-04-protect-
  // freeze-vs-solidity). Unsatisfiable by construction — the only lattice-region
  // overlap that is a real conflict, and the one the CLI warns on.
  long long lattice_export_include_void_by_clearance = 0;
  // PRE-FLIGHT REGION FORECAST (same task, item 6) — computed from the DECLARED
  // geometry before any solve: how many include regions are thinner than the
  // cells-per-member floor requires, and the two numbers that decide it. Present
  // only when the job declares include regions, so every other record is
  // byte-identical.
  bool lattice_forecast_present = false;
  long long lattice_forecast_include_regions = 0;
  long long lattice_forecast_region_too_thin = 0;
  double lattice_forecast_required_mm = 0.0;
  double lattice_forecast_thinnest_region_mm = 0.0;
  // FROZEN MATERIAL vs LATTICE (same task). Summed over the run's variants:
  // printed voxels the optimizer held frozen, and what the lattice page decided
  // they ARE. `frozen_cells_not_emitted` / `frozen_voxels_strut_and_solid` are
  // the audit (bar 3) — both 0 on a coherent run. Serialized ONLY when the run
  // had frozen material AND a lattice, so every other record is byte-identical.
  bool lattice_export_frozen_present = false;
  long long lattice_export_frozen_printed = 0;
  long long lattice_export_frozen_latticed = 0;
  long long lattice_export_frozen_solid = 0;
  long long lattice_export_frozen_cells_not_emitted = 0;
  long long lattice_export_frozen_voxels_strut_and_solid = 0;
  // The real divergence (0 on a coherent run) and the item-4 bar (0 always):
  // struts written into a region the certificate calls entirely solid, and
  // frozen voxels inside an EXCLUDE region that were latticed anyway.
  long long lattice_export_frozen_strut_and_solid_unexplained = 0;
  long long lattice_export_frozen_in_exclude_latticed = 0;
  double lattice_export_gen_seconds = 0.0;      // generation wall time
  double lattice_export_gen_fraction = 0.0;     // gen time / total job time (P6)
  // Boundary finish (handoff 2026-07-29-lattice-boundary-finish): clip/skin
  // record + B9 volume accounting (analytic per-primitive, soup basis).
  std::string lattice_export_skin;              // "none" | "rim" | "diagrid"
  long long lattice_export_clipped_struts = 0;
  long long lattice_export_landings = 0;
  long long lattice_export_anchor_nodes = 0;
  long long lattice_export_skin_triangles = 0;
  long long lattice_export_rim_triangles = 0;
  double lattice_export_interior_volume_mm3 = 0.0;
  double lattice_export_skin_volume_mm3 = 0.0;
  double lattice_export_rim_volume_mm3 = 0.0;
  // Outer finish + freeform skin (task 2026-07-30-lattice-skin-freeform).
  // Serialized ONLY when outer_finish != "shell", so a default run's
  // lattice_export record is byte-identical to the boundary-finish record.
  std::string lattice_export_outer_finish = "shell";  // "shell"|"skin"|"shell+skin"
  long long lattice_export_skin_chords = 0;            // freeform chords emitted
  long long lattice_export_skin_chords_rejected_band = 0;
  long long lattice_export_skin_chords_rejected_projection = 0;
  long long lattice_export_skin_chords_clipped_away = 0;
  bool lattice_export_finish_certified = true;  // false: "skin" (shell dropped)

  // GRADING LAW posture (handoff 2026-07-29-lattice-grading-law) — what the stress-to-
  // lattice grading law produced for a "grading" job block. Set by the analyze path
  // AND, since task lattice-page-core-hookup stage 4, by run_job (filled from the
  // LAST graded variant; each variant's full record — provenance, clamp counts —
  // lives in its own lattice receipt); the serializer emits a nested
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
  // ── ★ task 2026-08-20-lattice-only-grading: the utilisation law + R1/R4/R9 ────
  // All zero / empty on the peak-relative path, so a TO+lattice receipt is
  // byte-identical.
  double grading_demand_allowable_mpa = 0.0;   // R9: WHICH allowable governed
  double grading_utilisation_target = 0.0;     // §3's stated goal number
  double grading_max_utilisation = 0.0;
  double grading_median_utilisation = 0.0;
  long long grading_over_allowable_voxels = 0; // §0(b), clamped at 1.0 and COUNTED
  long long grading_unloaded_voxels = 0;       // §2: certified on self-weight alone
  // R4: the clamp counts, which the analyze receipt did NOT carry before this task.
  long long grading_clamped_lo_voxels = 0;
  long long grading_clamped_hi_voxels = 0;
  // R1: the DISTRIBUTION, not just its ends.
  long long grading_density_at_floor_voxels = 0;
  long long grading_density_at_ceiling_voxels = 0;
  std::vector<long long> grading_density_histogram;
  // ── ★ the grading INTENT (amendment §5c) ─────────────────────────────────────
  std::string grading_intent;                    // "structural" | "aesthetic"
  double grading_aesthetic_percentile = 0.0;
  double grading_aesthetic_percentile_mpa = 0.0;
  double grading_aesthetic_rho_min = 0.0;
  double grading_aesthetic_rho_max = 0.0;
  double grading_aesthetic_weight_exponent = 0.0;
  long long grading_above_percentile_voxels = 0;
  // §5(a): one line the app can show. Empty in structural mode, which KEEPS its
  // strength claim (utilisation against the in-plane allowable).
  std::string grading_density_meaning;
  // ── ★ the ADAPTIVE cells-per-member floor (aesthetic only) ───────────────────
  bool grading_adaptive_cells_armed = false;
  double grading_adaptive_error_budget = 0.0;
  double grading_adaptive_min_cells_allowed = 0.0;
  // Material the relaxation let through below the ACCURACY floor: buildable, and NOT
  // describable by the homogenised tensor. A certificate over it is out of regime.
  long long grading_below_accuracy_floor_voxels = 0;
  // ── ★ RE-CERTIFICATION OF THE LATTICED OBJECT (structural intent only) ───────
  // Before this, the lattice-only path certified the SOLID part and never the
  // hollowed-out one. These describe the second solve, run with the graded posture.
  bool grading_recertified = false;
  double grading_recertified_margin = 0.0;
  bool grading_recertified_accepted = false;
  bool grading_recertified_non_convergent = false;
  double grading_recertified_max_von_mises = 0.0;
  double grading_solid_margin = 0.0;          // the same run's SOLID-part margin
  // True when latticing flipped the verdict — the case this solve exists for.
  bool grading_recertify_changed_verdict = false;
  // ── ★ the layer height this lattice WANTS, and the one the job DECLARED ──────
  double grading_recommended_layer_height_mm = 0.0;
  double grading_layer_height_bound_strut_mm = 0.0;
  double grading_layer_height_bound_overhang_mm = 0.0;
  double grading_declared_layer_height_mm = 0.0;   // 0 = the job did not state one
  // ── ★ THE LATTICE ALGORITHM (task 2026-08-21-organic-lattice, §4) ────────────
  // "doubled" on every pre-task run and on every job that does not state one, so a
  // legacy receipt gains exactly one string and nothing else.
  std::string grading_algorithm;
  // ★ THE ONE NUMBER ALL THREE ALGORITHMS CAN BE COMPARED ON (§4a / bar R10), and it
  // exists BECAUSE all three emit a per-voxel relative density: the solid volume that
  // density implies, sum(rho[e]) * voxel_volume over the latticed set. It is computed
  // from whichever algorithm's density the run actually produced, so a three-way table
  // is reading the same quantity three times rather than three different quantities.
  double grading_lattice_solid_volume_mm3 = 0.0;
  long long grading_algorithm_latticed_voxels = 0;  // that algorithm's own count
  // ── ★ ORGANIC's own report. ALL ZERO unless the organic algorithm ran, which is
  // what keeps a doubled receipt byte-identical apart from the name above.
  bool organic_present = false;
  double organic_strut_diameter_mm = 0.0;
  // ★ R13 — THE TRACER'S COST, TIMED DIRECTLY around trace_organic_lattice and nothing
  // else. Never inferred by differencing two runs' wall clocks: the FEA solve dominates
  // both arms and its own run-to-run spread is larger than the quantity being claimed.
  double organic_trace_seconds = 0.0;
  long long organic_candidate_voxels = 0;
  long long organic_degenerate_voxels = 0;   // §6(d): the swirl, NAMED and COUNTED
  double organic_degenerate_fraction = 0.0;
  double organic_max_frame_swap_fraction = 0.0;
  long long organic_curves_traced = 0;
  long long organic_curves_kept = 0;
  long long organic_curves_thinned = 0;
  long long organic_curves_too_short = 0;
  std::vector<long long> organic_curves_per_family;
  std::vector<double> organic_curve_length_per_family_mm;
  // WHY each half-trace stopped, and why each offered seed was refused. Two ledgers
  // that each sum to their own total, so a thin lattice is attributable.
  long long organic_stop_left_region = 0;
  long long organic_stop_hit_d_test = 0;
  long long organic_stop_no_direction = 0;
  long long organic_stop_step_budget = 0;
  long long organic_stop_turned_too_far = 0;
  long long organic_stop_self_revisit = 0;
  long long organic_seeds_offered = 0;
  long long organic_seeds_outside_region = 0;
  long long organic_seeds_too_close = 0;
  long long organic_seeds_traced = 0;
  double organic_total_curve_length_mm = 0.0;
  // R3 — "the count of struts with fewer than two connections; the target is zero,
  // and a NON-ZERO COUNT IS THE FINDING".
  long long organic_connectors = 0;
  long long organic_curves_under_two_connections = 0;
  long long organic_curves_no_connection = 0;
  long long organic_connected_components = 0;
  // ★★ THE REAL R3: physical connectedness of the EMITTED SOLIDS, length-weighted.
  long long organic_solid_components = 0;
  double organic_solid_largest_fraction = 0.0;
  double organic_solid_stranded_length_mm = 0.0;
  long long organic_solid_segments = 0;
  // ★★ AND THE SAME TEST ON WHAT WAS WRITTEN — after the boundary clip.
  long long organic_emitted_components = 0;
  // ★★ THE GROUND-TIE REPAIR. floating_after != 0 means material the printer cannot
  // build — it starts in mid-air — and the caller REFUSES on it.
  long long organic_floating_voxels_before = 0;
  long long organic_floating_voxels_after = 0;
  long long organic_repair_legs = 0;
  long long organic_repair_rounds = 0;
  double organic_emitted_largest_fraction = 0.0;
  double organic_emitted_stranded_length_mm = 0.0;
  double organic_largest_component_fraction = 0.0;
  double organic_connector_median_length_mm = 0.0;
  double organic_connector_max_cross_deviation_deg = 0.0;
  double organic_connector_mean_cross_deviation_deg = 0.0;
  long long organic_connectors_cross_measured = 0;
  long long organic_connectors_below_resolution = 0;
  // R6 — the overhang clamp, and the 45-degree counterfactual measured beside it.
  bool organic_overhang_clamp_armed = false;
  double organic_overhang_angle_deg = 0.0;
  double organic_clamped_step_fraction = 0.0;
  double organic_curves_touched_fraction = 0.0;
  double organic_segments_outside_45_fraction = 0.0;
  double organic_curve_segments_outside_45_fraction = 0.0;
  double organic_connectors_outside_45_fraction = 0.0;
  // R5 — the ACHIEVED spacing window, against the requested one and against BOTH
  // floors, so the receipt says WHICH bound bit rather than only how wide it is.
  double organic_requested_spacing_min_mm = 0.0;
  double organic_requested_spacing_max_mm = 0.0;
  double organic_achieved_spacing_min_mm = 0.0;
  double organic_achieved_spacing_max_mm = 0.0;
  double organic_achieved_spacing_median_mm = 0.0;
  double organic_spacing_print_floor_mm = 0.0;
  double organic_spacing_resolution_floor_mm = 0.0;
  long long organic_spacing_raised_for_print_voxels = 0;
  long long organic_spacing_raised_for_resolution_voxels = 0;
  // R7 — the CURVE-CROSSING COUNT, under its OWN name. `cells_per_member` counts
  // cells across a wall and an organic lattice has no cells; this counts CURVES.
  double organic_min_curves_per_member = 0.0;
  double organic_median_curves_per_member = 0.0;
  double organic_curves_per_member_floor = 0.0;
  long long organic_below_curves_per_member_floor_voxels = 0;
  bool organic_curves_per_member_measured = false;
  // the emitted density
  long long organic_latticed_voxels = 0;
  double organic_rho_min = 0.0;
  double organic_rho_max = 0.0;
  double organic_rho_median = 0.0;
  long long organic_rho_clamped_lo_voxels = 0;
  long long organic_rho_clamped_hi_voxels = 0;
  double organic_emitted_volume_mm3 = 0.0;  // soup basis: crossings NOT deducted
  // ★ §3(c) — ALWAYS TRUE ON AN ORGANIC RUN, and it is the honest reading of the
  // certificate rather than a defect: the homogenised tensor is CUBIC and measured on
  // the octet cell, and traced geometry is anisotropic by construction.
  bool organic_tensor_out_of_regime = false;
  // ── ★ STEPPED's own report. All zero unless the stepped algorithm ran.
  bool stepped_present = false;
  long long stepped_regions = 0;
  std::vector<double> stepped_region_cell_mm;      // one per region, in id order
  std::vector<double> stepped_region_rho;          // its FEA-driven median density
  std::vector<double> stepped_region_width_mm;
  std::vector<double> stepped_region_cells_per_member;
  std::vector<long long> stepped_region_voxels;
  double stepped_min_cell_mm = 0.0;
  double stepped_max_cell_mm = 0.0;
  long long stepped_regions_out_of_regime = 0;     // below the ACCURACY floor
  long long stepped_regions_no_cell = 0;
  // ★ THE COST OF "NO TRANSITION HANDLING", MEASURED. Two regions are ADJACENT when
  // their latticed voxels touch; they are JOINED only when their cells are equal, and
  // an adjacent-but-not-joined pair is a mechanical disconnection at that seam.
  long long stepped_adjacent_region_pairs = 0;
  long long stepped_adjacent_pairs_joined = 0;
  long long grading_solid_fallback_voxels = 0;  // L4: too thin -> stayed solid
  double grading_min_member_width_mm = 0.0; // thinnest latticed member (mm)
  double grading_min_cells_per_member = 0.0;    // at that member (>= floor, EXCEPT
                                                //   over sub-floor-retained material)
  double grading_min_strut_diameter_mm = 0.0;
  double grading_max_strut_diameter_mm = 0.0;
  bool grading_any_strut_below_min = false; // requirement 3 honesty flag
  bool grading_region_ungradeable = false;  // L4 at region scale

  // ── SUB-FLOOR RETENTION (handoff 2026-08-04-subfloor-lattice-unloaded-regions).
  // Lattice deliberately kept BELOW the cells-per-member floor in a region measured
  // to carry almost no load. All zero / false unless a job opted in, which is what
  // keeps a run that did not bit-identical. `grading_subfloor_retained_voxels > 0` is
  // the reason `lattice_strut_out_of_regime` is raised, and the material it names is
  // certified OUT OF REGIME — an accepted, unquantified inaccuracy, never a claim of
  // accuracy (see lattice.hpp: the certification is blind to cells-per-member).
  bool grading_subfloor_armed = false;
  double grading_subfloor_stress_fraction_ceiling = 0.0;
  double grading_subfloor_region_stress_fraction = 0.0;  // MEASURED, not declared
  bool grading_subfloor_region_qualified = false;
  long long grading_subfloor_candidate_voxels = 0;  // below the floor, armed or not
  long long grading_subfloor_retained_voxels = 0;   // ...and kept as lattice
  long long grading_subfloor_recovered_voxels = 0;  // armed-path voxels that CLEAR
                                                    //   the floor: in regime, no
                                                    //   accuracy claim attached
  double grading_subfloor_min_cells_per_member = 0.0;  // over RETAINED voxels only
  double grading_subfloor_max_cells_per_member = 0.0;

  // ── CELL-SIZE MODE + the swept plan (handoff 2026-08-01-lattice-cell-size-sweep).
  // On a Fixed / Auto run this is a one-entry record of the uniform cell, so a reader
  // never has to branch on the mode. On a SWEPT run `grading_cell_levels` is the
  // per-REGION report (bar R5): one entry per dyadic cell size, each with the
  // thinnest member it spans and whether that member clears the cells-per-member
  // floor — flagged the way lattice_strut_out_of_regime flags a strut margin.
  std::string grading_cell_mode;              // "fixed" | "auto" | "swept"
  double grading_cell_base_mm = 0.0;          // the level-0 (finest) cell
  int grading_cell_max_level = 0;             // levels 0..this; 0 on a uniform run
  long long grading_cell_latticed_cells = 0;  // octree cells emitted
  long long grading_cells_raised_to_floor = 0;      // bar R3
  long long grading_cells_dropped_unprintable = 0;  // bounds crossed -> stayed solid
  long long grading_cells_split_by_balance = 0;     // split to hold the 2:1 balance
  bool grading_cell_any_out_of_regime = false;      // any level's tripwire fired

  // ── FIT (task 2026-08-05-lattice-cell-fit-mode). All zero on every other mode, and
  // the serializer emits the block only in fit mode, so a non-fit run is byte-
  // identical (bar R1). Per DECLARED include region: what its extent derived, and
  // what the run then did with it.
  struct GradingFitRegion {
    int region_index = 0;            // index into the job's lattice.regions
    double extent_mm = 0.0;          // thinnest declared dimension
    bool feasible = false;           // a printing AND percolating pair exists
    double cell_mm = 0.0;            // the derived cell
    double relative_density = 0.0;   // THE ONE IN FORCE — stated if stated, else derived
    // ★ STATED vs DERIVED, NEVER FLATTENED (task 2026-08-16-per-sector-density-
    // override). `relative_density` above is what the region was BUILT at. On its
    // own it cannot answer "did he ask for this, or did the derivation pick it?",
    // and PR 332 was bitten by exactly that shape — a per-region receipt that
    // dropped a distinction it was the only witness to. So both are reported:
    //   stated  == 0  ->  nothing was stated; relative_density IS derived
    //   stated  >  0  ->  he stated it, and `derived` is what he overrode
    // `derived` is also the FLOOR of the valid range the app offers (§2d): the
    // densities that print at this region's cell are exactly [derived, rho_max],
    // so the app reads the range off the receipt instead of re-deriving it.
    double stated_relative_density = 0.0;
    double derived_relative_density = 0.0;
    double strut_mm = 0.0;
    double cells_per_member = 0.0;
    bool out_of_regime = false;      // under the ACCURACY floor: buildable, uncertified
    // ── WHAT THIS REGION ACTUALLY GOT (review Q2). A bare part-level
    // `no_derivation_voxels` total is the shape of number that hid the overnight
    // run's real failure for a night, so the split is reported per region.
    long long candidate_voxels = 0;  // PRINTED voxels whose centre is in this region
    long long latticed_voxels = 0;   // of those, graded to lattice
  };
  std::vector<GradingFitRegion> grading_fit_regions;
  long long grading_fit_out_of_regime_voxels = 0;
  long long grading_fit_no_derivation_voxels = 0;
  // ★ PRINTED voxels lying in NO declared include region. The identity that answers
  // "were the skipped voxels inside or outside what he declared?" is
  //   grading_fit_no_derivation_voxels == grading_fit_printed_outside_regions
  // — when it holds, every skipped voxel was OUTSIDE, and the candidate set (not the
  // derivation) is what reached past the declaration.
  long long grading_fit_printed_outside_regions = 0;
  long long grading_fit_distinct_cells = 0;
  long long grading_density_raised_for_print_voxels = 0;
  double grading_min_printable_cell_mm = 0.0;
  struct GradingCellLevel {
    int level = 0;
    double cell_size_mm = 0.0;
    long long cells = 0;
    long long voxels = 0;
    double min_member_width_mm = 0.0;   // negative => thicker than the EDT cap
    double min_cells_per_member = 0.0;  // negative => likewise
    double min_strut_diameter_mm = 0.0;
    double max_strut_diameter_mm = 0.0;
    bool out_of_regime = false;
    bool any_strut_below_min = false;
  };
  std::vector<GradingCellLevel> grading_cell_levels;

  // ── MULTISCALE LATTICE TO (task multiscale-lattice-to) ─────────────────────
  // Written ONLY when the run armed multiscale (multiscale_armed), so a run that
  // did not is byte-for-byte the run_info.json it always wrote. One entry per
  // EVALUATED rung, in ladder order, so the receipt says what the optimizer did
  // on every rung rather than only the one that shipped.
  bool multiscale_armed = false;
  std::string multiscale_topology;        // "octet"
  long long multiscale_region_voxels = 0; // design voxels the lattice law covered
  long long multiscale_fit_rows = 0;      // measured rows the C(rho) fit ran through
  double multiscale_rho_lo = 0.0, multiscale_rho_hi = 0.0;
  double multiscale_floor_cells = 0.0;    // lattice_cells_per_member_min
  double multiscale_floor_cell_mm = 0.0;  // the cell widths were divided by
  int multiscale_floor_stride = 0;        // 0 = the per-iteration measure was off
  // THE CEILING: region voxels that clear the cells-per-member floor when the part
  // is FULLY SOLID — the most any design could lattice. Run-level, since it is a
  // property of the part and the cell size, not of a rung.
  // REACHABILITY of the declared lattice region under the design mask: how much
  // of it the optimizer can actually move. FrozenSolid voxels (a declared load or
  // fixture face, a face-protection collar) are held at density 1 all run and can
  // never become lattice in ANY formulation — the difference between "the
  // optimizer chose solid here" and "nothing could have been lattice here".
  // LENGTH-SCALE CONTROL derived from the cells-per-member floor: the minimum
  // feature size the floor implies (floor_cells * cell / 2), and the value the run
  // actually used (the max of that and whatever the job asked for). Without it the
  // multiscale optimizer spreads material into sub-floor webs; see production.cpp.
  double multiscale_min_feature_implied_mm = 0.0;
  double multiscale_min_feature_used_mm = 0.0;
  long long multiscale_region_active = 0;
  long long multiscale_region_frozen_solid = 0;
  long long multiscale_region_frozen_void = 0;
  long long multiscale_floor_ceiling_measured = 0;
  long long multiscale_floor_ceiling_eligible = 0;
  double multiscale_floor_ceiling_min_cells = 0.0;
  struct MultiscaleRung {
    double volume_fraction = 0.0;
    // Feasible-class occupancy of the CONVERGED, PROJECTED design.
    long long voxels_void = 0, voxels_band = 0, voxels_solid = 0;
    long long voxels_lower_gap = 0, voxels_upper_gap = 0;  // 0 after projection
    double band_rho_min = 0.0, band_rho_max = 0.0;
    // THE PROJECTION CHARGE — signed, reported, never absorbed.
    long long projected_lower = 0, projected_upper = 0;
    double projection_volume_delta = 0.0;
    double projection_max_density_move = 0.0;
    double volume_fraction_before_projection = 0.0;
    double volume_fraction_after_projection = 0.0;
    double volume_fraction_target = 0.0;
    double volume_constraint_violation = 0.0;
    // THE CELLS-PER-MEMBER FLOOR on the converged design.
    long long floor_measured_voxels = 0, floor_below_voxels = 0;
    double floor_min_cells_per_member = 0.0;
    std::vector<long long> floor_histogram;  // 1-cell buckets; last is [10, inf)
    // Per-iteration floor occupancy while the design was forming.
    struct FloorSample {
      int iteration = 0;
      long long measured = 0, below = 0;
      double min_cells_per_member = 0.0;
    };
    std::vector<FloorSample> floor_history;
  };
  std::vector<MultiscaleRung> multiscale_rungs;

  // ── THE EXPORTED GEOMETRY'S FRAME (handoff 2026-08-01-bake-build-orientation)
  // Provenance for the one question a reader of an exported file cannot answer
  // from the file itself: is this mesh in the input model's coordinates, or has
  // it been rotated so the certified build direction is +Z?
  //
  // The serializer emits an "export_frame" object ONLY when `export_baked` is
  // true, so a run that writes model-space coordinates — a declared build
  // direction, or bake mode "off" — keeps its run_info byte-identical.
  //
  // `applied_build_dir_*` is in the MODEL frame; in the FILE the build direction
  // is +Z by construction. `auto_applied` records that the orientation was
  // CHOSEN because none was declared, which is the fact a reader most needs and
  // the one a file cannot carry.
  bool export_baked = false;
  bool export_build_direction_auto_applied = false;
  bool export_rotation_exact = false;  // a signed axis permutation: lossless
  double applied_build_dir_x = 0.0;
  double applied_build_dir_y = 0.0;
  double applied_build_dir_z = 0.0;

  // ── ★ WHICH LADDER RAN, AND WHAT IT DID WITH A LATTICE'S FREED MASS
  // (task 2026-08-13-lattice-as-a-material §0.5, the maintainer's ruling).
  //
  // ★ `mode` ABOVE DOES NOT ANSWER THIS AND NEVER DID. It is `job.mode` — the
  // job KIND, "minimize_plastic" vs "analyze" — so it reads "minimize_plastic"
  // on every optimisation run whether or not the user ticked the box. The two
  // are different axes wearing the same words, which is why every run this
  // project has produced looks identical here. `ladder_direction` is the
  // CHECKBOX: `loads.minimize_plastic` ON walks the REDUCTION ladder, OFF walks
  // the GROWTH ladder (cli/loadcase.cpp: `growth = !lc.minimize_plastic`).
  //
  // `lattice_budget_convention` is what that choice means for a lattice, and it
  // is READ FROM THE MODE rather than from any option of its own — one
  // user-facing control, one meaning:
  //   "banked" (reduce) the budget covers only what the OPTIMISER controls, so
  //             the lattice's saving leaves the part and it gets LIGHTER;
  //   "spent"  (grow)   the budget covers EVERYTHING including the lattice, so
  //             the freed mass is re-placed inside the same total and the
  //             lattice buys STRUCTURE;
  //   "none"            no lattice region emitted — the question did not arise.
  //
  // ★ `achieved_solid_fraction` is the achieved mass over the mass the SAME part
  // would have SOLID. Without it a latticed ladder cannot be compared with an
  // unlatticed one at all: the rung is a fraction of the ACTIVE envelope, and a
  // frozen region that stopped costing its envelope moves what that fraction
  // means. Comparing his own runs is exactly what the last convention defect
  // destroyed. `observed` false emits JSON null rather than a 0.0 that reads
  // like a measured weightless part.
  std::string ladder_direction;           // "reduce" | "grow" | "" (unknown)
  std::string lattice_budget_convention;  // "banked" | "spent" | "none"
  double achieved_solid_fraction = 0.0;
  bool achieved_solid_fraction_observed = false;
};

// Serialize / write the version record as JSON (hand-rolled, matching the repo's
// report.cpp style). write_run_info throws std::runtime_error on IO failure.
std::string run_info_json(const RunInfo& info);
void write_run_info(const std::string& path, const RunInfo& info);

// Wall-clock epoch milliseconds (the CSV/run_info timestamp source).
long long wall_clock_ms();

}  // namespace topopt
