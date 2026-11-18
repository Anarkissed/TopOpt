// Lattice rebuild: the lattice file job. See lattice_layout_file.hpp and
// docs/design/lattice-rebuild/04-layout-file-job.md.
#include "topopt/lattice_layout_file.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <exception>
#include <fstream>
#include <map>
#include <sstream>
#include <utility>

#include "../flexible/json.hpp"        // the always-built strict JSON reader (no new parser)
#include "topopt/face_overrides.hpp"   // import_part_file_resolved
#include "topopt/lattice.hpp"          // lattice_topology_from_id, lattice_topology_is_sheet
#include "topopt/stl.hpp"

namespace topopt::lattice_layout {
namespace {
namespace json = topopt::flexible::json;

double ms_since(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

// ── reading the job ───────────────────────────────────────────────────────────
double num(const json::Value& o, const char* key, double otherwise, const std::string& where) {
  const json::Value* v = json::find(o, key);
  return v ? json::as_number(*v, where + "." + key) : otherwise;
}
int whole(const json::Value& o, const char* key, int otherwise, const std::string& where) {
  const json::Value* v = json::find(o, key);
  return v ? json::as_int(*v, where + "." + key) : otherwise;
}
bool flag(const json::Value& o, const char* key, bool otherwise, const std::string& where) {
  const json::Value* v = json::find(o, key);
  return v ? json::as_bool(*v, where + "." + key) : otherwise;
}
std::string text(const json::Value& o, const char* key, const std::string& otherwise,
                 const std::string& where) {
  const json::Value* v = json::find(o, key);
  return v ? json::as_string(*v, where + "." + key) : otherwise;
}
std::vector<int> wholes(const json::Value& o, const char* key, const std::string& where) {
  std::vector<int> out;
  const json::Value* v = json::find(o, key);
  if (!v) return out;
  const std::string at = where + "." + key;
  for (const json::Value& e : json::as_array(*v, at).arr) out.push_back(json::as_int(e, at));
  return out;
}
std::vector<double> nums(const json::Value& o, const char* key, const std::string& where) {
  std::vector<double> out;
  const json::Value* v = json::find(o, key);
  if (!v) return out;
  const std::string at = where + "." + key;
  for (const json::Value& e : json::as_array(*v, at).arr) out.push_back(json::as_number(e, at));
  return out;
}
// A list of yes/no: true/false, or the bridge's own 1/0.
std::vector<bool> flags(const json::Value& o, const char* key, const std::string& where) {
  std::vector<bool> out;
  const json::Value* v = json::find(o, key);
  if (!v) return out;
  const std::string at = where + "." + key;
  for (const json::Value& e : json::as_array(*v, at).arr) {
    if (e.is_bool()) { out.push_back(e.boolean); continue; }
    const int n = json::as_int(e, at);
    if (n != 0 && n != 1) json::fail(at, "each entry must be true, false, 1 or 0");
    out.push_back(n == 1);
  }
  return out;
}

// A flattened list of lists, as the bridge sends it: item i's entries are counts[i]
// values of `values`, after the earlier items'.
std::vector<std::vector<int>> unflatten(const std::vector<int>& counts, const std::vector<int>& values,
                                        const std::string& what) {
  std::vector<std::vector<int>> out;
  std::size_t at = 0;
  for (int c : counts) {
    if (c < 0 || at + static_cast<std::size_t>(c) > values.size())
      json::fail(what, "the face counts run past the faces listed");
    out.emplace_back(values.begin() + static_cast<long>(at), values.begin() + static_cast<long>(at + c));
    at += static_cast<std::size_t>(c);
  }
  if (at != values.size()) json::fail(what, "faces are listed that no count claims");
  return out;
}

// D21: one region's zone, in place of its faces.
//   {"kind": "box", "centre": [x,y,z], "axes": [[..],[..],[..]], "half_mm": [a,b,c]}
//   {"kind": "cylinder", "centre": [x,y,z], "axis": [x,y,z], "radius_mm": r, "half_length_mm": h}
// Numbers region_from_zone would refuse refuse the job here, with the reason.
Vec3 vec3(const json::Value& o, const char* key, const std::string& where) {
  const std::string at = where + "." + key;
  const auto& a = json::as_array(json::require(o, key, where), at).arr;
  if (a.size() != 3) json::fail(at, "must be three numbers");
  return {json::as_number(a[0], at), json::as_number(a[1], at), json::as_number(a[2], at)};
}
Zone zone_from(const json::Value& v, const std::string& w) {
  const json::Value& o = json::as_object(v, w);
  Zone z;
  const std::string kind = json::as_string(json::require(o, "kind", w), w + ".kind");
  if (kind == "box") {
    json::reject_unknown(o, {"kind", "centre", "axes", "half_mm"}, w);
    z.kind = Zone::Kind::Box;
    z.centre = vec3(o, "centre", w);
    const std::string at = w + ".axes";
    const auto& axes = json::as_array(json::require(o, "axes", w), at).arr;
    if (axes.size() != 3) json::fail(at, "must be three axes");
    for (int a = 0; a < 3; ++a) {
      const auto& e = json::as_array(axes[static_cast<std::size_t>(a)], at).arr;
      if (e.size() != 3) json::fail(at, "each axis must be three numbers");
      z.axis[a] = {json::as_number(e[0], at), json::as_number(e[1], at), json::as_number(e[2], at)};
    }
    const Vec3 h = vec3(o, "half_mm", w);
    z.half[0] = h.x; z.half[1] = h.y; z.half[2] = h.z;
    bool ok = false;
    (void)region_from_zone(z, 1, Role::Lattice, 0.0, &ok);
    if (!ok) json::fail(w, "a box zone needs three half sizes above 0 and three unit axes at right angles");
  } else if (kind == "cylinder") {
    json::reject_unknown(o, {"kind", "centre", "axis", "radius_mm", "half_length_mm"}, w);
    z.kind = Zone::Kind::Cylinder;
    z.centre = vec3(o, "centre", w);
    z.axis[2] = vec3(o, "axis", w);
    z.half[0] = json::as_number(json::require(o, "radius_mm", w), w + ".radius_mm");
    z.half[2] = json::as_number(json::require(o, "half_length_mm", w), w + ".half_length_mm");
    bool ok = false;
    (void)region_from_zone(z, 1, Role::Lattice, 0.0, &ok);
    if (!ok) json::fail(w, "a cylinder zone needs a radius and a half length above 0 and a unit axis");
  } else {
    json::fail(w + ".kind", "unknown zone \"" + kind + "\" (box | cylinder)");
  }
  return z;
}

// D22: one region's or Protect skin's pieces, in place of its faces:
//   [{"faces": [..], "cuts": [{"point": [x,y,z], "normal": [x,y,z], "strict": false}]}, ..]
// A cut's normal of nothing is refused here; faces the part does not have are found later,
// with every other face the job names (region_faces_missing, protect_faces_missing).
std::vector<FacePiece> pieces_from(const json::Value& v, const std::string& w) {
  std::vector<FacePiece> out;
  const auto& list = json::as_array(v, w).arr;
  for (std::size_t i = 0; i < list.size(); ++i) {
    const std::string pw = w + "[" + std::to_string(i) + "]";
    const json::Value& o = json::as_object(list[i], pw);
    json::reject_unknown(o, {"faces", "cuts"}, pw);
    FacePiece piece;
    for (const json::Value& f : json::as_array(json::require(o, "faces", pw), pw + ".faces").arr)
      piece.faces.push_back(json::as_int(f, pw + ".faces"));
    if (const json::Value* cuts = json::find(o, "cuts")) {
      const auto& cl = json::as_array(*cuts, pw + ".cuts").arr;
      for (std::size_t k = 0; k < cl.size(); ++k) {
        const std::string cw = pw + ".cuts[" + std::to_string(k) + "]";
        const json::Value& c = json::as_object(cl[k], cw);
        json::reject_unknown(c, {"point", "normal", "strict"}, cw);
        FaceCut cut;
        cut.point = vec3(c, "point", cw);
        cut.normal = vec3(c, "normal", cw);
        cut.strict = flag(c, "strict", false, cw);
        const Vec3& n = cut.normal;
        if (!(n.x * n.x + n.y * n.y + n.z * n.z > 0.0) || !std::isfinite(n.x * n.x + n.y * n.y + n.z * n.z))
          json::fail(cw + ".normal", "a cut's normal must not be zero");
        piece.cuts.push_back(cut);
      }
    }
    out.push_back(std::move(piece));
  }
  return out;
}

Algorithm algorithm_from(const std::string& s, const std::string& where) {
  if (s == "uniform") return Algorithm::Uniform;
  if (s == "default_grade") return Algorithm::DefaultGrade;
  if (s == "stepped") return Algorithm::Stepped;
  json::fail(where, "unknown algorithm \"" + s + "\" (uniform | default_grade | stepped)");
}

// The bridge's LatticeLayoutSettings, key for key (lattice_layout_bridge.cpp, settings_from),
// and more that core's Settings has: small_cells_in_thin_walls, one_grid ("Let walls cut cells") and
// cells_by_stress (C22).
Settings settings_from(const json::Value& in, const std::string& w) {
  json::reject_unknown(
      in,
      {"all_lattice", "bead_mm", "min_strut_lines", "min_wall_mm", "rim_mm", "cover_mm",
       "region_ids", "region_no_lattice", "region_depth_mm", "region_expand_mm",
       "region_face_counts", "region_faces", "region_zones", "region_finish", "region_pieces", "protect_ids", "protect_depth_mm",
       "protect_face_counts", "protect_faces", "protect_pieces", "protect_chip", "topology", "algorithm", "cell_mm", "cell_max_mm",
       "cell_min_mm", "min_cells_across", "grade_to_shape", "band_mm", "band_cell_mm",
       "per_region", "dial", "dial_region", "dial_value", "strut_width_mm", "allow_quilt",
       "strength", "small_cells_in_thin_walls", "one_grid", "cells_by_stress", "bars", "join_loose", "skin",
       "skin_width_mm", "skin_reach_cells", "drop_loose", "by_stress", "dial_light", "dial_heavy", "width_light_mm",
       "width_heavy_mm", "reference_mpa", "percentile", "response", "region_own", "max_step", "region_weave", "organic_spacing_mm",
       "organic_width_mm", "organic_spacing_min_mm", "organic_spacing_max_mm", "organic_spacing_exponent",
       "organic_shape_fit", "organic_mode", "organic_walls_out", "organic_ties", "organic_tie_swirl",
       "organic_foot_gap", "organic_stress_goal",
       "organic_void_ratio", "organic_reseed_rounds", "organic_wall_connect", "organic_wall_gap",
       "organic_wall_cross", "organic_top_run", "organic_run_max", "organic_root_run", "organic_run_gap",
       "organic_run_follow", "organic_run_pull", "organic_run_seek", "organic_run_min", "organic_root_gap"},
      w);
  Settings s;
  s.start = flag(in, "all_lattice", false, w) ? Start::AllLattice : Start::AllSolid;
  s.bead_mm = num(in, "bead_mm", s.bead_mm, w);
  s.min_strut_lines = num(in, "min_strut_lines", s.min_strut_lines, w);
  s.min_wall_mm = num(in, "min_wall_mm", s.min_wall_mm, w);
  s.rim_mm = num(in, "rim_mm", s.rim_mm, w);
  s.cover_mm = num(in, "cover_mm", s.cover_mm, w);

  const std::vector<int> ids = wholes(in, "region_ids", w);
  const std::vector<bool> no_lattice = flags(in, "region_no_lattice", w);
  const std::vector<double> depth = nums(in, "region_depth_mm", w);
  const std::vector<double> expand = nums(in, "region_expand_mm", w);
  const std::vector<int> counts = wholes(in, "region_face_counts", w);
  const std::size_t nr = ids.size();
  if (no_lattice.size() != nr || depth.size() != nr || expand.size() != nr || counts.size() != nr)
    json::fail(w, "the region lists (region_ids, region_no_lattice, region_depth_mm, "
                  "region_expand_mm, region_face_counts) are not all one length");
  // Organic, Traced: which regions are filled by the weave. Absent: none.
  const std::vector<bool> weave = flags(in, "region_weave", w);
  if (json::find(in, "region_weave") && weave.size() != nr)
    json::fail(w + ".region_weave", "is not as long as region_ids (one true or false for each region)");
  const auto rf = unflatten(counts, wholes(in, "region_faces", w), w + ".region_faces");
  // D21: per region, null (its faces) or its zone (and then no faces).
  const json::Value* zones = json::find(in, "region_zones");
  const std::string zat = w + ".region_zones";
  if (zones && json::as_array(*zones, zat).arr.size() != nr)
    json::fail(w, "region_zones is not as long as region_ids");
  for (std::size_t r = 0; r < nr; ++r) {
    Settings::RegionAsk a;
    a.id = ids[r];
    a.role = no_lattice[r] ? Role::NoLattice : Role::Lattice;
    a.faces = rf[r];
    a.depth_mm = depth[r];
    a.expand_mm = expand[r];
    if (zones && !zones->arr[r].is_null()) {
      a.zone = zone_from(zones->arr[r], zat);
      if (!a.faces.empty()) json::fail(zat, "region " + std::to_string(a.id) + " has faces and a zone: one or the other");
    }
    a.weave = !weave.empty() && weave[r];
    s.regions.push_back(std::move(a));
  }
  // D22: per region, null (its faces, or its zone) or its pieces; with pieces its faces are not read.
  if (const json::Value* pieces = json::find(in, "region_pieces")) {
    const std::string at = w + ".region_pieces";
    const auto& list = json::as_array(*pieces, at).arr;
    if (list.size() != nr) json::fail(w, "region_pieces is not as long as region_ids");
    for (std::size_t r = 0; r < nr; ++r) {
      if (list[r].is_null()) continue;
      const std::string pw = at + "[" + std::to_string(r) + "]";
      s.regions[r].pieces = pieces_from(list[r], pw);
      if (s.regions[r].pieces.empty()) json::fail(pw, "a region's pieces, when given, must not be an empty list");
      if (s.regions[r].zone.kind != Zone::Kind::None)
        json::fail(pw, "region " + std::to_string(s.regions[r].id) + " has pieces and a zone: one or the other");
    }
  }
  // C23, R19: per region, null (the part's settings in everything) or its own, under the part's own key names.
  if (const json::Value* own = json::find(in, "region_own")) {
    const std::string at = w + ".region_own";
    const auto& list = json::as_array(*own, at).arr;
    if (list.size() != nr) json::fail(w, "region_own is not as long as region_ids");
    for (std::size_t r = 0; r < nr; ++r) {
      if (list[r].is_null()) continue;
      const std::string ow = at + "[" + std::to_string(r) + "]";
      const json::Value& o = json::as_object(list[r], ow);
      json::reject_unknown(o,
                           {"algorithm", "cell_mm", "cell_max_mm", "cell_min_mm", "min_cells_across", "grade_to_shape",
                            "band_mm", "band_cell_mm", "cells_by_stress", "by_stress", "dial", "dial_light",
                            "dial_heavy", "strut_width_mm", "width_light_mm", "width_heavy_mm", "strength", "response",
                            "reference_mpa", "max_step"},
                           ow);
      AreaOwn& a = s.regions[r].own;
      if (json::find(o, "algorithm")) a.algorithm = algorithm_from(text(o, "algorithm", "", ow), ow + ".algorithm");
      const auto mm = [&](const char* key, std::optional<double>& v) { if (json::find(o, key)) v = num(o, key, 0.0, ow); };
      const auto yes = [&](const char* key, std::optional<bool>& v) { if (json::find(o, key)) v = flag(o, key, false, ow); };
      mm("cell_mm", a.cell_mm); mm("cell_max_mm", a.cell_max_mm); mm("cell_min_mm", a.cell_min_mm);
      if (json::find(o, "min_cells_across")) a.min_cells_across = whole(o, "min_cells_across", 1, ow);
      yes("grade_to_shape", a.grade_to_shape); mm("band_mm", a.band_mm); mm("band_cell_mm", a.band_cell_mm);
      yes("cells_by_stress", a.cells_by_stress); yes("by_stress", a.by_stress);
      mm("dial", a.dial); mm("dial_light", a.dial_light); mm("dial_heavy", a.dial_heavy);
      mm("strut_width_mm", a.width_mm); mm("width_light_mm", a.width_light_mm); mm("width_heavy_mm", a.width_heavy_mm);
      mm("strength", a.strength); mm("response", a.response); mm("reference_mpa", a.reference_mpa);
      mm("max_step", a.max_step);   // C24
    }
  }
  // S13: per region, null (the part's Finish) or its own: any of rim_mm, cover_mm, skin,
  // skin_width_mm, skin_reach_cells; what it leaves out is the part's.
  if (const json::Value* fin = json::find(in, "region_finish")) {
    const std::string at = w + ".region_finish";
    const auto& list = json::as_array(*fin, at).arr;
    if (list.size() != nr) json::fail(w, "region_finish is not as long as region_ids");
    for (std::size_t r = 0; r < nr; ++r) {
      if (list[r].is_null()) continue;
      const json::Value& o = json::as_object(list[r], at);
      json::reject_unknown(o, {"rim_mm", "cover_mm", "skin", "skin_width_mm", "skin_reach_cells"}, at);
      Settings::RegionAsk& a = s.regions[r];
      if (json::find(o, "rim_mm")) a.rim_mm = num(o, "rim_mm", 0.0, at);
      if (json::find(o, "cover_mm")) a.cover_mm = num(o, "cover_mm", 0.0, at);
      if (json::find(o, "skin")) a.skin = flag(o, "skin", false, at);
      if (json::find(o, "skin_width_mm")) a.skin_width_mm = num(o, "skin_width_mm", 0.0, at);
      if (json::find(o, "skin_reach_cells")) a.skin_reach_cells = num(o, "skin_reach_cells", 0.0, at);
    }
  }
  const std::vector<int> pids = wholes(in, "protect_ids", w);
  const std::vector<double> pdepth = nums(in, "protect_depth_mm", w);
  const std::vector<int> pcounts = wholes(in, "protect_face_counts", w);
  const std::size_t np = pids.size();
  if (pdepth.size() != np || pcounts.size() != np)
    json::fail(w, "the Protect skin lists (protect_ids, protect_depth_mm, protect_face_counts) "
                  "are not all one length");
  const auto pf = unflatten(pcounts, wholes(in, "protect_faces", w), w + ".protect_faces");
  for (std::size_t p = 0; p < np; ++p) s.protect.push_back({pids[p], pf[p], pdepth[p], {}});
  // D23: per Protect skin, 1 when it is a place's answer "Solid" (a chip's), 0 when it is the owner's own skin.
  // Absent: all 0. It acts in the layout exactly as any Protect skin; the place it answers stays listed.
  if (json::find(in, "protect_chip")) {
    const std::vector<bool> chip = flags(in, "protect_chip", w);
    if (chip.size() != np) json::fail(w, "protect_chip is not as long as protect_ids");
    for (std::size_t p = 0; p < np; ++p) s.protect[p].chip = chip[p];
  }
  // D22: per Protect skin, null (its faces) or its pieces; with pieces its faces are not read.
  if (const json::Value* pieces = json::find(in, "protect_pieces")) {
    const std::string at = w + ".protect_pieces";
    const auto& list = json::as_array(*pieces, at).arr;
    if (list.size() != np) json::fail(w, "protect_pieces is not as long as protect_ids");
    for (std::size_t p = 0; p < np; ++p) {
      if (list[p].is_null()) continue;
      const std::string pw = at + "[" + std::to_string(p) + "]";
      s.protect[p].pieces = pieces_from(list[p], pw);
      if (s.protect[p].pieces.empty()) json::fail(pw, "a Protect skin's pieces, when given, must not be an empty list");
    }
  }

  s.cells.algorithm = algorithm_from(text(in, "algorithm", "default_grade", w), w + ".algorithm");
  try {
    s.cells.topology = lattice_topology_from_id(text(in, "topology", "octet", w));
  } catch (const std::exception& e) {
    json::fail(w + ".topology", e.what());
  }
  s.cells.cell_mm = num(in, "cell_mm", s.cells.cell_mm, w);
  s.cells.cell_max_mm = num(in, "cell_max_mm", s.cells.cell_max_mm, w);
  s.cells.cell_min_mm = num(in, "cell_min_mm", s.cells.cell_min_mm, w);
  s.cells.min_cells_across = whole(in, "min_cells_across", s.cells.min_cells_across, w);
  s.cells.grade_to_shape = flag(in, "grade_to_shape", s.cells.grade_to_shape, w);
  s.cells.band_mm = num(in, "band_mm", s.cells.band_mm, w);
  s.cells.band_cell_mm = num(in, "band_cell_mm", s.cells.band_cell_mm, w);
  s.cells.by_stress = flag(in, "cells_by_stress", s.cells.by_stress, w);   // C22
  s.cells.max_step = num(in, "max_step", s.cells.max_step, w);            // C24

  const bool per_region = flag(in, "per_region", false, w), by_stress = flag(in, "by_stress", false, w);
  if (per_region && by_stress) json::fail(w, "by_stress and per_region cannot both be on: pick one density");
  s.struts.mode = by_stress ? Density::ByStress : per_region ? Density::PerRegion : Density::Uniform;
  s.struts.dial_light = num(in, "dial_light", s.struts.dial_light, w);
  s.struts.dial_heavy = num(in, "dial_heavy", s.struts.dial_heavy, w);
  s.struts.width_light_mm = num(in, "width_light_mm", s.struts.width_light_mm, w);
  s.struts.width_heavy_mm = num(in, "width_heavy_mm", s.struts.width_heavy_mm, w);
  s.stress.reference_mpa = num(in, "reference_mpa", s.stress.reference_mpa, w);
  s.stress.percentile = num(in, "percentile", s.stress.percentile, w);
  s.stress.response = num(in, "response", s.stress.response, w);
  s.struts.dial = num(in, "dial", s.struts.dial, w);
  const std::vector<int> dial_region = wholes(in, "dial_region", w);
  const std::vector<double> dial_value = nums(in, "dial_value", w);
  if (dial_region.size() != dial_value.size())
    json::fail(w, "dial_region and dial_value are not one length");
  for (std::size_t i = 0; i < dial_region.size(); ++i)
    s.struts.region_dial.push_back({dial_region[i], dial_value[i]});
  s.struts.width_mm = num(in, "strut_width_mm", s.struts.width_mm, w);
  s.struts.allow_quilt = flag(in, "allow_quilt", s.struts.allow_quilt, w);
  s.struts.strength = num(in, "strength", s.struts.strength, w);
  s.small_cells_in_thin_walls = flag(in, "small_cells_in_thin_walls", s.small_cells_in_thin_walls, w);
  s.one_grid = flag(in, "one_grid", s.one_grid, w);

  s.bars = flag(in, "bars", s.bars, w);
  s.join_loose = flag(in, "join_loose", s.join_loose, w);
  s.skin = flag(in, "skin", s.skin, w);
  s.skin_spec.width_mm = num(in, "skin_width_mm", s.skin_spec.width_mm, w);
  s.skin_spec.reach_cells = num(in, "skin_reach_cells", s.skin_spec.reach_cells, w);
  s.drop_loose = flag(in, "drop_loose", s.drop_loose, w);
  return s;
}

// Organic, Traced: the trace's ask, from the layout object (its keys are let through by settings_from). The spacing is
// needed when any region is a weave: one spacing ("organic_spacing_mm", both ends), or the range (O12:
// "organic_spacing_min_mm" and "organic_spacing_max_mm" together, "organic_spacing_exponent" 1 when not given), never
// both. The reference is the layout's own ("reference_mpa", "percentile"). O13, "organic_shape_fit": true when not
// given, as the old run reads a job that does not say. The width is 0 (the thinnest strut) or at least the thinnest
// strut.
OrganicAsk organic_from(const json::Value& in, const Settings& s, const std::string& w) {
  OrganicAsk a;
  bool any_weave = false;
  for (const Settings::RegionAsk& r : s.regions) any_weave = any_weave || r.weave;
  const bool has_spacing = json::find(in, "organic_spacing_mm") != nullptr;
  const bool has_min = json::find(in, "organic_spacing_min_mm") != nullptr;
  const bool has_max = json::find(in, "organic_spacing_max_mm") != nullptr;
  const bool has_exp = json::find(in, "organic_spacing_exponent") != nullptr;
  a.spacing_mm = num(in, "organic_spacing_mm", 0.0, w);
  a.width_mm = num(in, "organic_width_mm", 0.0, w);
  if (has_spacing && !(std::isfinite(a.spacing_mm) && a.spacing_mm > 0.0))
    json::fail(w + ".organic_spacing_mm", "must be above 0");
  if (has_spacing && (has_min || has_max || has_exp))
    json::fail(w + ".organic_spacing_mm", "is one spacing for both ends; give it, or the range "
                                          "(organic_spacing_min_mm, organic_spacing_max_mm), not both");
  if (has_min != has_max)
    json::fail(w + (has_min ? ".organic_spacing_max_mm" : ".organic_spacing_min_mm"),
               "is needed with the other end of the range");
  if (has_exp && !has_min)
    json::fail(w + ".organic_spacing_exponent", "is read only with the range (organic_spacing_min_mm, "
                                                "organic_spacing_max_mm)");
  if (has_min) {
    a.spacing_min_mm = num(in, "organic_spacing_min_mm", a.spacing_min_mm, w);
    a.spacing_max_mm = num(in, "organic_spacing_max_mm", a.spacing_max_mm, w);
    a.spacing_exponent = num(in, "organic_spacing_exponent", a.spacing_exponent, w);
    if (!(std::isfinite(a.spacing_min_mm) && a.spacing_min_mm > 0.0))
      json::fail(w + ".organic_spacing_min_mm", "must be above 0");
    if (!(std::isfinite(a.spacing_max_mm) && a.spacing_max_mm >= a.spacing_min_mm))
      json::fail(w + ".organic_spacing_max_mm", "must be at least organic_spacing_min_mm");
    if (!(std::isfinite(a.spacing_exponent) && a.spacing_exponent > 0.0))
      json::fail(w + ".organic_spacing_exponent", "must be above 0");
  }
  if (any_weave && !has_spacing && !has_min)
    json::fail(w + ".organic_spacing_mm", "is needed when a region is filled by the weave (region_weave): the distance "
                                          "between neighbouring strands, mm (or the range: organic_spacing_min_mm and "
                                          "organic_spacing_max_mm)");
  a.reference_mpa = s.stress.reference_mpa;
  a.percentile = s.stress.percentile;
  a.shape_fit = flag(in, "organic_shape_fit", a.shape_fit, w);
  // G1: Traced (the default) or Grown; the keys read by Grown only (its layer is the mesh's "layer_mm").
  const std::string mode = text(in, "organic_mode", "traced", w);
  if (mode != "traced" && mode != "grown")
    json::fail(w + ".organic_mode", "must be \"traced\" or \"grown\", not \"" + mode + "\"");
  a.mode = mode == "grown" ? OrganicMode::Grown : OrganicMode::Traced;
  a.walls_out = flag(in, "organic_walls_out", a.walls_out, w);
  a.ties = flag(in, "organic_ties", a.ties, w);
  a.tie_swirl = num(in, "organic_tie_swirl", a.tie_swirl, w);
  if (!(a.tie_swirl >= 0.0 && a.tie_swirl <= 1.0)) json::fail(w + ".organic_tie_swirl", "must be 0 to 1");
  a.foot_gap = num(in, "organic_foot_gap", a.foot_gap, w);
  // D (brief G6, an experiment): the stress lines are the goal (off when not given).
  a.stress_goal = flag(in, "organic_stress_goal", a.stress_goal, w);
  // E (brief G6, try keys): the re-seeding's bare distance (1.5 when not given) and its rounds (1 when not given).
  a.void_ratio = num(in, "organic_void_ratio", a.void_ratio, w);
  if (!(std::isfinite(a.void_ratio) && a.void_ratio > 0.0)) json::fail(w + ".organic_void_ratio", "must be above 0");
  const double rounds = num(in, "organic_reseed_rounds", a.reseed_rounds, w);
  if (!(rounds >= 0.0 && rounds <= 100.0 && rounds == std::floor(rounds)))
    json::fail(w + ".organic_reseed_rounds", "must be a whole number, 0 to 100");
  a.reseed_rounds = static_cast<int>(rounds);
  a.wall_connect = flag(in, "organic_wall_connect", a.wall_connect, w);   // E (off when not given)
  a.wall_gap = num(in, "organic_wall_gap", a.wall_gap, w);   // E: 0 or less (and when not given): off
  if (!std::isfinite(a.wall_gap)) json::fail(w + ".organic_wall_gap", "must be a number (0 or less: off)");
  // F (brief G7, a try key): crossing vines (0 when not given: off).
  const double cross = num(in, "organic_wall_cross", a.wall_cross, w);
  if (!(cross == 0.0 || cross == 1.0 || cross == 2.0)) json::fail(w + ".organic_wall_cross", "must be 0, 1 or 2");
  a.wall_cross = static_cast<int>(cross);
  // G (brief G8, try keys): top runs, roots (0 when not given: off), runs per end (1 when not given).
  a.top_run = num(in, "organic_top_run", a.top_run, w);
  if (!(std::isfinite(a.top_run) && a.top_run >= 0.0)) json::fail(w + ".organic_top_run", "must be 0 or above");
  a.root_run = num(in, "organic_root_run", a.root_run, w);
  if (!(std::isfinite(a.root_run) && a.root_run >= 0.0)) json::fail(w + ".organic_root_run", "must be 0 or above");
  a.run_gap = num(in, "organic_run_gap", a.run_gap, w);
  if (!(std::isfinite(a.run_gap) && a.run_gap >= 0.0)) json::fail(w + ".organic_run_gap", "must be 0 or above");
  const double rmax = num(in, "organic_run_max", a.run_max, w);
  if (!(std::isfinite(rmax) && rmax >= 1.0 && rmax <= 1e6 && rmax == std::floor(rmax)))
    json::fail(w + ".organic_run_max", "must be a whole number, 1 or more");
  a.run_max = static_cast<int>(rmax);
  // H (brief G9, try keys): how a run is steered and when it may end.
  a.run_follow = num(in, "organic_run_follow", a.run_follow, w);
  if (!(std::isfinite(a.run_follow) && a.run_follow > 0.0)) json::fail(w + ".organic_run_follow", "must be above 0");
  a.run_pull = num(in, "organic_run_pull", a.run_pull, w);
  if (!(std::isfinite(a.run_pull) && a.run_pull >= 0.0)) json::fail(w + ".organic_run_pull", "must be 0 or above");
  a.run_seek = num(in, "organic_run_seek", a.run_seek, w);
  if (!(std::isfinite(a.run_seek) && a.run_seek >= 0.0)) json::fail(w + ".organic_run_seek", "must be 0 or above");
  a.run_min = num(in, "organic_run_min", a.run_min, w);
  if (!(std::isfinite(a.run_min) && a.run_min >= 0.0)) json::fail(w + ".organic_run_min", "must be 0 or above");
  a.root_gap = num(in, "organic_root_gap", a.root_gap, w);
  if (!std::isfinite(a.root_gap)) json::fail(w + ".organic_root_gap", "must be a number (below 0: the run gap)");
  // G13: 0 or less: the feet do not compete.
  if (!std::isfinite(a.foot_gap)) json::fail(w + ".organic_foot_gap", "must be a number (0 or less: feet do not compete)");
  const double thinnest = s.bead_mm * s.min_strut_lines;
  if (!(std::isfinite(a.width_mm) && a.width_mm >= 0.0))
    json::fail(w + ".organic_width_mm", "must be 0 (the thinnest strut) or more");
  if (a.width_mm > 0.0 && a.width_mm < thinnest) {
    char b[160];
    std::snprintf(b, sizeof b, "is under the thinnest strut (%.9g mm: bead_mm x min_strut_lines); 0 gives the thinnest",
                  thinnest);
    json::fail(w + ".organic_width_mm", b);
  }
  return a;
}

FileOptions options_from(const json::Value& in, const std::string& w) {
  json::reject_unknown(in,
                       {"pitch_mm", "bar_sides", "block_mm", "grow_mm", "clean_mm", "part_mm",
                        "fill_under_mm3", "bridge_rise", "post_mm", "layer_mm", "pixel_mm", "most_passes",
                        "leave_out", "keep_if_not_clean", "weave_stand_every_mm", "weave_foot_mm", "weave_round_top",
                        "weave_sag_lift_mm", "weave_sag_legs"},
                       w);
  FileOptions o;
  o.pitch_mm = num(in, "pitch_mm", o.pitch_mm, w);
  o.mesh.bar_sides = whole(in, "bar_sides", o.mesh.bar_sides, w);
  o.mesh.block_mm = num(in, "block_mm", o.mesh.block_mm, w);
  o.mesh.grow_mm = num(in, "grow_mm", o.mesh.grow_mm, w);
  o.mesh.clean_mm = num(in, "clean_mm", o.mesh.clean_mm, w);
  o.mesh.part_mm = num(in, "part_mm", o.mesh.part_mm, w);
  o.mesh.fill_under_mm3 = num(in, "fill_under_mm3", o.mesh.fill_under_mm3, w);
  o.mesh.bridge_rise = num(in, "bridge_rise", o.mesh.bridge_rise, w);
  o.mesh.post_mm = num(in, "post_mm", o.mesh.post_mm, w);
  o.mesh.weave_stand_every_mm = num(in, "weave_stand_every_mm", o.mesh.weave_stand_every_mm, w);
  if (!(o.mesh.weave_stand_every_mm >= 0.0)) json::fail(w + ".weave_stand_every_mm", "must be 0 (never) or more");
  o.mesh.weave_foot_mm = num(in, "weave_foot_mm", o.mesh.weave_foot_mm, w);   // O11: 0 = no foot, below 0 = half the bar's width
  o.mesh.weave_round_top = flag(in, "weave_round_top", o.mesh.weave_round_top, w);   // O14: false = the square bar
  o.mesh.weave_sag_lift_mm = num(in, "weave_sag_lift_mm", o.mesh.weave_sag_lift_mm, w);   // O17: 0 = never lift
  if (!(o.mesh.weave_sag_lift_mm >= 0.0)) json::fail(w + ".weave_sag_lift_mm", "must be 0 (never) or more");
  o.mesh.weave_sag_legs = flag(in, "weave_sag_legs", o.mesh.weave_sag_legs, w);   // O18: false = no leg
  o.layers.layer_mm = num(in, "layer_mm", o.layers.layer_mm, w);
  o.layers.pixel_mm = num(in, "pixel_mm", o.layers.pixel_mm, w);
  o.most_passes = whole(in, "most_passes", o.most_passes, w);
  o.leave_out = flag(in, "leave_out", o.leave_out, w);
  o.keep_if_not_clean = flag(in, "keep_if_not_clean", o.keep_if_not_clean, w);
  if (!(o.layers.layer_mm > 0.0)) json::fail(w + ".layer_mm", "must be above 0");
  if (!(o.layers.pixel_mm > 0.0)) json::fail(w + ".pixel_mm", "must be above 0");
  if (o.most_passes < 1) json::fail(w + ".most_passes", "must be 1 or more");
  if (!(o.pitch_mm > 0.0)) json::fail(w + ".pitch_mm", "must be above 0");
  if (o.mesh.bar_sides < 3) json::fail(w + ".bar_sides", "must be 3 or more");
  if (!(o.mesh.block_mm > 0.0)) json::fail(w + ".block_mm", "must be above 0");
  return o;
}

// ── the result ────────────────────────────────────────────────────────────────
struct Refusal {
  const char* code;
  int exit_code;
};
// 3 = the part or the settings cannot give a file (the maker can change them);
// 1 = anything else.
constexpr Refusal kJobUnreadable{"job_unreadable", 1};
constexpr Refusal kModelUnreadable{"model_unreadable", 3};
constexpr Refusal kModelEmpty{"model_empty", 3};
constexpr Refusal kPartNotClosed{"part_not_closed", 3};
constexpr Refusal kRegionFacesMissing{"region_faces_missing", 3};
constexpr Refusal kProtectFacesMissing{"protect_faces_missing", 3};
constexpr Refusal kTypeNotSupported{"type_not_supported", 3};
constexpr Refusal kNoCells{"no_cells", 3};
constexpr Refusal kNoStruts{"no_struts", 3};
constexpr Refusal kMeshUnavailable{"mesh_unavailable", 3};
constexpr Refusal kMeshFailed{"mesh_failed", 1};
// The file would have something starting in mid-air when printed (his rule P8 b): not written.
constexpr Refusal kWouldNotPrint{"would_not_print", 3};
// By stress (R18) or cell size by stress (C22) was asked and there is no stress result to grade by.
constexpr Refusal kNoStress{"no_stress_result", 3};
// The stress result sent with the job could not be read (missing, or not a demand file).
constexpr Refusal kDemandUnreadable{"demand_unreadable", 1};
// The tensor file sent with the job (Organic, Traced) could not be read.
constexpr Refusal kTensorUnreadable{"tensor_unreadable", 1};
constexpr Refusal kCannotWrite{"cannot_write", 1};
// V4: a strength check was asked for and this build has none to make.
constexpr Refusal kStrengthUnavailable{"strength_unavailable", 1};
constexpr Refusal kCancelled{"cancelled", 1};
constexpr Refusal kError{"error", 1};

void refuse(FileResult& r, const Refusal& which, const std::string& why, const std::string& detail = {}) {
  r.ok = false;
  r.code = which.code;
  r.exit_code = which.exit_code;
  r.why = why;
  r.detail = detail;
}

// "3", "3 and 5", "3, 5 and 9".
std::string listed(const std::vector<int>& ids) {
  std::string out;
  for (std::size_t i = 0; i < ids.size(); ++i) {
    if (i) out += i + 1 == ids.size() ? " and " : ", ";
    out += std::to_string(ids[i]);
  }
  return out;
}
std::string faces_missing(const char* one, const char* many, const std::vector<int>& ids) {
  const bool single = ids.size() == 1;
  return std::string(single ? one : many) + " " + listed(ids) +
         (single ? " points at faces this part does not have. Pick its faces again."
                 : " point at faces this part does not have. Pick their faces again.");
}

std::string escaped(const std::string& in) {
  std::string out;
  for (const char c : in) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\t': out += "\\t"; break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char b[8];
          std::snprintf(b, sizeof b, "\\u%04x", static_cast<unsigned>(c));
          out += b;
        } else {
          out += c;
        }
    }
  }
  return out;
}
std::string base_name(const std::string& path) {
  const std::string::size_type slash = path.find_last_of('/');
  return slash == std::string::npos ? path : path.substr(slash + 1);
}
std::string folder_of(const std::string& path) {
  const std::string::size_type slash = path.find_last_of('/');
  if (slash == std::string::npos) return ".";
  if (slash == 0) return "/";
  return path.substr(0, slash);
}
std::size_t size_of_file(const std::string& path) {
  std::ifstream f(path, std::ios::binary | std::ios::ate);
  return f ? static_cast<std::size_t>(f.tellg()) : 0;
}
void say(void (*said)(const char*), const char* line) {
  if (said) said(line);
}
}  // namespace

