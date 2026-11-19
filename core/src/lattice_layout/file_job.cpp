// Lattice rebuild: the lattice file job. See lattice_layout_file.hpp and
// docs/design/lattice-rebuild/04-layout-file-job.md.
#include "topopt/lattice_layout_file.hpp"
#include "topopt/threemf_stream.hpp"

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
       "organic_run_follow", "organic_run_pull", "organic_run_seek", "organic_run_min", "organic_root_gap",
       "organic_auto", "organic_width_heavy_mm", "organic_member_cap", "organic_prune", "organic_bed_floor_mm",
       "organic_shape_reach", "organic_hold_parts", "organic_part_reach_mm",
       "organic_part_support_mm", "organic_part_to_floor", "organic_wall_gap_heavy", "organic_cross_gap",
       "organic_cross_gap_heavy", "organic_cross_climb_max_deg", "organic_tie_level", "organic_tie_gap",
       "organic_tie_gap_heavy", "organic_link_width", "organic_unbraced_max", "organic_follow_stress",
       "organic_gap_lines", "organic_face_relief_mm", "organic_relief_exclude_faces", "organic_strand_keep"},
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
  // OP7 (brief C2, E1): only what a key IS is checked here (a number, a whole number, given with what); every range
  // and rule on the values is validate_organic's, called by parse_file_job once the ask is whole (its layer is the
  // mesh's), exactly as the session path calls it.
  // A whole number held to [lo_cap, hi_cap] before the cast (the range itself is validate_organic's).
  const auto whole_of = [&](const char* key, double v, const char* text_if_not) {
    if (!(std::isfinite(v) && v == std::floor(v) && std::fabs(v) <= 2e9)) json::fail(w + "." + key, text_if_not);
    return static_cast<int>(v);
  };
  a.walls_out = flag(in, "organic_walls_out", a.walls_out, w);
  a.ties = flag(in, "organic_ties", a.ties, w);
  a.tie_swirl = num(in, "organic_tie_swirl", a.tie_swirl, w);
  a.foot_gap = num(in, "organic_foot_gap", a.foot_gap, w);
  // D (brief G6, an experiment): the stress lines are the goal (off when not given).
  a.stress_goal = flag(in, "organic_stress_goal", a.stress_goal, w);
  // E (brief G6, try keys): the re-seeding's bare distance (1.5 when not given) and its rounds (1 when not given).
  a.void_ratio = num(in, "organic_void_ratio", a.void_ratio, w);
  a.reseed_rounds = whole_of("organic_reseed_rounds", num(in, "organic_reseed_rounds", a.reseed_rounds, w),
                             "must be a whole number, 0 to 100");
  a.wall_connect = flag(in, "organic_wall_connect", a.wall_connect, w);   // E (off when not given)
  a.wall_gap = num(in, "organic_wall_gap", a.wall_gap, w);   // E: 0 or less (and when not given): off
  a.wall_gap_heavy = num(in, "organic_wall_gap_heavy", a.wall_gap_heavy, w);   // M: 0 or less (and when not given): off
  // F (brief G7, a try key): crossing vines (0 when not given: off).
  a.wall_cross = whole_of("organic_wall_cross", num(in, "organic_wall_cross", a.wall_cross, w), "must be 0, 1 or 2");
  // N (brief G21): the crossing gap in spacings (2.5 when not given), and by stress (0 or less, and not given: off).
  a.cross_gap = num(in, "organic_cross_gap", a.cross_gap, w);
  a.cross_gap_heavy = num(in, "organic_cross_gap_heavy", a.cross_gap_heavy, w);
  // O (brief G22): the steepest a crossing vine climbs, degrees from level (45 when not given, as before).
  a.cross_climb_max_deg = num(in, "organic_cross_climb_max_deg", a.cross_climb_max_deg, w);
  // P (brief G23): level ties (off when not given), the tie gap in spacings (1 when not given), and by stress (0 or
  // less, and not given: off). R (brief G26): a Traced job lays them too, with no need of organic_ties (Grown's switch).
  a.tie_level = flag(in, "organic_tie_level", a.tie_level, w);
  a.tie_gap = num(in, "organic_tie_gap", a.tie_gap, w);
  a.tie_gap_heavy = num(in, "organic_tie_gap_heavy", a.tie_gap_heavy, w);
  // S8 (brief G28): a link's width, in the thinner joined strut's widths (1 when not given).
  a.link_width = num(in, "organic_link_width", a.link_width, w);
  // T (brief G30): the longest a strut runs without a joint, in its widths (0 when not given: off).
  a.unbraced_max = num(in, "organic_unbraced_max", a.unbraced_max, w);
  // G (brief G8, try keys): top runs, roots (0 when not given: off), runs per end (1 when not given).
  a.top_run = num(in, "organic_top_run", a.top_run, w);
  a.root_run = num(in, "organic_root_run", a.root_run, w);
  a.run_gap = num(in, "organic_run_gap", a.run_gap, w);
  a.run_max = whole_of("organic_run_max", num(in, "organic_run_max", a.run_max, w), "must be a whole number, 1 or more");
  // H (brief G9, try keys): how a run is steered and when it may end.
  a.run_follow = num(in, "organic_run_follow", a.run_follow, w);
  a.run_pull = num(in, "organic_run_pull", a.run_pull, w);
  a.run_seek = num(in, "organic_run_seek", a.run_seek, w);
  a.run_min = num(in, "organic_run_min", a.run_min, w);
  a.root_gap = num(in, "organic_root_gap", a.root_gap, w);
  a.auto_by_stress = flag(in, "organic_auto", a.auto_by_stress, w);   // I
  a.follow_stress = flag(in, "organic_follow_stress", a.follow_stress, w);   // OP6: false = shape only
  a.member_cap = flag(in, "organic_member_cap", a.member_cap, w);   // J1
  a.prune = flag(in, "organic_prune", a.prune, w);   // J2
  a.bed_floor_mm = num(in, "organic_bed_floor_mm", a.bed_floor_mm, w);   // K1
  a.shape_reach = num(in, "organic_shape_reach", a.shape_reach, w);   // L1
  a.hold_parts = flag(in, "organic_hold_parts", a.hold_parts, w);   // L2
  a.part_reach_mm = num(in, "organic_part_reach_mm", a.part_reach_mm, w);
  a.part_support_mm = num(in, "organic_part_support_mm", a.part_support_mm, w);
  a.part_to_floor = flag(in, "organic_part_to_floor", a.part_to_floor, w);
  a.width_heavy_mm = num(in, "organic_width_heavy_mm", a.width_heavy_mm, w);   // I
  // OG1, OG2 (brief E6): the gap between struts in line widths (1.5 when not given; 0 off), the surface relief in mm (1
  // when not given; 0 off) and the faces left flush (none when not given). Their ranges are validate_organic's.
  a.gap_lines = num(in, "organic_gap_lines", a.gap_lines, w);
  a.face_relief_mm = num(in, "organic_face_relief_mm", a.face_relief_mm, w);
  a.relief_exclude_faces = wholes(in, "organic_relief_exclude_faces", w);
  a.strand_keep = num(in, "organic_strand_keep", a.strand_keep, w);   // OG3 (0.9 when not given)
  return a;
}

