// See topopt/stepped_plan.hpp for the menu rule and why it is depth-clean.
#include <limits>
#include "topopt/stepped_plan.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <map>
#include <unordered_map>

#include "topopt/lattice.hpp"   // lattice_density_from_strut

namespace topopt {

std::vector<int> stepped_admitted_divisors(LatticeTopology topo,
                                           double base_cell_mm, double bead_mm,
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
          rho = lattice_density_from_strut(topo, tile, 0.5 * bead_mm);
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
      rho = lattice_density_from_strut(topo, tile, 0.5 * bead_mm);
    } catch (const std::exception&) {
      continue;                          // the cell fills solid: emphatically not open
    }
    if (rho > kSteppedPrintsOpenMaxRho) continue;
    out.push_back(n);
  }
  return out;
}

std::vector<double> stepped_size_menu(LatticeTopology topo, double base_cell_mm,
                                      double bead_mm,
                                      double min_tile_mm, bool apply_prints_open,
                                      SteppedMenu which) {
  std::vector<double> menu;
  if (!(base_cell_mm > 0.0) || !std::isfinite(base_cell_mm)) return menu;
  // ★ D5: THE BASE GETS THE SAME FLOOR AS EVERY OTHER TILE. This was unconditional --
  // "the base is always on its own menu" -- so a base cell below the job's own tile floor,
  // or narrower than the bead it must print, was admitted while every division of it was
  // refused. A base cell is a whole slot and has to print like any other.
  if (min_tile_mm > 0.0 && base_cell_mm < min_tile_mm) return menu;   // empty: nothing legal
  if (base_cell_mm <= bead_mm) return menu;   // the bead does not fit in the cell at all
  menu.push_back(base_cell_mm);
  // ★ RULING A: under Halves a rung contributes ONLY its own size. Any-step's k*(S/n)
  // is what lets a 9 sit beside an 8; the dyadic ladder has no such sizes, and adding
  // them here would quietly make "doubled" accept an any-step plan.
  if (which == SteppedMenu::Halves) {
    for (int n : stepped_admitted_divisors(topo, base_cell_mm, bead_mm, min_tile_mm,
                                           apply_prints_open, which))
      menu.push_back(base_cell_mm / n);
  } else
  for (int n : stepped_admitted_divisors(topo, base_cell_mm, bead_mm, min_tile_mm,
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

SteppedPlanCheck stepped_validate_plan(LatticeTopology topo,
                                       const std::vector<SteppedCell>& cells,
                                       const std::vector<SteppedPlanRegion>& regions,
                                       double bead_mm, double min_tile_mm,
                                       bool apply_prints_open, SteppedMenu menu,
                                       const std::vector<ClearanceGeometry>* includes,
                                       double max_relative_density) {
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
        stepped_size_menu(topo, r.base_cell_mm, bead_mm, min_tile_mm,
                          apply_prints_open, menu);
    div_of[r.region_id] = stepped_admitted_divisors(topo, r.base_cell_mm, bead_mm, min_tile_mm,
                                                    apply_prints_open, menu);
  }

  // Hoisted: inside the per-cell loop `menu` is shadowed by that region's size
  // vector, so the MENU KIND is read here, where the name still means the parameter.
  const bool own_grid_only = menu == SteppedMenu::Halves;
  std::map<double, std::size_t, std::greater<double>> hist;

  // ── ★ OVERLAP IS TESTED EXACTLY, IN WORLD COORDINATES (R5, R3 and a false
  // acceptance; #354's core brief 2026-10-02, reviewer's ruling 2026-10-07) ─────
  // This was a hash of ONE finest menu tile, keyed on (i, j, k) with offsets measured
  // from each region's own slot origin, and it carried the assumption that "every cell
  // is a whole number of those on every axis". Three defects came out of it:
  //   - R5: the assumption holds only if every region's ladder nests in every other's.
  //     Off a shared grid a span rounds UP while the next cell's start rounds DOWN, and
  //     two cells that merely TOUCH were called overlapping -- 1,458 false collisions on
  //     one of his projects, every one false;
  //   - R3: the key had no region id, so two cells at the same offset in different
  //     regions collided 36 mm apart;
  //   - and where a region's menu holds only its base (every base does at a 0.45 mm
  //     bead), the tile EQUALS the cell, so cells half a cell apart rounded into
  //     different slots and a REAL overlap was ACCEPTED. Base cells are exempt from the
  //     alignment check, so that offset is exactly what the app sends.
  // A tile hash cannot be repaired by choosing a better tile: the quantity being decided
  // is whether two boxes share volume, so that is what is computed. The grid below only
  // finds CANDIDATES -- it never decides -- so no rounding of it can change a verdict.
  // Boxes are in WORLD coordinates, which is what "two cells occupy the same space"
  // means and which no region's own frame can express.
  struct PlacedBox {
    double lo[3], hi[3];
    std::size_t cell;
    int region;
  };
  double bucket_mm = 0.0;
  for (const SteppedCell& c : cells) bucket_mm = std::max(bucket_mm, c.size_mm);
  if (bucket_mm <= 0.0) bucket_mm = 1.0;
  std::vector<PlacedBox> placed;
  placed.reserve(cells.size());
  std::unordered_map<long long, std::vector<std::size_t>> bucket_of;
  auto key = [](long long i, long long j, long long k) {
    constexpr long long b = 1LL << 20;
    return (((i + b) & 0x1FFFFF) << 42) | (((j + b) & 0x1FFFFF) << 21) | ((k + b) & 0x1FFFFF);
  };
  // Two cells that share a FACE are packed, not overlapping; the tolerance is a
  // nanometre, far below the bead and far above the arithmetic.
  constexpr double kOverlapTolMm = 1e-6;
  auto shared_volume = [](const PlacedBox& a, const PlacedBox& b, double out[3]) {
    for (int d = 0; d < 3; ++d) {
      out[d] = std::min(a.hi[d], b.hi[d]) - std::max(a.lo[d], b.lo[d]);
      if (out[d] <= kOverlapTolMm) return false;
    }
    return true;
  };
  // ── ★ STRADDLERS AT A MITRE (reviewer's ruling 4) ────────────────────────────
  // Where two include prisms meet, the app keeps a cell WHOLE and lets it cross the
  // seam, so two regions' cells legitimately share space. That is allowed exactly when
  // each cell's CENTRE is owned by its own region -- then each is a cell of the region
  // it belongs to, and only the owner's lattice is laid in the shared volume. Any other
  // cross-region overlap is a real collision and is refused.
  //
  // Without the include geometry there is nothing to ask, so a caller that does not pass
  // it gets the conservative answer: every cross-region overlap refused. run_job always
  // passes it; the pure-header tests that do not are testing same-region behaviour.
  auto centre_of = [](const PlacedBox& b) {
    return Vec3{0.5 * (b.lo[0] + b.hi[0]), 0.5 * (b.lo[1] + b.hi[1]),
                0.5 * (b.lo[2] + b.hi[2])};
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

    // ★ D5: AN UNDER-FLOOR BASE IS NAMED, not implied by an empty menu. With the base
    // now subject to the floor, a region whose base is below it has NO legal size at all,
    // and "not on that region's menu ... admits 0 size(s)" would describe the symptom
    // rather than the cause.
    if (menu.empty()) {
      std::snprintf(msg, sizeof msg,
                    "stepped cell %zu names region %d, whose base cell is %.4g mm -- below "
                    "the tile floor %.4g mm (or no wider than the %.4g mm bead), so NO size "
                    "is legal in that region and the plan cannot be built there",
                    c, cell.region_id, reg.base_cell_mm, min_tile_mm, bead_mm);
      out.error = msg;
      return out;
    }
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

    // ── ★ D5: THE DENSITY THAT CAME WITH THE CELL IS CHECKED, at its OWN size ────
    // `cell.rho` sizes the strut (ruling C) and was checked against nothing here: the
    // schema admits (0, 1] and the validator never read it. Two ways that ships a part
    // core could have refused -- a strut under the bead, and a density over the cap the
    // job states -- so both are refused by name, with the number.
    if (cell.rho > 0.0) {
      if (max_relative_density > 0.0 && std::isfinite(max_relative_density) &&
          cell.rho > max_relative_density * (1.0 + kSteppedMenuSameRel)) {
        std::snprintf(msg, sizeof msg,
                      "stepped cell %zu in region %d states a density of %.6g, over this "
                      "job's \"max_relative_density\" of %.6g. Refused rather than clamped: "
                      "the density sizes the strut, so clamping it silently prints a cell "
                      "lighter than the plan asked for",
                      c, cell.region_id, cell.rho, max_relative_density);
        out.error = msg;
        return out;
      }
      double dia = 0.0;
      try {
        dia = lattice_strut_diameter_mm(topo, cell.rho, cell.size_mm);
      } catch (const std::exception&) {
        dia = 0.0;                       // no measured law at that density: treated as unprintable
      }
      if (!(dia >= bead_mm * (1.0 - kSteppedMenuSameRel))) {
        std::snprintf(msg, sizeof msg,
                      "stepped cell %zu in region %d is %.4g mm at a density of %.6g, which "
                      "builds a %.4g mm strut -- under the %.4g mm bead. The strut is sized "
                      "from the density the cell carries, so this cell cannot be printed at "
                      "the size and density the plan pairs",
                      c, cell.region_id, cell.size_mm, cell.rho, dia, bead_mm);
        out.error = msg;
        return out;
      }
    }
    const double ox = cell.origin.x - reg.slot_origin.x;
    const double oy = cell.origin.y - reg.slot_origin.y;
    const double oz = cell.origin.z - reg.slot_origin.z;
    const std::vector<int>& divs = div_of[cell.region_id];
    // ── ★ R6: WHICH GRID A CELL MUST LAND ON (#354's brief 2026-10-02; reviewer's
    // ruling 3, 2026-10-07) ──────────────────────────────────────────────────────
    // Two things were wrong here. BASE cells were exempt entirely, so a base cell at any
    // offset was accepted -- and then MOVED by stepped_group_cells to the nearest point
    // of its own grid, by up to half its size, which the STL shows and no receipt does.
    // And every other cell was checked only against SOME family that can express its
    // size, never against its own size's grid.
    //
    // DOUBLED is a halving octree: it can only ever place a cell on its OWN size's grid
    // from the slot origin, so that is what is required, base cells included. R6 (a base
    // cell 1 mm off) and R6b (an S/2 cell on the S/4 tile) are refused here.
    //
    // ANY-STEP may place a k-tile cell at ANY whole tile, so the family disjunction
    // stands -- R6c and R6d are sound plans and must be accepted, and grouping keeps
    // their origins. The base exemption is gone under both menus: a base cell is a whole
    // slot and belongs on the base grid.
    auto on_own_size_grid = [&](double off) {
      const double q = off / cell.size_mm;
      return std::fabs(q - std::floor(q + 0.5)) <= 1e-6;
    };
    // A cell on its OWN size's grid is always legitimate -- that is the one grid every
    // packer can place it on, and for a base cell it is the base grid. Under ANY-STEP a
    // k-tile cell may additionally sit at any whole tile of a family that can express its
    // size, so there the family disjunction ADDS permission rather than replacing it.
    // (It cannot be the only test: `stepped_admitted_divisors` returns an EMPTY list when
    // the printability rule leaves a region's menu holding nothing but its base, and
    // asking only the families would then refuse every cell -- which is what the base
    // exemption this replaces was quietly covering up.)
    auto aligned = [&](double off) {
      if (on_own_size_grid(off)) return true;
      return !own_grid_only &&
             aligned_on_some_family(off, cell.size_mm, reg.base_cell_mm, divs);
    };
    const bool ax = aligned(ox), ay = aligned(oy), az = aligned(oz);
    if (!(ax && ay && az)) {
      std::snprintf(msg, sizeof msg,
                    "stepped cell %zu in region %d is %.4g mm at offset (%.4g, %.4g, "
                    "%.4g) from the slot grid, which is not a multiple of %s on %s%s%s",
                    c, cell.region_id, cell.size_mm, ox, oy, oz,
                    own_grid_only ? "its OWN size (the halving octree can place it "
                                    "nowhere else)"
                                  : "its family's tile",
                    ax ? "" : "x ", ay ? "" : "y ", az ? "" : "z");
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
        // ★ PROJECT THE CUBE, NOT ONE CORNER (R2, #354's core brief 2026-10-02).
        // `origin` is the cell's MINIMUM corner, so s0 + size is the cell's far face
        // only when the normal points the way that makes the minimum corner the NEAR
        // one -- a positive axis normal. On a wall whose normal has a negative
        // component the minimum corner is the cell's FAR end along n, and this read the
        // deepest legal layer one cell too deep (refusing 1,467 sound cells on the
        // stand's -y wall alone) while accepting a cell sitting entirely in FRONT of
        // the face. The cube's eight corners are o + S*b for b in {0,1}^3, so its
        // extent along n is [s0 + S*sum(min(0,n_i)), s0 + S*sum(max(0,n_i))]. For an
        // axis normal that is exact, and for a positive axis normal it is unchanged.
        // For a TILTED facet the extent is sum(|n_i|)*S, wider than S, so this is
        // stricter there than the old read -- see R2b in the handoff: what containment
        // a tilted facet's cells must satisfy is the maintainer's rule, not core's to
        // invent, and no projection accepts a cell that starts in front of the plane.
        const double n_lo = std::min(0.0, nx) + std::min(0.0, ny) + std::min(0.0, nz);
        const double n_hi = std::max(0.0, nx) + std::max(0.0, ny) + std::max(0.0, nz);
        const double s_lo = s0 + cell.size_mm * n_lo;
        const double s_hi = s0 + cell.size_mm * n_hi;
        // ★ ONE CONTAINMENT RULE FOR EVERY FACE, axis-aligned or tilted (reviewer's
        // ruling 1, 2026-10-05, settling R2, R2x and R2b together). The cell's CENTRE
        // must lie in the prism, and its FAR side must not pass the prism's depth. Its
        // NEAR side may stand in front of the face plane: that is how the app covers a
        // tilted facet -- it starts the span in front of the plane so the cube covers
        // the slant -- and what lies outside the part is not laid. A near-side bound is
        // what would have refused the stand's 90 face-23 facet cells for doing the one
        // thing that makes them cover their face.
        // The centre is the cube's centre projected: s0 + (S/2)*(nx + ny + nz).
        const double s_mid = s0 + 0.5 * cell.size_mm * (nx + ny + nz);
        if (s_mid < -1e-6 || s_mid > reg.depth_mm + 1e-6 ||
            s_hi > reg.depth_mm + 1e-6) {
          std::snprintf(msg, sizeof msg,
                        "stepped cell %zu in region %d (%.4g mm at %.4g, %.4g, %.4g) lies "
                        "from %.4g to %.4g mm along the region normal with its centre at "
                        "%.4g, outside its %.4g mm prism: the centre must lie in the prism "
                        "and the far side must not pass it, though the near side may stand "
                        "in front of the face",

                        c, cell.region_id, cell.size_mm, cell.origin.x, cell.origin.y,
                        cell.origin.z, s_lo, s_hi, s_mid, reg.depth_mm);
          out.error = msg;
          return out;
        }
      }
    }

    PlacedBox box;
    box.lo[0] = cell.origin.x;
    box.lo[1] = cell.origin.y;
    box.lo[2] = cell.origin.z;
    for (int d = 0; d < 3; ++d) box.hi[d] = box.lo[d] + cell.size_mm;
    box.cell = c;
    box.region = cell.region_id;
    long long b0[3], b1[3];
    for (int d = 0; d < 3; ++d) {
      b0[d] = static_cast<long long>(std::floor(box.lo[d] / bucket_mm));
      b1[d] = static_cast<long long>(std::floor(box.hi[d] / bucket_mm));
    }
    for (long long i = b0[0]; i <= b1[0]; ++i)
      for (long long j = b0[1]; j <= b1[1]; ++j)
        for (long long k = b0[2]; k <= b1[2]; ++k) {
          auto it_b = bucket_of.find(key(i, j, k));
          if (it_b == bucket_of.end()) continue;
          for (std::size_t other : it_b->second) {
            const PlacedBox& o = placed[other];
            double ov[3];
            if (!shared_volume(box, o, ov)) continue;
            if (box.region != o.region && includes != nullptr) {
              // A straddler pair: allowed only if each centre is owned by its own region.
              const int own_a = stepped_region_owner(centre_of(box), *includes);
              const int own_b = stepped_region_owner(centre_of(o), *includes);
              if (own_a == box.region && own_b == o.region) continue;
              std::snprintf(
                  msg, sizeof msg,
                  "stepped cell %zu in region %d (%.4g mm at %.4g, %.4g, %.4g) OVERLAPS "
                  "cell %zu in region %d by %.4g x %.4g x %.4g mm, and it is not a "
                  "straddled seam: the centre of cell %zu is owned by region %d and the "
                  "centre of cell %zu by region %d. Two regions may share space only "
                  "where each cell's CENTRE lies in its own region's prism",
                  c, cell.region_id, cell.size_mm, cell.origin.x, cell.origin.y,
                  cell.origin.z, o.cell, o.region, ov[0], ov[1], ov[2], c, own_a, o.cell,
                  own_b);
              out.error = msg;
              return out;
            }
            std::snprintf(msg, sizeof msg,
                          "stepped cell %zu in region %d (%.4g mm at %.4g, %.4g, %.4g) "
                          "OVERLAPS cell %zu in region %d (%.4g mm at %.4g, %.4g, %.4g) "
                          "by %.4g x %.4g x %.4g mm",
                          c, cell.region_id, cell.size_mm, cell.origin.x, cell.origin.y,
                          cell.origin.z, o.cell, o.region, o.hi[0] - o.lo[0], o.lo[0],
                          o.lo[1], o.lo[2], ov[0], ov[1], ov[2]);
            out.error = msg;
            return out;
          }
        }
    placed.push_back(box);
    for (long long i = b0[0]; i <= b1[0]; ++i)
      for (long long j = b0[1]; j <= b1[1]; ++j)
        for (long long k = b0[2]; k <= b1[2]; ++k)
          bucket_of[key(i, j, k)].push_back(placed.size() - 1);
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

  // ── ★ R6: A GROUP IS (REGION, SIZE, PHASE), AND THAT IS WHY NOTHING MOVES ─────
  // The key was (region, size) alone, and each bucket got ONE grid of that size walked
  // back from the slot origin. A cell that was not a whole number of its own size from
  // the slot origin therefore rounded to the nearest grid point -- measured at up to half
  // its size, and on one of the brief's jobs a 7.25 mm cell landed ON TOP of its
  // neighbour, covering x 18-20.42 twice and leaving x 25.25-27.67 bare. Any-step packs
  // produce such cells as a matter of course, because the packer may place a k-tile cell
  // at ANY whole tile.
  //
  // The PHASE -- the cell's offset from the slot origin modulo its own size, per axis --
  // joins the key. Within one phase bucket every cell is a whole number of sizes from
  // every other, so the bucket's own minimum corner IS an exact grid origin and every
  // index maps back to the origin that was SENT. Nothing is re-anchored, which is what
  // this file's own header always promised ("never a re-anchoring that could move a cell
  // the maintainer approved").
  //
  // Prototyped against the brief's own Python port of this function before being written
  // here: all seven of its measured cases come back at 0.000e+00 mm of movement, and
  // core's packed-slot fixture goes from 7,344 once / 3,240 uncovered / 3,240 doubled back
  // to 13,824 / 0 / 0.
  //
  // THE COST is passes: a group is an emission pass, so phases multiply them (a k-tile
  // cell admits up to k phases per axis). Measured before shipping -- see the handoff.
  auto phase_key = [](double off, double size) {
    double q = off / size;
    q -= std::floor(q);                       // the fractional part, in [0, 1)
    long long k = std::llround(q * size * 1e6);
    if (k == std::llround(size * 1e6)) k = 0;  // a hair under a whole step is a whole step
    return k;
  };
  struct GroupKey {
    int region;
    long long size, px, py, pz;
    bool operator<(const GroupKey& o) const {
      if (region != o.region) return region < o.region;
      if (size != o.size) return size > o.size;   // size DESCENDING, as before
      if (px != o.px) return px < o.px;
      if (py != o.py) return py < o.py;
      return pz < o.pz;
    }
  };
  std::map<GroupKey, std::vector<const SteppedCell*>> bucket;
  for (const SteppedCell& c : cells) {
    auto it_r = by_id.find(c.region_id);
    if (it_r == by_id.end() || !(c.size_mm > 0.0)) continue;
    const SteppedPlanRegion& rg = *it_r->second;
    const GroupKey k{c.region_id, static_cast<long long>(std::llround(c.size_mm * 1e6)),
                     phase_key(c.origin.x - rg.slot_origin.x, c.size_mm),
                     phase_key(c.origin.y - rg.slot_origin.y, c.size_mm),
                     phase_key(c.origin.z - rg.slot_origin.z, c.size_mm)};
    bucket[k].push_back(&c);
  }

  std::vector<SteppedCellGroup> out;
  for (auto& kv : bucket) {
    const double size = static_cast<double>(kv.first.size) * 1e-6;
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
    // Every cell in this bucket shares a phase, so the bucket's own minimum corner is a
    // point of their common grid -- exact, with no walk back and nothing to round.
    double org[3];
    for (int a = 0; a < 3; ++a) org[a] = lo[a];
    SteppedCellGroup g;
    g.region_id = kv.first.region;
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

int stepped_region_owner(const Vec3& p, const std::vector<ClearanceGeometry>& includes) {
  int owner = 0;
  double best = 0.0;
  for (std::size_t i = 0; i < includes.size(); ++i) {
    // The SAME membership test core resolves per-voxel region ids with. Not a second one.
    if (!point_in_clearance_region(includes[i], p, 0.0)) continue;
    const Vec3& n = includes[i].normal;
    const double ln = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    double d = std::numeric_limits<double>::infinity();   // no face plane => cannot win
    if (ln > 0.0) {
      const Vec3& o = includes[i].origin;
      d = std::fabs(((p.x - o.x) * n.x + (p.y - o.y) * n.y + (p.z - o.z) * n.z) / ln);
    }
    // STRICT improvement only, and `includes` is walked in ascending id order, so an
    // exact tie keeps the LOWER id without needing a second comparison.
    if (owner == 0 || d < best) {
      owner = static_cast<int>(i) + 1;
      best = d;
    }
  }
  return owner;
}

}  // namespace topopt
