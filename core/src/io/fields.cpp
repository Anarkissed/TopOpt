#include "topopt/fields.hpp"

#include <cstdint>
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
                      const VoxelGrid& solved_grid) {
  const std::size_t voxel_count = solved_grid.voxel_count();
  // Node count of the structured hex grid = (nx+1)(ny+1)(nz+1), the same value
  // fea_node_count returns (assembly.cpp). Computed inline so this always-built io
  // source carries no dependency on the Eigen-gated FEA translation unit.
  const std::size_t node_count =
      static_cast<std::size_t>(solved_grid.nx + 1) *
      static_cast<std::size_t>(solved_grid.ny + 1) *
      static_cast<std::size_t>(solved_grid.nz + 1);

  // Count the accepted variants first (the header carries the count).
  std::vector<const MinimizePlasticVariant*> accepted;
  for (const MinimizePlasticVariant& v : result.evaluated)
    if (v.accepted) accepted.push_back(&v);

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

  std::ofstream out(path, std::ios::binary);
  if (!out) throw FieldsError("cannot open fields file for writing: " + path);
  out.write(reinterpret_cast<const char*>(w.bytes.data()),
            static_cast<std::streamsize>(w.bytes.size()));
  out.flush();
  if (!out) throw FieldsError("failed writing fields file: " + path);
  return static_cast<int>(accepted.size());
}

}  // namespace topopt
