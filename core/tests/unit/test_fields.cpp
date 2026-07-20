// Handoff 122 — round-trip test for the per-voxel result FIELDS container
// (out/fields.bin, topopt/fields.hpp).
//
// The writer serialises each ACCEPTED variant's von Mises + displacement fields
// and the voxel mass/support summary so a LAN remote run gets the same overlays a
// local run does. This test builds a synthetic MinimizePlasticResult by hand (no
// solver, no Eigen, no OCCT — so it runs in every configuration like the other io
// tests), writes it, then parses the bytes back with an INDEPENDENT little-endian
// reader and asserts every header field, count and float value round-trips. The
// point is to pin the on-disk format the Swift RemoteRunner parser must match; if
// the layout ever drifts, this test — and the app parser test — must move together.
//
// No third-party framework (ARCHITECTURE §4): the self-contained CHECK harness.

#include "topopt/fields.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/voxel.hpp"

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using topopt::FieldsError;
using topopt::kFieldsFormatVersion;
using topopt::MinimizePlasticResult;
using topopt::MinimizePlasticVariant;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;
using topopt::write_fields_file;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

static std::string tmp_path(const std::string& name) {
  return std::string(FIELDS_TMP_DIR) + "/" + name;
}

// ── an independent little-endian reader (NOT the writer's helper) ───────────
struct LEReader {
  const std::uint8_t* p;
  const std::uint8_t* end;
  bool ok = true;

  std::uint8_t u8() {
    if (p + 1 > end) { ok = false; return 0; }
    return *p++;
  }
  void skip(std::size_t n) {
    if (p + n > end) { ok = false; return; }
    p += n;
  }
  template <typename T>
  T scalar() {
    T v{};
    if (p + sizeof(T) > end) { ok = false; return v; }
    std::memcpy(&v, p, sizeof(T));
    p += sizeof(T);
    return v;
  }
  std::int32_t i32() { return scalar<std::int32_t>(); }
  std::int64_t i64() { return scalar<std::int64_t>(); }
  float f32() { return scalar<float>(); }
  double f64() { return scalar<double>(); }
};

// A grid whose voxels are all Interior, given dims/spacing/origin.
static VoxelGrid make_grid(int nx, int ny, int nz, double h, Vec3 origin) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = origin;
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

// Build a synthetic accepted variant whose fields are sized to `grid` and filled
// with deterministic, distinguishable values so the round-trip catches any
// index/offset error.
static MinimizePlasticVariant make_variant(const VoxelGrid& g, double req_vf,
                                          double mass, int support, float seed) {
  const std::size_t voxels = g.voxel_count();
  const std::size_t nodes = static_cast<std::size_t>(g.nx + 1) *
                            static_cast<std::size_t>(g.ny + 1) *
                            static_cast<std::size_t>(g.nz + 1);
  MinimizePlasticVariant v;
  v.accepted = true;
  v.requested_volume_fraction = req_vf;
  v.mass_grams = mass;
  v.support_volume_voxels = support;
  v.von_mises_field.resize(voxels);
  for (std::size_t i = 0; i < voxels; ++i)
    v.von_mises_field[i] = seed + static_cast<float>(i);
  v.displacement_field.resize(3 * nodes);
  for (std::size_t i = 0; i < 3 * nodes; ++i)
    v.displacement_field[i] = -seed - static_cast<float>(i) * 0.5f;
  return v;
}

