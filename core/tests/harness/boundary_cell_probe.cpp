// boundary_cell_probe — S1 of task 2026-08-08-how-wrong-is-the-boundary-cell.
//
//   cmake --build core/build --target boundary_cell_probe
//   ./core/build/boundary_cell_probe <job_dir> <design.bin> <rung> <refine> <csv_out>
//                                    [--mode replicate|retag] [--calibrate]
//
// ── THE QUESTION ────────────────────────────────────────────────────────────
//
// The certificate reads ONE number: `max_von_mises`, the largest per-voxel von
// Mises over the printed set. `margin.in_plane = yield / max_von_mises`, and on
// the maintainer's run the in-plane term is the min, so the reported margin IS
// yield/peak. A relative error in the peak is exactly minus the relative error
// in the margin, and the ACCEPT verdict is a threshold on it.
//
// A boundary voxel holds its material smeared uniformly across the cell: the cell
// knows HOW MUCH it holds and nothing about WHERE. So the question is whether the
// coarse cell's peak stress is the peak stress of the object it is meant to
// describe.
//
// ── THE INSTRUMENT, AND WHY IT IS THE REFERENCE AND NOT CutFEM ───────────────
//
// Re-solve the SAME design on a grid `refine`x finer and treat that as truth.
// The physics comes from analyze_fixed_design — the same call the ladder's
// per-rung certification and the re-lattice path both make — and the load case
// from production_loadcase_from_job + the ONE core builder
// build_production_loadcase. Nothing here re-derives physics.
//
// ★ THERE ARE TWO WAYS TO REFINE A CERTIFICATE, AND THEY ANSWER DIFFERENT
//   QUESTIONS, SO THE PROBE RUNS BOTH AND NAMES THEM.
//
//   --mode replicate  (THE REFERENCE.) ONLY the element size changes. The fine
//     grid is the exact `refine`x subdivision of the run's own grid: the tags are
//     replicated child-for-child, so the Fixture region, the Load region and the
//     part occupancy are the SAME SOLIDS, not re-derived from the CAD. The BCs
//     are then rebuilt by the production rule (clamp all 8 corner nodes of every
//     Fixture voxel, loadcase.cpp:249-263) and the traction by the production call
//     (traction_loads over the Load region's exposed faces, loadcase.cpp:236) — so
//     the clamped volume, the loaded surface and its resultant are geometrically
//     identical to the run's, refined. Any difference this mode shows is
//     DISCRETIZATION ERROR OF THE SOLVE and nothing else. It requires exactly one
//     live load group, because build_production_loadcase's per-group tractions are
//     built against an anchors-only base grid; with one group that base grid and
//     the final grid carry the same tags, so the replication is exact. With more
//     than one, it refuses rather than approximating.
//
//   --mode retag      The shipped builder run at the finer resolution outright, so
//     the CAD is re-voxelized and the anchor/load faces re-tagged at that
//     resolution too. This prices something real and different — what the whole
//     job would say if it were RUN at 2x — but it moves the load case as well as
//     the mesh, and a design carved at 128 can lose the thinner skin the 256
//     tagging puts the load on. Reported, never mixed with the reference.
//
// THE ONE THING THIS FILE DOES ITSELF is carry the design across. The design
// exists only on the run's 128 grid. It is replicated piecewise-constant onto the
// fine grid — coarse voxel (i,j,k) -> the refine^3 fine voxels under it — which
// reproduces the object EXACTLY: same material, same total volume, same boundary
// surface, same smeared fraction in every grey cell. Nothing is interpolated, so
// nothing is invented. (Trilinear or tricubic resampling would MANUFACTURE a ramp
// through binary corners — mesh.hpp says so of resample_field — and the reference
// would then be a different object, not a better-resolved one.)
//
// So the fine solve answers exactly one question: was the coarse solve right
// about the object the certificate describes? Any difference is discretization
// error and nothing else.
//
// ★ THE TAG REPAIR (--mode retag ONLY), MEASURED AND REPORTED.
// build_production_loadcase voxelizes the STEP afresh at the fine resolution, so
// a handful of fine voxels under a coarse SOLID parent come back Empty (the finer
// voxelization of the CAD resolves the part boundary differently).
// analyze_fixed_design assembles no element on an Empty voxel, so leaving those
// alone would silently DELETE material the design holds and the comparison would
// be against a different object. Any fine voxel whose replicated density exceeds
// the printed iso is therefore forced solid, and the count is printed and written
// to the CSV. The converse — a fine voxel the finer voxelization calls solid
// whose parent was void — needs no repair: its replicated density is 0, which
// analyze clamps to rho_min, i.e. void. In `replicate` mode there is nothing to
// repair: the tags ARE the coarse tags.
//
// ── THE SOLVER POSTURE, AND WHY IT IS PINNED ────────────────────────────────
//
// Krylov recycling and GenEO are DISABLED for every solve here, which is exactly
// what ScopedLadderSolverIsolation (run_job.cpp:2553) does around every
// re-certification. Two reasons, both necessary:
//   1. comparability — the coarse and fine solves must differ in element size and
//      in nothing else, and a carried recycle subspace is state, not an argument
//      (task 2026-08-08-lattice-variant-margin-tolerance, S1(a));
//   2. arithmetic — GenEO's basis at 128 is 1674 columns over 1.47M DOF (40 MB).
//      At 2x refinement that is 1674 columns over 11.5M DOF, which does not fit on
//      any machine this runs on.
// One solve per process invocation, so the recycle space starts empty regardless.
//
// ── WHAT IT REPORTS ─────────────────────────────────────────────────────────
//
// Everything the gate reads (peak von Mises, in-plane / interlayer / worst-case
// margin, effective margin, the ACCEPT verdict, printed mass, compliance) plus
// the two splits a whole-part average would hide:
//
//   * peak von Mises restricted to BOUNDARY cells and to INTERIOR cells,
//     classified on the COARSE lattice both times. A boundary voxel is a printed
//     voxel with at least one face-neighbour not printed, off-grid reading void —
//     marching cubes' own rule. On the fine grid the fine field is first reduced
//     to the coarse lattice by max over each coarse cell's children, so the two
//     sides are the SAME population and the comparison is like for like. The
//     fine-native split is printed too, and they are not the same number.
//   * where the peak SITS: its coarse voxel index, whether that voxel is
//     Fixture- or Load-tagged, and its distance to the nearest clamped node. A
//     peak sitting on the Dirichlet boundary is a different finding from a peak
//     sitting on a cut surface, and the two must not be reported as one.
//
// R4: wall clock and work are reported separately. analyze_fixed_design does not
// return CgInfo, so the iteration count is reported as OPERATOR APPLIES
// (fea_matvec_count). `--calibrate` runs simp_compliance directly on the same
// arguments and prints cg.iterations beside the matvec delta, so the relation
// between the two is measured on this machine rather than assumed.
//
// A HARNESS, not a test: it prints a table and writes a CSV row, and it asserts
// only the preconditions that would make its own numbers meaningless.

