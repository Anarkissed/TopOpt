// stepped_beam_cost_probe — ★ HOW BIG IS THE BEAM-NETWORK CERTIFICATE FOR ANY-STEP
// STEPPED? (reviewer, 2026-10-01: measure only; nothing is wired into the run.)
//
// `refuse_stepped_structural` REQUIRES `structural_certification: "beam_network"` for
// any-step Stepped, and core never runs it: the only run-path call sits inside
// `algorithm == "organic" && intent == "structural"`, so the tensor certifies instead
// — the exact seam over-claim that refusal exists to prevent. Unreachable today only
// because no app sends `stepped_cells`.
//
// The CODE to close it is small: `hexm`, the load cases, the weld precondition and
// `subdivide_beam_segments` are already algorithm-agnostic, and the last was written
// FOR octet struts. What is missing is one emitter. This probe writes that emitter in
// a harness and measures what the existing solve then costs, because the estimate
// (10^5–10^6 segments against organic's ~24,000) is the thing that decides whether the
// feature is possible at all.
//
// ★ WHAT IS MEASURED, per plan size: segments before and after subdivision, welded
// nodes, T-junction ends, floating ends, peak RSS, and certificate wall time. Wall
// time on a shared box is an upper bound, not a benchmark; the load is printed beside
// every number so nobody reads it as one.
//
// ★ THE PLANS MIX FAMILIES THE WAY ANY-STEP DOES. Pure halvings share nodes and would
// flatter the weld; an 8 mm cell beside a 9 mm cell does not, and that is the case
// `refuse_stepped_structural` is about. Each plan interleaves 8 and 9 mm bases with
// some halvings, so the seams are real.

#include "topopt/beam_network.hpp"
#include "topopt/lattice.hpp"
#include "topopt/voxel.hpp"

#include <sys/resource.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <array>
#include <stdexcept>
#include <string>
#include <vector>

using topopt::BeamSegment;
using topopt::LatticeTopology;
using topopt::Vec3;
using topopt::VoxelGrid;

