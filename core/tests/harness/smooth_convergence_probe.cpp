// smooth_convergence_probe — task 2026-08-19-peak-stress-convergence.
//
//   cmake --build core/build --target smooth_convergence_probe
//   ./core/build/smooth_convergence_probe <job_dir> <alpha_stem> <resolution> \
//        <csv_out> [--mode replicate|retag] [--refine F]
//        [--arm frac|stair_fine|stair_base] [--samples K] [--hard]
//
// ── THE QUESTION ────────────────────────────────────────────────────────────
//
// PR 320 (`boundary_cell_probe`, task 2026-08-08-how-wrong-is-the-boundary-cell)
// measured that the certificate's peak von Mises DOES NOT CONVERGE under mesh
// refinement: sigma_peak ~ h^-q with q = 0.4945 then 0.4391, against 0.4555 for
// the 2-D re-entrant 90-degree corner. Its diagnosis was that a VOXEL STAIRCASE
// IS MADE OF RE-ENTRANT CORNERS, and a corner singularity has no finite peak.
//
// ★ THAT MEASUREMENT REFINED A STORED DENSITY FIELD BY REPLICATION. Replicating
// a binary field 2x reproduces the SAME staircase with smaller elements, so the
// corners survive every refinement by construction. The parametric level set now
// ships an ANALYTIC phi beside every variant (`<prefix>_<vf>_alpha.f64` +
// `.meta`, run_job.cpp:401), and the production ersatz is the EXACT VOLUME
// FRACTION of each cell inside {phi < 0} (PlsmErsatz::VolumeFraction, the
// default at plsm.hpp:142). So the boundary the certificate reads is no longer
// a staircase — and nobody has re-run the convergence measurement since.
//
// ── HOW THE GEOMETRY IS HELD FIXED, WHICH IS THE WHOLE BAR ──────────────────
//
// THE DESIGN IS `alpha`, NOT A VOXEL FIELD. phi(x) = sum_i alpha_i psi(|x-x_i|_R)
// is a function of position, defined everywhere, with no lattice of its own once
// the knots are placed. This probe reads ONE alpha file and re-EVALUATES that
// same function on each certification grid. Nothing is up- or down-sampled, no
// density field is interpolated, and no optimisation is re-run: every rung is
// the same analytic surface, read at a different element size.
//
// The knots live in the VOXEL COORDINATES OF THE GRID THE DESIGN WAS OPTIMISED
// ON (`plsm_support_of` takes x,y,z in that frame). A point P in model space maps
// to that frame by
//
//     u = (P - origin0) / spacing0 - 0.5
//
// because voxel (i,j,k) of the original grid is centred at origin0 + (i+0.5)h0.
// `voxelize` puts the origin at the model bbox min and the spacing at
// longest_extent/resolution, so EVERY resolution of the same model shares an
// origin; the probe asserts that bit-for-bit rather than assuming it, because if
// the two frames differed the sweep would be measuring a moving object.
//
// ── ★★ TWO MODES, AND ONLY ONE OF THEM CAN ANSWER THE QUESTION ─────────────
//
//   --mode replicate  (THE REFERENCE, and PR 320's own.) The load case is built
//     ONCE, at `<resolution>`, and the grid is then subdivided `--refine F` times
//     child-for-child: the tags, the mask, the anchor pad, the load pad and the
//     face protection are all THE SAME PHYSICAL SOLIDS at every rung, refined.
//     The Dirichlet set is rebuilt by the production rule (clamp all 8 corner
//     nodes of every Fixture voxel, loadcase.cpp) and the traction by the
//     production call (`traction_loads` over the Load region's exposed faces), so
//     the clamped volume, the loaded surface and its resultant are geometrically
//     identical across rungs. ONLY THE ELEMENT SIZE CHANGES. It needs exactly one
//     live load group, for the reason `boundary_cell_probe` states, and refuses
//     rather than approximating.
//
//   --mode retag      `build_production_loadcase` run outright at `<resolution>`
//     — what the job would say if it were RUN at that resolution. This prices
//     something real and DIFFERENT, and it CANNOT measure convergence: ★ the
//     anchor pad's depth is specified in VOXELS, so the pad is 10.2 mm thick at
//     resolution 64 and 2.6 mm at 192 and the certified object is a different
//     solid at every rung. Reported, never mixed with the reference.
//
// ── THE THREE ARMS ──────────────────────────────────────────────────────────
//
//   --arm frac        THE PRODUCTION READING. rho_e = rho_min + (1-rho_min) f_v,
//     f_v the exact volume fraction of the cell inside {phi < 0}, by k^3 sub-cell
//     samples at x = i + (p+0.5)/k - 0.5, mollified by the quadrature band at
//     eps_q = eps_mult * |grad phi| * h/k. That is `build_fields` + `frac_at`
//     (plsm.cpp:496-526) transcribed onto an arbitrary grid: same sample lattice,
//     same `plsm_frac_soft_step`, same `plsm_frac_eps`, same mask stamping.
//
//   --arm stair_fine  The SAME phi read as a hard 0/1 occupancy at the cell
//     centre of the SOLVE grid. A voxel staircase of the identical analytic
//     surface, whose steps shrink with h.
//
//   --arm stair_base  ★★ THE NEGATIVE CONTROL, AND IT IS PR 320's CONSTRUCTION
//     EXACTLY. The hard 0/1 occupancy is taken at the centres of the BASE grid
//     and then REPLICATED child-for-child onto the solve grid — so the staircase
//     is FROZEN at the base resolution and only the elements resolving it get
//     smaller, which is precisely what PR 320 did to a stored `design.bin`. Its
//     corners survive every refinement by construction, so it must reproduce
//     PR 320's q ~ 0.45. If it does NOT, this sweep is not measuring what PR 320
//     measured and the comparison between them is void. Only meaningful under
//     `--mode replicate`; refused under `retag`, where there is no base grid the
//     solve grid subdivides.
//
// All three arms stamp the frozen set identically (FrozenSolid -> 1, FrozenVoid
// and Empty -> 0, plsm.cpp:511-517), and all three classify their cells from the
// SAME sub-cell census of phi, so the only thing that differs between them is
// the density of the ACTIVE cells. That is what makes them an A/B/C.
//
// ── ★★ THE PEAK IS SPLIT BY WHO OWNS THE CELL, AND THAT IS THE POINT ───────
//
// The certified object is NOT the level set alone. It is {phi < 0} UNION the
// FROZEN set the mask stamps solid — the anchor pad, the load pad and the face
// protection (`effective_design_mask`, and loadcase.cpp's pad builder). Those are
// specified in VOXELS, so they are a DIFFERENT physical solid at every
// resolution, and their boundary is a CAD-tagged staircase that the level set
// never touched. A global peak that lands there is not a reading of the smooth
// boundary at all.
//
// So the peak is reported over four populations, every one of them printed:
//
//   ALL          what the gate reads, and what a margin is computed from
//   ACTIVE       cells the level set actually controls (mask == Active)
//   CUT          ★ THE SMOOTH BOUNDARY. Cells the analytic interface passes
//                through — mixed sub-cell sample signs. Their union is a
//                shrinking neighbourhood of the SAME analytic surface at every
//                resolution, which is the only population in this sweep that is
//                geometrically the same object as h falls.
//   FROZEN       cells the mask stamped solid
//
// ★★ AND CUT IS GATED BY DISTANCE, BECAUSE THE FROZEN SET SHRINKS WITH h. The
// anchor pad is `depth` VOXELS deep, so it is 10.2 mm thick at resolution 64 and
// 2.6 mm at 192: as h falls the pad retreats and the ACTIVE region GROWS into
// ground the level set did not previously own — ground right beside the load
// introduction, where the stress is highest. A CUT peak taken over the whole
// active set therefore rises with refinement for a reason that has nothing to do
// with the interface.
//
// So the CUT and ACTIVE peaks are ALSO reported at 5, 10 and 20 mm from
//
//     S = {Load tag} u {Fixture tag} u {FrozenSolid mask}
//
// by a chamfer distance in mm.
//
// ★★ AND THE DISTANCE FIELD IS COMPUTED ON THE **BASE** GRID AND REPLICATED,
// NOT recomputed on each solve grid. A chamfer computed per grid is quantised to
// that grid's own h, so the band EDGE moves by O(h) between rungs — and where the
// stress gradient across that edge is steep, the gated peak inherits the movement
// and reports a spurious exponent. (It did: an earlier pass, kept in
// `raw/pre_stable_gate/`, put the 10 mm gate at q = +1.48 while the 5 mm and
// 20 mm gates either side of it were flat — the band edge, not the physics.)
// Anchoring the field to the base grid makes the gate the SAME PHYSICAL REGION at
// every rung, to the base grid's own voxel, which is the only way the population
// is comparable. Under `--mode retag` there is no base grid to anchor to and the
// distance is necessarily this grid's own; the CSV records which.
//
// ★ THE CUT SET IS CLASSIFIED THE SAME WAY IN BOTH ARMS. The sub-cell census is
// computed from phi whatever the arm, and only the DENSITY differs between them,
// so `smooth` and `staircase` report their peaks over the SAME cells and the A/B
// changes exactly one thing.
//
// ── R1: THE INVARIANT THAT PROVES THE GEOMETRY DID NOT MOVE ─────────────────
//
// Two, printed on every row:
//   * the alpha file's own SHA-256 — the design is those bytes, and all rungs
//     read one file (checked outside, in the runner script);
//   * ★ `vol_phi_mm3` — the volume of {phi < 0} inside the part, sum_v f_v h^3
//     over EVERY non-Empty cell with the mask IGNORED. That is a pure property of
//     the analytic design and the part occupancy, it is what the exact fraction
//     integrates to O(1/k) per cut cell, and it is the number that must not drift.
//     The mask-stamped volume is reported beside it and is EXPECTED to drift,
//     because the pads are voxel-specified.
//
// A HARNESS, not a test: it prints a table and appends a CSV row, and asserts
// only the preconditions that would make its own numbers meaningless.

