// plsm_probe — ARM 1 of task 2026-08-10-parametric-level-set: THE GATE.
//
// ★ ONE QUESTION. Is the roughness in the REPRESENTATION or in the DESIGN?
//
// PR 322/323/324/325 all stored φ as ONE NUMBER PER VOXEL on the fixed grid.
// That is a DISCRETE level set: sub-voxel placement, but not resolution-free.
// A PARAMETRIC level set (Wang & Wang; Wei, Li, Wang & Gao's 88-line code) writes
//
//     φ(x) = Σ_i α_i ψ_i(x)
//
// — an ANALYTIC function of x, evaluable at ANY point, whose design variables are
// the RBF coefficients, far fewer than voxels, each with support spanning many.
// THAT is the vector graphic. Whether it is worth a rewrite is what this program
// measures, WITHOUT doing the rewrite: fit that analytic φ to a design we ALREADY
// HAVE, extract the surface FROM THE FUNCTION, and measure it on our instruments.
//
// ★ R5 — NOTHING IS RE-OPTIMISED HERE. This program contains no FEA, no
// sensitivity, no velocity and no time step. It reads a converged occupancy off
// disk, turns it into a signed distance with `levelset_kernel.hpp`'s OWN
// reinitialisation (the same one the `--simp` seed uses — the header exists so
// there is not a second copy), fits, and writes fields out. Every NUMBER in the
// handoff is produced by `external_field_surface_probe` and by
// `analyze_fixed_design` through `levelset_probe --certify-field`, both invoked
// as separate binaries on the fields this one writes.
//
// ── THE MEASUREMENT TRAP THIS FILE EXISTS TO AVOID, AND THE ONE IT INTRODUCES ─
//
// (a) THE FALSE NEGATIVE the task names. Evaluating the fitted φ at voxel centres
//     and running marching cubes reintroduces exactly the quantisation under
//     test. So the emitted fields are evaluated ANALYTICALLY on a REFINED lattice
//     — sample (m,·,·) of an F-refined lattice sits at
//     origin + (m + 0.5) * (h/F), which is EXACTLY where `resample_field` puts
//     its factor-F sample (mesh.cpp: u = (m+0.5)/F - 0.5, then
//     marching_cubes(nx*F, ..., h/F, origin, ...)). The fine lattice is passed to
//     `external_field_surface_probe` with `factor 1` / `interp none`, so that
//     probe extracts the ANALYTIC surface and interpolates nothing.
//
// (b) ★ THE FALSE POSITIVE THAT (a) CREATES, WHICH THE TASK DOES NOT NAME.
//     `dihedral_rms_deg` is RESOLUTION-DEPENDENT. On a smooth surface the
//     dihedral angle between adjacent triangles scales like κ·h, so extracting
//     ANYTHING on a finer lattice lowers it. Reporting an F=4 analytic surface
//     against SIMP's shipped F=2 surface would measure the lattice, not the
//     representation, and would open the gate on nothing.
//
//     ★ SO EVERY ROW IS EMITTED AT EVERY FACTOR AND COMPARED ONLY WITHIN A
//     COLUMN OF CONSTANT F. `--emit-source` writes the SOURCE occupancy
//     tricubically resampled to the same F by core's own `resample_field`, so
//     each factor carries its own voxel-representation control, and the SIMP rows
//     are re-extracted at the same F too (`--emit-extra`). If refining lifts the
//     voxel rows as much as it lifts the analytic one, the gate is CLOSED and the
//     table says so on its face.
//
// ── R4: PER AXIS, NOT MINIMUM ────────────────────────────────────────────────
//
// The slab trap cost PR 324 a day: GridapTopOpt's α rule reads
// `minimum(el_size)`, which on his 128 x 31 x 118 slab reads the THIN axis and
// sizes a length scale for a 31³ mesh. EVERY length in this program is per axis:
//
//   * knot spacing is `--knots dx,dy,dz` — THREE numbers, never one derived from
//     a minimum. The knot COUNT per axis follows the axis extent.
//   * the support radius is an ELLIPSOID, R_a = support * Δ_a per axis, so an
//     anisotropic knot lattice gets an anisotropic support and the basis stays
//     matched to the lattice it sits on. With Δ isotropic it reduces to the
//     ordinary isotropic CSRBF, which is the case the papers write.
//   * `--knots-min` REPRODUCES THE TRAP DELIBERATELY, deriving one spacing from
//     the thin axis, so its cost is measured rather than avoided by assertion.
//
// Lengths are carried in VOXELS throughout and converted to mm once, at the end.
// His grid is isotropic in spacing (h = 1.705279 mm on all three axes) and
// anisotropic only in EXTENT, so voxel units are exact and no unit can slip.
//
// ── THE FIT ──────────────────────────────────────────────────────────────────
//
// Least squares over every voxel, with the target φ CLAMPED to ±`--clamp`
// voxels. Clamping is not a cosmetic: `reinitialise` writes ±1e6 into cells the
// sweep never reached, and only the zero set of φ has any geometric meaning — a
// fit that spends its coefficients matching a 1e6 far field would be a fit of
// nothing. The residual is reported BOTH over the band and over the whole domain
// so the clamp cannot hide behind an average.
//
//     minimise  ‖A α − φ̃‖²  +  λ ‖α‖²
//
// solved by Jacobi-preconditioned CG on the normal equations, matrix-free in the
// normal matrix and explicit in A (CSR, plus its transpose, both built once).
// nnz(A) is n_samples * (knots in one support) and depends on the SUPPORT, not on
// the knot spacing, so memory is the same for every point of the spacing sweep.
// λ is not optional: knots over the void carry no data at all and would be free
// directions in an otherwise singular system.
//
// ── THE TWO BASES, AND WHY BOTH ─────────────────────────────────────────────
//
//   wendland   ψ(r) = (1−r)₊⁴ (4r+1), Wendland's C² CSRBF — the standard choice,
//              positive definite in 3D, compactly supported, sparse.
//   gaussian   ψ(r) = exp(−(3r)²/2), the globally-supported basis iPLSM uses,
//              TRUNCATED at r = 1 (i.e. 3σ). ★ THE TRUNCATION IS STATED, NOT
//              HIDDEN: a genuinely global basis over 10⁴ knots and 4.7×10⁵
//              samples is a dense 5×10⁹-entry operator, and 3σ carries 99.7% of
//              the mass. iPLSM's own warning is that CSRBF "sacrifices accuracy
//              for efficiency", so the comparison is worth having; a 3σ Gaussian
//              is a fair stand-in for it and a 3σ Gaussian is what is reported.
//
// ── VOLUME ──────────────────────────────────────────────────────────────────
//
// PR 323 §7: the level-set meshes enclose ~371,600 mm³ against SIMP's 440,551 at
// nominally the same achieved vf, so a roughness number without a volume beside
// it is comparing different objects. Every emitted field therefore comes in two
// flavours: AS FITTED, and VOLUME-MATCHED — a constant offset c on φ, bisected so
// that #{φ+c < 0} on the voxel lattice equals #{φ_src < 0} exactly. The offset is
// a rigid move of the level set and nothing else; a signed distance plus a
// constant is still a signed distance.
//
//   cmake --build build --target plsm_probe
//   ./build/plsm_probe <src_prefix> <out_dir> [options]
//
// `<src_prefix>.f64` + `<src_prefix>.meta` is exactly what
// `external_field_surface_probe` reads and what `levelset_probe` writes.

