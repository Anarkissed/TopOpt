// external_field_surface_probe — S2's measuring end, task
// 2026-08-09-reference-implementation-bakeoff.
//
// THE POINT OF THE WHOLE TASK is that the geometry a THIRD-PARTY optimiser
// produces on his part gets measured by OUR instruments, on the same rows as
// SIMP's and SEMDOT's. A number produced by GridapTopOpt's own post-processing
// and a number produced by PR 299's `deviation_from_cad` are not the same
// number, and the five refusals so far are all on the second kind.
//
// So this probe reads an EXTERNAL scalar field — anything, from anywhere,
// delivered as raw float64 on a stated lattice — and puts it through the exact
// path PR 319's `semdot_surface_probe` puts a design.bin through:
//
//     extract -> PR 307's CAD/cut classifier -> PR 299's oblique mask ->
//     deviation_from_cad + dihedral_rms_deg -> PR 306's controls
//
// `stairstep_metric.hpp` and `surface_instruments.hpp` are INCLUDED, not
// retyped (bar R2). The classifier is `attribute_to_cad_faces`. The one thing
// that is new here is the plumbing that lets a non-design.bin field enter, and
// it is deliberately dumb: no interpolation, no normalisation, no iso guessing.
//
//   cmake --build build --target external_field_surface_probe
//   ./build/external_field_surface_probe <ref/design.bin> <part.step> <out_dir> \
//        [<label>=<prefix> ...]
//
// The reference design.bin supplies HIS grid (128 x 31 x 118, spacing, origin)
// and contributes the four SIMP rows itself, so every run of this probe carries
// its own baseline and no row is ever compared against a remembered number.
//
// ── AN EXTERNAL ARM: <prefix>.f64 + <prefix>.meta ───────────────────────────
//
// `<prefix>.f64` is nx*ny*nz float64, x-fastest then y then z. `<prefix>.meta`
// is `key value` lines, one per line:
//
//   rung      0.68            the ladder rung this field is (a label)
//   nx ny nz  <int>           the field's own lattice
//   spacing   <mm>            its spacing
//   ox oy oz  <mm>            the position of sample (0,0,0) MINUS half a
//                             spacing on each axis — i.e. the `origin` argument
//                             marching_cubes wants, since it puts sample (i,j,k)
//                             at origin + (i+0.5)*spacing. A CELL-centred field
//                             on his lattice passes his origin unchanged; a
//                             NODE-sampled field passes his origin - h/2.
//   iso       0.5             the level to extract
//   factor    2               tessellation factor; 2 is the shipped export
//   interp    tricubic|none   the resample; `none` forces factor 1
//   achieved_vf / iterations / wall_s / compliance   optional, reported as given
//
// ── THE ONE JUDGEMENT THIS FILE MAKES, STATED ──────────────────────────────
//
// It requires the field to arrive as an OCCUPANCY: 0 = void, 1 = solid, iso
// between them, background outside the lattice = 0. A level-set function is not
// that — φ is negative inside and unbounded outside, and marching cubes' own
// one-layer zero pad would read φ's background as SOLID.
//
// ★ THE CONVERSION IS THE PRODUCER'S JOB, NOT THIS PROBE'S, and that is the
// whole reason it is not done here. GridapTopOpt already carries the function:
// `SmoothErsatzMaterialInterpolation`'s ρ, the relaxed Heaviside its own volume
// constraint integrates, with ρ(0) = 0.5 exactly. Exporting ρ(φ) rather than φ
// means the iso, the bandwidth and the void convention are all THEIRS, and this
// probe stays a measuring instrument rather than a sixth implementation of
// somebody else's idea. If a future producer has no such function, it must say
// what it used — not leave the choice to be made silently in here.

#include "topopt/cad_project.hpp"
#include "topopt/design_store.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include "stairstep_metric.hpp"
#include "surface_instruments.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

using namespace topopt;
using namespace topopt::stairstep;
using namespace topopt::surface_instruments;

