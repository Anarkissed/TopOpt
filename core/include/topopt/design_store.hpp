#pragma once

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/pipeline.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// Task 2026-08-02-lattice-a-variant — the per-variant DESIGN container
// (out/design.bin).
//
// WHY IT EXISTS. "Pick a finished variant and lattice it" needs the variant's
// DENSITY FIELD, and nothing on disk carried it. A run wrote, per accepted
// rung: the iso-surface MESH (variant_*.stl), the scalar report (report.json)
// and the per-voxel RESULT fields (fields.bin — von Mises / displacement).
// The DESIGN itself — the field the optimizer converged on and the gate
// certified — existed only in memory and was dropped when the process exited.
//
// That is why the maintainer's workaround was "export the STL and re-import
// it": the mesh was the only surviving record of the design. Re-importing is
// lossy in exactly the ways that matter here — the iso-surface is a 0.5-level
// crossing of a GRAYSCALE field, so a re-voxelization is a DIFFERENT design,
// and the certificate the gate then issues describes that different object.
// This container stores the field itself so the re-lattice path certifies and
// exports the SAME design the run produced, bit for bit.
//
// *** WHY THE DENSITY IS f64 AND NOT f32. *** fields.bin narrows its RESULT
// arrays to float32 deliberately (they are display data, and the bridge already
// narrows them). This container must NOT: the stored field is fed straight back
// into analyze_fixed_design, and the reproduction check the re-lattice path
// enforces (the restored design must reproduce the variant's RECORDED margin
// bit-for-bit, or the job refuses) is only meaningful if the field survives the
// round trip exactly. A narrowed field would reproduce a margin that is merely
// close, which is precisely the "plausible but wrong" class this codebase
// rejects everywhere else.
//
// *** WHICH FRAME. *** The MODEL frame, like fields.bin and for the same
// reason: the design is indexed to the solved grid, and that grid never moves.
// The exported meshes may be rotated onto the certified build direction; this
// container is not.
//
// FORMAT (design.bin v1). All integers/floats little-endian; the VERSION BYTE
// is first and a reader MUST check it before anything else.
//
//   run header
//     u8    version            = kDesignFormatVersion (1)
//     u8    reserved[3]        (0)
//     i32   grid_nx            solved-grid dims (the grid the field indexes to)
//     i32   grid_ny
//     i32   grid_nz
//     f64   grid_origin_x      solved-grid minimum corner (mm)
//     f64   grid_origin_y
//     f64   grid_origin_z
//     f64   spacing            cubic voxel edge (mm)
//     i32   variant_count      number of variant blocks that follow
//     i32   reserved           (0)
//
//   per variant (variant_count of these, in ladder order)
//     f64   requested_volume_fraction  the ladder rung — the app's join key
//     f64   achieved_volume_fraction   optimization.volume_fraction (continuous)
//     f64   margin_worst_case          the RECORDED solid margin of this variant
//     f64   margin_effective           the RECORDED gated margin
//     f64   max_von_mises_mpa          the RECORDED peak von Mises (MPa)
//     i32   accepted                   0/1, the RECORDED verdict
//     i32   iterations                 optimizer iterations that produced it
//     f64   applied_build_dir_x        THE ORIENTATION THIS VARIANT WAS
//     f64   applied_build_dir_y        CERTIFIED IN (model frame) — see below
//     f64   applied_build_dir_z
//     i32   build_direction_auto_applied  0/1 (the orientation was CHOSEN)
//     i32   export_baked                  0/1 (its mesh was rotated onto +Z)
//     u64   fingerprint                FNV-1a over the density bytes below
//     i64   density_count              == grid.voxel_count()
//     f64[density_count]               the physical density field, grid-indexed
//
// *** WHY THE BUILD DIRECTION IS STORED. *** The recorded margin is a margin AT
// AN ORIENTATION: the interlayer term is evaluated against the build direction.
// A run that let the scorer CHOOSE an orientation (bake "auto" with no declared
// direction) certified at the chosen one, and a later re-certification that
// re-derived the direction from gravity would reproduce a different number and
// refuse for a reason that has nothing to do with the design. Storing what was
// applied makes the re-certification ask the same question the run answered.
//
// SIZE at 128^3: 16.8 MB / variant (double precision, deliberately — see above).
// A 4-rung ladder is ~67 MB, alongside fields.bin's ~136 MB.

class DesignStoreError : public std::runtime_error {
 public:
  explicit DesignStoreError(const std::string& msg)
      : std::runtime_error(msg) {}
};

inline constexpr std::uint8_t kDesignFormatVersion = 1;

// The design FINGERPRINT — FNV-1a (64-bit) over the raw little-endian bytes of
// the density field. ONE definition, so "the field that was stored", "the field
// that was certified" and "the field the exported mesh was built from" are
// comparable as a single number rather than by inspection. Bar Z3's mechanism.
std::uint64_t design_fingerprint(const std::vector<double>& density);

// One variant's stored design.
struct StoredDesign {
  double requested_volume_fraction = 0.0;
  double achieved_volume_fraction = 0.0;
  double margin_worst_case = 0.0;
  double margin_effective = 0.0;
  double max_von_mises_mpa = 0.0;
  bool accepted = false;
  int iterations = 0;
  // The orientation this variant was CERTIFIED in (model frame) and how its
  // mesh was exported — see the format note above.
  Vec3 applied_build_dir{0.0, 0.0, 1.0};
  bool build_direction_auto_applied = false;
  bool export_baked = false;
  std::uint64_t fingerprint = 0;
  std::vector<double> density;  // size == grid.voxel_count()
};

// A whole design.bin, read back.
struct DesignStore {
  int nx = 0, ny = 0, nz = 0;
  Vec3 origin{0.0, 0.0, 0.0};
  double spacing = 0.0;
  std::vector<StoredDesign> variants;

  std::size_t voxel_count() const {
    return static_cast<std::size_t>(nx) * static_cast<std::size_t>(ny) *
           static_cast<std::size_t>(nz);
  }
};

// Write the design container for `result`'s EVALUATED variants that carry a
// density field, indexed to `solved_grid`. EVERY evaluated variant with a field
// is written, not just the accepted ones: a rejected rung is still a design a
// user may want to inspect or lattice, and dropping it would repeat the
// analyze-route mistake fields.bin had to fix (a field computed and then thrown
// away exactly when it mattered). The RECORDED verdict travels with each block.
//
// Returns the number of blocks written. Throws DesignStoreError if the file
// cannot be written, or if a variant's density size disagrees with the grid (a
// bug — fail loudly rather than ship a container a reader would misindex).
int write_design_file(const std::string& path,
                      const MinimizePlasticResult& result,
                      const VoxelGrid& solved_grid);

// Read a design.bin. Throws DesignStoreError on an unreadable file, an
// unrecognised version, a truncated/inconsistent container, or a block whose
// stored fingerprint does not match its density bytes (a corrupted design must
// never be certified — the whole point of the fingerprint).
DesignStore read_design_file(const std::string& path);

}  // namespace topopt
