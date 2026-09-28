#include "topopt/flexible/data.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <initializer_list>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "json.hpp"

namespace topopt {
namespace flexible {
namespace {

using json::Value;

std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw FlexibleError("cannot open " + path);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

std::string fmt(double v) {
  char b[40];
  std::snprintf(b, sizeof(b), "%g", v);
  return b;
}

MaybeNumber maybe_number(const Value& v, const std::string& where) {
  MaybeNumber m;
  if (v.is_null()) return m;
  m.known = true;
  m.value = json::as_number(v, where);
  return m;
}

// null | [lo, hi] (lo <= hi). With `scalar_ok`, a bare number reads as [v, v].
MaybeRange maybe_range(const Value& v, const std::string& where, bool scalar_ok) {
  MaybeRange r;
  if (v.is_null()) return r;
  if (scalar_ok && v.is_number()) {
    r.known = true;
    r.lo = r.hi = json::as_number(v, where);
    return r;
  }
  if (!v.is_array() || v.arr.size() != 2)
    json::fail(where, scalar_ok ? "must be null, a number or a [lo, hi] pair"
                                : "must be null or a [lo, hi] pair");
  r.known = true;
  r.lo = json::as_number(v.arr[0], where + "[0]");
  r.hi = json::as_number(v.arr[1], where + "[1]");
  if (r.lo > r.hi) json::fail(where, "lo " + fmt(r.lo) + " > hi " + fmt(r.hi));
  return r;
}

std::vector<std::string> string_array(const Value& v, const std::string& where) {
  std::vector<std::string> out;
  for (std::size_t i = 0; i < json::as_array(v, where).arr.size(); ++i)
    out.push_back(json::as_string(v.arr[i], where + "[" + std::to_string(i) + "]"));
  return out;
}

// {"190": 110, ...}: keys are temperatures written as strings.
std::map<double, double> temp_map(const Value& v, const std::string& where) {
  std::map<double, double> out;
  json::as_object(v, where);
  for (const auto& kv : v.obj) {
    if (json::is_comment_key(kv.first)) continue;
    char* end = nullptr;
    const double t = std::strtod(kv.first.c_str(), &end);
    if (kv.first.empty() || end == nullptr || *end != '\0' || !std::isfinite(t))
      json::fail(where, "key \"" + kv.first + "\" is not a temperature");
    out[t] = json::as_number(kv.second, where + "." + kv.first);
  }
  return out;
}

// The fifteen keys every filament carries (required even when their value is null:
// "not stated" and "stated as unknown" are different claims) and the documented
// optional ones.
const std::vector<std::string> kMaterialRequired = {
    "display_name", "family", "shore_a_nominal", "foaming", "tier",
    "nozzle_temp_range_c", "bed_temp_c", "speed_mm_s", "retraction", "drying",
    "ams_compatible", "solid_density_g_cm3", "solid_youngs_modulus_mpa",
    "squish_tables", "sources"};
const std::vector<std::string> kMaterialOptional = {
    "shore_d_nominal", "offered_nozzle_temps_c", "offered_temps_note",
    "flow_pct_at_temp", "hardness_by_temp_shore_a", "hardness_range_shore_a",
    "max_volumetric_flow_mm3_s", "nozzle_temp_note", "hardness_note", "flow_note",
    "note", "storage", "hyperelastic_constants"};

Material parse_material(const std::string& id, const Value& m,
                        const std::map<std::string, std::string>& tiers) {
  const std::string w = "flexible_materials.json: material \"" + id + "\"";
  json::as_object(m, w);
  std::vector<std::string> allowed = kMaterialRequired;
  allowed.insert(allowed.end(), kMaterialOptional.begin(), kMaterialOptional.end());
  json::reject_unknown(m, allowed, w);
  json::require_all(m, kMaterialRequired, w);
  auto key = [&](const char* k) { return w + "." + k; };

  Material out;
  out.id = id;
  out.display_name = json::as_string(*json::find(m, "display_name"), key("display_name"));
  out.family = json::as_string(*json::find(m, "family"), key("family"));
  out.shore_a_nominal = maybe_number(*json::find(m, "shore_a_nominal"), key("shore_a_nominal"));
  out.foaming = json::as_bool(*json::find(m, "foaming"), key("foaming"));
  out.tier = json::as_string(*json::find(m, "tier"), key("tier"));
  if (tiers.find(out.tier) == tiers.end())
    json::fail(key("tier"), "\"" + out.tier + "\" is not one of the tiers the file defines");
  out.nozzle_temp_range_c =
      maybe_range(*json::find(m, "nozzle_temp_range_c"), key("nozzle_temp_range_c"), false);
  out.bed_temp_c = maybe_range(*json::find(m, "bed_temp_c"), key("bed_temp_c"), false);
  out.speed_mm_s = maybe_range(*json::find(m, "speed_mm_s"), key("speed_mm_s"), false);
  {
    const Value& r = *json::find(m, "retraction");
    if (!r.is_null()) {
      out.retraction_known = true;
      out.retraction = json::as_string(r, key("retraction"));
    }
  }
  {
    const Value& d = *json::find(m, "drying");
    if (!d.is_null()) {
      const std::string dw = key("drying");
      json::as_object(d, dw);
      json::reject_unknown(d, {"temp_c", "hours", "hours_min", "method"}, dw);
      out.drying.known = true;
      out.drying.temp_c = maybe_range(json::require(d, "temp_c", dw), dw + ".temp_c", true);
      if (const Value* h = json::find(d, "hours"))
        out.drying.hours = maybe_range(*h, dw + ".hours", true);
      if (const Value* h = json::find(d, "hours_min"))
        out.drying.hours_min = maybe_number(*h, dw + ".hours_min");
      if (const Value* s = json::find(d, "method"))
        out.drying.method = json::as_string(*s, dw + ".method");
    }
  }
  {
    const Value& a = *json::find(m, "ams_compatible");
    if (!a.is_null()) {
      out.ams_compatible_known = true;
      out.ams_compatible = json::as_bool(a, key("ams_compatible"));
    }
  }
  out.solid_density_g_cm3 =
      maybe_number(*json::find(m, "solid_density_g_cm3"), key("solid_density_g_cm3"));
  {
    const Value& e = *json::find(m, "solid_youngs_modulus_mpa");
    if (!e.is_null()) {
      const std::string ew = key("solid_youngs_modulus_mpa");
      json::as_object(e, ew);
      json::reject_unknown(e, {"value", "condition"}, ew);
      out.solid_youngs_modulus_mpa.known = true;
      out.solid_youngs_modulus_mpa.value_mpa =
          json::as_number(json::require(e, "value", ew), ew + ".value");
      out.solid_youngs_modulus_mpa.condition =
          json::as_string(json::require(e, "condition", ew), ew + ".condition");
    }
  }
  out.squish_tables = string_array(*json::find(m, "squish_tables"), key("squish_tables"));
  out.sources = string_array(*json::find(m, "sources"), key("sources"));

  if (const Value* v = json::find(m, "shore_d_nominal"))
    out.shore_d_nominal = maybe_number(*v, key("shore_d_nominal"));
  if (const Value* v = json::find(m, "offered_nozzle_temps_c")) {
    const std::string ow = key("offered_nozzle_temps_c");
    json::as_array(*v, ow);
    if (v->arr.empty()) json::fail(ow, "must list at least one temperature when present");
    for (std::size_t i = 0; i < v->arr.size(); ++i) {
      const double t = json::as_number(v->arr[i], ow + "[" + std::to_string(i) + "]");
      if (!out.offered_nozzle_temps_c.empty() && !(t > out.offered_nozzle_temps_c.back()))
        json::fail(ow, "must be strictly increasing");
      out.offered_nozzle_temps_c.push_back(t);
    }
  }
  auto opt_string = [&](const char* k, std::string& dst) {
    if (const Value* v = json::find(m, k)) dst = json::as_string(*v, key(k));
  };
  opt_string("offered_temps_note", out.offered_temps_note);
  opt_string("nozzle_temp_note", out.nozzle_temp_note);
  opt_string("hardness_note", out.hardness_note);
  opt_string("flow_note", out.flow_note);
  opt_string("note", out.note);
  opt_string("storage", out.storage);
  opt_string("hyperelastic_constants", out.hyperelastic_constants);
  if (const Value* v = json::find(m, "flow_pct_at_temp"))
    out.flow_pct_at_temp = temp_map(*v, key("flow_pct_at_temp"));
  if (const Value* v = json::find(m, "hardness_by_temp_shore_a"))
    out.hardness_by_temp_shore_a = temp_map(*v, key("hardness_by_temp_shore_a"));
  if (const Value* v = json::find(m, "hardness_range_shore_a"))
    out.hardness_range_shore_a = maybe_range(*v, key("hardness_range_shore_a"), false);
  if (const Value* v = json::find(m, "max_volumetric_flow_mm3_s"))
    out.max_volumetric_flow_mm3_s = maybe_number(*v, key("max_volumetric_flow_mm3_s"));

  // A literature filament must say where its numbers come from, and a FOAMING one
  // must say which temperatures may be picked — otherwise every temperature would
  // be refused and the tier would be a lie.
  if (out.tier == "literature" && out.squish_tables.empty())
    json::fail(w, "a literature-tier filament must name at least one squish table");
  if (out.tier == "literature" && out.foaming && out.offered_nozzle_temps_c.empty())
    json::fail(w, "a foaming literature-tier filament must state offered_nozzle_temps_c "
                  "(R10: tested temperatures only)");
  return out;
}

double band_value(const Value& obj, const char* k, const std::string& where) {
  const double v = json::as_number(json::require(obj, k, where), where + "." + k);
  if (!(v > 0.0) || v >= 1.0)
    json::fail(where + "." + k, "must be a fraction in (0, 1) (got " + fmt(v) + ")");
  return v;
}

std::vector<CurvePoint> curve_points(const Value& v, const std::string& where) {
  std::vector<CurvePoint> out;
  json::as_array(v, where);
  for (std::size_t i = 0; i < v.arr.size(); ++i) {
    const std::string pw = where + "[" + std::to_string(i) + "]";
    const Value& p = v.arr[i];
    if (!p.is_array() || p.arr.size() != 2)
      json::fail(pw, "must be a [strain, stress] pair");
    CurvePoint c;
    c.strain = json::as_number(p.arr[0], pw + "[0]");
    c.stress_mpa = json::as_number(p.arr[1], pw + "[1]");
    out.push_back(c);
  }
  return out;
}

CurveEntry parse_entry(const Value& e, const std::string& table, std::size_t index) {
  std::string w = table + ": entries[" + std::to_string(index) + "]";
  json::as_object(e, w);
  if (const Value* id = json::find(e, "id"))
    if (id->is_string()) w = table + ": entry \"" + id->str + "\"";
  json::reject_unknown(
      e, {"id", "tier", "material_id", "nozzle_temp_c", "flow_pct", "topology",
          "geometry_source", "beads_per_wall", "bead_width_mm", "relative_density",
          "cell_mm", "specimen", "conditioning", "loading", "unloading",
          "strain_max_measured", "replicates", "rel_sd", "source",
          "relative_density_basis", "est_core_relative_density"},
      w);
  json::require_all(e, {"id", "tier", "material_id", "nozzle_temp_c", "topology",
                        "geometry_source", "relative_density", "specimen",
                        "conditioning", "loading", "strain_max_measured", "source",
                        "relative_density_basis"},
                    w);
  auto key = [&](const char* k) { return w + "." + k; };
  auto one_of = [&](const char* k, std::initializer_list<const char*> allowed) {
    const std::string s = json::as_string(*json::find(e, k), key(k));
    for (const char* a : allowed)
      if (s == a) return s;
    json::fail(key(k), "\"" + s + "\" is not an allowed value");
  };

  CurveEntry out;
  out.table = table;
  out.id = json::as_string(*json::find(e, "id"), key("id"));
  if (out.id.empty()) json::fail(key("id"), "must not be empty");
  out.tier = one_of("tier", {"literature", "calibrated", "proxy"});
  out.material_id = json::as_string(*json::find(e, "material_id"), key("material_id"));
  out.nozzle_temp_c = json::as_number(*json::find(e, "nozzle_temp_c"), key("nozzle_temp_c"));
  if (const Value* v = json::find(e, "flow_pct")) out.flow_pct = maybe_number(*v, key("flow_pct"));
  out.topology = one_of("topology", {"gyroid", "honeycomb"});
  out.geometry_source = one_of("geometry_source", {"slicer_infill", "generated_mesh"});
  if (const Value* v = json::find(e, "beads_per_wall")) {
    out.beads_per_wall = maybe_number(*v, key("beads_per_wall"));
    if (out.beads_per_wall.known &&
        (out.beads_per_wall.value != 1.0 && out.beads_per_wall.value != 2.0))
      json::fail(key("beads_per_wall"), "must be null, 1 or 2");
  }
  if (const Value* v = json::find(e, "bead_width_mm"))
    out.bead_width_mm = maybe_number(*v, key("bead_width_mm"));
  out.relative_density =
      json::as_number(*json::find(e, "relative_density"), key("relative_density"));
  if (!(out.relative_density > 0.0) || out.relative_density > 1.0)
    json::fail(key("relative_density"),
               "must lie in (0, 1] (got " + fmt(out.relative_density) + ")");
  out.relative_density_basis = one_of(
      "relative_density_basis", {"nominal_infill", "estimated_core", "measured_core", "designed"});
  if (const Value* v = json::find(e, "est_core_relative_density")) {
    out.est_core_relative_density = maybe_number(*v, key("est_core_relative_density"));
    if (out.est_core_relative_density.known &&
        (!(out.est_core_relative_density.value > 0.0) ||
         out.est_core_relative_density.value > 1.0))
      json::fail(key("est_core_relative_density"), "must lie in (0, 1]");
  }
  if (const Value* v = json::find(e, "cell_mm")) out.cell_mm = maybe_number(*v, key("cell_mm"));

  {
    const std::string sw = key("specimen");
    const Value& s = json::as_object(*json::find(e, "specimen"), sw);
    json::reject_unknown(s, {"shape", "diameter_mm", "width_mm", "depth_mm", "height_mm",
                             "skin_total_mm", "side_skin", "cells_across",
                             "mass_density_g_cm3"},
                         sw);
    json::require_all(s, {"shape", "height_mm", "skin_total_mm"}, sw);
    out.specimen.shape = json::as_string(*json::find(s, "shape"), sw + ".shape");
    if (out.specimen.shape != "cylinder" && out.specimen.shape != "block")
      json::fail(sw + ".shape", "must be \"cylinder\" or \"block\"");
    if (const Value* v = json::find(s, "diameter_mm"))
      out.specimen.diameter_mm = maybe_number(*v, sw + ".diameter_mm");
    if (const Value* v = json::find(s, "width_mm"))
      out.specimen.width_mm = maybe_number(*v, sw + ".width_mm");
    if (const Value* v = json::find(s, "depth_mm"))
      out.specimen.depth_mm = maybe_number(*v, sw + ".depth_mm");
    out.specimen.height_mm = json::as_number(*json::find(s, "height_mm"), sw + ".height_mm");
    out.specimen.skin_total_mm =
        json::as_number(*json::find(s, "skin_total_mm"), sw + ".skin_total_mm");
    if (!(out.specimen.height_mm > 0.0) || out.specimen.skin_total_mm < 0.0 ||
        out.specimen.skin_total_mm >= out.specimen.height_mm)
      json::fail(sw, "needs height_mm > 0 and 0 <= skin_total_mm < height_mm");
    if (const Value* v = json::find(s, "side_skin")) {
      out.specimen.has_side_skin = true;
      out.specimen.side_skin = json::as_bool(*v, sw + ".side_skin");
    }
    if (const Value* v = json::find(s, "cells_across"))
      out.specimen.cells_across = maybe_number(*v, sw + ".cells_across");
    if (const Value* v = json::find(s, "mass_density_g_cm3"))
      out.specimen.mass_density_g_cm3 = maybe_number(*v, sw + ".mass_density_g_cm3");
  }
  {
    const std::string cw = key("conditioning");
    const Value& c = json::as_object(*json::find(e, "conditioning"), cw);
    json::reject_unknown(c, {"cycle_reported", "rate_mm_per_min", "toe_corrected"}, cw);
    json::require_all(c, {"cycle_reported", "rate_mm_per_min"}, cw);
    out.conditioning.cycle_reported =
        json::as_int(*json::find(c, "cycle_reported"), cw + ".cycle_reported");
    if (out.conditioning.cycle_reported < 1) json::fail(cw + ".cycle_reported", "must be >= 1");
    out.conditioning.rate_mm_per_min =
        json::as_number(*json::find(c, "rate_mm_per_min"), cw + ".rate_mm_per_min");
    if (const Value* v = json::find(c, "toe_corrected")) {
      out.conditioning.has_toe_corrected = true;
      out.conditioning.toe_corrected = json::as_bool(*v, cw + ".toe_corrected");
    }
  }

  out.loading = curve_points(*json::find(e, "loading"), key("loading"));
  if (out.loading.size() < 2) json::fail(key("loading"), "needs at least two points");
  // (0, 0) is IMPLIED (02 §3): the first stated point must lie past it, and the
  // curve must climb in both strain and stress, strictly.
  if (!(out.loading[0].strain > 0.0) || !(out.loading[0].stress_mpa > 0.0))
    json::fail(key("loading"), "the first point must have strain > 0 and stress > 0 "
                               "(the origin is implied)");
  for (std::size_t i = 1; i < out.loading.size(); ++i)
    if (!(out.loading[i].strain > out.loading[i - 1].strain) ||
        !(out.loading[i].stress_mpa > out.loading[i - 1].stress_mpa))
      json::fail(key("loading"), "must be strictly increasing in both strain and stress "
                                 "(point " + std::to_string(i) + ")");
  if (const Value* v = json::find(e, "unloading")) {
    if (!v->is_null()) {
      out.has_unloading = true;
      out.unloading = curve_points(*v, key("unloading"));
    }
  }
  out.strain_max_measured =
      json::as_number(*json::find(e, "strain_max_measured"), key("strain_max_measured"));
  if (out.strain_max_measured < out.loading.back().strain)
    json::fail(key("strain_max_measured"),
               fmt(out.strain_max_measured) + " is below the last loading point's strain " +
                   fmt(out.loading.back().strain));
  if (const Value* v = json::find(e, "replicates"))
    out.replicates = maybe_number(*v, key("replicates"));
  if (const Value* v = json::find(e, "rel_sd")) out.rel_sd = maybe_number(*v, key("rel_sd"));
  out.source = json::as_string(*json::find(e, "source"), key("source"));
  return out;
}

}  // namespace

MaterialCatalogue parse_material_catalogue(const std::string& json_text) {
  const std::string w = "flexible_materials.json";
  const Value root = json::parse(json_text, w);
  json::as_object(root, w);
  json::reject_unknown(root, {"schema_version", "status", "tiers", "error_band_defaults",
                              "materials", "excluded_v1"},
                       w);
  json::require_all(root, {"schema_version", "tiers", "error_band_defaults", "materials"}, w);
  MaterialCatalogue c;
  c.schema_version = json::as_int(*json::find(root, "schema_version"), w + ".schema_version");
  if (c.schema_version != 1) json::fail(w + ".schema_version", "must be 1");
  if (const Value* s = json::find(root, "status")) c.status = json::as_string(*s, w + ".status");
  {
    const Value& t = json::as_object(*json::find(root, "tiers"), w + ".tiers");
    json::reject_unknown(t, {"literature", "proxy_candidate", "calibrate_first"}, w + ".tiers");
    for (const auto& kv : t.obj) {
      if (json::is_comment_key(kv.first)) continue;
      c.tiers[kv.first] = json::as_string(kv.second, w + ".tiers." + kv.first);
    }
  }
  {
    const std::string bw = w + ".error_band_defaults";
    const Value& b = json::as_object(*json::find(root, "error_band_defaults"), bw);
    json::reject_unknown(b, {"status", "literature_same_material", "calibrated", "proxy", "note"},
                         bw);
    c.error_bands.literature_same_material = band_value(b, "literature_same_material", bw);
    c.error_bands.calibrated = band_value(b, "calibrated", bw);
    c.error_bands.proxy = band_value(b, "proxy", bw);
    if (const Value* s = json::find(b, "status"))
      c.error_bands.status = json::as_string(*s, bw + ".status");
    if (const Value* s = json::find(b, "note"))
      c.error_bands.note = json::as_string(*s, bw + ".note");
  }
  {
    const Value& ms = json::as_object(*json::find(root, "materials"), w + ".materials");
    for (const auto& kv : ms.obj) {
      if (json::is_comment_key(kv.first)) continue;
      c.materials[kv.first] = parse_material(kv.first, kv.second, c.tiers);
    }
  }
  if (const Value* x = json::find(root, "excluded_v1")) {
    json::as_object(*x, w + ".excluded_v1");
    for (const auto& kv : x->obj) {
      if (json::is_comment_key(kv.first)) continue;
      c.excluded_v1[kv.first] = json::as_string(kv.second, w + ".excluded_v1." + kv.first);
    }
  }
  return c;
}

MaterialCatalogue load_material_catalogue(const std::string& path) {
  return parse_material_catalogue(read_file(path));
}

CurveTable parse_curve_table(const std::string& json_text, const std::string& name) {
  const Value root = json::parse(json_text, name);
  json::as_object(root, name);
  json::reject_unknown(root, {"schema_version", "entries"}, name);
  json::require_all(root, {"schema_version", "entries"}, name);
  CurveTable t;
  t.name = name;
  t.schema_version = json::as_int(*json::find(root, "schema_version"), name + ".schema_version");
  if (t.schema_version != 1) json::fail(name + ".schema_version", "must be 1");
  const Value& es = json::as_array(*json::find(root, "entries"), name + ".entries");
  for (std::size_t i = 0; i < es.arr.size(); ++i) t.entries.push_back(parse_entry(es.arr[i], name, i));
  return t;
}

FlexibleData make_flexible_data(MaterialCatalogue catalogue, std::vector<CurveTable> tables) {
  std::set<std::string> ids;
  for (const CurveTable& t : tables)
    for (const CurveEntry& e : t.entries) {
      if (!ids.insert(e.id).second)
        throw FlexibleError(t.name + ": duplicated entry id \"" + e.id + "\"");
      auto m = catalogue.materials.find(e.material_id);
      if (m == catalogue.materials.end())
        throw FlexibleError(t.name + ": entry \"" + e.id + "\" names material \"" +
                            e.material_id + "\", which flexible_materials.json does not define");
      const std::vector<std::string>& listed = m->second.squish_tables;
      if (std::find(listed.begin(), listed.end(), t.name) == listed.end())
        throw FlexibleError(t.name + ": entry \"" + e.id + "\" is for \"" + e.material_id +
                            "\", whose squish_tables do not list " + t.name);
    }
  FlexibleData d;
  d.catalogue = std::move(catalogue);
  d.tables = std::move(tables);
  return d;
}

FlexibleData load_flexible_data(const std::string& materials_path) {
  MaterialCatalogue c = load_material_catalogue(materials_path);
  std::string dir = ".";
  const std::size_t slash = materials_path.find_last_of('/');
  if (slash != std::string::npos) dir = materials_path.substr(0, slash);
  std::set<std::string> names;
  for (const auto& kv : c.materials)
    for (const std::string& t : kv.second.squish_tables) names.insert(t);
  std::vector<CurveTable> tables;
  for (const std::string& n : names) {
    if (n.find('/') != std::string::npos || n.find("..") != std::string::npos)
      throw FlexibleError("squish table name \"" + n + "\" must be a plain file name");
    tables.push_back(parse_curve_table(read_file(dir + "/flexible_curves/" + n), n));
  }
  return make_flexible_data(std::move(c), std::move(tables));
}

DensityAxis build_density_axis(const FlexibleData& data, const std::string& material_id,
                               const std::string& topology) {
  DensityAxis ax;
  ax.material_id = material_id;
  ax.topology = topology;
  std::set<std::string> bases;
  std::set<double> map_temps;
  for (const CurveTable& t : data.tables)
    for (const CurveEntry& e : t.entries) {
      if (e.material_id != material_id || e.topology != topology) continue;
      bases.insert(e.relative_density_basis);
      if (e.relative_density_basis == "nominal_infill" && e.est_core_relative_density.known) {
        map_temps.insert(e.nozzle_temp_c);
        for (const DensityMapPoint& p : ax.map)
          if (p.nominal == e.relative_density)
            throw FlexibleError("density axis " + material_id + "/" + topology +
                                ": nominal " + fmt(e.relative_density) +
                                " is mapped twice (entry \"" + e.id + "\")");
        ax.map.push_back({e.relative_density, e.est_core_relative_density.value});
      }
    }
  const std::string what = "density axis " + material_id + "/" + topology;
  if (bases.size() > 1)
    throw FlexibleError(what + ": rows mix relative_density bases; one axis needs one basis");
  if (bases.empty()) return ax;  // no rows: the gate in curve_set refuses by topology
  const std::string basis = *bases.begin();
  if (basis != "nominal_infill") {
    // Rows already stated on a core basis are used as stated.
    ax.map.clear();
    ax.density_basis = basis;
    return ax;
  }
  if (map_temps.size() > 1)
    throw FlexibleError(what + ": est_core_relative_density is stated at more than one "
                               "temperature, so there is no single nominal->core map");
  if (ax.map.empty())
    throw FlexibleError(what + ": nominal-infill rows carry no est_core_relative_density, "
                               "so they cannot be placed on the printed-core axis (R2)");
  ax.mapping_temp_c = *map_temps.begin();
  std::sort(ax.map.begin(), ax.map.end(),
            [](const DensityMapPoint& a, const DensityMapPoint& b) { return a.nominal < b.nominal; });
  for (std::size_t i = 1; i < ax.map.size(); ++i)
    if (!(ax.map[i].core > ax.map[i - 1].core))
      throw FlexibleError(what + ": the nominal->core map must be strictly increasing");
  char b[96];
  std::snprintf(b, sizeof(b), "estimated_core (%g \xC2\xB0""C mapping)", ax.mapping_temp_c);
  ax.density_basis = b;
  return ax;
}

double core_density_of(const DensityAxis& axis, const CurveEntry& entry) {
  if (entry.relative_density_basis != "nominal_infill") return entry.relative_density;
  for (const DensityMapPoint& p : axis.map)
    if (p.nominal == entry.relative_density) return p.core;
  throw FlexibleError("entry \"" + entry.id + "\": nominal " + fmt(entry.relative_density) +
                      " is not on the " + axis.material_id + "/" + axis.topology +
                      " nominal->core map; the map is never interpolated");
}

}  // namespace flexible
}  // namespace topopt
