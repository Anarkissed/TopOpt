// stress_measure.cpp -- see stress_measure.hpp.
#include "topopt/stress_measure.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

#include <Eigen/Dense>

namespace topopt {

namespace {

struct Tap {
  int di, dj, dk;
  double share;  // share of that neighbour voxel's volume inside the ball
};

// The ball is centred on a voxel centre, so the share of each neighbour voxel
// inside it depends only on the offset: one stencil serves the whole grid.
std::vector<Tap> ball_stencil(double radius_in_voxels) {
  constexpr int kSub = 6;
  const int reach = static_cast<int>(std::ceil(radius_in_voxels + 0.5));
  const double r2 = radius_in_voxels * radius_in_voxels;
  std::vector<Tap> taps;
  for (int dk = -reach; dk <= reach; ++dk)
    for (int dj = -reach; dj <= reach; ++dj)
      for (int di = -reach; di <= reach; ++di) {
        int in = 0;
        for (int c = 0; c < kSub; ++c)
          for (int b = 0; b < kSub; ++b)
            for (int a = 0; a < kSub; ++a) {
              const double x = di - 0.5 + (a + 0.5) / kSub;
              const double y = dj - 0.5 + (b + 0.5) / kSub;
              const double z = dk - 0.5 + (c + 0.5) / kSub;
              if (x * x + y * y + z * z <= r2) ++in;
            }
        if (in > 0)
          taps.push_back({di, dj, dk, static_cast<double>(in) / (kSub * kSub * kSub)});
      }
  return taps;
}

}  // namespace

std::vector<double> stress_over_size(const VoxelGrid& grid,
                                     const std::vector<double>& field,
                                     const std::vector<double>& density, double iso,
                                     double diameter_mm) {
  const std::size_t n = grid.voxel_count();
  if (field.size() != n || density.size() != n)
    throw std::invalid_argument("stress_over_size: field / density size != voxel_count");
  std::vector<double> out(n, 0.0);
  const double radius = 0.5 * diameter_mm / grid.spacing;
  // A ball that does not reach past its own voxel reads that voxel alone.
  const bool self_only = !(diameter_mm > 0.0) || radius <= 0.5;
  const std::vector<Tap> taps = self_only ? std::vector<Tap>{} : ball_stencil(radius);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t v = grid.index(i, j, k);
        if (!(density[v] >= iso)) continue;
        if (self_only) {
          out[v] = field[v];
          continue;
        }
        double sum = 0.0, weight = 0.0;
        for (const Tap& t : taps) {
          const int a = i + t.di, b = j + t.dj, c = k + t.dk;
          if (a < 0 || b < 0 || c < 0 || a >= grid.nx || b >= grid.ny || c >= grid.nz)
            continue;
          const std::size_t u = grid.index(a, b, c);
          if (!(density[u] >= iso)) continue;
          const double w = t.share * density[u];
          sum += w * field[u];
          weight += w;
        }
        out[v] = weight > 0.0 ? sum / weight : field[v];
      }
  return out;
}

namespace {
constexpr double kFullVoxel = 0.999;  // a voxel the surface does not cut
}  // namespace

