#include "topopt/flexible/job_block.hpp"

#include <algorithm>
#include <cmath>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "json.hpp"
#include "topopt/clearance.hpp"
#include "topopt/face_region.hpp"
#include "topopt/flexible/curve.hpp"
#include "topopt/lattice_boundary.hpp"

namespace topopt {
namespace {

using flexible::FlexibleError;
using flexible::json::Value;
namespace json = flexible::json;

void curve_of(const Value& v, const std::string& where, std::vector<double>& xs,
              std::vector<double>& ys) {
  json::as_array(v, where);
  for (std::size_t i = 0; i < v.arr.size(); ++i) {
    const std::string pw = where + "[" + std::to_string(i) + "]";
    const Value& p = v.arr[i];
    if (!p.is_array() || p.arr.size() != 2) json::fail(pw, "must be an [x, y] pair");
    xs.push_back(json::as_number(p.arr[0], pw + "[0]"));
    ys.push_back(json::as_number(p.arr[1], pw + "[1]"));
  }
  const std::string err = flexible::pen_curve_error(xs, ys);
  if (!err.empty()) json::fail(where, err);
}

flexible::StampGrid stamp_of(const Value& v, const std::string& where, bool with_face) {
  json::as_object(v, where);
  std::vector<std::string> keys{"name", "mode", "force_n", "origin_mm", "cell_mm",
                                "nu", "nv", "values_mpa"};
  if (with_face) keys.push_back("face_region_id");
  json::reject_unknown(v, keys, where);
  json::require_all(v, {"name", "mode", "force_n", "origin_mm", "cell_mm", "nu", "nv",
                        "values_mpa"},
                    where);
  flexible::StampGrid s;
  s.name = json::as_string(*json::find(v, "name"), where + ".name");
  const std::string mode = json::as_string(*json::find(v, "mode"), where + ".mode");
  if (mode != "soft" && mode != "rigid") json::fail(where + ".mode", "must be \"soft\" or \"rigid\"");
  s.rigid = mode == "rigid";
  s.force_n = json::as_number(*json::find(v, "force_n"), where + ".force_n");
  const Value& o = *json::find(v, "origin_mm");
  if (!o.is_array() || o.arr.size() != 2) json::fail(where + ".origin_mm", "must be [u, v]");
  s.origin_u_mm = json::as_number(o.arr[0], where + ".origin_mm[0]");
  s.origin_v_mm = json::as_number(o.arr[1], where + ".origin_mm[1]");
  s.cell_mm = json::as_number(*json::find(v, "cell_mm"), where + ".cell_mm");
  s.nu = json::as_int(*json::find(v, "nu"), where + ".nu");
  s.nv = json::as_int(*json::find(v, "nv"), where + ".nv");
  const Value& vals = json::as_array(*json::find(v, "values_mpa"), where + ".values_mpa");
  s.values_mpa.reserve(vals.arr.size());
  for (std::size_t i = 0; i < vals.arr.size(); ++i)
    s.values_mpa.push_back(json::as_number(vals.arr[i], where + ".values_mpa[" + std::to_string(i) + "]"));
  const std::string err = flexible::stamp_grid_error(s);
  if (!err.empty()) json::fail(where, err);
  return s;
}

}  // namespace

std::shared_ptr<const JobFlexible> parse_flexible_block(const std::string& job_json_text) {
  const Value root = json::parse(job_json_text, "job.json");
  const std::string w = "flexible";
  const Value& b = json::as_object(json::require(root, "flexible", "the job"), w);
  json::reject_unknown(b, {"material_id", "nozzle_temp_c", "topology", "feel", "beads_per_wall",
                           "min_extrudable_width_mm", "regions", "faces", "check_stamps"},
                       w);
  json::require_all(b, {"material_id", "nozzle_temp_c", "topology", "feel", "beads_per_wall",
                        "min_extrudable_width_mm", "faces"},
                    w);
  auto out = std::make_shared<JobFlexible>();
  JobFlexible& f = *out;
  f.material_id = json::as_string(*json::find(b, "material_id"), w + ".material_id");
  if (const Value* m = json::find(root, "material"))
    if (m->is_string() && m->str != f.material_id)
      json::fail(w + ".material_id", "\"" + f.material_id + "\" differs from the job's \"material\" \"" +
                                         m->str + "\"; a Flexible job names one filament");
  {
    const Value& t = *json::find(b, "nozzle_temp_c");
    if (t.is_string()) {
      if (t.str != "auto") json::fail(w + ".nozzle_temp_c", "must be a number or \"auto\"");
      f.nozzle_temp_auto = true;
    } else {
      f.nozzle_temp_c = json::as_number(t, w + ".nozzle_temp_c");
      if (!(f.nozzle_temp_c > 0.0)) json::fail(w + ".nozzle_temp_c", "must be > 0");
    }
  }
  f.topology = json::as_string(*json::find(b, "topology"), w + ".topology");
  if (f.topology != "auto" && f.topology != "gyroid" && f.topology != "honeycomb")
    json::fail(w + ".topology", "must be \"auto\", \"gyroid\" or \"honeycomb\"");
  f.feel = json::as_string(*json::find(b, "feel"), w + ".feel");
  if (f.feel != "springy" && f.feel != "damped")
    json::fail(w + ".feel", "must be \"springy\" or \"damped\"");
  f.beads_per_wall = json::as_int(*json::find(b, "beads_per_wall"), w + ".beads_per_wall");
  if (f.beads_per_wall != 1 && f.beads_per_wall != 2)
    json::fail(w + ".beads_per_wall", "must be 1 or 2 (whole beads, R1)");
  f.min_extrudable_width_mm =
      json::as_number(*json::find(b, "min_extrudable_width_mm"), w + ".min_extrudable_width_mm");
  if (!(f.min_extrudable_width_mm > 0.0))
    json::fail(w + ".min_extrudable_width_mm",
               "must be > 0: it is the bead width the walls are built from, and "
               "printability is user input, never a default");

  // The face regions the job declares (ids only; the lattice parser checks the rest).
  std::set<int> declared;
  if (const Value* loads = json::find(root, "loads"))
    if (const Value* frs = json::find(*loads, "face_regions"))
      if (frs->is_array())
        for (const Value& r : frs->arr)
          if (const Value* id = json::find(r, "id"))
            if (id->is_number()) declared.insert(static_cast<int>(id->num));

  if (const Value* regs = json::find(b, "regions")) {
    json::as_array(*regs, w + ".regions");
    for (std::size_t i = 0; i < regs->arr.size(); ++i) {
      const Value& r = regs->arr[i];
      if (!r.is_object()) continue;  // the lattice parser names it
      for (const char* k : {"relative_density", "synthetic_stress", "synthetic_foci",
                            "synthetic_soft_mm"})
        if (json::find(r, k))
          json::fail(w + ".regions[" + std::to_string(i) + "]",
                     std::string("\"") + k + "\" belongs to the Structural/Aesthetic lattice; "
                     "a Flexible region takes its density from the squish map");
    }
    if (!regs->arr.empty()) {
      // Parse through the lattice parser: the job without "flexible", with a stand-in
      // lattice block whose only meaningful key is `regions`.
      Value stand_in = root;
      stand_in.obj.erase(std::remove_if(stand_in.obj.begin(), stand_in.obj.end(),
                                        [](const std::pair<std::string, Value>& kv) {
                                          return kv.first == "flexible";
                                        }),
                         stand_in.obj.end());
      Value lat;
      lat.type = Value::Type::Object;
      Value one;
      one.type = Value::Type::Number;
      one.num = 1.0;
      lat.obj.push_back({"cell_mm", one});
      lat.obj.push_back({"strut_radius_mm", one});
      lat.obj.push_back({"regions", *regs});
      stand_in.obj.push_back({"lattice", lat});
      try {
        f.regions = parse_job(json::to_text(stand_in)).lattice.regions;
      } catch (const JobError& e) {
        std::string msg = e.what();
        const std::string prefix = "job.json: ";
        if (msg.compare(0, prefix.size(), prefix) == 0) msg = msg.substr(prefix.size());
        json::fail(w + ".regions", msg);
      }
    }
  }

  const Value& faces = json::as_array(*json::find(b, "faces"), w + ".faces");
  std::set<int> seen;
  int loaded = 0;
  for (std::size_t i = 0; i < faces.arr.size(); ++i) {
    const std::string fw = w + ".faces[" + std::to_string(i) + "]";
    const Value& fv = json::as_object(faces.arr[i], fw);
    JobFlexibleFace face;
    // A press names ONE region ("face_region_id") or 2+ adjacent regions pressed as one
    // footprint ("face_region_ids": an edge or corner press, named by its first id).
    std::vector<int> ids;
    if (const Value* list = json::find(fv, "face_region_ids")) {
      if (json::find(fv, "face_region_id"))
        json::fail(fw, "give \"face_region_id\" or \"face_region_ids\", not both");
      json::as_array(*list, fw + ".face_region_ids");
      for (std::size_t k = 0; k < list->arr.size(); ++k)
        ids.push_back(json::as_int(list->arr[k], fw + ".face_region_ids[" + std::to_string(k) + "]"));
      if (ids.size() < 2)
        json::fail(fw + ".face_region_ids", "needs at least 2 regions (one region: \"face_region_id\")");
      for (std::size_t a = 0; a < ids.size(); ++a)
        for (std::size_t b = a + 1; b < ids.size(); ++b)
          if (ids[a] == ids[b])
            json::fail(fw + ".face_region_ids", std::to_string(ids[a]) + " is listed twice");
      face.footprint_region_ids = ids;
    } else {
      ids.push_back(json::as_int(json::require(fv, "face_region_id", fw), fw + ".face_region_id"));
    }
    face.face_region_id = ids.front();
    for (int id : ids) {
      if (declared.find(id) == declared.end())
        json::fail(fw + ".face_region_id", std::to_string(id) + " is not declared in \"loads.face_regions\"");
      if (!seen.insert(id).second)
        json::fail(fw + ".face_region_id",
                   std::to_string(id) + " appears twice; one entry per face (a region is in one press)");
    }
    face.role = json::as_string(json::require(fv, "role", fw), fw + ".role");
    face.skin_on = json::as_bool(json::require(fv, "skin_on", fw), fw + ".skin_on");
    if (face.role == "resting") {
      json::reject_unknown(fv, {"face_region_id", "role", "skin_on"}, fw);
      f.faces.push_back(face);
      continue;
    }
    if (face.role != "loaded") json::fail(fw + ".role", "must be \"loaded\" or \"resting\"");
    ++loaded;
    json::reject_unknown(fv, {"face_region_id", "face_region_ids", "press_direction", "role", "skin_on",
                              "frame_rotation_deg", "weight_n", "deepest_squish_mm", "mode", "curve_x",
                              "curve_y", "curve_centre_edge", "design_stamp"},
                         fw);
    if (const Value* pd = json::find(fv, "press_direction")) {
      const std::string pw = fw + ".press_direction";
      if (!pd->is_array() || pd->arr.size() != 3) json::fail(pw, "must be [x, y, z]");
      face.press_direction = {json::as_number(pd->arr[0], pw + "[0]"), json::as_number(pd->arr[1], pw + "[1]"),
                              json::as_number(pd->arr[2], pw + "[2]")};
      const Vec3& d = face.press_direction;
      if (!(d.x * d.x + d.y * d.y + d.z * d.z > 0.0)) json::fail(pw, "must be non-zero");
      face.has_press_direction = true;
    }
    json::require_all(fv, {"weight_n", "deepest_squish_mm", "mode"}, fw);
    if (const Value* r = json::find(fv, "frame_rotation_deg")) {
      face.frame_rotation_deg = json::as_int(*r, fw + ".frame_rotation_deg");
      if (face.frame_rotation_deg != 0 && face.frame_rotation_deg != 90 &&
          face.frame_rotation_deg != 180 && face.frame_rotation_deg != 270)
        json::fail(fw + ".frame_rotation_deg", "must be 0, 90, 180 or 270");
    }
    face.weight_n = json::as_number(*json::find(fv, "weight_n"), fw + ".weight_n");
    if (!(face.weight_n > 0.0)) json::fail(fw + ".weight_n", "must be > 0");
    face.deepest_squish_mm =
        json::as_number(*json::find(fv, "deepest_squish_mm"), fw + ".deepest_squish_mm");
    if (!(face.deepest_squish_mm > 0.0)) json::fail(fw + ".deepest_squish_mm", "must be > 0");
    face.mode = json::as_string(*json::find(fv, "mode"), fw + ".mode");
    if (face.mode == "both" || face.mode == "either") {
      if (json::find(fv, "curve_centre_edge"))
        json::fail(fw, "\"curve_centre_edge\" is only for mode \"centre_edge\"");
      curve_of(json::require(fv, "curve_x", fw), fw + ".curve_x", face.curve_x_x, face.curve_x_y);
      curve_of(json::require(fv, "curve_y", fw), fw + ".curve_y", face.curve_y_x, face.curve_y_y);
    } else if (face.mode == "centre_edge") {
      if (json::find(fv, "curve_x") || json::find(fv, "curve_y"))
        json::fail(fw, "\"curve_x\" / \"curve_y\" are only for modes \"both\" and \"either\"");
      curve_of(json::require(fv, "curve_centre_edge", fw), fw + ".curve_centre_edge",
               face.curve_c_x, face.curve_c_y);
    } else {
      json::fail(fw + ".mode", "must be \"both\", \"either\" or \"centre_edge\"");
    }
    if (const Value* ds = json::find(fv, "design_stamp")) {
      if (!ds->is_null()) {
        face.has_design_stamp = true;
        face.design_stamp = stamp_of(*ds, fw + ".design_stamp", false);
      }
    }
    f.faces.push_back(face);
  }
  if (loaded == 0) json::fail(w + ".faces", "needs at least one \"loaded\" face");

  if (const Value* cs = json::find(b, "check_stamps")) {
    json::as_array(*cs, w + ".check_stamps");
    for (std::size_t i = 0; i < cs->arr.size(); ++i) {
      const std::string sw = w + ".check_stamps[" + std::to_string(i) + "]";
      JobFlexibleCheckStamp c;
      c.stamp = stamp_of(cs->arr[i], sw, true);
      c.face_region_id =
          json::as_int(json::require(cs->arr[i], "face_region_id", sw), sw + ".face_region_id");
      bool on_loaded = false;
      for (const JobFlexibleFace& fc : f.faces)
        if (fc.face_region_id == c.face_region_id && fc.role == "loaded") on_loaded = true;
      if (!on_loaded)
        json::fail(sw + ".face_region_id", std::to_string(c.face_region_id) +
                                               " is not a loaded face of this block");
      f.check_stamps.push_back(c);
    }
  }
  return out;
}

flexible::SquishMap squish_map_of(const JobFlexibleFace& face) {
  flexible::SquishMap m;
  m.mode = face.mode;
  m.x_x = face.curve_x_x;
  m.x_y = face.curve_x_y;
  m.y_x = face.curve_y_x;
  m.y_y = face.curve_y_y;
  m.c_x = face.curve_c_x;
  m.c_y = face.curve_c_y;
  m.deepest_squish_mm = face.deepest_squish_mm;
  return m;
}

std::vector<char> flexible_region_mask(const JobDescription& job, const StepModel& model,
                                       const VoxelGrid& grid) {
  if (!job.flexible) throw FlexibleError("flexible_region_mask: the job has no flexible block");
  LatticeBoundary members;
  // Keep-outs: the job's clearances, resolved exactly as run_job.cpp's
  // lattice_keep_outs_from_job resolves them.
  if (job.loads.present)
    for (const JobClearance& jc : job.loads.clearances) {
      const bool bolt = jc.kind == "bolt";
      double bore_r = 0.0;
      if (bolt) {
        if (jc.manual)
          bore_r = jc.radius_mm;
        else if (jc.face_id >= 0 && jc.face_id < model.face_count)
          bore_r = model.faces[static_cast<std::size_t>(jc.face_id)].cylinder_radius_mm;
      }
      ClearanceParams params = bolt ? default_bolt_clearance(bore_r) : default_face_clearance();
      if (jc.concentric_margin_mm > 0.0) params.concentric_margin_mm = jc.concentric_margin_mm;
      if (jc.axial_clearance_mm > 0.0) params.axial_clearance_mm = jc.axial_clearance_mm;
      if (jc.slab_depth_mm > 0.0) params.slab_depth_mm = jc.slab_depth_mm;
      ClearanceGeometry g;
      if (jc.manual) {
        ManualClearanceGeometry mg;
        mg.kind = bolt ? ClearanceKind::Bolt : ClearanceKind::Face;
        mg.axis_point = jc.axis_point;
        mg.axis_dir = jc.axis_dir;
        mg.radius_mm = jc.radius_mm;
        mg.half_length_mm = jc.half_length_mm;
        mg.origin = jc.origin;
        mg.normal = jc.normal;
        mg.half_u_mm = jc.half_u_mm;
        mg.half_w_mm = jc.half_w_mm;
        g = resolve_clearance_manual(mg, params);
      } else {
        if (jc.face_id < 0 || jc.face_id >= model.face_count) continue;
        g = resolve_clearance_from_face(model, jc.face_id, params);
      }
      if (g.valid) members.add_keep_out(g, g.kind == ClearanceKind::Bolt);
    }
  // Role regions, resolved exactly as lattice_role_regions_from_job resolves them.
  std::vector<ResolvedFaceRegion> resolved;
  bool resolved_done = false;
  for (const JobLatticeRegion& r : job.flexible->regions) {
    ClearanceGeometry g;
    if (r.kind == "region") {
      if (!resolved_done) {
        resolved = resolve_face_regions(model, job.loads.face_regions);
        resolved_done = true;
      }
      const ResolvedFaceRegion* found = nullptr;
      for (const ResolvedFaceRegion& x : resolved)
        if (x.id == r.region_id) found = &x;
      if (found == nullptr)
        throw FlexibleError("flexible region names region_id " + std::to_string(r.region_id) +
                            ", which is not declared in \"loads.face_regions\"");
      auto m = std::make_shared<ClearanceVoxelMask>();
      m->nx = grid.nx;
      m->ny = grid.ny;
      m->nz = grid.nz;
      m->spacing = grid.spacing;
      m->origin = grid.origin;
      m->inside.assign(grid.voxel_count(), 0);
      const int layers = region_depth_layers(r.depth_mm, grid.spacing);
      for (int idx : cut_voxels(grid, region_member_voxels(grid, model, *found, layers), found->cuts))
        if (idx >= 0 && static_cast<std::size_t>(idx) < m->inside.size())
          m->inside[static_cast<std::size_t>(idx)] = 1;
      if (m->set_count() == 0)
        throw FlexibleError("flexible region " + std::to_string(r.region_id) +
                            " selects no solid voxels at " + std::to_string(r.depth_mm) +
                            " mm on this grid; it would lattice nothing");
      g.valid = true;
      g.kind = ClearanceKind::Face;
      g.mask = m;
    } else {
      ManualClearanceGeometry mg;
      ClearanceParams p;  // zero margins: the primitive IS the region
      if (r.kind == "bolt") {
        mg.kind = ClearanceKind::Bolt;
        p.kind = ClearanceKind::Bolt;
        mg.axis_point = r.axis_point;
        mg.axis_dir = r.axis_dir;
        mg.radius_mm = r.radius_mm;
        mg.half_length_mm = r.half_length_mm;
      } else {
        mg.kind = ClearanceKind::Face;
        p.kind = ClearanceKind::Face;
        p.slab_depth_mm = r.depth_mm;
        mg.origin = r.origin;
        mg.normal = r.normal;
        mg.half_u_mm = r.half_u_mm;
        mg.half_w_mm = r.half_w_mm;
        mg.outline_uv = r.outline_uv;
      }
      g = resolve_clearance_manual(mg, p);
      if (!g.valid) continue;
    }
    if (r.role == "include")
      members.add_include_region(g);
    else
      members.add_exclude_region(g);
  }
  std::vector<char> mask(grid.voxel_count(), 0);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const Vec3 c = grid.voxel_center(i, j, k);
        if (members.in_keep_out(c, 0.0)) continue;
        if (members.in_exclude_region(c, 0.0)) continue;
        if (members.has_include_regions() && !members.in_include_region(c, 0.0)) continue;
        mask[grid.index(i, j, k)] = 1;
      }
  return mask;
}

}  // namespace topopt
