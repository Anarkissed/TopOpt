#include "topopt/flexible/field.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <map>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "topopt/flexible/curve.hpp"

namespace topopt {
namespace flexible {
namespace {

std::string fmt(double v) {
  char b[40];
  std::snprintf(b, sizeof(b), "%.4g", v);
  return b;
}

double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }

// Squared Euclidean distance (in cells) from every INSIDE cell centre to the nearest
// OUTSIDE cell centre; cells beyond the grid count as outside. Felzenszwalb &
// Huttenlocher's separable exact transform.
std::vector<double> edt2_inside(int nu, int nv, const std::vector<char>& inside) {
  const int pu = nu + 2, pv = nv + 2;  // one outside cell of padding all round
  const double INF = 1e20;
  std::vector<double> f(static_cast<std::size_t>(pu) * static_cast<std::size_t>(pv), 0.0);
  for (int j = 0; j < nv; ++j)
    for (int i = 0; i < nu; ++i)
      if (inside[static_cast<std::size_t>(j) * static_cast<std::size_t>(nu) + static_cast<std::size_t>(i)])
        f[static_cast<std::size_t>(j + 1) * static_cast<std::size_t>(pu) + static_cast<std::size_t>(i + 1)] = INF;
  auto pass = [&](int n, int stride, int count, int step) {
    std::vector<double> g(static_cast<std::size_t>(n)), d(static_cast<std::size_t>(n));
    std::vector<int> v(static_cast<std::size_t>(n));
    std::vector<double> z(static_cast<std::size_t>(n) + 1);
    for (int line = 0; line < count; ++line) {
      const std::size_t base = static_cast<std::size_t>(line) * static_cast<std::size_t>(step);
      for (int q = 0; q < n; ++q) g[static_cast<std::size_t>(q)] = f[base + static_cast<std::size_t>(q) * static_cast<std::size_t>(stride)];
      int k = 0;
      v[0] = 0;
      z[0] = -INF;
      z[1] = INF;
      for (int q = 1; q < n; ++q) {
        double s;
        while (true) {
          const int r = v[static_cast<std::size_t>(k)];
          s = ((g[static_cast<std::size_t>(q)] + double(q) * q) - (g[static_cast<std::size_t>(r)] + double(r) * r)) / (2.0 * (q - r));
          if (s <= z[static_cast<std::size_t>(k)] && k > 0) {
            --k;
            continue;
          }
          break;
        }
        ++k;
        v[static_cast<std::size_t>(k)] = q;
        z[static_cast<std::size_t>(k)] = s;
        z[static_cast<std::size_t>(k) + 1] = INF;
      }
      k = 0;
      for (int q = 0; q < n; ++q) {
        while (z[static_cast<std::size_t>(k) + 1] < q) ++k;
        const int r = v[static_cast<std::size_t>(k)];
        d[static_cast<std::size_t>(q)] = double(q - r) * (q - r) + g[static_cast<std::size_t>(r)];
      }
      for (int q = 0; q < n; ++q) f[base + static_cast<std::size_t>(q) * static_cast<std::size_t>(stride)] = d[static_cast<std::size_t>(q)];
    }
  };
  pass(pu, 1, pv, pu);  // along u, one line per v row
  pass(pv, pu, pu, 1);  // along v, one line per u column
  std::vector<double> out(static_cast<std::size_t>(nu) * static_cast<std::size_t>(nv), 0.0);
  for (int j = 0; j < nv; ++j)
    for (int i = 0; i < nu; ++i)
      out[static_cast<std::size_t>(j) * static_cast<std::size_t>(nu) + static_cast<std::size_t>(i)] =
          f[static_cast<std::size_t>(j + 1) * static_cast<std::size_t>(pu) + static_cast<std::size_t>(i + 1)];
  return out;
}

void accumulate(Range1& r, double v, int& n) {
  if (!r.any) {
    r.any = true;
    r.min = r.max = v;
    r.mean = 0.0;
  }
  r.min = std::min(r.min, v);
  r.max = std::max(r.max, v);
  r.mean += v;
  ++n;
}
void finish(Range1& r, int n) {
  if (n > 0) r.mean /= n;
}

// Is model point p inside stack s? Returns the column and the depth below the face.
bool in_stack(const Stack& s, const Vec3& p, int& col, double& depth) {
  double u = 0, v = 0;
  s.frame.to_uv(p, u, v);
  const int iu = static_cast<int>(std::floor(u / s.pitch_mm));
  const int iv = static_cast<int>(std::floor(v / s.pitch_mm));
  col = s.column_at(iu, iv);
  if (col < 0) return false;
  const StackColumn& c = s.columns[static_cast<std::size_t>(col)];
  const double t = dot(sub(p, s.frame.centroid), s.frame.load);
  if (t < c.entry_t - 1e-9 || t > c.exit_t + 1e-9) return false;
  depth = t - c.entry_t;
  return true;
}

}  // namespace

double stamp_force_n(const StampGrid& s) {
  double f = 0.0;
  for (double v : s.values_mpa) f += v;
  return f * s.cell_mm * s.cell_mm;
}

std::string stamp_grid_error(const StampGrid& s) {
  const std::string who = "stamp \"" + s.name + "\": ";
  if (s.nu < 1 || s.nv < 1) return who + "needs at least one cell in each direction";
  if (!(s.cell_mm > 0.0) || !std::isfinite(s.cell_mm)) return who + "cell_mm must be > 0";
  if (s.values_mpa.size() != static_cast<std::size_t>(s.nu) * static_cast<std::size_t>(s.nv))
    return who + "has " + std::to_string(s.values_mpa.size()) + " values for a " +
           std::to_string(s.nu) + " x " + std::to_string(s.nv) + " grid";
  if (!std::isfinite(s.origin_u_mm) || !std::isfinite(s.origin_v_mm))
    return who + "origin must be finite";
  bool pressed = false;
  for (double v : s.values_mpa) {
    if (!std::isfinite(v) || v < 0.0) return who + "every pressure must be finite and >= 0";
    if (v > 0.0) pressed = true;
  }
  if (!pressed) return who + "presses nowhere (every cell is 0)";
  if (!(s.force_n > 0.0) || !std::isfinite(s.force_n)) return who + "force_n must be > 0";
  const double f = stamp_force_n(s);
  if (std::fabs(f - s.force_n) > kStampForceTolerance * s.force_n)
    return who + "its cells add up to " + fmt(f) + " N but it states " + fmt(s.force_n) +
           " N (more than 0.5 % apart)";
  return "";
}

StampOnColumns stamp_on_columns(const StampGrid& s, const Stack& stack) {
  const std::string err = stamp_grid_error(s);
  if (!err.empty()) throw FlexibleError(err);
  StampOnColumns out;
  out.pressure_mpa.assign(stack.columns.size(), 0.0);
  out.covered.assign(stack.columns.size(), 0);
  out.covered_area_mm2.assign(stack.columns.size(), 0.0);
  const double p = stack.pitch_mm, c = s.cell_mm;
  for (int j = 0; j < s.nv; ++j)
    for (int i = 0; i < s.nu; ++i) {
      const double val = s.values_mpa[static_cast<std::size_t>(j) * static_cast<std::size_t>(s.nu) + static_cast<std::size_t>(i)];
      if (!(val > 0.0)) continue;
      const double u0 = s.origin_u_mm + i * c, u1 = u0 + c;
      const double v0 = s.origin_v_mm + j * c, v1 = v0 + c;
      double landed = 0.0;
      const int ci0 = static_cast<int>(std::floor(u0 / p)), ci1 = static_cast<int>(std::floor(u1 / p));
      const int cj0 = static_cast<int>(std::floor(v0 / p)), cj1 = static_cast<int>(std::floor(v1 / p));
      for (int cj = cj0; cj <= cj1; ++cj)
        for (int ci = ci0; ci <= ci1; ++ci) {
          const int col = stack.column_at(ci, cj);
          if (col < 0) continue;
          const double ou = std::min(u1, (ci + 1) * p) - std::max(u0, ci * p);
          const double ov = std::min(v1, (cj + 1) * p) - std::max(v0, cj * p);
          if (!(ou > 0.0) || !(ov > 0.0)) continue;
          const double a = ou * ov;
          out.pressure_mpa[static_cast<std::size_t>(col)] +=
              val * a / stack.columns[static_cast<std::size_t>(col)].area_mm2;
          out.covered[static_cast<std::size_t>(col)] = 1;
          out.covered_area_mm2[static_cast<std::size_t>(col)] += a;
          landed += a;
        }
      out.force_on_face_n += val * landed;
      out.force_off_face_n += val * (c * c - landed);
    }
  return out;
}

double stamp_width_mm(const StampGrid& s) {
  const std::string err = stamp_grid_error(s);
  if (!err.empty()) throw FlexibleError(err);
  std::vector<char> in(s.values_mpa.size(), 0);
  for (std::size_t i = 0; i < in.size(); ++i) in[i] = s.values_mpa[i] > 0.0;
  const std::vector<double> d2 = edt2_inside(s.nu, s.nv, in);
  double dmax = 0.0;
  for (std::size_t i = 0; i < in.size(); ++i)
    if (in[i]) dmax = std::max(dmax, std::sqrt(d2[i]));
  // Cell centre -> nearest outside centre is D cells; the shape is (2D - 1) cells
  // across there: exact for an odd count, one cell under for an even one (the
  // conservative side for the narrow-stamp flag).
  return (2.0 * dmax - 1.0) * s.cell_mm;
}

std::vector<double> edge_fraction(const Stack& stack) {
  std::vector<char> in(static_cast<std::size_t>(stack.nu) * static_cast<std::size_t>(stack.nv), 0);
  for (const StackColumn& c : stack.columns)
    in[static_cast<std::size_t>(c.iv) * static_cast<std::size_t>(stack.nu) + static_cast<std::size_t>(c.iu)] = 1;
  const std::vector<double> d2 = edt2_inside(stack.nu, stack.nv, in);
  std::vector<double> t(stack.columns.size(), 0.0);
  double tmax = 0.0;
  for (std::size_t k = 0; k < stack.columns.size(); ++k) {
    const StackColumn& c = stack.columns[k];
    // the column centre sits half a pitch inside the boundary cell's edge
    t[k] = std::sqrt(d2[static_cast<std::size_t>(c.iv) * static_cast<std::size_t>(stack.nu) + static_cast<std::size_t>(c.iu)]) - 0.5;
    tmax = std::max(tmax, t[k]);
  }
  for (double& v : t) v = tmax > 0.0 ? v / tmax : 1.0;
  return t;
}

std::vector<double> squish_fraction(const Stack& stack, const SquishMap& map) {
  std::vector<double> s(stack.columns.size(), 0.0);
  if (map.mode == "both" || map.mode == "either") {
    const PenCurve X(map.x_x, map.x_y), Y(map.y_x, map.y_y);
    const double U = stack.frame.u_extent_mm, V = stack.frame.v_extent_mm;
    for (std::size_t k = 0; k < s.size(); ++k) {
      const double x = X(U > 0 ? stack.columns[k].u_mm / U : 0.5);
      const double y = Y(V > 0 ? stack.columns[k].v_mm / V : 0.5);
      s[k] = map.mode == "both" ? x * y : std::max(x, y);
    }
    return s;
  }
  if (map.mode == "centre_edge") {
    const PenCurve C(map.c_x, map.c_y);
    const std::vector<double> t = edge_fraction(stack);
    for (std::size_t k = 0; k < s.size(); ++k) s[k] = C(t[k]);
    return s;
  }
  throw FlexibleError("squish map mode must be \"both\", \"either\" or \"centre_edge\" (got \"" +
                      map.mode + "\")");
}

FaceDesign design_face(const CurveSet& set, const Stack& stack, const SquishMap& map,
                       double weight_n, const StampGrid* design_stamp, const BuildParams& build,
                       const TierBand& tier) {
  if (!(weight_n > 0.0) || !std::isfinite(weight_n))
    throw FlexibleError("face " + std::to_string(stack.face_region_id) + ": weight must be > 0");
  if (!(map.deepest_squish_mm > 0.0) || !std::isfinite(map.deepest_squish_mm))
    throw FlexibleError("face " + std::to_string(stack.face_region_id) +
                        ": deepest squish must be > 0");
  FaceDesign out;
  out.face_region_id = stack.face_region_id;
  out.tier = tier;
  const std::vector<double> S = squish_fraction(stack, map);
  out.design_pressure_even_mpa = weight_n / stack.footprint_area_mm2;
  std::vector<double> stamp_p(stack.columns.size(), 0.0);
  std::vector<char> stamp_cov(stack.columns.size(), 0);
  if (design_stamp != nullptr) {
    const StampOnColumns soc = stamp_on_columns(*design_stamp, stack);
    out.design_stamp_used = true;
    out.design_stamp_off_face_n = soc.force_off_face_n;
    stamp_p = soc.pressure_mpa;
    stamp_cov = soc.covered;
    if (design_stamp->rigid) {
      // A rigid stamp's pressure depends on the lattice under it; for DESIGN it is
      // read as its average over the footprint (what it presses on a map that sinks
      // evenly), and the receipt says so.
      double area = 0.0;
      for (std::size_t k = 0; k < stamp_cov.size(); ++k)
        if (stamp_cov[k]) area += stack.columns[k].area_mm2;
      for (std::size_t k = 0; k < stamp_cov.size(); ++k)
        if (stamp_cov[k]) stamp_p[k] = soc.force_on_face_n / area;
      out.design_stamp_rigid_averaged = true;
    }
  }
  const double lim = set.strain_limit();
  out.columns.resize(stack.columns.size());
  for (std::size_t k = 0; k < stack.columns.size(); ++k) {
    const StackColumn& sc = stack.columns[k];
    ColumnDesign& c = out.columns[k];
    c.s = S[k];
    c.height_mm = sc.lattice_mm;
    c.pressure_mpa = (stamp_cov[k] && stamp_p[k] > 0.0) ? stamp_p[k] : out.design_pressure_even_mpa;
    c.target_depth_mm = S[k] * map.deepest_squish_mm;
    if (!(c.height_mm > 0.0)) {
      c.status = "no_lattice";
      ++out.no_lattice;
      continue;
    }
    c.target_strain = c.target_depth_mm / c.height_mm;
    const InverseResult inv = density_for(set, c.target_strain, c.pressure_mpa);
    c.status = inv.status;
    if (inv.ok) {
      c.target_density = inv.core_density;
      c.target_extrapolated = inv.extrapolated;
      c.clamped_density = inv.core_density;
      c.clamped_depth_mm = c.target_depth_mm;
      ++out.ok;
      if (inv.extrapolated) ++out.target_extrapolated;
      continue;
    }
    if (inv.status == "too_firm" || inv.status == "too_soft") {
      (inv.status == "too_firm" ? out.too_firm : out.too_soft)++;
      c.clamped_density = inv.nearest_density;
      c.nearest_known = inv.nearest_known;
      c.nearest_depth_mm = inv.nearest_known ? inv.nearest_strain * c.height_mm : 0.0;
      c.clamped_depth_mm = inv.nearest_known ? c.nearest_depth_mm : lim * c.height_mm;
      continue;
    }
    // beyond_data: pull the target back to the strain limit, then re-invert.
    ++out.beyond_data;
    const InverseResult at_lim = density_for(set, lim, c.pressure_mpa);
    if (at_lim.ok)
      c.clamped_density = at_lim.core_density;
    else
      c.clamped_density = at_lim.status == "too_firm" ? set.density_min() : set.density_max();
    const StrainResult f = strain_under(set, c.pressure_mpa, c.clamped_density);
    c.nearest_known = f.ok;
    c.nearest_depth_mm = f.ok ? f.strain * c.height_mm : 0.0;
    c.clamped_depth_mm = f.ok ? c.nearest_depth_mm : lim * c.height_mm;
  }

  // F7: a Gaussian of σ = half the local cell, gathered over the face's columns.
  const double p = stack.pitch_mm;
  int nt = 0, nb = 0, nd = 0, nc = 0, ns = 0;
  for (std::size_t k = 0; k < stack.columns.size(); ++k) {
    ColumnDesign& c = out.columns[k];
    if (c.status == "no_lattice") continue;
    c.sigma_mm = 0.5 * cell_size_mm(build.topology, c.clamped_density, build.beads_per_wall,
                                    build.bead_width_mm);
    accumulate(out.sigma, c.sigma_mm, ns);
    const int r = static_cast<int>(std::ceil(3.0 * c.sigma_mm / p));
    const StackColumn& sc = stack.columns[k];
    double wsum = 0.0, rsum = 0.0;
    for (int dj = -r; dj <= r; ++dj)
      for (int di = -r; di <= r; ++di) {
        const int j = stack.column_at(sc.iu + di, sc.iv + dj);
        if (j < 0) continue;
        const ColumnDesign& o = out.columns[static_cast<std::size_t>(j)];
        if (o.status == "no_lattice") continue;
        const double d2 = p * p * (double(di) * di + double(dj) * dj);
        const double w = std::exp(-d2 / (2.0 * c.sigma_mm * c.sigma_mm));
        wsum += w;
        rsum += w * o.clamped_density;
      }
    c.buildable_density = rsum / wsum;
  }
  const double span = set.density_max() - set.density_min();
  for (std::size_t k = 0; k < stack.columns.size(); ++k) {
    ColumnDesign& c = out.columns[k];
    if (c.status == "no_lattice") continue;
    c.cell_mm = cell_size_mm(build.topology, c.buildable_density, build.beads_per_wall,
                             build.bead_width_mm);
    const StrainResult f = strain_under(set, c.pressure_mpa, c.buildable_density);
    c.buildable_ok = f.ok;
    if (f.ok) {
      c.buildable_depth_mm = f.strain * c.height_mm;
      c.buildable_extrapolated = f.extrapolated;
      if (f.extrapolated) ++out.buildable_extrapolated;
      out.max_smoothing_change_mm =
          std::max(out.max_smoothing_change_mm, std::fabs(c.buildable_depth_mm - c.clamped_depth_mm));
      accumulate(out.buildable_depth, c.buildable_depth_mm, nb);
    } else {
      ++out.buildable_beyond_data;
    }
    if (c.buildable_density - set.density_min() < 0.1 * span ||
        set.density_max() - c.buildable_density < 0.1 * span)
      ++out.near_edge;
    out.material_volume_mm3 += c.buildable_density * stack.columns[k].area_mm2 * c.height_mm;
    accumulate(out.target_depth, c.target_depth_mm, nt);
    accumulate(out.buildable_density, c.buildable_density, nd);
    accumulate(out.cell, c.cell_mm, nc);
  }
  finish(out.target_depth, nt);
  finish(out.buildable_depth, nb);
  finish(out.buildable_density, nd);
  finish(out.cell, nc);
  finish(out.sigma, ns);
  return out;
}

StampCheck check_stamp(const CurveSet& set, const Stack& stack,
                       const std::vector<double>& column_density, const StampGrid& stamp,
                       const BuildParams& build, const TierBand& tier) {
  if (column_density.size() != stack.columns.size())
    throw FlexibleError("check_stamp: one density per column is required");
  StampCheck out;
  out.name = stamp.name;
  out.rigid = stamp.rigid;
  out.tier = tier;
  const StampOnColumns soc = stamp_on_columns(stamp, stack);
  out.force_off_face_n = soc.force_off_face_n;
  out.stamp_width_mm = stamp_width_mm(stamp);
  out.depth_mm.assign(stack.columns.size(), -1.0);
  out.status.assign(stack.columns.size(), "");
  std::vector<std::size_t> under;
  for (std::size_t k = 0; k < stack.columns.size(); ++k) {
    if (!soc.covered[k] || !(soc.pressure_mpa[k] > 0.0)) continue;
    if (!(column_density[k] > 0.0) || !(stack.columns[k].lattice_mm > 0.0)) {
      if (stamp.rigid) ++out.rigid_unlatticed_columns;
      continue;
    }
    under.push_back(k);
    out.local_cell_mm = std::max(out.local_cell_mm,
                                 cell_size_mm(build.topology, column_density[k],
                                              build.beads_per_wall, build.bead_width_mm));
  }
  out.pressed_columns = static_cast<int>(under.size());
  out.narrow = out.local_cell_mm > 0.0 && out.stamp_width_mm < 3.0 * out.local_cell_mm;
  if (under.empty()) {
    out.refusal = Refusal{"no_lattice_under_stamp", "the stamp presses no latticed column"};
    return out;
  }
  if (!stamp.rigid) {
    for (std::size_t k : under) {
      const StrainResult f = strain_under(set, soc.pressure_mpa[k], column_density[k]);
      if (!f.ok) {
        out.status[k] = "beyond_data";
        ++out.beyond_data_columns;
        continue;
      }
      out.depth_mm[k] = f.strain * stack.columns[k].lattice_mm;
      out.status[k] = f.extrapolated ? "extrapolated" : "ok";
      if (f.extrapolated) ++out.extrapolated_columns;
      out.max_depth_mm = std::max(out.max_depth_mm, out.depth_mm[k]);
    }
    out.ok = true;
    return out;
  }
  // A rigid stamp resting partly on SOLID (a column with no lattice) is carried by the
  // solid: the independent-column model cannot say how far it sinks, so it refuses.
  if (out.rigid_unlatticed_columns > 0) {
    out.refusal = Refusal{"rigid_over_solid",
                          "the rigid stamp rests on " + std::to_string(out.rigid_unlatticed_columns) +
                              " columns with no lattice; the solid carries it and v1 does not model that"};
    return out;
  }
  // Each column takes the stamp only over the area the stamp covers in it.
  std::vector<double> a, h, rho;
  for (std::size_t k : under) {
    a.push_back(soc.covered_area_mm2[k]);
    h.push_back(stack.columns[k].lattice_mm);
    rho.push_back(column_density[k]);
  }
  const RigidResult r = rigid_press(set, a, h, rho, soc.force_on_face_n);
  if (!r.ok) {
    out.refusal = r.refusal;
    for (std::size_t k : under) out.status[k] = "beyond_data";
    out.beyond_data_columns = static_cast<int>(under.size());
    return out;
  }
  out.ok = true;
  out.rigid_depth_mm = r.depth_mm;
  out.max_depth_mm = r.depth_mm;
  for (std::size_t i = 0; i < under.size(); ++i) {
    const std::size_t k = under[i];
    out.depth_mm[k] = r.depth_mm;
    const bool ex = r.strain[i] > set.strain_measured_max() + 1e-12;
    out.status[k] = ex ? "extrapolated" : "ok";
    if (ex) ++out.extrapolated_columns;
  }
  return out;
}

std::vector<StackConflict> find_stack_conflicts(const VoxelGrid& grid,
                                                const std::vector<char>& lattice_mask,
                                                const std::vector<const Stack*>& stacks) {
  std::map<std::pair<std::size_t, std::size_t>, double> vol;
  const double vv = grid.voxel_volume();
  std::vector<std::pair<std::size_t, std::size_t>> same;
  for (std::size_t a = 0; a < stacks.size(); ++a)
    for (std::size_t b = a + 1; b < stacks.size(); ++b)
      if (axis_angle_deg(stacks[a]->frame.load, stacks[b]->frame.load) < kSameAxisDeg)
        same.push_back({a, b});
  if (same.empty()) return {};
  std::vector<char> in(stacks.size(), 0);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t idx = grid.index(i, j, k);
        if (idx >= lattice_mask.size() || !lattice_mask[idx]) continue;
        const Vec3 p = grid.voxel_center(i, j, k);
        for (std::size_t s = 0; s < stacks.size(); ++s) {
          int col = -1;
          double d = 0.0;
          in[s] = in_stack(*stacks[s], p, col, d);
        }
        for (const auto& pr : same)
          if (in[pr.first] && in[pr.second]) vol[pr] += vv;
      }
  std::vector<StackConflict> out;
  for (const auto& kv : vol) {
    StackConflict c;
    c.face_a = stacks[kv.first.first]->face_region_id;
    c.face_b = stacks[kv.first.second]->face_region_id;
    c.overlap_mm3 = kv.second;
    c.axis_angle_deg = axis_angle_deg(stacks[kv.first.first]->frame.load,
                                      stacks[kv.first.second]->frame.load);
    out.push_back(c);
  }
  return out;
}