#include "topopt/mesh.hpp"
// ★ AT FILE SCOPE, DELIBERATELY. `plsm_basis.hpp` below is a SHIM over this
// header and is included from inside an anonymous namespace; core's basis must
// keep EXTERNAL linkage so this probe and the production optimiser share one
// definition of the function they fit.
#include "topopt/plsm_basis.hpp"
#include "topopt/plsm_kernel.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using namespace topopt;

namespace {

// The field kernel — `reinitialise` above all — INCLUDED, not retyped. Same
// header `levelset_probe.cpp` includes, from inside its anonymous namespace too.
#include "levelset_kernel.hpp"

// ── the source field's own description, as external_field_surface_probe reads it
struct Meta {
  std::string rung = "0.68";
  int nx = 0, ny = 0, nz = 0;
  double spacing = 0.0, ox = 0.0, oy = 0.0, oz = 0.0;
  double iso = 0.5;
  double achieved_vf = 0.0;
};

Meta read_meta(const std::string& path) {
  Meta m;
  std::ifstream in(path);
  if (!in) {
    std::printf("FATAL: cannot read %s\n", path.c_str());
    std::exit(2);
  }
  std::string line;
  while (std::getline(in, line)) {
    std::istringstream ls(line);
    std::string k;
    if (!(ls >> k)) continue;
    if (k == "rung") ls >> m.rung;
    else if (k == "nx") ls >> m.nx;
    else if (k == "ny") ls >> m.ny;
    else if (k == "nz") ls >> m.nz;
    else if (k == "spacing") ls >> m.spacing;
    else if (k == "ox") ls >> m.ox;
    else if (k == "oy") ls >> m.oy;
    else if (k == "oz") ls >> m.oz;
    else if (k == "iso") ls >> m.iso;
    else if (k == "achieved_vf") ls >> m.achieved_vf;
  }
  if (m.nx < 1 || m.ny < 1 || m.nz < 1 || m.spacing <= 0.0) {
    std::printf("FATAL: %s does not describe a lattice\n", path.c_str());
    std::exit(2);
  }
  return m;
}

std::vector<double> read_f64(const std::string& path, std::size_t n) {
  std::vector<double> f(n, 0.0);
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    std::printf("FATAL: cannot read %s\n", path.c_str());
    std::exit(2);
  }
  in.read(reinterpret_cast<char*>(f.data()),
          static_cast<std::streamsize>(n * sizeof(double)));
  if (static_cast<std::size_t>(in.gcount()) != n * sizeof(double)) {
    std::printf("FATAL: %s is %lld bytes, this lattice needs %zu\n", path.c_str(),
                static_cast<long long>(in.gcount()), n * sizeof(double));
    std::exit(2);
  }
  return f;
}

