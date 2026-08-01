#include "topopt/observability.hpp"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <stdexcept>
#include <system_error>

// Process-memory sampling (task 2026-08-02-iteration-phase-timing). getrusage is
// POSIX; the mach task/host calls are macOS-only and give the two numbers that
// actually decide the paging question there — phys_footprint (what the kernel
// charges this process, the number Activity Monitor shows) and the memory
// COMPRESSOR's holdings, which on Apple silicon absorb pressure long before any
// swap file is touched. Everything is #if-guarded so a platform without them
// reports "unavailable" (negative) rather than a fabricated zero.
#if defined(__unix__) || defined(__APPLE__)
#include <sys/resource.h>
#include <unistd.h>
#endif
#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/task.h>
#endif

namespace topopt {

// ---------------------------------------------------------------------------
// binary16 codec (round-to-nearest-even). Correct over the whole float range;
// densities only exercise [0, 1], but Inf/NaN/overflow are handled so the codec
// is safe for any field.

std::uint16_t float_to_half(float value) {
  std::uint32_t x;
  std::memcpy(&x, &value, sizeof(x));
  const std::uint32_t sign = (x >> 16) & 0x8000u;
  const std::uint32_t biased = (x >> 23) & 0xFFu;
  const std::uint32_t mant = x & 0x007FFFFFu;

  if (biased == 0xFF)  // Inf / NaN
    return static_cast<std::uint16_t>(sign | 0x7C00u | (mant ? 0x0200u : 0u));

  // Unbiased exponent re-biased to half's 15.
  const std::int32_t exp = static_cast<std::int32_t>(biased) - 127 + 15;

  if (exp >= 0x1F)  // overflow -> Inf
    return static_cast<std::uint16_t>(sign | 0x7C00u);

  if (exp <= 0) {  // subnormal or zero
    if (exp < -10) return static_cast<std::uint16_t>(sign);  // underflow -> +/-0
    const std::uint32_t m = mant | 0x00800000u;              // restore implicit 1
    const int shift = 14 - exp;                              // in [14, 24]
    std::uint32_t half_mant = m >> shift;
    const std::uint32_t rem = m & ((1u << shift) - 1u);
    const std::uint32_t halfway = 1u << (shift - 1);
    if (rem > halfway || (rem == halfway && (half_mant & 1u))) ++half_mant;
    return static_cast<std::uint16_t>(sign | half_mant);
  }

  // Normal. Add the round bit into the COMBINED value so a mantissa carry
  // propagates into the exponent (and, at the top, cleanly to Inf).
  std::uint16_t half = static_cast<std::uint16_t>(
      sign | (static_cast<std::uint32_t>(exp) << 10) | (mant >> 13));
  const std::uint32_t rem = mant & 0x1FFFu;
  if (rem > 0x1000u || (rem == 0x1000u && (half & 1u)))
    half = static_cast<std::uint16_t>(half + 1);
  return half;
}

float half_to_float(std::uint16_t half) {
  const std::uint32_t sign = static_cast<std::uint32_t>(half & 0x8000u) << 16;
  std::uint32_t exp = (half >> 10) & 0x1Fu;
  std::uint32_t mant = half & 0x3FFu;
  std::uint32_t f;
  if (exp == 0) {
    if (mant == 0) {
      f = sign;
    } else {  // subnormal -> normalize
      exp = 1;
      while ((mant & 0x400u) == 0) {
        mant <<= 1;
        --exp;
      }
      mant &= 0x3FFu;
      f = sign | ((exp + (127u - 15u)) << 23) | (mant << 13);
    }
  } else if (exp == 0x1F) {  // Inf / NaN
    f = sign | 0x7F800000u | (mant << 13);
  } else {  // normal
    f = sign | ((exp + (127u - 15u)) << 23) | (mant << 13);
  }
  float out;
  std::memcpy(&out, &f, sizeof(out));
  return out;
}

// ---------------------------------------------------------------------------

long long wall_clock_ms() {
  using namespace std::chrono;
  return duration_cast<milliseconds>(system_clock::now().time_since_epoch())
      .count();
}

double steady_clock_ms() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch())
      .count();
}

// ---------------------------------------------------------------------------
// Process memory (task 2026-08-02-iteration-phase-timing).

ProcessMemory process_memory() {
  ProcessMemory pm;  // every field starts NEGATIVE = "not answered"
  constexpr double kMb = 1024.0 * 1024.0;

#if defined(__unix__) || defined(__APPLE__)
  {
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) == 0) {
      // ru_maxrss is BYTES on macOS/BSD and KILOBYTES on Linux — the one
      // portability trap in this function, and getting it wrong would be a
      // 1024x error in the exact number the paging question turns on.
#if defined(__APPLE__)
      pm.peak_rss_mb = static_cast<double>(ru.ru_maxrss) / kMb;
#else
      pm.peak_rss_mb = static_cast<double>(ru.ru_maxrss) / 1024.0;
#endif
      // Major faults = faults the kernel had to satisfy from BACKING STORE.
      // A machine that is genuinely paging shows this climbing; a machine that
      // is merely large does not. It is the direct test, so it is recorded even
      // where richer counters exist.
      pm.major_faults = static_cast<long long>(ru.ru_majflt);
    }
  }
#endif

