// flexible_bridge.cpp — the Flexible stage's bridge (task 2026-09-29-flexible-screens,
// A1). See FlexibleBridge.hpp. Every function copies a core `topopt::flexible` result
// into POD vectors; none computes a squish number itself (M9, DECISIONS 2026-09-27
// item 4). The one piece of state is the SCENE registry: a part, its grid, mask and
// regions, plus the stacks and designs built on it, so a dragged curve point re-runs
// only the map and the design.

#include "FlexibleBridge.hpp"
#include "flexible_squish_fe.hpp"  // ★ BATCH G: the squish sim's setup (private)

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#include "topopt/face_overrides.hpp"  // import_part_file_resolved
#include "topopt/face_region.hpp"
#include "topopt/flexible/curve.hpp"
#include "topopt/flexible/data.hpp"
#include "topopt/flexible/faces.hpp"
#include "topopt/flexible/field.hpp"
#include "topopt/flexible/job_block.hpp"
#include "topopt/flexible/recommend.hpp"
#include "topopt/flexible/run.hpp"
#include "topopt/flexible/squish.hpp"
#include "topopt/job.hpp"
#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

namespace topoptbridge {
namespace {

namespace fx = topopt::flexible;

void fail(BridgeError& err, const std::exception& e) {
  err.ok = false;
  err.message = e.what();
}

// ── the data, loaded once per path ──────────────────────────────────────────
std::mutex g_data_mu;
std::map<std::string, std::shared_ptr<const fx::FlexibleData>> g_data;

std::shared_ptr<const fx::FlexibleData> data_at(const std::string& path) {
  std::lock_guard<std::mutex> lock(g_data_mu);
  auto it = g_data.find(path);
  if (it != g_data.end()) return it->second;
  auto d = std::make_shared<const fx::FlexibleData>(fx::load_flexible_data(path));
  g_data[path] = d;
  return d;
}

fx::CurveSetResult set_for(const std::string& path, const std::string& material,
                           double temp_c, const std::string& topology) {
  return fx::curve_set(*data_at(path), material, temp_c, topology);
}

fx::StampGrid to_core(const FlexStampGrid& s) {
  fx::StampGrid g;
  g.name = s.name;
  g.origin_u_mm = s.origin_u_mm;
  g.origin_v_mm = s.origin_v_mm;
  g.cell_mm = s.cell_mm;
  g.nu = s.nu;
  g.nv = s.nv;
  g.values_mpa = s.values_mpa;
  g.force_n = s.force_n;
  g.rigid = s.rigid;
  return g;
}

FlexStampGrid from_core(const fx::StampGrid& g) {
  FlexStampGrid s;
  s.present = true;
  s.name = g.name;
  s.origin_u_mm = g.origin_u_mm;
  s.origin_v_mm = g.origin_v_mm;
  s.cell_mm = g.cell_mm;
  s.nu = g.nu;
  s.nv = g.nv;
  s.values_mpa = g.values_mpa;
  s.force_n = g.force_n;
  s.rigid = g.rigid;
  return s;
}

fx::SquishMap to_core(const FlexSquishMap& m) {
  fx::SquishMap s;
  s.mode = m.mode;
  s.x_x = m.x_x;
  s.x_y = m.x_y;
  s.y_x = m.y_x;
  s.y_y = m.y_y;
  s.c_x = m.c_x;
  s.c_y = m.c_y;
  s.deepest_squish_mm = m.deepest_squish_mm;
  return s;
}

fx::BuildParams to_core(const FlexBuild& b) {
  return fx::BuildParams{b.topology, b.beads_per_wall, b.bead_width_mm};
}

void put3(double out[3], const topopt::Vec3& v) {
  out[0] = v.x;
  out[1] = v.y;
  out[2] = v.z;
}

// ── scenes ──────────────────────────────────────────────────────────────────
struct Scene {
  std::mutex mu;
  topopt::JobDescription job;
  topopt::StepModel model;
  topopt::VoxelGrid grid;
  std::vector<char> mask;
  std::vector<topopt::ResolvedFaceRegion> regions;
  topopt::Vec3 build{0, 0, 1};
  long long lattice_voxels = 0;
  // cached per (face region, rotation): they do not change while the user draws
  std::map<std::pair<int, int>, std::unique_ptr<fx::Stack>> stacks;
  // the last design per (face region, rotation), for the field and check mode
  std::map<std::pair<int, int>, std::unique_ptr<fx::FaceDesign>> designs;
  std::map<std::pair<int, int>, std::unique_ptr<fx::TierBand>> tiers;
  // the last assembled field and the key it was assembled for
  std::unique_ptr<fx::DensityField> field;
  std::vector<std::tuple<int, int, const fx::FaceDesign*>> field_key;
  std::string field_build_key;
};

std::mutex g_scene_mu;
std::map<int64_t, std::shared_ptr<Scene>> g_scenes;
int64_t g_next_scene = 1;

std::shared_ptr<Scene> scene_at(int64_t id) {
  std::lock_guard<std::mutex> lock(g_scene_mu);
  auto it = g_scenes.find(id);
  if (it == g_scenes.end()) throw std::invalid_argument("flexible scene " + std::to_string(id) + " is not open");
  return it->second;
}

const topopt::ResolvedFaceRegion& region_of(const Scene& s, int id) {
  for (const auto& r : s.regions)
    if (r.id == id) return r;
  throw std::invalid_argument("face region " + std::to_string(id) + " is not declared in the job");
}

// Caller holds s.mu.
const fx::Stack& stack_of(Scene& s, int face, int rot) {
  auto key = std::make_pair(face, rot);
  auto it = s.stacks.find(key);
  if (it != s.stacks.end()) return *it->second;
  auto st = std::make_unique<fx::Stack>(fx::build_stack(s.model, region_of(s, face), s.regions, s.grid,
                                                        s.mask, rot, s.build, s.grid.spacing));
  const fx::Stack& ref = *st;
  s.stacks[key] = std::move(st);
  return ref;
}

void copy_design(const fx::FaceDesign& d, FlexFaceDesign& o) {
  const std::size_t n = d.columns.size();
  auto sz = [n](auto& v) { v.resize(n); };
  sz(o.s); sz(o.pressure_mpa); sz(o.height_mm); sz(o.target_depth_mm); sz(o.target_strain);
  sz(o.target_density); sz(o.nearest_depth_mm); sz(o.clamped_density); sz(o.clamped_depth_mm);
  sz(o.buildable_density); sz(o.buildable_depth_mm); sz(o.cell_mm); sz(o.sigma_mm); sz(o.status);
  sz(o.target_extrapolated); sz(o.nearest_known); sz(o.buildable_ok); sz(o.buildable_extrapolated);
  for (std::size_t k = 0; k < n; ++k) {
    const fx::ColumnDesign& c = d.columns[k];
    o.s[k] = c.s;
    o.pressure_mpa[k] = c.pressure_mpa;
    o.height_mm[k] = c.height_mm;
    o.target_depth_mm[k] = c.target_depth_mm;
    o.target_strain[k] = c.target_strain;
    o.target_density[k] = c.target_density;
    o.nearest_depth_mm[k] = c.nearest_depth_mm;
    o.clamped_density[k] = c.clamped_density;
    o.clamped_depth_mm[k] = c.clamped_depth_mm;
    o.buildable_density[k] = c.buildable_density;
    o.buildable_depth_mm[k] = c.buildable_depth_mm;
    o.cell_mm[k] = c.cell_mm;
    o.sigma_mm[k] = c.sigma_mm;
    o.status[k] = c.status;
    o.target_extrapolated[k] = c.target_extrapolated ? 1 : 0;
    o.nearest_known[k] = c.nearest_known ? 1 : 0;
    o.buildable_ok[k] = c.buildable_ok ? 1 : 0;
    o.buildable_extrapolated[k] = c.buildable_extrapolated ? 1 : 0;
  }
  o.tier = d.tier.tier;
  o.band = d.tier.band;
  o.tier_why = d.tier.why;
  o.ok = d.ok;
  o.too_firm = d.too_firm;
  o.too_soft = d.too_soft;
  o.beyond_data = d.beyond_data;
  o.no_lattice = d.no_lattice;
  o.solid_under_map = d.solid_under_map;
  o.target_extrapolated_count = d.target_extrapolated;
  o.buildable_extrapolated_count = d.buildable_extrapolated;
  o.buildable_beyond_data = d.buildable_beyond_data;
  o.near_edge = d.near_edge;
  o.design_pressure_even_mpa = d.design_pressure_even_mpa;
  o.design_stamp_used = d.design_stamp_used;
  o.design_stamp_rigid_averaged = d.design_stamp_rigid_averaged;
  o.design_stamp_off_face = d.design_stamp_off_face;
  o.design_stamp_off_face_n = d.design_stamp_off_face_n;
  o.max_smoothing_change_mm = d.max_smoothing_change_mm;
  o.material_volume_mm3 = d.material_volume_mm3;
  o.target_depth_min = d.target_depth.min;
  o.target_depth_max = d.target_depth.max;
  o.buildable_depth_min = d.buildable_depth.min;
  o.buildable_depth_max = d.buildable_depth.max;
  o.buildable_density_min = d.buildable_density.min;
  o.buildable_density_max = d.buildable_density.max;
  o.cell_min = d.cell.min;
  o.cell_max = d.cell.max;
  o.sigma_min = d.sigma.min;
  o.sigma_max = d.sigma.max;
}

// The assembled field for these faces' last designs (cached on the scene). Caller holds s.mu.
const fx::DensityField& field_of(Scene& s, const std::vector<int32_t>& face_region_ids,
                                 const std::vector<int32_t>& rotations, const FlexBuild& build) {
  std::vector<fx::LoadedStack> ls;
  std::vector<std::tuple<int, int, const fx::FaceDesign*>> key;
  for (std::size_t i = 0; i < face_region_ids.size(); ++i) {
    const int rot = i < rotations.size() ? rotations[i] : 0;
    const auto k = std::make_pair(static_cast<int>(face_region_ids[i]), rot);
    auto it = s.designs.find(k);
    if (it == s.designs.end())
      throw std::invalid_argument("face " + std::to_string(face_region_ids[i]) + " has no design yet");
    ls.push_back({&stack_of(s, k.first, k.second), it->second.get()});
    key.emplace_back(k.first, k.second, it->second.get());
  }
  const std::string bkey = build.topology + "/" + std::to_string(build.beads_per_wall) + "/" +
                           std::to_string(build.bead_width_mm);
  if (!s.field || s.field_key != key || s.field_build_key != bkey) {
    s.field = std::make_unique<fx::DensityField>(
        fx::assemble_density_field(s.grid, s.mask, ls, to_core(build)));
    s.field_key = key;
    s.field_build_key = bkey;
  }
  return *s.field;
}

}  // namespace

// ── catalogue ───────────────────────────────────────────────────────────────
std::vector<FlexMaterial> flexible_materials(const std::string& materials_path, BridgeError& err) {
  std::vector<FlexMaterial> out;
  try {
    auto d = data_at(materials_path);
    for (const auto& kv : d->catalogue.materials) {
      const fx::Material& m = kv.second;
      FlexMaterial o;
      o.id = kv.first;
      o.display_name = m.display_name;
      o.family = m.family;
      o.tier = m.tier;
      o.foaming = m.foaming;
      o.shore_a_known = m.shore_a_nominal.known;
      o.shore_a = m.shore_a_nominal.value;
      o.nozzle_range_known = m.nozzle_temp_range_c.known;
      o.nozzle_range_lo = m.nozzle_temp_range_c.lo;
      o.nozzle_range_hi = m.nozzle_temp_range_c.hi;
      o.tested_temps_c = fx::tested_temperatures(*d, kv.first);
      o.offered_temps_note = m.offered_temps_note;
      o.note = m.note;
      o.sources = m.sources;
      if (o.tested_temps_c.empty()) {
        // core's own gate sentence (curve_set refuses before it reads a temperature)
        const fx::Refusal r = fx::curve_set(*d, kv.first, 0.0, "gyroid").refusal;
        o.no_prediction_code = r.code;
        o.no_prediction_reason = r.reason;
      }
      out.push_back(std::move(o));
    }
  } catch (const std::exception& e) {
    fail(err, e);
    out.clear();
  }
  return out;
}

FlexErrorBands flexible_error_bands(const std::string& materials_path, BridgeError& err) {
  FlexErrorBands o;
  try {
    const fx::ErrorBands& b = data_at(materials_path)->catalogue.error_bands;
    o.literature = b.literature_same_material;
    o.calibrated = b.calibrated;
    o.proxy = b.proxy;
    o.status = b.status;
    o.note = b.note;
  } catch (const std::exception& e) {
    fail(err, e);
  }
  return o;
}

std::string flexible_temperature_note(const std::string& materials_path,
                                      const std::string& material_id, double temp_c,
                                      BridgeError& err) {
  try {
    return fx::temperature_note(*data_at(materials_path), material_id, temp_c);
  } catch (const std::exception& e) {
    fail(err, e);
    return "";
  }
}

// ── pen curves ──────────────────────────────────────────────────────────────
std::string flexible_pen_curve_error(const std::vector<double>& x, const std::vector<double>& y) {
  return fx::pen_curve_error(x, y);
}

std::vector<double> flexible_pen_curve_values(const std::vector<double>& x,
                                              const std::vector<double>& y,
                                              const std::vector<double>& t, BridgeError& err) {
  try {
    return fx::pen_curve_values(x, y, t);
  } catch (const std::exception& e) {
    fail(err, e);
    return {};
  }
}

// ── the squish table ────────────────────────────────────────────────────────
FlexCurveSet flexible_curve_set(const std::string& materials_path, const std::string& material_id,
                                double temp_c, const std::string& topology, BridgeError& err) {
  FlexCurveSet o;
  try {
    const fx::CurveSetResult r = set_for(materials_path, material_id, temp_c, topology);
    if (r.refusal.refused()) {
      o.refused = true;
      o.refusal_code = r.refusal.code;
      o.refusal_reason = r.refusal.reason;
      return o;
    }
    const fx::CurveSet& s = r.set;
    o.density_min = s.density_min();
    o.density_max = s.density_max();
    o.strain_measured_max = s.strain_measured_max();
    o.strain_limit = s.strain_limit();
    o.density_basis = s.density_basis;
    o.tier = s.tier;
    o.strain_convention = s.strain_convention;
    auto d = data_at(materials_path);
    for (const fx::CurveRow& row : s.rows) {
      o.row_density.push_back(row.core_density);
      o.row_entry_id.push_back(row.entry_id);
      std::string src;
      for (const auto& t : d->tables)
        for (const auto& e : t.entries)
          if (e.id == row.entry_id) src = e.source;
      o.row_source.push_back(src);
    }
  } catch (const std::exception& e) {
    fail(err, e);
  }
  return o;
}

FlexStress flexible_stress_at(const std::string& materials_path, const std::string& material_id,
                              double temp_c, const std::string& topology, double strain,
                              double core_density, BridgeError& err) {
  FlexStress o;
  try {
    const fx::CurveSetResult r = set_for(materials_path, material_id, temp_c, topology);
    if (r.refusal.refused()) {
      o.refusal_code = r.refusal.code;
      o.refusal_reason = r.refusal.reason;
      return o;
    }
    const fx::StressResult s = fx::stress_at(r.set, strain, core_density);
    o.ok = s.ok;
    o.stress_mpa = s.stress_mpa;
    o.extrapolated = s.extrapolated;
    o.refusal_code = s.refusal.code;
    o.refusal_reason = s.refusal.reason;
  } catch (const std::exception& e) {
    fail(err, e);
  }
  return o;
}

FlexInverse flexible_density_for(const std::string& materials_path, const std::string& material_id,
                                 double temp_c, const std::string& topology, double target_strain,
                                 double pressure_mpa, BridgeError& err) {
  FlexInverse o;
  try {
    const fx::CurveSetResult r = set_for(materials_path, material_id, temp_c, topology);
    if (r.refusal.refused()) {
      o.status = r.refusal.code;
      o.refusal_code = r.refusal.code;
      o.refusal_reason = r.refusal.reason;
      return o;
    }
    const fx::InverseResult s = fx::density_for(r.set, target_strain, pressure_mpa);
    o.ok = s.ok;
    o.status = s.status;
    o.core_density = s.core_density;
    o.extrapolated = s.extrapolated;
    o.nearest_density = s.nearest_density;
    o.nearest_strain = s.nearest_strain;
    o.nearest_known = s.nearest_known;
    o.refusal_code = s.refusal.code;
    o.refusal_reason = s.refusal.reason;
  } catch (const std::exception& e) {
    fail(err, e);
  }
  return o;
}

FlexStrain flexible_strain_under(const std::string& materials_path, const std::string& material_id,
                                 double temp_c, const std::string& topology, double pressure_mpa,
                                 double core_density, BridgeError& err) {
  FlexStrain o;
  try {
    const fx::CurveSetResult r = set_for(materials_path, material_id, temp_c, topology);
    if (r.refusal.refused()) {
      o.refusal_code = r.refusal.code;
      o.refusal_reason = r.refusal.reason;
      return o;
    }
    const fx::StrainResult s = fx::strain_under(r.set, pressure_mpa, core_density);
    o.ok = s.ok;
    o.strain = s.strain;
    o.extrapolated = s.extrapolated;
    o.refusal_code = s.refusal.code;
    o.refusal_reason = s.refusal.reason;
  } catch (const std::exception& e) {
    fail(err, e);
  }
  return o;
}

FlexCurveSamples flexible_curve_samples(const std::string& materials_path,
                                        const std::string& material_id, double temp_c,
                                        const std::string& topology, double core_density,
                                        const std::vector<double>& strains, BridgeError& err) {
  FlexCurveSamples o;
  try {
    const fx::CurveSetResult r = set_for(materials_path, material_id, temp_c, topology);
    for (double e : strains) {
      o.strain.push_back(e);
      if (r.refusal.refused()) {
        o.stress_mpa.push_back(0.0);
        o.ok.push_back(0);
        o.extrapolated.push_back(0);
        continue;
      }
      const fx::StressResult s = fx::stress_at(r.set, e, core_density);
      o.stress_mpa.push_back(s.ok ? s.stress_mpa : 0.0);
      o.ok.push_back(s.ok ? 1 : 0);
      o.extrapolated.push_back(s.extrapolated ? 1 : 0);
    }
  } catch (const std::exception& e) {
    fail(err, e);
    o = FlexCurveSamples{};
  }
  return o;
}

FlexTierBand flexible_tier_band(const std::string& materials_path, const std::string& set_tier,
                                bool side_stack, int32_t beads_per_wall, BridgeError& err) {
  FlexTierBand o;
  try {
    const fx::TierBand t =
        fx::tier_band(data_at(materials_path)->catalogue.error_bands, set_tier, side_stack, beads_per_wall);
    o.tier = t.tier;
    o.band = t.band;
    o.why = t.why;
  } catch (const std::exception& e) {
    fail(err, e);
  }
  return o;
}

double flexible_cell_size_mm(const std::string& topology, double core_density,
                             int32_t beads_per_wall, double bead_width_mm, BridgeError& err) {
  try {
    return fx::cell_size_mm(topology, core_density, beads_per_wall, bead_width_mm);
  } catch (const std::exception& e) {
    fail(err, e);
    return 0.0;
  }
}

// ── stamps ──────────────────────────────────────────────────────────────────
std::string flexible_stamp_grid_error(const FlexStampGrid& s) {
  return fx::stamp_grid_error(to_core(s));
}
double flexible_stamp_force_n(const FlexStampGrid& s) { return fx::stamp_force_n(to_core(s)); }
double flexible_stamp_width_mm(const FlexStampGrid& s) { return fx::stamp_width_mm(to_core(s)); }

// ── scenes ──────────────────────────────────────────────────────────────────
int64_t flexible_scene_open(const std::string& job_json, const std::string& job_dir,
                            BridgeError& err) {
  try {
    auto s = std::make_shared<Scene>();
    s->job = topopt::parse_job(job_json);
    if (!s->job.flexible) throw std::invalid_argument("the job has no \"flexible\" block");
    const std::string model_path = (std::filesystem::path(job_dir) / s->job.model).string();
    s->model = topopt::import_part_file_resolved(model_path);
    s->grid = topopt::voxelize(s->model.mesh, s->job.resolution);
    s->mask = topopt::flexible_region_mask(s->job, s->model, s->grid);
    s->regions = topopt::resolve_face_regions(s->model, s->job.loads.face_regions);
    s->build = s->job.has_build_direction
                   ? s->job.build_direction
                   : (s->job.loads.present ? s->job.loads.build_dir : topopt::Vec3{0, 0, 1});
    for (char c : s->mask) s->lattice_voxels += c ? 1 : 0;
    std::lock_guard<std::mutex> lock(g_scene_mu);
    const int64_t id = g_next_scene++;
    g_scenes[id] = s;
    return id;
  } catch (const std::exception& e) {
    fail(err, e);
    return 0;
  }
}

void flexible_scene_close(int64_t scene) {
  std::lock_guard<std::mutex> lock(g_scene_mu);
  g_scenes.erase(scene);
}

FlexSceneInfo flexible_scene_info(int64_t scene, BridgeError& err) {
  FlexSceneInfo o;
  try {
    auto s = scene_at(scene);
    std::lock_guard<std::mutex> lock(s->mu);
    o.nx = s->grid.nx;
    o.ny = s->grid.ny;
    o.nz = s->grid.nz;
    o.spacing = s->grid.spacing;
    put3(o.origin, s->grid.origin);
    put3(o.build_dir, s->build);
    o.lattice_voxels = s->lattice_voxels;
    o.region_face_offsets.push_back(0);
    for (const auto& r : s->regions) {
      o.region_ids.push_back(r.id);
      o.region_names.push_back(r.name);
      for (int f : r.member_faces) o.region_faces.push_back(f);
      o.region_face_offsets.push_back(static_cast<int32_t>(o.region_faces.size()));
    }
  } catch (const std::exception& e) {
    fail(err, e);
  }
  return o;
}

FlexStack flexible_scene_stack(int64_t scene, int32_t face_region_id, int32_t rotation_deg,
                               BridgeError& err) {
  FlexStack o;
  try {
    auto s = scene_at(scene);
    std::lock_guard<std::mutex> lock(s->mu);
    const fx::Stack& st = stack_of(*s, face_region_id, rotation_deg);
    const fx::FaceFrame& f = st.frame;
    o.frame_valid = f.valid;
    o.frame_reason = f.reason;
    put3(o.load, f.load);
    put3(o.x_axis, f.x_axis);
    put3(o.y_axis, f.y_axis);
    put3(o.centroid, f.centroid);
    o.rotation_deg = f.rotation_deg;
    o.u_min = f.u_min;
    o.v_min = f.v_min;
    o.u_extent_mm = f.u_extent_mm;
    o.v_extent_mm = f.v_extent_mm;
    o.area_mm2 = f.area_mm2;
    o.projected_area_mm2 = f.projected_area_mm2;
    o.normal_spread_deg = f.normal_spread_deg;
    o.normal_spread_flag = f.normal_spread_flag;
    o.build_angle_deg = f.build_angle_deg;
    o.side = f.side;
    o.principal_axis_tied = f.principal_axis_tied;
    o.pitch_mm = st.pitch_mm;
    o.nu = st.nu;
    o.nv = st.nv;
    o.cell.assign(st.cell.begin(), st.cell.end());
    for (const fx::StackColumn& c : st.columns) {
      o.col_iu.push_back(c.iu);
      o.col_iv.push_back(c.iv);
      o.col_u_mm.push_back(c.u_mm);
      o.col_v_mm.push_back(c.v_mm);
      o.col_area_mm2.push_back(c.area_mm2);
      o.col_entry_t.push_back(c.entry_t);
      o.col_exit_t.push_back(c.exit_t);
      o.col_lattice_mm.push_back(c.lattice_mm);
      o.col_exit_face.push_back(c.exit_face);
    }
    for (const fx::StackLink& l : st.exit_faces) {
      o.exit_face_ids.push_back(l.id);
      o.exit_face_fractions.push_back(l.area_fraction);
    }
    for (const fx::StackLink& l : st.exit_regions) {
      o.exit_region_ids.push_back(l.id);
      o.exit_region_fractions.push_back(l.area_fraction);
    }
    o.exit_unresolved_fraction = st.exit_unresolved_fraction;
    o.footprint_area_mm2 = st.footprint_area_mm2;
    o.latticed_columns = st.latticed_columns;
    o.lattice_mm_min = st.lattice_mm_min;
    o.lattice_mm_mean = st.lattice_mm_mean;
    o.lattice_mm_max = st.lattice_mm_max;
    o.stack_mm_max = st.stack_mm_max;
  } catch (const std::exception& e) {
    fail(err, e);
  }
  return o;
}

std::vector<double> flexible_scene_from_uv(int64_t scene, int32_t face_region_id,
                                           int32_t rotation_deg, const std::vector<double>& uv,
                                           BridgeError& err) {
  std::vector<double> out;
  try {
    auto s = scene_at(scene);
    std::lock_guard<std::mutex> lock(s->mu);
    const fx::FaceFrame& f = stack_of(*s, face_region_id, rotation_deg).frame;
    out.reserve(uv.size() / 2 * 3);
    for (std::size_t i = 0; i + 1 < uv.size(); i += 2) {
      const topopt::Vec3 p = f.from_uv(uv[i], uv[i + 1]);
      out.push_back(p.x);
      out.push_back(p.y);
      out.push_back(p.z);
    }
  } catch (const std::exception& e) {
    fail(err, e);
    out.clear();
  }
  return out;
}

std::vector<double> flexible_scene_to_uvt(int64_t scene, int32_t face_region_id,
                                          int32_t rotation_deg, const std::vector<double>& xyz,
                                          BridgeError& err) {
  std::vector<double> out;
  try {
    auto s = scene_at(scene);
    std::lock_guard<std::mutex> lock(s->mu);
    const fx::FaceFrame& f = stack_of(*s, face_region_id, rotation_deg).frame;
    out.reserve(xyz.size());
    for (std::size_t i = 0; i + 2 < xyz.size(); i += 3) {
      const topopt::Vec3 p{xyz[i], xyz[i + 1], xyz[i + 2]};
      double u = 0.0, v = 0.0;
      f.to_uv(p, u, v);
      const double t = (p.x - f.centroid.x) * f.load.x + (p.y - f.centroid.y) * f.load.y +
                       (p.z - f.centroid.z) * f.load.z;
      out.push_back(u);
      out.push_back(v);
      out.push_back(t);
    }
  } catch (const std::exception& e) {
    fail(err, e);
    out.clear();
  }
  return out;
}

std::vector<double> flexible_scene_squish_fraction(int64_t scene, int32_t face_region_id,
                                                   int32_t rotation_deg, const FlexSquishMap& map,
                                                   BridgeError& err) {
  try {
    auto s = scene_at(scene);
    std::lock_guard<std::mutex> lock(s->mu);
    return fx::squish_fraction(stack_of(*s, face_region_id, rotation_deg), to_core(map));
  } catch (const std::exception& e) {
    fail(err, e);
    return {};
  }
}

std::vector<double> flexible_scene_edge_fraction(int64_t scene, int32_t face_region_id,
                                                 int32_t rotation_deg, BridgeError& err) {
  try {
    auto s = scene_at(scene);
    std::lock_guard<std::mutex> lock(s->mu);
    return fx::edge_fraction(stack_of(*s, face_region_id, rotation_deg));
  } catch (const std::exception& e) {
    fail(err, e);
    return {};
  }
}

FlexFaceDesign flexible_scene_design(int64_t scene, const std::string& materials_path,
                                     const std::string& material_id, double temp_c,
                                     int32_t face_region_id, int32_t rotation_deg,
                                     const FlexSquishMap& map, double weight_n,
                                     const FlexStampGrid& design_stamp, const FlexBuild& build,
                                     BridgeError& err) {
  FlexFaceDesign o;
  try {
    const fx::CurveSetResult r = set_for(materials_path, material_id, temp_c, build.topology);
    auto s = scene_at(scene);
    std::lock_guard<std::mutex> lock(s->mu);
    const auto key = std::make_pair(static_cast<int>(face_region_id), static_cast<int>(rotation_deg));
    if (r.refusal.refused()) {
      o.refused = true;
      o.refusal_code = r.refusal.code;
      o.refusal_reason = r.refusal.reason;
      s->designs.erase(key);
      return o;
    }
    const fx::Stack& st = stack_of(*s, face_region_id, rotation_deg);
    const fx::TierBand tier = fx::tier_band(data_at(materials_path)->catalogue.error_bands, r.set.tier,
                                            st.frame.side, build.beads_per_wall);
    fx::StampGrid stamp;
    if (design_stamp.present) stamp = to_core(design_stamp);
    auto d = std::make_unique<fx::FaceDesign>(fx::design_face(
        r.set, st, to_core(map), weight_n, design_stamp.present ? &stamp : nullptr, to_core(build), tier));
    copy_design(*d, o);
    s->designs[key] = std::move(d);
    s->tiers[key] = std::make_unique<fx::TierBand>(tier);
  } catch (const std::exception& e) {
    fail(err, e);
    o = FlexFaceDesign{};
  }
  return o;
}

FlexStampCheck flexible_scene_check_stamp(int64_t scene, const std::string& materials_path,
                                          const std::string& material_id, double temp_c,
                                          int32_t face_region_id, int32_t rotation_deg,
                                          const std::vector<double>& column_density,
                                          const FlexStampGrid& stamp, const FlexBuild& build,
                                          BridgeError& err) {
  FlexStampCheck o;
  try {
    const fx::CurveSetResult r = set_for(materials_path, material_id, temp_c, build.topology);
    if (r.refusal.refused()) {
      o.refusal_code = r.refusal.code;
      o.refusal_reason = r.refusal.reason;
      return o;
    }
    auto s = scene_at(scene);
    std::lock_guard<std::mutex> lock(s->mu);
    const auto key = std::make_pair(static_cast<int>(face_region_id), static_cast<int>(rotation_deg));
    const fx::Stack& st = stack_of(*s, face_region_id, rotation_deg);
    std::vector<double> rho = column_density;
    if (rho.empty()) {
      // the densities core designed on this scene, exactly as run_flexible_job reads
      // them: a solid column (no_lattice) is 0
      auto it = s->designs.find(key);
      if (it == s->designs.end())
        throw std::invalid_argument("face " + std::to_string(face_region_id) + " has no design yet");
      rho.assign(st.columns.size(), 0.0);
      for (std::size_t k = 0; k < st.columns.size(); ++k)
        rho[k] = it->second->columns[k].status == "no_lattice" ? 0.0 : it->second->columns[k].buildable_density;
    }
    const fx::TierBand tier = fx::tier_band(data_at(materials_path)->catalogue.error_bands, r.set.tier,
                                            st.frame.side, build.beads_per_wall);
    const fx::StampCheck c = fx::check_stamp(r.set, st, rho, to_core(stamp), to_core(build), tier);
    o.ok = c.ok;
    o.refusal_code = c.refusal.code;
    o.refusal_reason = c.refusal.reason;
    o.depth_mm = c.depth_mm;
    o.status = c.status;
    o.pressed_columns = c.pressed_columns;
    o.extrapolated_columns = c.extrapolated_columns;
    o.beyond_data_columns = c.beyond_data_columns;
    o.rigid_unlatticed_columns = c.rigid_unlatticed_columns;
    o.max_depth_mm = c.max_depth_mm;
    o.rigid_depth_mm = c.rigid_depth_mm;
    o.stamp_width_mm = c.stamp_width_mm;
    o.local_cell_mm = c.local_cell_mm;
    o.narrow = c.narrow;
    o.force_off_face_n = c.force_off_face_n;
    o.off_face = c.off_face;
    o.tier = c.tier.tier;
    o.band = c.tier.band;
    o.tier_why = c.tier.why;
  } catch (const std::exception& e) {
    fail(err, e);
    o = FlexStampCheck{};
  }
  return o;
}

std::vector<FlexConflict> flexible_scene_conflicts(int64_t scene,
                                                   const std::vector<int32_t>& face_region_ids,
                                                   const std::vector<int32_t>& rotations,
                                                   BridgeError& err) {
  std::vector<FlexConflict> out;
  try {
    auto s = scene_at(scene);
    std::lock_guard<std::mutex> lock(s->mu);
    std::vector<const fx::Stack*> sp;
    for (std::size_t i = 0; i < face_region_ids.size(); ++i)
      sp.push_back(&stack_of(*s, face_region_ids[i], i < rotations.size() ? rotations[i] : 0));
    for (const fx::StackConflict& c : fx::find_stack_conflicts(s->grid, s->mask, sp))
      out.push_back(FlexConflict{c.face_a, c.face_b, c.overlap_mm3, c.axis_angle_deg});
  } catch (const std::exception& e) {
    fail(err, e);
    out.clear();
  }
  return out;
}

FlexFieldSlice flexible_scene_density_slice(int64_t scene,
                                            const std::vector<int32_t>& face_region_ids,
                                            const std::vector<int32_t>& rotations,
                                            const FlexBuild& build, int32_t axis, int32_t index,
                                            BridgeError& err) {
  FlexFieldSlice o;
  try {
    auto s = scene_at(scene);
    std::lock_guard<std::mutex> lock(s->mu);
    const fx::DensityField& f = field_of(*s, face_region_ids, rotations, build);
    const int n[3] = {f.nx, f.ny, f.nz};
    if (axis < 0 || axis > 2) throw std::invalid_argument("axis must be 0, 1 or 2");
    if (index < 0 || index >= n[axis]) throw std::invalid_argument("slice index out of range");
    const int a = axis == 0 ? 1 : 0;       // first in-plane axis
    const int b = axis == 2 ? 1 : 2;       // second in-plane axis
    o.width = n[a];
    o.height = n[b];
    o.spacing = f.spacing;
    o.density.resize(static_cast<std::size_t>(o.width) * o.height);
    o.owner.resize(o.density.size());
    for (int jb = 0; jb < n[b]; ++jb)
      for (int ja = 0; ja < n[a]; ++ja) {
        int ijk[3];
        ijk[axis] = index;
        ijk[a] = ja;
        ijk[b] = jb;
        const std::size_t vi = (static_cast<std::size_t>(ijk[2]) * f.ny + ijk[1]) * f.nx + ijk[0];
        const std::size_t oi = static_cast<std::size_t>(jb) * o.width + ja;
        o.density[oi] = f.density[vi];
        o.owner[oi] = f.owner[vi];
      }
    o.lattice_voxels = f.lattice_voxels;
    o.assigned_voxels = f.assigned_voxels;
    o.unassigned_voxels = f.unassigned_voxels;
    for (const fx::Handover& h : f.handovers) {
      o.handover_a.push_back(h.face_a);
      o.handover_b.push_back(h.face_b);
      o.handover_overlap_mm3.push_back(h.overlap_mm3);
      o.handover_blended_mm3.push_back(h.blended_mm3);
    }
  } catch (const std::exception& e) {
    fail(err, e);
    o = FlexFieldSlice{};
  }
  return o;
}

FlexField flexible_scene_density_field(int64_t scene, const std::vector<int32_t>& face_region_ids,
                                       const std::vector<int32_t>& rotations, const FlexBuild& build,
                                       BridgeError& err) {
  FlexField o;
  try {
    auto s = scene_at(scene);
    std::lock_guard<std::mutex> lock(s->mu);
    const fx::DensityField& f = field_of(*s, face_region_ids, rotations, build);
    o.nx = f.nx;
    o.ny = f.ny;
    o.nz = f.nz;
    o.spacing = f.spacing;
    put3(o.origin, f.origin);
    o.density.assign(f.density.begin(), f.density.end());
    o.owner.assign(f.owner.begin(), f.owner.end());
  } catch (const std::exception& e) {
    fail(err, e);
    o = FlexField{};
  }
  return o;
}

FlexRecommendation flexible_scene_recommend(int64_t scene, const std::string& materials_path,
                                            const std::string& material_id,
                                            const std::vector<double>& temps,
                                            const std::vector<std::string>& topologies,
                                            const std::string& feel, int32_t beads_per_wall,
                                            double bead_width_mm,
                                            const std::vector<FlexFaceRequest>& faces,
                                            BridgeError& err) {
  FlexRecommendation o;
  try {
    auto d = data_at(materials_path);
    auto s = scene_at(scene);
    std::lock_guard<std::mutex> lock(s->mu);
    std::vector<fx::StampGrid> stamps(faces.size());
    std::vector<fx::FaceRequest> req;
    for (std::size_t i = 0; i < faces.size(); ++i) {
      const FlexFaceRequest& f = faces[i];
      if (f.design_stamp.present) stamps[i] = to_core(f.design_stamp);
      req.push_back({&stack_of(*s, f.face_region_id, f.rotation_deg), to_core(f.map), f.weight_n,
                     f.design_stamp.present ? &stamps[i] : nullptr});
    }
    const fx::Recommendation r =
        fx::recommend(*d, material_id, temps, topologies, feel, beads_per_wall, bead_width_mm, req);
    o.chosen = r.chosen;
    o.reachable = r.reachable;
    o.topology = r.topology;
    o.temp_c = r.temp_c;
    o.feel = r.feel;
    o.sentence = r.sentence;
    for (const fx::Reason& x : r.reasons) {
      o.reason_code.push_back(x.code);
      o.reason_text.push_back(x.text);
      o.reason_face.push_back(x.face_region_id);
    }
    for (const fx::Candidate& c : r.candidates) {
      o.cand_topology.push_back(c.topology);
      o.cand_temp_c.push_back(c.temp_c);
      o.cand_eligible.push_back(c.eligible ? 1 : 0);
      o.cand_has_data.push_back(c.has_data ? 1 : 0);
      o.cand_reachable.push_back(c.reachable ? 1 : 0);
      o.cand_unreachable_columns.push_back(c.unreachable_columns);
      o.cand_near_edge_columns.push_back(c.near_edge_columns);
      o.cand_mass_known.push_back(c.mass_known ? 1 : 0);
      o.cand_mass_g.push_back(c.mass_g);
      o.cand_refusal_code.push_back(c.refusal.code);
      o.cand_refusal_reason.push_back(c.refusal.reason);
    }
    for (const fx::FaceFailure& f : r.failures) {
      o.fail_face.push_back(f.face_region_id);
      o.fail_text.push_back(f.text);
      o.fail_u_min.push_back(f.u_min_mm);
      o.fail_u_max.push_back(f.u_max_mm);
      o.fail_v_min.push_back(f.v_min_mm);
      o.fail_v_max.push_back(f.v_max_mm);
      o.fail_nearest_known.push_back(f.nearest_known ? 1 : 0);
      o.fail_nearest_min_mm.push_back(f.nearest_depth_min_mm);
      o.fail_nearest_max_mm.push_back(f.nearest_depth_max_mm);
      o.fail_too_firm.push_back(f.too_firm);
      o.fail_too_soft.push_back(f.too_soft);
      o.fail_beyond_data.push_back(f.beyond_data);
    }
  } catch (const std::exception& e) {
    fail(err, e);
    o = FlexRecommendation{};
  }
  return o;
}

// ── the job block, through core's own parser ────────────────────────────────
FlexJobBlock flexible_parse_job_block(const std::string& job_json, BridgeError& err) {
  FlexJobBlock o;
  try {
    const topopt::JobDescription job = topopt::parse_job(job_json);
    if (!job.flexible) throw std::invalid_argument("the job has no \"flexible\" block");
    const topopt::JobFlexible& b = *job.flexible;
    o.material_id = b.material_id;
    o.nozzle_temp_auto = b.nozzle_temp_auto;
    o.nozzle_temp_c = b.nozzle_temp_c;
    o.topology = b.topology;
    o.feel = b.feel;
    o.beads_per_wall = b.beads_per_wall;
    o.min_extrudable_width_mm = b.min_extrudable_width_mm;
    o.region_count = static_cast<int32_t>(b.regions.size());
    for (const topopt::JobFlexibleFace& f : b.faces) {
      FlexJobFace g;
      g.face_region_id = f.face_region_id;
      g.role = f.role;
      g.frame_rotation_deg = f.frame_rotation_deg;
      g.weight_n = f.weight_n;
      g.deepest_squish_mm = f.deepest_squish_mm;
      g.mode = f.mode;
      g.x_x = f.curve_x_x;
      g.x_y = f.curve_x_y;
      g.y_x = f.curve_y_x;
      g.y_y = f.curve_y_y;
      g.c_x = f.curve_c_x;
      g.c_y = f.curve_c_y;
      if (f.has_design_stamp) g.design_stamp = from_core(f.design_stamp);
      g.skin_on = f.skin_on;
      o.faces.push_back(std::move(g));
    }
    for (const topopt::JobFlexibleCheckStamp& c : b.check_stamps) {
      o.check_face_ids.push_back(c.face_region_id);
      o.check_stamps.push_back(from_core(c.stamp));
    }
  } catch (const std::exception& e) {
    fail(err, e);
    o = FlexJobBlock{};
  }
  return o;
}


// ★ ROUND 4 (C2): core's own Flexible runner — see FlexibleBridge.hpp.
FlexRunResult flexible_run_job(const std::string& job_json, const std::string& job_dir,
                               const std::string& out_dir, const std::string& materials_path,
                               const std::string& fingerprint, BridgeError& err) {
  FlexRunResult o;
  try {
    const topopt::JobDescription job = topopt::parse_job(job_json);
    topopt::FlexibleProvenance prov;
    prov.cli_version = "app";
    prov.fingerprint = fingerprint;
    const topopt::FlexibleRunResult r =
        topopt::run_flexible_job(job, job_dir, out_dir, materials_path, prov);
    o.refused = r.refused;
    o.refusal_code = r.refusal_code;
    o.refusal_reason = r.refusal_reason;
    o.receipt_json = r.receipt_json;
    o.files = r.files;
  } catch (const std::exception& e) {
    fail(err, e);
    o = FlexRunResult{};
  }
  return o;
}

// ★ BATCH G: one squeeze group's squish as a 3D displacement field — see FlexibleBridge.hpp.
// Under the scene's lock only what the solve needs is COPIED (the grid, each pressed face's region
// and stack — built and cached here as the Settings page builds them —, the resting regions); the
// part is read through the scene's shared_ptr (immutable after open, and kept alive through a
// concurrent close). The lock is RELEASED before the solve, so the Settings page's design calls
// never wait seconds on it.
FlexSquishSolution flexible_scene_squish_solve(int64_t scene, const FlexSquishRequest& req,
                                               BridgeError& err) {
  try {
    auto s = scene_at(scene);
    squishfe::Setup setup;
    {
      std::lock_guard<std::mutex> lock(s->mu);
      setup.grid = s->grid;
      for (const FlexSquishPress& p : req.pressed)
        setup.pressed.push_back({region_of(*s, p.face_region_id), stack_of(*s, p.face_region_id, p.rotation_deg)});
      for (int32_t id : req.resting_region_ids) {
        const auto it = std::find_if(s->regions.begin(), s->regions.end(),
                                     [id](const topopt::ResolvedFaceRegion& r) { return r.id == id; });
        if (it == s->regions.end()) setup.resting_missing.push_back(id);
        else setup.resting.push_back(*it);
      }
    }
    setup.model = &s->model;
    return squishfe::solve(setup, req, *data_at(req.law.materials_path));
  } catch (const std::exception& e) {
    fail(err, e);
    return FlexSquishSolution{};
  }
}

double flexible_squish_modulus(const FlexSquishLaw& law, double rho, double strain,
                               double skin_frac, int32_t control, BridgeError& err) {
  try {
    return squishfe::modulus(law, *data_at(law.materials_path), rho, strain, skin_frac, control);
  } catch (const std::exception& e) {
    fail(err, e);
    return 0.0;
  }
}

int32_t flexible_squish_coarsen(int32_t nx, int32_t ny, int32_t nz) {
  return squishfe::coarsen(nx, ny, nz);
}

}  // namespace topoptbridge