// ── THE ONE PLACE THE MESH IS MADE ────────────────────────────────────────────
// (LatticeReview's build-and-check-the-layers loop replaces this body.)
TriangleMesh make_file_mesh(const Session& session, const Outcome& outcome, const FileOptions& options,
                            FileReport& report, const std::atomic<bool>* stop) {
  report = FileReport{};
  const Domain* domain = session.domain();
  if (!domain) {
    report.mesh.why = "The lattice was not laid before its file was asked for.";
    return TriangleMesh{};
  }
  const OpenSpace open = read_open_space(*domain, outcome.layout, options.pitch_mm, options.threads, stop);
  report.open_boxes = open.boxes.size();
  report.ms_open_space = open.ms;
  // Made, checked layer by layer, and made again until it prints (P8).
  PrintableSpec spec;
  spec.mesh = options.mesh;
  spec.mesh.threads = options.threads;
  spec.mesh.stop = stop;
  spec.layers = options.layers;
  spec.layers.threads = options.threads;
  spec.layers.stop = stop;
  spec.most_passes = options.most_passes;
  spec.leave_out = options.leave_out;
  PrintableReport made;
  TriangleMesh mesh = build_printable_mesh(session.measure(), *domain, outcome.layout, outcome.bars, open, spec, &made);
  report.mesh = made.mesh;
  report.builds = made.passes;
  report.ms_carve = made.ms_carve;
  report.layers = made.layers;
  report.print_clean = made.clean;
  report.found_per_pass = made.found_per_pass;
  report.left_out_at = made.drop_at;
  report.posts = made.posts;
  report.stands_added = made.stands_added;
  report.weave_specks_ignored = made.weave_specks_ignored;
  report.weave_held_ignored = made.weave_held_ignored;
  report.sags = made.sags;
  report.sagged = made.sagged;
  if (made.mesh.ok) {
    report.bed_contact_mm2 = made.layers.bed_mm2;
    report.midair_starts = static_cast<int>(made.layers.mid_air.size());
  }
  return mesh;
}

