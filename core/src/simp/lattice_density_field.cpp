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

    // The thinnest member that clears the CERTIFIABLE floor at this nozzle, at
    // any (cell, density) pair in the band. `lattice_derive_cell_for_member`
    // refuses a non-positive width, and a region whose median width is 0 is a
    // region of unprinted voxels — reported, not passed on.
    if (v.member_width_median_mm > 0.0) {
      const LatticeCellDerivation d = lattice_derive_cell_for_member(
          topo, v.member_width_median_mm, min_extrudable_width_mm);
      v.min_member_width_certifiable_mm = d.min_member_width_certifiable_mm;
    }

    v.in_validity_range = v.cells_per_member_median >= floor_cert;
    v.buildable_not_certifiable =
        !v.in_validity_range && v.cells_per_member_median >= floor_build;
    if (!v.in_validity_range) {
      char buf[512];
      std::snprintf(
          buf, sizeof buf,
          "region %d spans %.3f mm at the median, which is %.2f cells per member "
          "at a %.3f mm cell — below the %.1f-cell homogenisation floor the "
          "certificate needs%s. The rho->stiffness law is OUT OF ITS VALIDITY "
          "RANGE here: no density in the band is certifiable for this member "
          "until it is at least %.4f mm across (or the cell gets finer).",
          v.id, v.member_width_median_mm, v.cells_per_member_median, cell_mm,
          floor_cert,
          v.buildable_not_certifiable
              ? " (it clears the percolation floor, so it is BUILDABLE AND "
                "UNCERTIFIABLE, not un-latticeable)"
              : "",
          v.min_member_width_certifiable_mm);
      v.refusal = buf;
    }
  }
  return out;
}

ResolvedLatticeDensityField resolve_lattice_density_field(
    const VoxelGrid& grid, const std::vector<int>& region_id,
    const std::vector<LatticeRegionSpec>& regions, LatticeTopology topo,
    const LatticeBetaField* beta, const std::vector<char>* only_where,
    const std::vector<int>& refused) {
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
  out.refused_region_ids = refused;

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
        } else {
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

}  // namespace topopt
