#include "topopt/lattice_density_field.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

namespace topopt {

const char* lattice_region_mode_name(LatticeRegionMode m) {
  switch (m) {
    case LatticeRegionMode::Solid: return "solid";
    case LatticeRegionMode::Declared: return "declared";
    case LatticeRegionMode::Optimised: return "optimised";
  }
  // Never a silent fallback: an unnamed enumerator is a programming error, and
  // returning "unknown" would let it reach a receipt as though it were a mode.
  throw std::logic_error("lattice_region_mode_name: unnamed LatticeRegionMode");
}

const char* lattice_region_cell_mode_name(LatticeRegionCellMode m) {
  switch (m) {
    case LatticeRegionCellMode::Fixed: return "fixed";
    case LatticeRegionCellMode::Fit: return "fit";
  }
  throw std::logic_error(
      "lattice_region_cell_mode_name: unnamed LatticeRegionCellMode");
}

double lattice_density_heaviside(double t, double steepness) {
  if (!(steepness > 0.0))
    throw std::invalid_argument(
        "lattice_density_heaviside: steepness must be > 0");
  const double u = t / steepness;
  // Branch on the sign so neither exp() overflows: both branches are the same
  // function, written so the exponent is always <= 0.
  if (u >= 0.0) {
    const double e = std::exp(-u);
    return 1.0 / (1.0 + e);
  }
  const double e = std::exp(u);
  return e / (1.0 + e);
}

double lattice_density_heaviside_deriv(double t, double steepness) {
  const double h = lattice_density_heaviside(t, steepness);
  return h * (1.0 - h) / steepness;
}

LatticeBetaKnots lattice_beta_knots_for_grid(const VoxelGrid& grid, double phi_dx,
                                             double phi_dy, double phi_dz) {
  // FOUR TIMES phi's spacing, per axis, no minimum and no maximum taken over the
  // axes. Stated before it was measured. When phi's spacing is unset (all zero)
  // the fallback is an eighth of the grid's LONGEST axis, floored at 4 voxels —
  // again per axis and again with no min/max over axes, only a floor that stops
  // the lattice degenerating on a thin slab.
  const double have = phi_dx + phi_dy + phi_dz;
  LatticeBetaKnots k;
  if (have > 0.0) {
    k.dx = 4.0 * phi_dx;
    k.dy = 4.0 * phi_dy;
    k.dz = 4.0 * phi_dz;
  } else {
    const double longest = static_cast<double>(
        std::max({grid.nx, grid.ny, grid.nz}));
    const double s = std::max(4.0, longest / 8.0);
    k.dx = k.dy = k.dz = s;
  }
  return k;
}

namespace {

// The band a region's density is admissible in: the topology's own certifiable
// band, intersected with whatever the region narrowed it to. A caller may narrow,
// never widen.
void region_band(const LatticeRegionSpec& r, LatticeTopology topo, double* lo,
                 double* hi) {
  const double band_lo = lattice_rho_min(topo);
  const double band_hi = lattice_rho_max(topo);
  double l = band_lo, h = band_hi;
  if (r.optimised_rho_min > 0.0) l = std::max(l, r.optimised_rho_min);
  if (r.optimised_rho_max > 0.0) h = std::min(h, r.optimised_rho_max);
  if (!(h >= l)) {
    // A narrowing that empties the band is a declaration error, not something to
    // silently widen back out.
    throw std::invalid_argument(
        "resolve_lattice_density_field: region " + std::to_string(r.id) +
        " narrows the admissible density band to nothing (" +
        std::to_string(l) + " > " + std::to_string(h) + ")");
  }
  *lo = l;
  *hi = h;
}

std::unordered_map<int, std::size_t> index_regions(
    const std::vector<LatticeRegionSpec>& regions) {
  std::unordered_map<int, std::size_t> by_id;
  for (std::size_t i = 0; i < regions.size(); ++i) {
    if (regions[i].id <= 0)
      throw std::invalid_argument(
          "lattice density field: region ids are 1-based and must be > 0");
    if (!by_id.emplace(regions[i].id, i).second)
      throw std::invalid_argument(
          "lattice density field: duplicate region id " +
          std::to_string(regions[i].id));
  }
  return by_id;
}

double percentile_sorted(const std::vector<double>& v, double p) {
  if (v.empty()) return 0.0;
  const double x = p * static_cast<double>(v.size() - 1);
  const std::size_t lo = static_cast<std::size_t>(std::floor(x));
  const std::size_t hi = std::min(v.size() - 1, lo + 1);
  const double w = x - static_cast<double>(lo);
  return v[lo] * (1.0 - w) + v[hi] * w;
}

}  // namespace

bool lattice_density_printable(LatticeTopology topo, double rho, double cell_mm,
                               double min_extrudable_width_mm) {
  if (topo != LatticeTopology::Octet) {
    // Only octet carries a measured strut-diameter table. Refusing is the same
    // answer `lattice_min_density_for_strut` gives, and for the same reason:
    // there is no measurement to borrow.
    return false;
  }
  return octet_strut_diameter_mm(rho, cell_mm) >= min_extrudable_width_mm;
}

std::vector<LatticeRegionValidity> lattice_region_validity(
    const VoxelGrid& grid, const std::vector<int>& region_id,
    const std::vector<LatticeRegionSpec>& regions,
    const std::vector<double>& member_width_mm, LatticeTopology topo,
    double cell_mm, double min_extrudable_width_mm) {
  if (region_id.size() != grid.voxel_count())
    throw std::invalid_argument(
        "lattice_region_validity: region_id size != grid.voxel_count()");
  if (member_width_mm.size() != grid.voxel_count())
    throw std::invalid_argument(
        "lattice_region_validity: member_width_mm size != grid.voxel_count()");
  if (!(cell_mm > 0.0))
    throw std::invalid_argument("lattice_region_validity: cell_mm must be > 0");

  const auto by_id = index_regions(regions);
  const double floor_cert = lattice_cells_per_member_min(topo);
  const double floor_build = lattice_percolation_cells_per_member_min(topo);

  std::vector<std::vector<double>> widths(regions.size());
  for (std::size_t e = 0; e < region_id.size(); ++e) {
    if (region_id[e] <= 0) continue;
    const auto it = by_id.find(region_id[e]);
    if (it == by_id.end()) continue;
    widths[it->second].push_back(member_width_mm[e]);
  }

  std::vector<LatticeRegionValidity> out(regions.size());
  for (std::size_t i = 0; i < regions.size(); ++i) {
    LatticeRegionValidity& v = out[i];
    v.id = regions[i].id;
    v.name = regions[i].name;
    v.cell_mm = cell_mm;
    v.floor_certifiable = floor_cert;
    v.floor_buildable = floor_build;
    v.lightest_printable_density =
        topo == LatticeTopology::Octet
            ? lattice_min_density_for_strut(topo, cell_mm,
                                            min_extrudable_width_mm)
            : -1.0;
    std::vector<double>& w = widths[i];
    v.voxels = w.size();
    if (w.empty()) {
      v.refusal = "region " + std::to_string(v.id) +
                  " owns no voxel on this grid — nothing to lattice";
      continue;
    }
    std::sort(w.begin(), w.end());
    v.member_width_min_mm = w.front();
    v.member_width_p10_mm = percentile_sorted(w, 0.10);
    v.member_width_median_mm = percentile_sorted(w, 0.50);
    v.cells_per_member_median = v.member_width_median_mm / cell_mm;
    v.cells_per_member_p10 = v.member_width_p10_mm / cell_mm;

    std::size_t above = 0;
    for (double x : w)
      if (x / cell_mm >= floor_cert) ++above;
    v.fraction_above_floor =
        static_cast<double>(above) / static_cast<double>(w.size());

    // ★ THE FITTED CELL, and the thinnest member that clears the CERTIFIABLE
    // floor at this nozzle. `lattice_derive_cell_for_member` answers both from
    // the region's OWN width: the coarsest admissible cell is exactly N* cells
    // across, and the lightest density whose strut still prints there is the
    // minimum-mass certified lattice for that member.
    //
    // Computed for EVERY region, whatever cell mode it asked for, so a refusal
    // under a fixed cell can name the cell that WOULD have worked rather than
    // just saying no. It refuses a non-positive width, and a region whose median
    // width is 0 is a region of unprinted voxels — reported, not passed on.
    if (v.member_width_median_mm > 0.0) {
      const LatticeCellDerivation d = lattice_derive_cell_for_member(
          topo, v.member_width_median_mm, min_extrudable_width_mm);
      v.min_member_width_certifiable_mm = d.min_member_width_certifiable_mm;
      v.fit_feasible = d.feasible;
      if (d.feasible) {
        v.fit_cell_mm = d.lightest_cell_size_mm;
        v.fit_min_density = d.lightest_relative_density;
        v.fit_strut_diameter_mm = d.lightest_strut_diameter_mm;
      }
    }

    v.in_validity_range = v.cells_per_member_median >= floor_cert;
    v.buildable_not_certifiable =
        !v.in_validity_range && v.cells_per_member_median >= floor_build;
    if (!v.in_validity_range) {
      char buf[512];
      // ★ A REFUSAL MUST CARRY THE NUMBER THAT FIXES IT. When the region WOULD
      // work at a cell derived from its own thickness, say so and give that
      // cell — "too thin for a 2 mm cell" and "cannot be latticed" are very
      // different statements and only one of them is usually true.
      if (v.fit_feasible) {
        std::snprintf(
            buf, sizeof buf,
            "region %d spans %.3f mm at the median, which is %.2f cells per "
            "member at the run's %.3f mm cell — below the %.1f-cell "
            "homogenisation floor the certificate needs. ★ IT FITS AT ITS OWN "
            "CELL: at %.4f mm this member holds exactly %.1f cells, and the "
            "lightest density that still prints there at a %.3f mm strut width "
            "is %.4f (strut %.4f mm). Set this region's cell mode to FIT, or "
            "lower the run's cell to %.4f mm.",
            v.id, v.member_width_median_mm, v.cells_per_member_median, cell_mm,
            floor_cert, v.fit_cell_mm, floor_cert, min_extrudable_width_mm,
            v.fit_min_density, v.fit_strut_diameter_mm, v.fit_cell_mm);
      } else {
        std::snprintf(
            buf, sizeof buf,
            "region %d spans %.3f mm at the median, which is %.2f cells per "
            "member at a %.3f mm cell — below the %.1f-cell homogenisation floor "
            "the certificate needs%s. ★ AND NO FINER CELL RESCUES IT: at a %.3f "
            "mm strut width no (cell, density) pair in the band fits a member "
            "this thin. It must be at least %.4f mm across, or the strut width "
            "must come down.",
            v.id, v.member_width_median_mm, v.cells_per_member_median, cell_mm,
            floor_cert,
            v.buildable_not_certifiable
                ? " (it clears the percolation floor, so it is BUILDABLE AND "
                  "UNCERTIFIABLE, not un-latticeable)"
                : "",
            min_extrudable_width_mm, v.min_member_width_certifiable_mm);
      }
      v.refusal = buf;
    }
  }
  return out;
}

ResolvedLatticeDensityField resolve_lattice_density_field(
    const VoxelGrid& grid, const std::vector<int>& region_id,
    const std::vector<LatticeRegionSpec>& regions, LatticeTopology topo,
    const LatticeBetaField* beta, const std::vector<char>* only_where,
    const std::vector<int>& refused,
    const std::vector<LatticeRegionValidity>* validity) {
  const std::size_t n = grid.voxel_count();
  if (region_id.size() != n)
    throw std::invalid_argument(
        "resolve_lattice_density_field: region_id size != grid.voxel_count()");
  if (only_where != nullptr && only_where->size() != n)
    throw std::invalid_argument(
        "resolve_lattice_density_field: only_where size != grid.voxel_count()");
  if (beta != nullptr && beta->beta.size() != beta->lattice.count())
    throw std::invalid_argument(
        "resolve_lattice_density_field: beta coefficient count (" +
        std::to_string(beta->beta.size()) + ") != its knot lattice count (" +
        std::to_string(beta->lattice.count()) + ")");

  const auto by_id = index_regions(regions);

  ResolvedLatticeDensityField out;
  out.region_latticed_voxels.assign(regions.size(), 0);
  out.region_freed_mass_voxels.assign(regions.size(), 0.0);
  out.region_mean_rho.assign(regions.size(), 0.0);
  out.region_cell_mm.assign(regions.size(), 0.0);
  out.region_density_raised.assign(regions.size(), 0);
  out.refused_region_ids = refused;

  if (validity != nullptr && validity->size() != regions.size())
    throw std::invalid_argument(
        "resolve_lattice_density_field: validity size != regions size — it is "
        "parallel to `regions` or it is absent");

  // ★ A FITTED REGION NEEDS SOMETHING TO FIT TO. Falling back to the run's cell
  // would silently give it the very cell it was declared Fit to escape.
  for (const LatticeRegionSpec& r : regions) {
    if (r.cell_mode != LatticeRegionCellMode::Fit) continue;
    if (std::find(refused.begin(), refused.end(), r.id) != refused.end()) continue;
    if (r.mode == LatticeRegionMode::Solid) continue;
    if (validity == nullptr)
      throw std::invalid_argument(
          "resolve_lattice_density_field: region " + std::to_string(r.id) +
          " is in cell mode FIT but no validity was supplied to fit against "
          "(run lattice_region_validity first and pass it)");
  }

  // Nothing to emit at all? Leave `mask` / `rho` EMPTY rather than allocating two
  // grid-sized zero vectors, so a caller can test `empty()` and take the
  // byte-identical path without touching a single voxel.
  bool any_emitting = false;
  for (const LatticeRegionSpec& r : regions) {
    if (std::find(refused.begin(), refused.end(), r.id) != refused.end()) continue;
    if (r.mode == LatticeRegionMode::Solid) continue;
    if (r.mode == LatticeRegionMode::Declared &&
        r.declared_density >= kLatticeSolidAt)
      continue;
    if (r.mode == LatticeRegionMode::Optimised && beta == nullptr)
      throw std::invalid_argument(
          "resolve_lattice_density_field: region " + std::to_string(r.id) +
          " is in Optimised mode but no beta field was supplied");
    any_emitting = true;
  }
  if (!any_emitting) return out;

  out.mask.assign(n, 0);
  out.rho.assign(n, 0.0);

  std::vector<double> rho_sum(regions.size(), 0.0);
  std::vector<int> idx;
  std::vector<double> w;

  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        if (region_id[e] <= 0) continue;
        if (only_where != nullptr && !(*only_where)[e]) continue;
        const auto it = by_id.find(region_id[e]);
        if (it == by_id.end()) continue;
        const LatticeRegionSpec& r = regions[it->second];
        if (std::find(refused.begin(), refused.end(), r.id) != refused.end())
          continue;
        if (r.mode == LatticeRegionMode::Solid) continue;

        double lo = 0.0, hi = 0.0;
        region_band(r, topo, &lo, &hi);

        // ★ THE CELL THIS REGION IS ACTUALLY BUILT AT, and the density floor
        // that comes with it. A FITTED region takes the coarsest cell its own
        // thickness can homogenise; everything else takes the run's.
        double cell_here = 0.0, printable_floor = 0.0;
        if (r.cell_mode == LatticeRegionCellMode::Fit) {
          const LatticeRegionValidity& vv = (*validity)[it->second];
          if (!vv.fit_feasible) continue;  // refused upstream; emit nothing
          cell_here = vv.fit_cell_mm;
          printable_floor = vv.fit_min_density;
        }

        double rho;
        if (r.mode == LatticeRegionMode::Declared) {
          if (!std::isfinite(r.declared_density))
            throw std::invalid_argument(
                "resolve_lattice_density_field: region " +
                std::to_string(r.id) + " declared a non-finite density");
          // ★ C0: f = 1.0 IS SOLID. Emit nothing — not a clamp to rho_hi, which
          // would silently turn "leave this solid" into "lattice it at 0.90".
          if (r.declared_density >= kLatticeSolidAt) continue;
          rho = std::min(hi, std::max(lo, r.declared_density));
          // ★ RAISED TO PRINT, AND REPORTED. A fitted cell changes which
          // densities come out of the nozzle; emitting a strut thinner than one
          // bead because the user typed a lighter number is the one outcome a
          // mass feature must not have. The raise is recorded per region so the
          // receipt can say the user asked for one mass and got another.
          if (printable_floor > 0.0 && rho < printable_floor) {
            rho = std::min(hi, printable_floor);
            out.region_density_raised[it->second] = 1;
          }
        } else {
          // MODE 2's band takes the fitted cell's printable floor as its LOWER
          // bound, so the optimiser cannot choose a density that does not print.
          if (printable_floor > 0.0) lo = std::max(lo, std::min(hi, printable_floor));
          idx.clear();
          w.clear();
          plsm_support_of(beta->lattice, beta->basis, static_cast<double>(i),
                          static_cast<double>(j), static_cast<double>(k), idx, w);
          double t = 0.0;
          for (std::size_t q = 0; q < idx.size(); ++q)
            t += beta->beta[static_cast<std::size_t>(idx[q])] * w[q];
          rho = lo + (hi - lo) * lattice_density_heaviside(t, beta->steepness);
        }

        out.mask[e] = 1;
        out.rho[e] = rho;
        if (cell_here > 0.0) {
          if (out.cell_mm.empty()) out.cell_mm.assign(n, 0.0);
          out.cell_mm[e] = cell_here;
          out.region_cell_mm[it->second] = cell_here;
        }
        ++out.latticed_voxels;
        out.freed_mass_voxels += 1.0 - rho;
        ++out.region_latticed_voxels[it->second];
        out.region_freed_mass_voxels[it->second] += 1.0 - rho;
        rho_sum[it->second] += rho;
      }