#if defined(__APPLE__)
  {
    // phys_footprint is what the kernel charges this process (compressed pages
    // included) — the number that decides whether the machine is under pressure.
    task_vm_info_data_t vmi;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO,
                  reinterpret_cast<task_info_t>(&vmi), &count) == KERN_SUCCESS) {
      // phys_footprint arrived in REV1; `compressed` predates every revision.
      pm.compressed_mb = static_cast<double>(vmi.compressed) / kMb;
      pm.rss_mb = count >= TASK_VM_INFO_REV1_COUNT
                      ? static_cast<double>(vmi.phys_footprint) / kMb
                      : static_cast<double>(vmi.resident_size) / kMb;
      // The per-task SWAPIN ledger arrived in REV6; a shorter reply means the
      // running kernel does not report it, so it stays -1 ("not answered")
      // rather than 0 ("measured no swapping") — the distinction the whole
      // memory-pressure question turns on.
      if (count >= TASK_VM_INFO_REV6_COUNT)
        pm.swapins = static_cast<long long>(vmi.ledger_swapins);
    }
  }
  {
    // Host-wide availability: free + inactive + speculative pages. "Peak RSS
    // against available RAM" needs a denominator, and a total-RAM denominator
    // would overstate the headroom a running machine actually has.
    vm_statistics64_data_t vms;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_size_t page = 0;
    if (host_page_size(mach_host_self(), &page) == KERN_SUCCESS &&
        host_statistics64(mach_host_self(), HOST_VM_INFO64,
                          reinterpret_cast<host_info64_t>(&vms),
                          &count) == KERN_SUCCESS) {
      const double pages = static_cast<double>(vms.free_count) +
                           static_cast<double>(vms.inactive_count) +
                           static_cast<double>(vms.speculative_count);
      pm.available_mb = pages * static_cast<double>(page) / kMb;
    }
  }
#elif defined(__linux__)
  {
    // /proc/self/statm: field 2 is resident pages.
    if (std::FILE* f = std::fopen("/proc/self/statm", "r")) {
      long long total = 0, resident = 0;
      if (std::fscanf(f, "%lld %lld", &total, &resident) == 2) {
        const double page = static_cast<double>(sysconf(_SC_PAGESIZE));
        pm.rss_mb = static_cast<double>(resident) * page / kMb;
      }
      std::fclose(f);
    }
    if (std::FILE* f = std::fopen("/proc/meminfo", "r")) {
      char key[64];
      long long kb = 0;
      while (std::fscanf(f, "%63s %lld kB\n", key, &kb) == 2)
        if (std::strcmp(key, "MemAvailable:") == 0) {
          pm.available_mb = static_cast<double>(kb) / 1024.0;
          break;
        }
      std::fclose(f);
    }
  }
#endif
  return pm;
}

// ---------------------------------------------------------------------------
// Per-iteration CSV.

const char kIterationCsvHeader[] =
    "rung,iter,wall_ms,compliance,achieved_vf,plateau,cg_iters,cg_multigrid,beta,"
    "hier_built,mg_cycles_attempted,infeasible,recycle_dim,active_fraction,"
    // ── PHASE TIMING (task 2026-08-02-iteration-phase-timing) ──────────────
    "total_ms,tail_prev_ms,filter_ms,project_ms,solve_ms,fea_ms,sens_ms,"
    "update_ms,analysis_ms,observe_ms,residual_ms,"
    // ── the solve's own split (a SUB-split of solve_ms, not extra terms) ───
    "solver_build_ms,mg_build_ms,mg_ms,cg_ms,geneo_setup_ms,geneo_apply_ms,"
    "recycle_ms,"
    // ── work counters + the GenEO lifecycle that explains them ────────────
    "fea_solves,matvecs,geneo_dim,geneo_action,"
    // ── process memory (negative = the platform could not answer) ─────────
    "rss_mb,peak_rss_mb,compressed_mb,available_mb,major_faults,swapins";

IterationCsvWriter::IterationCsvWriter(const std::string& path) : path_(path) {
  out_.open(path, std::ios::binary | std::ios::trunc);
  if (!out_)
    throw std::runtime_error("IterationCsvWriter: cannot open " + path);
  out_ << kIterationCsvHeader << '\n';
  out_.flush();
  if (!out_)
    throw std::runtime_error("IterationCsvWriter: failed writing header to " +
                             path);
}

void IterationCsvWriter::append(std::size_t rung,
                                const SimpIterationObservation& obs) {
  append_at(rung, obs, wall_clock_ms());
}

void IterationCsvWriter::append_at(std::size_t rung,
                                   const SimpIterationObservation& obs,
                                   long long wall_ms) {
  // %.10g keeps the objective's magnitude honest across the ~30x drop of a solve;
  // %.6f is ample for the [0,1] volume fraction. `beta` (handoff 123) is the
  // continuation sharpness this iteration — 0 while not projecting, else the
  // integer-valued stage β (1/2/4/…), so %.6g prints it exactly and compactly.
  // `hier_built`/`mg_cycles_attempted` (handoff 128) make build-rejection vs
  // stagnation a direct read: cg_multigrid=0 with hier_built=1 is stagnation,
  // hier_built=0 is build-rejection (or the 127 latch). append+flush = crash-safe.
  // `infeasible` (handoff 131) is the rung-infeasibility verdict at this iteration:
  // it reads 1 on AT MOST the rung's LAST row, and that row is where the rung was
  // ended as "load path lost" (0 on every row of every healthy rung).
  // `active_fraction` (active-domain phase 1) is the fraction of the analysis
  // grid's solid elements this iteration's trajectory solve actually assembled:
  // exactly 1.000000 when the active domain is off, has latched off, or the solve
  // fell back to the full domain — so the column is comparable across every run.
  //
  // Task 2026-08-02-iteration-phase-timing appends the PHASE columns. `wall_ms`
  // above is unchanged and still an epoch TIMESTAMP (it always was — the name
  // predates any duration on this row); `total_ms` is this iteration's measured
  // DURATION and `residual_ms` is the part of it no named phase claimed. The
  // solver_* columns SUB-SPLIT solve_ms and must not be added to the sum. A
  // negative memory column means the platform could not answer, never zero.
  char buf[720];
  std::snprintf(
      buf, sizeof(buf),
      "%zu,%d,%lld,%.10g,%.6f,%d,%d,%d,%.6g,%d,%d,%d,%d,%.6f,"
      "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,"
      "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,"
      "%lld,%lld,%d,%d,"
      "%.2f,%.2f,%.2f,%.2f,%lld,%lld\n",
      rung, obs.iteration, wall_ms, obs.compliance, obs.volume_fraction,
      obs.plateau ? 1 : 0, obs.cg_iterations, obs.cg_used_multigrid ? 1 : 0,
      obs.beta, obs.cg_hier_built ? 1 : 0, obs.cg_mg_cycles_attempted,
      obs.infeasible ? 1 : 0, obs.cg_recycle_dim, obs.active_fraction,
      obs.phases.total_ms, obs.phases.tail_prev_ms, obs.phases.filter_ms,
      obs.phases.project_ms, obs.phases.solve_ms, obs.phases.fea_ms,
      obs.phases.sens_ms, obs.phases.update_ms, obs.phases.analysis_ms,
      obs.phases.observe_ms, obs.phases.residual_ms, obs.phases.solver_build_ms,
      obs.phases.solver_mg_build_ms, obs.phases.solver_mg_ms,
      obs.phases.solver_cg_ms, obs.phases.solver_geneo_setup_ms,
      obs.phases.solver_geneo_apply_ms, obs.phases.solver_recycle_ms,
      obs.phases.fea_solves, obs.phases.matvecs, obs.cg_geneo_dim,
      obs.cg_geneo_action, obs.phases.rss_mb, obs.phases.peak_rss_mb,
      obs.phases.compressed_mb, obs.phases.available_mb,
      obs.phases.major_faults, obs.phases.swapins);
  out_ << buf;
  out_.flush();
  if (!out_)
    throw std::runtime_error("IterationCsvWriter: failed writing row to " +
                             path_);
  ++rows_;
}