// ── THE DEMAND FILE ───────────────────────────────────────────────────────────
namespace {
constexpr char kDemandMagic[8] = {'T', 'O', 'D', 'E', 'M', 'A', 'N', 'D'};
constexpr std::size_t kDemandHead = 8 + 4 + 3 * 4 + 3 * 8 + 8;   // 56 bytes before the values
std::uint32_t u32_at(const unsigned char* p) {
  return static_cast<std::uint32_t>(p[0]) | static_cast<std::uint32_t>(p[1]) << 8 |
         static_cast<std::uint32_t>(p[2]) << 16 | static_cast<std::uint32_t>(p[3]) << 24;
}
std::uint64_t u64_at(const unsigned char* p) {
  return static_cast<std::uint64_t>(u32_at(p)) | static_cast<std::uint64_t>(u32_at(p + 4)) << 32;
}
std::int32_t i32_at(const unsigned char* p) {
  const std::uint32_t u = u32_at(p);
  std::int32_t v;
  std::memcpy(&v, &u, 4);
  return v;
}
double f64_at(const unsigned char* p) {
  const std::uint64_t u = u64_at(p);
  double v;
  std::memcpy(&v, &u, 8);
  return v;
}
float f32_at(const unsigned char* p) {
  const std::uint32_t u = u32_at(p);
  float v;
  std::memcpy(&v, &u, 4);
  return v;
}
void put_u32(std::string& o, std::uint32_t u) {
  for (int b = 0; b < 4; ++b) o += static_cast<char>((u >> (8 * b)) & 0xff);
}
void put_u64(std::string& o, std::uint64_t u) {
  put_u32(o, static_cast<std::uint32_t>(u));
  put_u32(o, static_cast<std::uint32_t>(u >> 32));
}
}  // namespace

