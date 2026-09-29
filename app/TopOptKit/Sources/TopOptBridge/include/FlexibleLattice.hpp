// FlexibleLattice — the Flexible lattice's C++ copy and its streaming STL exporter
// (task 2026-09-29-flexible-screens, overnight round).
//
// ★ THE APP IS THE SOURCE OF TRUTH FOR THIS GEOMETRY (maintainer, 2026-09-29: "there is
// no core yet for Flexibles, so your preview will be the source of truth"). The field is
// DEFINED in FlexibleLatticeField.swift; `flx_field_lattice` / `flx_field_solid` in
// flexible_lattice.cpp are line-for-line ports of `.lattice(at:)` / `.solid(at:)`, and
// `FlexibleLatticeExportTests` samples both at the same points and fails if they
// disagree. A change to the field is made in all three copies (Swift, MSL, here).
//
// ★ WHY C++ AND NOT SWIFT. The export evaluates the field at every sample of a grid
// at h = t/2.5 over the whole part (10⁷–10⁸ samples on a real pad) and writes
// millions of triangles; the octet writer's rule (03-generators §7) is to STREAM:
// two sample layers in memory, triangles straight to the file, flat RSS. The Swift
// caller drives it slab by slab so it can show progress and cancel.
//
// Conventions as FlexibleBridge.hpp: namespace topoptbridge, POD structs, std::vector,
// errors through BridgeError. No core type appears here (there is no core for this).
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "TopOptBridge.hpp"  // BridgeError

namespace topoptbridge {

// Named vector type so Swift can spell it.
using FlexFloats = std::vector<float>;

// A Swift [Float] → std::vector<float> in ONE copy. ★ Building a vector with
// push_back per element, or reading a vector member element by element from Swift,
// goes through the interop per element (and a member read COPIES the whole vector
// each time, measured 2026-09-29); a 128³ grid is two million of them.
FlexFloats flex_floats_from(const float* values, std::size_t n);

// One FlexGrid (FlexibleLatticeField.swift): VOXEL-CENTRE convention, value (i,j,k)
// at c0 + (i,j,k)·spacing, x fastest; sampled trilinearly with the continuous index
// clamped to [0, n−1] per axis.
struct FlexScalarGrid {
  int32_t nx = 0, ny = 0, nz = 0;
  float c0[3] = {0, 0, 0};
  float spacing = 1.0f;
  std::vector<float> values;  // nx·ny·nz
};

// FlexibleLatticeInputs, as POD.
struct FlexLatticeGrids {
  int32_t topology = 0;  // 0 gyroid, 1 honeycomb
  float wall_mm = 0.0f;  // t
  float l_min_mm = 0.0f, l_max_mm = 0.0f;  // gyroid cell clamp
  float honeycomb_cell_mm = 0.0f;          // uniform d
  float build_dir[3] = {0, 0, 1};
  float skin_mm = 0.0f;
  FlexScalarGrid rho, mask, part_sdf, skin_dist;
  float bounds_min[3] = {0, 0, 0};
  float bounds_max[3] = {0, 0, 0};
};

// "" when the grids can be evaluated, else the sentence why not.
std::string flexible_lattice_grids_error(const FlexLatticeGrids& f);

// The field at one model point (mm; negative = inside). Ports of
// FlexibleLatticeField.lattice(at:) (what the preview draws) and .solid(at:) (what the
// export writes). The grids must be valid (see flexible_lattice_grids_error).
float flx_field_lattice(const FlexLatticeGrids& f, float x, float y, float z);
float flx_field_solid(const FlexLatticeGrids& f, float x, float y, float z);

// Both fields at many points, for the agreement test: `xyz` flattened, one value per
// point. `which` 0 = lattice, 1 = solid. Invalid grids ⇒ empty.
std::vector<float> flexible_lattice_field_values(const FlexLatticeGrids& f,
                                                 const std::vector<float>& xyz, int32_t which);

// ---------------------------------------------------------------------------
// THE EXPORT. The sample grid is the part bounds padded by 2h on every side, samples
// AT the grid points (x_i = bounds_min − 2h + i·h); every sample on the outermost
// layer is taken as OUTSIDE (+h) so the surface is always closed. Marching cubes over
// solid(at:), binary STL, outward winding.

// What an export at pitch h would cost, BEFORE running it: sample counts, and a
// rough triangle count from a quasi-random probe of the cubes (the crossing share ×
// the mean triangles of a crossed cube × every cube). Rough: ± ~10 % on a lattice.
struct FlexExportEstimate {
  int32_t nx = 0, ny = 0, nz = 0;  // samples per axis
  int64_t samples = 0;
  int64_t cubes = 0;
  int64_t probed_cubes = 0;
  double crossing_fraction = 0.0;  // share of probed cubes the surface crosses
  int64_t triangles = 0;
  int64_t bytes = 0;  // 84 + 50 · triangles
};
FlexExportEstimate flexible_lattice_export_estimate(const FlexLatticeGrids& f, double h_mm);

// Opens `path` (created/truncated), writes the header and a placeholder count, and
// keeps a COPY of the grids. Returns a handle > 0, or 0 with `err` filled.
int64_t flexible_lattice_export_begin(const FlexLatticeGrids& f, double h_mm,
                                      const std::string& path, BridgeError& err);

// March up to `slabs` more z-slabs (one slab = the cubes between two sample layers);
// returns the slabs still to do (0 = all marched), or −1 with `err` filled.
int32_t flexible_lattice_export_step(int64_t handle, int32_t slabs, BridgeError& err);

// Where an export stands, and what it holds. ★ `sample_floats_peak` is the most
// sample storage it ever held: two layers (2 · slab_floats), never the grid.
struct FlexExportStatus {
  int32_t nx = 0, ny = 0, nz = 0;
  int32_t slabs_total = 0;  // nz − 1
  int32_t slabs_done = 0;
  int64_t triangles = 0;    // written so far
  int64_t slab_floats = 0;  // nx · ny: one sample layer
  int64_t sample_floats_allocated = 0;
  int64_t sample_floats_peak = 0;
  int64_t write_buffer_bytes = 0;
};
FlexExportStatus flexible_lattice_export_status(int64_t handle, BridgeError& err);

struct FlexExportResult {
  int64_t triangles = 0;
  int64_t bytes = 0;  // the file's length: 84 + 50 · triangles
  int32_t nx = 0, ny = 0, nz = 0;
};
// Marches any slabs left, patches the triangle count, closes the file and releases
// the handle. On failure the partial file is deleted.
FlexExportResult flexible_lattice_export_finish(int64_t handle, BridgeError& err);

// Closes and DELETES the partial file and releases the handle. Unknown handle: no-op.
void flexible_lattice_export_cancel(int64_t handle);

}  // namespace topoptbridge
