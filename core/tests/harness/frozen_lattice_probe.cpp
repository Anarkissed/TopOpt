// frozen_lattice_probe.cpp — task 2026-08-13-lattice-as-a-material.
//
// THE INSTRUMENT for the whole task. It answers, on HIS part and nothing else:
//
//   --stage law      M0  the rho->stiffness law: what it is fitted to, how far it
//                        sits from the asymptotic Gibson-Ashby form the optimiser
//                        must never see, and its validity range in CELLS PER
//                        MEMBER.
//   --stage regions  M1  the frozen set decomposed into REGIONS, and the STRAIN
//                        ENERGY of each from a solve that is being run anyway.
//                        QUIET vs LOAD-BEARING, and what fraction of the 247.3 g
//                        sits in each. If most of the prize is quiet, most of the
//                        risk in this task evaporates.
//   --stage r1       R1  C0 inertness: Lattice(f = 1.0) against Solid, by
//                        checksum of the converged design, plus the element-level
//                        agreement of the cubic and isotropic laws at rho = 1.
//   --stage assign   M2  the MODE 1 assignment table: region x density, certified,
//                        EVERY CELL INCLUDING THE FAILURES.
//   --stage loop     M3  assign -> re-optimise -> certify -> step up. The NET
//                        saving per pass.
//   --stage cost     M5  what the coefficient block costs against the state solve.
//
// ★ THE PROBLEM IS NOT RE-DERIVED. `build_production_loadcase` builds it from the
// same transcription `levelset_probe` and `portable_problem_export` use, and the
// counts printed in the header must reproduce theirs or the run is not on his
// part. The BASELINE DESIGNS are read from the committed reference bakeoff's
// `design.bin` — the same converged SIMP rungs every arm since PR 322 has been
// measured against — so a margin row here is comparable to those and not to
// nothing.
//
// ★ THE CERTIFICATION IS ISOLATED exactly as production isolates it: recycling and
// GenEO off, FP64, the tight tolerance. The TRAJECTORY (the --stage loop
// re-optimisations) runs in the PRODUCTION posture, because
// `probe-must-not-disarm-production-posture` records that disarming what
// `build_production_loadcase` armed cost 2.5x per iteration on this part and was
// measuring the handicap rather than the mechanism.
//
// Prints tables. Asserts the things bar R1 and the pre-registration turn on.

#include "topopt/analyze.hpp"
#include "topopt/design_store.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_density_field.hpp"
#include "topopt/lattice_material.hpp"
#include "topopt/lattice_void.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <limits>
#include <map>
#include <tuple>
#include <string>
#include <vector>

using namespace topopt;

namespace {

double now_s() {
  using namespace std::chrono;
  return duration<double>(steady_clock::now().time_since_epoch()).count();
}

struct Args {
  std::string step, materials, ref_design, out;
  std::string stage = "regions";
  double rung = 0.68;
  double cell_mm = 2.0;
  double min_extrudable_width_mm = 0.45;
  int threads = 3;
  int iters = 60;
  std::vector<double> densities{0.20, 0.30, 0.45, 0.60};
  double freed_mass_return = 0.0;
  bool allow_below_floor = false;
  // ★ WHICH REGIONS THE ASSIGNMENT TABLE COVERS, and it is a COST decision, not a
  // scientific one: one certification of his part in production's isolated posture
  // is minutes of matrix-free CG, so a 5x4x2 table is hours. Empty = every region.
  // A run that names a subset PRINTS the ones it skipped (`no silent caps`).
  std::vector<int> only_regions;
};

// ── THE REGION DECOMPOSITION ────────────────────────────────────────────────
//
// ★ REGIONS ARE MEASURED FROM THE MASK, NOT DECLARED BESIDE IT. The frozen set is
// split into 26-CONNECTED COMPONENTS of `effective_design_mask`'s FrozenSolid
// voxels, and each component is then LABELLED by what it contains: Fixture voxels
// make it an anchor region, Load voxels a load region, neither a protection
// region. 26 and not 6 because the load path's own walk over the solid set is
// 26-connected (voxel.hpp, walk_load_path) — two elements meeting at a corner
// share that node and really do pass force through it, so a component that walk
// treats as one piece must be one region here too.
//
// This is deliberately NOT read back from ProductionRunSetup's per-face reports:
// those carry COUNTS, not per-voxel provenance, and a region a user can point at
// on screen is a connected piece of material, not a face id.
struct Region {
  int id = 0;
  std::string name;
  std::vector<std::size_t> voxels;
  bool has_fixture = false;
  bool has_load = false;
  // filled by measure_regions
  double mass_g = 0.0;
  double strain_energy = 0.0;     // sum over the region of 0.5 u^T K u
  double peak_vm = 0.0;
  double member_width_median_mm = 0.0;
  double cells_per_member_median = 0.0;
  bool quiet = false;
};

std::vector<Region> decompose_frozen(const VoxelGrid& g, const DesignMask& eff) {
  const std::size_t n = g.voxel_count();
  std::vector<int> comp(n, 0);
  std::vector<Region> out;
  std::vector<std::size_t> stack;
  int next_id = 0;
  for (int k0 = 0; k0 < g.nz; ++k0)
    for (int j0 = 0; j0 < g.ny; ++j0)
      for (int i0 = 0; i0 < g.nx; ++i0) {
        const std::size_t s = g.index(i0, j0, k0);
        if (eff[s] != MaskValue::FrozenSolid || comp[s] != 0) continue;
        ++next_id;
        Region r;
        r.id = next_id;
        stack.clear();
        stack.push_back(s);
        comp[s] = next_id;
        while (!stack.empty()) {
          const std::size_t v = stack.back();
          stack.pop_back();
          r.voxels.push_back(v);
          const int i = static_cast<int>(v % static_cast<std::size_t>(g.nx));
          const int j = static_cast<int>((v / static_cast<std::size_t>(g.nx)) %
                                         static_cast<std::size_t>(g.ny));
          const int k = static_cast<int>(v / (static_cast<std::size_t>(g.nx) *
                                              static_cast<std::size_t>(g.ny)));
          const VoxelTag t = g.tag(i, j, k);
          if (t == VoxelTag::Fixture) r.has_fixture = true;
          if (t == VoxelTag::Load) r.has_load = true;
          for (int dk = -1; dk <= 1; ++dk)
            for (int dj = -1; dj <= 1; ++dj)
              for (int di = -1; di <= 1; ++di) {
                if (di == 0 && dj == 0 && dk == 0) continue;
                const int a = i + di, b = j + dj, c = k + dk;
                if (a < 0 || b < 0 || c < 0 || a >= g.nx || b >= g.ny || c >= g.nz)
                  continue;
                const std::size_t w = g.index(a, b, c);
                if (eff[w] != MaskValue::FrozenSolid || comp[w] != 0) continue;
                comp[w] = next_id;
                stack.push_back(w);
              }
        }
        out.push_back(std::move(r));
      }
  // Largest first, then renumbered 1..N so the ids a table prints are stable and
  // ordered by how much of the prize each region holds.
  std::sort(out.begin(), out.end(), [](const Region& a, const Region& b) {
    return a.voxels.size() > b.voxels.size();
  });
  for (std::size_t q = 0; q < out.size(); ++q) {
    out[q].id = static_cast<int>(q + 1);
    out[q].name = out[q].has_fixture   ? "anchor"
                  : out[q].has_load    ? "load-pad"
                                       : "protection";
    out[q].name += "-" + std::to_string(out[q].id);
  }
  return out;
}

std::vector<int> region_id_field(const VoxelGrid& g,
                                 const std::vector<Region>& regions) {
  std::vector<int> id(g.voxel_count(), 0);
  for (const Region& r : regions)
    for (std::size_t v : r.voxels) id[v] = r.id;
  return id;
}

// Per-element strain energy 0.5 u^T K(rho) u from a solved displacement field.
// The SAME element and the SAME modulus law the solve used, so this is a re-read
// of one solve and not a second opinion about it.
double element_strain_energy(const VoxelGrid& g, const SimpParams& params,
                             const std::vector<double>& u, int i, int j, int k,
                             double rho, const Hex8Stiffness& Kunit) {
  const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
  std::array<double, 24> ue{};
  for (int a = 0; a < 8; ++a)
    for (int c = 0; c < 3; ++c)
      ue[static_cast<std::size_t>(3 * a + c)] =
          u[static_cast<std::size_t>(3 * en[a] + c)];
  double q = 0.0;
  for (int r = 0; r < 24; ++r) {
    double kr = 0.0;
    for (int c = 0; c < 24; ++c) kr += Kunit(r, c) * ue[static_cast<std::size_t>(c)];
    q += ue[static_cast<std::size_t>(r)] * kr;
  }
  return 0.5 * std::pow(rho, params.penalty) * params.youngs_modulus * q;
}

}  // namespace