bool read_demand_file(const std::string& path, DemandField& out, std::string* why) {
  const auto no = [&](const std::string& reason) {
    if (why) *why = reason;
    return false;
  };
  std::ifstream f(path, std::ios::binary);
  if (!f) return no("cannot open " + path);
  std::ostringstream all;
  all << f.rdbuf();
  const std::string bytes = all.str();
  const auto* p = reinterpret_cast<const unsigned char*>(bytes.data());
  if (bytes.size() < 8 || std::memcmp(p, kDemandMagic, 8) != 0) return no("not a stress result file (it does not start with TODEMAND)");
  if (bytes.size() < kDemandHead) return no("the stress result file is cut short");
  const std::int32_t version = i32_at(p + 8);
  if (version != kDemandVersion)
    return no("the stress result file is version " + std::to_string(version) + ", and only version 1 can be read");
  const std::int32_t nx = i32_at(p + 12), ny = i32_at(p + 16), nz = i32_at(p + 20);
  if (nx <= 0 || ny <= 0 || nz <= 0) return no("the stress result's grid has no voxels");
  const std::uint64_t n = static_cast<std::uint64_t>(nx) * static_cast<std::uint64_t>(ny) * static_cast<std::uint64_t>(nz);
  if (bytes.size() != kDemandHead + 4 * n)
    return no("the stress result file is " + std::to_string(bytes.size()) + " bytes, and its grid needs " +
              std::to_string(kDemandHead + 4 * n));
  DemandField d;
  d.nx = nx; d.ny = ny; d.nz = nz;
  d.origin = {f64_at(p + 24), f64_at(p + 32), f64_at(p + 40)};
  d.spacing = f64_at(p + 48);
  if (!std::isfinite(d.origin.x) || !std::isfinite(d.origin.y) || !std::isfinite(d.origin.z))
    return no("the stress result's grid corner is not a finite number");
  if (!std::isfinite(d.spacing) || !(d.spacing > 0.0)) return no("the stress result's voxel size is not a number above 0");
  d.mpa.resize(static_cast<std::size_t>(n));
  for (std::size_t i = 0; i < d.mpa.size(); ++i) {
    d.mpa[i] = f32_at(p + kDemandHead + 4 * i);
    if (!std::isfinite(d.mpa[i])) return no("the stress result holds a value that is not a finite number (voxel " + std::to_string(i) + ")");
  }
  out = std::move(d);
  return true;
}

