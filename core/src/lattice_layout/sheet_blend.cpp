// SHEETS, the blend band between two sheet regions (notes28 sheets SPEC 1.5): builder E's file. The signature is the
// contract (lattice_layout_mesh.hpp, mesh_sheet_seam_band); until E's band lands every Blend seam falls back to the
// solid wall, and says so.
#include <string>

#include "topopt/lattice_layout_mesh.hpp"

namespace topopt::lattice_layout {

SeamBand mesh_sheet_seam_band(const Domain& domain, const Layout& layout, const std::vector<SheetField>& sheets,
                              const SheetSeamBand& seam, const MeshSpec& spec) {
  (void)domain;
  (void)layout;
  (void)spec;
  SeamBand out;
  out.ok = false;
  const auto name = [](int r) { return r == 0 ? std::string("the whole part") : "region " + std::to_string(r); };
  if (seam.a < 0 || seam.b < 0 || static_cast<std::size_t>(seam.a) >= sheets.size() ||
      static_cast<std::size_t>(seam.b) >= sheets.size()) {
    out.why = "Two lattices meet where no blend could be made, so a solid wall joins them.";
    return out;
  }
  out.why = "The lattices of " + name(seam.region_a) + " and " + name(seam.region_b) +
            " could not be blended into each other, so a solid wall joins them.";
  return out;
}

}  // namespace topopt::lattice_layout
