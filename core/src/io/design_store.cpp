#include "topopt/design_store.hpp"

#include <cstdint>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace topopt {
namespace {

// Little-endian byte sink / source. Same discipline as fields.cpp: the format is
// fixed little-endian and serialised byte-by-byte, so it is immune to struct
// padding and correct on a big-endian host too.
struct LEWriter {
  std::vector<std::uint8_t> bytes;

  void u8(std::uint8_t v) { bytes.push_back(v); }
  void pad(int n) {
    for (int i = 0; i < n; ++i) bytes.push_back(0);
  }
  void i32(std::int32_t v) { raw(&v, sizeof(v)); }
  void i64(std::int64_t v) { raw(&v, sizeof(v)); }
  void u64(std::uint64_t v) { raw(&v, sizeof(v)); }
  void f64(double v) { raw(&v, sizeof(v)); }
  void f64_array(const std::vector<double>& src) {
    for (const double d : src) f64(d);
  }

 private:
  void raw(const void* p, std::size_t n) {
    const auto* b = static_cast<const std::uint8_t*>(p);
    bytes.insert(bytes.end(), b, b + n);
  }
};

struct LEReader {
  const std::vector<std::uint8_t>& bytes;
  std::size_t at = 0;

  void need(std::size_t n) const {
    if (at + n > bytes.size())
      throw DesignStoreError(
          "design.bin: truncated container (wanted " + std::to_string(n) +
          " more bytes at offset " + std::to_string(at) + " of " +
          std::to_string(bytes.size()) + ")");
  }
  std::uint8_t u8() {
    need(1);
    return bytes[at++];
  }
  void skip(std::size_t n) {
    need(n);
    at += n;
  }
  std::int32_t i32() { return raw<std::int32_t>(); }
  std::int64_t i64() { return raw<std::int64_t>(); }
  std::uint64_t u64() { return raw<std::uint64_t>(); }
  double f64() { return raw<double>(); }

 private:
  template <typename T>
  T raw() {
    need(sizeof(T));
    T v;
    std::memcpy(&v, bytes.data() + at, sizeof(T));
    at += sizeof(T);
    return v;
  }
};

}  // namespace

std::uint64_t design_fingerprint(const std::vector<double>& density) {
  // FNV-1a 64. Hashed over the little-endian IEEE-754 bytes of each element, so
  // the number is a property of the FIELD, not of a host's struct layout.
  std::uint64_t h = 1469598103934665603ULL;
  for (const double d : density) {
    std::uint8_t buf[sizeof(double)];
    std::memcpy(buf, &d, sizeof(double));
    for (const std::uint8_t b : buf) {
      h ^= static_cast<std::uint64_t>(b);
      h *= 1099511628211ULL;
    }
  }
  return h;
}

int write_design_file(const std::string& path,
                      const MinimizePlasticResult& result,
                      const VoxelGrid& solved_grid) {
  const std::size_t voxel_count = solved_grid.voxel_count();

  std::vector<const MinimizePlasticVariant*> blocks;
  for (const MinimizePlasticVariant& v : result.evaluated)
    if (!v.optimization.physical_density.empty()) blocks.push_back(&v);

  LEWriter w;
  w.u8(kDesignFormatVersion);
  w.pad(3);
  w.i32(solved_grid.nx);
  w.i32(solved_grid.ny);
  w.i32(solved_grid.nz);
  w.f64(solved_grid.origin.x);
  w.f64(solved_grid.origin.y);
  w.f64(solved_grid.origin.z);
  w.f64(solved_grid.spacing);
  w.i32(static_cast<std::int32_t>(blocks.size()));
  w.pad(4);

  for (const MinimizePlasticVariant* vp : blocks) {
    const MinimizePlasticVariant& v = *vp;
    const std::vector<double>& d = v.optimization.physical_density;
    if (d.size() != voxel_count)
      throw DesignStoreError(
          "design.bin: variant density size " + std::to_string(d.size()) +
          " != grid voxel count " + std::to_string(voxel_count));
    w.f64(v.requested_volume_fraction);
    w.f64(v.optimization.volume_fraction);
    w.f64(v.report.margin.worst_case);
    w.f64(v.report.margin_effective);
    w.f64(v.report.max_stress_mpa);
    w.i32(v.accepted ? 1 : 0);
    w.i32(static_cast<std::int32_t>(v.optimization.iterations));
    w.f64(v.applied_build_dir.x);
    w.f64(v.applied_build_dir.y);
    w.f64(v.applied_build_dir.z);
    w.i32(v.build_direction_auto_applied ? 1 : 0);
    w.i32(v.export_baked ? 1 : 0);
    w.u64(design_fingerprint(d));
    w.i64(static_cast<std::int64_t>(d.size()));
    w.f64_array(d);
  }

  std::ofstream out(path, std::ios::binary);
  if (!out)
    throw DesignStoreError("cannot open design file for writing: " + path);
  out.write(reinterpret_cast<const char*>(w.bytes.data()),
            static_cast<std::streamsize>(w.bytes.size()));
  out.flush();
  if (!out) throw DesignStoreError("failed writing design file: " + path);
  return static_cast<int>(blocks.size());
}