std::vector<double> stress_over_size_on_surface(const VoxelGrid& grid,
                                                const std::vector<double>& field,
                                                const std::vector<double>& density,
                                                double material_floor, double diameter_mm) {
  const std::size_t n = grid.voxel_count();
  if (field.size() != n || density.size() != n)
    throw std::invalid_argument("stress_over_size_on_surface: field / density size != voxel_count");
  std::vector<double> out(n, 0.0);
  const double radius = 0.5 * diameter_mm / grid.spacing;  // in voxels
  if (!(diameter_mm > 0.0) || radius <= 0.5) return out;
  // The share of each voxel inside a ball centred on a NODE: voxel (di, dj, dk)
  // spans [di, di + 1) from the node, so one stencil serves every node.
  constexpr int kSub = 6;
  const int reach = static_cast<int>(std::ceil(radius)) + 1;
  const double r2 = radius * radius;
  std::vector<Tap> taps;
  for (int dk = -reach; dk < reach; ++dk)
    for (int dj = -reach; dj < reach; ++dj)
      for (int di = -reach; di < reach; ++di) {
        int in = 0;
        for (int c = 0; c < kSub; ++c)
          for (int b = 0; b < kSub; ++b)
            for (int a = 0; a < kSub; ++a) {
              const double x = di + (a + 0.5) / kSub, y = dj + (b + 0.5) / kSub,
                           z = dk + (c + 0.5) / kSub;
              if (x * x + y * y + z * z <= r2) ++in;
            }
        if (in > 0)
          taps.push_back({di, dj, dk, static_cast<double>(in) / (kSub * kSub * kSub)});
      }
  auto holds = [&](int i, int j, int k) {
    return i >= 0 && j >= 0 && k >= 0 && i < grid.nx && j < grid.ny && k < grid.nz &&
           density[grid.index(i, j, k)] >= material_floor;
  };
  // Node (i, j, k), 0 <= i <= nx and so on, touches the eight voxels (i - 1 or i, ...).
  for (int k = 0; k <= grid.nz; ++k)
    for (int j = 0; j <= grid.ny; ++j)
      for (int i = 0; i <= grid.nx; ++i) {
        int with = 0, cut = 0;
        for (int c = -1; c <= 0; ++c)
          for (int b = -1; b <= 0; ++b)
            for (int a = -1; a <= 0; ++a)
              if (holds(i + a, j + b, k + c)) {
                ++with;
                if (density[grid.index(i + a, j + b, k + c)] < kFullVoxel) ++cut;
              }
        if (with == 0 || with == 8) continue;  // inside the air, or inside the material
        // Only where the surface lies ON voxel boundaries (every voxel at the node is
        // full). Where the surface cuts voxels, a voxel-centred ball already sits on
        // the edge (on the cut voxels), and a node there would average mostly
        // slivers, whose stress the solve reads high: measured 2026-11-27, the plate
        // and the ring read 10 to 68 % high with such nodes counted.
        if (cut > 0) continue;
        double sum = 0.0, weight = 0.0;
        for (const Tap& t : taps) {
          const int a = i + t.di, b = j + t.dj, c = k + t.dk;
          if (!holds(a, b, c)) continue;
          const std::size_t u = grid.index(a, b, c);
          const double w = t.share * density[u];
          sum += w * field[u];
          weight += w;
        }
        if (!(weight > 0.0)) continue;
        const double reading = sum / weight;
        for (int c = -1; c <= 0; ++c)
          for (int b = -1; b <= 0; ++b)
            for (int a = -1; a <= 0; ++a)
              if (holds(i + a, j + b, k + c)) {
                double& o = out[grid.index(i + a, j + b, k + c)];
                if (reading > o) o = reading;
              }
      }
  return out;
}