  for (std::size_t q = 0; q < regions.size(); ++q)
    out.region_mean_rho[q] =
        out.region_latticed_voxels[q] > 0
            ? rho_sum[q] / static_cast<double>(out.region_latticed_voxels[q])
            : 0.0;

  if (out.latticed_voxels == 0) {
    // Every emitting region turned out to own no eligible voxel. Hand back the
    // EMPTY field so the caller's byte-identical test still fires.
    out.mask.clear();
    out.rho.clear();
    out.cell_mm.clear();
  }
  return out;
}

PlsmCsr lattice_beta_jacobian(const VoxelGrid& grid,
                              const std::vector<int>& region_id,
                              const std::vector<LatticeRegionSpec>& regions,
                              LatticeTopology topo, const LatticeBetaField& beta,
                              const std::vector<char>* only_where,
                              const std::vector<int>& refused, int threads) {
  const std::size_t n = grid.voxel_count();
  if (region_id.size() != n)
    throw std::invalid_argument(
        "lattice_beta_jacobian: region_id size != grid.voxel_count()");
  if (only_where != nullptr && only_where->size() != n)
    throw std::invalid_argument(
        "lattice_beta_jacobian: only_where size != grid.voxel_count()");
  if (beta.beta.size() != beta.lattice.count())
    throw std::invalid_argument(
        "lattice_beta_jacobian: beta coefficient count != knot lattice count");

  const auto by_id = index_regions(regions);

  // Which voxels couple, and to which band. Precomputed so both CSR passes agree
  // by construction rather than by two copies of the same test.
  std::vector<char> couples(n, 0);
  std::vector<double> span(n, 0.0);  // (hi - lo) at that voxel
  for (std::size_t e = 0; e < n; ++e) {
    if (region_id[e] <= 0) continue;
    if (only_where != nullptr && !(*only_where)[e]) continue;
    const auto it = by_id.find(region_id[e]);
    if (it == by_id.end()) continue;
    const LatticeRegionSpec& r = regions[it->second];
    if (r.mode != LatticeRegionMode::Optimised) continue;
    if (std::find(refused.begin(), refused.end(), r.id) != refused.end()) continue;
    double lo = 0.0, hi = 0.0;
    region_band(r, topo, &lo, &hi);
    couples[e] = 1;
    span[e] = hi - lo;
  }

  PlsmCsr J;
  J.rows = n;
  J.cols = beta.lattice.count();
  J.row.assign(J.rows + 1, 0);

  std::vector<int> per_row(n, 0);
  plsm_parallel_for(n, threads, [&](std::size_t v) {
    if (!couples[v]) return;
    const int i = static_cast<int>(v % static_cast<std::size_t>(grid.nx));
    const int j = static_cast<int>((v / static_cast<std::size_t>(grid.nx)) %
                                   static_cast<std::size_t>(grid.ny));
    const int k = static_cast<int>(v / (static_cast<std::size_t>(grid.nx) *
                                        static_cast<std::size_t>(grid.ny)));
    std::vector<int> idx;
    std::vector<double> w;
    plsm_support_of(beta.lattice, beta.basis, i, j, k, idx, w);
    per_row[v] = static_cast<int>(idx.size());
  });
  for (std::size_t v = 0; v < n; ++v)
    J.row[v + 1] = J.row[v] + static_cast<std::size_t>(per_row[v]);
  J.col.resize(J.row[n]);
  J.val.resize(J.row[n]);

  plsm_parallel_for(n, threads, [&](std::size_t v) {
    if (!couples[v]) return;
    const int i = static_cast<int>(v % static_cast<std::size_t>(grid.nx));
    const int j = static_cast<int>((v / static_cast<std::size_t>(grid.nx)) %
                                   static_cast<std::size_t>(grid.ny));
    const int k = static_cast<int>(v / (static_cast<std::size_t>(grid.nx) *
                                        static_cast<std::size_t>(grid.ny)));
    std::vector<int> idx;
    std::vector<double> w;
    plsm_support_of(beta.lattice, beta.basis, i, j, k, idx, w);
    double t = 0.0;
    for (std::size_t q = 0; q < idx.size(); ++q)
      t += beta.beta[static_cast<std::size_t>(idx[q])] * w[q];
    // rho = lo + (hi - lo) H(t),  t = sum_j beta_j psi_j
    //   => d rho / d beta_j = (hi - lo) H'(t) psi_j
    const double g = span[v] * lattice_density_heaviside_deriv(t, beta.steepness);
    std::size_t p = J.row[v];
    for (std::size_t q = 0; q < idx.size(); ++q, ++p) {
      J.col[p] = idx[q];
      J.val[p] = g * w[q];
    }
  });
  return J;
}

