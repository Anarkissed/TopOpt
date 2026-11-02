// The sample block (topopt/lattice_sample.hpp states the contract).

#include "topopt/lattice_sample.hpp"

#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>

#include "topopt/lattice.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/lattice_types.hpp"

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

std::string lattice_sample_receipt_json(const LatticeSampleReceipt& r) {
  std::string s = "{\n";
  s += "  \"topology\": \"" + r.topology + "\",\n";
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
  s += "  \"nodes\": " + std::to_string(r.nodes) + "\n";
  s += "}\n";
  return s;
}

}  // namespace topopt
