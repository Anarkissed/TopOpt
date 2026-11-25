// A print coupon per strut type, on the new engine (the reviewer, 2026-11-24, maintainer-approved: every type but the
// octet and bccz carries "Not print-tested" until he prints a sample; each gets a coupon like the 8 mm rim coupon he
// printed on 2026-11-11). See lattice_layout_file.hpp, make_type_coupon.
#include <cmath>
#include <cstdio>
#include <exception>
#include <fstream>
#include <string>

#include "topopt/face_overrides.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice_sample.hpp"
#include "topopt/stl.hpp"

namespace topopt::lattice_layout {
namespace {

// The face whose triangles hold the most area facing straight down (the coupon's underside).
int underside(const StepModel& m) {
  std::vector<double> area(static_cast<std::size_t>(std::max(0, m.face_count)), 0.0);
  for (std::size_t t = 0; t < m.mesh.triangles.size() && t < m.triangle_face.size(); ++t) {
    const int f = m.triangle_face[t];
    if (f < 0 || f >= m.face_count) continue;
    const Vec3& a = m.mesh.vertices[static_cast<std::size_t>(m.mesh.triangles[t][0])];
    const Vec3& b = m.mesh.vertices[static_cast<std::size_t>(m.mesh.triangles[t][1])];
    const Vec3& c = m.mesh.vertices[static_cast<std::size_t>(m.mesh.triangles[t][2])];
    const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z}, w{c.x - a.x, c.y - a.y, c.z - a.z};
    const double nz = u.x * w.y - u.y * w.x;
    const double l = std::sqrt((u.y * w.z - u.z * w.y) * (u.y * w.z - u.z * w.y) +
                               (u.z * w.x - u.x * w.z) * (u.z * w.x - u.x * w.z) + nz * nz);
    if (l > 0.0 && nz / l < -0.99) area[static_cast<std::size_t>(f)] += 0.5 * l;
  }
  int best = -1;
  for (int f = 0; f < m.face_count; ++f)
    if (area[static_cast<std::size_t>(f)] > 0.0 && (best < 0 || area[static_cast<std::size_t>(f)] > area[static_cast<std::size_t>(best)]))
      best = f;
  return best;
}

std::string number(double v) {
  char b[32];
  std::snprintf(b, sizeof b, "%.9g", v);
  return b;
}

}  // namespace

std::string type_coupon_job(const CouponAsk& ask, const std::string& model, int underside_face) {
  return std::string("{\"mode\": \"lattice_file\", \"model\": \"") + model + "\", \"output\": \"" +
         lattice_topology_name(ask.topology) + "_coupon_lattice.stl\", \"layout\": {\"all_lattice\": true, " +
         "\"bead_mm\": " + number(ask.bead_mm) + ", \"min_strut_lines\": 2, \"topology\": \"" +
         lattice_topology_name(ask.topology) + "\", \"algorithm\": \"default_grade\", \"cell_mm\": " +
         number(ask.cell_mm) + ", \"cell_max_mm\": " + number(ask.cell_mm) + ", \"min_cells_across\": 1, \"skin\": true, " +
         "\"protect_ids\": [1], \"protect_depth_mm\": [" + number(ask.plate_mm) + "], \"protect_face_counts\": [1], " +
         "\"protect_faces\": [" + std::to_string(underside_face) + "]}" +
         (ask.threads > 0 ? ", \"threads\": " + std::to_string(ask.threads) : std::string()) + "}";
}

FileResult make_type_coupon(const CouponAsk& ask, const std::string& out_dir) {
  FileResult r;
  const std::string id = lattice_topology_name(ask.topology);
  try {
    const std::string part = out_dir + "/" + id + "_coupon_part.stl";
    write_stl_file(part, lattice_coupon_solid(), StlFormat::Binary);
    const StepModel m = import_part_file_resolved(part);
    const int under = underside(m);
    if (under < 0) {
      r.code = "error";
      r.why = "The coupon could not be made: its underside was not found.";
      return r;
    }
    const std::string job = out_dir + "/" + id + "_coupon_job.json";
    { std::ofstream(job) << type_coupon_job(ask, id + "_coupon_part.stl", under); }
    return run_file_job(job, out_dir, ask.threads);
  } catch (const std::exception& e) {
    r.code = "error";
    r.why = "The coupon could not be made.";
    r.detail = e.what();
  }
  return r;
}

}  // namespace topopt::lattice_layout