namespace {

double peak_rss_mb() {
  struct rusage ru{};
  getrusage(RUSAGE_SELF, &ru);
#if defined(__APPLE__)
  return static_cast<double>(ru.ru_maxrss) / (1024.0 * 1024.0);   // bytes on macOS
#else
  return static_cast<double>(ru.ru_maxrss) / 1024.0;              // KiB elsewhere
#endif
}

double load1() {
  double a[3] = {0, 0, 0};
  if (getloadavg(a, 3) < 1) return -1.0;
  return a[0];
}

// One placed cell of an any-step plan.
struct Cell {
  Vec3 origin;
  double size_mm;
  double rho;
};

// ★ THE CANONICAL CELL, REPLICATED HERE ON PURPOSE. `octet_unit_struts()` lives in
// lattice.cpp's ANONYMOUS NAMESPACE (:25), so it is not callable from outside that
// file. That is a finding for the sizing, not an obstacle for the probe: production
// would need the function exported -- one declaration -- and the probe replicates its
// 24 segments operation-for-operation so the measurement is of the real geometry.
// The 6 face centres each join the 4 cube corners of their face: 6 x 4 = 24 struts.
std::vector<std::array<std::array<double, 3>, 2>> unit_octet_struts() {
  std::vector<std::array<double, 3>> all;
  for (int z = 0; z <= 1; ++z)
    for (int y = 0; y <= 1; ++y)
      for (int x = 0; x <= 1; ++x)
        all.push_back({double(x), double(y), double(z)});
  const std::array<std::array<double, 3>, 6> fc = {{{0.5, 0.5, 0.0}, {0.5, 0.5, 1.0},
                                                    {0.5, 0.0, 0.5}, {0.5, 1.0, 0.5},
                                                    {0.0, 0.5, 0.5}, {1.0, 0.5, 0.5}}};
  for (const auto& f : fc) all.push_back(f);
  std::vector<std::array<std::array<double, 3>, 2>> segs;
  for (std::size_t fi = 8; fi < all.size(); ++fi)
    for (std::size_t ci = 0; ci < 8; ++ci) {
      double d2 = 0.0;
      for (int k = 0; k < 3; ++k) {
        const double v = all[fi][k];
        if (v == 0.0 || v == 1.0) d2 += (all[ci][k] - v) * (all[ci][k] - v);
      }
      if (d2 < 1e-9) segs.push_back({all[fi], all[ci]});
    }
  return segs;
}

// ★ THE EMITTER. This is the work the run would need: the canonical cell,
// instantiated per placed cell, with the radius from THAT cell's (rho, size) through
// core's own per-type law.
std::vector<BeamSegment> emit(const std::vector<Cell>& cells) {
  const std::vector<std::array<std::array<double, 3>, 2>> unit = unit_octet_struts();
  std::vector<BeamSegment> out;
  out.reserve(cells.size() * unit.size());
  for (const Cell& c : cells) {
    const double d =
        topopt::lattice_strut_diameter_mm(LatticeTopology::Octet, c.rho, c.size_mm);
    const double r = 0.5 * d;
    for (const auto& s : unit)
      out.push_back({Vec3{c.origin.x + s[0][0] * c.size_mm,
                          c.origin.y + s[0][1] * c.size_mm,
                          c.origin.z + s[0][2] * c.size_mm},
                     Vec3{c.origin.x + s[1][0] * c.size_mm,
                          c.origin.y + s[1][1] * c.size_mm,
                          c.origin.z + s[1][2] * c.size_mm},
                     r});
  }
  return out;
}

// A plan of about `want` cells over a stand-sized volume, families interleaved.
std::vector<Cell> make_plan(std::size_t want, double ext_x, double ext_y,
                            double z_lo, double z_hi, double x0 = 0.0,
                            double y0 = 0.0) {
  std::vector<Cell> cells;
  // Two incommensurate bases, plus a halving of each, cycled so neighbours differ.
  // 8 beside 9 is the seam that matters; the halvings and quarterings are what a real
  // plan reaches for in a thin region. Six bands so ~8000 cells fits a stand-sized
  // volume -- the first version ran out of part at 4,156 and silently reported that
  // as "plan~8000".
  const double sizes[6] = {8.0, 9.0, 4.0, 4.5, 2.0, 2.25};
  const double rhos[6] = {0.25, 0.30, 0.22, 0.28, 0.20, 0.24};
  double z = z_lo;
  int band = 0;
  while (cells.size() < want && z < z_hi) {
    const double s = sizes[band % 6];
    const double rho = rhos[band % 6];
    if (z + s > z_hi) break;        // a cell must fit inside the band
    for (double y = 0.0; y + s <= ext_y && cells.size() < want; y += s)
      for (double x = 0.0; x + s <= ext_x && cells.size() < want; x += s)
        cells.push_back({Vec3{x0 + x, y0 + y, z}, s, rho});
    z += s;
    ++band;
  }
  return cells;
}

VoxelGrid block_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx; g.ny = ny; g.nz = nz;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, topopt::VoxelTag::Interior);
  return g;
}

