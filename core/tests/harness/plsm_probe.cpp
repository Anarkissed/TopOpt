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
// S2 (task 2026-08-11-plsm-minimise-extra-surface): the frozen region from the
// CAD faces. `MeshDistance` is core's OWN exact signed distance to a closed
// triangle mesh (task 2026-08-08-strut-clip-matches-shell), accelerated by a
// uniform grid, sign by the Bærentzen–Aanæs angle-weighted pseudonormal. It is
// INVOKED, not reimplemented — R2 applies to geometry as much as to roughness.
#include "topopt/face_overrides.hpp"
#include "topopt/mesh_distance.hpp"
#include "topopt/step.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
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
  // ★ NON-EMPTY WHEN THE COEFFICIENTS COME FROM AN OPTIMISER RUN RATHER THAN
  // FROM A FIT. `--alpha` exists so S2's frozen treatment can be measured on a
  // design ARM 2 already produced, WITHOUT re-running the optimiser: the design
  // IS `alpha.f64`, 685 KB of it, and re-evaluating it under a different frozen
  // boolean is a minute of arithmetic instead of half an hour of state solves.
  std::vector<double> given;
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

// ═══ S2 — THE FROZEN REGION FROM THE CAD FACES ═══════════════════════════════
//
// ★ THE MEASUREMENT THIS EXISTS FOR. PR 324 §5 got the frozen set down from a
// HARD VOXEL STAMP (cut 5.9604, CAD error 0.4767) to a SMOOTH BOOLEAN (5.6056 /
// 0.4429) and said plainly what was left: "the frozen boundary is still defined
// by VOXEL TAGS: the boolean is smooth, but it is smoothly voxel-shaped. Getting
// the rest means deriving the frozen region from the CAD faces the tags came
// from." That is this.
//
// ── ★ AND THIS OVERRIDES THE TASK BRIEF'S S2(a), DECLARED RATHER THAN SLID IN.
//
// The brief says to use `StepFaceInfo`'s `kind` / `cylinder_radius_mm` /
// `axis_point` / `axis_dir` / `plane_normal` / `plane_origin`. Those describe the
// UNBOUNDED carrier surface of a face — an infinite plane, an infinite cylinder.
// The frozen region is not bounded by that. `mask_step_face`
// (core/src/io/face_tag.cpp) freezes
//
//     solid voxels whose CENTRE is within (depth_voxels - 0.5)*h of the face's
//     TRIANGULATION
//
// — the face's own bounded patch, edges included. Freezing everything within
// 5 mm of face 16's infinite plane would freeze a slab clear across the part;
// on this job face 16's protection is 10,554 voxels, and a half-space would be
// several times that. So the plane/cylinder parameters are the wrong object,
// and the right one is the exact distance to the face's bounded surface.
//
// ★ WHICH IS ALSO EXACTLY WHAT CORE ALREADY COMPUTES, so this is a CONTINUUM
// LIMIT of the shipped rule rather than a second definition of it: same faces,
// same depths, same distance-to-triangles — with the voxel-centre quantisation
// and the 0/1 stamp removed. The result is checked against the mask core
// actually built (`--frozen-mask` beside `--frozen-cad`), and the agreement is
// reported, so "same region" is a number and not a claim.
//
// One consequence is worth stating before any table: the part's OUTER boundary
// stops being voxel-shaped too, because FrozenVoid on this job is exactly
// {outside the CAD} (357,320 voxels against 110,904 part voxels — they sum to
// the lattice). That is the boundary the CAD population is measured on, and the
// optimiser never had any say over it: it is the part, not the design.
struct CadFrozen {
  // ★ THE MESHES ARE OWNED HERE, and that is load-bearing rather than tidy:
  // `MeshDistance` holds a POINTER to the mesh it was built over and its header
  // says the mesh "MUST outlive this object". The StepModel is a local at the
  // call site, so its mesh is copied in before any accelerator is built.
  TriangleMesh part_mesh;
  TriangleMesh face_mesh;
  // ★ ONE ACCELERATOR PER THREAD, for the reason its header gives in capitals:
  // "NOT THREAD-SAFE FOR CONCURRENT QUERIES ON ONE INSTANCE" — a query stamps a
  // per-instance visit array. Sharing one across a parallel_for would be a data
  // race that produces plausible-looking distances.
  std::vector<std::unique_ptr<MeshDistance>> part;
  std::vector<std::unique_ptr<MeshDistance>> faces;
  double depth_mm = 0.0;
  std::size_t face_tris = 0;
};