namespace {

// THE SHIPPED EXPORT, as PR 319's probe and `cut_population_probe` reproduce it:
// run_job extracts the variant mesh at output.smooth_factor with a tricubic
// resample and keeps the largest component.
constexpr int kShippedFactor = 2;

TriangleMesh extract(int nx, int ny, int nz, double spacing, const Vec3& origin,
                     const std::vector<double>& f, double iso, int factor,
                     bool tricubic) {
  return keep_largest_component(marching_cubes_resampled(
      nx, ny, nz, spacing, origin, f, iso, factor,
      tricubic ? ResampleInterp::Tricubic : ResampleInterp::Trilinear));
}

// The triangles all of whose vertices are in `only`, as a standalone mesh — so
// `dihedral_rms_deg` runs on a POPULATION without being rewritten. Verbatim from
// PR 319's semdot_surface_probe.
TriangleMesh submesh(const TriangleMesh& m, const std::vector<char>& only) {
  TriangleMesh out;
  std::vector<int> remap(m.vertices.size(), -1);
  for (const auto& tr : m.triangles) {
    if (!only[static_cast<std::size_t>(tr[0])] ||
        !only[static_cast<std::size_t>(tr[1])] ||
        !only[static_cast<std::size_t>(tr[2])])
      continue;
    std::array<int, 3> t{};
    for (int k = 0; k < 3; ++k) {
      const int v = tr[static_cast<std::size_t>(k)];
      if (remap[static_cast<std::size_t>(v)] < 0) {
        remap[static_cast<std::size_t>(v)] = static_cast<int>(out.vertices.size());
        out.vertices.push_back(m.vertices[static_cast<std::size_t>(v)]);
      }
      t[static_cast<std::size_t>(k)] = remap[static_cast<std::size_t>(v)];
    }
    out.triangles.push_back(t);
  }
  return out;
}

// ── THE FIELD READING, on whatever lattice the field arrived on ────────────
// PR 315's measurement, verbatim in structure from PR 319's probe: a voxel is a
// BOUNDARY voxel when one of its six neighbours is on the other side of the iso,
// reading outside the lattice as background 0 — marching cubes' own rule.
struct FieldStats {
  std::size_t boundary_voxels = 0;
  std::size_t binary_boundary = 0;
  std::size_t fractional_voxels = 0;
  double crossing_rms_frac = 0.0;
  double crossing_rms_mm = 0.0;
  std::size_t crossings = 0;
  double midpoint_share = 0.0;
};

FieldStats field_stats(int nx, int ny, int nz, double spacing,
                       const std::vector<double>& d, double iso, double band_lo,
                       double band_hi) {
  FieldStats s;
  auto idx = [&](int i, int j, int k) {
    return (static_cast<std::size_t>(k) * static_cast<std::size_t>(ny) +
            static_cast<std::size_t>(j)) * static_cast<std::size_t>(nx) +
           static_cast<std::size_t>(i);
  };
  auto at = [&](int i, int j, int k) -> double {
    if (i < 0 || j < 0 || k < 0 || i >= nx || j >= ny || k >= nz) return 0.0;
    return d[idx(i, j, k)];
  };
  double sum2 = 0.0;
  std::size_t near_mid = 0;
  const int off[6][3] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const double a = d[idx(i, j, k)];
        if (a > 0.0 && a < 1.0) ++s.fractional_voxels;
        bool boundary = false;
        for (const auto& o : off)
          if ((a > iso) != (at(i + o[0], j + o[1], k + o[2]) > iso)) boundary = true;
        if (!boundary) continue;
        ++s.boundary_voxels;
        if (a <= band_lo || a >= band_hi) ++s.binary_boundary;
        for (int e = 0; e < 3; ++e) {
          const double b = at(i + (e == 0), j + (e == 1), k + (e == 2));
          if ((a > iso) == (b > iso)) continue;
          if (a == b) continue;
          const double frac = (iso - a) / (b - a);
          const double off_mid = std::fabs(frac - 0.5);
          sum2 += off_mid * off_mid;
          if (off_mid < 0.01) ++near_mid;
          ++s.crossings;
        }
      }
  if (s.crossings) {
    s.crossing_rms_frac = std::sqrt(sum2 / static_cast<double>(s.crossings));
    s.crossing_rms_mm = s.crossing_rms_frac * spacing;
    s.midpoint_share = static_cast<double>(near_mid) /
                       static_cast<double>(s.crossings);
  }
  return s;
}

struct ArmRow {
  std::string arm, rung;
  double requested_vf = 0.0, achieved_vf = 0.0;
  double margin_worst = 0.0, margin_eff = 0.0, max_vm = 0.0;
  int accepted = -1;          // -1 = not certified by core (an external arm)
  int iterations = 0;
  double wall_s = 0.0, compliance = 0.0;
  std::size_t verts = 0, tris = 0;
  std::size_t n_cad = 0, n_cut = 0, n_amb = 0, n_oblique = 0;
  Deviation obl_all, obl_cad, obl_cut;
  double dih_all = 0.0, dih_cut = 0.0, dih_cad = 0.0;
  // The like-for-like columns (see ref_region_mask): the dihedral RMS over the
  // region the REFERENCE classified CUT / CAD, so every arm is measured over the
  // SAME part of space and a changed cut population cannot move the number.
  // 0 when no reference mask was supplied.
  double dih_refcut = 0.0, dih_refcad = 0.0;
  std::size_t n_refcut = 0, n_refcad = 0;
  double volume_mm3 = 0.0, min_section_mm2 = 0.0;
  int min_feature = 0;
  FieldStats field;
  double field_spacing = 0.0;
  std::string lattice;        // "design" | "node" | free text from the meta
};