// ---------------------------------------------------------------------------
// Density snapshots.

namespace {

void ensure_dir(const std::string& dir) {
  std::error_code ec;
  std::filesystem::create_directories(dir, ec);
  if (ec)
    throw std::runtime_error("snapshot: cannot create directory " + dir + ": " +
                             ec.message());
}

std::string join(const std::string& dir, const std::string& name) {
  if (dir.empty()) return name;
  return dir + "/" + name;
}

}  // namespace

void write_density_snapshot(const std::string& dir, const std::string& basename,
                            const VoxelGrid& grid,
                            const std::vector<double>& density,
                            std::size_t rung, int iteration, bool boundary) {
  if (density.size() != grid.voxel_count())
    throw std::runtime_error(
        "write_density_snapshot: density size != grid.voxel_count()");
  ensure_dir(dir);

  // Raw float16, x-fastest grid order (i + nx*(j + ny*k)) — exactly grid index
  // order, so no reindexing is needed on read.
  const std::string raw_path = join(dir, basename + ".f16");
  {
    std::ofstream raw(raw_path, std::ios::binary | std::ios::trunc);
    if (!raw)
      throw std::runtime_error("write_density_snapshot: cannot open " +
                               raw_path);
    std::vector<std::uint16_t> halves(density.size());
    for (std::size_t i = 0; i < density.size(); ++i)
      halves[i] = float_to_half(static_cast<float>(density[i]));
    raw.write(reinterpret_cast<const char*>(halves.data()),
              static_cast<std::streamsize>(halves.size() * sizeof(std::uint16_t)));
    raw.flush();
    if (!raw)
      throw std::runtime_error("write_density_snapshot: failed writing " +
                               raw_path);
  }

  // Tiny JSON sidecar (dims, spacing, origin, rung, iter, boundary, voxels).
  const std::string json_path = join(dir, basename + ".json");
  {
    std::ofstream js(json_path, std::ios::binary | std::ios::trunc);
    if (!js)
      throw std::runtime_error("write_density_snapshot: cannot open " +
                               json_path);
    char buf[512];
    std::snprintf(
        buf, sizeof(buf),
        "{\"dims\":[%d,%d,%d],\"spacing\":%.10g,"
        "\"origin\":[%.10g,%.10g,%.10g],\"rung\":%zu,\"iter\":%d,"
        "\"boundary\":%s,\"voxels\":%zu,\"dtype\":\"float16\","
        "\"order\":\"x-fastest\"}\n",
        grid.nx, grid.ny, grid.nz, grid.spacing, grid.origin.x, grid.origin.y,
        grid.origin.z, rung, iteration, boundary ? "true" : "false",
        density.size());
    js << buf;
    js.flush();
    if (!js)
      throw std::runtime_error("write_density_snapshot: failed writing " +
                               json_path);
  }
}

std::vector<float> read_density_f16(const std::string& path,
                                    std::size_t count) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw std::runtime_error("read_density_f16: cannot open " + path);
  std::vector<std::uint16_t> halves(count);
  in.read(reinterpret_cast<char*>(halves.data()),
          static_cast<std::streamsize>(count * sizeof(std::uint16_t)));
  if (static_cast<std::size_t>(in.gcount()) != count * sizeof(std::uint16_t))
    throw std::runtime_error("read_density_f16: " + path +
                             " is not exactly the expected size");
  std::vector<float> out(count);
  for (std::size_t i = 0; i < count; ++i) out[i] = half_to_float(halves[i]);
  return out;
}

SnapshotCapture::SnapshotCapture(std::string dir, int every_n, int cap)
    : dir_(std::move(dir)), every_n_(every_n > 0 ? every_n : 1), cap_(cap) {}