namespace {

// THE SURFACE POINTS shared by stress_carried_to_surface and stress_recovered_at_surface.
// Calls on_full(v) for every FULL voxel; on_point(i, j, k, v, n, t_surf) for every surface
// point (n the unit outward normal, the true surface t_surf voxels out from the voxel's
// centre along n); on_no_normal(v) for a cut voxel whose fill gives no normal.
template <class OnFull, class OnPoint, class OnNoNormal>
void for_each_surface_point(const VoxelGrid& grid, const std::vector<double>& density,
                            OnFull&& on_full, OnPoint&& on_point, OnNoNormal&& on_no_normal) {
  auto inside = [&](int i, int j, int k) {
    return i >= 0 && j >= 0 && k >= 0 && i < grid.nx && j < grid.ny && k < grid.nz;
  };
  // The fill the normal is taken from: 0 outside the grid and on Empty voxels.
  auto fill = [&](int i, int j, int k) {
    if (!inside(i, j, k)) return 0.0;
    const std::size_t v = grid.index(i, j, k);
    if (grid.tags[v] == VoxelTag::Empty) return 0.0;
    return density[v];
  };
  auto air = [&](int i, int j, int k) {
    if (!inside(i, j, k)) return true;
    const std::size_t v = grid.index(i, j, k);
    return grid.tags[v] == VoxelTag::Empty || !(density[v] >= kStressMaterialFloor);
  };
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (air(i, j, k)) continue;
        const std::size_t v = grid.index(i, j, k);
        const bool is_full = density[v] >= kFullVoxel;
        if (is_full) {
          on_full(v);
          if (!air(i - 1, j, k) && !air(i + 1, j, k) && !air(i, j - 1, k) &&
              !air(i, j + 1, k) && !air(i, j, k - 1) && !air(i, j, k + 1))
            continue;  // inside the material: not a surface voxel
        }
        // One surface voxel can lie on MORE THAN ONE face of the part (the edge where a
        // hole's wall meets a flat top face). Each face is read on its own normal:
        //  - a FLAT face lying on a voxel boundary along an axis: the neighbour on one
        //    side is air and the fill does not change towards the other side (a full
        //    voxel, or a cut voxel whose neighbour behind is cut the same);
        //  - the CUT face through the voxel: -grad(fill) with the flat axes left out
        //    (a diagonal normal across an edge would put the surface in the wrong place).
        bool flat[3] = {false, false, false};
        int flat_sign[3] = {0, 0, 0};  // the side the air is on
        for (int ax = 0; ax < 3; ++ax) {
          int lo[3] = {i, j, k}, hi[3] = {i, j, k};
          --lo[ax];
          ++hi[ax];
          const bool air_lo = air(lo[0], lo[1], lo[2]), air_hi = air(hi[0], hi[1], hi[2]);
          if (air_lo == air_hi) {
            // air on both sides: a sheet one voxel thick along this axis, flat both ways
            if (air_lo) flat[ax] = true;
            continue;
          }
          const double behind = air_lo ? fill(hi[0], hi[1], hi[2]) : fill(lo[0], lo[1], lo[2]);
          if (is_full || std::fabs(behind - density[v]) < 0.25) {
            flat[ax] = true;
            flat_sign[ax] = air_hi ? 1 : -1;
          }
        }
        // The flat faces of a FULL voxel (a cut voxel's flat faces have no full voxel
        // straight behind them; its cut face carries it).
        if (is_full) {
          for (int ax = 0; ax < 3; ++ax)
            if (flat[ax] && flat_sign[ax] != 0) {
              double nv[3] = {0.0, 0.0, 0.0};
              nv[ax] = flat_sign[ax];
              on_point(i, j, k, v, static_cast<const double*>(nv), 0.5);
            }
          continue;
        }
        // The cut face: n = -grad(fill), Sobel-weighted over the 3 x 3 x 3 neighbourhood,
        // the flat axes left out.
        double g[3] = {0.0, 0.0, 0.0};
        for (int p = -1; p <= 1; ++p)
          for (int q = -1; q <= 1; ++q) {
            const double wgt = (p == 0 ? 2.0 : 1.0) * (q == 0 ? 2.0 : 1.0);
            g[0] += wgt * (fill(i + 1, j + p, k + q) - fill(i - 1, j + p, k + q));
            g[1] += wgt * (fill(i + p, j + 1, k + q) - fill(i + p, j - 1, k + q));
            g[2] += wgt * (fill(i + p, j + q, k + 1) - fill(i + p, j + q, k - 1));
          }
        for (int ax = 0; ax < 3; ++ax)
          if (flat[ax]) g[ax] = 0.0;
        const double norm = std::sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
        if (norm < 1e-9) {
          on_no_normal(v);
          continue;
        }
        const double nv[3] = {-g[0] / norm, -g[1] / norm, -g[2] / norm};
        const double l1 = std::fabs(nv[0]) + std::fabs(nv[1]) + std::fabs(nv[2]);
        // The true surface along n from the centre, in voxels (material on the - side).
        on_point(i, j, k, v, nv, (density[v] - 0.5) * l1);
      }
}

// Von Mises of a Voigt [xx, yy, zz, xy, yz, zx] tensor with true shear.
double von_mises6(const double* s) {
  const double a = s[0] - s[1], b = s[1] - s[2], c = s[2] - s[0];
  return std::sqrt(0.5 * (a * a + b * b + c * c) + 3.0 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5]));
}

}  // namespace