#include "topopt/analyze.hpp"
#include "topopt/design_store.hpp"
#include "topopt/fea.hpp"
#include "topopt/job.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/plsm.hpp"
#include "topopt/plsm_basis.hpp"
#include "topopt/plsm_frac.hpp"
#include "topopt/plsm_kernel.hpp"
#include "topopt/production.hpp"
#include "topopt/report.hpp"
#include "topopt/simp.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <limits>
#include <map>
#include <sstream>
#include <string>
#include <vector>

using namespace topopt;

namespace {

std::string join(const std::string& a, const std::string& b) {
  if (a.empty()) return b;
  return a.back() == '/' ? a + b : a + "/" + b;
}

double now_s() {
  return std::chrono::duration<double>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// `key value...` lines; '#' comments ignored. The format run_job.cpp:425 writes.
std::map<std::string, std::string> read_meta(const std::string& path) {
  std::map<std::string, std::string> m;
  std::ifstream f(path);
  if (!f) return m;
  std::string line;
  while (std::getline(f, line)) {
    if (line.empty() || line[0] == '#') continue;
    std::istringstream is(line);
    std::string k;
    if (!(is >> k)) continue;
    std::string rest;
    std::getline(is, rest);
    while (!rest.empty() && rest.front() == ' ') rest.erase(rest.begin());
    m[k] = rest;
  }
  return m;
}

double meta_num(const std::map<std::string, std::string>& m, const char* k,
                int which = 0) {
  const auto it = m.find(k);
  if (it == m.end()) {
    std::fprintf(stderr, "PRECONDITION FAILED: alpha .meta has no key \"%s\"\n", k);
    std::exit(1);
  }
  std::istringstream is(it->second);
  double v = 0.0;
  for (int i = 0; i <= which; ++i)
    if (!(is >> v)) {
      std::fprintf(stderr,
                   "PRECONDITION FAILED: alpha .meta key \"%s\" has fewer than "
                   "%d numbers\n",
                   k, which + 1);
      std::exit(1);
    }
  return v;
}

// The BOUNDARY of the printed set: a printed voxel with at least one FACE
// neighbour not printed, off-grid reading void. PR 320's rule, verbatim, so the
// two probes' boundary/interior splits mean the same thing.
std::vector<char> boundary_mask(const VoxelGrid& g,
                                const std::vector<double>& rho, double iso) {
  const std::size_t n = g.voxel_count();
  std::vector<char> printed(n, 0), bdry(n, 0);
  for (std::size_t e = 0; e < n; ++e) printed[e] = rho[e] > iso ? 1 : 0;
  const int d[6][3] = {{-1, 0, 0}, {1, 0, 0}, {0, -1, 0},
                       {0, 1, 0},  {0, 0, -1}, {0, 0, 1}};
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const std::size_t e = g.index(i, j, k);
        if (!printed[e]) continue;
        for (const auto& v : d) {
          const int a = i + v[0], b = j + v[1], c = k + v[2];
          if (a < 0 || a >= g.nx || b < 0 || b >= g.ny || c < 0 || c >= g.nz) {
            bdry[e] = 1;
            break;
          }
          if (!printed[g.index(a, b, c)]) {
            bdry[e] = 1;
            break;
          }
        }
      }
  return bdry;
}

// A chamfer distance in MILLIMETRES to the nearest seed voxel, two passes with
// the standard (1, sqrt2, sqrt3) 3-D weights in voxel units. Not exact Euclidean
// — it is a GATE, and its error is a few percent of the radius, which is far
// inside the 5 mm granularity it is read at.
std::vector<double> chamfer_mm(const VoxelGrid& g, const std::vector<char>& seed) {
  const double kInf = 1e30;
  const std::size_t n = g.voxel_count();
  std::vector<double> d(n, kInf);
  for (std::size_t v = 0; v < n; ++v) if (seed[v]) d[v] = 0.0;
  const double w1 = 1.0, w2 = std::sqrt(2.0), w3 = std::sqrt(3.0);
  auto relax = [&](int i, int j, int k, int di, int dj, int dk, double w) {
    const int a = i + di, b = j + dj, c = k + dk;
    if (a < 0 || a >= g.nx || b < 0 || b >= g.ny || c < 0 || c >= g.nz) return;
    const double cand = d[g.index(a, b, c)] + w;
    if (cand < d[g.index(i, j, k)]) d[g.index(i, j, k)] = cand;
  };
  auto sweep = [&](bool forward) {
    for (int kk = 0; kk < g.nz; ++kk) {
      const int k = forward ? kk : g.nz - 1 - kk;
      for (int jj = 0; jj < g.ny; ++jj) {
        const int j = forward ? jj : g.ny - 1 - jj;
        for (int ii = 0; ii < g.nx; ++ii) {
          const int i = forward ? ii : g.nx - 1 - ii;
          const int s3 = forward ? -1 : 1;
          for (int dk = 0; dk <= 1; ++dk)
            for (int dj = -1; dj <= 1; ++dj)
              for (int di = -1; di <= 1; ++di) {
                if (dk == 0 && (dj > 0 || (dj == 0 && di >= 0))) continue;
                const int m = std::abs(di) + std::abs(dj) + std::abs(dk);
                if (m == 0) continue;
                relax(i, j, k, s3 * di, s3 * dj, s3 * dk,
                      m == 1 ? w1 : (m == 2 ? w2 : w3));
              }
        }
      }
    }
  };
  sweep(true);
  sweep(false);
  for (std::size_t v = 0; v < n; ++v)
    if (d[v] < kInf) d[v] *= g.spacing;
  return d;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 5) {
    std::fprintf(stderr,
                 "usage: %s <job_dir> <alpha_stem> <resolution> <csv_out> "
                 "[--arm smooth|staircase] [--samples K] [--hard]\n",
                 argv[0]);
    return 2;
  }
  const std::string job_dir = argv[1];
  const std::string alpha_stem = argv[2];   // ...variant_068_alpha  (no suffix)
  const int resolution = std::atoi(argv[3]);
  const std::string csv_out = argv[4];
  std::string arm = "frac";
  std::string mode = "replicate";
  int refine = 1;
  int fk = 4;                 // PlsmOptions::frac_samples, the production value
  bool mollified = true;      // PlsmOptions::frac_mollified, the production value
  const double eps_mult = 1.0;  // PlsmOptions::frac_eps_mult, the derived value
  for (int i = 5; i < argc; ++i) {
    if (std::strcmp(argv[i], "--arm") == 0 && i + 1 < argc) arm = argv[++i];
    else if (std::strcmp(argv[i], "--mode") == 0 && i + 1 < argc) mode = argv[++i];
    else if (std::strcmp(argv[i], "--refine") == 0 && i + 1 < argc)
      refine = std::atoi(argv[++i]);
    else if (std::strcmp(argv[i], "--samples") == 0 && i + 1 < argc)
      fk = std::atoi(argv[++i]);
    else if (std::strcmp(argv[i], "--hard") == 0) mollified = false;
    else {
      std::fprintf(stderr, "PRECONDITION FAILED: unknown argument \"%s\"\n",
                   argv[i]);
      return 1;
    }
  }
  if (arm != "frac" && arm != "stair_fine" && arm != "stair_base") {
    std::fprintf(stderr,
                 "PRECONDITION FAILED: --arm must be frac|stair_fine|stair_base\n");
    return 1;
  }
  if (mode != "replicate" && mode != "retag") {
    std::fprintf(stderr, "PRECONDITION FAILED: --mode must be replicate|retag\n");
    return 1;
  }
  if (refine < 1) {
    std::fprintf(stderr, "PRECONDITION FAILED: --refine must be >= 1\n");
    return 1;
  }
  if (mode == "retag" && refine != 1) {
    std::fprintf(stderr,
                 "PRECONDITION FAILED: --refine belongs to replicate mode; under "
                 "retag the resolution IS the argument.\n");
    return 1;
  }
  if (arm == "stair_base" && mode != "replicate") {
    std::fprintf(stderr,
                 "PRECONDITION FAILED: --arm stair_base freezes the staircase at "
                 "the BASE grid and replicates it, which only exists under --mode "
                 "replicate. Refusing rather than silently becoming stair_fine.\n");
    return 1;
  }
  if (fk < 2 || fk > 16) {
    std::fprintf(stderr,
                 "PRECONDITION FAILED: --samples is the SUB-CELL sampling per "
                 "axis and must be in [2,16] (plsm.cpp:240); 1 would put the "
                 "only sample back at the cell centre, which is the "
                 "approximation the fraction replaces — and is what --arm "
                 "staircase measures deliberately.\n");
    return 1;
  }
  if (resolution < 8) {
    std::fprintf(stderr, "PRECONDITION FAILED: resolution must be >= 8\n");
    return 1;
  }