bool write_demand_file(const std::string& path, const DemandField& field) {
  if (field.empty()) return false;
  std::string o(kDemandMagic, 8);
  put_u32(o, static_cast<std::uint32_t>(kDemandVersion));
  for (int n : {field.nx, field.ny, field.nz}) put_u32(o, static_cast<std::uint32_t>(n));
  for (double v : {field.origin.x, field.origin.y, field.origin.z, field.spacing}) {
    std::uint64_t u;
    std::memcpy(&u, &v, 8);
    put_u64(o, u);
  }
  for (float v : field.mpa) {
    std::uint32_t u;
    std::memcpy(&u, &v, 4);
    put_u32(o, u);
  }
  std::ofstream f(path, std::ios::binary | std::ios::trunc);
  f.write(o.data(), static_cast<std::streamsize>(o.size()));
  f.close();
  return static_cast<bool>(f);
}

// ── THE TENSOR FILE ───────────────────────────────────────────────────────────
namespace {
constexpr char kTensorMagic[8] = {'T', 'O', 'T', 'E', 'N', 'S', 'O', 'R'};
constexpr std::size_t kTensorHead = kDemandHead;   // the same 56 bytes before the values
}  // namespace

bool read_tensor_file(const std::string& path, TensorField& out, std::string* why) {
  const auto no = [&](const std::string& reason) {
    if (why) *why = reason;
    return false;
  };
  std::ifstream f(path, std::ios::binary);
  if (!f) return no("cannot open " + path);
  std::ostringstream all;
  all << f.rdbuf();
  const std::string bytes = all.str();
  const auto* p = reinterpret_cast<const unsigned char*>(bytes.data());
  if (bytes.size() < 8 || std::memcmp(p, kTensorMagic, 8) != 0)
    return no("not a stress tensor file (it does not start with TOTENSOR)");
  if (bytes.size() < kTensorHead) return no("the stress tensor file is cut short");
  const std::int32_t version = i32_at(p + 8);
  if (version != kTensorVersion)
    return no("the stress tensor file is version " + std::to_string(version) + ", and only version 1 can be read");
  const std::int32_t nx = i32_at(p + 12), ny = i32_at(p + 16), nz = i32_at(p + 20);
  if (nx <= 0 || ny <= 0 || nz <= 0) return no("the stress tensor's grid has no voxels");
  const std::uint64_t n = static_cast<std::uint64_t>(nx) * static_cast<std::uint64_t>(ny) * static_cast<std::uint64_t>(nz);
  if (bytes.size() != kTensorHead + 24 * n)
    return no("the stress tensor file is " + std::to_string(bytes.size()) + " bytes, and its grid needs " +
              std::to_string(kTensorHead + 24 * n));
  TensorField t;
  t.nx = nx; t.ny = ny; t.nz = nz;
  t.origin = {f64_at(p + 24), f64_at(p + 32), f64_at(p + 40)};
  t.spacing = f64_at(p + 48);
  if (!std::isfinite(t.origin.x) || !std::isfinite(t.origin.y) || !std::isfinite(t.origin.z))
    return no("the stress tensor's grid corner is not a finite number");
  if (!std::isfinite(t.spacing) || !(t.spacing > 0.0)) return no("the stress tensor's voxel size is not a number above 0");
  t.voigt.resize(static_cast<std::size_t>(6 * n));
  for (std::size_t i = 0; i < t.voigt.size(); ++i) {
    const float v = f32_at(p + kTensorHead + 4 * i);
    if (!std::isfinite(v))
      return no("the stress tensor holds a value that is not a finite number (voxel " + std::to_string(i / 6) + ")");
    t.voigt[i] = v;
  }
  out = std::move(t);
  return true;
}

bool write_tensor_file(const std::string& path, const TensorField& field) {
  if (field.empty()) return false;
  std::string o(kTensorMagic, 8);
  put_u32(o, static_cast<std::uint32_t>(kTensorVersion));
  for (int n : {field.nx, field.ny, field.nz}) put_u32(o, static_cast<std::uint32_t>(n));
  for (double v : {field.origin.x, field.origin.y, field.origin.z, field.spacing}) {
    std::uint64_t u;
    std::memcpy(&u, &v, 8);
    put_u64(o, u);
  }
  for (double d : field.voigt) {
    const float v = static_cast<float>(d);
    std::uint32_t u;
    std::memcpy(&u, &v, 4);
    put_u32(o, u);
  }
  std::ofstream f(path, std::ios::binary | std::ios::trunc);
  f.write(o.data(), static_cast<std::streamsize>(o.size()));
  f.close();
  return static_cast<bool>(f);
}