bool SnapshotCapture::capture(const VoxelGrid& grid,
                              const std::vector<double>& density,
                              std::size_t rung, int iteration, bool boundary) {
  // Cadence: boundaries always; per-iteration every `every_n`.
  if (!boundary && (iteration % every_n_ != 0)) return false;

  char base[96];
  std::snprintf(base, sizeof(base), "snap_rung%zu_iter%04d%s", rung, iteration,
                boundary ? "_boundary" : "");
  write_density_snapshot(dir_, base, grid, density, rung, iteration, boundary);
  ++written_;

  if (!boundary) {
    iter_snaps_.push_back(base);
    // Per-job cap with oldest-eviction over the PER-ITERATION snapshots only
    // (boundaries are the terminal/per-rung designs and are kept).
    while (cap_ > 0 && static_cast<int>(iter_snaps_.size()) > cap_) {
      const std::string victim = iter_snaps_.front();
      iter_snaps_.erase(iter_snaps_.begin());
      std::error_code ec;
      std::filesystem::remove(join(dir_, victim + ".f16"), ec);
      std::filesystem::remove(join(dir_, victim + ".json"), ec);
      ++evicted_;
    }
  }
  return true;
}

// ---------------------------------------------------------------------------
// Run version record.

namespace {

std::string json_escape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 2);
  for (char c : s) {
    if (c == '"' || c == '\\') out.push_back('\\');
    out.push_back(c);
  }
  return out;
}

std::string bool_json(bool b) { return b ? "true" : "false"; }

}  // namespace