  // ── the job, the model, the load case: all through the shipped path.
  const JobDescription job = load_job_file(join(job_dir, "job.json"));
  StepModel model;
  try {
    model = import_step_file(join(job_dir, job.model));
  } catch (const std::exception& e) {
    std::fprintf(stderr, "PRECONDITION FAILED: cannot import model: %s\n", e.what());
    return 1;
  }
  if (!job.loads.present) {
    std::fprintf(stderr,
                 "PRECONDITION FAILED: this probe measures a DECLARED load "
                 "case; this job has none\n");
    return 1;
  }
  MaterialLibrary lib = load_materials_file(MATERIALS_JSON_PATH);
  const auto mit = lib.find(job.material);
  if (mit == lib.end()) {
    std::fprintf(stderr, "PRECONDITION FAILED: material \"%s\" not in catalog\n",
                 job.material.c_str());
    return 1;
  }
  const Material material = mit->second;

  const ProductionLoadCase lc = production_loadcase_from_job(job, model);
  const ProductionRunSetup setup = build_production_loadcase(model, resolution, lc);
  if (setup.options.require_external_loads && setup.options.external_loads.empty()) {
    std::fprintf(stderr,
                 "PRECONDITION FAILED: the declared load case produced NO "
                 "external load at resolution %d\n",
                 resolution);
    return 1;
  }
  MinimizePlasticOptions options = setup.options;
  const SolvedDesignDomain domain =
      resolve_design_domain(setup.grid, setup.bcs, options);
  if (domain.expanded) {
    std::fprintf(stderr,
                 "PRECONDITION FAILED: this job expands the design domain (a "
                 "design box). Refusing rather than mapping a frame it has not "
                 "proven.\n");
    return 1;
  }
  const VoxelGrid base_grid = domain.grid;
  VoxelGrid cert_grid = base_grid;
  std::vector<DirichletBC> bcs = domain.bcs;
  std::vector<NodalLoad> loads =
      design_domain_loads(domain, options, material.density_g_cm3);
  // ★ THE SAME MASK THE RUN HOLDS FROZEN, through the same two functions the
  // production plsm path calls (plsm.cpp:258).
  const DesignMask base_eff =
      effective_design_mask(base_grid, design_domain_mask(domain, options));
  DesignMask eff = base_eff;