SurfaceCarry stress_carried_to_surface(const VoxelGrid& grid, const std::vector<double>& field,
                                       const std::vector<double>& density) {
  const std::size_t n = grid.voxel_count();
  if (field.size() != n || density.size() != n)
    throw std::invalid_argument("stress_carried_to_surface: field / density size != voxel_count");
  auto full = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= grid.nx || j >= grid.ny || k >= grid.nz) return false;
    const std::size_t v = grid.index(i, j, k);
    return grid.tags[v] != VoxelTag::Empty && density[v] >= kStressMaterialFloor &&
           density[v] >= kFullVoxel;
  };
  SurfaceCarry out;
  // carry along a unit normal nv with the surface t_surf voxels out from the centre
  auto carry = [&](int i, int j, int k, std::size_t v, const double* nv, double t_surf) {
    const double c[3] = {i + 0.5, j + 0.5, k + 0.5};
    bool have_a = false, have_b = false;
    std::size_t va = 0, vb = 0;
    double s_a = 0.0, s_b = 0.0;
    for (int step = 0; step <= 25 && !have_b; ++step) {
      const double s = -0.2 * step;
      const int a = static_cast<int>(std::floor(c[0] + s * nv[0]));
      const int b = static_cast<int>(std::floor(c[1] + s * nv[1]));
      const int d = static_cast<int>(std::floor(c[2] + s * nv[2]));
      if (!full(a, b, d)) continue;
      const std::size_t u = grid.index(a, b, d);
      const double su = (a + 0.5 - c[0]) * nv[0] + (b + 0.5 - c[1]) * nv[1] +
                        (d + 0.5 - c[2]) * nv[2];
      if (!have_a) {
        have_a = true;
        va = u;
        s_a = su;
      } else if (u != va && su < s_a - 0.5) {
        // b at least half a voxel further in than a, measured along the normal: two
        // voxels side by side across the ray would divide by almost nothing.
        have_b = true;
        vb = u;
        s_b = su;
      }
    }
    if (have_b) {
      double carried = field[va] + (field[va] - field[vb]) * (t_surf - s_a) / (s_a - s_b);
      if (carried < 0.0) carried = 0.0;
      ++out.surface_points;
      out.peak = std::max(out.peak, carried);
    } else {
      const double fallback = have_a ? field[va] : field[v];
      ++out.unresolved;
      out.peak_unresolved = std::max(out.peak_unresolved, fallback);
      out.peak = std::max(out.peak, fallback);
    }
  };
  for_each_surface_point(
      grid, density, [&](std::size_t v) { out.peak = std::max(out.peak, field[v]); }, carry,
      [&](std::size_t v) {
        ++out.unresolved;
        out.peak_unresolved = std::max(out.peak_unresolved, field[v]);
        out.peak = std::max(out.peak, field[v]);
      });
  return out;
}