std::vector<double> lattice_beta_chain(const PlsmCsr& jacobian,
                                       const std::vector<double>& dF_drho) {
  if (dF_drho.size() != jacobian.rows)
    throw std::invalid_argument(
        "lattice_beta_chain: dF_drho size != jacobian.rows");
  std::vector<double> g(jacobian.cols, 0.0);
  // Serial, and deliberately. The accumulation is a scatter into a shared vector
  // whose ORDER sets the rounding, so a thread-count-dependent partition would
  // make the gradient depend on how many cores ran it — the one property a
  // gradient must not have. It is O(nnz) with nnz = latticed voxels x the basis
  // support (~27), which is under a millisecond beside the state solve it is
  // chained onto (evidence/…/m5/cost.txt).
  for (std::size_t e = 0; e < jacobian.rows; ++e) {
    const double s = dF_drho[e];
    if (s == 0.0) continue;
    for (std::size_t p = jacobian.row[e]; p < jacobian.row[e + 1]; ++p)
      g[static_cast<std::size_t>(jacobian.col[p])] += s * jacobian.val[p];
  }
  return g;
}

LatticeFieldCoupling::LatticeFieldCoupling(
    const VoxelGrid& grid, std::vector<int> region_id,
    std::vector<LatticeRegionSpec> regions, LatticeTopology topo,
    LatticeBetaField beta, std::vector<char> only_where,
    std::vector<int> refused, std::vector<LatticeRegionValidity> validity,
    double allowance_voxels, bool shares_budget, double beta_box, int threads)
    : grid_(grid),
      region_id_(std::move(region_id)),
      regions_(std::move(regions)),
      topo_(topo),
      beta_(std::move(beta)),
      only_where_(std::move(only_where)),
      refused_(std::move(refused)),
      validity_(std::move(validity)),
      allowance_(allowance_voxels),
      shares_(shares_budget),
      box_(beta_box),
      threads_(threads) {
  if (!(box_ > 0.0))
    throw std::invalid_argument(
        "LatticeFieldCoupling: beta_box must be > 0");
  refresh();
  // ★ The allowance defaults to WHAT THE SEED OCCUPIES when the caller passes a
  // non-positive one. Under BANKED that holds the region at the mass Mode 1
  // would have printed, which is the whole meaning of "banked": the saving is
  // already taken, and Mode 2 only redistributes what is left.
  if (!(allowance_ > 0.0)) allowance_ = occupied_;
}