  // ── ★ REPLICATE: subdivide the run's own grid child-for-child, then rebuild the
  // BCs and the traction by the production rules. Verbatim from
  // `boundary_cell_probe` (task 2026-08-08), which is why the two probes'
  // reference modes are the same construction and their exponents comparable.
  //
  // ★ NO `refine > 1` GUARD, DELIBERATELY. At refine == 1 the subdivision is the
  // identity, so the whole construction — tag copy, mask copy, BC rebuild,
  // traction rebuild — runs on the base grid and must land on what `retag` at the
  // same resolution says. That is the positive control for the machinery, and
  // skipping it at refine 1 would leave it untested at the one resolution where
  // the right answer is already known.
  if (mode == "replicate") {
    int live_groups = 0;
    Vec3 gforce{0.0, 0.0, 0.0};
    for (const auto& lg : lc.load_groups)
      if (std::fabs(lg.force.x) + std::fabs(lg.force.y) + std::fabs(lg.force.z) >
          0.0) {
        ++live_groups;
        gforce = lg.force;
      }
    if (live_groups != 1) {
      std::fprintf(stderr,
                   "PRECONDITION FAILED: replicate mode needs exactly ONE live "
                   "load group (this job has %d). build_production_loadcase "
                   "builds each group's traction against an ANCHORS-ONLY base "
                   "grid; with one group that base grid carries the same tags as "
                   "the final grid, so subdividing the final grid is exact. With "
                   "more it is not, and this refuses rather than approximating.\n",
                   live_groups);
      return 1;
    }
    VoxelGrid fg;
    fg.nx = base_grid.nx * refine;
    fg.ny = base_grid.ny * refine;
    fg.nz = base_grid.nz * refine;
    fg.spacing = base_grid.spacing / refine;
    fg.origin = base_grid.origin;
    fg.tags.assign(static_cast<std::size_t>(fg.nx) * fg.ny * fg.nz,
                   VoxelTag::Empty);
    DesignMask fe(fg.tags.size(), MaskValue::Active);
    for (int k = 0; k < base_grid.nz; ++k)
      for (int j = 0; j < base_grid.ny; ++j)
        for (int i = 0; i < base_grid.nx; ++i) {
          const VoxelTag t = base_grid.tag(i, j, k);
          const MaskValue m = base_eff[base_grid.index(i, j, k)];
          for (int c = 0; c < refine; ++c)
            for (int b = 0; b < refine; ++b)
              for (int aa = 0; aa < refine; ++aa) {
                const std::size_t e =
                    fg.index(i * refine + aa, j * refine + b, k * refine + c);
                fg.tags[e] = t;
                fe[e] = m;
              }
        }
    cert_grid = fg;
    eff = fe;
    // The production BC rule, verbatim (loadcase.cpp): clamp all 8 corner nodes
    // of every Fixture voxel, deduped.
    bcs.clear();
    for (const int nd : fea_tagged_nodes(cert_grid, VoxelTag::Fixture))
      for (int c = 0; c < 3; ++c) bcs.push_back({nd, c, 0.0});
    // The production traction call, verbatim (loadcase.cpp).
    loads = traction_loads(cert_grid, VoxelTag::Load, gforce);
    options.external_loads = loads;
  }

  // ── THE ANALYTIC DESIGN. One file, read once, evaluated on this grid.
  const std::map<std::string, std::string> meta = read_meta(alpha_stem + ".meta");
  if (meta.empty()) {
    std::fprintf(stderr, "PRECONDITION FAILED: cannot read %s.meta\n",
                 alpha_stem.c_str());
    return 1;
  }
  const std::size_t n_coeff = static_cast<std::size_t>(meta_num(meta, "n_coeff"));
  std::vector<double> alpha(n_coeff, 0.0);
  {
    std::ifstream f(alpha_stem + ".f64", std::ios::binary);
    if (!f) {
      std::fprintf(stderr, "PRECONDITION FAILED: cannot read %s.f64\n",
                   alpha_stem.c_str());
      return 1;
    }
    f.read(reinterpret_cast<char*>(alpha.data()),
           static_cast<std::streamsize>(n_coeff * sizeof(double)));
    if (f.gcount() != static_cast<std::streamsize>(n_coeff * sizeof(double))) {
      std::fprintf(stderr,
                   "PRECONDITION FAILED: %s.f64 holds %lld bytes, the .meta "
                   "says %zu coefficients (%zu bytes)\n",
                   alpha_stem.c_str(), static_cast<long long>(f.gcount()),
                   n_coeff, n_coeff * sizeof(double));
      return 1;
    }
  }
  const auto bit = meta.find("basis");
  const PlsmBasisKind basis = (bit != meta.end() && bit->second == "gaussian")
                                  ? PlsmBasisKind::Gaussian
                                  : PlsmBasisKind::Wendland;
  // The ORIGINAL grid the knots were placed against.
  const int nx0 = static_cast<int>(meta_num(meta, "nx"));
  const int ny0 = static_cast<int>(meta_num(meta, "ny"));
  const int nz0 = static_cast<int>(meta_num(meta, "nz"));
  const double h0 = meta_num(meta, "spacing");
  const Vec3 o0{meta_num(meta, "ox"), meta_num(meta, "oy"), meta_num(meta, "oz")};
  const double kdx = meta_num(meta, "knots_vox", 0);
  const double kdy = meta_num(meta, "knots_vox", 1);
  const double kdz = meta_num(meta, "knots_vox", 2);
  const double srx = meta_num(meta, "support_vox", 0);
  const double sry = meta_num(meta, "support_vox", 1);
  const double srz = meta_num(meta, "support_vox", 2);
  // `plsm_make_lattice` takes ONE support in units of the per-axis knot spacing
  // (rx = support*dx). The .meta writes both, so it is read back rather than
  // assumed — and refused if the three axes disagree, because a single number
  // cannot then reconstruct the lattice.
  const double sup_x = srx / kdx, sup_y = sry / kdy, sup_z = srz / kdz;
  if (std::fabs(sup_x - sup_y) > 1e-12 || std::fabs(sup_x - sup_z) > 1e-12) {
    std::fprintf(stderr,
                 "PRECONDITION FAILED: the support ratio differs per axis "
                 "(%.17g / %.17g / %.17g). plsm_make_lattice takes ONE support; "
                 "this lattice cannot be rebuilt through it.\n",
                 sup_x, sup_y, sup_z);
    return 1;
  }
  const PlsmKnotLattice L = plsm_make_lattice(nx0, ny0, nz0, kdx, kdy, kdz, sup_x);
  // The rebuild must reproduce the .meta's own counts and padding, or the knots
  // are not where the design put them and every phi below is a different function.
  const int mmx = static_cast<int>(meta_num(meta, "counts", 0));
  const int mmy = static_cast<int>(meta_num(meta, "counts", 1));
  const int mmz = static_cast<int>(meta_num(meta, "counts", 2));
  const int ppx = static_cast<int>(meta_num(meta, "pad", 0));
  const int ppy = static_cast<int>(meta_num(meta, "pad", 1));
  const int ppz = static_cast<int>(meta_num(meta, "pad", 2));
  if (L.mx != mmx || L.my != mmy || L.mz != mmz || L.padx != ppx ||
      L.pady != ppy || L.padz != ppz || L.count() != n_coeff) {
    std::fprintf(stderr,
                 "PRECONDITION FAILED: the rebuilt knot lattice does not match "
                 "the .meta.\n  meta   counts %d %d %d pad %d %d %d n_coeff %zu\n"
                 "  rebuilt counts %d %d %d pad %d %d %d count %zu\n",
                 mmx, mmy, mmz, ppx, ppy, ppz, n_coeff, L.mx, L.my, L.mz,
                 L.padx, L.pady, L.padz, L.count());
    return 1;
  }
  // ★★ THE FRAME. Every resolution of one model shares the bbox-min origin;
  // asserted bit-for-bit, because a shifted origin would move the object between
  // rungs and the sweep would measure the shift.
  if (cert_grid.origin.x != o0.x || cert_grid.origin.y != o0.y ||
      cert_grid.origin.z != o0.z) {
    std::fprintf(stderr,
                 "PRECONDITION FAILED: the certification grid's origin "
                 "(%.17g,%.17g,%.17g) is not the design's (%.17g,%.17g,%.17g). "
                 "The two frames differ and phi cannot be re-evaluated.\n",
                 cert_grid.origin.x, cert_grid.origin.y, cert_grid.origin.z,
                 o0.x, o0.y, o0.z);
    return 1;
  }

