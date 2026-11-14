#include "topopt/fields.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace topopt {
namespace {

// Little-endian byte sink. The format is fixed little-endian (the app reads it on
// ARM iPads, which are LE, and the CLI hosts — x86_64 / arm64 — are LE too), so we
// serialise byte-by-byte rather than trust the host layout: correct on a BE host
// as well, and immune to struct padding.
struct LEWriter {
  std::vector<std::uint8_t> bytes;

  void u8(std::uint8_t v) { bytes.push_back(v); }
  void pad(int n) {
    for (int i = 0; i < n; ++i) bytes.push_back(0);
  }
  void i32(std::int32_t v) { raw(&v, sizeof(v)); }
  void i64(std::int64_t v) { raw(&v, sizeof(v)); }
  void f32(float v) { raw(&v, sizeof(v)); }
  void f64(double v) { raw(&v, sizeof(v)); }

  // Append a float array narrowed from the double source, one f32 per element.
  void f32_array(const std::vector<double>& src) {
    for (const double d : src) f32(static_cast<float>(d));
  }

 private:
  // Host is little-endian on every platform this ships to; copy the bytes as-is.
  void raw(const void* p, std::size_t n) {
    const auto* b = static_cast<const std::uint8_t*>(p);
    bytes.insert(bytes.end(), b, b + n);
  }
};

}  // namespace

int write_fields_file(const std::string& path,
                      const MinimizePlasticResult& result,
                      const VoxelGrid& solved_grid,
                      bool accepted_only) {
  std::vector<const MinimizePlasticVariant*> all;
  all.reserve(result.evaluated.size());
  for (const MinimizePlasticVariant& v : result.evaluated) all.push_back(&v);
  return write_fields_file(path, all, solved_grid, accepted_only);
}

int write_fields_file(const std::string& path,
                      const std::vector<const MinimizePlasticVariant*>& variants,
                      const VoxelGrid& solved_grid,
                      bool accepted_only) {
  const std::size_t voxel_count = solved_grid.voxel_count();
  // Node count of the structured hex grid = (nx+1)(ny+1)(nz+1), the same value
  // fea_node_count returns (assembly.cpp). Computed inline so this always-built io
  // source carries no dependency on the Eigen-gated FEA translation unit.
  const std::size_t node_count =
      static_cast<std::size_t>(solved_grid.nx + 1) *
      static_cast<std::size_t>(solved_grid.ny + 1) *
      static_cast<std::size_t>(solved_grid.nz + 1);

  // Count the serialised variants first (the header carries the count). The
  // analyze route passes accepted_only = false: its ONE pseudo-variant carries
  // the margin verdict, and the field must be served either way (N3 — see the
  // header comment).
  std::vector<const MinimizePlasticVariant*> accepted;
  for (const MinimizePlasticVariant* v : variants)
    if (v && (v->accepted || !accepted_only)) accepted.push_back(v);

  LEWriter w;
  // -- run header ------------------------------------------------------------
  w.u8(kFieldsFormatVersion);
  w.pad(3);
  w.i32(solved_grid.nx);
  w.i32(solved_grid.ny);
  w.i32(solved_grid.nz);
  w.f64(solved_grid.origin.x);
  w.f64(solved_grid.origin.y);
  w.f64(solved_grid.origin.z);
  w.f64(solved_grid.spacing);
  w.f64(solved_grid.voxel_volume());
  w.i32(static_cast<std::int32_t>(accepted.size()));
  w.pad(4);

  // -- one block per accepted variant ---------------------------------------
  for (const MinimizePlasticVariant* vp : accepted) {
    const MinimizePlasticVariant& v = *vp;
    // Guard: an accepted variant's fields MUST match the solved grid, or the app
    // would misindex the container. A cancelled/rejected rung would have empty
    // fields, but those are never `accepted`, so this should always hold.
    if (v.von_mises_field.size() != voxel_count)
      throw FieldsError(
          "fields.bin: accepted variant von_mises_field size " +
          std::to_string(v.von_mises_field.size()) + " != grid voxel count " +
          std::to_string(voxel_count));
    if (v.displacement_field.size() != 3 * node_count)
      throw FieldsError(
          "fields.bin: accepted variant displacement_field size " +
          std::to_string(v.displacement_field.size()) + " != 3*node count " +
          std::to_string(3 * node_count));

    w.f64(v.requested_volume_fraction);
    w.f64(v.mass_grams);
    w.i32(static_cast<std::int32_t>(v.support_volume_voxels));
    w.pad(4);
    w.i64(static_cast<std::int64_t>(v.von_mises_field.size()));
    // v1 omits the 6-component tensor for wire cost (see fields.hpp); the block is
    // still length-prefixed at 0 so a later version can populate it in place.
    w.i64(0);
    w.i64(static_cast<std::int64_t>(v.displacement_field.size()));
    w.f32_array(v.von_mises_field);
    // (no tensor bytes in v1)
    w.f32_array(v.displacement_field);
  }

  // ATOMIC PUBLISH, for the same reason design.bin has one: this file is now
  // flushed after every rung and served over HTTP while a later rung rewrites it,
  // so a reader must see a whole container or the previous one — never a prefix.
  const std::string tmp = path + ".part";
  {
    std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
    if (!out) throw FieldsError("cannot open fields file for writing: " + tmp);
    out.write(reinterpret_cast<const char*>(w.bytes.data()),
              static_cast<std::streamsize>(w.bytes.size()));
    out.flush();
    if (!out) throw FieldsError("failed writing fields file: " + tmp);
  }
  if (std::rename(tmp.c_str(), path.c_str()) != 0) {
    std::remove(tmp.c_str());
    throw FieldsError("failed publishing fields file: " + path);
  }
  return static_cast<int>(accepted.size());
}

