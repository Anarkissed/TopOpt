// part_scale.hpp -- is the part big enough for the nozzle to leave the optimiser
// any printable room? (TO rebuild; the maintainer, 2026-11-26: "Definitely a
// pop-up for when a part is too small for the nozzle with a recommendation for
// either a different nozzle size or to switch to resin printing.")
//
// The smallest thing a printer can make in a SOLID part is a wall ONE line wide
// (the maintainer, 2026-11-26: "The 2 beam thickness requirement is only for
// lattices. Printing lattices at a single extrusion thick failed. Printing a
// regular wall would not ... no reason to force the smallest measurement to be
// 0.8mm when we can go as low as 0.4."). To remove anything from a section and
// still leave something printable, the optimiser needs room for two such walls
// and a gap at least as wide between them: THREE line widths. A part whose
// THICKEST section is under that has nowhere a cut could go.
//
// Pure arithmetic; the caller supplies the thickest section (the largest value
// of local_member_thickness_mm over the part as drawn).
#pragma once

#include <cmath>
#include <initializer_list>
#include <limits>
#include <vector>

#include "topopt/voxel.hpp"

namespace topopt {

struct PartScale {
  double thickest_mm = 0.0;        // the part's thickest section
  double line_width_mm = 0.0;      // the job's wall line width
  double needed_mm = 0.0;          // three line widths
  bool too_small = false;          // thickest < needed
  // The largest common nozzle (0.6, 0.4, 0.2 mm: the sizes in wide use, the
  // maintainer 2026-11-26; line width taken as 1.125
  // x nozzle, as 0.45 is to 0.4) on which the part WOULD have room; 0 when even a
  // 0.2 mm nozzle leaves none, and then the advice is resin.
  double nozzle_that_fits_mm = 0.0;
};

// Two one-line walls and a one-line gap.
inline constexpr double kRoomForACutLines = 3.0;

inline PartScale part_scale(double thickest_mm, double line_width_mm) {
  PartScale s;
  s.thickest_mm = thickest_mm;
  s.line_width_mm = line_width_mm > 0.0 ? line_width_mm : 0.45;
  s.needed_mm = kRoomForACutLines * s.line_width_mm;
  s.too_small = thickest_mm < s.needed_mm;  // +infinity (beyond the measure) is never too small
  for (double nozzle : {0.6, 0.4, 0.2})
    if (thickest_mm >= kRoomForACutLines * 1.125 * nozzle) {
      s.nozzle_that_fits_mm = nozzle;
      break;
    }
  return s;
}

// The thickest section of the part AS DRAWN (every non-empty voxel), in mm: the
// largest local_member_thickness_mm. The grid is the part's bounding box, so the
// outside of it is AIR (otherwise a small part lying against the box's faces
// reads as thick as the measure reaches). +infinity = thicker than the measure's
// reach (`cap_radius_voxels`), which is never too small.
inline double thickest_section_mm(const VoxelGrid& grid, int cap_radius_voxels) {
  std::vector<double> drawn(grid.voxel_count(), 0.0);
  for (std::size_t i = 0; i < drawn.size(); ++i)
    if (grid.tags[i] != VoxelTag::Empty) drawn[i] = 1.0;
  double thickest = 0.0;
  for (double t : local_member_thickness_mm(grid, drawn, 0.5, cap_radius_voxels, true))
    if (t > thickest) thickest = t;
  return thickest;
}

// TO rebuild stage 4, piece "member" (a NOTICE ONLY; TOPOPT_STAGE4 contains
// member). Stage 2 measured (ledger A-06) that a member under 8 voxels through,
// in bending, is not read reliably (2 through reads 67 % low, 4: 32 %, 6: 20 %):
// "resolved" = 8 voxels through. This finds the THINNEST printed member of a
// voxel design and the resolution (voxels along the grid's longest side) at which
// it would be 8 through. It changes nothing: not the resolution, not a verdict.
//
// The width is NOT a new algorithm: it is lattice_member_width_mm (voxel.hpp),
// the measure analyze.cpp's thin-member rule reads, with the floor at 8 voxels:
// the largest inscribed ball, the grid's outside void, and the convex edges and
// corners of a thick member JOINED to it (without the join every edge of every
// part reads one or two voxels thin). min_feature_violations (voxelize.cpp) was
// not used: it only says yes or no at 2 voxels and gives no width.
// ITS GRAIN: the ball radius is a whole number of voxels and the width is twice
// it, so a member reads in EVEN voxel counts, an odd one rounded UP (3 through
// reads 4, 7 reads 8).
inline constexpr double kMemberResolvedVoxels = 8.0;

struct ThinMember {
  double thinnest_mm = std::numeric_limits<double>::infinity();
  double voxels_through = std::numeric_limits<double>::infinity();
  bool resolved = true;          // voxels_through >= 8 (or nothing printed)
  int resolution_now = 0;        // voxels along the grid's longest side
  int resolution_needed = 0;     // the same at which the thinnest is 8 through
};

inline ThinMember thin_member(const VoxelGrid& grid, const std::vector<double>& density,
                              double iso, int cap_radius_voxels = 8) {
  ThinMember m;
  const double h = grid.spacing;
  m.resolution_now = grid.nx > grid.ny ? (grid.nx > grid.nz ? grid.nx : grid.nz)
                                       : (grid.ny > grid.nz ? grid.ny : grid.nz);
  m.resolution_needed = m.resolution_now;
  if (!(h > 0.0) || density.size() != grid.voxel_count()) return m;
  const std::vector<double> w = lattice_member_width_mm(
      grid, density, iso, cap_radius_voxels, kMemberResolvedVoxels * h, h);
  for (double t : w)
    if (t > 0.0 && t < m.thinnest_mm) m.thinnest_mm = t;
  if (!std::isfinite(m.thinnest_mm)) return m;
  m.voxels_through = m.thinnest_mm / h;
  m.resolved = m.voxels_through >= kMemberResolvedVoxels - 1e-9;
  if (!m.resolved)
    m.resolution_needed = static_cast<int>(
        std::ceil(m.resolution_now * kMemberResolvedVoxels / m.voxels_through - 1e-9));
  return m;
}

// AUTOMATIC RESOLUTION (the maintainer, 2026-11-26: "The automatic resolution
// from part size is also great", and in Manual mode it stays adjustable).
//
// The resolution is the number of voxels along the part's longest side. Today it
// is a number picked by hand, so a small part gets tiny voxels it does not need
// and a large one gets voxels far wider than anything the printer makes. Auto
// picks the voxel from the PRINTER: one voxel per wall-line width, so the
// smallest printable wall (two lines) is two voxels across at any part size.
// That is capped (memory and time grow with the cube of the resolution) and
// floored (a very small part still needs enough voxels to have a shape).
//   resolution = clamp(ceil(longest side / line width), floor, cap)
// `capped` says the part is too large for a voxel per line at the cap; then
// `voxel_mm` is what it gets, and features under two of those do not resolve.
struct AutoResolution {
  int resolution = 0;
  double voxel_mm = 0.0;
  bool capped = false;
  bool floored = false;
};

inline AutoResolution auto_resolution(double longest_side_mm, double line_width_mm,
                                      int cap = 192, int floor = 32) {
  AutoResolution r;
  const double lw = line_width_mm > 0.0 ? line_width_mm : 0.45;
  if (!(longest_side_mm > 0.0)) return r;
  int n = static_cast<int>(longest_side_mm / lw);
  if (n * lw < longest_side_mm) ++n;
  r.capped = n > cap;
  r.floored = n < floor;
  r.resolution = n > cap ? cap : (n < floor ? floor : n);
  r.voxel_mm = longest_side_mm / r.resolution;
  return r;
}

}  // namespace topopt