FileOptions options_from(const json::Value& in, const std::string& w) {
  json::reject_unknown(in,
                       {"pitch_mm", "bar_sides", "block_mm", "grow_mm", "clean_mm", "part_mm",
                        "fill_under_mm3", "bridge_rise", "post_mm", "layer_mm", "pixel_mm", "most_passes",
                        "leave_out", "keep_if_not_clean", "weave_stand_every_mm", "weave_foot_mm", "weave_round_top",
                        "weave_sag_lift_mm", "weave_sag_legs", "weave_mesh", "tube_sides"},
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
  if (json::find(in, "weave_mesh")) {   // OF4
    const std::string m = text(in, "weave_mesh", "", w);
    if (m == "tubes") o.mesh.weave_mesh = MeshSpec::WeaveMesh::Tubes;
    else if (m == "merged") o.mesh.weave_mesh = MeshSpec::WeaveMesh::Merged;
    else json::fail(w + ".weave_mesh", "must be \"tubes\" or \"merged\", not \"" + m + "\"");
    o.weave_mesh_asked = true;
  }
  o.mesh.tube_sides = whole(in, "tube_sides", o.mesh.tube_sides, w);   // OF2
  if (o.mesh.tube_sides < 3) json::fail(w + ".tube_sides", "must be 3 or more");
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
// Brief E2: a strength job on a job whose lattice regions are both weave and cells: the two checks judge differently
// and are not made into one verdict.
constexpr Refusal kStrengthMixed{"strength_mixed", 1};
// Brief E2, item 11: the job's "strengthened" file (or what it names) could not be read.
constexpr Refusal kStrengthenedUnreadable{"strengthened_unreadable", 1};
// Brief E3a: the lay does not give the lattice its additions were made on (a round's hash, or a bar they name).
constexpr Refusal kStrengthenedMismatch{"strengthened_mismatch", 1};
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
  return make_file_mesh(session, outcome.layout, outcome.bars, options, report, stop);
}

TriangleMesh make_file_mesh(const Session& session, const Layout& layout, const Bars& bars, const FileOptions& options,
                            FileReport& report, const std::atomic<bool>* stop) {
  report = FileReport{};
  const Domain* domain = session.domain();
  if (!domain) {
    report.mesh.why = "The lattice was not laid before its file was asked for.";
    return TriangleMesh{};
  }
  const OpenSpace open = read_open_space(*domain, layout, options.pitch_mm, options.threads, stop);
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
  TriangleMesh mesh = build_printable_mesh(session.measure(), *domain, layout, bars, open, spec, &made);
  report.mesh = made.mesh;
  report.builds = made.passes;
  report.ms_carve = made.ms_carve;
  report.layers = made.layers;
  report.print_clean = made.clean;
  report.found_per_pass = made.found_per_pass;
  report.left_out_at = made.drop_at;
  report.posts = made.posts;
  report.stands_added = made.stands_added;
  report.findings_at = made.findings_at;   // OG2c
  report.relief_flushed = made.relief_flushed;
  report.relief_rounds = made.relief_rounds;
  report.weave_specks_ignored = made.weave_specks_ignored;
  report.weave_held_ignored = made.weave_held_ignored;
  report.part_overhangs = made.part_overhangs;
  report.sags = made.sags;
  report.sagged = made.sagged;
  report.tubes = made.tubes;
  report.shells = made.shells;
  report.base_triangles = made.base_triangles;
  report.shell_first_tri = made.shell_first_tri;
  report.base_builds = made.base_builds;
  report.ms_shells = made.ms_shells;
  report.pass_ms = made.pass_ms;
  if (made.mesh.ok) {
    report.bed_contact_mm2 = made.layers.bed_mm2;
    report.midair_starts = static_cast<int>(made.layers.mid_air.size());
  }
  return mesh;
}

// ── BRIEF E4, LEG 2 (OS16): THE PRINT CHECK, ITS BARS ───────────────────────────
std::vector<char> bars_in_file(const Bars& made_bars, const FileReport& made, const std::vector<int>& weave_regions,
                               const FileOptions& options) {
  const double layer = options.layers.layer_mm > 0.0 ? options.layers.layer_mm : 0.2;
  const std::vector<char> present = bars_present(made_bars, made.left_out_at, weave_regions, layer);
  return weave_holds(made_bars, weave_regions, present, options.mesh.bridge_rise).kept;
}

FileOptions file_options_for(const FileOptions& asked, bool weave) {
  FileOptions o = asked;
  if (weave && !o.weave_mesh_asked) o.mesh.weave_mesh = MeshSpec::WeaveMesh::Tubes;
  return o;
}

PrintChecked print_check_bars(const Session& session, const Layout& layout, const Bars& bars, const FileOptions& options,
                              const std::atomic<bool>* stop) {
  PrintChecked p;
  const TriangleMesh mesh = make_file_mesh(session, layout, bars, options, p.made, stop);
  if (!p.made.mesh.ok || mesh.empty()) {
    p.why = p.made.mesh.why.empty() ? "the lattice's mesh could not be made" : p.made.mesh.why;
    return p;
  }
  p.bars = p.made.sagged ? *p.made.sagged : bars;
  std::vector<int> weave_regions;
  for (const Layout::Weave& w : layout.weave) weave_regions.push_back(w.region);
  p.kept = bars_in_file(p.bars, p.made, weave_regions, options);
  p.ok = true;
  return p;
}

std::function<std::string(const Layout&, Bars&)> print_check_hook(const Session& session, const FileOptions& options,
                                                                   const std::atomic<bool>* stop) {
  return [&session, options, stop](const Layout& layout, Bars& bars) -> std::string {
    PrintChecked p = print_check_bars(session, layout, bars, options, stop);
    if (!p.ok) return "the print check could not be made: " + p.why;
    bars = std::move(p.bars);
    return {};
  };
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
    json::reject_unknown(doc, {"mode", "model", "output", "linear_deflection", "threads", "layout", "mesh", "demand",
                               "strength_job", "tensor", "file_format", "strengthened"},
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
    // OF5: the file's format, "3mf" or "stl"; not given: 3MF for the tubes route, STL otherwise.
    if (json::find(doc, "file_format")) {
      job.file_format = text(doc, "file_format", "", w);
      if (job.file_format != "3mf" && job.file_format != "stl")
        json::fail(w + ".file_format", "must be \"3mf\" or \"stl\", not \"" + job.file_format + "\"");
    }
    // The stress tensor (Organic, Traced): a file beside the job, by its bare name.
    if (json::find(doc, "strengthened")) {
      job.strengthened = text(doc, "strengthened", "", w);
      if (job.strengthened.empty()) throw FileJobError("\"strengthened\" must name a strengthened.json");
    }
    if (json::find(doc, "tensor")) {
      job.tensor = text(doc, "tensor", "", w);
      if (job.tensor.empty() || job.tensor == "." || job.tensor == ".." ||
          job.tensor.find_first_of("/\\") != std::string::npos)
        json::fail(w + ".tensor", "must be a file name with no folder in it");
    }
    if (const json::Value* v = json::find(doc, "layout")) {
      job.settings = settings_from(json::as_object(*v, w + ".layout"), w + ".layout");
      job.organic = organic_from(*v, job.settings, w + ".layout");
      // K1: the floor lives in the domain (where), so the growth, the path, the net skin, the print check and the
      // file all see it. Q1 (brief G24): a Traced job's weave regions as a Grown job's (the owner, 2026-11-17: "generate
      // a version with the flat floor"); a traced strand that meets it ends in it as in any solid (O4, finish_bar_ends).
      if (job.organic.bed_floor_mm > 0.0) {
        job.settings.bed_floor_mm = job.organic.bed_floor_mm;
        job.settings.bed_up = job.organic.build_dir;
      }
    }
    if (const json::Value* v = json::find(doc, "mesh"))
      job.options = options_from(json::as_object(*v, w + ".mesh"), w + ".mesh");
    job.organic.layer_mm = job.options.layers.layer_mm;   // G1: Grown grows one printed layer per step
    // OP7 (brief C2, E1): the ask's ranges and rules, as the session path checks them (validate_organic); the first
    // refusal is the job's (job_unreadable, as before), its key named in the detail, its plain sentence after it. The
    // stress input is the job's own refusal (no_stress_result), so it is not asked here. With no weave region the
    // organic keys are still held to their ranges (as the parser always did); the thinnest strut is then not Organic's
    // to refuse.
    {
      bool weave = false;
      for (const Settings::RegionAsk& r : job.settings.regions) weave = weave || (r.weave && r.role == Role::Lattice);
      std::vector<OrganicRefusal> refused = validate_organic(job.settings, job.organic, nullptr);
      if (!weave)
        refused.erase(std::remove_if(refused.begin(), refused.end(),
                                     [](const OrganicRefusal& x) { return x.setting == "bead_mm"; }),
                      refused.end());
      if (!refused.empty()) {
        const std::string& k = refused.front().setting;
        const std::string at = k == "layer_mm"                                      ? w + ".mesh.layer_mm"
                               : k == "bead_mm"                                     ? w + ".layout.bead_mm"
                               : (k == "build_dir" || k == "seed_stride") ? w + ".layout"
                                                                                    : w + ".layout.organic_" + k;
        json::fail(at, refused.front().text);
      }
    }
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
      bool any_cells = job.settings.regions.empty();
      for (const Settings::RegionAsk& a : job.settings.regions) any_cells = any_cells || (a.role == Role::Lattice && !a.weave);
      if (any_weave && any_cells) {
        refuse(r, kStrengthMixed,
               "The strength check judges an Organic lattice and a cell lattice in different ways and cannot check a "
               "part that has both, so no file was made. Use one kind in every region, or turn the strength check off.");
        return done();
      }
      if (!strength || !strength->before || !(any_weave ? strength->run_organic : strength->run)) {
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
    // OS16 (brief E4, leg 2): strengthening's additions are replayed with the file's print check before the first
    // round and after each, as the strengthen job made them.
    const FileOptions options = file_options_for(job.options, any_weave);
    OrganicAsk organic = job.organic;
    if (any_weave && !organic.additions.empty()) organic.print_check = print_check_hook(session, options, stop);
    const Outcome out = any_weave ? session.lay_organic(job.settings, *job.tensor_field, organic,
                                                        job.options.threads, stop)
                                  : session.lay(job.settings, job.options.threads, stop);
    if (out.cancelled) {
      refuse(r, kCancelled, "Stopped before the lattice file was finished. Nothing was made.");
      return done();
    }
    if (!out.additions_refused.empty()) {
      refuse(r, kStrengthenedMismatch,
             "The strengthening sent with the lattice job was made on a different lattice than this lay gives, so "
             "nothing was made.",
             out.additions_refused);
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
    r.gap_capped = out.gap_capped;   // OG1, OG2 (brief E6)
    r.gap_broken = out.gap_broken;
    r.tight = out.tight;
    r.relief = out.relief;
    r.guard = out.guard;   // OG5 (brief E9)
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
    // OF4: a job with a weave region takes the tubes route unless it asked for one (file_options_for, above).
    const TriangleMesh mesh = make_file_mesh(session, out, options, r.made, stop);
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
      // OG2c (brief E6, leg C): a refusal says where (x, y, z mm, each finding).
      std::string where = "at";
      for (const Vec3& p : r.made.findings_at) {
        char b[96];
        std::snprintf(b, sizeof b, " (%.2f, %.2f, %.2f)", p.x, p.y, p.z);
        where += b;
      }
      refuse(r, kWouldNotPrint, line, r.made.findings_at.empty() ? std::string() : where);
      return done();
    }

    say(said, "saving the file");
    t0 = std::chrono::steady_clock::now();
    // Written beside its target and moved in only when whole: a failed job never leaves
    // half a file, nor replaces an earlier good one.
    // OF5: the format. "3mf" (default for the tubes route): ONE object of the solid and every shell, shared vertices,
    // deflated where this build has zlib; written in place of a ".stl" name as ".3mf". "stl" (default otherwise): as
    // before, byte for byte.
    r.file_format = !job.file_format.empty() ? job.file_format : r.made.tubes ? "3mf" : "stl";
    r.weave_mesh = r.made.tubes ? "tubes" : "merged";
    std::string file_path = stl_path;
    if (r.file_format == "3mf" && file_path.size() >= 4 && file_path.compare(file_path.size() - 4, 4, ".stl") == 0)
      file_path.replace(file_path.size() - 4, 4, ".3mf");
    const std::string part = file_path + ".part";
    std::size_t want = 84 + 50 * mesh.triangles.size();
    bool written = false;
    std::string write_detail;
    try {
      if (r.file_format == "3mf") {
        StreamingThreeMfWriter::Options o;
        o.indexed = true;
        o.deflate = true;
        StreamingThreeMfWriter w(part, o);
        for (const Vec3& v : mesh.vertices) w.add_vertex(v);
        for (const auto& t : mesh.triangles)
          w.add_indexed(static_cast<std::uint64_t>(t[0]), static_cast<std::uint64_t>(t[1]), static_cast<std::uint64_t>(t[2]));
        w.finish();
        r.compressed = w.compressed();
        want = size_of_file(part);
        written = want > 0 && w.triangle_count() == mesh.triangles.size();
        if (!written) write_detail = "the 3MF file came out empty";
      } else {
        write_stl_file(part, mesh, StlFormat::Binary);
        written = size_of_file(part) == want;
        if (!written) write_detail = "the file is not the size its triangles need";
      }
    } catch (const std::exception& e) {
      write_detail = e.what();
    }
    if (written && std::rename(part.c_str(), file_path.c_str()) != 0) {
      written = false;
      write_detail = "cannot move the file into " + file_path;
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
      // Brief E2, item 7: Organic is checked on the FINAL bars, as the file holds them.
      std::vector<char> kept;
      if (any_weave) {
        const Bars& made = r.made.sagged ? *r.made.sagged : out.bars;
        kept = bars_in_file(made, r.made, weave_regions, options);
        ask.bars = &made;
        ask.kept = &kept;
        ask.light_width_mm = job.organic.width_mm > 0.0
                                 ? job.organic.width_mm
                                 : session.domain()->spec().bead_mm * session.domain()->spec().min_strut_lines;
      }
      StrengthDone sd;
      try {
        sd = any_weave ? strength->run_organic(ask) : strength->run(ask);
      } catch (const std::exception& e) {
        sd = StrengthDone{};
        sd.code = "strength_failed";
        sd.why = "The lattice's strength could not be checked, so no file was made.";
        sd.detail = e.what();
      }
      r.ms_strength = ms_since(t0);
      if (!sd.ok) {
        std::remove(file_path.c_str());
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
    r.file = file_path;
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

// Brief E2: what run_file_job reads before it makes anything (the job, its stress files, its "strengthened", the
// part), so the strengthen job reads a job exactly as the file job does. Not ok: `r` holds the refusal.
bool load_file_job(const std::string& job_path, int threads, FileJob& job, StepModel& model, FileResult& r,
                   void (*said)(const char*)) {
  const auto run = [&]() -> bool {
    {
      std::ifstream f(job_path, std::ios::binary);
      if (!f) {
        refuse(r, kJobUnreadable, "The lattice job could not be opened on the Mac, so nothing was made.",
               "cannot open " + job_path);
        return false;
      }
      std::ostringstream all;
      all << f.rdbuf();
      try {
        job = parse_file_job(all.str());
      } catch (const std::exception& e) {
        refuse(r, kJobUnreadable,
               "The lattice job sent to the Mac could not be read, so nothing was made.", e.what());
        return false;
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
        return false;
      }
      job.settings.stress.demand = std::move(field);
    }
    if (!job.tensor.empty()) {
      auto field = std::make_shared<TensorField>();
      std::string why;
      if (!read_tensor_file(folder_of(job_path) + "/" + job.tensor, *field, &why)) {
        refuse(r, kTensorUnreadable,
               "The stress tensor sent with the lattice job could not be read, so nothing was made.", why);
        return false;
      }
      job.tensor_field = std::move(field);
    }
    // Brief E2, item 11: a strengthen round's stress input, reference and floors in place of the job's own.
    if (!job.strengthened.empty()) {
      const std::string sp = job.strengthened[0] == '/' ? job.strengthened : folder_of(job_path) + "/" + job.strengthened;
      // (version 2, brief E3a: the job's own stress stays; version 1 replaces it)
      auto field = job.tensor_field ? std::make_shared<TensorField>(*job.tensor_field) : std::make_shared<TensorField>();
      std::string why;
      if (!apply_strengthened(sp, *field, job.organic, &why)) {
        refuse(r, kStrengthenedUnreadable,
               "The strengthened stress sent with the lattice job could not be read, so nothing was made.", why);
        return false;
      }
      job.tensor_field = std::move(field);
    }
    const std::string model_path =
        !job.model.empty() && job.model[0] == '/' ? job.model : folder_of(job_path) + "/" + job.model;
    say(said, "opening the part");
    const auto t0 = std::chrono::steady_clock::now();
    try {
      StepTessellation tess;
      if (job.linear_deflection > 0.0) tess.linear_deflection = job.linear_deflection;
      model = import_part_file_resolved(model_path, tess);
    } catch (const std::exception& e) {
      refuse(r, kModelUnreadable,
             "The part's file could not be opened on the Mac, so no lattice file was made.", e.what());
      return false;
    } catch (...) {
      refuse(r, kModelUnreadable,
             "The part's file could not be opened on the Mac, so no lattice file was made.");
      return false;
    }
    r.ms_import = ms_since(t0);
    return true;
  };
  return run();
}

FileResult run_file_job(const std::string& job_path, const std::string& out_dir, int threads,
                        void (*said)(const char*), const StrengthCheck* strength) {
  FileResult r;
  const auto t_all = std::chrono::steady_clock::now();
  const auto run = [&] {
    FileJob job;
    StepModel model;
    if (!load_file_job(job_path, threads, job, model, r, said)) return;
    const double ms_import = r.ms_import;
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
  if (r.weave_regions > 0 && !r.file_format.empty()) {   // OF5: only for a job with a weave region that made its file
    std::snprintf(b, sizeof b,
                  "  \"file_format\": \"%s\", \"weave_mesh\": \"%s\", \"shells\": %llu, \"shells_left_out\": %llu, "
                  "\"compressed\": %s, \"slicer_supports\": \"off\",\n",
                  r.file_format.c_str(), r.weave_mesh.c_str(), count(r.made.shells.shells()), count(r.made.shells.left_out),
                  r.compressed ? "true" : "false");
    o += b;
  }
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
  if (r.weave_regions > 0) {   // Organic: written only for a job with a weave region (a cube-lattice result is the
                               // released engine's, byte for byte)
    std::snprintf(b, sizeof b, "    \"weave_regions\": %llu, \"strands\": %llu, \"weave_bars\": %llu,\n",
                  count(r.weave_regions), count(r.strands), count(r.weave_bars));
    o += b;
  }
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
    {   // OG2c (brief E6, leg C)
      std::snprintf(b, sizeof b, "],\n    \"relief_flushed\": %llu, \"relief_rounds\": %d, \"findings_at\": [",
                    count(r.made.relief_flushed), r.made.relief_rounds);
      o += b;
      for (std::size_t i = 0; i < r.made.findings_at.size(); ++i) {
        const Vec3& p = r.made.findings_at[i];
        std::snprintf(b, sizeof b, "%s[%.4f, %.4f, %.4f]", i ? ", " : "", p.x, p.y, p.z);
        o += b;
      }
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
  if (r.weave_regions > 0) {
    // Organic, Traced: the trace's time and the shallow-bar table (ShallowTable). Only for a job with a weave region.
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
    {   // O10
      std::snprintf(b, sizeof b, ",\n    \"weave_specks_ignored\": %llu, \"weave_held_ignored\": %llu",
                    count(r.made.weave_specks_ignored), count(r.made.weave_held_ignored));
      o += b;
      std::snprintf(b, sizeof b, ", \"part_overhangs\": %llu", count(r.made.part_overhangs));
      o += b;
      // O17, O18: what was done with the weave's sags.
      std::snprintf(b, sizeof b,
                    ",\n    \"sags_lifted\": %llu, \"sag_lift_largest_mm\": %.9g, \"sag_legs\": %llu, \"sag_legs_mm\": %.9g, "
                    "\"sags_unsupported\": %llu",
                    count(r.made.sags.lifted), r.made.sags.lift_largest_mm, count(r.made.sags.legs), r.made.sags.legs_mm,
                    count(r.made.sags.unsupported));
      o += b;
      {   // OG5 (brief E9): what the guard pass cut or removed (no bar outside the part or through protected solid)
        const auto places = [&](const std::vector<Vec3>& v) {
          std::string t;
          char q[96];
          for (const Vec3& p : v) {
            std::snprintf(q, sizeof q, "%s[%.9g, %.9g, %.9g]", t.empty() ? "" : ", ", p.x, p.y, p.z);
            t += q;
          }
          return t;
        };
        std::snprintf(b, sizeof b, ",\n    \"guard\": {\"ends_moved_in\": %llu, \"outside_cut\": %llu, \"in_solid_cut\": %llu, "
                      "\"in_solid_removed\": %llu, \"by_kind\": {", count(r.guard.ends_moved_in), count(r.guard.outside_cut),
                      count(r.guard.in_solid_cut), count(r.guard.in_solid_removed));
        o += b;
        bool first = true;
        for (const auto& [k, v] : r.guard.by_kind) {
          o += std::string(first ? "" : ", ") + "\"" + k + "\": " + std::to_string(v);
          first = false;
        }
        o += "}, \"outside_at\": [" + places(r.guard.outside_at) + "], \"in_solid_at\": [" + places(r.guard.in_solid_at) +
             "], \"removed_at\": [" + places(r.guard.removed_at) + "]}";
      }
      // OG1 (brief E6): the gap rule and its diagnosis; OG2: the relief, and the tubes' proud ends.
      const Outcome::Tight& tt = r.tight;
      std::snprintf(b, sizeof b,
                    ",\n    \"gap\": {\"capped_points\": %llu, \"broken\": %llu},"
                    "\n    \"tight\": {\"line_mm\": %.9g, \"bars\": %llu, \"tight\": %llu, \"by\": {\"stress\": %llu, "
                    "\"shape\": %llu, \"hold\": %llu, \"floor\": %llu, \"uniform\": %llu, \"unknown\": %llu}, "
                    "\"supports\": %llu, \"links\": %llu, \"braces\": %llu}",
                    count(r.gap_capped), count(r.gap_broken), tt.line_mm, count(tt.bars), count(tt.tight), count(tt.stress),
                    count(tt.shape), count(tt.hold), count(tt.floor), count(tt.uniform), count(tt.unknown),
                    count(tt.supports), count(tt.links), count(tt.braces));
      o += b;
      const Outcome::Relief& rl = r.relief;
      std::snprintf(b, sizeof b,
                    ",\n    \"relief\": {\"surface_ends\": %llu, \"proud\": %llu, \"largest_mm\": %.9g, \"flush\": "
                    "{\"excluded_face\": %llu, \"down_facing\": %llu, \"near_bed\": %llu, \"along_surface\": %llu}, "
                    "\"faces_known\": %s, \"box_grew_mm\": {\"-x\": %.9g, \"+x\": %.9g, \"-y\": %.9g, \"+y\": %.9g, "
                    "\"-z\": %.9g, \"+z\": %.9g},\n      \"tube_proud_ends\": %llu, \"tube_proud_vertices\": %llu, "
                    "\"tube_proud_outside_mm\": %.9g,\n      \"along\": %llu, \"along_largest_mm\": %.9g, \"tube_along_bars\": %llu, "
                    "\"tube_along_vertices\": %llu, \"tube_along_outside_mm\": %.9g, \"file_box_grew_mm\": {\"-x\": %.9g, "
                    "\"+x\": %.9g, \"-y\": %.9g, \"+y\": %.9g, \"-z\": %.9g, \"+z\": %.9g}}",
                    count(rl.surface_ends), count(rl.proud), rl.largest_mm, count(rl.flush_excluded), count(rl.flush_down),
                    count(rl.flush_bed), count(rl.flush_along), rl.faces_known ? "true" : "false", rl.grew_mm[0],
                    rl.grew_mm[1], rl.grew_mm[2], rl.grew_mm[3], rl.grew_mm[4], rl.grew_mm[5],
                    count(r.made.shells.proud_ends), count(r.made.shells.proud_vertices), r.made.shells.proud_outside_mm,
                    count(rl.along), rl.along_largest_mm, count(r.made.shells.along_bars), count(r.made.shells.along_vertices),
                    r.made.shells.along_outside_mm, r.made.shells.grew_mm[0], r.made.shells.grew_mm[1], r.made.shells.grew_mm[2],
                    r.made.shells.grew_mm[3], r.made.shells.grew_mm[4], r.made.shells.grew_mm[5]);
      o += b;
    }
    o += "},\n";
  }
  if (r.grown) {
    // G12: written only for Grown, so a Traced file's result is as it was.
    const GrowReport& g = *r.grown;
    std::string wt;   // M: per area, the wall roots by third of the stress, kept with rule M off and as run
    if (!g.wall_thirds.empty()) {
      wt = "\"wall_thirds\": [";
      for (std::size_t i = 0; i < g.wall_thirds.size(); ++i) {
        const GrowReport::WallThirds& x = g.wall_thirds[i];
        char tb[320];
        std::snprintf(tb, sizeof tb,
                      "%s{\"area\": %d, \"roots\": [%llu, %llu, %llu], \"kept_off\": [%llu, %llu, %llu], "
                      "\"kept_on\": [%llu, %llu, %llu]}",
                      i ? ", " : "", x.region, count(x.roots[0]), count(x.roots[1]), count(x.roots[2]),
                      count(x.kept_off[0]), count(x.kept_off[1]), count(x.kept_off[2]), count(x.kept_on[0]),
                      count(x.kept_on[1]), count(x.kept_on[2]));
        wt += tb;
      }
      wt += "],\n    ";
    }
    if (!g.cross_thirds.empty()) {   // N: the crossing vines (seeded, grown), and per area those chosen by third
      char cb[160];
      std::snprintf(cb, sizeof cb, "\"cross_seeded\": %llu, \"cross_grown\": %llu, \"cross_thirds\": [",
                    count(g.cross_seeded), count(g.cross_grown));
      wt += cb;
      for (std::size_t i = 0; i < g.cross_thirds.size(); ++i) {
        const GrowReport::CrossThirds& x = g.cross_thirds[i];
        char tb[200];
        std::snprintf(tb, sizeof tb, "%s{\"area\": %d, \"seeded\": [%llu, %llu, %llu], \"total\": %llu}",
                      i ? ", " : "", x.region, count(x.seeded[0]), count(x.seeded[1]), count(x.seeded[2]),
                      count(x.total));
        wt += tb;
      }
      wt += "],\n    ";
      // O: the crossing vines' level reach (median, largest, mm) and how they ended.
      std::vector<double> reach = g.cross_reach_mm;
      std::sort(reach.begin(), reach.end());
      const std::size_t nr = reach.size();
      const double med = nr == 0 ? 0.0 : nr % 2 ? reach[nr / 2] : 0.5 * (reach[nr / 2 - 1] + reach[nr / 2]);
      const double big = nr == 0 ? 0.0 : reach.back();
      char rb[400];
      std::snprintf(rb, sizeof rb,
                    "\"cross_reach_median_mm\": %.9g, \"cross_reach_max_mm\": %.9g, \"cross_ended_side\": %llu, "
                    "\"cross_ended_top\": %llu, \"cross_ended_noface\": %llu, \"cross_ended_unsupported\": %llu, "
                    "\"cross_ended_guard\": %llu,\n    ",
                    med, big, count(g.cross_ended_side), count(g.cross_ended_top), count(g.cross_ended_noface),
                    count(g.cross_ended_unsupported), count(g.cross_ended_guard));
      wt += rb;
    }
    if (g.tie_level) {   // P: the level ties
      std::vector<std::size_t> jn = g.tie_level_joints;
      std::sort(jn.begin(), jn.end());
      std::vector<double> sp = g.tie_level_span_mm;
      std::sort(sp.begin(), sp.end());
      const std::size_t nj = jn.size(), ns = sp.size();
      const double jmed = nj == 0 ? 0.0 : nj % 2 ? static_cast<double>(jn[nj / 2])
                                                 : 0.5 * static_cast<double>(jn[nj / 2 - 1] + jn[nj / 2]);
      const double smed = ns == 0 ? 0.0 : ns % 2 ? sp[ns / 2] : 0.5 * (sp[ns / 2 - 1] + sp[ns / 2]);
      const double sbig = ns == 0 ? 0.0 : sp.back();
      char lb[600];
      std::snprintf(lb, sizeof lb,
                    "\"ties_level_refused_steep\": %llu, \"ties_level_cut_span\": %llu, \"tie_level_laid\": %llu, "
                    "\"tie_level_joints_median\": %.9g, \"tie_level_span_median_mm\": %.9g, "
                    "\"tie_level_span_max_mm\": %.9g, \"tie_level_dz_max_mm\": %.9g, "
                    "\"tie_level_dz_max_unsnapped_mm\": %.9g,\n    ",
                    count(g.ties_level_refused_steep), count(g.ties_level_cut_span), count(nj), jmed, smed, sbig,
                    g.tie_level_dz_max_mm, g.tie_level_dz_max_unsnapped_mm);
      wt += lb;
    }
    std::vector<char> gbuf(4096 + wt.size());   // O: room for the per-area counts, however many areas
    char* gb = gbuf.data();
    std::snprintf(gb, gbuf.size(),
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
                  "%s\"ms\": %.1f},\n",
                  count(g.strands), g.grown_mm, g.kept_mm, g.cut_outside_mm, g.cut_unsupported_mm, g.cut_nothing_mm,
                  g.cut_repeat_mm, count(g.seeds_floor), count(g.seeds_wall), count(g.seeds_refused_support),
                  count(g.strands_grown), count(g.steps), count(g.clamped), count(g.tips), count(g.tip_budget_hit),
                  count(g.ended_edge), count(g.ended_unsupported), count(g.ended_joins), count(g.joins),
                  count(g.grew_on_after_join), count(g.joins_refused_span), count(g.branches_offered),
                  count(g.branches_grown), count(g.links), count(g.refused_region), count(g.refused_support),
                  count(g.refused_crowded), g.bare_before, g.bare_after, count(g.reseed_voids), count(g.reseed_landed),
                  count(g.reseed_failed), g.reseed_mm, count(g.ties_seeded), count(g.ties_laid),
                  count(g.ties_refused_minor), count(g.ties_refused_reach), wt.c_str(), g.ms);
    o += gb;
  }
  std::snprintf(b, sizeof b,
                "  \"ms\": {\"import\": %.1f, \"measure\": %.1f, \"read\": %.1f, \"cells\": %.1f, "
                "\"bars\": %.1f, \"open_space\": %.1f, \"carve\": %.1f, \"struts\": %.1f, \"solid\": %.1f, "
                "\"finish\": %.1f, \"write\": %.1f, \"total\": %.1f",
                r.ms_import, r.ms_measure, r.ms_read, r.ms_cells, r.ms_bars, r.made.ms_open_space, r.made.ms_carve,
                m.ms_struts, m.ms_solid, m.ms_finish, r.ms_write, r.ms_total);
  o += b;
  if (r.made.tubes) {   // OF4: every pass of the tubes route (written only on that route: a cube job's result unchanged)
    o += ", \"passes\": [";
    for (std::size_t i = 0; i < r.made.pass_ms.size(); ++i) {
      const PrintableReport::PassTime& p = r.made.pass_ms[i];
      std::snprintf(b, sizeof b, "%s{\"shells\": %.1f, \"layers\": %.1f, \"solid\": %.1f}", i ? ", " : "", p.shells_ms,
                    p.layers_ms, p.solid_ms);
      o += b;
    }
    o += "]";
  }
  o += "}\n";
  o += "}\n";
  return o;
}

}  // namespace topopt::lattice_layout