SurfaceRecovery stress_recovered_at_surface(const VoxelGrid& grid,
                                            const std::vector<double>& stress_tensor,
                                            const std::vector<double>& density,
                                            const std::vector<char>* loaded,
                                            double patch_radius_voxels, int order) {
  const std::size_t n = grid.voxel_count();
  if (stress_tensor.size() != 6 * n || density.size() != n ||
      (loaded != nullptr && loaded->size() != n))
    throw std::invalid_argument(
        "stress_recovered_at_surface: stress_tensor / density / loaded size != voxel_count");
  if (order != 1 && order != 2)
    throw std::invalid_argument("stress_recovered_at_surface: order must be 1 or 2");
  auto full = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= grid.nx || j >= grid.ny || k >= grid.nz) return false;
    const std::size_t v = grid.index(i, j, k);
    return grid.tags[v] != VoxelTag::Empty && density[v] >= kStressMaterialFloor &&
           density[v] >= kFullVoxel;
  };
  auto vm_of = [&](std::size_t v) { return von_mises6(&stress_tensor[6 * v]); };
  SurfaceRecovery out;
  const double r = patch_radius_voxels > 0.0 ? patch_radius_voxels : 0.0;
  const double r2 = r * r;
  const int reach = static_cast<int>(std::ceil(r)) + 1;
  struct PatchVoxel {
    std::size_t v;
    double d[3];
  };
  std::vector<PatchVoxel> patch;
  auto fall_back = [&](double value) {
    ++out.unresolved;
    out.peak_unresolved = std::max(out.peak_unresolved, value);
    out.peak = std::max(out.peak, value);
  };
  // ORDER 2: each component a full quadratic in d (terms 0: 1; 1-3: dx, dy, dz; 4-6:
  // dx^2, dy^2, dz^2; 7: dx dy; 8: dy dz; 9: dz dx). A direction in which the patch's
  // centres take fewer than 3 distinct values (a plate two voxels thick) cannot tell
  // its square from a constant and a slope: that pure-square term is left out.
  auto term_value = [](int t, const double* d) {
    switch (t) {
      case 0: return 1.0;
      case 1: case 2: case 3: return d[t - 1];
      case 4: case 5: case 6: return d[t - 4] * d[t - 4];
      case 7: return d[0] * d[1];
      case 8: return d[1] * d[2];
      default: return d[2] * d[0];
    }
  };
  // d(term t)/d(x_ax) as coefficients over [1, dx, dy, dz].
  auto term_derivative = [](int t, int ax, double* r) {
    r[0] = r[1] = r[2] = r[3] = 0.0;
    if (t >= 1 && t <= 3) {
      if (t - 1 == ax) r[0] = 1.0;
    } else if (t >= 4 && t <= 6) {
      if (t - 4 == ax) r[1 + ax] = 2.0;
    } else if (t == 7) {
      if (ax == 0) r[2] = 1.0;
      if (ax == 1) r[1] = 1.0;
    } else if (t == 8) {
      if (ax == 1) r[3] = 1.0;
      if (ax == 2) r[2] = 1.0;
    } else if (t == 9) {
      if (ax == 2) r[1] = 1.0;
      if (ax == 0) r[3] = 1.0;
    }
  };
  // Voigt index of sigma_ij.
  static const int kVoigt[3][3] = {{0, 3, 5}, {3, 1, 4}, {5, 4, 2}};
  auto recover_quadratic = [&](std::size_t v, std::size_t v_near, const double* nv) {
    int terms[10];
    int nt = 0;
    for (int t = 0; t < 4; ++t) terms[nt++] = t;
    for (int e = 0; e < 3; ++e) {
      std::vector<double> vals;
      vals.reserve(patch.size());
      for (const PatchVoxel& p : patch) vals.push_back(p.d[e]);
      std::sort(vals.begin(), vals.end());
      int distinct = vals.empty() ? 0 : 1;
      for (std::size_t q = 1; q < vals.size(); ++q)
        if (vals[q] - vals[q - 1] > 1e-6) ++distinct;
      if (distinct >= 3) terms[nt++] = 4 + e;
      else ++out.squares_dropped;
    }
    for (int t = 7; t < 10; ++t) terms[nt++] = t;
    Eigen::MatrixXd M = Eigen::MatrixXd::Zero(nt, nt);
    Eigen::MatrixXd R = Eigen::MatrixXd::Zero(nt, 6);
    Eigen::VectorXd phi(nt);
    for (const PatchVoxel& p : patch) {
      for (int q = 0; q < nt; ++q) phi(q) = term_value(terms[q], p.d);
      M.noalias() += phi * phi.transpose();
      for (int comp = 0; comp < 6; ++comp) R.col(comp) += phi * stress_tensor[6 * p.v + comp];
    }
    // Well conditioned: the smallest eigenvalue of the scatter of the non-constant
    // terms (per voxel) at least 0.01.
    const double count = static_cast<double>(patch.size());
    const Eigen::VectorXd mean = M.block(1, 0, nt - 1, 1) / count;
    const Eigen::MatrixXd scatter =
        M.block(1, 1, nt - 1, nt - 1) / count - mean * mean.transpose();
    const Eigen::SelfAdjointEigenSolver<Eigen::MatrixXd> es(scatter, Eigen::EigenvaluesOnly);
    if (!(es.eigenvalues()(0) >= 0.01)) {
      fall_back(vm_of(v_near));
      return;
    }
    const Eigen::LDLT<Eigen::MatrixXd> Mf(M);
    const int nu = 6 * nt;  // component c, term q at c * nt + q
    Eigen::VectorXd z0(nu);
    for (int comp = 0; comp < 6; ++comp) z0.segment(comp * nt, nt) = Mf.solve(R.col(comp));
    const bool free_surface = loaded == nullptr || (*loaded)[v] == 0;
    const int m = free_surface ? 15 : 12;
    Eigen::MatrixXd C = Eigen::MatrixXd::Zero(m, nu);
    // Equilibrium everywhere: sum_j d(sigma_ij)/d(x_j) = 0, its constant and its three
    // linear coefficients, for each direction i.
    double r4[4];
    for (int i = 0; i < 3; ++i)
      for (int j = 0; j < 3; ++j) {
        const int comp = kVoigt[i][j];
        for (int q = 0; q < nt; ++q) {
          term_derivative(terms[q], j, r4);
          for (int coef = 0; coef < 4; ++coef) C(4 * i + coef, comp * nt + q) += r4[coef];
        }
      }
    if (free_surface)  // no traction at the point: sigma_ij(x_s) n_j = 0 (term 0 is the constant)
      for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) C(12 + i, kVoigt[i][j] * nt) += nv[j];
    Eigen::MatrixXd W(nu, m);
    for (int row = 0; row < m; ++row)
      for (int comp = 0; comp < 6; ++comp)
        W.block(comp * nt, row, nt, 1) = Mf.solve(C.block(row, comp * nt, 1, nt).transpose());
    const Eigen::MatrixXd S = C * W;
    const Eigen::VectorXd lambda = S.completeOrthogonalDecomposition().solve(C * z0);
    const Eigen::VectorXd z = z0 - W * lambda;
    double sig[6];
    for (int comp = 0; comp < 6; ++comp) sig[comp] = z(comp * nt);
    const double reading = von_mises6(sig);
    if (!std::isfinite(reading)) {
      fall_back(vm_of(v_near));
      return;
    }
    ++out.surface_points;
    out.peak = std::max(out.peak, reading);
  };
  auto recover = [&](int i, int j, int k, std::size_t v, const double* nv, double t_surf) {
    const double xs[3] = {i + 0.5 + t_surf * nv[0], j + 0.5 + t_surf * nv[1],
                          k + 0.5 + t_surf * nv[2]};
    patch.clear();
    double nearest = 1e300;
    std::size_t v_near = v;
    const int ci = static_cast<int>(std::floor(xs[0])), cj = static_cast<int>(std::floor(xs[1])),
              ck = static_cast<int>(std::floor(xs[2]));
    for (int c = ck - reach; c <= ck + reach; ++c)
      for (int b = cj - reach; b <= cj + reach; ++b)
        for (int a = ci - reach; a <= ci + reach; ++a) {
          if (!full(a, b, c)) continue;
          const double d[3] = {a + 0.5 - xs[0], b + 0.5 - xs[1], c + 0.5 - xs[2]};
          const double dd = d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
          if (dd > r2) continue;
          if (d[0] * nv[0] + d[1] * nv[1] + d[2] * nv[2] > 0.0) continue;  // the air side
          const std::size_t u = grid.index(a, b, c);
          patch.push_back({u, {d[0], d[1], d[2]}});
          if (dd < nearest) {
            nearest = dd;
            v_near = u;
          }
        }
    if (patch.size() < (order == 2 ? 20u : 8u)) {
      fall_back(vm_of(v_near));
      return;
    }
    if (order == 2) {
      recover_quadratic(v, v_near, nv);
      return;
    }
    // The shared normal matrix M = sum phi phi^T, phi = [1, d], and the right-hand sides.
    Eigen::Matrix4d M = Eigen::Matrix4d::Zero();
    Eigen::Matrix<double, 4, 6> R = Eigen::Matrix<double, 4, 6>::Zero();
    Eigen::Vector3d mean = Eigen::Vector3d::Zero();
    for (const PatchVoxel& p : patch) {
      const Eigen::Vector4d phi(1.0, p.d[0], p.d[1], p.d[2]);
      M.noalias() += phi * phi.transpose();
      for (int comp = 0; comp < 6; ++comp) R.col(comp) += phi * stress_tensor[6 * p.v + comp];
      mean += Eigen::Vector3d(p.d[0], p.d[1], p.d[2]);
    }
    // The centres must spread in all three directions: the smallest eigenvalue of
    // their scatter (per voxel, in voxels^2) at least 0.01.
    const double count = static_cast<double>(patch.size());
    mean /= count;
    const Eigen::Matrix3d scatter =
        M.block<3, 3>(1, 1) / count - mean * mean.transpose();
    const Eigen::SelfAdjointEigenSolver<Eigen::Matrix3d> es(scatter, Eigen::EigenvaluesOnly);
    if (!(es.eigenvalues()(0) >= 0.01)) {
      fall_back(vm_of(v_near));
      return;
    }
    const Eigen::LDLT<Eigen::Matrix4d> Mf(M);
    // z: 24 unknowns, component c at 4c + [a, bx, by, bz].
    Eigen::Matrix<double, 24, 1> z0;
    for (int comp = 0; comp < 6; ++comp) z0.segment<4>(4 * comp) = Mf.solve(R.col(comp));
    const bool free_surface = loaded == nullptr || (*loaded)[v] == 0;
    const int m = free_surface ? 6 : 3;
    Eigen::Matrix<double, Eigen::Dynamic, 24> C = Eigen::Matrix<double, Eigen::Dynamic, 24>::Zero(m, 24);
    // Voigt components 0..5 = xx, yy, zz, xy, yz, zx; a_c at 4c, b_c,x at 4c + 1 + x.
    // Equilibrium, div sigma = 0:
    C(0, 4 * 0 + 1) = 1.0; C(0, 4 * 3 + 2) = 1.0; C(0, 4 * 5 + 3) = 1.0;  // x
    C(1, 4 * 3 + 1) = 1.0; C(1, 4 * 1 + 2) = 1.0; C(1, 4 * 4 + 3) = 1.0;  // y
    C(2, 4 * 5 + 1) = 1.0; C(2, 4 * 4 + 2) = 1.0; C(2, 4 * 2 + 3) = 1.0;  // z
    if (free_surface) {
      // No traction at the point, sigma(x_s) n = 0:
      C(3, 4 * 0) = nv[0]; C(3, 4 * 3) = nv[1]; C(3, 4 * 5) = nv[2];  // x
      C(4, 4 * 3) = nv[0]; C(4, 4 * 1) = nv[1]; C(4, 4 * 4) = nv[2];  // y
      C(5, 4 * 5) = nv[0]; C(5, 4 * 4) = nv[1]; C(5, 4 * 2) = nv[2];  // z
    }
    // z = z0 - G^-1 C^T (C G^-1 C^T)^-1 C z0, G = blockdiag(M x 6).
    Eigen::Matrix<double, 24, Eigen::Dynamic> W(24, m);
    for (int row = 0; row < m; ++row)
      for (int comp = 0; comp < 6; ++comp)
        W.block<4, 1>(4 * comp, row) = Mf.solve(C.block<1, 4>(row, 4 * comp).transpose());
    const Eigen::MatrixXd S = C * W;
    const Eigen::VectorXd lambda = S.ldlt().solve(C * z0);
    const Eigen::Matrix<double, 24, 1> z = z0 - W * lambda;
    double sig[6];
    for (int comp = 0; comp < 6; ++comp) sig[comp] = z(4 * comp);
    const double reading = von_mises6(sig);
    if (!std::isfinite(reading)) {
      fall_back(vm_of(v_near));
      return;
    }
    ++out.surface_points;
    out.peak = std::max(out.peak, reading);
  };
  for_each_surface_point(
      grid, density, [&](std::size_t v) { out.peak = std::max(out.peak, vm_of(v)); }, recover,
      [&](std::size_t v) { fall_back(vm_of(v)); });
  return out;
}

