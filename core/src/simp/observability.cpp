#include "topopt/observability.hpp"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <stdexcept>
#include <system_error>

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

// ---------------------------------------------------------------------------
// Per-iteration CSV.

const char kIterationCsvHeader[] =
    "rung,iter,wall_ms,compliance,achieved_vf,plateau,cg_iters,cg_multigrid,beta,"
    "hier_built,mg_cycles_attempted,infeasible";

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
  char buf[240];
  std::snprintf(buf, sizeof(buf),
                "%zu,%d,%lld,%.10g,%.6f,%d,%d,%d,%.6g,%d,%d,%d\n",
                rung, obs.iteration, wall_ms, obs.compliance, obs.volume_fraction,
                obs.plateau ? 1 : 0, obs.cg_iterations,
                obs.cg_used_multigrid ? 1 : 0, obs.beta,
                obs.cg_hier_built ? 1 : 0, obs.cg_mg_cycles_attempted,
                obs.infeasible ? 1 : 0);
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
  num("warm_start_inherit", bool_json(info.warm_start_inherit));
  num("warm_start_coarse", bool_json(info.warm_start_coarse));
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
  num("min_feature_mm", fmt(info.min_feature_mm));
  num("margin_stop", fmt(info.margin_stop));
  num("infill_percent", fmt(info.infill_percent));
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
  num("snapshot_cap", fmt_i(info.snapshot_cap), /*comma=*/false);

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