std::map<std::string, std::string> read_meta(const std::string& path) {
  std::map<std::string, std::string> m;
  std::ifstream f(path);
  if (!f) { std::printf("FATAL: cannot read %s\n", path.c_str()); std::exit(2); }
  std::string line;
  while (std::getline(f, line)) {
    if (line.empty() || line[0] == '#') continue;
    std::istringstream ss(line);
    std::string k, v;
    ss >> k;
    std::getline(ss, v);
    while (!v.empty() && (v.front() == ' ' || v.front() == '\t')) v.erase(v.begin());
    m[k] = v;
  }
  return m;
}

double meta_d(const std::map<std::string, std::string>& m, const char* k, double dflt) {
  const auto it = m.find(k);
  return it == m.end() ? dflt : std::stod(it->second);
}
int meta_i(const std::map<std::string, std::string>& m, const char* k, int dflt) {
  const auto it = m.find(k);
  return it == m.end() ? dflt : std::stoi(it->second);
}
std::string meta_s(const std::map<std::string, std::string>& m, const char* k,
                   const char* dflt) {
  const auto it = m.find(k);
  return it == m.end() ? std::string(dflt) : it->second;
}

// ── A FIXED TRIANGLE SET, SO ONE COLUMN COMPARES LIKE WITH LIKE ────────────
//
// ★ WHY THIS EXISTS. `dih_cut` restricts each arm to the triangles THAT ARM's
// own classifier called CUT, and the two arms do not have the same cut
// population: PR 323 measured the level set's cut share at 36.2% against SIMP's
// 18.4% ON ITS FIRST ITERATION, before the optimiser had moved anything of
// consequence. An eta = 2 ersatz offsets the extracted surface away from the CAD
// faces, so triangles that are CAD for SIMP are CUT for the level set, and part
// of "+2.2 deg of cut roughness" is therefore two different sets of triangles
// being compared rather than two different surfaces.
//
// The honest fix is not to make the two meshes share triangles — they cannot,
// they are different meshes — but to measure both over THE SAME PART OF SPACE.
// This builds an occupancy mask of the voxels the REFERENCE's cut surface
// passes through, dilated by one voxel so a surface that has moved sub-voxel is
// still inside it, and every arm then reports a dihedral RMS restricted to the
// triangles whose vertices fall in that mask.
//
// ★ WHAT IT IS AND IS NOT. It is a SPATIAL restriction, so it answers "over the
// region SIMP cuts, is our surface rougher than SIMP's?" — a question with one
// population and one answer. It is NOT a claim that the two meshes are
// triangle-for-triangle comparable, and it does not replace `dih_all`, which is
// already population-independent and is reported beside it.
std::vector<char> ref_region_mask(const TriangleMesh& ref,
                                  const std::vector<char>& ref_sel,
                                  const VoxelGrid& g) {
  const std::size_t n = g.voxel_count();
  std::vector<char> hit(n, 0);
  auto vox = [&](const Vec3& p, int& i, int& j, int& k) {
    i = static_cast<int>(std::floor((p.x - g.origin.x) / g.spacing));
    j = static_cast<int>(std::floor((p.y - g.origin.y) / g.spacing));
    k = static_cast<int>(std::floor((p.z - g.origin.z) / g.spacing));
  };
  for (std::size_t v = 0; v < ref.vertices.size(); ++v) {
    if (!ref_sel[v]) continue;
    int i, j, k;
    vox(ref.vertices[v], i, j, k);
    // Dilate by one voxel on each axis: the comparison surface has moved by up
    // to a band width, and a mask that excluded it would measure emptiness.
    for (int dk = -1; dk <= 1; ++dk)
      for (int dj = -1; dj <= 1; ++dj)
        for (int di = -1; di <= 1; ++di) {
          const int a = i + di, b = j + dj, c = k + dk;
          if (a < 0 || a >= g.nx || b < 0 || b >= g.ny || c < 0 || c >= g.nz)
            continue;
          hit[static_cast<std::size_t>(a) +
              static_cast<std::size_t>(g.nx) *
                  (static_cast<std::size_t>(b) +
                   static_cast<std::size_t>(g.ny) * static_cast<std::size_t>(c))] = 1;
        }
  }
  return hit;
}