// ── THE SHALLOW-BAR TABLE ─────────────────────────────────────────────────────
ShallowTable shallow_bar_table(const Bars& all, const std::vector<int>& regions, const std::vector<Vec3>& drop_at,
                               const std::vector<MeshSpec::Post>& posts, double layer_mm) {
  ShallowTable t;
  const auto length = [](const Bar& b) {
    return std::sqrt((b.b.x - b.a.x) * (b.b.x - b.a.x) + (b.b.y - b.a.y) * (b.b.y - b.a.y) + (b.b.z - b.a.z) * (b.b.z - b.a.z));
  };
  const auto to_segment = [](const Vec3& p, const Vec3& a, const Vec3& b) {
    const Vec3 d{b.x - a.x, b.y - a.y, b.z - a.z};
    const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
    const double s = l2 > 0.0 ? std::clamp(((p.x - a.x) * d.x + (p.y - a.y) * d.y + (p.z - a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
    const double ex = a.x + s * d.x - p.x, ey = a.y + s * d.y - p.y, ez = a.z + s * d.z - p.z;
    return std::sqrt(ex * ex + ey * ey + ez * ez);
  };
  const auto holds = [](Bar::End e) { return e == Bar::End::Node || e == Bar::End::Solid || e == Bar::End::Joined; };
  // The shallow bars of the weave, in bar order.
  std::vector<const Bar*> sb;
  for (const Bar& b : all.bars)
    if (std::find(regions.begin(), regions.end(), b.region) != regions.end() && bar_is_bridge(b)) sb.push_back(&b);
  t.bars = sb.size();
  for (const Bar* b : sb) {
    const int h = holds(b->end_a) + holds(b->end_b);
    (h == 2 ? t.held_both : h == 1 ? t.held_one : t.held_none) += 1;
  }
  // The joints: the shallow bars' ends, ends within a hundredth of a micron being one point (O6, end_joints).
  const std::vector<std::size_t> joint = end_joints(all);
  std::map<std::size_t, std::vector<std::pair<std::size_t, int>>> at;   // (shallow bar, which end: 0 a, 1 b)
  for (std::size_t i = 0; i < sb.size(); ++i) {
    const std::size_t k = static_cast<std::size_t>(sb[i] - all.bars.data());
    at[joint[2 * k]].push_back({i, 0});
    at[joint[2 * k + 1]].push_back({i, 1});
  }
  // Chained through a joint of exactly two shallow bars, in line within 15 degrees.
  std::vector<std::size_t> up(sb.size());
  for (std::size_t i = 0; i < up.size(); ++i) up[i] = i;
  const auto find = [&](std::size_t v) {
    while (up[v] != v) v = up[v] = up[up[v]];
    return v;
  };
  const double in_line = std::cos(15.0 * 3.14159265358979323846 / 180.0);
  for (const auto& kv : at) {
    if (kv.second.size() != 2) continue;
    const auto [i, ei] = kv.second[0];
    const auto [j, ej] = kv.second[1];
    if (i == j) continue;
    // Into the joint along bar i, and out of it along bar j.
    const Vec3& p = ei ? sb[i]->b : sb[i]->a;
    const Vec3& pi = ei ? sb[i]->a : sb[i]->b;
    const Vec3& pj = ej ? sb[j]->a : sb[j]->b;
    const Vec3 u{p.x - pi.x, p.y - pi.y, p.z - pi.z}, v{pj.x - p.x, pj.y - p.y, pj.z - p.z};
    const double lu = std::sqrt(u.x * u.x + u.y * u.y + u.z * u.z), lv = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    if (!(lu > 0.0) || !(lv > 0.0)) continue;
    if ((u.x * v.x + u.y * v.y + u.z * v.z) / (lu * lv) >= in_line) up[find(i)] = find(j);
  }
  // Each run: its length and what the layer check did with it.
  // As the file writer leaves a bar out (solid_mesh.cpp: bars_present with the weave regions, O10).
  const std::vector<char> present = bars_present(all, drop_at, regions, layer_mm);
  const auto left_out = [&](const Bar& x) { return !present[static_cast<std::size_t>(&x - all.bars.data())]; };
  const auto under_post = [&](const Bar& x) {
    for (const MeshSpec::Post& q : posts)
      if (to_segment(Vec3{q.x, q.y, q.z_top}, x.a, x.b) < 0.5 * x.width + 0.5) return true;
    return false;
  };
  // The owner's bridge rules on what the places leave (weave_holds): a bar they leave out is left out.
  const WeaveHolds rules = weave_holds(all, regions, present);
  t.kept_any_length = rules.kept_any_length;
  t.weave_left_unheld = rules.left_unheld;
  const auto unheld = [&](const Bar* x) {
    const std::size_t i = static_cast<std::size_t>(x - all.bars.data());
    return rules.shallow[i] && !rules.kept[i];
  };
  struct Run { double mm = 0.0; bool out = false, post = false; };
  std::map<std::size_t, Run> runs;
  for (std::size_t i = 0; i < sb.size(); ++i) {
    Run& r = runs[find(i)];
    r.mm += length(*sb[i]);
    r.out = r.out || left_out(*sb[i]) || unheld(sb[i]);
    r.post = r.post || under_post(*sb[i]);
  }
  t.runs = runs.size();
  for (const auto& kv : runs) {
    const Run& r = kv.second;
    t.longest_run_mm = std::max(t.longest_run_mm, r.mm);
    ShallowTable::Band& b = t.bands[r.mm <= 5.0 ? 0 : r.mm <= 10.0 ? 1 : r.mm <= 20.0 ? 2 : 3];
    ++b.runs;
    (r.out ? b.left_out : r.post ? b.post : b.kept) += 1;
  }
  return t;
}

FileJob parse_file_job(const std::string& json_text) {
  try {
    const json::Value doc = json::parse(json_text, "job.json");
    const std::string w = "job.json";
    json::as_object(doc, w);
    json::reject_unknown(
        doc, {"mode", "model", "output", "linear_deflection", "threads", "layout", "mesh", "demand", "strength_job"}, w);
    json::reject_unknown(doc, {"mode", "model", "output", "linear_deflection", "threads", "layout", "mesh", "demand",
                               "tensor"},
                         w);
    const std::string mode = json::as_string(json::require(doc, "mode", w), w + ".mode");
    if (mode != "lattice_file") json::fail(w + ".mode", "must be \"lattice_file\", not \"" + mode + "\"");
    FileJob job;
    job.model = json::as_string(json::require(doc, "model", w), w + ".model");
    if (job.model.empty()) json::fail(w + ".model", "must name the part's file");
    job.output = text(doc, "output", job.output, w);
    // A bare file name: the STL always lands in the output folder, wherever the job came from.
    if (job.output.empty() || job.output == "." || job.output == ".." ||
        job.output.find_first_of("/\\") != std::string::npos)
      json::fail(w + ".output", "must be a file name with no folder in it");
    if (job.output == kFileResultName) json::fail(w + ".output", "is the result file's own name");
    job.linear_deflection = num(doc, "linear_deflection", 0.0, w);
    // The stress result: a file beside the job, by its bare name.
    if (json::find(doc, "demand")) {
      job.demand = text(doc, "demand", "", w);
      if (job.demand.empty() || job.demand == "." || job.demand == ".." ||
          job.demand.find_first_of("/\\") != std::string::npos)
        json::fail(w + ".demand", "must be a file name with no folder in it");
    }
    // The strength check's job (V4): a file beside the job, by its bare name.
    if (json::find(doc, "strength_job")) {
      job.strength_job = text(doc, "strength_job", "", w);
      if (job.strength_job.empty() || job.strength_job == "." || job.strength_job == ".." ||
          job.strength_job.find_first_of("/\\") != std::string::npos)
        json::fail(w + ".strength_job", "must be a file name with no folder in it");
      if (job.strength_job == job.output || job.strength_job == kFileResultName)
        json::fail(w + ".strength_job", "is the name of a file the job writes");
    }
    if (const json::Value* v = json::find(doc, "layout"))
    // The stress tensor (Organic, Traced): a file beside the job, by its bare name.
    if (json::find(doc, "tensor")) {
      job.tensor = text(doc, "tensor", "", w);
      if (job.tensor.empty() || job.tensor == "." || job.tensor == ".." ||
          job.tensor.find_first_of("/\\") != std::string::npos)
        json::fail(w + ".tensor", "must be a file name with no folder in it");
    }
    if (const json::Value* v = json::find(doc, "layout")) {
      job.settings = settings_from(json::as_object(*v, w + ".layout"), w + ".layout");
      job.organic = organic_from(*v, job.settings, w + ".layout");
    }
    if (const json::Value* v = json::find(doc, "mesh"))
      job.options = options_from(json::as_object(*v, w + ".mesh"), w + ".mesh");
    job.organic.layer_mm = job.options.layers.layer_mm;   // G1: Grown grows one printed layer per step
    job.options.threads = whole(doc, "threads", 0, w);
    if (job.options.threads < 0) json::fail(w + ".threads", "must be 0 (every core) or more");
    return job;
  } catch (const FileJobError&) {
    throw;
  } catch (const std::exception& e) {
    throw FileJobError(e.what());
  }
}

FileResult make_lattice_file(StepModel model, const FileJob& job, const std::string& stl_path,
                             const std::atomic<bool>* stop, void (*said)(const char*),
                             const StrengthCheck* strength) {
  FileResult r;
  const auto t_all = std::chrono::steady_clock::now();
  const auto done = [&]() -> FileResult& {
    r.ms_total += ms_since(t_all);
    return r;
  };
  try {
    r.faces = model.face_count;
    r.part_triangles = model.mesh.triangles.size();
    if (model.mesh.triangles.empty()) {
      refuse(r, kModelEmpty, "The part's file has no surface in it, so there is nothing to put lattice in.");
      return done();
    }
    // Before the long work: the faces every region and Protect skin names must be the part's.
    {
      std::vector<int> regions, skins;
      // A zone has no faces; pieces (D22) stand in for the faces and must leave a surface.
      auto none = [&](const std::vector<int>& faces, const std::vector<FacePiece>& pieces) {
        if (pieces.empty()) return faces_mesh(model, faces).triangles.empty();
        bool ok = false;
        (void)pieces_mesh(model, pieces, &ok);
        return !ok;
      };
      for (const Settings::RegionAsk& a : job.settings.regions)
        if (a.zone.kind == Zone::Kind::None && none(a.faces, a.pieces)) regions.push_back(a.id);
      for (const Settings::ProtectAsk& a : job.settings.protect)
        if (none(a.faces, a.pieces)) skins.push_back(a.id);
      if (!regions.empty()) {
        r.empty_regions = regions;
        refuse(r, kRegionFacesMissing, faces_missing("Region", "Regions", regions));
        return done();
      }
      if (!skins.empty()) {
        refuse(r, kProtectFacesMissing, faces_missing("Protect skin", "Protect skins", skins));
        return done();
      }
    }
    // R18: By stress with no stress result is refused, never made at the light end.
    // (A Lattice region's own By stress or cell size by stress, C23 and R19, asks for the stress as the part's does.)
    bool by_stress = job.settings.struts.mode == Density::ByStress, cells_by_stress = job.settings.cells.by_stress;
    for (const Settings::RegionAsk& a : job.settings.regions)
      if (a.role == Role::Lattice) {
        by_stress = by_stress || (a.own.by_stress && *a.own.by_stress);
        cells_by_stress = cells_by_stress || (a.own.cells_by_stress && *a.own.cells_by_stress);
      }
    const auto no_stress = [&] {
      refuse(r, kNoStress,
             "By stress needs a stress result, and none came with this job, so no file was made. Run the stress "
             "check first, or pick another density.");
      return done();
    };
    if (by_stress && (!job.settings.stress.demand || job.settings.stress.demand->empty()) &&
        (!job.settings.struts.demand || job.settings.struts.demand->empty()))
      return no_stress();
    // OR14: the weave is traced from the part's own stress, never from a made-up one here.
    bool any_weave = false;
    for (const Settings::RegionAsk& a : job.settings.regions) any_weave = any_weave || a.weave;
    if (any_weave && (!job.tensor_field || job.tensor_field->empty())) {
      refuse(r, kNoStress,
             "Organic follows the part's stress, and no stress result came with this job, so no file was made. Run the "
             "stress check first.");
      return done();
    }
    if (lattice_topology_is_sheet(job.settings.cells.topology)) {
      refuse(r, kTypeNotSupported,
             "This lattice type is made of sheets, and a lattice file can only be made from the "
             "types made of struts so far. Pick a strut type.");
      return done();
    }
    if (cells_by_stress && (!job.settings.stress.demand || job.settings.stress.demand->empty())) {
      refuse(r, kNoStress,
             "Cell size by stress needs a stress result, and this job has none, so nothing was made. Send the "
             "part's stress result with it, or turn Cell size by stress off.");
      return done();
    }
    // V4: the strength job is read before the long work, and refused now if it cannot be checked.
    if (!job.strength_job.empty()) {
      if (!strength || !strength->before || !strength->run) {
        refuse(r, kStrengthUnavailable,
               "This worker cannot check a lattice's strength, so no file was made. Update the worker.");
        return done();
      }
      const StrengthDone ok = strength->before(job.strength_job);
      if (!ok.ok) {
        r.ok = false;
        r.code = ok.code;
        r.exit_code = ok.exit_code;
        r.why = ok.why;
        r.detail = ok.detail;
        return done();
      }
    }
    if (!mesh_available()) {
      refuse(r, kMeshUnavailable,
             "The worker on the Mac was built without the part that makes lattice files, so it "
             "cannot make one. Update the worker.");
      return done();
    }

    say(said, "measuring the part");
    auto t0 = std::chrono::steady_clock::now();
    Vec3 part_lo{1e300, 1e300, 1e300}, part_hi{-1e300, -1e300, -1e300};
    for (const Vec3& v : model.mesh.vertices) {
      part_lo = {std::min(part_lo.x, v.x), std::min(part_lo.y, v.y), std::min(part_lo.z, v.z)};
      part_hi = {std::max(part_hi.x, v.x), std::max(part_hi.y, v.y), std::max(part_hi.z, v.z)};
    }
    Session session(std::move(model));
    r.ms_measure = ms_since(t0);
    r.open_edges = session.open_edges();
    if (r.open_edges != 0) {
      refuse(r, kPartNotClosed,
             "The part's surface has gaps in it (" + std::to_string(r.open_edges) +
                 (r.open_edges == 1 ? " open edge" : " open edges") +
                 "), so its inside cannot be told from its outside. Repair the model and send it again.");
      return done();
    }

    say(said, "laying the lattice");
    const Outcome out = any_weave ? session.lay_organic(job.settings, *job.tensor_field, job.organic,
                                                        job.options.threads, stop)
                                  : session.lay(job.settings, job.options.threads, stop);
    if (out.cancelled) {
      refuse(r, kCancelled, "Stopped before the lattice file was finished. Nothing was made.");
      return done();
    }
    r.cells = out.layout.cells.size();
    r.solid_pieces = out.layout.solid.size();
    r.bars = out.bars.bars.size();
    r.at_one_line = out.struts.at_bead;
    r.at_widest = out.struts.at_ceiling;
    r.stubs = out.bars.stubs;
    r.joined = out.bars.joined;
    r.dropped = out.bars.dropped;
    r.pieces = out.pieces.pieces;
    r.adrift = out.pieces.adrift;
    r.stepped_edges = out.stepped_edges.size();
    r.thin_solid = out.thin_solid;
    r.cells_by_stress = out.cells_by_stress;
    r.step_held_at = out.step_held_at;   // C24
    r.floor_cell_mm = out.layout.floor_cell_mm;
    r.min_strut_mm = out.layout.min_strut_mm;
    r.open_look = out.layout.open_look;
    r.touch = out.layout.touch;
    r.empty_regions = out.empty_regions;
    r.ms_read = out.ms_read;
    r.ms_cells = out.ms_cells;
    r.ms_bars = out.ms_bars;
    r.by_stress = by_stress;
    r.reference_mpa = out.struts.reference_mpa;
    r.highest_mpa = out.struts.highest_mpa;
    r.at_light = out.struts.at_light;
    r.at_heavy = out.struts.at_heavy;
    std::vector<int> weave_regions;
    for (const Layout::Weave& w : out.layout.weave) weave_regions.push_back(w.region);
    r.weave_regions = weave_regions.size();
    r.strands = out.strands;
    r.ms_trace = out.ms_trace;
    r.spacing_smallest_mm = out.spacing_smallest_mm;
    r.spacing_largest_mm = out.spacing_largest_mm;
    r.spacing_mean_mm = out.spacing_mean_mm;
    r.net_struts = out.net_struts;
    r.net_mm = out.net_mm;
    r.grown = out.grown;
    for (const Bar& b : out.bars.bars)
      r.weave_bars += std::find(weave_regions.begin(), weave_regions.end(), b.region) != weave_regions.end();
    if (!out.empty_regions.empty()) {
      refuse(r, kRegionFacesMissing, faces_missing("Region", "Regions", out.empty_regions));
      return done();
    }
    if (out.layout.cells.empty() && out.layout.weave.empty()) {   // O1: a weave has no cells and is not refused for it
      refuse(r, kNoCells,
             "No lattice cell fits anywhere in this part with these settings, so there is no lattice "
             "to make. Try a smaller cell, a deeper region, or more of the part.");
      return done();
    }
    // A field with no stress in the lattice's space gives no reference: no stress result to grade by either (R18).
    if (by_stress && out.struts.no_stress) return no_stress();
    if (out.bars.bars.empty()) {
      refuse(r, kNoStruts,
             "The lattice here has no struts left to print, so no file was made. Try a smaller cell "
             "or a deeper region.");
      return done();
    }

    say(said, "making the file");
    const TriangleMesh mesh = make_file_mesh(session, out, job.options, r.made, stop);
    if (!r.made.mesh.ok || mesh.empty()) {
      refuse(r, kMeshFailed,
             r.made.mesh.why.empty() ? "The lattice file could not be put together. Nothing was made."
                                     : r.made.mesh.why);
      return done();
    }
    if (!weave_regions.empty()) {
      r.shallow = shallow_bar_table(r.made.sagged ? *r.made.sagged : out.bars, weave_regions, r.made.left_out_at, r.made.posts,
                                    job.options.layers.layer_mm);
      r.shallow.stands_added = r.made.stands_added;
    }
    if (!r.made.print_clean && !job.options.keep_if_not_clean) {
      const std::size_t mid = r.made.layers.mid_air.size(), one = r.made.layers.one_ended.size(),
                        far = r.made.layers.long_bridges.size();
      char line[320];
      std::snprintf(line, sizeof line,
                    "After %d tries the lattice still has %zu place%s that would start printing in mid-air, %zu overhang%s "
                    "held at one end only and %zu bridge%s longer than a printer can span. No file was made. A larger cell "
                    "or a Protect skin near those places usually fixes it.",
                    r.made.builds, mid, mid == 1 ? "" : "s", one, one == 1 ? "" : "s", far, far == 1 ? "" : "s");
      refuse(r, kWouldNotPrint, line);
      return done();
    }

    say(said, "saving the file");
    t0 = std::chrono::steady_clock::now();
    // Written beside its target and moved in only when whole: a failed job never leaves
    // half a file, nor replaces an earlier good one.
    const std::string part = stl_path + ".part";
    const std::size_t want = 84 + 50 * mesh.triangles.size();
    bool written = false;
    std::string write_detail;
    try {
      write_stl_file(part, mesh, StlFormat::Binary);
      written = size_of_file(part) == want;
      if (!written) write_detail = "the file is not the size its triangles need";
    } catch (const std::exception& e) {
      write_detail = e.what();
    }
    if (written && std::rename(part.c_str(), stl_path.c_str()) != 0) {
      written = false;
      write_detail = "cannot move the file into " + stl_path;
    }
    r.ms_write = ms_since(t0);
    if (!written) {
      std::remove(part.c_str());
      refuse(r, kCannotWrite,
             "The lattice file could not be saved on the Mac (the folder is missing or the disk is full).",
             write_detail);
      return done();
    }
    // V4: the check of the lattice that is in the file, after every cut and repair. A check asked for that cannot
    // run fails the job: the file is taken away again, so nothing looks checked that was not.
    if (!job.strength_job.empty()) {
      say(said, "checking its strength");
      t0 = std::chrono::steady_clock::now();
      StrengthAsk ask;
      ask.session = &session;
      ask.outcome = &out;
      ask.made = &r.made;
      ask.job_path = job.strength_job;
      ask.out_dir = folder_of(stl_path);
      ask.part_lo = part_lo;
      ask.part_hi = part_hi;
      ask.threads = job.options.threads;
      StrengthDone sd;
      try {
        sd = strength->run(ask);
      } catch (const std::exception& e) {
        sd = StrengthDone{};
        sd.code = "strength_failed";
        sd.why = "The lattice's strength could not be checked, so no file was made.";
        sd.detail = e.what();
      }
      r.ms_strength = ms_since(t0);
      if (!sd.ok) {
        std::remove(stl_path.c_str());
        for (const std::string& f : sd.files) std::remove((ask.out_dir + "/" + f).c_str());
        r.ok = false;
        r.code = sd.code.empty() ? "strength_failed" : sd.code;
        r.exit_code = sd.exit_code;
        r.why = sd.why;
        r.detail = sd.detail;
        return done();
      }
      r.strength_ran = true;
      r.strength_accepted = sd.accepted;
      r.strength_json = sd.json;
    }
    r.file = stl_path;
    r.file_bytes = want;
    r.ok = true;
    r.code = "ok";
    r.exit_code = 0;
  } catch (const LayCancelled&) {
    refuse(r, kCancelled, "Stopped before the lattice file was finished. Nothing was made.");
  } catch (const std::exception& e) {
    refuse(r, kError, "Something went wrong while making the lattice file, and nothing was made.", e.what());
  } catch (...) {
    refuse(r, kError, "Something went wrong while making the lattice file, and nothing was made.");
  }
  return done();
}

FileResult run_file_job(const std::string& job_path, const std::string& out_dir, int threads,
                        void (*said)(const char*), const StrengthCheck* strength) {
  FileResult r;
  const auto t_all = std::chrono::steady_clock::now();
  const auto run = [&] {
    FileJob job;
    {
      std::ifstream f(job_path, std::ios::binary);
      if (!f) {
        refuse(r, kJobUnreadable, "The lattice job could not be opened on the Mac, so nothing was made.",
               "cannot open " + job_path);
        return;
      }
      std::ostringstream all;
      all << f.rdbuf();
      try {
        job = parse_file_job(all.str());
      } catch (const std::exception& e) {
        refuse(r, kJobUnreadable,
               "The lattice job sent to the Mac could not be read, so nothing was made.", e.what());
        return;
      }
    }
    if (threads > 0) job.options.threads = threads;
    if (!job.strength_job.empty()) job.strength_job = folder_of(job_path) + "/" + job.strength_job;
    if (!job.demand.empty()) {
      auto field = std::make_shared<DemandField>();
      std::string why;
      if (!read_demand_file(folder_of(job_path) + "/" + job.demand, *field, &why)) {
        refuse(r, kDemandUnreadable, "The stress result sent with the lattice job could not be read, so nothing was made.",
               why);
        return;
      }
      job.settings.stress.demand = std::move(field);
    }
    if (!job.tensor.empty()) {
      auto field = std::make_shared<TensorField>();
      std::string why;
      if (!read_tensor_file(folder_of(job_path) + "/" + job.tensor, *field, &why)) {
        refuse(r, kTensorUnreadable,
               "The stress tensor sent with the lattice job could not be read, so nothing was made.", why);
        return;
      }
      job.tensor_field = std::move(field);
    }
    const std::string model_path =
        !job.model.empty() && job.model[0] == '/' ? job.model : folder_of(job_path) + "/" + job.model;
    say(said, "opening the part");
    const auto t0 = std::chrono::steady_clock::now();
    StepModel model;
    try {
      StepTessellation tess;
      if (job.linear_deflection > 0.0) tess.linear_deflection = job.linear_deflection;
      model = import_part_file_resolved(model_path, tess);
    } catch (const std::exception& e) {
      refuse(r, kModelUnreadable,
             "The part's file could not be opened on the Mac, so no lattice file was made.", e.what());
      return;
    } catch (...) {
      refuse(r, kModelUnreadable,
             "The part's file could not be opened on the Mac, so no lattice file was made.");
      return;
    }
    const double ms_import = ms_since(t0);
    r = make_lattice_file(std::move(model), job, out_dir + "/" + job.output, nullptr, said, strength);
    r.ms_import = ms_import;
  };
  run();
  r.ms_total = ms_since(t_all);
  // The result file, whatever happened.
  const std::string result_path = out_dir + "/" + kFileResultName;
  std::ofstream f(result_path, std::ios::binary | std::ios::trunc);
  f << file_result_json(r);
  f.close();
  if (!f && r.ok) {
    std::remove(r.file.c_str());
    refuse(r, kCannotWrite,
           "The lattice file could not be saved on the Mac (the folder is missing or the disk is full).",
           "cannot write " + result_path);
    r.file.clear();
    r.file_bytes = 0;
  }
  return r;
}

std::string file_result_json(const FileResult& r) {
  std::string o;
  char b[1024];
  const auto count = [](std::size_t n) { return static_cast<unsigned long long>(n); };
  o += "{\n";
  o += std::string("  \"ok\": ") + (r.ok ? "true" : "false") + ",\n";
  o += "  \"code\": \"" + escaped(r.code) + "\",\n";
  o += "  \"why\": \"" + escaped(r.why) + "\",\n";
  o += "  \"detail\": \"" + escaped(r.detail) + "\",\n";
  o += "  \"file\": \"" + escaped(base_name(r.file)) + "\",\n";
  std::snprintf(b, sizeof b, "  \"file_bytes\": %llu,\n", count(r.file_bytes));
  o += b;
  std::snprintf(b, sizeof b, "  \"part\": {\"faces\": %d, \"triangles\": %llu, \"open_edges\": %llu},\n",
                r.faces, count(r.part_triangles), count(r.open_edges));
  o += b;
  std::snprintf(b, sizeof b,
                "  \"layout\": {\"cells\": %llu, \"solid_pieces\": %llu, \"bars\": %llu, "
                "\"at_one_line\": %llu, \"at_widest\": %llu, \"stubs\": %llu, \"joined\": %llu, "
                "\"dropped\": %llu, \"pieces\": %llu, \"adrift\": %llu, \"stepped_edges\": %llu, "
                "\"thin_solid\": %llu, \"cells_by_stress\": %s, \"step_held_at\": %.9g,\n",
                count(r.cells), count(r.solid_pieces), count(r.bars), count(r.at_one_line),
                count(r.at_widest), count(r.stubs), count(r.joined), count(r.dropped), count(r.pieces),
                count(r.adrift), count(r.stepped_edges), count(r.thin_solid),
                r.cells_by_stress ? "true" : "false", r.step_held_at);
  o += b;
  std::snprintf(b, sizeof b, "    \"weave_regions\": %llu, \"strands\": %llu, \"weave_bars\": %llu,\n",
                count(r.weave_regions), count(r.strands), count(r.weave_bars));
  o += b;
  std::snprintf(b, sizeof b,
                "    \"floor_cell_mm\": %.9g, \"min_strut_mm\": %.9g, \"open_look\": %.9g, "
                "\"touch\": %.9g, \"empty_regions\": [",
                r.floor_cell_mm, r.min_strut_mm, r.open_look, r.touch);
  o += b;
  for (std::size_t i = 0; i < r.empty_regions.size(); ++i)
    o += (i ? ", " : "") + std::to_string(r.empty_regions[i]);
  o += "],\n";
  std::snprintf(b, sizeof b,
                "    \"by_stress\": %s, \"reference_mpa\": %.9g, \"highest_mpa\": %.9g, \"at_light\": %llu, "
                "\"at_heavy\": %llu},\n",
                r.by_stress ? "true" : "false", r.reference_mpa, r.highest_mpa, count(r.at_light), count(r.at_heavy));
  o += b;
  const MeshReport& m = r.made.mesh;
  std::snprintf(b, sizeof b,
                "  \"mesh\": {\"triangles\": %llu, \"mm3\": %.9g, \"part_mm3\": %.9g, \"struts_mm3\": %.9g, "
                "\"solid_mm3\": %.9g, \"bars\": %llu, \"bridges\": %llu, \"balls\": %llu,\n",
                count(m.triangles), m.mm3, m.part_mm3, m.struts_mm3, m.solid_mm3, count(m.bars),
                count(m.bridges), count(m.balls));
  o += b;
  std::snprintf(b, sizeof b,
                "    \"bars_left_out\": %llu, \"bars_left_out_mm\": %.9g, \"drop_unanswered\": %llu, "
                "\"posts\": %llu, \"posts_mm\": %.9g, \"solid_pieces\": %llu,\n",
                count(m.bars_left_out), m.bars_left_out_mm, count(m.drop_unanswered), count(m.posts),
                m.posts_mm, count(m.solid_pieces));
  o += b;
  std::snprintf(b, sizeof b,
                "    \"slivers_left_out\": %llu, \"slivers_mm3\": %.9g, \"touching_places\": %llu, "
                "\"air_pockets\": %llu, \"air_pockets_mm3\": %.9g, \"sealed_spaces\": %llu,\n",
                count(m.slivers_left_out), m.slivers_mm3, count(m.touching_places), count(m.air_pockets),
                m.air_pockets_mm3, count(m.sealed_spaces));
  o += b;
  std::snprintf(b, sizeof b,
                "    \"loose_bits\": %llu, \"loose_mm3\": %.9g, \"flat_triangles\": %llu, "
                "\"open_boxes\": %llu, \"builds\": %d},\n",
                count(m.loose_bits), m.loose_mm3, count(m.flat_triangles), count(r.made.open_boxes),
                r.made.builds);
  o += b;
  {
    // His print rules, as measured on the mesh the file holds, and what the loop did to get there.
    const LayerReport& l = r.made.layers;
    std::snprintf(b, sizeof b,
                  "  \"print_check\": {\"bed_contact_mm2\": %.9g, \"midair_starts\": %d, \"clean\": %s, \"passes\": %d,\n"
                  "    \"one_ended\": %llu, \"long_bridges\": %llu, \"longest_bridge_reach_mm\": %.9g, \"bed_flat\": %s, \"first_layer_mm2\": %.9g, "
                  "\"sloped_underside_mm2\": %.9g,\n    \"layers\": %d, \"thin_islands\": %llu, \"thin_layers\": %d,\n",
                  r.made.bed_contact_mm2, r.made.midair_starts, r.made.print_clean ? "true" : "false", r.made.builds,
                  count(l.one_ended.size()), count(l.long_bridges.size()), l.longest_reach_mm, l.bed_flat() ? "true" : "false", l.first_layer_mm2,
                  l.sloped_mm2, l.layers, count(l.thin_islands), l.thin_layers);
    o += b;
    o += "    \"found_per_pass\": [";
    for (std::size_t i = 0; i < r.made.found_per_pass.size(); ++i) {
      std::snprintf(b, sizeof b, "%s%d", i ? ", " : "", r.made.found_per_pass[i]);
      o += b;
    }
    o += "],\n    \"left_out_at\": [";
    for (std::size_t i = 0; i < r.made.left_out_at.size(); ++i) {
      const Vec3& p = r.made.left_out_at[i];
      std::snprintf(b, sizeof b, "%s[%.4f, %.4f, %.4f]", i ? ", " : "", p.x, p.y, p.z);
      o += b;
    }
    o += "],\n    \"posts\": [";
    for (std::size_t i = 0; i < r.made.posts.size(); ++i) {
      const MeshSpec::Post& p = r.made.posts[i];
      std::snprintf(b, sizeof b, "%s[%.4f, %.4f, %.4f, %.4f]", i ? ", " : "", p.x, p.y, p.z_bottom, p.z_top);
      o += b;
    }
    o += "]},\n";
  }
  // V4: written only when the check ran (V2); the block is the check's own.
  if (r.strength_ran) o += "  \"strength\": " + r.strength_json + ",\n";
  {
    // Organic, Traced: the trace's time and the shallow-bar table (ShallowTable).
    const ShallowTable& t = r.shallow;
    std::snprintf(b, sizeof b,
                  "  \"organic\": {\"ms_trace\": %.1f, \"spacing_used_mm\": {\"smallest\": %.9g, \"largest\": %.9g, "
                  "\"mean\": %.9g},\n    \"net_struts\": %llu, \"net_mm\": %.9g,"
                  "\n    \"shallow_bars\": %llu, \"held_both\": %llu, \"held_one\": %llu, "
                  "\"held_none\": %llu,\n    \"kept_any_length\": %llu, \"weave_left_unheld\": %llu, \"stands_added\": %llu,"
                  "\n    \"feet\": %llu, \"feet_held\": %llu, \"feet_mm3\": %.9g,"
                  "\n    \"runs\": %llu, \"longest_run_mm\": %.9g, \"run_bands\": [",
                  r.ms_trace, r.spacing_smallest_mm, r.spacing_largest_mm, r.spacing_mean_mm,
                  count(r.net_struts), r.net_mm, count(t.bars),
                  count(t.held_both), count(t.held_one), count(t.held_none),
                  count(t.kept_any_length), count(t.weave_left_unheld), count(t.stands_added),
                  count(r.made.mesh.feet), count(r.made.mesh.feet_held), r.made.mesh.feet_mm3, count(t.runs),
                  t.longest_run_mm);
    o += b;
    const char* names[4] = {"to 5 mm", "5 to 10 mm", "10 to 20 mm", "over 20 mm"};
    for (int k = 0; k < 4; ++k) {
      const ShallowTable::Band& d = t.bands[k];
      std::snprintf(b, sizeof b, "%s\n      {\"band\": \"%s\", \"runs\": %llu, \"kept\": %llu, \"left_out\": %llu, \"post\": %llu}",
                    k ? "," : "", names[k], count(d.runs), count(d.kept), count(d.left_out), count(d.post));
      o += b;
    }
    o += "]";
    if (r.weave_regions > 0) {   // O10: only a job with a weave says them (a cube-lattice file is as before)
      std::snprintf(b, sizeof b, ",\n    \"weave_specks_ignored\": %llu, \"weave_held_ignored\": %llu",
                    count(r.made.weave_specks_ignored), count(r.made.weave_held_ignored));
      o += b;
      // O17, O18: what was done with the weave's sags.
      std::snprintf(b, sizeof b,
                    ",\n    \"sags_lifted\": %llu, \"sag_lift_largest_mm\": %.9g, \"sag_legs\": %llu, \"sag_legs_mm\": %.9g, "
                    "\"sags_unsupported\": %llu",
                    count(r.made.sags.lifted), r.made.sags.lift_largest_mm, count(r.made.sags.legs), r.made.sags.legs_mm,
                    count(r.made.sags.unsupported));
      o += b;
    }
    o += "},\n";
  }
  if (r.grown) {
    // G12: written only for Grown, so a Traced file's result is as it was.
    const GrowReport& g = *r.grown;
    char gb[4096];
    std::snprintf(gb, sizeof gb,
                  "  \"grown\": {\"strands\": %llu, \"grown_mm\": %.9g, \"kept_mm\": %.9g, \"cut_mm\": {\"outside\": %.9g, "
                  "\"unsupported\": %.9g, \"leads_to_nothing\": %.9g, \"repeat\": %.9g},\n"
                  "    \"seeds_floor\": %llu, \"seeds_wall\": %llu, \"seeds_refused_support\": %llu, "
                  "\"strands_grown\": %llu, \"steps\": %llu, \"clamped\": %llu, \"tips\": %llu, \"tip_budget_hit\": %llu,\n"
                  "    \"ended_edge\": %llu, \"ended_unsupported\": %llu, \"ended_joins\": %llu, \"joins\": %llu, "
                  "\"grew_on_after_join\": %llu, \"joins_refused_span\": %llu,\n"
                  "    \"branches_offered\": %llu, \"branches_grown\": %llu, \"links\": %llu, \"refused_region\": %llu, "
                  "\"refused_support\": %llu, \"refused_crowded\": %llu,\n"
                  "    \"bare_before\": %.9g, \"bare_after\": %.9g, \"reseed_voids\": %llu, \"reseed_landed\": %llu, "
                  "\"reseed_failed\": %llu, \"reseed_mm\": %.9g,\n"
                  "    \"ties_seeded\": %llu, \"ties_laid\": %llu, \"ties_refused_minor\": %llu, \"ties_refused_reach\": %llu, "
                  "\"ms\": %.1f},\n",
                  count(g.strands), g.grown_mm, g.kept_mm, g.cut_outside_mm, g.cut_unsupported_mm, g.cut_nothing_mm,
                  g.cut_repeat_mm, count(g.seeds_floor), count(g.seeds_wall), count(g.seeds_refused_support),
                  count(g.strands_grown), count(g.steps), count(g.clamped), count(g.tips), count(g.tip_budget_hit),
                  count(g.ended_edge), count(g.ended_unsupported), count(g.ended_joins), count(g.joins),
                  count(g.grew_on_after_join), count(g.joins_refused_span), count(g.branches_offered),
                  count(g.branches_grown), count(g.links), count(g.refused_region), count(g.refused_support),
                  count(g.refused_crowded), g.bare_before, g.bare_after, count(g.reseed_voids), count(g.reseed_landed),
                  count(g.reseed_failed), g.reseed_mm, count(g.ties_seeded), count(g.ties_laid),
                  count(g.ties_refused_minor), count(g.ties_refused_reach), g.ms);
    o += gb;
  }
  std::snprintf(b, sizeof b,
                "  \"ms\": {\"import\": %.1f, \"measure\": %.1f, \"read\": %.1f, \"cells\": %.1f, "
                "\"bars\": %.1f, \"open_space\": %.1f, \"carve\": %.1f, \"struts\": %.1f, \"solid\": %.1f, "
                "\"finish\": %.1f, \"write\": %.1f, \"total\": %.1f}\n",
                r.ms_import, r.ms_measure, r.ms_read, r.ms_cells, r.ms_bars, r.made.ms_open_space, r.made.ms_carve,
                m.ms_struts, m.ms_solid, m.ms_finish, r.ms_write, r.ms_total);
  o += b;
  o += "}\n";
  return o;
}

}  // namespace topopt::lattice_layout