  // ── the stored variant, for the build direction and the recorded certificate.
  DesignStore store = read_design_file(join(job_dir, "out/design.bin"));
  const double want_vf = meta_num(meta, "requested_vf");
  int rung = -1;
  for (std::size_t v = 0; v < store.variants.size(); ++v)
    if (std::fabs(store.variants[v].requested_volume_fraction - want_vf) < 1e-9)
      rung = static_cast<int>(v);
  if (rung < 0) {
    std::fprintf(stderr,
                 "PRECONDITION FAILED: no stored variant at requested vf %.10g "
                 "(design.bin holds %zu)\n",
                 want_vf, store.variants.size());
    return 1;
  }
  const StoredDesign& sd = store.variants[static_cast<std::size_t>(rung)];

  // ── ★ THE DENSITY. `build_fields` + `frac_at` (plsm.cpp:496-526) on this grid.
  const int nx = cert_grid.nx, ny = cert_grid.ny, nz = cert_grid.nz;
  const int eff_res = resolution * refine;   // the effective longest-axis divisions
  const double h = cert_grid.spacing;
  const std::size_t n = cert_grid.voxel_count();
  const double ratio = h / h0;   // model mm per new voxel, in ORIGINAL voxels
  const int threads = plsm_hw_threads(0);

  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;
  const double rho_min = params.density_min;

  // phi at every CELL CENTRE of THIS grid, in the design's own frame. Used by
  // the staircase arm as its occupancy and by the smooth arm for |grad phi|,
  // which is what the quadrature bandwidth is tied to (plsm_frac_eps).
  std::vector<double> phi(n, 0.0);
  const double t_phi0 = now_s();
  plsm_parallel_for(n, threads, [&](std::size_t v) {
    const int i = static_cast<int>(v % static_cast<std::size_t>(nx));
    const int j = static_cast<int>((v / static_cast<std::size_t>(nx)) %
                                   static_cast<std::size_t>(ny));
    const int k = static_cast<int>(v / (static_cast<std::size_t>(nx) *
                                        static_cast<std::size_t>(ny)));
    std::vector<int> idx;
    std::vector<double> w;
    plsm_support_of(L, basis, (i + 0.5) * ratio - 0.5, (j + 0.5) * ratio - 0.5,
                    (k + 0.5) * ratio - 0.5, idx, w);
    double s = 0.0;
    for (std::size_t m = 0; m < idx.size(); ++m)
      s += alpha[static_cast<std::size_t>(idx[m])] * w[m];
    phi[v] = s;
  });
  // ★ stair_base's OWN field: phi at the BASE grid's cell centres. The staircase
  // is frozen there and replicated down, which is PR 320's construction.
  std::vector<double> phi_base;
  if (arm == "stair_base") {
    const double rb = base_grid.spacing / h0;
    phi_base.assign(base_grid.voxel_count(), 0.0);
    const int bx = base_grid.nx, by = base_grid.ny;
    plsm_parallel_for(phi_base.size(), threads, [&](std::size_t v) {
      const int i = static_cast<int>(v % static_cast<std::size_t>(bx));
      const int j = static_cast<int>((v / static_cast<std::size_t>(bx)) %
                                     static_cast<std::size_t>(by));
      const int k = static_cast<int>(v / (static_cast<std::size_t>(bx) *
                                          static_cast<std::size_t>(by)));
      std::vector<int> idx;
      std::vector<double> w;
      plsm_support_of(L, basis, (i + 0.5) * rb - 0.5, (j + 0.5) * rb - 0.5,
                      (k + 0.5) * rb - 0.5, idx, w);
      double sacc = 0.0;
      for (std::size_t m = 0; m < idx.size(); ++m)
        sacc += alpha[static_cast<std::size_t>(idx[m])] * w[m];
      phi_base[v] = sacc;
    });
  }
  const double phi_wall = now_s() - t_phi0;

  std::vector<double> occ(n, 0.0);
  std::size_t n_active = 0, n_frozen_solid = 0, n_frozen_void = 0;
  std::size_t n_cut = 0, n_full = 0, n_empty_active = 0;
  for (std::size_t v = 0; v < n; ++v) {
    if (cert_grid.tags[v] == VoxelTag::Empty) continue;
    if (eff[v] == MaskValue::FrozenSolid) ++n_frozen_solid;
    else if (eff[v] == MaskValue::FrozenVoid) ++n_frozen_void;
    else ++n_active;
  }
  // ★ THE SUB-CELL PASS RUNS IN BOTH ARMS. `f_all` is the exact volume fraction
  // of every non-Empty cell inside {phi < 0} with the MASK IGNORED, and
  // `incount` is the hard sample count that classifies the cell. The `smooth`
  // arm's density is built from `f_all`; the `staircase` arm's is not — but both
  // arms need the classification, and computing it the same way in both is what
  // makes the two peaks comparable over the SAME cells. -1 = never sampled
  // (Empty only).
  std::vector<int> incount(n, -1);
  std::vector<double> f_all(n, 0.0);
  const double t_occ0 = now_s();
  plsm_parallel_for(n, threads, [&](std::size_t v) {
    if (cert_grid.tags[v] == VoxelTag::Empty) { occ[v] = 0.0; return; }
    const int i = static_cast<int>(v % static_cast<std::size_t>(nx));
    const int j = static_cast<int>((v / static_cast<std::size_t>(nx)) %
                                   static_cast<std::size_t>(ny));
    const int k = static_cast<int>(v / (static_cast<std::size_t>(nx) *
                                        static_cast<std::size_t>(ny)));
    const double eps =
        plsm_frac_eps(plsm_grad_mag(nx, ny, nz, phi, i, j, k, h), h, fk, eps_mult);
    const double inv = 1.0 / static_cast<double>(fk);
    std::vector<int> idx;
    std::vector<double> w;
    double acc = 0.0;
    int in = 0;
    for (int r = 0; r < fk; ++r)
      for (int q = 0; q < fk; ++q)
        for (int p = 0; p < fk; ++p) {
          // The SAME sub-cell lattice plsm_frac_build lays down (plsm_frac.hpp:
          // 317-322), in THIS grid's indices, mapped into the design's frame.
          const double x = (i + (p + 0.5) * inv) * ratio - 0.5;
          const double y = (j + (q + 0.5) * inv) * ratio - 0.5;
          const double z = (k + (r + 0.5) * inv) * ratio - 0.5;
          idx.clear();
          w.clear();
          plsm_support_of(L, basis, x, y, z, idx, w);
          double sp = 0.0;
          for (std::size_t m = 0; m < idx.size(); ++m)
            sp += alpha[static_cast<std::size_t>(idx[m])] * w[m];
          in += sp < 0.0 ? 1 : 0;
          acc += plsm_frac_soft_step(sp, eps);
        }
    const int kk = fk * fk * fk;
    incount[v] = in;
    f_all[v] = mollified ? acc / kk : static_cast<double>(in) / kk;
    // ★ THE DENSITY. `build_fields` (plsm.cpp:509-526) verbatim: the frozen set is
    // STAMPED and the active cells carry the ersatz — except that the `staircase`
    // arm substitutes the cell centre for the fraction, which is the whole
    // control.
    if (eff[v] == MaskValue::FrozenSolid) occ[v] = 1.0;
    else if (eff[v] == MaskValue::FrozenVoid) occ[v] = 0.0;
    else if (arm == "stair_fine") occ[v] = phi[v] < 0.0 ? 1.0 : 0.0;
    else if (arm == "stair_base")
      occ[v] = phi_base[base_grid.index(i / refine, j / refine, k / refine)] < 0.0
                   ? 1.0
                   : 0.0;
    else occ[v] = f_all[v];
  });
  const double occ_wall = now_s() - t_occ0;
  // The cut/full/empty census over the ACTIVE set, read off the counts above.
  {
    const int kk = fk * fk * fk;
    for (std::size_t v = 0; v < n; ++v) {
      if (incount[v] < 0 || eff[v] != MaskValue::Active) continue;
      if (incount[v] == 0) ++n_empty_active;
      else if (incount[v] == kk) ++n_full;
      else ++n_cut;
    }
  }