DesignStore read_design_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw DesignStoreError("cannot open design file: " + path);
  std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(in)),
                                  std::istreambuf_iterator<char>());
  if (!in.eof() && in.fail())
    throw DesignStoreError("failed reading design file: " + path);

  LEReader r{bytes};
  const std::uint8_t version = r.u8();
  if (version != kDesignFormatVersion)
    throw DesignStoreError("design.bin: unrecognised version " +
                           std::to_string(static_cast<int>(version)) +
                           " (this build reads version " +
                           std::to_string(static_cast<int>(
                               kDesignFormatVersion)) +
                           ")");
  r.skip(3);

  DesignStore st;
  st.nx = r.i32();
  st.ny = r.i32();
  st.nz = r.i32();
  st.origin.x = r.f64();
  st.origin.y = r.f64();
  st.origin.z = r.f64();
  st.spacing = r.f64();
  const std::int32_t count = r.i32();
  r.skip(4);
  if (st.nx <= 0 || st.ny <= 0 || st.nz <= 0 || count < 0)
    throw DesignStoreError("design.bin: nonsensical header (dims " +
                           std::to_string(st.nx) + "x" + std::to_string(st.ny) +
                           "x" + std::to_string(st.nz) + ", " +
                           std::to_string(count) + " variants)");

  const std::size_t voxels = st.voxel_count();
  for (std::int32_t i = 0; i < count; ++i) {
    StoredDesign sd;
    sd.requested_volume_fraction = r.f64();
    sd.achieved_volume_fraction = r.f64();
    sd.margin_worst_case = r.f64();
    sd.margin_effective = r.f64();
    sd.max_von_mises_mpa = r.f64();
    sd.accepted = r.i32() != 0;
    sd.iterations = static_cast<int>(r.i32());
    sd.applied_build_dir.x = r.f64();
    sd.applied_build_dir.y = r.f64();
    sd.applied_build_dir.z = r.f64();
    sd.build_direction_auto_applied = r.i32() != 0;
    sd.export_baked = r.i32() != 0;
    sd.fingerprint = r.u64();
    const std::int64_t n = r.i64();
    if (n < 0 || static_cast<std::size_t>(n) != voxels)
      throw DesignStoreError(
          "design.bin: variant " + std::to_string(i) + " density count " +
          std::to_string(n) + " != header voxel count " +
          std::to_string(voxels));
    sd.density.resize(voxels);
    for (std::size_t e = 0; e < voxels; ++e) sd.density[e] = r.f64();
    // The fingerprint is not decoration: a design that does not hash to what was
    // recorded must never reach the gate, because the certificate would then
    // describe a field nobody stored.
    const std::uint64_t fp = design_fingerprint(sd.density);
    if (fp != sd.fingerprint)
      throw DesignStoreError(
          "design.bin: variant " + std::to_string(i) +
          " density does not match its recorded fingerprint (stored " +
          std::to_string(sd.fingerprint) + ", computed " + std::to_string(fp) +
          ") — the stored design is corrupt and will NOT be certified");
    st.variants.push_back(std::move(sd));
  }
  return st;
}

}  // namespace topopt