// The vertices of `subject` that fall inside a mask built by ref_region_mask.
std::vector<char> in_region(const TriangleMesh& subject,
                            const std::vector<char>& mask, const VoxelGrid& g) {
  std::vector<char> sel(subject.vertices.size(), 0);
  for (std::size_t v = 0; v < subject.vertices.size(); ++v) {
    const Vec3& p = subject.vertices[v];
    const int i = static_cast<int>(std::floor((p.x - g.origin.x) / g.spacing));
    const int j = static_cast<int>(std::floor((p.y - g.origin.y) / g.spacing));
    const int k = static_cast<int>(std::floor((p.z - g.origin.z) / g.spacing));
    if (i < 0 || i >= g.nx || j < 0 || j >= g.ny || k < 0 || k >= g.nz) continue;
    sel[v] = mask[static_cast<std::size_t>(i) +
                  static_cast<std::size_t>(g.nx) *
                      (static_cast<std::size_t>(j) +
                       static_cast<std::size_t>(g.ny) *
                           static_cast<std::size_t>(k))];
  }
  return sel;
}

// ── the measurement, shared by every arm ───────────────────────────────────
// One function, so a SIMP row and a GridapTopOpt row cannot diverge by which
// branch built them.
//
// `ref_cut_mask` / `ref_cad_mask`, when non-null, are the spatial masks above:
// the arm additionally reports its dihedral RMS over the region the REFERENCE
// classified CUT (and CAD), which is the one column in this table that compares
// the same part of space across arms.
void measure(ArmRow& row, const TriangleMesh& subject, const StepModel& model,
             const TriGrid& cad_ref, const CadProjectOptions& copts,
             const VoxelGrid& his_grid,
             const std::vector<char>* ref_cut_mask = nullptr,
             const std::vector<char>* ref_cad_mask = nullptr) {
  row.verts = subject.vertices.size();
  row.tris = subject.triangles.size();
  if (subject.vertices.empty()) return;

  const CadAttribution att = attribute_to_cad_faces(subject, model, copts);
  std::vector<char> cad(subject.vertices.size(), 0);
  std::vector<char> cut(subject.vertices.size(), 0);
  for (std::size_t v = 0; v < subject.vertices.size(); ++v) {
    if (att.face_of_vertex[v] >= 0) { cad[v] = 1; ++row.n_cad; }
    else if (att.ambiguous_at(v)) { ++row.n_amb; }
    else { cut[v] = 1; ++row.n_cut; }
  }

  std::vector<char> oblique(subject.vertices.size(), 0);
  for (std::size_t v = 0; v < subject.vertices.size(); ++v) {
    const auto dt = cad_ref.distance_and_tri(subject.vertices[v]);
    if (dt.second < 0) continue;
    const Vec3 n = cad_ref.tri_normal(dt.second);
    const double m = std::fmax(std::fabs(n.x), std::fmax(std::fabs(n.y), std::fabs(n.z)));
    if (m < 0.98) { oblique[v] = 1; ++row.n_oblique; }
  }
  std::vector<char> obl_cad(subject.vertices.size(), 0);
  std::vector<char> obl_cut(subject.vertices.size(), 0);
  for (std::size_t v = 0; v < subject.vertices.size(); ++v) {
    obl_cad[v] = static_cast<char>(oblique[v] && cad[v]);
    obl_cut[v] = static_cast<char>(oblique[v] && cut[v]);
  }

  row.obl_all = deviation_from_cad(subject, cad_ref, oblique);
  row.obl_cad = deviation_from_cad(subject, cad_ref, obl_cad);
  row.obl_cut = deviation_from_cad(subject, cad_ref, obl_cut);
  row.dih_all = dihedral_rms_deg(subject);
  row.dih_cut = dihedral_rms_deg(submesh(subject, cut));
  row.dih_cad = dihedral_rms_deg(submesh(subject, cad));
  // The like-for-like columns: the SAME REGION OF SPACE on every arm.
  if (ref_cut_mask) {
    const std::vector<char> sel = in_region(subject, *ref_cut_mask, his_grid);
    row.n_refcut = 0;
    for (char c : sel) row.n_refcut += c ? 1u : 0u;
    row.dih_refcut = dihedral_rms_deg(submesh(subject, sel));
  }
  if (ref_cad_mask) {
    const std::vector<char> sel = in_region(subject, *ref_cad_mask, his_grid);
    row.n_refcad = 0;
    for (char c : sel) row.n_refcad += c ? 1u : 0u;
    row.dih_refcad = dihedral_rms_deg(submesh(subject, sel));
  }
  row.volume_mm3 = std::fabs(signed_volume(subject));
  // ALWAYS HIS GRID for the two controls, never the arm's own lattice: a
  // min-feature count measured against a finer reference is a different
  // question, and PR 299 requires these two to be comparable across arms.
  const CrossSection cs = min_cross_section(subject, his_grid);
  row.min_section_mm2 = cs.valid ? cs.min_mm : 0.0;
  row.min_feature = min_feature_now(subject, his_grid);
}

