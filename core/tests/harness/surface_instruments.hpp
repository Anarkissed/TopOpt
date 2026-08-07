// surface_instruments.hpp — THE S3 GEOMETRY INSTRUMENTS of task
// 2026-08-06-smoothing-operator-bakeoff (PR 306), lifted VERBATIM out of
// `operator_bakeoff_probe.cpp` so a second probe is judged by LITERALLY THE SAME
// CODE rather than by a re-implementation that agrees "in spirit".
//
// This is the same move `stairstep_metric.hpp` records for PR 299's metric, made
// for the same reason and under the same rule: task
// 2026-08-08-smoothing-that-works-and-is-usable has to compare its cut-population
// readings with PR 306's dumbbell readings, and re-typing the minimum
// cross-section, the slice-area instrument or the design-box excursion would put
// a silent discrepancy exactly where the comparison lives.
//
// NOTHING BELOW IS EDITED. It is PR 306's text and code, unchanged, and
// `operator_bakeoff_probe.cpp` now includes this file and defines none of these
// symbols itself. Its output is byte-identical across the move — see
// evidence/2026-08-08-smoothing-that-works-and-is-usable/r5_instrument_move.txt.

#pragma once

#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

namespace topopt {
namespace surface_instruments {

// ── S3 INSTRUMENT 1: MINIMUM CROSS-SECTION OF EVERY TENDRIL ─────────────────
//
// AVERAGES HIDE THE FAILURE MODE. A mean cross-section can hold perfectly steady
// while one strut necks to nothing, and the necking strut is the whole objection.
// So this is a MINIMUM over the printed set, never a mean.
//
// The measure is `local_member_thickness_mm` — the Hildebrand inscribed-sphere
// diameter core already computes for the width-aware knockdown gate. It assigns
// every voxel of a member the member's FULL width, so a surface voxel of a rib
// reads the rib, not its own distance to the void. The mesh is re-voxelized onto
// a fixed reference grid first, so before and after are measured on the same
// lattice and a change in the reading is a change in the GEOMETRY.
struct CrossSection {
  double min_mm = 0.0;         // the thinnest member of the part proper
  double p01_mm = 0.0;         // 1st percentile, to show the minimum is not a fluke
  double global_min_mm = 0.0;  // including detached slivers (see below)
  std::size_t solid_voxels = 0;
  std::size_t components = 0;      // connected components of the printed set
  std::size_t dropped_voxels = 0;  // voxels outside the largest component
  bool valid = false;
};

// 6-connected component labels over the solid set; -1 on void.
std::vector<int> solid_components(const VoxelGrid& g, const std::vector<double>& d,
                                  double iso, std::size_t& out_count) {
  std::vector<int> lab(d.size(), -1);
  std::vector<int> stack;
  int next = 0;
  for (int k0 = 0; k0 < g.nz; ++k0)
    for (int j0 = 0; j0 < g.ny; ++j0)
      for (int i0 = 0; i0 < g.nx; ++i0) {
        const std::size_t s0 = g.index(i0, j0, k0);
        if (d[s0] <= iso || lab[s0] >= 0) continue;
        lab[s0] = next;
        stack.assign(1, static_cast<int>(s0));
        while (!stack.empty()) {
          const int cur = stack.back();
          stack.pop_back();
          const int i = cur % g.nx;
          const int j = (cur / g.nx) % g.ny;
          const int k = cur / (g.nx * g.ny);
          const int off[6][3] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
          for (const auto& o : off) {
            const int a = i + o[0], b = j + o[1], c = k + o[2];
            if (a < 0 || b < 0 || c < 0 || a >= g.nx || b >= g.ny || c >= g.nz) continue;
            const std::size_t s1 = g.index(a, b, c);
            if (d[s1] <= iso || lab[s1] >= 0) continue;
            lab[s1] = next;
            stack.push_back(static_cast<int>(s1));
          }
        }
        ++next;
      }
  out_count = static_cast<std::size_t>(next);
  return lab;
}

// THE INSTRUMENT, AND TWO THINGS IT CANNOT DO, both measured rather than assumed.
//
// (1) IT HAS A TWO-VOXEL QUANTUM. local_member_thickness_mm reports 2*r*spacing
//     for an INTEGER radius r, so its readings are 2, 4, 6, ... voxels and nothing
//     between. A 3-voxel neck reads 2.000, not 3.000. It can therefore see a
//     member cross a whole even step, and cannot see anything finer. Every
//     conclusion drawn from it below is stated at that resolution.
//
// (2) RE-VOXELIZING THE MESH MANUFACTURES DETACHED SLIVERS. Measured on the
//     dumbbell: the source occupancy's thickness histogram is {4:16, 6:200,
//     8:824} — minimum 4 — while the same solid put through marching cubes and
//     voxelize_onto_grid reads {2:36, 4:16, 6:200, 8:824}, and the 36 new
//     two-voxel entries sit at (10..13, 9|14, 0..1): at k = 0, nowhere near the
//     part, which lives at k >= 8. They are a voxelization artefact of the round
//     trip, they are present identically before AND after any operator runs, and
//     because this statistic is a MINIMUM they would pin it at 2.000 forever —
//     an instrument that cannot move is exactly the instrument this task warns
//     about. So the minimum is taken over the LARGEST CONNECTED COMPONENT, and
//     the component count and dropped-voxel count are reported beside it: if an
//     operator ever severs a real tendril, the component count moves and that is
//     visible rather than silently discarded.
CrossSection min_cross_section(const TriangleMesh& mesh, const VoxelGrid& ref,
                               int cap_voxels = 12) {
  CrossSection c;
  VoxelGrid g;
  try {
    g = voxelize_onto_grid(mesh, ref);
  } catch (const std::exception&) {
    return c;
  }
  std::vector<double> density(g.voxel_count(), 0.0);
  for (std::size_t i = 0; i < density.size(); ++i)
    if (g.tags[i] != VoxelTag::Empty) density[i] = 1.0;
  const std::vector<double> w = local_member_thickness_mm(g, density, 0.5, cap_voxels);

  std::size_t ncomp = 0;
  const std::vector<int> lab = solid_components(g, density, 0.5, ncomp);
  std::vector<std::size_t> size(ncomp, 0);
  for (const int l : lab)
    if (l >= 0) size[static_cast<std::size_t>(l)]++;
  int biggest = -1;
  std::size_t best = 0;
  for (std::size_t i = 0; i < ncomp; ++i)
    if (size[i] > best) { best = size[i]; biggest = static_cast<int>(i); }

  std::vector<double> solid;
  solid.reserve(w.size());
  double gmin = 0.0;
  bool first = true;
  for (std::size_t i = 0; i < w.size(); ++i) {
    if (!(w[i] > 0.0) || !std::isfinite(w[i])) continue;
    if (first) { gmin = w[i]; first = false; }
    else gmin = std::fmin(gmin, w[i]);
    if (lab[i] == biggest) solid.push_back(w[i]);
    else c.dropped_voxels++;
  }
  if (solid.empty()) return c;
  std::sort(solid.begin(), solid.end());
  c.min_mm = solid.front();
  c.p01_mm = solid[static_cast<std::size_t>(0.01 * (solid.size() - 1))];
  c.global_min_mm = gmin;
  c.solid_voxels = solid.size();
  c.components = ncomp;
  c.valid = true;
  return c;
}

// ── S3 INSTRUMENT 1b: MINIMUM CROSS-SECTION, MEASURED AS A CROSS-SECTION ────
//
// WHY A SECOND ONE. The Hildebrand measure above is the project's own width
// field and belongs in the table, but it is an INSCRIBED-SPHERE diameter and
// that is not what "cross-section" means for a rectangular member: on the
// dumbbell's own source occupancy, a bridge 6 voxels wide reads 4, because the
// largest sphere that fits inside a 6x6 section and still contains one of its
// CORNER voxels has diameter 4. The number is correct for what it measures and
// wrong for what this task asks. It also carries a 2-voxel quantum.
//
// So the deciding column is the plain engineering one: the solid AREA of the
// thinnest slice, minimised over slices and over the three axes. On a member of
// constructed width n voxels this reads exactly n^2 * spacing^2, which is what
// makes it a positive control rather than a plausibility check. Reported as an
// area and as its square root, an equivalent width, so it can be read against a
// voxel size.
struct SliceSection {
  double min_area_mm2 = 0.0;
  double equiv_width_mm = 0.0;
  std::size_t solid_voxels = 0;  // total, so a change in the fill is visible
  int axis = -1;
  int index = -1;
  bool valid = false;
};

SliceSection min_slice_section(const VoxelGrid& g, const std::vector<double>& d,
                               double iso) {
  SliceSection s;
  const double a = g.spacing * g.spacing;
  const int dim[3] = {g.nx, g.ny, g.nz};
  for (const double x : d)
    if (x > iso) s.solid_voxels++;
  if (s.solid_voxels == 0) return s;
  for (int ax = 0; ax < 3; ++ax)
    for (int t = 0; t < dim[ax]; ++t) {
      std::size_t count = 0;
      for (int u = 0; u < dim[(ax + 1) % 3]; ++u)
        for (int v = 0; v < dim[(ax + 2) % 3]; ++v) {
          int c[3];
          c[ax] = t;
          c[(ax + 1) % 3] = u;
          c[(ax + 2) % 3] = v;
          if (d[g.index(c[0], c[1], c[2])] > iso) ++count;
        }
      if (count == 0) continue;  // a slice clear of the part is not a section
      const double area = static_cast<double>(count) * a;
      if (!s.valid || area < s.min_area_mm2) {
        s.min_area_mm2 = area;
        s.axis = ax;
        s.index = t;
        s.valid = true;
      }
    }
  s.equiv_width_mm = std::sqrt(s.min_area_mm2);
  return s;
}

// The same statistic restricted to one axis and one index range: the minimum
// cross-section OF A NAMED MEMBER rather than of the whole grid. This is what
// answers "what did the thinnest tendril do" without the answer being hostage to
// an artefact somewhere else in the volume.
SliceSection min_slice_section_range(const VoxelGrid& g, const std::vector<double>& d,
                                     int axis, int lo, int hi, double iso) {
  SliceSection s;
  const double a = g.spacing * g.spacing;
  const int dim[3] = {g.nx, g.ny, g.nz};
  for (int t = lo; t < hi && t < dim[axis]; ++t) {
    if (t < 0) continue;
    std::size_t count = 0;
    for (int u = 0; u < dim[(axis + 1) % 3]; ++u)
      for (int v = 0; v < dim[(axis + 2) % 3]; ++v) {
        int c[3];
        c[axis] = t;
        c[(axis + 1) % 3] = u;
        c[(axis + 2) % 3] = v;
        if (d[g.index(c[0], c[1], c[2])] > iso) ++count;
      }
    const double area = static_cast<double>(count) * a;
    if (!s.valid || area < s.min_area_mm2) {
      s.min_area_mm2 = area;
      s.axis = axis;
      s.index = t;
      s.valid = true;
    }
  }
  s.equiv_width_mm = std::sqrt(s.min_area_mm2);
  return s;
}

SliceSection min_slice_section_range_of(const TriangleMesh& m, const VoxelGrid& ref,
                                        int axis, int lo, int hi) {
  SliceSection s;
  VoxelGrid g;
  try {
    g = voxelize_onto_grid(m, ref);
  } catch (const std::exception&) {
    return s;
  }
  std::vector<double> d(g.voxel_count(), 0.0);
  for (std::size_t i = 0; i < d.size(); ++i)
    if (g.tags[i] != VoxelTag::Empty) d[i] = 1.0;
  return min_slice_section_range(g, d, axis, lo, hi, 0.5);
}

SliceSection min_slice_section_of(const TriangleMesh& m, const VoxelGrid& ref) {
  SliceSection s;
  VoxelGrid g;
  try {
    g = voxelize_onto_grid(m, ref);
  } catch (const std::exception&) {
    return s;
  }
  std::vector<double> d(g.voxel_count(), 0.0);
  for (std::size_t i = 0; i < d.size(); ++i)
    if (g.tags[i] != VoxelTag::Empty) d[i] = 1.0;
  return min_slice_section(g, d, 0.5);
}

}  // namespace surface_instruments
}  // namespace topopt