// ★ AN INDEPENDENT POINT-TRIANGLE DISTANCE, AND IT IS A CHECK, NOT AN
// INSTRUMENT. R2 says invoke, do not retype — and `MeshDistance` is what is
// invoked everywhere a distance is USED. This exists only to verify that
// accelerated answer against a brute force over every triangle, which is worth
// nothing if it shares an implementation with the thing it is checking. It is
// the standard Ericson closest-point-on-triangle by Voronoi region, written out
// once, used only in the verification block, and never in a measurement.
double check_point_tri_dist2(const Vec3& p, const Vec3& a, const Vec3& b,
                             const Vec3& c) {
  auto sub = [](const Vec3& u, const Vec3& v) {
    return Vec3{u.x - v.x, u.y - v.y, u.z - v.z};
  };
  auto dot = [](const Vec3& u, const Vec3& v) {
    return u.x * v.x + u.y * v.y + u.z * v.z;
  };
  const Vec3 ab = sub(b, a), ac = sub(c, a), ap = sub(p, a);
  const double dd1 = dot(ab, ap), dd2 = dot(ac, ap);
  auto d2 = [&](const Vec3& q) { const Vec3 e = sub(p, q); return dot(e, e); };
  if (dd1 <= 0.0 && dd2 <= 0.0) return d2(a);
  const Vec3 bp = sub(p, b);
  const double dd3 = dot(ab, bp), dd4 = dot(ac, bp);
  if (dd3 >= 0.0 && dd4 <= dd3) return d2(b);
  const double vc = dd1 * dd4 - dd3 * dd2;
  if (vc <= 0.0 && dd1 >= 0.0 && dd3 <= 0.0) {
    const double t = dd1 / (dd1 - dd3);
    return d2(Vec3{a.x + t * ab.x, a.y + t * ab.y, a.z + t * ab.z});
  }
  const Vec3 cp = sub(p, c);
  const double dd5 = dot(ab, cp), dd6 = dot(ac, cp);
  if (dd6 >= 0.0 && dd5 <= dd6) return d2(c);
  const double vb = dd5 * dd2 - dd1 * dd6;
  if (vb <= 0.0 && dd2 >= 0.0 && dd6 <= 0.0) {
    const double t = dd2 / (dd2 - dd6);
    return d2(Vec3{a.x + t * ac.x, a.y + t * ac.y, a.z + t * ac.z});
  }
  const double va = dd3 * dd6 - dd5 * dd4;
  if (va <= 0.0 && (dd4 - dd3) >= 0.0 && (dd5 - dd6) >= 0.0) {
    const double t = (dd4 - dd3) / ((dd4 - dd3) + (dd5 - dd6));
    const Vec3 bc = sub(c, b);
    return d2(Vec3{b.x + t * bc.x, b.y + t * bc.y, b.z + t * bc.z});
  }
  const double den = 1.0 / (va + vb + vc);
  const double t1 = vb * den, t2 = vc * den;
  return d2(Vec3{a.x + ab.x * t1 + ac.x * t2, a.y + ab.y * t1 + ac.y * t2,
                 a.z + ab.z * t1 + ac.z * t2});
}

