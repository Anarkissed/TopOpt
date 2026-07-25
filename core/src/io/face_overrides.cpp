// face_overrides.cpp — the self-describing sidecar for a mesh part's face
// partition (handoff 2026-07-24, paint mode). See face_overrides.hpp for why the
// sidecar exists (a stateless bridge re-imports on every call, so the user's
// tuning + painted faces must travel with the file).

#include "topopt/face_overrides.hpp"

#include <cmath>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>

#include "topopt/mesh.hpp"

namespace topopt {

namespace {
// A fixed, locale-independent double->text with enough digits to round-trip an
// angle exactly. Determinism: no printf %g locale surprises.
std::string fmt_double(double v) {
  char buf[64];
  std::snprintf(buf, sizeof(buf), "%.10g", v);
  return std::string(buf);
}
}  // namespace

SegmentOptions segment_options_from(const FaceOverrides& ov) {
  SegmentOptions o;
  if (ov.dihedral_threshold_deg > 0.0)
    o.dihedral_threshold_deg = ov.dihedral_threshold_deg;
  if (ov.planar_region_cone_deg >= 0.0)
    o.planar_region_cone_deg = ov.planar_region_cone_deg;
  return o;
}

void apply_face_overrides(StepModel& model, const FaceOverrides& ov) {
  if (ov.paint_faces.empty()) return;
  const std::size_t nt = model.triangle_face.size();
  if (nt != model.mesh.triangles.size())
    throw std::invalid_argument(
        "apply_face_overrides: triangle_face is not parallel to mesh.triangles");

  // Physical bound on a fitted cylinder radius, from the part's own size.
  Vec3 lo, hi;
  bounding_box(model.mesh, lo, hi);
  const double bb_diag = std::sqrt((hi.x - lo.x) * (hi.x - lo.x) +
                                   (hi.y - lo.y) * (hi.y - lo.y) +
                                   (hi.z - lo.z) * (hi.z - lo.z));
  const SegmentOptions fit_opts;  // fit tolerances are classification-only

  for (const std::vector<int>& set : ov.paint_faces) {
    if (set.empty())
      throw std::invalid_argument(
          "apply_face_overrides: a painted face has no triangles");
    for (const int t : set)
      if (t < 0 || static_cast<std::size_t>(t) >= nt)
        throw std::invalid_argument(
            "apply_face_overrides: painted triangle index out of range");

    const int new_id = model.face_count;
    for (const int t : set) model.triangle_face[static_cast<std::size_t>(t)] = new_id;
    model.faces.push_back(fit_pseudo_face(model.mesh, set, fit_opts, bb_diag));
    model.face_count = new_id + 1;
  }
}

std::string face_overrides_sidecar_path(const std::string& model_path) {
  return model_path + ".faces";
}

void save_face_overrides(const std::string& path, const FaceOverrides& ov) {
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  if (!out) throw std::runtime_error("save_face_overrides: cannot write " + path);
  out << "topopt-face-overrides 1\n";
  if (ov.dihedral_threshold_deg > 0.0)
    out << "dihedral " << fmt_double(ov.dihedral_threshold_deg) << "\n";
  if (ov.planar_region_cone_deg >= 0.0)
    out << "cone " << fmt_double(ov.planar_region_cone_deg) << "\n";
  for (const std::vector<int>& set : ov.paint_faces) {
    out << "face";
    for (const int t : set) out << " " << t;
    out << "\n";
  }
  if (!out) throw std::runtime_error("save_face_overrides: write failed for " + path);
}

FaceOverrides load_face_overrides(const std::string& path) {
  FaceOverrides ov;
  std::ifstream in(path, std::ios::binary);
  if (!in) return ov;  // no sidecar: the common case (no tuning, no paint)

  std::string line;
  bool header_ok = false;
  int lineno = 0;
  while (std::getline(in, line)) {
    ++lineno;
    std::istringstream ls(line);
    std::string tok;
    if (!(ls >> tok)) continue;  // blank line
    if (!header_ok) {
      int ver = 0;
      if (tok != "topopt-face-overrides" || !(ls >> ver) || ver != 1)
        throw std::runtime_error("load_face_overrides: bad header in " + path);
      header_ok = true;
      continue;
    }
    if (tok == "dihedral") {
      if (!(ls >> ov.dihedral_threshold_deg))
        throw std::runtime_error("load_face_overrides: bad 'dihedral' in " + path);
    } else if (tok == "cone") {
      if (!(ls >> ov.planar_region_cone_deg))
        throw std::runtime_error("load_face_overrides: bad 'cone' in " + path);
    } else if (tok == "face") {
      std::vector<int> set;
      int t;
      while (ls >> t) set.push_back(t);
      if (set.empty())
        throw std::runtime_error("load_face_overrides: empty 'face' at line " +
                                 std::to_string(lineno) + " in " + path);
      ov.paint_faces.push_back(std::move(set));
    } else {
      throw std::runtime_error("load_face_overrides: unknown directive '" + tok +
                               "' at line " + std::to_string(lineno) + " in " + path);
    }
  }
  if (!header_ok)
    throw std::runtime_error("load_face_overrides: missing header in " + path);
  return ov;
}

StepModel import_part_file_resolved(const std::string& path,
                                    const StepTessellation& tess) {
  const FaceOverrides ov =
      load_face_overrides(face_overrides_sidecar_path(path));
  PartOptions opts;
  opts.tessellation = tess;
  opts.segmentation = segment_options_from(ov);
  StepModel model = import_part(path, opts).model;
  apply_face_overrides(model, ov);
  return model;
}

}  // namespace topopt