void print_row(const ArmRow& r, double his_spacing) {
  std::printf("\n---------------------------------------------------------------\n");
  std::printf("%s  rung %s   %zu verts / %zu tris   iterations %d   wall %.1f s\n",
              r.arm.c_str(), r.rung.c_str(), r.verts, r.tris, r.iterations, r.wall_s);
  std::printf("---------------------------------------------------------------\n");
  std::printf("  vf requested %.4f   achieved %.6f   (miss %+.6f)\n",
              r.requested_vf, r.achieved_vf, r.achieved_vf - r.requested_vf);
  if (r.accepted >= 0)
    std::printf("  margin worst %.4f   effective %.4f   max vM %.4f MPa   accepted %s\n",
                r.margin_worst, r.margin_eff, r.max_vm, r.accepted ? "yes" : "no");
  else
    std::printf("  margin — NOT CERTIFIED BY CORE (external arm; see the handoff's §S4b)\n");
  if (!r.verts) { std::printf("  EMPTY MESH — nothing extracted\n"); return; }
  std::printf("  SPLIT: CAD %zu (%.2f%%)  ambiguous %zu (%.2f%%)  CUT %zu (%.2f%%)"
              "   oblique %zu (%.2f%%)\n",
              r.n_cad, 100.0 * r.n_cad / r.verts, r.n_amb, 100.0 * r.n_amb / r.verts,
              r.n_cut, 100.0 * r.n_cut / r.verts, r.n_oblique,
              100.0 * r.n_oblique / r.verts);
  std::printf("  ★ STAIR-STEP AMPLITUDE (PR 299's metric, oblique CAD surface)\n");
  std::printf("      oblique ALL   rms %.4f mm  max %.4f  p99 %.4f  (%.1f%% of a voxel)\n",
              r.obl_all.rms_mm, r.obl_all.max_mm, r.obl_all.p99_mm,
              100.0 * r.obl_all.rms_mm / his_spacing);
  std::printf("      oblique CAD   rms %.4f mm  max %.4f  p99 %.4f\n",
              r.obl_cad.rms_mm, r.obl_cad.max_mm, r.obl_cad.p99_mm);
  std::printf("      oblique CUT   rms %.4f mm  (NOT an error — no reference exists"
              " there; PR 314)\n", r.obl_cut.rms_mm);
  std::printf("  ★ ROUGHNESS (rms dihedral, same instrument, restricted populations)\n");
  std::printf("      whole mesh %.4f deg    CUT %.4f deg    CAD %.4f deg\n",
              r.dih_all, r.dih_cut, r.dih_cad);
  if (r.n_refcut || r.n_refcad)
    std::printf("      ★ LIKE-FOR-LIKE, over the REFERENCE's regions (same part of\n"
                "        space on every arm): refCUT %.4f deg (%zu verts)   "
                "refCAD %.4f deg (%zu verts)\n",
                r.dih_refcut, r.n_refcut, r.dih_refcad, r.n_refcad);
  std::printf("  CONTROLS: volume %.1f mm3   min section %.4f mm2   min-feature %d\n",
              r.volume_mm3, r.min_section_mm2, r.min_feature);
  std::printf("  ★ THE FIELD, on the %s lattice (spacing %.6f mm)\n",
              r.lattice.c_str(), r.field_spacing);
  std::printf("      boundary samples %zu   binary at a band end %zu (%.2f%%)\n",
              r.field.boundary_voxels, r.field.binary_boundary,
              r.field.boundary_voxels
                  ? 100.0 * r.field.binary_boundary / r.field.boundary_voxels : 0.0);
  std::printf("      fractional samples (0<v<1): %zu\n", r.field.fractional_voxels);
  std::printf("      MC crossings %zu   |frac-0.5| rms %.6f = %.4f mm   "
              "within 1%% of midpoint %.2f%%\n",
              r.field.crossings, r.field.crossing_rms_frac, r.field.crossing_rms_mm,
              100.0 * r.field.midpoint_share);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    std::printf("usage: external_field_surface_probe <ref/design.bin> <part.step>"
                " <out_dir> [<label>=<prefix> ...]\n");
    return 2;
  }
  const std::string ref_path = argv[1];
  const std::string step_path = argv[2];
  const std::string ev = argv[3];

  const StepModel model = import_part_file_resolved(step_path);
  if (model.mesh.vertices.empty()) {
    std::printf("FATAL: the STEP imported empty — OCCT is required for this probe\n");
    return 2;
  }
  const TriGrid cad_ref(model.mesh);

  DesignStore store = read_design_file(ref_path);
  VoxelGrid grid;
  grid.nx = store.nx; grid.ny = store.ny; grid.nz = store.nz;
  grid.spacing = store.spacing; grid.origin = store.origin;
  grid.tags.assign(store.voxel_count(), VoxelTag::Empty);
  const CadProjectOptions copts = cad_project_options_for_grid(grid.spacing);

  std::printf("== external_field_surface_probe — S2 on HIS OWN PART ==\n\n");
  std::printf("reference  %s\n", ref_path.c_str());
  std::printf("part       %s (%zu faces, %zu tessellation triangles)\n",
              step_path.c_str(), model.faces.size(), model.mesh.triangles.size());
  std::printf("grid       %d x %d x %d, spacing %.6f mm, origin (%.4f, %.4f, %.4f)\n",
              grid.nx, grid.ny, grid.nz, grid.spacing, grid.origin.x, grid.origin.y,
              grid.origin.z);
  std::printf("classifier tolerance %.6f mm\n", copts.tolerance_mm);

  std::vector<ArmRow> rows;

  // ── THE LIKE-FOR-LIKE REGION, built from the reference's TOP rung ─────────
  //
  // The masks are built ONCE, from the first (heaviest) rung in the reference
  // design.bin — his 0.68, the rung every arm in this table targets — and then
  // handed to every arm including the SIMP rows themselves. So the SIMP 0.68 row
  // reports its own roughness over its own cut region, which is the control that
  // makes the column readable: it is by construction the number `dih_cut`
  // already gives it, up to the one-voxel dilation.
  std::vector<char> ref_cut_mask, ref_cad_mask;
  bool have_masks = false;
  if (!store.variants.empty()) {
    const StoredDesign& ref0 = store.variants.front();
    const TriangleMesh rm = extract(grid.nx, grid.ny, grid.nz, grid.spacing,
                                    grid.origin, ref0.density, 0.5,
                                    kShippedFactor, true);
    const CadAttribution ratt = attribute_to_cad_faces(rm, model, copts);
    std::vector<char> rcut(rm.vertices.size(), 0), rcad(rm.vertices.size(), 0);
    for (std::size_t v = 0; v < rm.vertices.size(); ++v) {
      if (ratt.face_of_vertex[v] >= 0) rcad[v] = 1;
      else if (!ratt.ambiguous_at(v)) rcut[v] = 1;
    }
    ref_cut_mask = ref_region_mask(rm, rcut, grid);
    ref_cad_mask = ref_region_mask(rm, rcad, grid);
    have_masks = true;
    std::size_t ncut = 0, ncad = 0;
    for (char c : ref_cut_mask) ncut += c ? 1u : 0u;
    for (char c : ref_cad_mask) ncad += c ? 1u : 0u;
    std::printf("like-for-like  reference rung %.2f: CUT region %zu voxels, "
                "CAD region %zu voxels (dilated 1)\n",
                ref0.requested_volume_fraction, ncut, ncad);
  }
  const std::vector<char>* pcut = have_masks ? &ref_cut_mask : nullptr;
  const std::vector<char>* pcad = have_masks ? &ref_cad_mask : nullptr;

  // ── the SIMP baseline, from the reference design.bin ──────────────────────
  std::printf("\n#####################################################################\n");
  std::printf("# ARM SIMP — the run of record, re-measured here so no row in this\n");
  std::printf("#            table is compared against a remembered number\n");
  std::printf("#####################################################################\n");
  for (std::size_t r = 0; r < store.variants.size(); ++r) {
    const StoredDesign& d = store.variants[r];
    ArmRow row;
    row.arm = "SIMP";
    char rung[64];
    std::snprintf(rung, sizeof rung, "%.2f", d.requested_volume_fraction);
    row.rung = rung;
    row.requested_vf = d.requested_volume_fraction;
    row.achieved_vf = d.achieved_volume_fraction;
    row.margin_worst = d.margin_worst_case;
    row.margin_eff = d.margin_effective;
    row.max_vm = d.max_von_mises_mpa;
    row.accepted = d.accepted ? 1 : 0;
    row.iterations = d.iterations;
    row.lattice = "design";
    row.field_spacing = grid.spacing;
    row.field = field_stats(grid.nx, grid.ny, grid.nz, grid.spacing, d.density,
                            0.5, 0.05047, 0.89988);
    const TriangleMesh subject = extract(grid.nx, grid.ny, grid.nz, grid.spacing,
                                         grid.origin, d.density, 0.5,
                                         kShippedFactor, true);
    measure(row, subject, model, cad_ref, copts, grid, pcut, pcad);
    print_row(row, grid.spacing);
    rows.push_back(row);
  }

  // ── every external arm ────────────────────────────────────────────────────
  for (int a = 4; a < argc; ++a) {
    const std::string spec = argv[a];
    const std::size_t eq = spec.find('=');
    if (eq == std::string::npos) {
      std::printf("FATAL: arm spec '%s' is not <label>=<prefix>\n", spec.c_str());
      return 2;
    }
    const std::string label = spec.substr(0, eq);
    const std::string prefix = spec.substr(eq + 1);
    const auto meta = read_meta(prefix + ".meta");

    ArmRow row;
    row.arm = label;
    row.rung = meta_s(meta, "rung", "?");
    row.requested_vf = meta_d(meta, "requested_vf", 0.0);
    row.achieved_vf = meta_d(meta, "achieved_vf", 0.0);
    row.iterations = meta_i(meta, "iterations", 0);
    row.wall_s = meta_d(meta, "wall_s", 0.0);
    row.compliance = meta_d(meta, "compliance", 0.0);
    row.lattice = meta_s(meta, "lattice", "external");

    const int fnx = meta_i(meta, "nx", grid.nx);
    const int fny = meta_i(meta, "ny", grid.ny);
    const int fnz = meta_i(meta, "nz", grid.nz);
    const double fh = meta_d(meta, "spacing", grid.spacing);
    const Vec3 forig{meta_d(meta, "ox", grid.origin.x),
                     meta_d(meta, "oy", grid.origin.y),
                     meta_d(meta, "oz", grid.origin.z)};
    const double iso = meta_d(meta, "iso", 0.5);
    const std::string interp = meta_s(meta, "interp", "tricubic");
    const int factor = interp == "none" ? 1 : meta_i(meta, "factor", kShippedFactor);
    row.field_spacing = fh;

    const std::size_t n = static_cast<std::size_t>(fnx) *
                          static_cast<std::size_t>(fny) *
                          static_cast<std::size_t>(fnz);
    std::vector<double> f(n);
    {
      std::ifstream fs(prefix + ".f64", std::ios::binary);
      if (!fs) { std::printf("FATAL: cannot read %s.f64\n", prefix.c_str()); return 2; }
      fs.read(reinterpret_cast<char*>(f.data()),
              static_cast<std::streamsize>(n * sizeof(double)));
      if (fs.gcount() != static_cast<std::streamsize>(n * sizeof(double))) {
        std::printf("FATAL: %s.f64 is %lld bytes, expected %zu (%d x %d x %d float64)\n",
                    prefix.c_str(), static_cast<long long>(fs.gcount()),
                    n * sizeof(double), fnx, fny, fnz);
        return 2;
      }
      // A trailing byte means the producer and this probe disagree about the
      // lattice; that is exactly the silent difference this task exists to
      // avoid, so it is fatal rather than tolerated.
      char extra = 0;
      if (fs.read(&extra, 1)) {
        std::printf("FATAL: %s.f64 has MORE data than %d x %d x %d float64\n",
                    prefix.c_str(), fnx, fny, fnz);
        return 2;
      }
    }

    std::printf("\n#####################################################################\n");
    std::printf("# ARM %s — rung %s, external field %d x %d x %d, spacing %.6f,\n"
                "#   iso %.4f, factor %d (%s), lattice '%s'\n",
                label.c_str(), row.rung.c_str(), fnx, fny, fnz, fh, iso, factor,
                interp.c_str(), row.lattice.c_str());
    std::printf("#####################################################################\n");

    // Range check, printed rather than assumed. An occupancy leaves [0,1]; a raw
    // level set does not, and would be read by marching cubes' zero pad as solid
    // background. See the header note.
    double lo = f.empty() ? 0.0 : f[0], hi = lo;
    for (double v : f) { lo = std::fmin(lo, v); hi = std::fmax(hi, v); }
    std::printf("  field range [%.6f, %.6f]", lo, hi);
    if (lo < -1e-9 || hi > 1.0 + 1e-9)
      std::printf("   ★ OUTSIDE [0,1] — this is not an occupancy; the background"
                  " pad will misread\n");
    else
      std::printf("   (an occupancy, as required)\n");

    row.field = field_stats(fnx, fny, fnz, fh, f, iso, 0.05047, 0.89988);
    const TriangleMesh subject =
        extract(fnx, fny, fnz, fh, forig, f, iso, factor, interp != "trilinear");
    measure(row, subject, model, cad_ref, copts, grid, pcut, pcad);
    print_row(row, grid.spacing);
    rows.push_back(row);
  }

  // ── the CSV, PR 319's column set plus the four external-arm columns ───────
  std::ofstream csv(ev + "/s2_reference_impl_vs_simp.csv");
  csv << "arm,rung,requested_vf,achieved_vf,iterations,wall_s,compliance,"
         "margin_worst_case,margin_effective,max_von_mises_mpa,accepted,verts,"
         "tris,n_cad,n_cut,n_ambiguous,n_oblique,obl_all_rms_mm,obl_all_max_mm,"
         "obl_all_p99_mm,obl_cad_rms_mm,obl_cut_rms_mm,dihedral_all_deg,"
         "dihedral_cut_deg,dihedral_cad_deg,dihedral_refcut_deg,"
         "dihedral_refcad_deg,n_refcut,n_refcad,volume_mm3,min_section_mm2,"
         "min_feature_violations,field_lattice,field_spacing_mm,"
         "boundary_samples,binary_boundary,fractional_samples,crossings,"
         "crossing_rms_frac,crossing_rms_mm,midpoint_share\n";
  csv.setf(std::ios::fixed);
  csv.precision(6);
  for (const ArmRow& r : rows) {
    csv << r.arm << ',' << r.rung << ',' << r.requested_vf << ','
        << r.achieved_vf << ',' << r.iterations << ',' << r.wall_s << ','
        << r.compliance << ',' << r.margin_worst << ',' << r.margin_eff << ','
        << r.max_vm << ',' << r.accepted << ',' << r.verts << ',' << r.tris << ','
        << r.n_cad << ',' << r.n_cut << ',' << r.n_amb << ',' << r.n_oblique << ','
        << r.obl_all.rms_mm << ',' << r.obl_all.max_mm << ',' << r.obl_all.p99_mm
        << ',' << r.obl_cad.rms_mm << ',' << r.obl_cut.rms_mm << ',' << r.dih_all
        << ',' << r.dih_cut << ',' << r.dih_cad << ',' << r.dih_refcut << ','
        << r.dih_refcad << ',' << r.n_refcut << ',' << r.n_refcad << ','
        << r.volume_mm3 << ','
        << r.min_section_mm2 << ',' << r.min_feature << ',' << r.lattice << ','
        << r.field_spacing << ',' << r.field.boundary_voxels << ','
        << r.field.binary_boundary << ',' << r.field.fractional_voxels << ','
        << r.field.crossings << ',' << r.field.crossing_rms_frac << ','
        << r.field.crossing_rms_mm << ',' << r.field.midpoint_share << '\n';
  }
  csv.close();

  // ── the verdict table ─────────────────────────────────────────────────────
  std::printf("\n\n=====================================================================\n");
  std::printf("THE ANSWER — every arm against SIMP, rung by rung\n");
  std::printf("=====================================================================\n");
  std::printf("The headline amplitude is the CAD population. PR 314 settled that the\n"
              "CUT surface has no ground truth, so its distance-to-CAD is a fact about\n"
              "the part's shape and not an error; the CUT column here is therefore the\n"
              "rms DIHEDRAL, which needs no reference. Sub-voxel content is the\n"
              "MECHANISM column and is signed the other way up: bigger = more sub-voxel\n"
              "placement, because a crossing at the edge midpoint IS a staircase.\n\n");
  std::printf("%-22s | %-6s | %-17s | %-17s | %-17s\n", "arm", "rung",
              "amp CAD (mm)", "rough CUT (deg)", "sub-voxel (mm)");
  std::printf("%-22s | %-6s | %8s %8s | %8s %8s | %8s %8s\n", "", "",
              "value", "%better", "value", "%better", "value", "%more");
  auto simp_at = [&rows](const std::string& rung) -> const ArmRow* {
    for (const ArmRow& r : rows)
      if (r.arm == "SIMP" && r.rung == rung) return &r;
    return nullptr;
  };
  auto pct = [](double from, double to) {
    return from > 0.0 ? 100.0 * (from - to) / from : 0.0;
  };
  for (const ArmRow& r : rows) {
    const ArmRow* s = simp_at(r.rung);
    if (r.arm == "SIMP") {
      std::printf("%-22s | %-6s | %8.4f %8s | %8.4f %8s | %8.4f %8s\n",
                  r.arm.c_str(), r.rung.c_str(), r.obl_cad.rms_mm, "—",
                  r.dih_cut, "—", r.field.crossing_rms_mm, "—");
      continue;
    }
    if (!s) {
      std::printf("%-22s | %-6s | NO SIMP ROW AT THIS RUNG — not compared\n",
                  r.arm.c_str(), r.rung.c_str());
      continue;
    }
    std::printf("%-22s | %-6s | %8.4f %+8.1f | %8.4f %+8.1f | %8.4f %+8.0f\n",
                r.arm.c_str(), r.rung.c_str(), r.obl_cad.rms_mm,
                pct(s->obl_cad.rms_mm, r.obl_cad.rms_mm), r.dih_cut,
                pct(s->dih_cut, r.dih_cut), r.field.crossing_rms_mm,
                -pct(s->field.crossing_rms_mm, r.field.crossing_rms_mm));
  }
  std::printf("\nA POSITIVE %% IS THE ARM WINNING. THE BAR IS SIMP, not zero.\n");
  std::printf("\nwrote %s/s2_reference_impl_vs_simp.csv\n", ev.c_str());
  return 0;
}