// The triangles of `wanted` faces, welded-as-is out of the model. The sub-mesh
// is NOT closed, so only `unsigned_distance` is ever asked of it — which
// `MeshDistance` documents as "correct regardless" of the winding and closure.
TriangleMesh submesh_of_faces(const StepModel& model,
                              const std::vector<int>& wanted) {
  std::vector<char> keep(static_cast<std::size_t>(model.face_count), 0);
  for (int f : wanted)
    if (f >= 0 && f < model.face_count) keep[static_cast<std::size_t>(f)] = 1;
  TriangleMesh out;
  out.vertices = model.mesh.vertices;   // shared indices; unreferenced ones are inert
  for (std::size_t t = 0; t < model.mesh.triangles.size(); ++t) {
    const int f = model.triangle_face[t];
    if (f >= 0 && f < model.face_count && keep[static_cast<std::size_t>(f)])
      out.triangles.push_back(model.mesh.triangles[t]);
  }
  return out;
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
        "  S2 (2026-08-11) — the frozen region from the CAD, not from the tags:\n"
        "       [--frozen-cad S]     <part.step>: the frozen boolean built from\n"
        "                            the EXACT distance to the CAD faces, at the\n"
        "                            REFINED lattice. Needs --frozen-faces.\n"
        "       [--frozen-faces L]   comma-separated B-rep face ids to freeze\n"
        "       [--frozen-depth V]   their depth in VOXELS (core uses 3)\n"
        "  reading an OPTIMISED design back in:\n"
        "       [--alpha P]          skip the fit: read P.f64 / P.meta, the\n"
        "                            coefficients an optimiser run wrote, and\n"
        "                            emit THAT design under the label P\n"
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
  // S2
  std::string frozen_cad, alpha_prefix;
  std::vector<int> frozen_faces;
  double frozen_depth_vox = 3.0;   // core: lround(5.0 mm / 1.705279) = 3

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
    else if (s == "--frozen-cad") frozen_cad = next("--frozen-cad");
    else if (s == "--frozen-depth")
      frozen_depth_vox = std::atof(next("--frozen-depth").c_str());
    else if (s == "--alpha") alpha_prefix = next("--alpha");
    else if (s == "--frozen-faces") {
      const std::string spec = next("--frozen-faces");
      std::string cur;
      for (char c : spec + ",") {
        if (c == ',') { if (!cur.empty()) frozen_faces.push_back(std::atoi(cur.c_str())); cur.clear(); }
        else cur.push_back(c);
      }
    }
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

  // ── `--alpha`: the design an optimiser already found, read back in ────────
  //
  // `alpha.meta` is written by `levelset_probe`'s ARM 2 beside `alpha.f64` and
  // carries everything needed to rebuild the basis: the basis name, the per-axis
  // knot spacing, the support multiplier, and — as a CHECK rather than an input
  // — the counts and padding `make_lattice` derived from them.
  if (!alpha_prefix.empty()) {
    std::ifstream am(alpha_prefix + ".meta");
    if (!am) {
      std::printf("FATAL: cannot read %s.meta\n", alpha_prefix.c_str());
      return 2;
    }
    FitSpec f;
    f.label = "ALPHA";
    long want_coeff = -1, want_mx = -1, want_my = -1, want_mz = -1;
    std::string line;
    while (std::getline(am, line)) {
      std::istringstream ls(line);
      std::string key;
      ls >> key;
      if (key == "basis") {
        std::string b; ls >> b;
        if (b == "gaussian") f.basis = Basis::Gaussian;
        else if (b == "wendland") f.basis = Basis::Wendland;
        else { std::printf("FATAL: alpha.meta basis '%s'\n", b.c_str()); return 2; }
      } else if (key == "knots_vox") ls >> f.dx >> f.dy >> f.dz;
      else if (key == "support") ls >> f.support;
      else if (key == "counts") ls >> want_mx >> want_my >> want_mz;
      else if (key == "n_coeff") ls >> want_coeff;
    }
    if (want_coeff <= 0) {
      std::printf("FATAL: %s.meta has no n_coeff\n", alpha_prefix.c_str());
      return 2;
    }
    f.given = read_f64(alpha_prefix + ".f64", static_cast<std::size_t>(want_coeff));
    const KnotLattice chk = make_lattice(d, f.dx, f.dy, f.dz, f.support);
    if (chk.mx != want_mx || chk.my != want_my || chk.mz != want_mz) {
      std::printf("FATAL: alpha.meta says the knot lattice is %ld x %ld x %ld, "
                  "but rebuilding it from (%.4g, %.4g, %.4g) voxels at support "
                  "%.4g on this %d x %d x %d grid gives %d x %d x %d. The "
                  "design and the grid do not match.\n",
                  want_mx, want_my, want_mz, f.dx, f.dy, f.dz, f.support,
                  d.nx, d.ny, d.nz, chk.mx, chk.my, chk.mz);
      return 2;
    }
    std::printf("alpha      %s: %ld coefficients on %d x %d x %d knots, %s "
                "basis, spacing (%.4g, %.4g, %.4g) voxels, support %.4g\n",
                alpha_prefix.c_str(), want_coeff, chk.mx, chk.my, chk.mz,
                f.basis == Basis::Gaussian ? "gaussian" : "wendland",
                f.dx, f.dy, f.dz, f.support);
    fits.push_back(std::move(f));
  }
  if (fits.empty()) {
    std::printf("FATAL: nothing to do — give at least one --fit or an --alpha\n");
    return 2;
  }


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

  // ── ★ S2 — THE SAME BOOLEAN, BUILT FROM THE CAD INSTEAD OF FROM THE TAGS ──
  //
  // Two exact distance fields, evaluated wherever they are asked for rather than
  // sampled onto the design lattice and interpolated:
  //
  //   phi_part(x)   = -signed_distance_to_the_STEP_mesh(x)      [< 0 INSIDE]
  //   phi_faces(x)  =  unsigned_distance_to_the_frozen_faces(x)
  //                      - (depth - 0.5)*h                      [< 0 in the pad]
  //
  // and then, in VOXEL units to match everything else in this program,
  //
  //   phi_fsolid = max(phi_faces, phi_part)   "in the pad AND in the part"
  //   phi_fvoid  = -phi_part                  "outside the part"
  //
  // The (depth - 0.5) is `mask_step_face`'s own threshold, not a re-derivation:
  // "a voxel in layer L against a flush planar face has its centre (L + 0.5)
  // edges from the face, so the first depth_voxels layers are exactly the solid
  // voxels whose centre is within (depth_voxels - 0.5) edges of the face."
  std::unique_ptr<CadFrozen> cad;
  if (!frozen_cad.empty()) {
    if (frozen_faces.empty()) {
      std::printf("FATAL: --frozen-cad needs --frozen-faces <ids>. The frozen\n"
                  "       region is a property of the JOB, not of the STEP, and\n"
                  "       guessing which faces the job froze is exactly the kind\n"
                  "       of silent re-derivation this task must not do.\n");
      return 2;
    }
    const StepModel model = import_part_file_resolved(frozen_cad);
    if (model.mesh.vertices.empty()) {
      std::printf("FATAL: %s imported empty — OCCT is required\n", frozen_cad.c_str());
      return 2;
    }
    cad = std::make_unique<CadFrozen>();
    cad->part_mesh = model.mesh;
    cad->face_mesh = submesh_of_faces(model, frozen_faces);
    cad->face_tris = cad->face_mesh.triangles.size();
    if (cad->face_tris == 0) {
      std::printf("FATAL: --frozen-faces selected 0 triangles of %zu (the model\n"
                  "       has %d B-rep faces). A frozen region of nothing would\n"
                  "       measure a part with no anchor and no protection.\n",
                  model.mesh.triangles.size(), model.face_count);
      return 2;
    }
    // ★ THE THRESHOLD IS CORE'S, INCLUSIVE OF EQUALITY, AND THAT IS A WHOLE
    // VOXEL LAYER RATHER THAN A PEDANTIC POINT. `mask_step_face` tests
    // `point_tri_dist2 <= thr2 + eps` with `thr = (depth - 0.5)*h` and
    // `eps = 1e-9*h*h`. A continuous field tested with `< 0` excludes the
    // equality case — and on a FLUSH PLANAR FACE the equality case is not a
    // measure-zero curiosity: the header's own reasoning is that "a voxel in
    // layer L against a flush planar face has its centre (L + 0.5) edges from
    // the face", so the LAST layer's centres sit at EXACTLY (depth - 0.5)*h.
    //
    // Measured before the fix: 3,348 voxels of the 40,216 — 8.3% of the frozen
    // set — appeared as "core froze it, the CAD rule did not", and their
    // distance beyond the threshold was 0.0000 mm at the minimum, the median,
    // the 90th percentile AND the maximum. Every one of them was the flush
    // layer. Carrying core's `+ eps` inside the square root reproduces its
    // predicate exactly; geometrically the boundary moves by 2e-10 of a voxel.
    cad->depth_mm = std::sqrt((frozen_depth_vox - 0.5) * h *
                                  ((frozen_depth_vox - 0.5) * h) +
                              1e-9 * h * h);
    for (int t = 0; t < threads; ++t) {
      cad->part.push_back(std::make_unique<MeshDistance>(cad->part_mesh));
      cad->faces.push_back(std::make_unique<MeshDistance>(cad->face_mesh));
    }
    std::printf("\n★ S2 FROZEN FROM THE CAD\n");
    std::printf("  part       %s, %d B-rep faces, %zu triangles\n",
                frozen_cad.c_str(), model.face_count,
                model.mesh.triangles.size());
    std::printf("  frozen     %zu faces -> %zu triangles, depth %.4g voxels "
                "(threshold %.4f mm)\n",
                frozen_faces.size(), cad->face_tris, frozen_depth_vox,
                cad->depth_mm);
    std::printf("  accelerator cell %.4f mm (part) / %.4f mm (faces), %d "
                "instances (one per thread); the part mesh reads %s-wound\n",
                cad->part[0]->cell_mm(), cad->faces[0]->cell_mm(), threads,
                cad->part[0]->inward_wound() ? "INWARD" : "outward");
    // ★ AND THE CHECK THAT MAKES IT A CONTINUUM LIMIT AND NOT A SECOND RULE.
    // Rasterised at voxel centres, the analytic region must reproduce the mask
    // core actually built. `--frozen-mask` is the one core wrote; when both are
    // given, the agreement is COUNTED and printed. A disagreement means the
    // face list or the depth is wrong, and the reader sees it before any
    // roughness number that depends on it.
    if (!frozen_mask.empty() && !phi_fsolid.empty()) {
      std::size_t agree = 0, only_cad = 0, only_tags = 0;
      // ★ AND WHERE A DISAGREEMENT COMES FROM, SPLIT. The analytic region is an
      // intersection of two conditions — "within the pad depth of a frozen
      // face" and "in the part" — and core's is the same intersection with
      // `grid.solid(i,j,k)` standing in for the second. Reporting only a
      // percentage would leave which of the two moved unknown, and they mean
      // different things: the first would be a wrong face list or depth (a
      // MISTAKE), the second is the voxelisation of the part boundary
      // disagreeing with the CAD at the half-voxel (the thing S2 is FOR).
      std::size_t tags_only_face = 0, tags_only_part = 0;
      std::vector<double> excess;   // how far BEYOND the threshold they sit, mm
      for (int k = 0; k < d.nz; ++k)
        for (int j = 0; j < d.ny; ++j)
          for (int i = 0; i < d.nx; ++i) {
            const std::size_t v = d.at(i, j, k);
            const Vec3 p{meta.ox + (i + 0.5) * h, meta.oy + (j + 0.5) * h,
                         meta.oz + (k + 0.5) * h};
            const double dpart = -cad->part[0]->signed_distance(p);
            const double dface = cad->faces[0]->unsigned_distance(p) - cad->depth_mm;
            const bool by_cad = std::max(dface, dpart) < 0.0;
            const bool by_tag = phi_fsolid[v] < 0.0;
            if (by_cad == by_tag) ++agree;
            else if (by_cad) ++only_cad;
            else {
              ++only_tags;
              if (!(dface < 0.0)) { ++tags_only_face; excess.push_back(dface); }
              else ++tags_only_part;   // in the pad, but the centre is not in the CAD
            }
          }
      // ★ AND BEFORE THAT NUMBER IS BELIEVED: IS THE ACCELERATED DISTANCE THE
      // DISTANCE? A one-sided disagreement (core freezes voxels the analytic
      // rule does not, never the other way) has exactly two explanations — core
      // is applying a rule this does not reproduce, or `MeshDistance` is
      // returning distances that are too LARGE. The second is cheap to rule
      // out: brute-force the point-triangle distance over every frozen-face
      // triangle for a stride-sampled set of voxels and compare. Same
      // primitive core's own `mask_step_face` uses, no accelerator in it.
      {
        double worst = 0.0;
        std::size_t checked = 0;
        for (std::size_t v = 0; v < n; v += 997) {
          const int i = static_cast<int>(v % static_cast<std::size_t>(d.nx));
          const int j = static_cast<int>((v / static_cast<std::size_t>(d.nx)) %
                                         static_cast<std::size_t>(d.ny));
          const int k = static_cast<int>(v / (static_cast<std::size_t>(d.nx) *
                                              static_cast<std::size_t>(d.ny)));
          const Vec3 p{meta.ox + (i + 0.5) * h, meta.oy + (j + 0.5) * h,
                       meta.oz + (k + 0.5) * h};
          double brute2 = 1e300;
          for (const auto& tri : cad->face_mesh.triangles) {
            const Vec3& A = cad->face_mesh.vertices[static_cast<std::size_t>(tri[0])];
            const Vec3& B = cad->face_mesh.vertices[static_cast<std::size_t>(tri[1])];
            const Vec3& C = cad->face_mesh.vertices[static_cast<std::size_t>(tri[2])];
            brute2 = std::min(brute2, check_point_tri_dist2(p, A, B, C));
          }
          worst = std::max(worst, std::fabs(std::sqrt(brute2) -
                                            cad->faces[0]->unsigned_distance(p)));
          ++checked;
        }
        std::printf("  accelerator check: %zu voxels brute-forced against all "
                    "%zu frozen-face triangles,\n"
                    "                     worst |brute - accelerated| = %.3e mm\n",
                    checked, cad->face_tris, worst);
      }
      std::printf("  ★ AGREEMENT with the tags core built, at voxel centres:\n"
                  "      %zu of %zu voxels agree (%.4f%%);  CAD-only %zu, "
                  "tags-only %zu\n"
                  "      of the tags-only: %zu fail the FACE-DEPTH test "
                  "(a wrong face list or depth would live here)\n"
                  "                        %zu fail the IN-THE-PART test "
                  "(the voxelisation is wider than the CAD)\n",
                  agree, n, 100.0 * static_cast<double>(agree) /
                                static_cast<double>(n), only_cad, only_tags,
                  tags_only_face, tags_only_part);
      // ★ HOW FAR BEYOND, because the shape of that distribution names the
      // cause. A tight shell just past the threshold is a tessellation or
      // rounding subtlety in a rule this DOES reproduce; a broad spread is a
      // face this face list is missing, and the two need different answers.
      if (!excess.empty()) {
        std::sort(excess.begin(), excess.end());
        std::printf("      their distance BEYOND the %.4f mm threshold: min "
                    "%.4f, median %.4f, p90 %.4f, max %.4f mm  (a voxel is "
                    "%.4f mm)\n",
                    cad->depth_mm, excess.front(),
                    excess[excess.size() / 2],
                    excess[(excess.size() * 9) / 10], excess.back(), h);
      }
    }
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

  // ── S2: the CAD frozen fields, on whichever refined lattice is asked for ──
  //
  // Built once per factor and cached, because each is 2 * nx*ny*nz*F^3 exact
  // distance queries — 11.2 million at F=2 on this part — and both flavours (as
  // fitted / volume-matched) of every fit read the same two fields.
  std::map<int, std::pair<std::vector<double>, std::vector<double>>> cad_fields;
  auto cad_for = [&](int F) -> const std::pair<std::vector<double>, std::vector<double>>& {
    auto found = cad_fields.find(F);
    if (found != cad_fields.end()) return found->second;
    const int fx = d.nx * F, fy = d.ny * F, fz = d.nz * F;
    const std::size_t fn = static_cast<std::size_t>(fx) *
                           static_cast<std::size_t>(fy) *
                           static_cast<std::size_t>(fz);
    std::vector<double> fs(fn, 0.0), fv(fn, 0.0);
    const double hf = h / F;
    const double t0 = now_s();
    // ★ THE THREAD INDEX IS DERIVED FROM THE SLAB, NOT FROM A COUNTER. This
    // splits by k so each thread owns a contiguous range and can be given its
    // OWN MeshDistance instance — see CadFrozen for why sharing one is a race.
    const int nt = std::max(1, threads);
    std::vector<std::thread> pool;
    for (int t = 0; t < nt; ++t) {
      pool.emplace_back([&, t] {
        MeshDistance& mp = *cad->part[static_cast<std::size_t>(t)];
        MeshDistance& mf = *cad->faces[static_cast<std::size_t>(t)];
        for (int k = t; k < fz; k += nt)
          for (int j = 0; j < fy; ++j)
            for (int i = 0; i < fx; ++i) {
              const std::size_t v =
                  static_cast<std::size_t>(i) +
                  static_cast<std::size_t>(fx) *
                      (static_cast<std::size_t>(j) +
                       static_cast<std::size_t>(fy) * static_cast<std::size_t>(k));
              const Vec3 p{meta.ox + (i + 0.5) * hf, meta.oy + (j + 0.5) * hf,
                           meta.oz + (k + 0.5) * hf};
              // signed_distance is POSITIVE INSIDE; this program's phi is
              // NEGATIVE INSIDE, so the sign flips exactly once, here.
              const double part_mm = -mp.signed_distance(p);
              const double face_mm = mf.unsigned_distance(p) - cad->depth_mm;
              // In VOXELS, because every other length in this program is.
              fs[v] = std::max(face_mm, part_mm) / h;
              fv[v] = -part_mm / h;
            }
      });
    }
    for (auto& th : pool) th.join();
    std::printf("  S2 CAD frozen fields at F=%d: %zu points x 2 exact distance "
                "queries, %.1f s\n", F, fn, now_s() - t0);
    return cad_fields.emplace(F, std::make_pair(std::move(fs), std::move(fv)))
        .first->second;
  };

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

    // ★ THE LATTICE THE COEFFICIENTS WERE WRITTEN ON MUST BE THE LATTICE THEY
    // ARE READ ON, and `alpha.meta` carries both the spacing/support this
    // rebuilt `L` from AND the counts/pad `make_lattice` derived. Checking the
    // derived quantities is what catches a mismatch that the inputs alone
    // would not: a different grid, a different `make_lattice`, a stale file.
    if (!f.given.empty() && f.given.size() != m) {
      std::printf("FATAL: --alpha has %zu coefficients but this knot lattice "
                  "(%d x %d x %d) wants %zu. The design was written on a "
                  "different lattice.\n",
                  f.given.size(), L.mx, L.my, L.mz, m);
      return 2;
    }

    const double t0 = now_s();
    const Csr A = build_A(d, L, f.basis, threads);
    std::printf("  A          %zu x %zu, nnz %zu (%.1f knots per voxel), %.1f MB\n",
                A.rows, A.cols, A.nnz(),
                static_cast<double>(A.nnz()) / static_cast<double>(A.rows),
                static_cast<double>(A.nnz()) * 12.0 / 1048576.0);
    const Csr At = transpose(A, threads);
    FitResult fr;
    if (!f.given.empty()) {
      fr.alpha = f.given;
      std::printf("  ★ NO FIT — the %zu coefficients come from %s, an optimiser\n"
                  "    run's own design. The residual columns below are against\n"
                  "    the SOURCE occupancy and describe how far that design's\n"
                  "    phi is from a signed distance, not a fit quality.\n",
                  m, f.label.c_str());
    } else {
      fr = solve_normal(A, At, target, w, f.lambda, cg_iters, cg_tol, threads);
    }
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

    // ★ THE VOLUME MATCH MUST COUNT THE OBJECT THAT GETS EMITTED, and with a
    // frozen boolean in play that is NOT `#{phi + c < 0}`. `match_offset`
    // counts the raw sub-level set over the whole lattice; the emitted field is
    // `max(min(phi + c, phi_fsolid), -phi_fvoid)`, which adds the frozen
    // material and subtracts everything outside the part. On the ARM 2 designs
    // the two differ by a factor of four — the raw phi is negative over much of
    // the void, where nothing constrains it — so matching on the raw count
    // would put every volume-matched row at the wrong volume, and R4 asks for
    // the volume beside every roughness number precisely so that cannot pass.
    auto inside_effective = [&](double c) {
      if (!cad) return inside_count(phi_fit, c);
      const auto& F1 = cad_for(1);
      std::size_t s = 0;
      for (std::size_t v = 0; v < n; ++v) {
        double p = phi_fit[v] + c;
        p = std::min(p, F1.first[v]);
        p = std::max(p, -F1.second[v]);
        if (p < 0.0) ++s;
      }
      return s;
    };
    const std::size_t inside_asfit = inside_effective(0.0);
    double off;
    if (cad) {
      // Same bisection as `match_offset`, on the effective count. It is
      // non-increasing in c for the same reason: raising phi can only remove
      // material from the sub-level set, and both booleans are monotone in it.
      double lo = -60.0, hi = 60.0;
      for (int bi = 0; bi < 80; ++bi) {
        const double mid = 0.5 * (lo + hi);
        if (inside_effective(mid) > src_inside) lo = mid; else hi = mid;
      }
      off = 0.5 * (lo + hi);
    } else {
      off = match_offset(phi_fit, src_inside);
    }
    std::printf("  volume     as fitted %zu voxels inside, source %zu "
                "(%+.3f%%)\n",
                inside_asfit, src_inside,
                100.0 * (static_cast<double>(inside_asfit) -
                         static_cast<double>(src_inside)) /
                    static_cast<double>(src_inside));
    std::printf("  ★ VOLUME-MATCHED offset %+.6f voxels = %+.6f mm -> %zu inside\n",
                off, off * h, inside_effective(off));

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
        // ★ THREE FROZEN TREATMENTS, ONE EXPRESSION EACH, AND THE ROW SAYS
        // WHICH. No frozen set at all (does not certify — PR 324 §5); the
        // smooth boolean off the VOXEL TAGS (PR 324's best); and S2's, off the
        // CAD. `--frozen-cad` wins when both are given, because the tags are
        // then present only to be agreed with.
        const std::vector<double> occ =
            cad ? occupancy_fine(pf, c, eta_vox, cad_for(F).first,
                                 cad_for(F).second)
                : (frozen_mask.empty()
                       ? occupancy(pf, c, eta_vox)
                       : occupancy(pf, c, eta_vox, &phi_fsolid, &phi_fvoid, F, &d));
        char note[512];
        std::snprintf(note, sizeof note,
                      "analytic phi = sum alpha_i psi_i, evaluated at the F=%d "
                      "lattice; %s; %zu coefficients; frozen set: %s", F,
                      which ? "VOLUME-MATCHED" : "as fitted", m,
                      cad ? "ANALYTIC, from the CAD faces"
                          : (frozen_mask.empty() ? "NONE (does not certify)"
                                                 : "smooth boolean off the voxel tags"));
        char pfx[512];
        std::snprintf(pfx, sizeof pfx, "%s/%s_%s_f%d", out.c_str(),
                      f.label.c_str(), which ? "vm" : "af", F);
        write_field(pfx, occ, d.nx * F, d.ny * F, d.nz * F, h / F, meta, note,
                    vf_of(which ? inside_effective(off)
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
