// The sample block (topopt/lattice_sample.hpp states the contract).

#include "topopt/lattice_sample.hpp"

#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>

#include "topopt/lattice.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/lattice_types.hpp"
#include "topopt/tpms_gen.hpp"

namespace topopt {
namespace {

// An axis-aligned box as 12 outward-wound triangles.
void emit_box(TriangleSink& sink, const Vec3& lo, const Vec3& hi) {
  const Vec3 p[8] = {{lo.x, lo.y, lo.z}, {hi.x, lo.y, lo.z}, {hi.x, hi.y, lo.z},
                     {lo.x, hi.y, lo.z}, {lo.x, lo.y, hi.z}, {hi.x, lo.y, hi.z},
                     {hi.x, hi.y, hi.z}, {lo.x, hi.y, hi.z}};
  const int f[12][3] = {{0, 2, 1}, {0, 3, 2},   // bottom (-z)
                        {4, 5, 6}, {4, 6, 7},   // top (+z)
                        {0, 1, 5}, {0, 5, 4},   // -y
                        {2, 3, 7}, {2, 7, 6},   // +y
                        {1, 2, 6}, {1, 6, 5},   // +x
                        {3, 0, 4}, {3, 4, 7}};  // -x
  for (const auto& t : f) sink.add_triangle(p[t[0]], p[t[1]], p[t[2]]);
}

std::string num(double v) {
  char b[64];
  std::snprintf(b, sizeof b, "%.6g", v);
  return b;
}

}  // namespace

LatticeSampleReceipt write_lattice_sample(const LatticeSampleSpec& spec, TriangleSink& sink) {
  if (spec.shape == "coupon") return write_lattice_coupon(spec, sink);
  if (spec.shape != "cube")
    throw std::invalid_argument("lattice-sample: --shape is \"cube\" or \"coupon\" (got \"" +
                                spec.shape + "\")");
  const LatticeGenTopology gt = lattice_gen_topology_from_id(spec.topology);
  const LatticeTopology t = lattice_gen_certificate_topology(gt);
  if (!(spec.cell_mm > 0.0) || !(spec.size_mm > 0.0) || !(spec.plate_mm >= 0.0))
    throw std::invalid_argument("lattice-sample: cell, size must be > 0 and plate >= 0");
  const double n_real = spec.size_mm / spec.cell_mm;
  const int n = static_cast<int>(std::lround(n_real));
  if (n < 1 || std::fabs(n_real - n) > 1e-9)
    throw std::invalid_argument(
        "lattice-sample: --size " + num(spec.size_mm) + " is not a whole number of " +
        num(spec.cell_mm) + " mm cells; a part cell would print a different lattice");

  LatticeSampleReceipt r;
  r.topology = spec.topology;
  r.band_min = lattice_rho_min(t);
  r.band_max = lattice_rho_max(t);
  r.rho_was_band_middle = !(spec.rho > 0.0);
  r.rho = r.rho_was_band_middle ? 0.5 * (r.band_min + r.band_max) : spec.rho;
  if (!(r.rho >= r.band_min && r.rho <= r.band_max))
    throw std::invalid_argument(
        "lattice-sample: --rho " + num(r.rho) + " is outside " + spec.topology +
        "'s certifiable band [" + num(r.band_min) + ", " + num(r.band_max) + "]");
  r.cell_mm = spec.cell_mm;
  r.cells_per_side = n;
  r.size_mm = spec.size_mm;
  r.plate_mm = spec.plate_mm;
  r.strut_diameter_mm = lattice_strut_diameter_mm(t, r.rho, spec.cell_mm);
  if (spec.bead_mm > 0.0 && r.strut_diameter_mm + 1e-12 < spec.bead_mm)
    throw std::invalid_argument(
        "lattice-sample: a " + spec.topology + " strut at rho " + num(r.rho) + " in a " +
        num(spec.cell_mm) + " mm cell is " + num(r.strut_diameter_mm) +
        " mm, thinner than the " + num(spec.bead_mm) +
        " mm bead. Raise --rho or --cell.");

  if (spec.plate_mm > 0.0) {
    emit_box(sink, Vec3{0.0, 0.0, 0.0}, Vec3{spec.size_mm, spec.size_mm, spec.plate_mm});
    r.triangles += 12;
  }
  if (lattice_gen_is_sheet(gt)) {
    // A sheet: the TPMS wall over the same cube, the TRUE wall from the type's law (the
    // receipt's "strut_diameter_mm" is that wall), the field parameter from the wall law.
    // Both sheets pass through every cell corner (f = 0 there), so a block cut on cell
    // lines leaves a cap at a corner that joins nothing: measured, a 12-triangle gyroid
    // piece and a 48-triangle Schwarz-D piece at the far top corner of the 40 mm block,
    // which would print as a loose speck. So the sample shifts the sheet an eighth of a
    // cell, where both fields are at their maximum (the middle of a channel, the farthest
    // point from the wall), and clips it to the cube: no corner of the block meets the
    // wall. The clip box reaches one DC cell past the cube (the generator erodes its clip
    // by one) and down into the plate, so the sheet fills the cube and stands on the plate.
    const double s = spec.cell_mm / 8.0;
    TpmsGenOptions o;
    o.min_wall_mm = r.strut_diameter_mm;
    o.dc_cell_mm = r.strut_diameter_mm / 3.0;  // the generator's own default, stated
    const double h = o.dc_cell_mm;
    LatticeBoundary cube;
    cube.add_box(Vec3{-h, -h, 0.5 * spec.plate_mm},
                 Vec3{spec.size_mm + h, spec.size_mm + h, spec.plate_mm + spec.size_mm + h});
    TpmsRegion TR;
    TR.anchor = Vec3{-s, -s, spec.plate_mm - s};
    TR.nx = TR.ny = TR.nz = n + 1;
    TR.cell_mm = spec.cell_mm;
    TR.boundary = &cube;
    TpmsWallField W;
    W.uniform_mm = lattice_sheet_wall_param_mm(t, r.strut_diameter_mm, spec.cell_mm);
    // ★ Finding 8: simplified to within kSheetMaxDeviationMm of the true surface; with a
    // bead, no wall is cut below it.
    o.max_deviation_mm = kSheetMaxDeviationMm;
    o.bead_mm = spec.bead_mm;
    const double wall = r.strut_diameter_mm, cell = spec.cell_mm;
    o.true_wall_mm = [wall](const Vec3&) { return wall; };
    o.wall_param_of = [t, cell](double w) { return lattice_sheet_wall_param_mm(t, w, cell); };
    const TpmsGenStats ts = generate_tpms(
        gt == LatticeGenTopology::Gyroid ? TpmsKind::Gyroid : TpmsKind::SchwarzD, TR, W, sink, o);
    r.lattice_triangles_contoured = static_cast<unsigned long long>(ts.simplify.triangles_in);
    r.lattice_triangles = static_cast<unsigned long long>(ts.simplify.triangles_out);
    r.triangles += r.lattice_triangles;
    r.max_deviation_mm = std::max(ts.simplify.max_out_measured_mm, ts.simplify.max_in_measured_mm);
    r.cut_max_deviation_mm = std::max(ts.simplify.cut_max_out_mm, ts.simplify.cut_max_in_mm);
    return r;
  }
  LatticeRegion R;
  R.origin = Vec3{0.0, 0.0, spec.plate_mm};
  R.nx = R.ny = R.nz = n;
  R.cell_mm = spec.cell_mm;
  LatticeRadiusField G;
  G.uniform_mm = 0.5 * r.strut_diameter_mm;
  const LatticeGenStats st = generate_lattice(gt, R, G, sink);
  r.lattice_triangles = st.triangles;
  r.triangles += st.triangles;
  r.struts = st.struts;
  r.nodes = st.nodes;
  return r;
}

TriangleMesh lattice_sample_mesh(const LatticeSampleSpec& spec, LatticeSampleReceipt* receipt) {
  struct Soup : TriangleSink {
    TriangleMesh m;
    void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override {
      const int i = static_cast<int>(m.vertices.size());
      m.vertices.push_back(a);
      m.vertices.push_back(b);
      m.vertices.push_back(c);
      m.triangles.push_back({i, i + 1, i + 2});
    }
  } soup;
  const LatticeSampleReceipt r = write_lattice_sample(spec, soup);
  if (receipt) *receipt = r;
  return soup.m;
}

std::string lattice_sample_receipt_json(const LatticeSampleReceipt& r) {
  std::string s = "{\n";
  s += "  \"topology\": \"" + r.topology + "\",\n";
  if (r.shape == "coupon") {
    s += "  \"shape\": \"coupon\",\n";
    s += "  \"dimensions_mm\": [" + num(r.coupon_dims_mm[0]) + ", " + num(r.coupon_dims_mm[1]) +
         ", " + num(r.coupon_dims_mm[2]) + "],\n";
    s += "  \"bead_mm\": " + num(r.bead_mm) + ",\n";
    s += "  \"relative_density_graded\": [" + num(r.rho_lo) + ", " + num(r.rho_hi) + "],\n";
    s += "  \"step\": \"" + r.step + "\",\n";
    if (r.step != "none") s += "  \"step_at_x_mm\": " + num(r.step_at_x_mm) + ",\n";
    else s += "  \"step_reason\": \"" + r.step_reason + "\",\n";
    s += "  \"tongue\": \"" + std::string(r.tongue_latticed ? "latticed" : "solid") + "\",\n";
    if (!r.tongue_latticed) s += "  \"tongue_reason\": \"" + r.tongue_reason + "\",\n";
    s += "  \"loose_pieces_dropped\": " + std::to_string(r.loose_pieces_dropped) + ",\n";
    s += "  \"loose_triangles_dropped\": " + std::to_string(r.loose_triangles_dropped) + ",\n";
  }
  const std::string note = lattice_type_directional_note(r.topology);
  if (!note.empty()) s += "  \"directional_note\": \"" + note + "\",\n";
  s += "  \"relative_density\": " + num(r.rho) + ",\n";
  s += "  \"relative_density_is_band_middle\": " +
       std::string(r.rho_was_band_middle ? "true" : "false") + ",\n";
  s += "  \"band\": [" + num(r.band_min) + ", " + num(r.band_max) + "],\n";
  s += "  \"cell_mm\": " + num(r.cell_mm) + ",\n";
  s += "  \"cells_per_side\": " + std::to_string(r.cells_per_side) + ",\n";
  s += "  \"size_mm\": " + num(r.size_mm) + ",\n";
  s += "  \"base_plate_mm\": " + num(r.plate_mm) + ",\n";
  s += "  \"strut_diameter_mm\": " + num(r.strut_diameter_mm) + ",\n";
  s += "  \"triangles\": " + std::to_string(r.triangles) + ",\n";
  s += "  \"lattice_triangles\": " + std::to_string(r.lattice_triangles) + ",\n";
  s += "  \"struts\": " + std::to_string(r.struts) + ",\n";
  if (r.lattice_triangles_contoured > 0) {
    s += "  \"lattice_triangles_contoured\": " + std::to_string(r.lattice_triangles_contoured) +
         ",\n";
    s += "  \"max_deviation_mm\": " + num(r.max_deviation_mm) + ",\n";
    s += "  \"cut_max_deviation_mm\": " + num(r.cut_max_deviation_mm) + ",\n";
  }
  s += "  \"nodes\": " + std::to_string(r.nodes) + "\n";
  s += "}\n";
  return s;
}

}  // namespace topopt