int main() {
  const VoxelGrid grid = make_grid(3, 2, 2, 2.5, Vec3{1.0, -2.0, 0.5});
  const std::size_t voxels = grid.voxel_count();                 // 12
  const std::size_t nodes = 4u * 3u * 3u;                        // 36
  CHECK(voxels == 12, "grid voxel count");

  MinimizePlasticResult result;
  // One accepted, one rejected (NOT accepted, must be skipped), one accepted.
  result.evaluated.push_back(make_variant(grid, 0.68, 12.5, 7, 100.0f));
  MinimizePlasticVariant rejected = make_variant(grid, 0.52, 9.0, 3, 200.0f);
  rejected.accepted = false;   // a rejected/terminal rung is NOT serialised
  result.evaluated.push_back(rejected);
  result.evaluated.push_back(make_variant(grid, 0.38, 6.25, 0, 300.0f));
  result.solved_grid = grid;

  const std::string path = tmp_path("fields.bin");
  int written = 0;
  try {
    written = write_fields_file(path, result, grid);
  } catch (const FieldsError& e) {
    std::fprintf(stderr, "write_fields_file threw: %s\n", e.what());
    return 1;
  }
  CHECK(written == 2, "two accepted variants written (rejected skipped)");

  std::ifstream in(path, std::ios::binary);
  CHECK(in.good(), "fields.bin opened for read");
  std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(in)),
                                  std::istreambuf_iterator<char>());
  in.close();
  CHECK(!bytes.empty(), "fields.bin is non-empty");

  LEReader r{bytes.data(), bytes.data() + bytes.size()};
  // -- run header --
  CHECK(r.u8() == kFieldsFormatVersion, "version byte is first and correct");
  r.skip(3);
  CHECK(r.i32() == 3, "grid_nx");
  CHECK(r.i32() == 2, "grid_ny");
  CHECK(r.i32() == 2, "grid_nz");
  CHECK(r.f64() == 1.0, "origin_x");
  CHECK(r.f64() == -2.0, "origin_y");
  CHECK(r.f64() == 0.5, "origin_z");
  CHECK(r.f64() == 2.5, "spacing");
  CHECK(r.f64() == 2.5 * 2.5 * 2.5, "voxel_volume_mm3");
  const std::int32_t vcount = r.i32();
  CHECK(vcount == 2, "variant_count in header");
  r.skip(4);

  // -- variant blocks (the two accepted ones, in order) --
  struct Expect { double vf; double mass; int support; float seed; };
  const Expect expects[2] = {{0.68, 12.5, 7, 100.0f}, {0.38, 6.25, 0, 300.0f}};
  for (int b = 0; b < 2; ++b) {
    const Expect& e = expects[b];
    CHECK(r.f64() == e.vf, "block requested_volume_fraction");
    CHECK(r.f64() == e.mass, "block mass_grams");
    CHECK(r.i32() == e.support, "block support_volume_voxels");
    r.skip(4);
    const std::int64_t vm = r.i64();
    const std::int64_t st = r.i64();
    const std::int64_t disp = r.i64();
    CHECK(vm == static_cast<std::int64_t>(voxels), "von_mises_count == voxel count");
    CHECK(st == 0, "stress_tensor_count is 0 in v1");
    CHECK(disp == static_cast<std::int64_t>(3 * nodes), "displacement_count == 3*nodes");
    bool vm_ok = true;
    for (std::size_t i = 0; i < voxels; ++i)
      if (r.f32() != e.seed + static_cast<float>(i)) vm_ok = false;
    CHECK(vm_ok, "von Mises values round-trip in order");
    bool disp_ok = true;
    for (std::size_t i = 0; i < 3 * nodes; ++i)
      if (r.f32() != -e.seed - static_cast<float>(i) * 0.5f) disp_ok = false;
    CHECK(disp_ok, "displacement values round-trip in order");
  }
  CHECK(r.ok, "reader consumed the container without overrun");
  CHECK(r.p == r.end, "no trailing bytes (exact size)");

  // -- empty run: a valid header with variant_count 0 (no accepted variants) --
  MinimizePlasticResult empty;
  empty.solved_grid = grid;
  const std::string epath = tmp_path("fields_empty.bin");
  int ew = -1;
  try {
    ew = write_fields_file(epath, empty, grid);
  } catch (const FieldsError& e) {
    std::fprintf(stderr, "empty write threw: %s\n", e.what());
    return 1;
  }
  CHECK(ew == 0, "empty run writes 0 variants");
  std::ifstream ein(epath, std::ios::binary);
  std::vector<std::uint8_t> ebytes((std::istreambuf_iterator<char>(ein)),
                                   std::istreambuf_iterator<char>());
  LEReader er{ebytes.data(), ebytes.data() + ebytes.size()};
  CHECK(er.u8() == kFieldsFormatVersion, "empty: version byte");
  er.skip(3 + 12 + 8 * 5);   // reserved + dims + 5 doubles
  CHECK(er.i32() == 0, "empty: variant_count 0");
  er.skip(4);
  CHECK(er.p == er.end, "empty: header only, no blocks");

  // -- size guard: an accepted variant whose field size disagrees must throw --
  MinimizePlasticResult bad;
  MinimizePlasticVariant badv = make_variant(grid, 0.5, 1.0, 1, 1.0f);
  badv.von_mises_field.pop_back();   // now mis-sized vs the grid
  bad.evaluated.push_back(badv);
  bad.solved_grid = grid;
  bool threw = false;
  try {
    write_fields_file(tmp_path("fields_bad.bin"), bad, grid);
  } catch (const FieldsError&) {
    threw = true;
  }
  CHECK(threw, "mis-sized accepted field throws FieldsError, not a corrupt file");

  std::fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