int write_scenario_fields_file(const std::string& path,
                               const MinimizePlasticResult& result,
                               const VoxelGrid& solved_grid) {
  std::vector<const MinimizePlasticVariant*> all;
  all.reserve(result.evaluated.size());
  for (const MinimizePlasticVariant& v : result.evaluated) all.push_back(&v);
  return write_scenario_fields_file(path, all, solved_grid);
}

int write_scenario_fields_file(const std::string& path,
                               const std::vector<const MinimizePlasticVariant*>& variants,
                               const VoxelGrid& solved_grid) {
  // fields.bin's blocks: the accepted variants, in order.
  std::vector<const MinimizePlasticVariant*> accepted;
  for (const MinimizePlasticVariant* v : variants)
    if (v && v->accepted) accepted.push_back(v);
  std::size_t scenarios = 0;
  for (const MinimizePlasticVariant* v : accepted)
    scenarios = std::max(scenarios, v->scenario_fields.size());
  if (scenarios < 2 || accepted.empty()) return 0;
  const std::size_t voxel_count = solved_grid.voxel_count();
  const std::size_t node_count = static_cast<std::size_t>(solved_grid.nx + 1) *
                                 static_cast<std::size_t>(solved_grid.ny + 1) *
                                 static_cast<std::size_t>(solved_grid.nz + 1);
  const std::vector<ScenarioFields>& names = accepted.front()->scenario_fields;
  for (const MinimizePlasticVariant* v : accepted) {
    if (v->scenario_fields.size() != scenarios)
      throw FieldsError("scenario_fields.bin: an accepted variant carries " +
                        std::to_string(v->scenario_fields.size()) + " scenarios, not " +
                        std::to_string(scenarios));
    for (std::size_t s = 0; s < scenarios; ++s) {
      const ScenarioFields& f = v->scenario_fields[s];
      if (f.name != names[s].name)
        throw FieldsError("scenario_fields.bin: scenario " + std::to_string(s) +
                          " is \"" + f.name + "\" on one variant, \"" + names[s].name +
                          "\" on another");
      if (f.von_mises.size() != voxel_count || f.displacement.size() != 3 * node_count)
        throw FieldsError("scenario_fields.bin: scenario \"" + f.name +
                          "\"'s fields do not match the grid");
    }
  }

  LEWriter w;
  w.u8(kScenarioFieldsFormatVersion);
  w.pad(3);
  w.i32(solved_grid.nx);
  w.i32(solved_grid.ny);
  w.i32(solved_grid.nz);
  w.f64(solved_grid.origin.x);
  w.f64(solved_grid.origin.y);
  w.f64(solved_grid.origin.z);
  w.f64(solved_grid.spacing);
  w.i32(static_cast<std::int32_t>(scenarios));
  w.i32(static_cast<std::int32_t>(accepted.size()));
  for (const ScenarioFields& f : names) {
    w.i32(static_cast<std::int32_t>(f.name.size()));
    w.bytes.insert(w.bytes.end(), f.name.begin(), f.name.end());
  }
  for (const MinimizePlasticVariant* v : accepted) {
    int governing = -1;
    for (std::size_t s = 0; s < v->report.scenarios.size(); ++s)
      if (v->report.scenarios[s].governs) governing = static_cast<int>(s);
    w.f64(v->requested_volume_fraction);
    w.i32(governing);
    w.pad(4);
    for (const ScenarioFields& f : v->scenario_fields) {
      w.i64(static_cast<std::int64_t>(f.von_mises.size()));
      w.i64(static_cast<std::int64_t>(f.displacement.size()));
      for (const float x : f.von_mises) w.f32(x);
      for (const float x : f.displacement) w.f32(x);
    }
  }

  const std::string tmp = path + ".part";
  {
    std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
    if (!out) throw FieldsError("cannot open scenario fields file for writing: " + tmp);
    out.write(reinterpret_cast<const char*>(w.bytes.data()),
              static_cast<std::streamsize>(w.bytes.size()));
    out.flush();
    if (!out) throw FieldsError("failed writing scenario fields file: " + tmp);
  }
  if (std::rename(tmp.c_str(), path.c_str()) != 0) {
    std::remove(tmp.c_str());
    throw FieldsError("failed publishing scenario fields file: " + path);
  }
  return static_cast<int>(accepted.size());
}

}  // namespace topopt
