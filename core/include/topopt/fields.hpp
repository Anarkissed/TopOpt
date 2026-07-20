#pragma once

#include <cstdint>
#include <stdexcept>
#include <string>

#include "topopt/pipeline.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// Handoff 122 — the per-voxel result FIELDS container (out/fields.bin).
//
// WHY: a LAN remote run (tools/topopt-worker + app RemoteRunner) receives each
// accepted variant's MESH + the scalar report.json, but NOT the per-voxel arrays
// the results overlays consume — so the stress overlay, flex/deflection, the
// load-path overlay and the voxel mass all rendered "n/a — computed on Mac"
// (handoff 097). This container serialises exactly those arrays so a remote run
// lights up the same overlays a local run does. It is an ADDITIVE artifact: the
// CLI writes it after a run alongside the meshes; older readers ignore it.
//
// FORMAT (fields.bin v1). All integers/floats little-endian. The VERSION BYTE is
// first so the schema can evolve; a reader MUST check it before anything else.
// The container is ONE run-level header (the solved grid the fields index to)
// followed by one block per ACCEPTED variant. Byte layout:
//
//   run header
//     u8    version            = kFieldsFormatVersion (1)
//     u8    reserved[3]        (0)                  -- pad the header to 4 bytes
//     i32   grid_nx            solved-grid dims (the grid every field indexes to)
//     i32   grid_ny
//     i32   grid_nz
//     f64   grid_origin_x      solved-grid minimum corner (mm)
//     f64   grid_origin_y
//     f64   grid_origin_z
//     f64   spacing            cubic voxel edge (mm)
//     f64   voxel_volume_mm3   spacing^3, carried so the app need not recompute
//     i32   variant_count      number of accepted-variant blocks that follow
//     i32   reserved           (0)
//
//   per accepted variant (variant_count of these, in ladder order)
//     f64   requested_volume_fraction   the ladder rung — the app's join key
//     f64   mass_grams                  printed mass (g); scalar summary
//     i32   support_volume_voxels       support proxy count; scalar summary
//     i32   reserved                    (0)
//     i64   von_mises_count             == grid.voxel_count()  (or 0 if absent)
//     i64   stress_tensor_count         == 6*voxel_count       (0 in v1, see below)
//     i64   displacement_count          == 3*fea_node_count    (or 0 if absent)
//     f32[von_mises_count]              per-voxel von Mises (MPa), grid-indexed
//     f32[stress_tensor_count]          per-voxel Cauchy tensor, Voigt (empty v1)
//     f32[displacement_count]           per-node displacement (mm), DOF-ordered
//
// The three arrays are stored as float32 — the SAME narrowing the bridge applies
// (OptimizeVariant carries std::vector<float>), so the wire bytes are identical
// to what the app consumes locally, not an approximation.
//
// SIZE (v1, at 128^3): von Mises 128^3*4 = 8.4 MB; displacement 3*129^3*4 =
// 25.8 MB; scalars ~52 B. ~34.1 MB / accepted variant; a 4-rung ladder ~136 MB.
// The 6-component stress tensor (another ~50 MB/variant) is DELIBERATELY omitted
// in v1: only the load->anchor flow sub-mode consumes it, and it is 60% of the
// wire cost. The block is still length-prefixed (stress_tensor_count) so a later
// version can populate it with NO format change. See the handoff for the wire
// budget.

class FieldsError : public std::runtime_error {
 public:
  explicit FieldsError(const std::string& msg) : std::runtime_error(msg) {}
};

// The version byte written at the head of fields.bin. Bump when the schema
// changes; readers reject an unrecognised version rather than misparse.
inline constexpr std::uint8_t kFieldsFormatVersion = 1;

// Write the fields container for `result`'s ACCEPTED variants to `path`, indexed
// to `solved_grid` (result.solved_grid — the grid the variants' von_mises /
// displacement fields are sized to). Only accepted variants are serialised (a
// cancelled/rejected terminal rung's fields are default-constructed and not part
// of the results the app shows). Writes the v1 format above. Throws FieldsError
// if the file cannot be opened/written, or if an accepted variant's field sizes
// disagree with the grid (a bug — better to fail loudly than ship a corrupt
// container the app would misindex). Returns the number of accepted variants
// written (0 writes a valid header with variant_count 0).
int write_fields_file(const std::string& path,
                      const MinimizePlasticResult& result,
                      const VoxelGrid& solved_grid);

}  // namespace topopt