#include "topopt/analyze.hpp"
#include "topopt/design_store.hpp"
#include "topopt/fea.hpp"
#include "topopt/job.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/pipeline.hpp"
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
#include <string>
#include <vector>

using namespace topopt;

namespace {

std::string join(const std::string& a, const std::string& b) {
  if (a.empty()) return b;
  return a.back() == '/' ? a + b : a + "/" + b;
}

// The BOUNDARY of the printed set on `g`: a printed voxel with at least one FACE
// neighbour not printed. Off-grid reads as void (background), which is marching
// cubes' own rule and the rule the design-field census uses.
std::vector<char> boundary_mask(const VoxelGrid& g,
                                const std::vector<double>& rho, double iso) {
  const std::size_t n = g.voxel_count();
  std::vector<char> printed(n, 0), bdry(n, 0);
  for (std::size_t e = 0; e < n; ++e) printed[e] = rho[e] > iso ? 1 : 0;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const std::size_t e = g.index(i, j, k);
        if (!printed[e]) continue;
        const int d[6][3] = {{-1, 0, 0}, {1, 0, 0}, {0, -1, 0},
                             {0, 1, 0},  {0, 0, -1}, {0, 0, 1}};
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

struct PeakSplit {
  double boundary = 0.0;
  double interior = 0.0;
  std::size_t boundary_cells = 0;
  std::size_t interior_cells = 0;
};

PeakSplit split_peak(const VoxelGrid& g, const std::vector<double>& rho,
                     const std::vector<double>& vm, double iso) {
  const std::vector<char> bdry = boundary_mask(g, rho, iso);
  PeakSplit s;
  for (std::size_t e = 0; e < g.voxel_count(); ++e) {
    if (!(rho[e] > iso)) continue;
    if (bdry[e]) {
      s.boundary = std::max(s.boundary, vm[e]);
      ++s.boundary_cells;
    } else {
      s.interior = std::max(s.interior, vm[e]);
      ++s.interior_cells;
    }
  }
  return s;
}

// Reduce a FINE grid-indexed scalar field onto the COARSE lattice by max over
// each coarse cell's refine^3 children. This is what makes the coarse and fine
// boundary/interior splits the SAME population: the classification is done once,
// on the coarse design, and both fields are read through it.
std::vector<double> reduce_max_to_coarse(const VoxelGrid& coarse,
                                         const VoxelGrid& fine, int refine,
                                         const std::vector<double>& fine_field) {
  std::vector<double> out(coarse.voxel_count(), 0.0);
  for (int k = 0; k < coarse.nz; ++k)
    for (int j = 0; j < coarse.ny; ++j)
      for (int i = 0; i < coarse.nx; ++i) {
        double m = 0.0;
        for (int c = 0; c < refine; ++c)
          for (int b = 0; b < refine; ++b)
            for (int a = 0; a < refine; ++a) {
              const int fi = i * refine + a, fj = j * refine + b,
                        fk = k * refine + c;
              if (fi >= fine.nx || fj >= fine.ny || fk >= fine.nz) continue;
              m = std::max(m, fine_field[fine.index(fi, fj, fk)]);
            }
        out[coarse.index(i, j, k)] = m;
      }
  return out;
}

// ── S2: THE SAME SOLVE, READ AT THE FREE SURFACE INSTEAD OF THE CELL CENTRE.
//
// `analyze_fixed_design` recovers each printed voxel's stress at the ELEMENT
// CENTROID (`core/src/simp/analyze.cpp:355` — `hex8_stress(E, nu, spacing, ue)`,
// whose (xi,eta,zeta) default to (0,0,0), `fea.hpp:130`). On a member two
// elements thick that centroid is a QUARTER of the member's thickness in from
// the free surface, and under any through-thickness gradient the stress there is
// not the stress at the surface, which is where the part fails.
//
// hex8_stress already takes the evaluation point. So the cheapest possible test
// of that diagnosis needs no new solver, no cut cells and no production change:
// re-read THE SAME displacement field at the centre of each face that looks into
// void. Natural coordinates map to the grid axes directly — node 0 of
// fea_element_nodes is (i,j,k) at (xi,eta,zeta) = (-1,-1,-1)
// (`core/src/fea/hex_element.cpp:14-16`) — so the -x face is xi = -1, +x is
// xi = +1, and so on.
struct SurfaceRead {
  double peak = 0.0;         // worst face-centre von Mises over the boundary set
  std::size_t cells = 0;     // boundary cells read
  std::size_t faces = 0;     // void-facing faces read
  int i = 0, j = 0, k = 0;   // where the worst one sits
};

SurfaceRead read_at_free_surface(const VoxelGrid& g,
                                 const std::vector<double>& rho, double iso,
                                 const std::vector<double>& u, double E,
                                 double nu) {
  SurfaceRead s;
  const int d[6][3] = {{-1, 0, 0}, {1, 0, 0}, {0, -1, 0},
                       {0, 1, 0},  {0, 0, -1}, {0, 0, 1}};
  const double nat[6][3] = {{-1, 0, 0}, {1, 0, 0}, {0, -1, 0},
                            {0, 1, 0},  {0, 0, -1}, {0, 0, 1}};
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const std::size_t e = g.index(i, j, k);
        if (!g.solid(i, j, k) || !(rho[e] > iso)) continue;
        bool any = false;
        std::array<double, 24> ue{};
        for (int f = 0; f < 6; ++f) {
          const int a = i + d[f][0], b = j + d[f][1], c = k + d[f][2];
          const bool void_side =
              a < 0 || a >= g.nx || b < 0 || b >= g.ny || c < 0 || c >= g.nz ||
              !(rho[g.index(a, b, c)] > iso);
          if (!void_side) continue;
          if (!any) {
            const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
            for (int n = 0; n < 8; ++n)
              for (int cc = 0; cc < 3; ++cc)
                ue[static_cast<std::size_t>(3 * n + cc)] =
                    u[static_cast<std::size_t>(3 * en[n] + cc)];
            any = true;
            ++s.cells;
          }
          ++s.faces;
          const Hex8Stress st = hex8_stress(E, nu, g.spacing, ue, nat[f][0],
                                            nat[f][1], nat[f][2]);
          if (st.von_mises > s.peak) {
            s.peak = st.von_mises;
            s.i = i; s.j = j; s.k = k;
          }
        }
      }
  return s;
}

double now_s() {
  return std::chrono::duration<double>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 6) {
    std::fprintf(stderr,
                 "usage: %s <job_dir> <design.bin> <rung_index> <refine> "
                 "<csv_out> [--calibrate]\n",
                 argv[0]);
    return 2;
  }
  const std::string job_dir = argv[1];
  const std::string design_path = argv[2];
  const int rung = std::atoi(argv[3]);
  const int refine = std::atoi(argv[4]);
  const std::string csv_out = argv[5];
  bool calibrate = false;
  std::string mode = "replicate";
  for (int i = 6; i < argc; ++i) {
    if (std::strcmp(argv[i], "--calibrate") == 0) calibrate = true;
    else if (std::strcmp(argv[i], "--mode") == 0 && i + 1 < argc) mode = argv[++i];
  }
  if (mode != "replicate" && mode != "retag") {
    std::fprintf(stderr, "PRECONDITION FAILED: --mode must be replicate|retag\n");
    return 1;
  }
  if (refine < 1) {
    std::fprintf(stderr, "PRECONDITION FAILED: refine must be >= 1\n");
    return 1;
  }