// `<prefix>.f64` + `<prefix>.meta` in the convention that probe demands: an
// OCCUPANCY, 0 = void, 1 = solid, iso between, background 0 outside the lattice.
void write_field(const std::string& prefix, const std::vector<double>& f,
                 int nx, int ny, int nz, double spacing, const Meta& src,
                 const std::string& note, double achieved_vf) {
  {
    std::ofstream o(prefix + ".f64", std::ios::binary);
    o.write(reinterpret_cast<const char*>(f.data()),
            static_cast<std::streamsize>(f.size() * sizeof(double)));
    if (!o) {
      std::printf("FATAL: could not write %s.f64\n", prefix.c_str());
      std::exit(2);
    }
  }
  std::ofstream m(prefix + ".meta");
  m.precision(17);
  m << "rung " << src.rung << "\n";
  m << "requested_vf " << src.rung << "\n";
  m << "nx " << nx << "\nny " << ny << "\nnz " << nz << "\n";
  m << "spacing " << spacing << "\n";
  // ★ THE ORIGIN IS UNCHANGED AT EVERY REFINEMENT, and that is not an oversight.
  // `marching_cubes` puts sample (i,j,k) at origin + (i+0.5)*spacing, and
  // `marching_cubes_resampled` refines by calling it with (nx*F, h/F, origin) —
  // the SAME origin. So the F-refined lattice covers exactly the coarse extent
  // and its samples land exactly where the tricubic resample's would.
  m << "ox " << src.ox << "\noy " << src.oy << "\noz " << src.oz << "\n";
  m << "iso 0.5\nfactor 1\ninterp none\n";
  m << "achieved_vf " << achieved_vf << "\n";
  m << "iterations 0\nwall_s 0\ncompliance 0\n";
  m << "# " << note << "\n";
}

// ── THE PARAMETRIC BASIS ────────────────────────────────────────────────────
// The two bases, the knot lattice, Psi as a sparse operator and the weighted
// least-squares solve used to be written out here. They were MOVED VERBATIM to
// `plsm_basis.hpp` when ARM 2 needed to OPTIMISE over the same phi this program
// FITS — one basis, not two. `levelset_probe.cpp` includes the same header.
//
// ★ The move is verified: `evidence/2026-08-10-parametric-level-set/
// s0_basis_move/` holds a two-fit `fits.csv` from before it and one from after,
// and they are identical.
#include "plsm_basis.hpp"

struct FitSpec {
  std::string label;
  Basis basis = Basis::Wendland;
  double dx = 4.0, dy = 4.0, dz = 4.0;
  double support = 2.0;
  double lambda = 1e-6;
};

