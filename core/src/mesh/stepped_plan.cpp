// See topopt/stepped_plan.hpp for the menu rule and why it is depth-clean.
#include "topopt/stepped_plan.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <map>
#include <unordered_map>

#include "topopt/lattice.hpp"   // octet_relative_density

namespace topopt {

std::vector<int> stepped_admitted_divisors(double base_cell_mm, double bead_mm,
                                           double min_tile_mm, bool apply_prints_open,
                                           SteppedMenu menu) {
  std::vector<int> out;
  if (!(base_cell_mm > 0.0) || !std::isfinite(base_cell_mm)) return out;
  if (!(bead_mm > 0.0) || !std::isfinite(bead_mm)) return out;
  // ★ RULING A: the halving ladder. Same three admissions as any-step -- the stated
  // floor, the bead fitting in the tile, and printing open -- applied to 2, 4, 8, ...
  // instead of 2..6. It stops at the FIRST rung that fails rather than skipping it: a
  // ladder with a gap is not a halving ladder, and the sizes below a gap are reached by
  // halving a size that was refused.
  if (menu == SteppedMenu::Halves) {
    for (int n = 2; n <= (1 << kSteppedMaxHalvings); n *= 2) {
      const double tile = base_cell_mm / n;
      if (min_tile_mm > 0.0 && tile < min_tile_mm) break;
      if (tile <= bead_mm) break;
      if (apply_prints_open) {
        double rho = 1.0;
        try {
          rho = octet_relative_density(tile, 0.5 * bead_mm);
        } catch (const std::exception&) {
          break;
        }
        if (rho > kSteppedPrintsOpenMaxRho) break;
      }
      out.push_back(n);
    }
    return out;
  }
  for (int n = 2; n <= kSteppedMaxDivisor; ++n) {
    const double tile = base_cell_mm / n;
    if (min_tile_mm > 0.0 && tile < min_tile_mm) continue;
    if (tile <= bead_mm) continue;      // the bead does not fit in the tile at all
    if (!apply_prints_open) { out.push_back(n); continue; }   // structural: floor alone
    // ★ PRINTS OPEN, by the octet law and not by a rule of thumb: a bead-wide strut in a
    // tile this size must leave the cell mostly air. octet_relative_density depends only
    // on radius/cell, so this is a statement about the RATIO and nothing else.
    double rho = 1.0;
    try {
      rho = octet_relative_density(tile, 0.5 * bead_mm);
    } catch (const std::exception&) {
      continue;                          // the cell fills solid: emphatically not open
    }
    if (rho > kSteppedPrintsOpenMaxRho) continue;
    out.push_back(n);
  }
  return out;
}

std::vector<double> stepped_size_menu(double base_cell_mm, double bead_mm,
                                      double min_tile_mm, bool apply_prints_open,
                                      SteppedMenu which) {
  std::vector<double> menu;
  if (!(base_cell_mm > 0.0) || !std::isfinite(base_cell_mm)) return menu;
  menu.push_back(base_cell_mm);          // the base is always on its own menu
  // ★ RULING A: under Halves a rung contributes ONLY its own size. Any-step's k*(S/n)
  // is what lets a 9 sit beside an 8; the dyadic ladder has no such sizes, and adding
  // them here would quietly make "doubled" accept an any-step plan.
  if (which == SteppedMenu::Halves) {
    for (int n : stepped_admitted_divisors(base_cell_mm, bead_mm, min_tile_mm,
                                           apply_prints_open, which))
      menu.push_back(base_cell_mm / n);
  } else
  for (int n : stepped_admitted_divisors(base_cell_mm, bead_mm, min_tile_mm,
                                        apply_prints_open)) {
    const double tile = base_cell_mm / n;
    for (int k = 1; k < n; ++k) menu.push_back(k * tile);
  }
  std::sort(menu.begin(), menu.end(), std::greater<double>());
  // 2*(S/4) and S/2 are the same size reached two ways; the packer must see it once.
  menu.erase(std::unique(menu.begin(), menu.end(),
                         [](double a, double b) {
                           const double m = std::max(std::fabs(a), std::fabs(b));
                           return std::fabs(a - b) <= kSteppedMenuSameRel * (m > 0 ? m : 1.0);
                         }),
             menu.end());
  return menu;
}


namespace {

// A cell's origin must land on a multiple of its family's tile. A size reachable from
// several families is legitimate on ANY of their grids, so the test is a disjunction --
// asserting one family's grid would refuse arrangements the packer is entitled to make.
bool aligned_on_some_family(double offset, double size, double base, const std::vector<int>& divisors) {
  for (int n : divisors) {
    const double tile = base / n;
    if (tile <= 0.0) continue;
    const double k = size / tile;
    if (std::fabs(k - std::floor(k + 0.5)) > 1e-6) continue;   // not this family's size
    const double q = offset / tile;
    if (std::fabs(q - std::floor(q + 0.5)) <= 1e-6) return true;
  }
  return false;
}

}  // namespace

SteppedPlanCheck stepped_validate_plan(const std::vector<SteppedCell>& cells,
                                       const std::vector<SteppedPlanRegion>& regions,
                                       double bead_mm, double min_tile_mm,
                                       bool apply_prints_open, SteppedMenu menu) {
  SteppedPlanCheck out;
  out.cells = cells.size();
  out.regions = regions.size();
  char msg[512];

  std::unordered_map<int, const SteppedPlanRegion*> by_id;
  std::unordered_map<int, std::vector<double>> menu_of;
  std::unordered_map<int, std::vector<int>> div_of;
  for (const SteppedPlanRegion& r : regions) {
    by_id[r.region_id] = &r;
    menu_of[r.region_id] =
        stepped_size_menu(r.base_cell_mm, bead_mm, min_tile_mm, apply_prints_open, menu);
    div_of[r.region_id] = stepped_admitted_divisors(r.base_cell_mm, bead_mm, min_tile_mm,
                                                    apply_prints_open, menu);
  }

  double finest = 0.0;
  for (const auto& kv : menu_of)
    for (double s : kv.second)
      if (finest <= 0.0 || s < finest) finest = s;

  std::map<double, std::size_t, std::greater<double>> hist;
  // Overlap is tested on a hash of the FINEST menu tile: every cell is a whole number of
  // those on every axis, so a cell covers a exact block of hash slots and two cells
  // overlap iff they share one. No tolerance, no sweep over pairs.
  std::unordered_map<long long, std::size_t> occupied;
  auto key = [](long long i, long long j, long long k) {
    constexpr long long b = 1LL << 20;
    return (((i + b) & 0x1FFFFF) << 42) | (((j + b) & 0x1FFFFF) << 21) | ((k + b) & 0x1FFFFF);
  };

  for (std::size_t c = 0; c < cells.size(); ++c) {
    const SteppedCell& cell = cells[c];
    auto it = by_id.find(cell.region_id);
    if (it == by_id.end()) {
      std::snprintf(msg, sizeof msg,
                    "stepped cell %zu names region %d, which is not a declared region",
                    c, cell.region_id);
      out.error = msg;
      return out;
    }
    const SteppedPlanRegion& reg = *it->second;
    const std::vector<double>& menu = menu_of[cell.region_id];

    bool on_menu = false;
    for (double s : menu)
      if (std::fabs(s - cell.size_mm) <= kSteppedMenuSameRel * std::max(1.0, s)) on_menu = true;
    if (!on_menu) {
      std::snprintf(msg, sizeof msg,
                    "stepped cell %zu in region %d is %.4g mm, which is not on that "
                    "region's menu (base %.4g mm at a %.3g mm bead admits %zu size(s), "
                    "largest %.4g, finest %.4g)",
                    c, cell.region_id, cell.size_mm, reg.base_cell_mm, bead_mm,
                    menu.size(), menu.empty() ? 0.0 : menu.front(),
                    menu.empty() ? 0.0 : menu.back());
      out.error = msg;
      return out;
    }

    const double ox = cell.origin.x - reg.slot_origin.x;
    const double oy = cell.origin.y - reg.slot_origin.y;
    const double oz = cell.origin.z - reg.slot_origin.z;
    const std::vector<int>& divs = div_of[cell.region_id];
    const bool ax = aligned_on_some_family(ox, cell.size_mm, reg.base_cell_mm, divs);
    const bool ay = aligned_on_some_family(oy, cell.size_mm, reg.base_cell_mm, divs);
    const bool az = aligned_on_some_family(oz, cell.size_mm, reg.base_cell_mm, divs);
    const bool is_base = std::fabs(cell.size_mm - reg.base_cell_mm) <=
                         kSteppedMenuSameRel * std::max(1.0, reg.base_cell_mm);
    if (!is_base && !(ax && ay && az)) {
      std::snprintf(msg, sizeof msg,
                    "stepped cell %zu in region %d is %.4g mm at offset (%.4g, %.4g, "
                    "%.4g) from the slot grid, which is not a multiple of its family's "
                    "tile on %s%s%s",
                    c, cell.region_id, cell.size_mm, ox, oy, oz, ax ? "" : "x ",
                    ay ? "" : "y ", az ? "" : "z");
      out.error = msg;
      return out;
    }

    // ★ INSIDE THE REGION'S PRISM, along the face normal. The in-plane bound needs a u/w
    // axis convention this file does not own, and material is a voxel question, so those
    // are the caller's; the DEPTH is exact here and is the axis the pack is built on --
    // depth scanned from the face inward, a cell leaving a whole number of tiles behind
    // it. A cell that starts before the face or ends past the wall breaks that directly.
    if (reg.depth_mm > 0.0) {
      const double nl = std::sqrt(reg.normal.x * reg.normal.x + reg.normal.y * reg.normal.y +
                                  reg.normal.z * reg.normal.z);
      if (nl > 0.0) {
        const double nx = reg.normal.x / nl, ny = reg.normal.y / nl, nz = reg.normal.z / nl;
        const double s0 = ox * nx + oy * ny + oz * nz;
        const double s1 = s0 + cell.size_mm;
        if (s0 < -1e-6 || s1 > reg.depth_mm + 1e-6) {
          std::snprintf(msg, sizeof msg,
                        "stepped cell %zu in region %d (%.4g mm at %.4g, %.4g, %.4g) lies "
                        "from %.4g to %.4g mm along the region normal, outside its %.4g mm "
                        "prism",
                        c, cell.region_id, cell.size_mm, cell.origin.x, cell.origin.y,
                        cell.origin.z, s0, s1, reg.depth_mm);
          out.error = msg;
          return out;
        }
      }
    }

    if (finest > 0.0) {
      const long long i0 = static_cast<long long>(std::llround(ox / finest));
      const long long j0 = static_cast<long long>(std::llround(oy / finest));
      const long long k0 = static_cast<long long>(std::llround(oz / finest));
      const long long span = static_cast<long long>(std::llround(cell.size_mm / finest));
      for (long long i = i0; i < i0 + std::max(1LL, span); ++i)
        for (long long j = j0; j < j0 + std::max(1LL, span); ++j)
          for (long long k = k0; k < k0 + std::max(1LL, span); ++k) {
            auto ins = occupied.emplace(key(i, j, k), c);
            if (!ins.second) {
              std::snprintf(msg, sizeof msg,
                            "stepped cell %zu in region %d (%.4g mm at %.4g, %.4g, %.4g) "
                            "OVERLAPS cell %zu",
                            c, cell.region_id, cell.size_mm, cell.origin.x, cell.origin.y,
                            cell.origin.z, ins.first->second);
              out.error = msg;
              return out;
            }
          }
    }
    ++hist[cell.size_mm];
  }

  for (const auto& kv : hist) out.histogram.push_back({kv.first, kv.second});
  char buf[64];
  for (const auto& kv : out.histogram) {
    std::snprintf(buf, sizeof buf, "%s%.2f=%zu", out.histogram_line.empty() ? "" : " ",
                  kv.first, kv.second);
    out.histogram_line += buf;
  }
  out.ok = true;
  return out;
}


std::vector<SteppedCellGroup> stepped_group_cells(
    const std::vector<SteppedCell>& cells, const std::vector<SteppedPlanRegion>& regions) {
  std::unordered_map<int, const SteppedPlanRegion*> by_id;
  for (const SteppedPlanRegion& r : regions) by_id[r.region_id] = &r;

  // key: region id and the size, quantised so floating point cannot split one family
  std::map<std::pair<int, long long>, std::vector<const SteppedCell*>> bucket;
  for (const SteppedCell& c : cells) {
    if (!by_id.count(c.region_id) || !(c.size_mm > 0.0)) continue;
    bucket[{c.region_id, static_cast<long long>(std::llround(c.size_mm * 1e6))}]
        .push_back(&c);
  }

  std::vector<SteppedCellGroup> out;
  for (auto& kv : bucket) {
    const SteppedPlanRegion& reg = *by_id[kv.first.first];
    const double size = static_cast<double>(kv.first.second) * 1e-6;
    // The grid origin is the SLOT origin walked back by whole cells to below the group's
    // minimum corner, so every cell lands on a non-negative integer index without the
    // origin ever leaving the family's own tile grid.
    double lo[3] = {1e300, 1e300, 1e300}, hi[3] = {-1e300, -1e300, -1e300};
    for (const SteppedCell* c : kv.second) {
      const double p[3] = {c->origin.x, c->origin.y, c->origin.z};
      for (int a = 0; a < 3; ++a) {
        lo[a] = std::min(lo[a], p[a]);
        hi[a] = std::max(hi[a], p[a] + size);
      }
    }
    const double slot[3] = {reg.slot_origin.x, reg.slot_origin.y, reg.slot_origin.z};
    double org[3];
    for (int a = 0; a < 3; ++a) {
      const double steps = std::floor((lo[a] - slot[a]) / size + 1e-9);
      org[a] = slot[a] + steps * size;
    }
    SteppedCellGroup g;
    g.region_id = kv.first.first;
    g.size_mm = size;
    g.origin = Vec3{org[0], org[1], org[2]};
    g.nx = std::max(1, static_cast<int>(std::llround((hi[0] - org[0]) / size)));
    g.ny = std::max(1, static_cast<int>(std::llround((hi[1] - org[1]) / size)));
    g.nz = std::max(1, static_cast<int>(std::llround((hi[2] - org[2]) / size)));
    // ★ RULING C: the density rides WITH the cell through the sort. Sorting a parallel
    // array afterwards would silently pair the wrong density with the wrong cell, so
    // the two are sorted together and split after.
    std::vector<std::pair<std::array<int, 3>, double>> idx;
    idx.reserve(kv.second.size());
    for (const SteppedCell* c : kv.second)
      idx.push_back({{static_cast<int>(std::llround((c->origin.x - org[0]) / size)),
                      static_cast<int>(std::llround((c->origin.y - org[1]) / size)),
                      static_cast<int>(std::llround((c->origin.z - org[2]) / size))},
                     c->rho});
    std::sort(idx.begin(), idx.end(),
              [](const std::pair<std::array<int, 3>, double>& a,
                 const std::pair<std::array<int, 3>, double>& b) { return a.first < b.first; });
    g.cells.reserve(idx.size());
    g.rho.reserve(idx.size());
    for (const auto& e : idx) { g.cells.push_back(e.first); g.rho.push_back(e.second); }
    out.push_back(std::move(g));
  }
  // region ascending, then size DESCENDING: the coarse families are laid first, which is
  // the order the preview draws them and a fixed order either way.
  std::sort(out.begin(), out.end(), [](const SteppedCellGroup& a, const SteppedCellGroup& b) {
    if (a.region_id != b.region_id) return a.region_id < b.region_id;
    return a.size_mm > b.size_mm;
  });
  return out;
}

}  // namespace topopt