double peak_stress_over_size(const VoxelGrid& grid, const std::vector<double>& field,
                             const std::vector<double>& density, double iso,
                             double diameter_mm) {
  double peak = 0.0;
  for (double s : stress_over_size(grid, field, density, iso, diameter_mm))
    peak = std::max(peak, s);
  return peak;
}

std::vector<double> interlayer_tension_field(
    const VoxelGrid& grid, const std::vector<std::array<double, 6>>& stress,
    const Vec3& build_dir) {
  const double len = std::sqrt(build_dir.x * build_dir.x + build_dir.y * build_dir.y +
                               build_dir.z * build_dir.z);
  if (len < 1e-12)
    throw std::invalid_argument("interlayer_tension_field: build_dir is zero length");
  if (stress.size() != grid.voxel_count())
    throw std::invalid_argument("interlayer_tension_field: stress size != voxel_count");
  const Vec3 n{build_dir.x / len, build_dir.y / len, build_dir.z / len};
  std::vector<double> out(grid.voxel_count(), 0.0);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const std::size_t idx = grid.index(i, j, k);
        const std::array<double, 6>& s = stress[idx];
        const double t = n.x * n.x * s[0] + n.y * n.y * s[1] + n.z * n.z * s[2] +
                         2.0 * n.x * n.y * s[3] + 2.0 * n.y * n.z * s[4] +
                         2.0 * n.z * n.x * s[5];
        if (t > 0.0) out[idx] = t;
      }
  return out;
}

}  // namespace topopt