  std::vector<double> rho(n, 0.0);
  for (std::size_t v = 0; v < n; ++v) rho[v] = rho_min + (1.0 - rho_min) * occ[v];

  // ── ★ R1: THE ENCLOSED VOLUME, the invariant the sweep is held to.
  const double cell_mm3 = h * h * h;
  double vol_active = 0.0, vol_frozen = 0.0, vol_phi = 0.0;
  for (std::size_t v = 0; v < n; ++v) {
    if (cert_grid.tags[v] == VoxelTag::Empty) continue;
    // ★ THE INVARIANT: the analytic design's own volume inside the part, mask
    // ignored. It is a property of alpha and of the part occupancy and of
    // nothing else, so it must not move with h.
    vol_phi += f_all[v] * cell_mm3;
    if (eff[v] == MaskValue::Active) vol_active += occ[v] * cell_mm3;
    else vol_frozen += occ[v] * cell_mm3;
  }

  const double iso = 0.5;
  const bool load_path_ok = load_path_connected(cert_grid, rho, iso);
  std::size_t load_voxels = 0, load_unprinted = 0, fixture_voxels = 0,
              fixture_unprinted = 0;
  for (std::size_t v = 0; v < n; ++v) {
    if (cert_grid.tags[v] == VoxelTag::Load) {
      ++load_voxels;
      if (!(rho[v] > iso)) ++load_unprinted;
    } else if (cert_grid.tags[v] == VoxelTag::Fixture) {
      ++fixture_voxels;
      if (!(rho[v] > iso)) ++fixture_unprinted;
    }
  }
  Vec3 fsum{0.0, 0.0, 0.0};
  for (const NodalLoad& l : loads) {
    if (l.component == 0) fsum.x += l.value;
    if (l.component == 1) fsum.y += l.value;
    if (l.component == 2) fsum.z += l.value;
  }
  const KnockdownSpec knockdown = knockdown_spec_for(options);
  const double part_solid = static_cast<double>(cert_grid.solid_count());

  // ── THE SOLVER POSTURE, pinned exactly as PR 320 pinned it and as
  // ScopedLadderSolverIsolation pins every re-certification.
  const bool prev_recycle = fea_set_krylov_recycling(false);
  const bool prev_geneo = fea_set_geneo_twolevel(false);

  std::printf("== smooth_convergence_probe ==\n");
  std::printf("job        : %s (model %s, material %s)\n", job_dir.c_str(),
              job.model.c_str(), job.material.c_str());
  std::printf("design     : %s  (%zu coefficients, basis %s, requested vf %.10g, "
              "achieved %.10g)\n",
              alpha_stem.c_str(), n_coeff,
              basis == PlsmBasisKind::Gaussian ? "gaussian" : "wendland",
              want_vf, meta_num(meta, "achieved_vf"));
  std::printf("mode       : %s   (refine %dx  ->  effective resolution %d)\n",
              mode.c_str(), refine, eff_res);
  std::printf("arm        : %s   (%s; census always %d^3 sub-cell samples, "
              "eps_mult %.3g)\n",
              arm.c_str(),
              arm == "frac"
                  ? (mollified ? "exact volume fraction, mollified"
                               : "exact volume fraction, hard count")
                  : (arm == "stair_fine"
                         ? "hard 0/1 at the SOLVE grid's cell centre"
                         : "hard 0/1 at the BASE grid's cell centre, REPLICATED"),
              fk, eps_mult);
  std::printf("design grid: %dx%dx%d @ %.17g mm  origin (%.17g,%.17g,%.17g)\n",
              nx0, ny0, nz0, h0, o0.x, o0.y, o0.z);
  std::printf("base  grid : %dx%dx%d @ %.17g mm  (the load case is built here)\n",
              base_grid.nx, base_grid.ny, base_grid.nz, base_grid.spacing);
  std::printf("solve grid : %dx%dx%d @ %.17g mm  (%zu voxels, %d dofs)  "
              "h/h0 = %.17g\n",
              nx, ny, nz, h, n, 3 * fea_node_count(cert_grid), ratio);
  std::printf("mask       : %zu ACTIVE, %zu FrozenSolid, %zu FrozenVoid "
              "(non-Empty %zu of %zu)\n",
              n_active, n_frozen_solid, n_frozen_void,
              n_active + n_frozen_solid + n_frozen_void, n);
  std::printf("fraction   : %zu CUT cells, %zu full, %zu empty (of %zu active) "
              "— the census of phi, identical in every arm\n",
              n_cut, n_full, n_empty_active, n_active);
  std::printf("R1 volume  : ★ {phi<0} in part %.10f mm^3 (mask ignored — THE "
              "INVARIANT)\n"
              "             certified: ACTIVE %.10f + frozen-stamped %.10f = "
              "%.10f mm^3\n",
              vol_phi, vol_active, vol_frozen, vol_active + vol_frozen);
  std::printf("bcs        : %zu dirichlet dofs\n", bcs.size());
  std::printf("loads      : %zu nodal loads, resultant (%.12g, %.12g, %.12g) N\n",
              loads.size(), fsum.x, fsum.y, fsum.z);
  std::printf("load path  : connected=%s   Load voxels %zu (%zu NOT printed)   "
              "Fixture voxels %zu (%zu NOT printed)\n",
              load_path_ok ? "true" : "FALSE", load_voxels, load_unprinted,
              fixture_voxels, fixture_unprinted);
  std::printf("posture    : recycling OFF, geneo OFF, solver=%d, cg_tol=%.3g, "
              "cg_max=%d, margin_stop=%.10g\n",
              static_cast<int>(options.simp.solver), options.simp.cg_tolerance,
              options.simp.cg_max_iterations, options.margin_stop);
  std::printf("field wall : phi %.3f s, occupancy %.3f s\n", phi_wall, occ_wall);
  std::fflush(stdout);

