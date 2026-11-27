// FlexibleKit+Mask — core's lattice MASK for the shape-only lattice (task
// 2026-09-29-flexible-screens, round 3 batch B, item 9).
//
// ★ NO NEW BRIDGE CODE. The plan budgeted a `flexible_scene_mask_field` accessor in
// flexible_bridge.cpp; it is not needed: the existing `flexible_scene_density_field` with NO
// faces runs core's `assemble_density_field(grid, mask, {}, build)`, which writes 0 on every
// voxel of the scene's own `mask` (core's `flexible_region_mask`) and −1 everywhere else —
// the mask itself, from the same vector `lattice_voxels` counts. One route, core's.

import Foundation

extension FlexibleScene {
    /// Core's lattice mask on its grid: density 0 on every lattice voxel, −1 elsewhere
    /// (`FlexDensityField`, x fastest, origin = the grid's corner).
    public func latticeMask(build: FlexBuildParams) throws -> FlexDensityField {
        try densityField(faces: [], rotations: [], build: build)
    }
}