std::string run_info_json(const RunInfo& info) {
  std::string s = "{\n";
  auto str = [&](const char* k, const std::string& v, bool comma = true) {
    s += "  \"";
    s += k;
    s += "\": \"" + json_escape(v) + "\"";
    s += comma ? ",\n" : "\n";
  };
  auto num = [&](const char* k, const std::string& v, bool comma = true) {
    s += "  \"";
    s += k;
    s += "\": " + v;
    s += comma ? ",\n" : "\n";
  };
  char nb[64];
  auto fmt = [&](double d) {
    std::snprintf(nb, sizeof(nb), "%.10g", d);
    return std::string(nb);
  };
  auto fmt_ll = [&](long long v) {
    std::snprintf(nb, sizeof(nb), "%lld", v);
    return std::string(nb);
  };
  auto fmt_i = [&](int v) {
    std::snprintf(nb, sizeof(nb), "%d", v);
    return std::string(nb);
  };

  str("cli_version", info.cli_version);
  str("fingerprint", info.fingerprint);
  str("mode", info.mode);
  str("material", info.material);
  // True source format the user supplied (handoff 2026-07-26-3mf-optimize-path):
  // "3mf" even when the model file is an STL working copy the app normalised it to.
  str("source_format", info.source_format);
  num("resolution", fmt_i(info.resolution));
  str("load_source", info.load_source);
  str("solver", info.solver);
  // cg_multigrid / mg_levels are an OBSERVED outcome: null until the post-run
  // finalize records them, so an unfinished run never asserts a (mis)leading value.
  num("cg_multigrid",
      info.cg_multigrid_observed ? bool_json(info.cg_multigrid) : "null");
  num("mg_levels",
      info.cg_multigrid_observed ? fmt_i(info.mg_levels) : "null");
  // Handoff 128 — fallback mode (carried / stagnated-latched / build-rejected).
  // A string outcome: JSON null until observed (or when the solver isn't MG).
  num("mg_mode",
      (info.mg_mode_observed && !info.mg_mode.empty())
          ? std::string("\"") + json_escape(info.mg_mode) + "\""
          : std::string("null"));
  num("galerkin_block_cache", bool_json(info.galerkin_block_cache));
  num("mixed_precision", bool_json(info.mixed_precision));
  num("matfree_threads", fmt_i(info.matfree_threads));
  num("krylov_recycling", bool_json(info.krylov_recycling));
  num("krylov_recycle_dim", fmt_i(info.krylov_recycle_dim));
  num("krylov_recycle_wrap_multigrid", bool_json(info.krylov_recycle_wrap_multigrid));
  // Handoff 2026-07-29-geneo-arming — the GenEO deflation posture + lifecycle.
  num("geneo_twolevel", bool_json(info.geneo_twolevel));
  num("geneo_trigger_iters", fmt_i(info.geneo_trigger_iters));
  num("geneo_rebuild_factor", fmt(info.geneo_rebuild_factor));
  num("geneo_basis_builds", fmt_i(static_cast<int>(info.geneo_basis_builds)));
  num("geneo_coarse_refreshes",
      fmt_i(static_cast<int>(info.geneo_coarse_refreshes)));
  num("geneo_armed_solves", fmt_i(static_cast<int>(info.geneo_armed_solves)));
  num("geneo_basis_dim", fmt_i(info.geneo_basis_dim));
  num("geneo_basis_mb", fmt(info.geneo_basis_mb));
  num("warm_start_inherit", bool_json(info.warm_start_inherit));
  num("warm_start_coarse", bool_json(info.warm_start_coarse));
  num("warm_start_coarse_iterations", fmt_i(info.warm_start_coarse_iterations));
  num("warm_start_coarse_ms", fmt(info.warm_start_coarse_ms));
  num("warm_start_coarse_matvecs",
      fmt_i(static_cast<int>(info.warm_start_coarse_matvecs)));
  num("projection", bool_json(info.projection));
  // Handoff 123 — conditional MMA-projection echo: the armed threshold plus the
  // per-rung fired flags and measured grayscale Mnd (the honest cost readout).
  num("conditional_mma_projection_mnd_threshold",
      fmt(info.conditional_mma_projection_mnd_threshold));
  {
    std::string fired = "[";
    for (std::size_t i = 0; i < info.conditional_projection_fired.size(); ++i) {
      if (i) fired += ", ";
      fired += info.conditional_projection_fired[i] ? "true" : "false";
    }
    fired += "]";
    num("conditional_projection_fired", fired);
    std::string mnd = "[";
    for (std::size_t i = 0; i < info.conditional_projection_rung_mnd.size();
         ++i) {
      if (i) mnd += ", ";
      // A rung cancelled before it converged has no measured grayness — emit
      // JSON `null` (NaN is not valid JSON) rather than a bogus number.
      const double v = info.conditional_projection_rung_mnd[i];
      mnd += std::isfinite(v) ? fmt(v) : std::string("null");
    }
    mnd += "]";
    num("conditional_projection_rung_mnd", mnd);
  }
  // Handoff 131 — rung-infeasibility: the armed thresholds (config, written
  // up-front) and the per-rung outcome (empty until the post-run finalize).
  num("infeasible_compliance_ratio", fmt(info.infeasible_compliance_ratio));
  num("infeasible_cg_blowup", fmt(info.infeasible_cg_blowup));
  num("infeasible_flat_tol", fmt(info.infeasible_flat_tol));
  num("infeasible_window", fmt_i(info.infeasible_window));
  {
    std::string ri = "[";
    for (std::size_t i = 0; i < info.rung_infeasible.size(); ++i) {
      if (i) ri += ", ";
      ri += info.rung_infeasible[i] ? "true" : "false";
    }
    ri += "]";
    num("rung_infeasible", ri);
  }
  // Handoff 2026-07-27-nonconvergence-rejection — the per-rung non-convergence
  // outcome: which rungs a linear solve failed to converge on, and for each the CG
  // iteration reached and the residual it stalled at (empty until the post-run
  // finalize; all-false/zeros is "every rung's solves converged").
  {
    std::string nc = "[";
    for (std::size_t i = 0; i < info.rung_non_convergent.size(); ++i) {
      if (i) nc += ", ";
      nc += info.rung_non_convergent[i] ? "true" : "false";
    }
    nc += "]";
    num("rung_non_convergent", nc);
    std::string ni = "[";
    for (std::size_t i = 0; i < info.rung_non_convergent_iteration.size(); ++i) {
      if (i) ni += ", ";
      ni += fmt_i(info.rung_non_convergent_iteration[i]);
    }
    ni += "]";
    num("rung_non_convergent_iteration", ni);
    std::string nr = "[";
    for (std::size_t i = 0; i < info.rung_non_convergent_residual.size(); ++i) {
      if (i) nr += ", ";
      nr += fmt(info.rung_non_convergent_residual[i]);
    }
    nr += "]";
    num("rung_non_convergent_residual", nr);
  }
  // active-domain phase 1 — the requested band (config, up-front) and the
  // per-rung latch outcome (empty until the post-run finalize).
  num("active_domain_band", fmt_i(info.active_domain_band));
  {
    std::string br = "[";
    for (std::size_t i = 0; i < info.active_domain_band_resolved.size(); ++i) {
      if (i) br += ", ";
      br += fmt_i(info.active_domain_band_resolved[i]);
    }
    br += "]";
    num("active_domain_band_resolved", br);
    std::string al = "[";
    for (std::size_t i = 0; i < info.active_domain_latched.size(); ++i) {
      if (i) al += ", ";
      al += info.active_domain_latched[i] ? "true" : "false";
    }
    al += "]";
    num("active_domain_latched", al);
    std::string li = "[";
    for (std::size_t i = 0; i < info.active_domain_latch_iteration.size(); ++i) {
      if (i) li += ", ";
      li += fmt_i(info.active_domain_latch_iteration[i]);
    }
    li += "]";
    num("active_domain_latch_iteration", li);
    std::string ec = "[";
    for (std::size_t i = 0; i < info.active_domain_escape_count.size(); ++i) {
      if (i) ec += ", ";
      ec += std::to_string(info.active_domain_escape_count[i]);
    }
    ec += "]";
    num("active_domain_escape_count", ec);
    std::string ar = "[";
    for (std::size_t i = 0; i < info.active_domain_latch_reason.size(); ++i) {
      if (i) ar += ", ";
      ar += "\"" + json_escape(info.active_domain_latch_reason[i]) + "\"";
    }
    ar += "]";
    num("active_domain_latch_reason", ar);
    std::string af = "[";
    for (std::size_t i = 0; i < info.active_domain_fraction_mean.size(); ++i) {
      if (i) af += ", ";
      af += fmt(info.active_domain_fraction_mean[i]);
    }
    af += "]";
    num("active_domain_fraction_mean", af);
  }
  // Handoff 2026-07-25-draft-quality — the draft posture echo (config up-front) plus
  // the per-rung outcome (empty until the post-run finalize) and the compact
  // escalation list.
  num("draft_quality", bool_json(info.draft_quality));
  num("draft_loose_tol", fmt(info.draft_loose_tol));
  num("draft_escalation_c_gap", fmt(info.draft_escalation_c_gap));
  {
    std::string tk = "[";
    for (std::size_t i = 0; i < info.draft_rung_tail_k.size(); ++i) {
      if (i) tk += ", ";
      tk += fmt_i(info.draft_rung_tail_k[i]);
    }
    tk += "]";
    num("draft_rung_tail_k", tk);
    std::string gp = "[";
    for (std::size_t i = 0; i < info.draft_rung_c_gap.size(); ++i) {
      if (i) gp += ", ";
      // A rung that measured no gap (cancelled/infeasible, recorded as -1) emits
      // JSON `null` rather than a bogus negative gap.
      const double v = info.draft_rung_c_gap[i];
      gp += (std::isfinite(v) && v >= 0.0) ? fmt(v) : std::string("null");
    }
    gp += "]";
    num("draft_rung_c_gap", gp);
    std::string es = "[";
    for (std::size_t i = 0; i < info.draft_rung_escalated.size(); ++i) {
      if (i) es += ", ";
      es += info.draft_rung_escalated[i] ? "true" : "false";
    }
    es += "]";
    num("draft_rung_escalated", es);
    // "Every escalation with its rung index and measured gap" — one object per
    // escalated rung, in ladder order.
    std::string ex = "[";
    bool first = true;
    for (std::size_t i = 0; i < info.draft_rung_escalated.size(); ++i) {
      if (!info.draft_rung_escalated[i]) continue;
      if (!first) ex += ", ";
      first = false;
      const double g = i < info.draft_rung_c_gap.size() ? info.draft_rung_c_gap[i]
                                                        : -1.0;
      ex += "{\"rung\": " + fmt_i(static_cast<int>(i)) + ", \"gap\": " +
            ((std::isfinite(g) && g >= 0.0) ? fmt(g) : std::string("null")) + "}";
    }
    ex += "]";
    num("draft_escalations", ex);
    // Handoff 2026-07-26-draft-quality-phase2 — the design-space trigger echo.
    num("draft_use_design_trigger", bool_json(info.draft_use_design_trigger));
    num("draft_escalation_design_flip", fmt(info.draft_escalation_design_flip));
    std::string pf = "[";
    for (std::size_t i = 0; i < info.draft_rung_probe_flip.size(); ++i) {
      if (i) pf += ", ";
      const double v = info.draft_rung_probe_flip[i];
      pf += (std::isfinite(v) && v >= 0.0) ? fmt(v) : std::string("null");
    }
    pf += "]";
    num("draft_rung_probe_flip", pf);
    std::string pc = "[";
    for (std::size_t i = 0; i < info.draft_rung_probe_cg.size(); ++i) {
      if (i) pc += ", ";
      pc += fmt_i(static_cast<int>(info.draft_rung_probe_cg[i]));
    }
    pc += "]";
    num("draft_rung_probe_cg", pc);
  }
  num("min_feature_mm", fmt(info.min_feature_mm));
  num("margin_stop", fmt(info.margin_stop));
  num("infill_percent", fmt(info.infill_percent));
  num("width_aware_knockdown", bool_json(info.width_aware_knockdown));
  num("wall_loops", std::to_string(info.wall_loops));
  num("wall_line_width_mm", fmt(info.wall_line_width_mm));
  num("wall_line_width_outer_mm", fmt(info.wall_line_width_outer_mm));
  num("wall_thickness_mm", fmt(info.wall_thickness_mm));
  num("has_design_box", bool_json(info.has_design_box));

  std::string ladder = "[";
  for (std::size_t i = 0; i < info.ladder.size(); ++i) {
    if (i) ladder += ", ";
    ladder += fmt(info.ladder[i]);
  }
  ladder += "]";
  num("ladder", ladder);

  num("created_wall_ms", fmt_ll(info.created_wall_ms));
  num("iteration_csv", bool_json(info.iteration_csv));
  num("density_snapshots", bool_json(info.density_snapshots));
  num("snapshot_every", fmt_i(info.snapshot_every));

  // Lattice certification posture (handoff 2026-07-27-lattice-certification). Emitted
  // ONLY when a lattice region was certified, so a non-latticed run (every current
  // run — no job front-end declares a region yet) is byte-for-byte the pre-lattice
  // record: snapshot_cap stays the last field with no trailing comma and NO lattice
  // key is written. A latticed run appends a nested "lattice" object with the topology,
  // cell size, relative-density RANGE and region size, and the strut-strength-
  // uncertified flag (the margin certifies composite stiffness + solid strength, not
  // strut strength — Phase 2 de-homogenization).
  // Two optional trailing objects: the certification `lattice` and the GEOMETRY
  // `lattice_export` (handoff 2026-07-28-lattice-generation-production). The LAST
  // emitted field carries no trailing comma; when both are absent snapshot_cap is
  // last exactly as before (byte-identical, the P1 bar).
  const bool has_cert = info.lattice_present;
  const bool has_exp = info.lattice_export_present;
  const bool has_grad = info.grading_present;
  // THE EXPORTED GEOMETRY'S FRAME (handoff 2026-08-01-bake-build-orientation).
  // Emitted only when the export was rotated, so a run that writes model-space
  // coordinates keeps its run_info byte-identical.
  const bool has_frame = info.export_baked;
  num("snapshot_cap", fmt_i(info.snapshot_cap),
      /*comma=*/has_cert || has_exp || has_grad || has_frame);
  if (has_cert) {
    std::string lat = "{\"topology\": \"" + info.lattice_topology + "\"";
    lat += ", \"cell_size_mm\": " + fmt(info.lattice_cell_size_mm);
    lat += ", \"rho_min\": " + fmt(info.lattice_rho_min);
    lat += ", \"rho_max\": " + fmt(info.lattice_rho_max);
    lat += ", \"region_voxels\": " + fmt_ll(info.lattice_region_voxels);
    lat += ", \"margin_worst_case\": " + fmt(info.lattice_margin_worst_case);
    lat += ", \"margin_effective\": " + fmt(info.lattice_margin_effective);
    lat += ", \"accepted\": " + bool_json(info.lattice_accepted);
    lat += ", \"strength_uncertified\": " + bool_json(info.lattice_strength_uncertified);
    // Strut-strength REPORT (task 2026-07-31-lattice-strut-strength-report):
    // report-only de-homogenized strut margins (in-plane and interlayer kept
    // SEPARATE — which one binds is the point). Keys appear only when the report
    // ran, so pre-existing latticed records are byte-identical.
    if (info.lattice_strut_report_present) {
      // Unbounded margins (a mode nothing loads) and an over-cap member width are
      // legitimate +inf — serialize as null (the run_info convention, cf. mnd).
      auto fmt_or_null = [&](double v) {
        return std::isfinite(v) ? fmt(v) : std::string("null");
      };
      lat += ", \"strut_margin_in_plane\": " +
             fmt_or_null(info.lattice_strut_margin_in_plane);
      lat += ", \"strut_margin_interlayer\": " +
             fmt_or_null(info.lattice_strut_margin_interlayer);
      lat += ", \"strut_margin_worst_case\": " +
             fmt_or_null(info.lattice_strut_margin_worst_case);
      lat += ", \"strut_z_knockdown\": " + fmt(info.lattice_strut_z_knockdown);
      lat += ", \"strut_z_knockdown_unsourced\": true";
      lat += ", \"strut_min_cells_per_member\": " +
             fmt_or_null(info.lattice_strut_min_cells_per_member);
      lat += ", \"strut_out_of_regime\": " +
             bool_json(info.lattice_strut_out_of_regime);
      lat += ", \"strut_rho_clamped_voxels\": " +
             fmt_ll(info.lattice_strut_rho_clamped_voxels);
      lat += ", \"strut_gated\": false";
    }
    lat += "}";
    num("lattice", lat, /*comma=*/has_exp || has_grad || has_frame);
  }
  if (has_exp) {
    std::string le = "{\"topology\": \"" + info.lattice_export_topology + "\"";
    le += ", \"cell_size_mm\": " + fmt(info.lattice_export_cell_mm);
    le += ", \"strut_radius_min_mm\": " + fmt(info.lattice_export_strut_radius_min_mm);
    le += ", \"strut_radius_max_mm\": " + fmt(info.lattice_export_strut_radius_max_mm);
    le += ", \"latticed_cells\": " + fmt_ll(info.lattice_export_latticed_cells);
    le += ", \"region_voxels\": " + fmt_ll(info.lattice_export_region_voxels);
    le += ", \"triangles\": " + fmt_ll(info.lattice_export_triangles);
    le += ", \"variant_count\": " + fmt_i(info.lattice_export_variant_count);
    le += ", \"emit_stl\": " + bool_json(info.lattice_export_emit_stl);
    le += ", \"emit_3mf\": " + bool_json(info.lattice_export_emit_3mf);
    le += ", \"interpenetrating_soup\": " +
          bool_json(info.lattice_export_interpenetrating_soup);
    le += ", \"gen_seconds\": " + fmt(info.lattice_export_gen_seconds);
    le += ", \"gen_fraction\": " + fmt(info.lattice_export_gen_fraction);
    // Boundary finish (handoff 2026-07-29-lattice-boundary-finish): the clip /
    // skin / collar record + the B9 volume accounting (analytic per-primitive
    // sums on the soup basis, overlaps not deducted).
    le += ", \"skin\": \"" + info.lattice_export_skin + "\"";
    le += ", \"clipped_struts\": " + fmt_ll(info.lattice_export_clipped_struts);
    le += ", \"landings\": " + fmt_ll(info.lattice_export_landings);
    le += ", \"anchor_nodes\": " + fmt_ll(info.lattice_export_anchor_nodes);
    le += ", \"skin_triangles\": " + fmt_ll(info.lattice_export_skin_triangles);
    le += ", \"rim_triangles\": " + fmt_ll(info.lattice_export_rim_triangles);
    le += ", \"interior_volume_mm3\": " +
          fmt(info.lattice_export_interior_volume_mm3);
    le += ", \"skin_volume_mm3\": " + fmt(info.lattice_export_skin_volume_mm3);
    le += ", \"rim_volume_mm3\": " + fmt(info.lattice_export_rim_volume_mm3);
    // Outer finish (task 2026-07-30-lattice-skin-freeform): keys appear ONLY
    // for a non-default finish, so a "shell" run's record is byte-identical to
    // the boundary-finish record (bar E1).
    if (info.lattice_export_outer_finish != "shell") {
      le += ", \"outer_finish\": \"" + info.lattice_export_outer_finish + "\"";
      le += ", \"skin_chords\": " + fmt_ll(info.lattice_export_skin_chords);
      le += ", \"skin_chords_rejected_band\": " +
            fmt_ll(info.lattice_export_skin_chords_rejected_band);
      le += ", \"skin_chords_rejected_projection\": " +
            fmt_ll(info.lattice_export_skin_chords_rejected_projection);
      le += ", \"skin_chords_clipped_away\": " +
            fmt_ll(info.lattice_export_skin_chords_clipped_away);
      le += ", \"finish_certified\": " +
            bool_json(info.lattice_export_finish_certified);
    }
    // Lattice ROLE regions + solid companion (task lattice-page-core-hookup,
    // stage 1): keys appear ONLY when roles/companion were in play, so a job
    // with no lattice.regions and no grading writes a byte-identical record.
    if (info.lattice_export_role_regions_present) {
      le += ", \"include_regions\": " +
            fmt_ll(info.lattice_export_include_regions);
      le += ", \"exclude_regions\": " +
            fmt_ll(info.lattice_export_exclude_regions);
      le += ", \"solid_region_voxels\": " +
            fmt_ll(info.lattice_export_solid_region_voxels);
      le += ", \"solid_region_volume_mm3\": " +
            fmt(info.lattice_export_solid_region_volume_mm3);
      le += ", \"solid_region_triangles\": " +
            fmt_ll(info.lattice_export_solid_region_triangles);
      le += ", \"include_void_voxels\": " +
            fmt_ll(info.lattice_export_include_void_voxels);
    }
    le += "}";
    num("lattice_export", le, /*comma=*/has_grad || has_frame);
  }
  if (has_grad) {
    // The grading-law report (handoff 2026-07-29-lattice-grading-law). `band_*` and
    // `cells_per_member_floor` are the limits the law READ from core (provenance);
    // `solid_fallback_voxels` / `region_ungradeable` are bar L4 (members too thin to
    // grade stayed solid); `min_strut_diameter_mm` / `any_strut_below_min` are the
    // requirement-3 printability check. ALWAYS last when present (no trailing comma).
    std::string gr = "{\"topology\": \"" + info.grading_topology + "\"";
    gr += ", \"band_rho_min\": " + fmt(info.grading_band_rho_min);
    gr += ", \"band_rho_max\": " + fmt(info.grading_band_rho_max);
    gr += ", \"cells_per_member_floor\": " +
          fmt(info.grading_cells_per_member_floor);
    gr += ", \"cell_size_mm\": " + fmt(info.grading_cell_size_mm);
    gr += ", \"printability_floor_mm\": " + fmt(info.grading_printability_floor_mm);
    gr += ", \"cell_size_floored\": " + bool_json(info.grading_cell_size_floored);
    gr += ", \"min_extrudable_width_mm\": " +
          fmt(info.grading_min_extrudable_width_mm);
    gr += ", \"rho_min_used\": " + fmt(info.grading_rho_min_used);
    gr += ", \"rho_max_used\": " + fmt(info.grading_rho_max_used);
    gr += ", \"region_voxels\": " + fmt_ll(info.grading_region_voxels);
    gr += ", \"latticed_voxels\": " + fmt_ll(info.grading_latticed_voxels);
    gr += ", \"solid_fallback_voxels\": " +
          fmt_ll(info.grading_solid_fallback_voxels);
    // Both can be the +inf "thicker than the EDT cap" sentinel (every latticed member
    // exceeds it); JSON has no infinity, so emit null exactly as the Mnd field does.
    gr += ", \"min_member_width_mm\": " +
          (std::isfinite(info.grading_min_member_width_mm)
               ? fmt(info.grading_min_member_width_mm)
               : std::string("null"));
    gr += ", \"min_cells_per_member\": " +
          (std::isfinite(info.grading_min_cells_per_member)
               ? fmt(info.grading_min_cells_per_member)
               : std::string("null"));
    gr += ", \"min_strut_diameter_mm\": " + fmt(info.grading_min_strut_diameter_mm);
    gr += ", \"max_strut_diameter_mm\": " + fmt(info.grading_max_strut_diameter_mm);
    gr += ", \"any_strut_below_min\": " +
          bool_json(info.grading_any_strut_below_min);
    gr += ", \"region_ungradeable\": " + bool_json(info.grading_region_ungradeable);
    // Cell-size mode + the swept plan. Present in every mode (a uniform run reports
    // one level), so a reader never branches; `cell_levels` is the per-REGION
    // cells-per-member report (bar R5).
    if (!info.grading_cell_mode.empty()) {
      gr += ", \"cell_mode\": \"" + info.grading_cell_mode + "\"";
      gr += ", \"cell_base_mm\": " + fmt(info.grading_cell_base_mm);
      gr += ", \"cell_max_level\": " +
            std::to_string(info.grading_cell_max_level);
      gr += ", \"cell_latticed_cells\": " +
            std::to_string(info.grading_cell_latticed_cells);
      gr += ", \"cells_raised_to_floor\": " +
            std::to_string(info.grading_cells_raised_to_floor);
      gr += ", \"cells_dropped_unprintable\": " +
            std::to_string(info.grading_cells_dropped_unprintable);
      gr += ", \"cells_split_by_balance\": " +
            std::to_string(info.grading_cells_split_by_balance);
      gr += ", \"cell_any_out_of_regime\": " +
            bool_json(info.grading_cell_any_out_of_regime);
      gr += ", \"cell_levels\": [";
      for (std::size_t i = 0; i < info.grading_cell_levels.size(); ++i) {
        const RunInfo::GradingCellLevel& L = info.grading_cell_levels[i];
        if (i) gr += ", ";
        gr += "{\"level\": " + std::to_string(L.level);
        gr += ", \"cell_size_mm\": " + fmt(L.cell_size_mm);
        gr += ", \"cells\": " + std::to_string(L.cells);
        gr += ", \"voxels\": " + std::to_string(L.voxels);
        // A negative value carries the +inf "thicker than the EDT cap" sentinel;
        // JSON has no infinity, so it serializes as null like the fields above.
        gr += ", \"min_member_width_mm\": " +
              (L.min_member_width_mm >= 0.0 ? fmt(L.min_member_width_mm)
                                            : std::string("null"));
        gr += ", \"min_cells_per_member\": " +
              (L.min_cells_per_member >= 0.0 ? fmt(L.min_cells_per_member)
                                             : std::string("null"));
        gr += ", \"min_strut_diameter_mm\": " + fmt(L.min_strut_diameter_mm);
        gr += ", \"max_strut_diameter_mm\": " + fmt(L.max_strut_diameter_mm);
        gr += ", \"out_of_regime\": " + bool_json(L.out_of_regime);
        gr += ", \"any_strut_below_min\": " + bool_json(L.any_strut_below_min);
        gr += "}";
      }
      gr += "]";
    }
    gr += "}";
    num("grading", gr, /*comma=*/has_frame);
  }

  if (has_frame) {
    // WHICH FRAME THE EXPORTED MESH IS IN — the one question a reader of the
    // exported file cannot answer from the file itself. `applied_build_dir` is
    // in the MODEL frame; in the FILE the build direction is +Z by construction.
    std::string ef = "{\"baked\": true";
    ef += ", \"build_direction_in_file\": [0, 0, 1]";
    ef += ", \"applied_build_dir_model\": [" + fmt(info.applied_build_dir_x) +
          ", " + fmt(info.applied_build_dir_y) + ", " +
          fmt(info.applied_build_dir_z) + "]";
    ef += ", \"auto_applied\": " +
          bool_json(info.export_build_direction_auto_applied);
    ef += ", \"rotation_exact\": " + bool_json(info.export_rotation_exact);
    ef += ", \"note\": \"the exported mesh was ROTATED so the certified build "
          "direction is +Z in the file. fields.bin, the voxel grid, the loads, "
          "the fixtures and the clearances are all in the MODEL frame and did "
          "NOT move. Every direction-bearing NUMBER in the report is a "
          "rigid-motion invariant and reads the same in both frames.\"";
    ef += "}";
    num("export_frame", ef, /*comma=*/false);  // last when present
  }

  s += "}\n";
  return s;
}

void write_run_info(const std::string& path, const RunInfo& info) {
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  if (!out) throw std::runtime_error("write_run_info: cannot open " + path);
  out << run_info_json(info);
  out.flush();
  if (!out) throw std::runtime_error("write_run_info: failed writing " + path);
}

}  // namespace topopt