  fea_matvec_count_reset();
  const double t0 = now_s();
  FixedDesignAnalysis a;
  try {
    a = analyze_fixed_design(
        cert_grid, params, rho, bcs, loads, material, sd.applied_build_dir,
        options.simp.cg_tolerance, options.simp.cg_max_iterations,
        options.simp.solver, options.margin_stop, knockdown, load_path_ok,
        part_solid, /*lattice=*/nullptr, /*score_build_orientation=*/false,
        /*build_direction_inferred=*/false,
        /*auto_apply_build_orientation=*/false);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "SOLVE FAILED: %s\n", e.what());
    fea_set_geneo_twolevel(prev_geneo);
    fea_set_krylov_recycling(prev_recycle);
    return 1;
  }
  const double wall = now_s() - t0;
  const long long matvecs = fea_matvec_count();
  fea_set_geneo_twolevel(prev_geneo);
  fea_set_krylov_recycling(prev_recycle);

  if (a.non_convergent) {
    std::printf("\n*** CERTIFICATION SOLVE DID NOT CONVERGE at iteration %d, "
                "residual %.6g. Nothing below is a measurement. ***\n",
                a.non_convergent_iteration, a.non_convergent_residual);
    return 3;
  }

  double compliance = 0.0;
  for (const NodalLoad& l : loads)
    compliance += l.value * a.displacement_field[static_cast<std::size_t>(
                                3 * l.node + l.component)];
  double max_disp = 0.0;
  for (std::size_t v = 0; v + 2 < a.displacement_field.size(); v += 3) {
    const double ux = a.displacement_field[v], uy = a.displacement_field[v + 1],
                 uz = a.displacement_field[v + 2];
    max_disp = std::max(max_disp, std::sqrt(ux * ux + uy * uy + uz * uz));
  }

  // ── ★★ THE FOUR POPULATIONS (see the header). Every one is restricted to the
  // PRINTED set, so a cell the certificate does not weigh cannot enter any of
  // them. `CUT` is the one that is the same analytic object at every resolution.
  const std::vector<char> bdry = boundary_mask(cert_grid, rho, iso);
  const int kk_all = fk * fk * fk;
  // ★ THE GATE'S SEED SET: the CAD-tagged load and anchor faces, plus everything
  // the mask stamped solid. See the header for why the CUT peak is worthless
  // without it.
  //
  // ★ SEEDED AND SOLVED ON THE **BASE** GRID under replicate mode, then read
  // through the parent index, so the band edge does not move between rungs.
  const VoxelGrid& dgrid = (mode == "replicate") ? base_grid : cert_grid;
  const DesignMask& dmask = (mode == "replicate") ? base_eff : eff;
  std::vector<char> seed(dgrid.voxel_count(), 0);
  for (std::size_t v = 0; v < dgrid.voxel_count(); ++v)
    seed[v] = (dgrid.tags[v] == VoxelTag::Load ||
               dgrid.tags[v] == VoxelTag::Fixture ||
               dmask[v] == MaskValue::FrozenSolid)
                  ? 1
                  : 0;
  const std::vector<double> dist_field = chamfer_mm(dgrid, seed);
  auto dist_at = [&](std::size_t v) {
    if (mode != "replicate") return dist_field[v];
    const int i = static_cast<int>(v % static_cast<std::size_t>(nx));
    const int j = static_cast<int>((v / static_cast<std::size_t>(nx)) %
                                   static_cast<std::size_t>(ny));
    const int k = static_cast<int>(v / (static_cast<std::size_t>(nx) *
                                        static_cast<std::size_t>(ny)));
    return dist_field[base_grid.index(i / refine, j / refine, k / refine)];
  };
  static const double kGate[4] = {0.0, 5.0, 10.0, 20.0};
  double pk_b = 0.0, pk_i = 0.0, pk_frz = 0.0;
  std::size_t nb = 0, ni = 0, n_frz_p = 0;
  double pk_act[4] = {0, 0, 0, 0}, pk_cut[4] = {0, 0, 0, 0};
  std::size_t n_act_p[4] = {0, 0, 0, 0}, n_cut_p[4] = {0, 0, 0, 0};
  for (std::size_t v = 0; v < n; ++v) {
    if (!(rho[v] > iso)) continue;
    const double vm = a.von_mises_field[v];
    if (bdry[v]) { pk_b = std::max(pk_b, vm); ++nb; }
    else { pk_i = std::max(pk_i, vm); ++ni; }
    if (eff[v] == MaskValue::Active) {
      const bool is_cut = incount[v] > 0 && incount[v] < kk_all;
      const double dv = dist_at(v);
      for (int q = 0; q < 4; ++q) {
        if (dv < kGate[q]) continue;
        pk_act[q] = std::max(pk_act[q], vm);
        ++n_act_p[q];
        if (is_cut) {
          pk_cut[q] = std::max(pk_cut[q], vm);
          ++n_cut_p[q];
        }
      }
    } else {
      pk_frz = std::max(pk_frz, vm);
      ++n_frz_p;
    }
  }

  std::size_t am = 0;
  for (std::size_t v = 1; v < a.von_mises_field.size(); ++v)
    if (a.von_mises_field[v] > a.von_mises_field[am]) am = v;
  const int pk_k = static_cast<int>(am / (static_cast<std::size_t>(nx) * ny));
  const int pk_j = static_cast<int>((am / static_cast<std::size_t>(nx)) %
                                    static_cast<std::size_t>(ny));
  const int pk_i_idx = static_cast<int>(am % static_cast<std::size_t>(nx));
  const VoxelTag pt = cert_grid.tags[am];
  const char* tagname = pt == VoxelTag::Empty      ? "Empty"
                        : pt == VoxelTag::Interior ? "Interior"
                        : pt == VoxelTag::Surface  ? "Surface"
                        : pt == VoxelTag::Load     ? "Load"
                        : pt == VoxelTag::Fixture  ? "Fixture"
                                                   : "UserTagged";
  const char* peak_mask = eff[am] == MaskValue::Active        ? "Active"
                          : eff[am] == MaskValue::FrozenSolid ? "FrozenSolid"
                                                              : "FrozenVoid";
  const Vec3 pc = cert_grid.voxel_center(pk_i_idx, pk_j, pk_k);
  double d_bc = std::numeric_limits<double>::infinity();
  {
    std::vector<char> clamped(
        static_cast<std::size_t>(fea_node_count(cert_grid)), 0);
    for (const DirichletBC& b : bcs) clamped[static_cast<std::size_t>(b.node)] = 1;
    const int nnx = nx + 1, nny = ny + 1;
    for (std::size_t q = 0; q < clamped.size(); ++q) {
      if (!clamped[q]) continue;
      const int nk = static_cast<int>(q / (static_cast<std::size_t>(nnx) * nny));
      const int nj = static_cast<int>((q / static_cast<std::size_t>(nnx)) %
                                      static_cast<std::size_t>(nny));
      const int ni2 = static_cast<int>(q % static_cast<std::size_t>(nnx));
      const double x = cert_grid.origin.x + ni2 * h;
      const double y = cert_grid.origin.y + nj * h;
      const double z = cert_grid.origin.z + nk * h;
      const double dd = (x - pc.x) * (x - pc.x) + (y - pc.y) * (y - pc.y) +
                        (z - pc.z) * (z - pc.z);
      if (dd < d_bc) d_bc = dd;
    }
    d_bc = std::sqrt(d_bc);
  }

  std::printf("\n-- WHAT THE GATE READS ------------------------------------\n");
  std::printf("  peak von Mises        : %.17g MPa\n", a.max_von_mises);
  std::printf("  max interlayer tension: %.17g MPa\n", a.max_interlayer_tension);
  std::printf("  margin in_plane       : %.17g\n", a.margin.in_plane);
  std::printf("  margin interlayer     : %.17g\n", a.margin.interlayer);
  std::printf("  margin worst_case     : %.17g\n", a.margin.worst_case);
  std::printf("  margin effective      : %.17g\n", a.margin_effective);
  std::printf("  ACCEPTED              : %s   (load_path_ok=%s, margin_effective "
              "%s margin_stop %.10g)\n",
              a.accepted ? "true" : "false", load_path_ok ? "true" : "FALSE",
              a.margin_effective >= options.margin_stop ? ">=" : "<",
              options.margin_stop);
  std::printf("  printed mass          : %.17g g\n", a.mass_grams);
  std::printf("  compliance f.u        : %.17g N.mm\n", compliance);
  std::printf("  peak |displacement|   : %.17g mm\n", max_disp);
  std::printf("  printed voxels        : %zu (fraction %.10g)\n", a.printed_voxels,
              a.printed_fraction);
  std::printf("  recorded (design.bin) : margin %.17g, peak vM %.17g  [at res %d, "
              "H_eta ersatz — NOT this reading]\n",
              sd.margin_worst_case, sd.max_von_mises_mpa, nx0);

  std::printf("\n-- ★ THE PEAK BY WHO OWNS THE CELL (printed cells only) ----\n");
  std::printf("  ALL     (what the gate reads) : %.17g   (%zu cells)\n",
              a.max_von_mises, a.printed_voxels);
  std::printf("  FROZEN  (mask-stamped pads)   : %.17g   (%zu cells)\n", pk_frz,
              n_frz_p);
  std::printf("  gated by distance from {Load tag, Fixture tag, FrozenSolid},\n"
              "  measured on the %s grid so the band edge does not move:\n",
              mode == "replicate" ? "BASE" : "solve");
  std::printf("    %-9s %-30s %-30s\n", "gate mm", "ACTIVE (cells)",
              "CUT — THE SMOOTH BOUNDARY (cells)");
  for (int q = 0; q < 4; ++q)
    std::printf("    %-9.10g %-14.17g (%6zu)  %-14.17g (%6zu)\n", kGate[q],
                pk_act[q], n_act_p[q], pk_cut[q], n_cut_p[q]);

  std::printf("\n-- SURFACE vs INTERIOR (this grid's own classification) ----\n");
  std::printf("  peak vM on BOUNDARY cells : %.17g   (%zu cells)\n", pk_b, nb);
  std::printf("  peak vM on INTERIOR cells : %.17g   (%zu cells)\n", pk_i, ni);

  std::printf("\n-- WHERE THE PEAK SITS ------------------------------------\n");
  std::printf("  voxel (%d,%d,%d) tag=%s mask=%s rho=%.17g occ=%.17g\n", pk_i_idx,
              pk_j, pk_k, tagname, peak_mask, rho[am], occ[am]);
  std::printf("  centre (model frame) : (%.6f, %.6f, %.6f) mm\n", pc.x, pc.y, pc.z);
  std::printf("  distance to nearest clamped node : %.6f mm (%.4f voxels)\n", d_bc,
              d_bc / h);

  std::printf("\n-- COST (R4/R8: measured directly, Release) ----------------\n");
  std::printf("  analyze wall    : %.3f s\n", wall);
  std::printf("  operator applies: %lld\n", matvecs);

  const bool exists = [&] {
    std::ifstream f(csv_out);
    return f.good();
  }();
  std::ofstream csv(csv_out, std::ios::app);
  if (!csv) {
    std::fprintf(stderr, "cannot write %s\n", csv_out.c_str());
    return 1;
  }
  if (!exists)
    csv << "arm,mode,base_resolution,refine,resolution,nx,ny,nz,spacing_mm,"
           "h_over_h0,dofs,samples,mollified,"
           "peak_vm_mpa,max_interlayer_mpa,margin_in_plane,margin_interlayer,"
           "margin_worst_case,margin_effective,accepted,mass_g,compliance,"
           "max_disp_mm,printed_voxels,vol_phi_mm3,vol_active_mm3,"
           "vol_frozen_mm3,vol_total_mm3,n_active,n_frozen_solid,n_frozen_void,"
           "n_cut,n_full,n_empty_active,peak_vm_active,peak_vm_cut,"
           "peak_vm_frozen,active_printed,cut_printed,frozen_printed,"
           "peak_vm_active_g5,peak_vm_cut_g5,active_printed_g5,cut_printed_g5,"
           "peak_vm_active_g10,peak_vm_cut_g10,active_printed_g10,"
           "cut_printed_g10,peak_vm_active_g20,peak_vm_cut_g20,"
           "active_printed_g20,cut_printed_g20,"
           "peak_vm_boundary,peak_vm_interior,boundary_cells,"
           "interior_cells,peak_i,peak_j,peak_k,peak_tag,peak_mask,"
           "peak_dist_to_bc_mm,load_path_ok,load_voxels,load_unprinted,"
           "fixture_voxels,fixture_unprinted,load_resultant_z,bc_dofs,"
           "nodal_loads,wall_s,matvecs,phi_wall_s,occ_wall_s\n";
  csv.setf(std::ios::fmtflags(0), std::ios::floatfield);
  csv.precision(17);
  csv << arm << ',' << mode << ',' << resolution << ',' << refine << ','
      << eff_res << ',' << nx << ',' << ny << ',' << nz << ','
      << h << ',' << ratio << ',' << 3 * fea_node_count(cert_grid) << ','
      << fk << ',' << (mollified && arm == "frac" ? 1 : 0)
      << ',' << a.max_von_mises << ',' << a.max_interlayer_tension << ','
      << a.margin.in_plane << ',' << a.margin.interlayer << ','
      << a.margin.worst_case << ',' << a.margin_effective << ','
      << (a.accepted ? 1 : 0) << ',' << a.mass_grams << ',' << compliance << ','
      << max_disp << ',' << a.printed_voxels << ',' << vol_phi << ','
      << vol_active << ',' << vol_frozen << ',' << (vol_active + vol_frozen)
      << ',' << n_active << ',' << n_frozen_solid << ',' << n_frozen_void << ','
      << n_cut << ',' << n_full << ',' << n_empty_active << ',' << pk_act[0]
      << ',' << pk_cut[0] << ',' << pk_frz << ',' << n_act_p[0] << ','
      << n_cut_p[0] << ',' << n_frz_p << ',' << pk_act[1] << ',' << pk_cut[1]
      << ',' << n_act_p[1] << ',' << n_cut_p[1] << ',' << pk_act[2] << ','
      << pk_cut[2] << ',' << n_act_p[2] << ',' << n_cut_p[2] << ',' << pk_act[3]
      << ',' << pk_cut[3] << ',' << n_act_p[3] << ',' << n_cut_p[3] << ','
      << pk_b << ',' << pk_i << ',' << nb << ','
      << ni << ',' << pk_i_idx << ',' << pk_j << ',' << pk_k << ',' << tagname
      << ',' << peak_mask << ',' << d_bc << ',' << (load_path_ok ? 1 : 0) << ','
      << load_voxels << ',' << load_unprinted << ',' << fixture_voxels << ','
      << fixture_unprinted << ',' << fsum.z << ',' << bcs.size() << ','
      << loads.size() << ',' << wall << ',' << matvecs << ',' << phi_wall << ','
      << occ_wall << '\n';
  csv.close();
  std::printf("\nwrote CSV row -> %s\n", csv_out.c_str());
  return 0;
}
