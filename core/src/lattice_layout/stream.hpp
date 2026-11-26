// notes30 (option D, his 2026-11-26: "The strut engine hands over its struts while it works, the way Organic's engine
// does, so the floors rise in step with the real work."): the strut stream's own parts, private to core's lattice layout.
// The plan: agent-scratch/organic1/notes30/strut-stream/scope.md (3.2); the API: notes30/strut-stream/api.md.
#pragma once

#include <atomic>
#include <cstddef>
#include <memory>
#include <vector>

#include "topopt/lattice_layout.hpp"

namespace topopt::lattice_layout {

// C4: the solid view's map for `layout` in `domain` (the bridge's lattice_layout_grid, byte for byte): every voxel of
// `ask` on `threads` (0: all). Null when `stop` is set part way.
std::shared_ptr<LayoutMap> make_layout_map(const Layout& layout, const Domain& domain, const MapAsk& ask, int threads,
                                           const std::atomic<bool>* stop);

}  // namespace topopt::lattice_layout
