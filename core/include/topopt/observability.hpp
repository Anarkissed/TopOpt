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
//   hier_built,mg_cycles_attempted
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
  double min_feature_mm = 0.0;
  double margin_stop = 0.0;
  double infill_percent = 100.0;
  bool has_design_box = false;
  std::vector<double> ladder;
  long long created_wall_ms = 0;  // run-info write time (epoch ms)
  // Capture config echo (what observability this run captured).
  bool iteration_csv = false;
  bool density_snapshots = false;
  int snapshot_every = 0;
  int snapshot_cap = 0;
};

// Serialize / write the version record as JSON (hand-rolled, matching the repo's
// report.cpp style). write_run_info throws std::runtime_error on IO failure.
std::string run_info_json(const RunInfo& info);
void write_run_info(const std::string& path, const RunInfo& info);

// Wall-clock epoch milliseconds (the CSV/run_info timestamp source).
long long wall_clock_ms();

}  // namespace topopt