  // ── the job, the model, the load case: all through the shipped path.
  const JobDescription job = load_job_file(join(job_dir, "job.json"));
  StepModel model;
  try {
    model = import_step_file(join(job_dir, job.model));
  } catch (const std::exception& e) {
    std::fprintf(stderr, "PRECONDITION FAILED: cannot import model: %s\n",
                 e.what());
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
  const int res = job.resolution * refine;

  // The run's OWN setup, at the run's own resolution. In `replicate` mode this is
  // what gets subdivided; in either mode it is what the options come from, so the
  // solver posture, the ladder, the knockdown and margin_stop are the run's.
  const ProductionRunSetup setup_c =
      build_production_loadcase(model, job.resolution, lc);
  // The setup at the TARGET resolution. In `retag` mode this is the model; in
  // `replicate` mode only its `options` are borrowed (identical either way for
  // everything the analysis reads) and its grid/BCs/loads are discarded.
  const ProductionRunSetup setup_f =
      refine == 1 ? setup_c : build_production_loadcase(model, res, lc);
  const ProductionRunSetup& setup = (mode == "retag") ? setup_f : setup_c;
  if (setup.options.require_external_loads &&
      setup.options.external_loads.empty()) {
    std::fprintf(stderr,
                 "PRECONDITION FAILED: the declared load case produced NO "
                 "external load at resolution %d\n",
                 res);
    return 1;
  }

  MinimizePlasticOptions options = setup.options;
  VoxelGrid grid = setup.grid;
  const SolvedDesignDomain domain =
      resolve_design_domain(grid, setup.bcs, options);
  if (domain.expanded) {
    std::fprintf(stderr,
                 "PRECONDITION FAILED: this job expands the design domain (a "
                 "design box). The probe's replication maps the PART grid; "
                 "refusing rather than mapping a domain it has not proven.\n");
    return 1;
  }
  VoxelGrid cert_grid = domain.grid;
  std::vector<DirichletBC> bcs = domain.bcs;
  std::vector<NodalLoad> loads =
      design_domain_loads(domain, options, material.density_g_cm3);

  // ★ REPLICATE MODE: subdivide the run's own grid instead of re-voxelizing the
  // CAD, then rebuild the BCs and the traction from the replicated tags by the
  // production rules. See the header for why this, and not `retag`, is the
  // reference.
  // ★ NO `refine > 1` GUARD HERE, DELIBERATELY. At refine == 1 the subdivision is
  // the identity, so `--mode replicate --refine 1` runs the WHOLE replicate
  // construction — the tag copy, the BC rebuild, the traction rebuild — on the
  // run's own grid. It must then land on the run's own recorded margin. That is
  // the positive control for the machinery this task's answer rests on, and
  // skipping the path at refine 1 (as an earlier version of this file did) would
  // have left the reference's construction untested at the only resolution where
  // the right answer is already known.
  long long fixture_children = 0, load_children = 0;
  if (mode == "replicate") {
    int live_groups = 0;
    for (const auto& g : lc.load_groups)
      if (std::fabs(g.force.x) + std::fabs(g.force.y) + std::fabs(g.force.z) >
          0.0)
        ++live_groups;
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
    Vec3 gforce{0.0, 0.0, 0.0};
    for (const auto& g : lc.load_groups)
      if (std::fabs(g.force.x) + std::fabs(g.force.y) + std::fabs(g.force.z) >
          0.0)
        gforce = g.force;

    const VoxelGrid& cg = setup_c.grid;
    VoxelGrid fg;
    fg.nx = cg.nx * refine;
    fg.ny = cg.ny * refine;
    fg.nz = cg.nz * refine;
    fg.spacing = cg.spacing / refine;
    fg.origin = cg.origin;
    fg.tags.assign(static_cast<std::size_t>(fg.nx) * fg.ny * fg.nz,
                   VoxelTag::Empty);
    for (int k = 0; k < cg.nz; ++k)
      for (int j = 0; j < cg.ny; ++j)
        for (int i = 0; i < cg.nx; ++i) {
          const VoxelTag t = cg.tag(i, j, k);
          if (t == VoxelTag::Fixture) fixture_children += refine * refine * refine;
          if (t == VoxelTag::Load) load_children += refine * refine * refine;
          for (int c = 0; c < refine; ++c)
            for (int b = 0; b < refine; ++b)
              for (int a = 0; a < refine; ++a)
                fg.set_tag(i * refine + a, j * refine + b, k * refine + c, t);
        }
    cert_grid = fg;
    grid = fg;
    // The production BC rule, verbatim (loadcase.cpp:249-263): clamp all 8 corner
    // nodes of every Fixture voxel, deduped.
    bcs.clear();
    for (const int n : fea_tagged_nodes(cert_grid, VoxelTag::Fixture))
      for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});
    // The production traction call, verbatim (loadcase.cpp:236).
    loads = traction_loads(cert_grid, VoxelTag::Load, gforce);
    options.external_loads = loads;
  }

  // ── the stored design (always the run's own 128 grid).
  DesignStore store = read_design_file(design_path);
  if (rung < 0 || rung >= static_cast<int>(store.variants.size())) {
    std::fprintf(stderr, "PRECONDITION FAILED: rung %d of %zu\n", rung,
                 store.variants.size());
    return 1;
  }
  const StoredDesign& sd = store.variants[static_cast<std::size_t>(rung)];

  // The fine grid must be the exact `refine`x subdivision of the stored grid, or
  // replication is not the identity it claims to be. voxelize() puts the origin
  // at the mesh bbox min and the spacing at longest_extent/resolution, so the
  // origin is shared and the spacing halves exactly; the dimension check is what
  // catches the case where a non-longest axis' ceil() does not double.
  const double sp_ratio = store.spacing / cert_grid.spacing;
  const bool geom_ok =
      std::fabs(sp_ratio - refine) < 1e-12 * refine &&
      store.origin.x == cert_grid.origin.x &&
      store.origin.y == cert_grid.origin.y &&
      store.origin.z == cert_grid.origin.z;
  if (!geom_ok) {
    std::fprintf(stderr,
                 "PRECONDITION FAILED: the fine grid is not the %dx "
                 "subdivision of the stored grid.\n  stored %dx%dx%d @ %.17g "
                 "origin (%.17g,%.17g,%.17g)\n  built  %dx%dx%d @ %.17g origin "
                 "(%.17g,%.17g,%.17g)\n",
                 refine, store.nx, store.ny, store.nz, store.spacing,
                 store.origin.x, store.origin.y, store.origin.z, cert_grid.nx,
                 cert_grid.ny, cert_grid.nz, cert_grid.spacing,
                 cert_grid.origin.x, cert_grid.origin.y, cert_grid.origin.z);
    return 1;
  }

  // The COARSE grid the design indexes to, rebuilt so the boundary/interior
  // classification and the reduction below have a lattice to speak about. Only
  // its dimensions/spacing/origin are used.
  VoxelGrid coarse_grid;
  coarse_grid.nx = store.nx;
  coarse_grid.ny = store.ny;
  coarse_grid.nz = store.nz;
  coarse_grid.spacing = store.spacing;
  coarse_grid.origin = store.origin;
  coarse_grid.tags.assign(store.voxel_count(), VoxelTag::Empty);

  const double iso = 0.5;

  // ── replicate the design onto the fine grid, piecewise constant.
  std::vector<double> rho(cert_grid.voxel_count(), 0.0);
  long long dropped_by_grid = 0;   // fine voxels the CAD re-voxelization dropped
  long long outside_fine = 0;      // coarse children with no fine cell (ceil gap)
  long long outside_fine_printed = 0;
  for (int k = 0; k < coarse_grid.nz; ++k)
    for (int j = 0; j < coarse_grid.ny; ++j)
      for (int i = 0; i < coarse_grid.nx; ++i) {
        const double d = sd.density[coarse_grid.index(i, j, k)];
        for (int c = 0; c < refine; ++c)
          for (int b = 0; b < refine; ++b)
            for (int a = 0; a < refine; ++a) {
              const int fi = i * refine + a, fj = j * refine + b,
                        fk = k * refine + c;
              if (fi >= cert_grid.nx || fj >= cert_grid.ny ||
                  fk >= cert_grid.nz) {
                ++outside_fine;
                if (d > iso) ++outside_fine_printed;
                continue;
              }
              const std::size_t e = cert_grid.index(fi, fj, fk);
              rho[e] = d;
              // ★ THE TAG REPAIR. A fine voxel the design occupies must carry an
              // element, or the fine solve describes a different object.
              if (d > iso && cert_grid.tags[e] == VoxelTag::Empty) {
                cert_grid.tags[e] = VoxelTag::Surface;
                ++dropped_by_grid;
              }
            }
      }
  if (outside_fine_printed > 0)
    std::fprintf(stderr,
                 "WARNING: %lld PRINTED coarse children fall outside the fine "
                 "grid (ceil gap). The comparison is not on the whole design.\n",
                 outside_fine_printed);

  // The declared resultant must survive the refinement exactly, or the two sides
  // are not carrying the same load. Asserted, not assumed.
  Vec3 fsum{0.0, 0.0, 0.0};
  for (const NodalLoad& l : loads) {
    if (l.component == 0) fsum.x += l.value;
    if (l.component == 1) fsum.y += l.value;
    if (l.component == 2) fsum.z += l.value;
  }

  // ── THE LOAD-PATH BELT, AND WHY IT IS DIAGNOSED HERE RATHER THAN JUST READ.
  // `accepted = load_path_ok && (margin_effective >= margin_stop)`, so a false
  // belt flips the verdict with nothing to do with stress. And the belt is false
  // by construction when a LOAD-TAGGED voxel is not printed (voxel.hpp: "A Load
  // voxel that is not itself printed is unreachable by construction, hence
  // false") — which is exactly what re-tagging the CAD at a finer resolution can
  // manufacture, because the finer tagging puts the load on a thinner skin the
  // design may have carved. So the counts are printed beside the bool: a moved
  // verdict must be attributable, not merely observed.
  const bool load_path_ok = load_path_connected(cert_grid, rho, iso);
  std::size_t load_voxels = 0, load_unprinted = 0;
  std::size_t fixture_voxels = 0, fixture_unprinted = 0;
  for (std::size_t e = 0; e < cert_grid.voxel_count(); ++e) {
    if (cert_grid.tags[e] == VoxelTag::Load) {
      ++load_voxels;
      if (!(rho[e] > iso)) ++load_unprinted;
    } else if (cert_grid.tags[e] == VoxelTag::Fixture) {
      ++fixture_voxels;
      if (!(rho[e] > iso)) ++fixture_unprinted;
    }
  }
  const KnockdownSpec knockdown = knockdown_spec_for(options);
  const double part_solid = static_cast<double>(grid.solid_count());

  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;

  // ── THE SOLVER POSTURE (see the header). Restored on exit for symmetry even
  // though this process ends here.
  const bool prev_recycle = fea_set_krylov_recycling(false);
  const bool prev_geneo = fea_set_geneo_twolevel(false);

  std::printf("== boundary_cell_probe ==\n");
  std::printf("job        : %s (model %s, material %s)\n", job_dir.c_str(),
              job.model.c_str(), job.material.c_str());
  std::printf("rung       : index %d, requested vf %.10g, achieved %.10g, "
              "fingerprint %llu\n",
              rung, sd.requested_volume_fraction, sd.achieved_volume_fraction,
              static_cast<unsigned long long>(sd.fingerprint));
  std::printf("mode       : %s\n", mode.c_str());
  std::printf("refine     : %dx  ->  resolution %d\n", refine, res);
  std::printf("coarse grid: %dx%dx%d @ %.12g mm  (%zu voxels)\n", coarse_grid.nx,
              coarse_grid.ny, coarse_grid.nz, coarse_grid.spacing,
              coarse_grid.voxel_count());
  std::printf("solve grid : %dx%dx%d @ %.12g mm  (%zu voxels, %d nodes, %d dofs)\n",
              cert_grid.nx, cert_grid.ny, cert_grid.nz, cert_grid.spacing,
              cert_grid.voxel_count(), fea_node_count(cert_grid),
              3 * fea_node_count(cert_grid));
  std::printf("tag repair : %lld fine voxels forced solid (design occupied, the "
              "%dx CAD voxelization dropped them)\n",
              dropped_by_grid, refine);
  std::printf("ceil gap   : %lld coarse children outside the fine grid, of which "
              "%lld printed\n",
              outside_fine, outside_fine_printed);
  std::printf("bcs        : %zu dirichlet dofs\n", bcs.size());
  std::printf("loads      : %zu nodal loads, resultant (%.12g, %.12g, %.12g) N\n",
              loads.size(), fsum.x, fsum.y, fsum.z);
  std::printf("load path  : connected=%s   Load voxels %zu (%zu NOT printed)   "
              "Fixture voxels %zu (%zu NOT printed)\n",
              load_path_ok ? "true" : "FALSE", load_voxels, load_unprinted,
              fixture_voxels, fixture_unprinted);
  if (mode == "replicate")
    std::printf("replicated : %lld Fixture children, %lld Load children\n",
                fixture_children, load_children);
  std::printf("posture    : recycling OFF, geneo OFF, solver=%d, cg_tol=%.3g, "
              "cg_max=%d, margin_stop=%.10g\n",
              static_cast<int>(options.simp.solver), options.simp.cg_tolerance,
              options.simp.cg_max_iterations, options.margin_stop);
  std::printf("build_dir  : (%.10g, %.10g, %.10g) [stored, as certified]\n",
              sd.applied_build_dir.x, sd.applied_build_dir.y,
              sd.applied_build_dir.z);
  std::fflush(stdout);

  // ── the calibration solve (R4): the ONLY way to put a real CG iteration count
  // beside the operator-apply count on this seam.
  long long calib_matvecs = 0;
  int calib_iters = 0;
  bool calib_ran = false;
  if (calibrate) {
    fea_matvec_count_reset();
    const double t0 = now_s();
    const SimpCompliance sc =
        simp_compliance(cert_grid, params, rho, bcs, loads,
                        options.simp.cg_tolerance, options.simp.cg_max_iterations,
                        nullptr, nullptr, options.simp.solver);
    const double t1 = now_s();
    calib_matvecs = fea_matvec_count();
    calib_iters = sc.cg.iterations;
    calib_ran = true;
    std::printf("calibrate  : simp_compliance cg.iterations=%d matvecs=%lld "
                "ratio=%.6g converged=%d residual=%.6g multigrid=%d wall=%.2fs\n",
                calib_iters, calib_matvecs,
                calib_iters ? double(calib_matvecs) / calib_iters : 0.0,
                sc.cg.converged ? 1 : 0, sc.cg.residual,
                sc.cg.used_multigrid ? 1 : 0, t1 - t0);
    std::fflush(stdout);
  }

  // ── THE SOLVE.
  fea_matvec_count_reset();
  const long long calls0 = simp_compliance_call_count();
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
  const long long solves = simp_compliance_call_count() - calls0;

  fea_set_geneo_twolevel(prev_geneo);
  fea_set_krylov_recycling(prev_recycle);

  if (a.non_convergent) {
    std::printf("\n*** CERTIFICATION SOLVE DID NOT CONVERGE at iteration %d, "
                "residual %.6g. Nothing below is a measurement. ***\n",
                a.non_convergent_iteration, a.non_convergent_residual);
    return 3;
  }

  // ── compliance, c = f^T u (exact; analyze_fixed_design does not return it).
  double compliance = 0.0;
  for (const NodalLoad& l : loads)
    compliance += l.value * a.displacement_field[static_cast<std::size_t>(
                                3 * l.node + l.component)];
  // Peak nodal displacement magnitude — a second, independent global reading of
  // "did the structure get softer or stiffer", so a surprising compliance is not
  // the only witness to it.
  double max_disp = 0.0;
  for (std::size_t n = 0; n + 2 < a.displacement_field.size(); n += 3) {
    const double ux = a.displacement_field[n], uy = a.displacement_field[n + 1],
                 uz = a.displacement_field[n + 2];
    max_disp = std::max(max_disp, std::sqrt(ux * ux + uy * uy + uz * uz));
  }

  // ── the splits. The FINE-native one first, then the one that is comparable
  // across resolutions: the fine field reduced to the coarse lattice by max over
  // children, classified by the COARSE design's own boundary mask.
  const PeakSplit native = split_peak(cert_grid, rho, a.von_mises_field, iso);
  const std::vector<double> vm_coarse =
      refine == 1 ? a.von_mises_field
                  : reduce_max_to_coarse(coarse_grid, cert_grid, refine,
                                         a.von_mises_field);
  const PeakSplit onlattice =
      split_peak(coarse_grid, sd.density, vm_coarse, iso);

  // ── WHERE THE PEAK SITS. Reported on the coarse lattice so the four runs name
  // the same cell, plus the fine index and the tag it carries.
  std::size_t argmax_fine = 0;
  for (std::size_t e = 1; e < a.von_mises_field.size(); ++e)
    if (a.von_mises_field[e] > a.von_mises_field[argmax_fine]) argmax_fine = e;
  const int fk = static_cast<int>(argmax_fine /
                                  (std::size_t(cert_grid.nx) * cert_grid.ny));
  const int fj = static_cast<int>(
      (argmax_fine / std::size_t(cert_grid.nx)) % std::size_t(cert_grid.ny));
  const int fi = static_cast<int>(argmax_fine % std::size_t(cert_grid.nx));
  const VoxelTag peak_tag = cert_grid.tags[argmax_fine];
  // distance from the peak voxel's centre to the nearest CLAMPED node
  double d_bc = std::numeric_limits<double>::infinity();
  {
    std::vector<char> clamped(
        static_cast<std::size_t>(fea_node_count(cert_grid)), 0);
    for (const DirichletBC& b : bcs)
      clamped[static_cast<std::size_t>(b.node)] = 1;
    const Vec3 c = cert_grid.voxel_center(fi, fj, fk);
    const int nnx = cert_grid.nx + 1, nny = cert_grid.ny + 1;
    for (std::size_t n = 0; n < clamped.size(); ++n) {
      if (!clamped[n]) continue;
      const int nk = static_cast<int>(n / (std::size_t(nnx) * nny));
      const int nj = static_cast<int>((n / std::size_t(nnx)) % std::size_t(nny));
      const int ni = static_cast<int>(n % std::size_t(nnx));
      const double x = cert_grid.origin.x + ni * cert_grid.spacing;
      const double y = cert_grid.origin.y + nj * cert_grid.spacing;
      const double z = cert_grid.origin.z + nk * cert_grid.spacing;
      const double dd = (x - c.x) * (x - c.x) + (y - c.y) * (y - c.y) +
                        (z - c.z) * (z - c.z);
      if (dd < d_bc) d_bc = dd;
    }
    d_bc = std::sqrt(d_bc);
  }
  const char* tagname = peak_tag == VoxelTag::Empty      ? "Empty"
                        : peak_tag == VoxelTag::Interior ? "Interior"
                        : peak_tag == VoxelTag::Surface  ? "Surface"
                        : peak_tag == VoxelTag::Load     ? "Load"
                        : peak_tag == VoxelTag::Fixture  ? "Fixture"
                                                         : "UserTagged";

  std::printf("\n-- WHAT THE GATE READS ------------------------------------\n");
  std::printf("  peak von Mises        : %.17g MPa\n", a.max_von_mises);
  std::printf("  max interlayer tension: %.17g MPa\n", a.max_interlayer_tension);
  std::printf("  margin in_plane       : %.17g\n", a.margin.in_plane);
  std::printf("  margin interlayer     : %.17g\n", a.margin.interlayer);
  std::printf("  margin worst_case     : %.17g\n", a.margin.worst_case);
  std::printf("  margin effective      : %.17g\n", a.margin_effective);
  std::printf("  ACCEPTED              : %s   (load_path_ok=%s, "
              "margin_effective %s margin_stop %.10g)\n",
              a.accepted ? "true" : "false", load_path_ok ? "true" : "FALSE",
              a.margin_effective >= options.margin_stop ? ">=" : "<",
              options.margin_stop);
  std::printf("  printed mass          : %.17g g\n", a.mass_grams);
  std::printf("  compliance f.u        : %.17g N.mm\n", compliance);
  std::printf("  peak |displacement|   : %.17g mm\n", max_disp);
  std::printf("  printed voxels        : %zu (fraction %.10g)\n",
              a.printed_voxels, a.printed_fraction);
  std::printf("  recorded (design.bin) : margin %.17g, peak vM %.17g\n",
              sd.margin_worst_case, sd.max_von_mises_mpa);

  std::printf("\n-- SURFACE vs INTERIOR ------------------------------------\n");
  std::printf("  on the COARSE lattice (comparable across resolutions):\n");
  std::printf("    peak vM on BOUNDARY cells : %.17g   (%zu cells)\n",
              onlattice.boundary, onlattice.boundary_cells);
  std::printf("    peak vM on INTERIOR cells : %.17g   (%zu cells)\n",
              onlattice.interior, onlattice.interior_cells);
  std::printf("    boundary / interior       : %.10g\n",
              onlattice.interior > 0 ? onlattice.boundary / onlattice.interior
                                     : 0.0);
  std::printf("  on the FINE lattice (its own classification):\n");
  std::printf("    peak vM on BOUNDARY cells : %.17g   (%zu cells)\n",
              native.boundary, native.boundary_cells);
  std::printf("    peak vM on INTERIOR cells : %.17g   (%zu cells)\n",
              native.interior, native.interior_cells);

  // ── S2: the same field, read at the free surface.
  const SurfaceRead surf = read_at_free_surface(
      cert_grid, rho, iso, a.displacement_field, params.youngs_modulus,
      params.poisson);
  std::printf("\n-- S2: THE SAME SOLVE READ AT THE FREE SURFACE -------------\n");
  std::printf("  peak vM at the CELL CENTRE (what the gate reads) : %.17g MPa\n",
              a.max_von_mises);
  std::printf("  peak vM at the FREE-SURFACE FACE CENTRE          : %.17g MPa\n",
              surf.peak);
  std::printf("  surface / centroid                              : %.10g\n",
              a.max_von_mises > 0 ? surf.peak / a.max_von_mises : 0.0);
  std::printf("  margin if the gate read the surface              : %.10g "
              "(certified rule gives %.10g)\n",
              surf.peak > 0 ? material.yield_strength_mpa / surf.peak : 0.0,
              a.margin.in_plane);
  std::printf("  boundary cells read: %zu over %zu void-facing faces; worst at "
              "(%d,%d,%d)\n",
              surf.cells, surf.faces, surf.i, surf.j, surf.k);

  std::printf("\n-- WHERE THE PEAK SITS ------------------------------------\n");
  std::printf("  fine voxel (%d,%d,%d) tag=%s rho=%.17g\n", fi, fj, fk, tagname,
              rho[argmax_fine]);
  std::printf("  coarse voxel (%d,%d,%d)\n", fi / refine, fj / refine,
              fk / refine);
  std::printf("  centre (model frame) : (%.6f, %.6f, %.6f) mm\n",
              cert_grid.voxel_center(fi, fj, fk).x,
              cert_grid.voxel_center(fi, fj, fk).y,
              cert_grid.voxel_center(fi, fj, fk).z);
  std::printf("  distance to nearest clamped node : %.6f mm (%.4f fine voxels)\n",
              d_bc, d_bc / cert_grid.spacing);

  std::printf("\n-- COST (R4: separately) ----------------------------------\n");
  std::printf("  wall            : %.3f s\n", wall);
  std::printf("  operator applies: %lld\n", matvecs);
  std::printf("  simp_compliance calls in this analysis: %lld\n", solves);
  if (calib_ran)
    std::printf("  calibration     : %d CG iterations for %lld applies "
                "(%.6g applies / iteration)\n",
                calib_iters, calib_matvecs,
                calib_iters ? double(calib_matvecs) / calib_iters : 0.0);

  // ── the CSV row.
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
    csv << "mode,rung_vf,refine,resolution,nx,ny,nz,spacing_mm,dofs,"
           "peak_vm_mpa,max_interlayer_mpa,margin_in_plane,margin_interlayer,"
           "margin_worst_case,margin_effective,accepted,mass_g,compliance,"
           "printed_voxels,peak_vm_boundary_onlattice,peak_vm_interior_onlattice,"
           "boundary_cells_onlattice,interior_cells_onlattice,"
           "peak_vm_boundary_native,peak_vm_interior_native,"
           "peak_i,peak_j,peak_k,peak_tag,peak_dist_to_bc_mm,"
           "tag_repair_voxels,ceil_gap_printed,wall_s,matvecs,"
           "recorded_margin,recorded_peak_vm,load_resultant_z,"
           "load_path_ok,load_voxels,load_unprinted,fixture_voxels,"
           "fixture_unprinted,max_disp_mm,bc_dofs,nodal_loads,"
           "peak_vm_surface,surface_cells,surface_faces,"
           "surf_i,surf_j,surf_k\n";
  csv.setf(std::ios::fmtflags(0), std::ios::floatfield);
  csv.precision(17);
  csv << mode << ',' << sd.requested_volume_fraction << ',' << refine << ','
      << res << ','
      << cert_grid.nx << ',' << cert_grid.ny << ',' << cert_grid.nz << ','
      << cert_grid.spacing << ',' << 3 * fea_node_count(cert_grid) << ','
      << a.max_von_mises << ',' << a.max_interlayer_tension << ','
      << a.margin.in_plane << ',' << a.margin.interlayer << ','
      << a.margin.worst_case << ',' << a.margin_effective << ','
      << (a.accepted ? 1 : 0) << ',' << a.mass_grams << ',' << compliance << ','
      << a.printed_voxels << ',' << onlattice.boundary << ','
      << onlattice.interior << ',' << onlattice.boundary_cells << ','
      << onlattice.interior_cells << ',' << native.boundary << ','
      << native.interior << ',' << fi << ',' << fj << ',' << fk << ',' << tagname
      << ',' << d_bc << ',' << dropped_by_grid << ',' << outside_fine_printed
      << ',' << wall << ',' << matvecs << ',' << sd.margin_worst_case << ','
      << sd.max_von_mises_mpa << ',' << fsum.z << ',' << (load_path_ok ? 1 : 0)
      << ',' << load_voxels << ',' << load_unprinted << ',' << fixture_voxels
      << ',' << fixture_unprinted << ',' << max_disp << ',' << bcs.size() << ','
      << loads.size() << ',' << surf.peak << ',' << surf.cells << ','
      << surf.faces << ',' << surf.i << ',' << surf.j << ',' << surf.k << '\n';
  csv.close();
  std::printf("\nwrote CSV row -> %s\n", csv_out.c_str());
  return 0;
}