bool parse_fit(const std::string& s, FitSpec& f) {
  // LABEL:basis:dx,dy,dz:support[:lambda]
  std::vector<std::string> parts;
  std::string cur;
  for (char c : s) {
    if (c == ':') { parts.push_back(cur); cur.clear(); }
    else cur.push_back(c);
  }
  parts.push_back(cur);
  if (parts.size() < 4) return false;
  f.label = parts[0];
  if (parts[1] == "wendland") f.basis = Basis::Wendland;
  else if (parts[1] == "gaussian") f.basis = Basis::Gaussian;
  else return false;
  if (std::sscanf(parts[2].c_str(), "%lf,%lf,%lf", &f.dx, &f.dy, &f.dz) != 3)
    return false;
  f.support = std::atof(parts[3].c_str());
  if (parts.size() > 4) f.lambda = std::atof(parts[4].c_str());
  return f.dx > 0.0 && f.dy > 0.0 && f.dz > 0.0 && f.support > 0.0;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::printf(
        "usage: plsm_probe <src_prefix> <out_dir>\n"
        "       [--fit LABEL:basis:dx,dy,dz:support[:lambda]] ...   repeatable\n"
        "       [--knots-min]        add the SLAB TRAP arm: one spacing from the\n"
        "                            THIN axis, the mistake PR 324 measured\n"
        "       [--eta V]            ersatz band half-width, VOXELS (default 2)\n"
        "       [--clamp V]          |phi| clamp on the fit target, VOXELS (6)\n"
        "       [--band-weight W]    weight on samples near the interface,\n"
        "                            w = 1 + (W-1) exp(-(phi/eta)^2)  (default 1)\n"
        "       [--sweeps N]         reinitialisation passes (default 8)\n"
        "       [--emit-factor F]    write the analytic field on the F-refined\n"
        "                            lattice; repeatable; default 1 and 2\n"
        "       [--frozen-mask P]    combine the fit with the frozen set as a\n"
        "                            SMOOTH BOOLEAN instead of a hard stamp\n"
        "       [--emit-source]      write the SOURCE occupancy tricubically\n"
        "                            resampled to each F — the RESOLUTION CONTROL\n"
        "       [--emit-extra P=L]   also resample the occupancy at prefix P to\n"
        "                            each F under label L (used for the SIMP rows)\n"
        "       [--cg-iters N]       (default 400)   [--cg-tol T] (default 1e-10)\n"
        "       [--threads N]\n");
    return 1;
  }
  const std::string src_prefix = argv[1];
  const std::string out = argv[2];

  std::vector<FitSpec> fits;
  std::vector<int> factors;
  std::vector<std::pair<std::string, std::string>> extras;
  double eta_vox = 2.0, clamp_vox = 6.0, cg_tol = 1e-10, band_weight = 1.0;
  int sweeps = 8, cg_iters = 2000, threads = 3;
  bool emit_source = false, knots_min = false;
  std::string frozen_mask;

  for (int i = 3; i < argc; ++i) {
    const std::string s = argv[i];
    auto next = [&](const char* what) -> std::string {
      if (i + 1 >= argc) {
        std::printf("FATAL: %s needs a value\n", what);
        std::exit(1);
      }
      return argv[++i];
    };
    if (s == "--fit") {
      FitSpec f;
      const std::string spec = next("--fit");
      if (!parse_fit(spec, f)) {
        std::printf("FATAL: cannot parse --fit '%s'\n", spec.c_str());
        return 1;
      }
      fits.push_back(f);
    } else if (s == "--knots-min") knots_min = true;
    else if (s == "--eta") eta_vox = std::atof(next("--eta").c_str());
    else if (s == "--clamp") clamp_vox = std::atof(next("--clamp").c_str());
    else if (s == "--band-weight") band_weight = std::atof(next("--band-weight").c_str());
    else if (s == "--sweeps") sweeps = std::atoi(next("--sweeps").c_str());
    else if (s == "--emit-factor") factors.push_back(std::atoi(next("--emit-factor").c_str()));
    else if (s == "--emit-source") emit_source = true;
    else if (s == "--emit-extra") {
      const std::string spec = next("--emit-extra");
      const std::size_t eq = spec.rfind('=');
      if (eq == std::string::npos) {
        std::printf("FATAL: --emit-extra wants PREFIX=LABEL\n");
        return 1;
      }
      extras.emplace_back(spec.substr(0, eq), spec.substr(eq + 1));
    }
    else if (s == "--frozen-mask") frozen_mask = next("--frozen-mask");
    else if (s == "--cg-iters") cg_iters = std::atoi(next("--cg-iters").c_str());
    else if (s == "--cg-tol") cg_tol = std::atof(next("--cg-tol").c_str());
    else if (s == "--threads") threads = std::atoi(next("--threads").c_str());
    else {
      std::printf("FATAL: unknown argument '%s'\n", s.c_str());
      return 1;
    }
  }
  if (factors.empty()) { factors.push_back(1); factors.push_back(2); }
  std::sort(factors.begin(), factors.end());
  factors.erase(std::unique(factors.begin(), factors.end()), factors.end());
  threads = hw_threads(threads);
  std::filesystem::create_directories(out);

  const Meta meta = read_meta(src_prefix + ".meta");
  Dims d{meta.nx, meta.ny, meta.nz};
  const std::size_t n = d.count();
  const double h = meta.spacing;
  const std::vector<double> rho = read_f64(src_prefix + ".f64", n);

  std::printf("== plsm_probe — ARM 1, the gate ==\n\n");
  std::printf("source     %s\n", src_prefix.c_str());
  std::printf("lattice    %d x %d x %d = %zu voxels, spacing %.6f mm\n", d.nx,
              d.ny, d.nz, n, h);
  std::printf("origin     (%.4f, %.4f, %.4f)\n", meta.ox, meta.oy, meta.oz);
  std::printf("threads    %d\n", threads);
  std::printf("eta        %.3f voxels = %.6f mm  (the arms' band, unchanged)\n",
              eta_vox, eta_vox * h);
  std::printf("clamp      +-%.3f voxels on the fit target\n", clamp_vox);

  // ── the source signed distance ────────────────────────────────────────────
  //
  // ★ THE SEED IS THE ARMS' OWN SEED. levelset_probe.cpp seeds from a converged
  // SIMP rung with phi = 0.5 - rho followed by `reinitialise(..., false)` — NOT
  // Russo-Smereka, which that file's own comment explains is wrong on a
  // near-binary step. This is the identical call on the identical function, from
  // the header both files include, so the phi fitted here is the phi the
  // optimiser would have been handed.
  std::vector<double> phi_src(n, 0.0);
  for (std::size_t v = 0; v < n; ++v) phi_src[v] = 0.5 - rho[v];
  const double t_re = now_s();
  reinitialise(d, phi_src, 1.0, sweeps, false);  // lengths in VOXELS
  std::printf("reinit     %d sweeps, %.2f s\n", sweeps, now_s() - t_re);

  const std::size_t src_inside = inside_count(phi_src, 0.0);
  std::printf("source     %zu voxels inside {phi < 0} (%.4f of the lattice)\n",
              src_inside, static_cast<double>(src_inside) / static_cast<double>(n));

  // ── ★ THE FROZEN SET AS A FUNCTION, NOT AS A STAMP ────────────────────────
  //
  // Stamping 40,216 voxels to hard 0/1 over an analytic phi is a staircase by
  // construction, and measured (s19) it costs about a fifth of the
  // representation's advantage and pins `midpoint_share` at 51% against the
  // unstamped 5%. A level set does not need to be stamped: with solid = {phi<0},
  // UNION is `min` and INTERSECTION is `max`, so
  //
  //     phi_eff = max( min(phi, phi_frozen_solid), -phi_frozen_void )
  //
  // is "whatever the optimiser chose, PLUS the frozen material, MINUS the frozen
  // void" — exactly, with no tags anywhere in the result.
  //
  // ★ WHAT THIS FIXES AND WHAT IT DOES NOT, STATED BEFORE IT IS RUN. The frozen
  // boundary is still defined by VOXEL TAGS, so this removes the HARD STAMP but
  // not the voxel quantisation of the boundary. If it recovers most of the gap,
  // the stamp was the problem and the fix is cheap. If it does not, the boundary
  // has to be rebuilt from the CAD faces the tags came from, which is a much
  // larger job. That is exactly why it is run rather than assumed.
  std::vector<double> phi_fsolid, phi_fvoid;
  if (!frozen_mask.empty()) {
    const Meta fm = read_meta(frozen_mask + ".meta");
    if (fm.nx != d.nx || fm.ny != d.ny || fm.nz != d.nz) {
      std::printf("FATAL: --frozen-mask is %d x %d x %d, not this lattice\n",
                  fm.nx, fm.ny, fm.nz);
      return 2;
    }
    const std::vector<double> mk = read_f64(frozen_mask + ".f64", n);
    std::size_t ns = 0, nv = 0;
    phi_fsolid.assign(n, 0.0);
    phi_fvoid.assign(n, 0.0);
    for (std::size_t v = 0; v < n; ++v) {
      const bool solid = mk[v] > 0.75;
      const bool voidv = mk[v] < 0.25;
      phi_fsolid[v] = solid ? -0.5 : 0.5;
      phi_fvoid[v] = voidv ? -0.5 : 0.5;
      ns += solid ? 1 : 0; nv += voidv ? 1 : 0;
    }
    reinitialise(d, phi_fsolid, 1.0, sweeps, false);
    reinitialise(d, phi_fvoid, 1.0, sweeps, false);
    std::printf("frozen      %zu FrozenSolid and %zu FrozenVoid voxels, each turned\n"
                "            into a signed distance by the same reinitialise()\n",
                ns, nv);
  }

  // The fit target: clamped, because only the zero set carries geometry and
  // `reinitialise` writes 1e6 into cells the sweep never reached.
  std::vector<double> target(n, 0.0);
  std::size_t band_n = 0;
  for (std::size_t v = 0; v < n; ++v) {
    target[v] = std::max(-clamp_vox, std::min(clamp_vox, phi_src[v]));
    if (std::fabs(phi_src[v]) <= eta_vox) ++band_n;
  }
  std::printf("band       %zu voxels with |phi| <= eta\n", band_n);

  // The weight. Gaussian in phi/eta so there is no kink anywhere for the basis to
  // chase: w = 1 is the unweighted fit and every fit reports both residuals.
  std::vector<double> w(n, 1.0);
  if (band_weight != 1.0) {
    for (std::size_t v = 0; v < n; ++v) {
      const double t = phi_src[v] / eta_vox;
      w[v] = 1.0 + (band_weight - 1.0) *
                       std::exp(-std::min(60.0, t * t));
    }
    std::printf("band weight %.4g at the interface, 1 far from it\n", band_weight);
  }
  std::printf("\n");

  // ── the sweep, if `--knots-min` asked for the trap arm ────────────────────
  if (knots_min) {
    // ★ THE SLAB TRAP, REPRODUCED ON PURPOSE. GridapTopOpt's alpha rule reads
    // `minimum(el_size)`; the analogous mistake here is to take ONE knot spacing
    // from the THIN axis and use it on all three. On 128 x 31 x 118 that is a
    // spacing sized for a 31-voxel cube. It is run so its cost is MEASURED.
    const double thin = std::min({static_cast<double>(d.nx),
                                  static_cast<double>(d.ny),
                                  static_cast<double>(d.nz)});
    const double sp = std::max(1.0, std::floor(thin / 8.0));  // 31/8 -> 3
    FitSpec f;
    f.label = "TRAP-min";
    f.basis = Basis::Wendland;
    f.dx = f.dy = f.dz = sp;
    f.support = 2.0;
    fits.push_back(f);
    std::printf("--knots-min: THE SLAB TRAP ARM, spacing %.0f voxels on all three\n"
                "             axes, derived from min(nx,ny,nz) = %.0f. R4 says do\n"
                "             not do this; this arm measures what it costs.\n\n",
                sp, thin);
  }
  if (fits.empty()) {
    std::printf("FATAL: no --fit given, nothing to do\n");
    return 1;
  }

  // ── the resolution controls: the SOURCE, and any extra field, at every F ──
  //
  // ★ WITHOUT THESE THE TABLE CANNOT BE READ. `dihedral_rms_deg` falls with the
  // extraction lattice on ANY field, so an analytic row at F=4 beside a voxel row
  // at F=2 measures the lattice. These rows put a VOXEL representation at every F
  // the analytic one is emitted at, using core's own `resample_field` — the exact
  // interpolant `marching_cubes_resampled` uses — so each column is like for like.
  // ★ THE REPORTED achieved_vf MUST BE THE ROW'S OWN. It used to be the source's
  // on every row, which is right for a volume-matched fit and WRONG for an
  // as-fitted one or for the band control. vf = printed / part_solid and
  // part_solid is a property of the GRID, identical for every row here, so
  // scaling the source's vf by the ratio of inside-counts is exact and needs no
  // part_solid of its own.
  auto vf_of = [&](std::size_t inside) {
    return src_inside ? meta.achieved_vf * static_cast<double>(inside) /
                            static_cast<double>(src_inside)
                      : 0.0;
  };
  auto emit_resampled = [&](const std::vector<double>& field,
                            const std::string& label, double vf) {
    for (int F : factors) {
      const std::vector<double> fine =
          F == 1 ? field
                 : resample_field(d.nx, d.ny, d.nz, field, F,
                                  ResampleInterp::Tricubic);
      char note[256];
      std::snprintf(note, sizeof note,
                    "voxel representation, tricubic resample to F=%d "
                    "(the RESOLUTION CONTROL)", F);
      char pfx[512];
      std::snprintf(pfx, sizeof pfx, "%s/%s_f%d", out.c_str(), label.c_str(), F);
      write_field(pfx, fine, d.nx * F, d.ny * F, d.nz * F, h / F, meta, note, vf);
      std::printf("  wrote %s  (%d x %d x %d)\n", pfx, d.nx * F, d.ny * F,
                  d.nz * F);
    }
  };
  if (emit_source) {
    std::printf("resolution controls — the SOURCE occupancy at every factor:\n");
    emit_resampled(rho, "SRC", meta.achieved_vf);

    // ★★ THE CONTROL THAT DECIDES WHETHER ANY OF THIS IS THE REPRESENTATION,
    // AND IT IS NOT THE ONE THE TASK ASKED FOR.
    //
    // The source occupancy is NOT a 2-voxel band, whatever its run's summary
    // says. Measured on PR 325's C=2 arm at iteration 25: 29961 sign-changing
    // lattice edges and only 19250 cells with 0 < rho < 1, i.e. an EFFECTIVE
    // half-width of 0.32 VOXELS against the nominal eta of 2. Its phi is about
    // six times steeper than a distance function at the interface, so H_eta
    // saturates within one cell of the surface. The fitted phi is not steep, so
    // the SAME eta gives it a band 89260 cells wide — 4.6x more.
    //
    // That difference is not cosmetic and it attacks two of the headline numbers
    // directly. `midpoint_share` and `dihedral_rms_deg` are both computed from
    // where marching cubes puts a vertex on a lattice edge, and marching cubes
    // interpolates LINEARLY between the two sampled values. When both endpoints
    // are saturated at 0 and 1 the sample carries NO sub-voxel information and
    // the vertex lands at the midpoint — a staircase — no matter where the true
    // surface is. A wide band keeps the information and the vertex lands right.
    //
    // So "the analytic surface is smoother" could be nothing but "the analytic
    // field has a wider gray band". This row separates them: it is the SOURCE's
    // OWN phi, still one number per voxel, still extracted by tricubic resample,
    // put through the SAME ersatz at the SAME eta as the fit. If it comes back
    // as smooth as the fit, the win was the band and the gate is CLOSED. If it
    // stays rough, the win is the representation.
    std::printf("★ the BAND CONTROL — the SOURCE's own phi re-banded at the same "
                "eta as the fits:\n");
    {
      const std::vector<double> sp = occupancy(phi_src, 0.0, eta_vox);
      std::size_t si = 0;
      for (double v : sp) if (v > 0.5) ++si;
      emit_resampled(sp, "SRCPHI", vf_of(si));
    }
  }
  for (const auto& e : extras) {
    const Meta em = read_meta(e.first + ".meta");
    if (em.nx != d.nx || em.ny != d.ny || em.nz != d.nz) {
      std::printf("FATAL: --emit-extra %s is %d x %d x %d, not this lattice\n",
                  e.first.c_str(), em.nx, em.ny, em.nz);
      return 2;
    }
    std::printf("resolution controls — %s at every factor:\n", e.second.c_str());
    emit_resampled(read_f64(e.first + ".f64", n), e.second, em.achieved_vf);
  }

  // ── the fits ──────────────────────────────────────────────────────────────
  std::ofstream csv(out + "/fits.csv");
  csv.precision(12);
  csv << "label,basis,knot_dx_vox,knot_dy_vox,knot_dz_vox,support_mult,"
         "support_rx_mm,support_ry_mm,support_rz_mm,lambda,knots_x,knots_y,"
         "knots_z,n_coeff,n_voxels,compression,nnz_A,cg_iters,cg_rel_resid,"
         "resid_band_rms_vox,resid_band_rms_mm,resid_all_rms_vox,"
         "resid_all_max_vox,inside_asfit,inside_src,offset_vox,offset_mm,"
         "fit_wall_s\n";

  for (const FitSpec& f : fits) {
    const KnotLattice L = make_lattice(d, f.dx, f.dy, f.dz, f.support);
    const std::size_t m = L.count();
    std::printf(
        "\n#####################################################################\n"
        "# FIT %s — %s, knot spacing (%.3g, %.3g, %.3g) voxels PER AXIS,\n"
        "#   support %.3g x spacing = (%.3g, %.3g, %.3g) voxels "
        "= (%.3f, %.3f, %.3f) mm\n"
        "#####################################################################\n",
        f.label.c_str(),
        f.basis == Basis::Wendland ? "Wendland C2 CSRBF" : "Gaussian (3-sigma)",
        f.dx, f.dy, f.dz, f.support, L.rx, L.ry, L.rz, L.rx * h, L.ry * h,
        L.rz * h);
    std::printf("  knots      %d x %d x %d = %zu coefficients\n", L.mx, L.my,
                L.mz, m);
    std::printf("  ★ COMPRESSION %.1fx — %zu coefficients against %zu voxels\n",
                static_cast<double>(n) / static_cast<double>(m), m, n);

    const double t0 = now_s();
    const Csr A = build_A(d, L, f.basis, threads);
    std::printf("  A          %zu x %zu, nnz %zu (%.1f knots per voxel), %.1f MB\n",
                A.rows, A.cols, A.nnz(),
                static_cast<double>(A.nnz()) / static_cast<double>(A.rows),
                static_cast<double>(A.nnz()) * 12.0 / 1048576.0);
    const Csr At = transpose(A, threads);
    const FitResult fr =
        solve_normal(A, At, target, w, f.lambda, cg_iters, cg_tol, threads);
    const double fit_wall = now_s() - t0;
    std::printf("  CG         %d iterations, relative residual %.3e, %.1f s\n",
                fr.cg_iters, fr.rel_resid, fit_wall);

    // The fit ON THE VOXEL LATTICE, for the residual and for certification.
    std::vector<double> phi_fit(n, 0.0);
    spmv(A, fr.alpha, phi_fit, threads);

    double sb = 0.0, sa = 0.0, mx = 0.0;
    for (std::size_t v = 0; v < n; ++v) {
      const double e = phi_fit[v] - target[v];
      sa += e * e;
      mx = std::max(mx, std::fabs(e));
      if (std::fabs(phi_src[v]) <= eta_vox) sb += e * e;
    }
    const double rb = band_n ? std::sqrt(sb / static_cast<double>(band_n)) : 0.0;
    const double ra = std::sqrt(sa / static_cast<double>(n));
    std::printf("  ★ RESIDUAL against the source signed distance:\n");
    std::printf("      in the band (|phi| <= %.2g vox): rms %.5f voxels = %.5f mm\n",
                eta_vox, rb, rb * h);
    std::printf("      whole domain (clamped target)  : rms %.5f voxels, "
                "max %.5f\n", ra, mx);

    const std::size_t inside_asfit = inside_count(phi_fit, 0.0);
    const double off = match_offset(phi_fit, src_inside);
    std::printf("  volume     as fitted %zu voxels inside, source %zu "
                "(%+.3f%%)\n",
                inside_asfit, src_inside,
                100.0 * (static_cast<double>(inside_asfit) -
                         static_cast<double>(src_inside)) /
                    static_cast<double>(src_inside));
    std::printf("  ★ VOLUME-MATCHED offset %+.6f voxels = %+.6f mm -> %zu inside\n",
                off, off * h, inside_count(phi_fit, off));

    // ── what comes out ──────────────────────────────────────────────────────
    // Two flavours (as fitted / volume-matched) at every factor. F=1 is the
    // voxel-lattice field: it is what `levelset_probe --certify-field` reads, and
    // it is ALSO the row the task warns is a false negative — reported as such
    // rather than left out, because the size of the gap between it and F>=2 is
    // itself the measurement of how much the voxel lattice was costing.
    for (int F : factors) {
      const std::vector<double> pf =
          F == 1 ? phi_fit
                 : evaluate(L, f.basis, fr.alpha, d.nx * F, d.ny * F, d.nz * F, F,
                            threads);
      for (int which = 0; which < 2; ++which) {
        const double c = which ? off : 0.0;
        const std::vector<double> occ =
            frozen_mask.empty()
                ? occupancy(pf, c, eta_vox)
                : occupancy(pf, c, eta_vox, &phi_fsolid, &phi_fvoid, F, &d);
        char note[512];
        std::snprintf(note, sizeof note,
                      "analytic phi = sum alpha_i psi_i, evaluated at the F=%d "
                      "lattice; %s; %zu coefficients", F,
                      which ? "VOLUME-MATCHED" : "as fitted", m);
        char pfx[512];
        std::snprintf(pfx, sizeof pfx, "%s/%s_%s_f%d", out.c_str(),
                      f.label.c_str(), which ? "vm" : "af", F);
        write_field(pfx, occ, d.nx * F, d.ny * F, d.nz * F, h / F, meta, note,
                    vf_of(which ? inside_count(phi_fit, off)
                                : inside_asfit));
        std::printf("  wrote %s\n", pfx);
      }
    }

    csv << f.label << ','
        << (f.basis == Basis::Wendland ? "wendland" : "gaussian") << ',' << f.dx
        << ',' << f.dy << ',' << f.dz << ',' << f.support << ',' << (L.rx * h)
        << ',' << (L.ry * h) << ',' << (L.rz * h) << ',' << f.lambda << ','
        << L.mx << ',' << L.my << ',' << L.mz << ',' << m << ',' << n << ','
        << (static_cast<double>(n) / static_cast<double>(m)) << ',' << A.nnz()
        << ',' << fr.cg_iters << ',' << fr.rel_resid << ',' << rb << ','
        << (rb * h) << ',' << ra << ',' << mx << ',' << inside_asfit << ','
        << src_inside << ',' << off << ',' << (off * h) << ',' << fit_wall
        << '\n';
    csv.flush();
  }

  std::printf("\nwrote %s/fits.csv\n", out.c_str());
  return 0;
}