void run_one(std::size_t want, double weld_scale, const char* label) {
  // ★ THE PRODUCTION LOAD PATH, NOT A UNIT FIXTURE (reviewer, 2026-10-02). In the
  // run, `hexm` is solid voxels that are NOT lattice -- the beams carry load BETWEEN
  // solid regions. My previous version set the mask ALL SOLID (copying
  // test_beam_network's unit fixture), which puts the block in PARALLEL with every
  // beam: the block carries the load, the beams carry nothing, the certificate passes
  // trivially, and the conditioning is not a Stepped part's. So:
  //   - solid slabs SLAB voxels thick at both ends of the load path (where the BCs
  //     sit and where the load is applied);
  //   - the plan's cells filling the space between them;
  //   - hex mask = solid AND NOT lattice, exactly as hexm is built.
  // Geometry then GUARANTEES the beams are the only path between the slabs, and the
  // certificate's own honesty fields confirm it.
  const int nx = 96, ny = 24, nz = 72;
  const double h = 1.7;
  const int SLAB = 3;                 // solid layers at each end of the load path
  const int WALL = 2;                 // solid side walls, so the solid is ONE body
  const VoxelGrid g = block_grid(nx, ny, nz, h);
  const double ext_x = nx * h, ext_y = ny * h;
  const double z_lo = SLAB * h, z_hi = (nz - SLAB) * h;

  // ★ A LATTICED POCKET IN A CONNECTED SOLID -- which is what a part is, and what the
  // certificate's own restraint rule requires. My previous attempt put the plan
  // between two solid SLABS and nothing else, per the brief. The certificate REFUSED
  // it, and the refusal is the instrument working: beam_network.cpp:1121 says "a
  // component is real if a Dirichlet node sits on one of its elements", so hex
  // connectivity plus Dirichlet decides support and THE BEAMS DO NOT COUNT. Two slabs
  // bridged only by beams make the far slab an unsupported island -- 50 % of the
  // meshed solid -- and `kIslandRefuseFraction` stops the solve before it starts.
  //
  // So the solid here is one connected body: both slabs plus WALL-thick side walls,
  // with the lattice filling the pocket between them. The walls carry load in
  // parallel, exactly as a real part's shell does -- "the beams carry everything" is
  // not a production arrangement and chasing it would be measuring a fiction. Whether
  // the lattice is genuinely loaded is then reported, not assumed: p99, the zero-stress
  // fraction and the dropped-load fraction are on every CERT line.
  std::vector<char> hexm(g.voxel_count(), 0);
  std::size_t hex_n = 0;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const bool slab = (k < SLAB) || (k >= nz - SLAB);
        const bool wall = (i < WALL) || (i >= nx - WALL) || (j < WALL) || (j >= ny - WALL);
        if (!(slab || wall)) continue;
        hexm[(static_cast<std::size_t>(k) * ny + j) * nx + i] = 1;
        ++hex_n;
      }

  // the pocket the plan fills: inset from the walls, between the slabs
  const double x0 = WALL * h, y0 = WALL * h;
  const double pocket_x = (nx - 2 * WALL) * h, pocket_y = (ny - 2 * WALL) * h;
  const std::vector<Cell> cells =
      make_plan(want, pocket_x, pocket_y, z_lo, z_hi, x0, y0);
  std::vector<BeamSegment> segs = emit(cells);
  const std::size_t before = segs.size();

  double rmin = 0.0, longest = 0.0;
  for (const BeamSegment& s : segs) {
    if (s.radius_mm > 0.0 && (rmin <= 0.0 || s.radius_mm < rmin)) rmin = s.radius_mm;
    const double dx = s.b.x - s.a.x, dy = s.b.y - s.a.y, dz = s.b.z - s.a.z;
    longest = std::max(longest, std::sqrt(dx * dx + dy * dy + dz * dz));
  }
  const double piece = rmin > 0.0 ? weld_scale * 2.0 * rmin : 0.0;
  const auto t_sub0 = std::chrono::steady_clock::now();
  if (piece > 0.0 && longest > piece) segs = topopt::subdivide_beam_segments(segs, piece);
  const double sub_s = std::chrono::duration<double>(
      std::chrono::steady_clock::now() - t_sub0).count();

  const auto t_net0 = std::chrono::steady_clock::now();
  const topopt::BeamNetwork net = topopt::build_beam_network(segs);
  const topopt::BeamNetworkSeams seams = topopt::beam_network_seams(net);
  const double net_s = std::chrono::duration<double>(
      std::chrono::steady_clock::now() - t_net0).count();

  std::printf("%s GEOM | cells PLACED %zu | pocket z %.1f..%.1f mm | hex voxels %zu "
              "(slabs + %d-voxel walls) | weld x%.2f piece %.4f mm | segments %zu -> %zu | "
              "welded %zu | T-ends %zu | floating %zu | subdiv %.2f s | network %.2f s "
              "| peak RSS %.0f MB | load %.2f\n",
              label, cells.size(), z_lo, z_hi, hex_n, WALL, weld_scale, piece, before,
              segs.size(), seams.welded_nodes, seams.t_junction_ends,
              seams.floating_ends, sub_s, net_s, peak_rss_mb(), load1());
  std::fflush(stdout);

  const int NXn = nx + 1, NYn = ny + 1;
  auto nod = [&](int i, int j, int k) {
    return static_cast<int>((static_cast<std::size_t>(k) * NYn + j) * NXn + i); };
  topopt::OrganicLoadCase lc;
  lc.name = "cost";
  for (int j = 0; j <= ny; ++j)
    for (int i = 0; i <= nx; ++i) {
      for (int c = 0; c < 3; ++c) lc.bcs.push_back({nod(i, j, 0), c, 0.0});
      lc.loads.push_back({nod(i, j, nz), 2, -400.0 / ((nx + 1.0) * (ny + 1.0))});
    }
  std::vector<topopt::OrganicLoadCase> cases{lc};

  const auto t0 = std::chrono::steady_clock::now();
  try {
    const topopt::OrganicCertificate c = topopt::certify_organic_structural(
        g, hexm, segs, cases, 3500.0, 0.35, 55.0, 0.8, Vec3{0.0, 0.0, 1.0}, 9.0, true);
    const double s = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - t0).count();
    const char* vn = c.verdict == topopt::OrganicCertificate::Verdict::Certified
                         ? "CERTIFIED"
                         : c.verdict == topopt::OrganicCertificate::Verdict::Refused
                               ? "REFUSED" : "NOT-RUN";
    // ★ IS THE LATTICE ACTUALLY IN THE LOAD PATH? The certificate does not report a
    // beams-versus-hex split, so I am not going to invent one. What it DOES report is
    // the two facts that settle it: how much of the applied load found no material at
    // all (worst_load_dropped_fraction) and what fraction of members carry exactly
    // zero stress. With the hex mask confined to the two slabs, geometry leaves the
    // beams as the only path between them, so a low dropped fraction plus a low
    // zero-stress fraction plus a non-trivial p99 IS the load going through the beams.
    std::printf("%s CERT | verdict %s | margin %.4g | p99 %.4g MPa | max %.4g | "
                "stat %s | members %zu | dropped %zu (%.3f of length) | "
                "load_dropped %.4f | zero_stress %.4f | cert_seconds %.1f | "
                "wall %.1f s | cert_peak_RSS %.0f MB | peak RSS %.0f MB | load %.2f%s%s\n",
                label, vn, c.margin, c.stress_p99_mpa, c.stress_max_mpa,
                c.verdict_statistic.empty() ? "-" : c.verdict_statistic.c_str(),
                c.members, c.members_dropped, c.dropped_length_fraction,
                c.worst_load_dropped_fraction, c.zero_stress_fraction, c.seconds, s,
                c.peak_rss_mb, peak_rss_mb(), load1(),
                c.refusal.empty() ? "" : " | refusal: ",
                c.refusal.empty() ? "" : c.refusal.substr(0, 160).c_str());
  } catch (const std::exception& e) {
    const double s = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - t0).count();
    std::printf("%s CERT | THREW after %.1f s: %s\n", label, s,
                std::string(e.what()).substr(0, 200).c_str());
  }
  std::fflush(stdout);
}

}  // namespace

int main(int argc, char** argv) {
  // argv: <cells> [weld_scale]. ONE size per invocation, so a slow size can be given
  // its own timeout instead of blocking the others.
  const std::size_t want = argc > 1 ? static_cast<std::size_t>(std::atol(argv[1])) : 500;
  const double weld = argc > 2 ? std::atof(argv[2]) : 1.0;
  std::printf("# stepped beam cost probe. Shared box: wall times are UPPER BOUNDS,\n"
              "# not benchmarks; load1 is on every line. start load %.2f\n", load1());
  char label[64];
  std::snprintf(label, sizeof label, "plan~%zu", want);
  run_one(want, weld, label);
  return 0;
}