DensityField assemble_density_field(const VoxelGrid& grid, const std::vector<char>& lattice_mask,
                                    const std::vector<LoadedStack>& stacks,
                                    const BuildParams& build) {
  std::vector<const Stack*> ss;
  for (const LoadedStack& l : stacks) {
    if (l.stack == nullptr || l.design == nullptr)
      throw FlexibleError("assemble_density_field: a loaded stack needs its stack and design");
    ss.push_back(l.stack);
  }
  const std::vector<StackConflict> cf = find_stack_conflicts(grid, lattice_mask, ss);
  if (!cf.empty())
    throw FlexibleError("faces " + std::to_string(cf[0].face_a) + " and " +
                        std::to_string(cf[0].face_b) +
                        " push the same material along the same axis (one profile per stack)");
  for (const LoadedStack& l : stacks)
    if (l.design->columns.size() != l.stack->columns.size())
      throw FlexibleError("assemble_density_field: a design does not match its stack");
  DensityField f;
  f.nx = grid.nx;
  f.ny = grid.ny;
  f.nz = grid.nz;
  f.spacing = grid.spacing;
  f.origin = grid.origin;
  f.density.assign(grid.voxel_count(), -1.0);
  f.owner.assign(grid.voxel_count(), -1);
  const double vv = grid.voxel_volume();
  std::map<std::pair<int, int>, Handover> hv;
  struct Hit {
    std::size_t s;
    int col;
    double depth;
  };
  std::vector<Hit> hits;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t idx = grid.index(i, j, k);
        if (idx >= lattice_mask.size() || !lattice_mask[idx]) continue;
        ++f.lattice_voxels;
        const Vec3 p = grid.voxel_center(i, j, k);
        hits.clear();
        for (std::size_t s = 0; s < stacks.size(); ++s) {
          int col = -1;
          double d = 0.0;
          if (!in_stack(*stacks[s].stack, p, col, d)) continue;
          const ColumnDesign& cd = stacks[s].design->columns[static_cast<std::size_t>(col)];
          if (!(cd.buildable_density > 0.0)) continue;
          hits.push_back({s, col, d});
        }
        if (hits.empty()) {
          f.density[idx] = 0.0;
          ++f.unassigned_voxels;
          continue;
        }
        ++f.assigned_voxels;
        std::sort(hits.begin(), hits.end(), [](const Hit& a, const Hit& b) {
          return a.depth != b.depth ? a.depth < b.depth : a.s < b.s;
        });
        const Hit& A = hits[0];
        const ColumnDesign& ca = stacks[A.s].design->columns[static_cast<std::size_t>(A.col)];
        const int fa = stacks[A.s].stack->face_region_id;
        if (hits.size() == 1) {
          f.density[idx] = ca.buildable_density;
          f.owner[idx] = fa;
          continue;
        }
        const Hit& B = hits[1];
        const ColumnDesign& cb = stacks[B.s].design->columns[static_cast<std::size_t>(B.col)];
        const int fb = stacks[B.s].stack->face_region_id;
        // R11: the nearest loaded face, blended over one cell of the larger size.
        const double L = std::max(
            cell_size_mm(build.topology, ca.buildable_density, build.beads_per_wall, build.bead_width_mm),
            cell_size_mm(build.topology, cb.buildable_density, build.beads_per_wall, build.bead_width_mm));
        const double w = std::min(1.0, std::max(0.0, 0.5 + (B.depth - A.depth) / (2.0 * L)));
        f.density[idx] = w * ca.buildable_density + (1.0 - w) * cb.buildable_density;
        f.owner[idx] = w >= 0.5 ? fa : fb;
        for (std::size_t x = 0; x < hits.size(); ++x)
          for (std::size_t y = x + 1; y < hits.size(); ++y) {
            int a = stacks[hits[x].s].stack->face_region_id;
            int b = stacks[hits[y].s].stack->face_region_id;
            if (a > b) std::swap(a, b);
            Handover& h = hv[{a, b}];
            h.face_a = a;
            h.face_b = b;
            h.overlap_mm3 += vv;
            if (x == 0 && y == 1 && w > 0.0 && w < 1.0) h.blended_mm3 += vv;
          }
      }
  for (const auto& kv : hv) f.handovers.push_back(kv.second);
  return f;
}

}  // namespace flexible
}  // namespace topopt