void LatticeFieldCoupling::refresh() {
  // ★ The SAME validity the run resolved its seed field with — a fitted region's
  // cell and density floor come from it, so resolving without it here would move
  // the field the optimiser is stepping to a different cell than the one the run
  // certified against.
  field_ = resolve_lattice_density_field(
      grid_, region_id_, regions_, topo_, &beta_, &only_where_, refused_,
      validity_.empty() ? nullptr : &validity_);
  const std::size_t n = grid_.voxel_count();
  lr_.assign(n, -1.0);
  occupied_ = 0.0;
  if (!field_.empty())
    for (std::size_t e = 0; e < n; ++e)
      if (field_.mask[e]) {
        lr_[e] = field_.rho[e];
        occupied_ += field_.rho[e];
      }
  // Rebuilt at THIS beta — see the header. A cached Jacobian would be the
  // gradient of a field the solve never used.
  jac_ = lattice_beta_jacobian(grid_, region_id_, regions_, topo_, beta_,
                               &only_where_, refused_, threads_);
}

void LatticeFieldCoupling::set_coefficients(const std::vector<double>& b) {
  if (b.size() != beta_.beta.size())
    throw std::invalid_argument(
        "LatticeFieldCoupling::set_coefficients: size != coefficient count");
  beta_.beta = b;
  refresh();
}

std::vector<double> LatticeFieldCoupling::chain(
    const std::vector<double>& dF_drho) const {
  return lattice_beta_chain(jac_, dF_drho);
}

}  // namespace topopt