int main(int argc, char** argv) {
  Args a;
  if (argc < 5) {
    std::printf(
        "usage: frozen_lattice_probe <part.step> <materials.json> "
        "<ref_design.bin> <out_dir> [--stage law|regions|r1|assign|loop|cost]\n"
        "       [--rung R] [--cell MM] [--threads N] [--iters N]\n"
        "       [--densities a,b,c] [--freed-mass-return X] [--allow-below-floor]\n");
    return 2;
  }
  a.step = argv[1];
  a.materials = argv[2];
  a.ref_design = argv[3];
  a.out = argv[4];
  for (int i = 5; i < argc; ++i) {
    const std::string s = argv[i];
    auto next = [&](double& d) { if (i + 1 < argc) d = std::atof(argv[++i]); };
    auto nexti = [&](int& d) { if (i + 1 < argc) d = std::atoi(argv[++i]); };
    if (s == "--stage" && i + 1 < argc) a.stage = argv[++i];
    else if (s == "--rung") next(a.rung);
    else if (s == "--cell") next(a.cell_mm);
    else if (s == "--min-width") next(a.min_extrudable_width_mm);
    else if (s == "--threads") nexti(a.threads);
    else if (s == "--iters") nexti(a.iters);
    else if (s == "--freed-mass-return") next(a.freed_mass_return);
    else if (s == "--allow-below-floor") a.allow_below_floor = true;
    else if (s == "--only-regions" && i + 1 < argc) {
      std::string v = argv[++i];
      std::size_t p = 0;
      while (p <= v.size()) {
        const std::size_t q = v.find(',', p);
        const std::string tok = v.substr(p, q == std::string::npos ? q : q - p);
        if (!tok.empty()) a.only_regions.push_back(std::atoi(tok.c_str()));
        if (q == std::string::npos) break;
        p = q + 1;
      }
    }
    else if (s == "--densities" && i + 1 < argc) {
      a.densities.clear();
      std::string v = argv[++i];
      std::size_t p = 0;
      while (p <= v.size()) {
        const std::size_t q = v.find(',', p);
        const std::string tok = v.substr(p, q == std::string::npos ? q : q - p);
        if (!tok.empty()) a.densities.push_back(std::atof(tok.c_str()));
        if (q == std::string::npos) break;
        p = q + 1;
      }
    } else {
      std::printf("FATAL: unknown argument %s\n", s.c_str());
      return 2;
    }
  }

  // ── HIS PROBLEM, from the PRODUCTION builder ──────────────────────────────
  // Transcribed from evidence/2026-08-09-reference-implementation-bakeoff/
  // job_simp.json, character for character as levelset_probe transcribes it, and
  // for the same reason: `production_loadcase_from_job` lives inside run_job.cpp's
  // translation unit and is not on a public header. The transcription is PROVED
  // right by the counts printed below, which must reproduce that probe's.
  const int resolution = 128;
  ProductionLoadCase lc;
  lc.anchor_face_ids = {18};
  ProductionLoadCase::LoadGroup lg;
  lg.face_ids = {20, 1, 4, 19, 21, 22, 25, 26, 27, 32, 41, 42,
                 43, 44, 45, 46, 47, 49, 75, 76, 24, 31};
  lg.force = Vec3{0.0, 0.0, -22.241134643554688};
  lc.load_groups.push_back(lg);
  lc.minimize_plastic = true;
  lc.build_dir = Vec3{0.0, 0.0, 1.0};
  lc.build_orientation_report = true;
  lc.infill_percent = 35.0;
  lc.wall_loops = 5;
  lc.wall_line_width_mm = 0.45;
  lc.wall_line_width_outer_mm = 0.42;
  lc.face_protection_face_ids = {16};
  lc.face_protection_depth_mm = 5.0;

  const StepModel model = import_part_file_resolved(a.step);
  if (model.mesh.vertices.empty()) {
    std::printf("FATAL: the STEP imported empty — OCCT is required\n");
    return 2;
  }
  const ProductionRunSetup setup = build_production_loadcase(model, resolution, lc);
  const VoxelGrid& grid = setup.grid;
  const MinimizePlasticOptions& options = setup.options;
  const std::vector<DirichletBC>& bcs = setup.bcs;
  const std::vector<NodalLoad>& loads = options.external_loads;

  const MaterialLibrary lib = load_materials_file(a.materials);
  const auto mit = lib.find("PLA");
  if (mit == lib.end()) { std::printf("FATAL: PLA not in %s\n", a.materials.c_str()); return 2; }
  const Material& material = mit->second;

  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;

  const std::size_t n = grid.voxel_count();
  const double part_solid = static_cast<double>(grid.solid_count());
  const DesignMask eff = effective_design_mask(grid, options.design_mask);
  std::size_t n_active = 0, n_fsolid = 0, n_fvoid = 0;
  for (std::size_t v = 0; v < n; ++v) {
    if (eff[v] == MaskValue::Active) ++n_active;
    else if (eff[v] == MaskValue::FrozenSolid) ++n_fsolid;
    else ++n_fvoid;
  }

  // He needs his Mac. production.hpp names the one safe way to do this — call
  // fea_set_matfree_threads AFTER configure_production_options — and
  // build_production_loadcase has already run that, so this is the documented
  // override. It cannot change an answer: the matrix-free apply threads a
  // deterministic 8-colour partition whose accumulation order is set by the
  // colour scheme and not by the thread count.
  const int prev_threads = fea_set_matfree_threads(a.threads);

  std::printf("== frozen_lattice_probe — a frozen region as a MATERIAL ==\n\n");
  std::printf("part        %s (%zu B-rep faces)\n", a.step.c_str(),
              model.faces.size());
  std::printf("grid        %d x %d x %d = %zu voxels, spacing %.9f mm\n", grid.nx,
              grid.ny, grid.nz, n, grid.spacing);
  std::printf("part solid  %.0f voxels;  mask Active %zu / FrozenSolid %zu / "
              "FrozenVoid %zu\n", part_solid, n_active, n_fsolid, n_fvoid);
  std::printf("stage       %s   rung %.4g   cell %.4g mm   nozzle %.4g mm   "
              "threads %d\n\n", a.stage.c_str(), a.rung, a.cell_mm,
              a.min_extrudable_width_mm, a.threads);

  const LatticeTopology topo = LatticeTopology::Octet;
  const double g_per_voxel =
      material.density_g_cm3 * grid.voxel_volume() / 1000.0;

  // ─────────────────────────────────────────────────────────────────────────
  // M0 — THE LAW
  // ─────────────────────────────────────────────────────────────────────────
  if (a.stage == "law") {
    const LatticeMaterialModel M = build_lattice_material_model(
        topo, material.youngs_modulus_mpa, material.poisson);
    std::string why;
    const bool trust = lattice_material_model_trustworthy(topo, &why);
    std::printf("-- M0(a) THE FIT: what the optimiser actually sees --\n");
    std::printf("   topology            %s\n", lattice_topology_name(topo));
    std::printf("   measured rows       %zu   (lattice_resolved_rows — CORE, never "
                "a transcript)\n", M.rows);
    std::printf("   certifiable band    [%.6f, %.6f]\n", M.rho_lo, M.rho_hi);
    std::printf("   trustworthy to STEER a loop on   %s%s%s\n",
                trust ? "YES" : "NO", trust ? "" : " — ", why.c_str());
    std::printf("   fit order           %d terms, origin-anchored C(0) = 0\n",
                M.fit[0].nterms);
    std::printf("   solid triplet at rho=1  C11 %.4f  C12 %.4f  C44 %.4f\n",
                M.solid[0], M.solid[1], M.solid[2]);

    // The EXACT isotropic triplet, computed here independently of the model, so
    // "the curve reaches solid exactly" is a comparison and not a restatement.
    const double E = material.youngs_modulus_mpa, nu = material.poisson;
    const double c = E / ((1.0 + nu) * (1.0 - 2.0 * nu));
    const double iC11 = c * (1.0 - nu), iC12 = c * nu, iC44 = E / (2.0 * (1.0 + nu));
    const CubicTensor at1 = M.value(1.0);
    std::printf("   isotropic solid         C11 %.4f  C12 %.4f  C44 %.4f\n", iC11,
                iC12, iC44);
    std::printf("   |curve(1) - isotropic|  %.3e  %.3e  %.3e   (relative)\n",
                std::fabs(at1.C11 - iC11) / iC11, std::fabs(at1.C12 - iC12) / iC12,
                std::fabs(at1.C44 - iC44) / iC44);

    std::printf("\n-- M0(b) THE ASYMPTOTIC LAW THE OPTIMISER MUST NEVER SEE --\n");
    std::printf("   Gibson-Ashby E*/Es = C rho^m is fitted here to the MEASURED "
                "rows' own\n"
                "   effective Young's modulus so the comparison is like for like, "
                "then the\n"
                "   two are differenced ROW BY ROW. `lattice-phase0` M2 measured "
                "this gap at\n"
                "   23-52%% with an exponent near 2.0, OVER-PREDICTING stiffness.\n\n");
    const std::vector<LatticeResolvedRow> rows = lattice_resolved_rows(topo);
    // E_eff of a cubic tensor along a cube axis: the [100] Young's modulus
    // E = (C11 - C12)(C11 + 2 C12) / (C11 + C12).
    auto Eaxis = [](double C11, double C12) {
      return (C11 - C12) * (C11 + 2.0 * C12) / (C11 + C12);
    };
    // Least squares for (log C, m) on log E = log C + m log rho, over the rows.
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    const double Es_lib = lattice_library_youngs_modulus();
    for (const LatticeResolvedRow& r : rows) {
      const double x = std::log(r.rho);
      const double y = std::log(Eaxis(r.C11, r.C12) / Es_lib);
      sx += x; sy += y; sxx += x * x; sxy += x * y;
    }
    const double N = static_cast<double>(rows.size());
    const double m = (N * sxy - sx * sy) / (N * sxx - sx * sx);
    const double logC = (sy - m * sx) / N;
    const double Cga = std::exp(logC);
    std::printf("   fitted Gibson-Ashby   E*/Es = %.6f rho^%.4f   (over %zu "
                "measured rows)\n", Cga, m, rows.size());
    std::printf("   %8s  %14s  %14s  %10s\n", "rho", "measured E*/Es",
                "G-A E*/Es", "G-A error");
    double worst = 0.0, worst_rho = 0.0;
    for (const LatticeResolvedRow& r : rows) {
      const double meas = Eaxis(r.C11, r.C12) / Es_lib;
      const double ga = Cga * std::pow(r.rho, m);
      const double err = (ga - meas) / meas;
      if (std::fabs(err) > std::fabs(worst)) { worst = err; worst_rho = r.rho; }
      std::printf("   %8.4f  %14.6e  %14.6e  %+9.2f%%\n", r.rho, meas, ga,
                  100.0 * err);
    }
    std::printf("   WORST %+0.2f%% at rho %.4f. This is the error the fitted "
                "curve does NOT\n"
                "   inherit, because it interpolates the rows instead of an "
                "exponent.\n", 100.0 * worst, worst_rho);

    std::printf("\n-- M0(c) THE VALIDITY RANGE, IN CELLS PER MEMBER --\n");
    std::printf("   certifiable floor N*      %.4f  (lattice_cells_per_member_min)\n",
                lattice_cells_per_member_min(topo));
    std::printf("   percolation floor         %.4f  "
                "(lattice_percolation_cells_per_member_min)\n",
                lattice_percolation_cells_per_member_min(topo));
    std::printf("   printability floor cell   %.6f mm at a %.4g mm nozzle\n",
                lattice_cell_printability_floor_mm(topo, a.min_extrudable_width_mm),
                a.min_extrudable_width_mm);
    for (double W : {3.0, 5.0, 8.0, 10.0, 12.0, 15.0, 20.0, 25.0}) {
      const LatticeCellDerivation d =
          lattice_derive_cell_for_member(topo, W, a.min_extrudable_width_mm);
      std::printf("   member %5.1f mm  feasible %-3s  min certifiable member "
                  "%7.4f mm  cells at cell %.4g mm: %5.2f\n",
                  W, d.feasible ? "yes" : "NO",
                  d.min_member_width_certifiable_mm, a.cell_mm, W / a.cell_mm);
    }
    std::printf("\n   OUTSIDE THE RANGE the law is not softened and not "
                "extrapolated: the\n"
                "   region is REFUSED (bar B4). `lattice_derive_cell_for_member` "
                "gives the\n"
                "   number a user acts on — the thinnest member that could clear "
                "the floor at\n"
                "   this nozzle at ANY (cell, density) pair in the band.\n");
    fea_set_matfree_threads(prev_threads);
    return 0;
  }

  // Everything below needs the baseline design.
  const DesignStore store = read_design_file(a.ref_design);
  if (store.nx != grid.nx || store.ny != grid.ny || store.nz != grid.nz) {
    std::printf("FATAL: %s is %dx%dx%d, this grid is %dx%dx%d\n",
                a.ref_design.c_str(), store.nx, store.ny, store.nz, grid.nx,
                grid.ny, grid.nz);
    return 2;
  }
  const StoredDesign* pick = nullptr;
  for (const auto& s : store.variants)
    if (std::fabs(s.requested_volume_fraction - a.rung) < 1e-9) pick = &s;
  if (!pick) {
    std::printf("FATAL: no rung %.4g in %s (it has:", a.rung, a.ref_design.c_str());
    for (const auto& s : store.variants)
      std::printf(" %.4g", s.requested_volume_fraction);
    std::printf(")\n");
    return 2;
  }
  const std::vector<double>& rho0 = pick->density;
  std::printf("baseline    rung %.4g from %s (achieved %.6f)\n\n",
              pick->requested_volume_fraction, a.ref_design.c_str(),
              pick->achieved_volume_fraction);

  const std::vector<Region> regions0 = decompose_frozen(grid, eff);
  const std::vector<int> rid = region_id_field(grid, regions0);

  // ── ★ THE CERTIFICATION POSTURE, AND WHY IT IS THE ISOLATED ONE ──────────
  //
  // There are TWO certification postures in this repository:
  //
  //   the LADDER's per-rung certification runs in the PRODUCTION posture, with
  //     the Krylov recycle subspace WARM and GenEO armed — it is one solve inside
  //     a rung of sixty, so both accelerators are already built and paid for
  //     (run_job.cpp:1760-1765 says exactly this);
  //   the STANDALONE re-analysis — `analyze_job`, the lattice re-cert, and THIS
  //     PROBE — runs under `ScopedLadderSolverIsolation`: recycling and GenEO OFF.
  //
  // ★ AND THE SECOND ONE IS NOT A HABIT, IT IS THE CHEAPER ONE HERE, MEASURED.
  // This probe was first written in the production posture on the argument that
  // the baseline rungs' margins were produced there. On a COLD standalone solve
  // that is wrong twice over: there is no recycle subspace to reuse, and GenEO
  // pays its full coarse-basis build with nothing to amortise it over. The run
  // was sampled sitting inside `geneo_engage_now` after fifty-one minutes of CPU
  // and had not reached its first certificate. The isolated posture is what
  // ships for a one-off re-analysis precisely because of this, and it is what
  // this probe uses.
  //
  // run_job.cpp records that the two postures "converged to the same residual
  // tolerance: the margins agree to the band that tolerance justifies, and no
  // further" — so this choice is about COST, and the band it costs is stated
  // rather than assumed.
  //
  // FP64 is forced: mixed precision is a V-cycle preconditioner choice no
  // certificate in this repository has been produced under.
  auto certify = [&](const std::vector<double>& rho,
                     const LatticePosture* posture, bool strut_gate) {
    const bool pr = fea_set_krylov_recycling(false);
    const bool pg = fea_set_geneo_twolevel(false);
    const bool pm = fea_set_matfree_mixed_precision(false);
    const bool lp = load_path_connected(grid, rho, 0.5);
    const KnockdownSpec kd = knockdown_spec_for(options);
    FixedDesignAnalysis an;
    try {
      an = analyze_fixed_design(grid, params, rho, bcs, loads, material,
                                options.build_direction, options.simp.cg_tolerance,
                                options.simp.cg_max_iterations, options.simp.solver,
                                options.margin_stop, kd, lp, part_solid, posture,
                                false, false, false, 0.5, strut_gate);
    } catch (const std::exception& e) {
      std::printf("   CERTIFICATION THREW: %s\n", e.what());
    }
    fea_set_matfree_mixed_precision(pm);
    fea_set_geneo_twolevel(pg);
    fea_set_krylov_recycling(pr);
    return an;
  };

  // ─────────────────────────────────────────────────────────────────────────
  // M1 — THE REGIONS, AND WHICH OF THEM ARE QUIET
  // ─────────────────────────────────────────────────────────────────────────
  if (a.stage == "regions") {
    std::printf("-- M1(a) THE FROZEN SET, DECOMPOSED --\n");
    std::printf("   %zu 26-connected components of the effective mask's "
                "FrozenSolid set\n\n", regions0.size());

    const double t0 = now_s();
    const FixedDesignAnalysis base = certify(rho0, nullptr, false);
    std::printf("   baseline certification: margin_eff %.6f  accepted %s  "
                "mass %.4f g  (%.1f s)\n\n", base.margin_effective,
                base.accepted ? "yes" : "NO", base.mass_grams, now_s() - t0);
    if (base.non_convergent) {
      std::printf("FATAL: the baseline certification solve did not converge — "
                  "nothing below is comparable.\n");
      return 3;
    }

    // Per-region strain energy and peak macro von Mises, re-read off THAT solve.
    const Hex8Stiffness Kunit = hex8_stiffness(1.0, params.poisson, grid.spacing);
    std::vector<Region> R = regions0;
    double total_energy = 0.0, part_peak_vm = 0.0;
    for (std::size_t e = 0; e < n; ++e)
      part_peak_vm = std::max(part_peak_vm, base.von_mises_field[e]);
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          const std::size_t e = grid.index(i, j, k);
          if (!grid.solid(i, j, k)) continue;
          if (!(rho0[e] > 0.5)) continue;
          total_energy += element_strain_energy(grid, params,
                                                base.displacement_field, i, j, k,
                                                rho0[e], Kunit);
        }
    const std::vector<double> width = local_member_thickness_mm(
        grid, rho0, 0.5, 32);
    for (Region& r : R) {
      std::vector<double> w;
      w.reserve(r.voxels.size());
      for (std::size_t v : r.voxels) {
        const int i = static_cast<int>(v % static_cast<std::size_t>(grid.nx));
        const int j = static_cast<int>((v / static_cast<std::size_t>(grid.nx)) %
                                       static_cast<std::size_t>(grid.ny));
        const int k = static_cast<int>(v / (static_cast<std::size_t>(grid.nx) *
                                            static_cast<std::size_t>(grid.ny)));
        r.strain_energy += element_strain_energy(grid, params,
                                                 base.displacement_field, i, j, k,
                                                 1.0, Kunit);
        r.peak_vm = std::max(r.peak_vm, base.von_mises_field[v]);
        w.push_back(width[v]);
      }
      std::sort(w.begin(), w.end());
      r.member_width_median_mm = w.empty() ? 0.0 : w[w.size() / 2];
      r.cells_per_member_median = r.member_width_median_mm / a.cell_mm;
      r.mass_g = static_cast<double>(r.voxels.size()) * g_per_voxel;
    }

    // ★ THE QUIET TEST IS CORE'S OWN, NOT A NEW ONE. `grade_lattice`'s sub-floor
    // retention already asks "region peak demand / PART peak demand <= ceiling",
    // and the app already exposes it as "counts as unloaded up to core's N%".
    // Using a different threshold here would mean the probe and the shipped
    // grading law disagreed about which regions are quiet.
    const double quiet_ceiling = lattice_subfloor_retention_stress_fraction();
    std::printf("-- M1(b) STRAIN ENERGY PER REGION, and the QUIET / LOAD-BEARING "
                "split --\n");
    std::printf("   quiet ceiling  %.4f  (lattice_subfloor_retention_stress_"
                "fraction — core's own,\n"
                "                  the SAME predicate grade_lattice arms sub-floor "
                "retention on)\n", quiet_ceiling);
    std::printf("   part peak vM   %.6f MPa   total printed strain energy %.6e\n\n",
                part_peak_vm, total_energy);
    std::printf("   %-14s %8s %9s %10s %10s %8s %8s  %s\n", "region", "voxels",
                "mass g", "energy", "share", "peakVM", "vM/part", "verdict");
    double quiet_mass = 0.0, loud_mass = 0.0, all_mass = 0.0;
    for (Region& r : R) {
      const double frac = part_peak_vm > 0.0 ? r.peak_vm / part_peak_vm : 0.0;
      r.quiet = frac <= quiet_ceiling;
      all_mass += r.mass_g;
      (r.quiet ? quiet_mass : loud_mass) += r.mass_g;
      std::printf("   %-14s %8zu %9.3f %10.3e %9.2f%% %8.4f %7.2f%%  %s\n",
                  r.name.c_str(), r.voxels.size(), r.mass_g, r.strain_energy,
                  100.0 * (total_energy > 0.0 ? r.strain_energy / total_energy : 0.0),
                  r.peak_vm, 100.0 * frac, r.quiet ? "QUIET" : "LOAD-BEARING");
    }
    std::printf("\n   frozen mass total %.3f g of %.3f g printed (%.2f%%)\n",
                all_mass, base.mass_grams, 100.0 * all_mass / base.mass_grams);
    std::printf("   QUIET        %.3f g  (%.2f%% of the frozen mass)\n", quiet_mass,
                100.0 * quiet_mass / all_mass);
    std::printf("   LOAD-BEARING %.3f g  (%.2f%% of the frozen mass)\n", loud_mass,
                100.0 * loud_mass / all_mass);

    std::printf("\n-- M1(c) THE VALIDITY OF THE LAW, PER REGION (bar R5) --\n");
    std::vector<LatticeRegionSpec> specs;
    for (const Region& r : R) {
      LatticeRegionSpec s;
      s.id = r.id;
      s.name = r.name;
      s.mode = LatticeRegionMode::Declared;
      s.declared_density = 0.30;
      specs.push_back(s);
    }
    const std::vector<LatticeRegionValidity> V = lattice_region_validity(
        grid, rid, specs, width, topo, a.cell_mm, a.min_extrudable_width_mm);
    std::printf("   %-14s %10s %8s %8s %9s  %s\n", "region", "medianW", "cells",
                "p10", "above N*", "verdict");
    for (const LatticeRegionValidity& v : V)
      std::printf("   %-14s %9.4f %8.2f %8.2f %8.1f%%  %s\n", v.name.c_str(),
                  v.member_width_median_mm, v.cells_per_member_median,
                  v.cells_per_member_p10, 100.0 * v.fraction_above_floor,
                  v.in_validity_range ? "IN RANGE"
                  : v.buildable_not_certifiable
                      ? "BUILDABLE AND UNCERTIFIABLE — REFUSED"
                      : "OUT OF RANGE — REFUSED");
    for (const LatticeRegionValidity& v : V)
      if (!v.refusal.empty())
        std::printf("\n   %s\n", v.refusal.c_str());
    fea_set_matfree_threads(prev_threads);
    return 0;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // M2 — THE MODE 1 ASSIGNMENT TABLE
  // ─────────────────────────────────────────────────────────────────────────
  if (a.stage == "assign") {
    const std::vector<double> width = local_member_thickness_mm(grid, rho0, 0.5, 32);
    std::vector<LatticeRegionSpec> all;
    for (const Region& r : regions0) {
      LatticeRegionSpec s;
      s.id = r.id;
      s.name = r.name;
      s.mode = LatticeRegionMode::Declared;
      all.push_back(s);
    }
    const std::vector<LatticeRegionValidity> V = lattice_region_validity(
        grid, rid, all, width, topo, a.cell_mm, a.min_extrudable_width_mm);

    const double t0 = now_s();
    const FixedDesignAnalysis base = certify(rho0, nullptr, false);
    std::printf("-- M2 THE ASSIGNMENT TABLE — EVERY CELL, INCLUDING THE FAILURES "
                "--\n\n");
    std::printf("   baseline (every region SOLID): margin_eff %.6f  accepted %s  "
                "mass %.4f g  (%.1f s)\n",
                base.margin_effective, base.accepted ? "yes" : "NO",
                base.mass_grams, now_s() - t0);
    std::printf("   margin_stop %.6f   knockdown posture: infill %.4g%%, "
                "width_aware %s\n\n", options.margin_stop,
                knockdown_spec_for(options).infill_percent,
                knockdown_spec_for(options).width_aware ? "on" : "off");
    std::printf("   %-14s %6s %8s %9s %9s %10s %10s %8s %7s %6s %s\n", "region",
                "f", "cells/m", "mass g", "dmass g", "margin", "dmargin",
                "strutM", "regime", "drain", "verdict");

    std::ofstream csv(a.out + "/m2_assignment.csv");
    csv << "rung,region,region_voxels,f,cells_per_member,in_range,mass_g,"
           "dmass_g,margin_effective,margin_solid_only,dmargin_pct,strut_margin,"
           "out_of_regime,sealed,accepted,load_path,refused\n";
    csv.precision(10);

    if (!a.only_regions.empty()) {
      std::printf("   ★ COVERAGE IS CAPPED and here is what was dropped: only "
                  "regions");
      for (int id : a.only_regions) std::printf(" %d", id);
      std::printf(" are certified below. The others are NOT measured — a table "
                  "that\n     silently omitted them would read as though they "
                  "had been.\n\n");
    }
    for (std::size_t q = 0; q < regions0.size(); ++q) {
      const Region& r = regions0[q];
      const LatticeRegionValidity& v = V[q];
      if (!a.only_regions.empty() &&
          std::find(a.only_regions.begin(), a.only_regions.end(), r.id) ==
              a.only_regions.end())
        continue;
      for (double f : a.densities) {
        std::vector<LatticeRegionSpec> spec1;
        LatticeRegionSpec s;
        s.id = r.id;
        s.name = r.name;
        s.mode = LatticeRegionMode::Declared;
        s.declared_density = f;
        spec1.push_back(s);
        std::vector<char> only(n, 0);
        for (std::size_t vx : r.voxels) only[vx] = 1;
        std::vector<int> refused;
        if (!v.in_validity_range && !a.allow_below_floor) refused.push_back(r.id);

        const ResolvedLatticeDensityField F = resolve_lattice_density_field(
            grid, rid, spec1, topo, nullptr, &only, refused);
        if (F.empty()) {
          std::printf("   %-14s %6.2f %8.2f %9s %9s %10s %10s %8s %7s %6s  "
                      "REFUSED (below N* = %.1f)\n", r.name.c_str(), f,
                      v.cells_per_member_median, "-", "-", "-", "-", "-", "-",
                      "-", v.floor_certifiable);
          csv << a.rung << "," << r.name << "," << r.voxels.size() << "," << f
              << "," << v.cells_per_member_median << "," << (v.in_validity_range ? 1 : 0)
              << ",,,,,,,,,,1\n";
          continue;
        }
        LatticePosture posture;
        posture.topology = topo;
        posture.cell_size_mm = a.cell_mm;
        posture.mask = F.mask;
        posture.relative_density = F.rho;
        const double t1 = now_s();
        const FixedDesignAnalysis an = certify(rho0, &posture, true);
        // Drainability, with the manufacturing definition: void 6-connected, the
        // escape network is LATTICED u VOID, and FROZEN MATERIAL THAT IS NOT
        // LATTICED IS SOLID and BLOCKS — powder does not pass through a bolt boss.
        const LatticeVoidEscapeReport ve = lattice_void_escape(
            grid, rho0, 0.5, F.mask, grid.origin, a.cell_mm, &rid);
        const double dmass = an.mass_grams - base.mass_grams;
        const double dmargin = base.margin_effective > 0.0
                                   ? 100.0 * (an.margin_effective -
                                              base.margin_effective) /
                                         base.margin_effective
                                   : 0.0;
        const char* verdict =
            an.non_convergent ? "NON-CONVERGENT"
            : !an.accepted    ? "REJECTED"
            : ve.sealed()     ? "SEALED — REFUSED"
                              : "accepted";
        std::printf("   %-14s %6.2f %8.2f %9.3f %+9.3f %10.4f %+9.2f%% %8.4f "
                    "%7s %6s  %s (%.0f s)\n",
                    r.name.c_str(), f, v.cells_per_member_median, an.mass_grams,
                    dmass, an.margin_effective, dmargin,
                    an.lattice_strut_report ? an.lattice_strut.margin_worst_case
                                            : 0.0,
                    an.lattice_strut_out_of_regime ? "OUT" : "in",
                    ve.sealed() ? "SEAL" : "ok", verdict, now_s() - t1);
        csv << a.rung << "," << r.name << "," << r.voxels.size() << "," << f << ","
            << v.cells_per_member_median << "," << (v.in_validity_range ? 1 : 0)
            << "," << an.mass_grams << "," << dmass << "," << an.margin_effective
            << "," << an.margin_effective_solid_only << "," << dmargin << ","
            << (an.lattice_strut_report ? an.lattice_strut.margin_worst_case : 0.0)
            << "," << (an.lattice_strut_out_of_regime ? 1 : 0) << ","
            << (ve.sealed() ? 1 : 0) << "," << (an.accepted ? 1 : 0) << ","
            << (load_path_connected(grid, rho0, 0.5) ? 1 : 0) << ",0\n";
        csv.flush();
      }
    }
    std::printf("\n   wrote %s/m2_assignment.csv\n", a.out.c_str());
    fea_set_matfree_threads(prev_threads);
    return 0;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // R1 — C0 INERTNESS. THIS RUNS BEFORE ANY ARM.
  // ─────────────────────────────────────────────────────────────────────────
  //
  // ★ IF IT FAILS, THE MATERIAL MODEL IS WRONG AND NO RESULT AFTER IT CAN BE
  // TRUSTED (bar R1, and a BLOCKED-STOP).
  //
  // The bar is BYTE-IDENTICAL, so what is compared is the design_fingerprint of
  // the converged field — the same FNV-1a over the density bytes the shipped
  // design container stores, so "identical" here means identical to the file
  // format's own definition of identical and not to a tolerance this probe chose.
  //
  // TWO HALVES, and the second is the one a checksum inside one binary cannot
  // give you:
  //   (a) HERE — the ladder run with `frozen_lattice` OFF against the SAME ladder
  //       with it ON and every region declared at f = 1.0. A lattice at relative
  //       density 1.0 has no pore space; it IS solid. So the arming must resolve
  //       to an EMPTY field and touch nothing.
  //   (b) `r1_c0_inertness.sh` — this same OFF run, built from the tree BEFORE
  //       this task's commits, against the OFF run built from the tree after. That
  //       is the half that proves the shipped path did not move, and no amount of
  //       in-binary comparison substitutes for it.
  //
  // Reported beside them, because the two claims are different and only the first
  // is a bar: the ELEMENT-LEVEL agreement between the cubic law at rho = 1 and the
  // isotropic element the solid path builds. That is "identical to machine
  // precision", which is what would have had to carry R1 if the dispatch rule did
  // not exist.
  if (a.stage == "r1") {
    MinimizePlasticOptions o = options;
    o.volume_fraction_ladder = {a.rung};
    o.simp.max_iterations = a.iters;
    // The rules file sits beside the materials file the caller already named, so
    // the probe needs no build-time define of its own.
    const std::string rules_path =
        a.materials.substr(0, a.materials.find_last_of('/') + 1) +
        "../settings/rules.json";
    const SettingsRules rules = load_settings_rules_file(rules_path);

    auto run = [&](bool arm, double f) {
      MinimizePlasticOptions oo = o;
      std::vector<LatticeRegionSpec> specs;
      if (arm) {
        oo.frozen_lattice = true;
        oo.frozen_lattice_topology = topo;
        oo.frozen_lattice_region_id = rid;
        oo.frozen_lattice_cell_mm = a.cell_mm;
        oo.frozen_lattice_min_extrudable_width_mm = a.min_extrudable_width_mm;
        // ★ THE FLOOR IS DELIBERATELY NOT ENFORCED FOR THIS TEST. A refusal
        // would ALSO produce an empty field, and then the checksum would pass
        // for the wrong reason — it would be measuring the refusal, not the
        // f = 1.0 dispatch. Every region here is admitted and every region is
        // declared SOLID-BY-DENSITY, so the only thing that can make the field
        // empty is the rule this bar is about.
        oo.frozen_lattice_refuse_below_floor = false;
        for (const Region& r : regions0) {
          LatticeRegionSpec s;
          s.id = r.id;
          s.name = r.name;
          s.mode = LatticeRegionMode::Declared;
          s.declared_density = f;
          specs.push_back(s);
        }
        oo.frozen_lattice_regions = specs;
      }
      const double t0 = now_s();
      MinimizePlasticResult mr =
          minimize_plastic(grid, material, "PLA", bcs, rules, oo);
      const double wall = now_s() - t0;
      std::uint64_t fp = 0;
      double vf = 0.0, comp = 0.0;
      if (!mr.evaluated.empty()) {
        const MinimizePlasticVariant& v = mr.evaluated.back();
        fp = design_fingerprint(v.optimization.physical_density);
        vf = v.optimization.volume_fraction;
        comp = v.optimization.compliance;
      }
      return std::make_tuple(fp, vf, comp, wall, mr.frozen_lattice);
    };

    std::printf("-- R1 C0 INERTNESS: Lattice(f = 1.0) against Solid --\n");
    std::printf("   ladder [%.4g], %d iterations, %d threads\n\n", a.rung, a.iters,
                a.threads);
    const auto off = run(false, 1.0);
    std::printf("   frozen_lattice OFF          fingerprint %016llx  vf %.12f  "
                "c %.12e  (%.1f s)\n",
                static_cast<unsigned long long>(std::get<0>(off)),
                std::get<1>(off), std::get<2>(off), std::get<3>(off));
    const auto on1 = run(true, 1.0);
    const FrozenLatticeReport& r1rep = std::get<4>(on1);
    std::printf("   frozen_lattice ON, f = 1.0  fingerprint %016llx  vf %.12f  "
                "c %.12e  (%.1f s)\n",
                static_cast<unsigned long long>(std::get<0>(on1)),
                std::get<1>(on1), std::get<2>(on1), std::get<3>(on1));
    std::printf("     -> armed %s, %zu regions declared, %zu voxels latticed, "
                "%.6f mass-equivalent voxels freed\n",
                r1rep.armed ? "yes" : "no", r1rep.regions.size(),
                r1rep.latticed_voxels, r1rep.freed_mass_voxels);

    const bool byte_identical = std::get<0>(off) == std::get<0>(on1);
    std::printf("\n   BYTE-IDENTICAL: %s\n", byte_identical ? "YES" : "*** NO ***");

    // The other claim, measured rather than asserted.
    const LatticeMaterialModel M = build_lattice_material_model(
        topo, material.youngs_modulus_mpa, material.poisson);
    const CubicTensor C1 = M.value(1.0);
    Hex8Stiffness KA, KB, KC;
    hex8_cubic_blocks(grid.spacing, KA, KB, KC);
    const Hex8Stiffness Kiso =
        hex8_stiffness(material.youngs_modulus_mpa, material.poisson, grid.spacing);
    double worst_abs = 0.0, worst_rel = 0.0, scale = 0.0;
    for (int r = 0; r < 24; ++r)
      for (int c = 0; c < 24; ++c)
        scale = std::max(scale, std::fabs(Kiso(r, c)));
    for (int r = 0; r < 24; ++r)
      for (int c = 0; c < 24; ++c) {
        const double cub =
            C1.C11 * KA(r, c) + C1.C12 * KB(r, c) + C1.C44 * KC(r, c);
        const double d = std::fabs(cub - Kiso(r, c));
        worst_abs = std::max(worst_abs, d);
        worst_rel = std::max(worst_rel, d / scale);
      }
    std::printf("\n   BESIDE IT (not a bar): the cubic element built from "
                "C(rho=1) against the\n"
                "   isotropic element the solid path builds — worst |dK| %.6e, "
                "relative to the\n"
                "   largest entry %.6e. The two laws AGREE at the join; the "
                "dispatch rule is\n"
                "   what makes the bar exact rather than merely tight.\n",
                worst_abs, worst_rel);

    std::ofstream f(a.out + "/r1_c0_inertness.txt");
    f.precision(17);
    f << "off_fingerprint " << std::get<0>(off) << "\n";
    f << "on_f1_fingerprint " << std::get<0>(on1) << "\n";
    f << "byte_identical " << (byte_identical ? 1 : 0) << "\n";
    f << "off_vf " << std::get<1>(off) << "\n";
    f << "on_vf " << std::get<1>(on1) << "\n";
    f << "off_compliance " << std::get<2>(off) << "\n";
    f << "on_compliance " << std::get<2>(on1) << "\n";
    f << "latticed_voxels " << r1rep.latticed_voxels << "\n";
    f << "cubic_vs_isotropic_worst_abs " << worst_abs << "\n";
    f << "cubic_vs_isotropic_worst_rel " << worst_rel << "\n";
    fea_set_matfree_threads(prev_threads);
    return byte_identical ? 0 : 4;
  }

  std::printf("FATAL: unknown --stage %s\n", a.stage.c_str());
  fea_set_matfree_threads(prev_threads);
  return 2;
}
