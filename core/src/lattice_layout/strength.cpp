// Lattice rebuild, Install 3: the lattice the strength check sees (rule V4). See lattice_layout_file.hpp,
// LatticeCredit. The check itself is the old engine's (run_job.cpp, lattice_file_strength_check).
#include <algorithm>
#include <cmath>
#include <thread>

#include "topopt/lattice.hpp"   // lattice_density_from_strut, lattice_rho_min / max
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice_layout_mesh.hpp"

namespace topopt::lattice_layout {
namespace {

// `p` within the cell's cube, its faces included to within `tol` mm (a strut on a cube face is the cell's).
bool near_cube(const Layout& layout, const Cell& c, const Vec3& p, double tol) {
  const Frame& f = layout.frames[static_cast<std::size_t>(c.frame)];
  const Vec3 rel{p.x - f.origin.x, p.y - f.origin.y, p.z - f.origin.z};
  for (int a = 0; a < 3; ++a) {
    const double q = rel.x * f.ax[a].x + rel.y * f.ax[a].y + rel.z * f.ax[a].z;
    if (q < c.lo[a] - tol || q > c.lo[a] + c.size + tol) return false;
  }
  return true;
}

const std::vector<std::uint32_t>* near_cells(const CellIndex& ix, const Vec3& p) {
  const auto it = ix.grid.find({static_cast<long long>(std::floor(p.x / ix.pitch)),
                                static_cast<long long>(std::floor(p.y / ix.pitch)),
                                static_cast<long long>(std::floor(p.z / ix.pitch))});
  return it == ix.grid.end() ? nullptr : &it->second;
}

}  // namespace

LatticeCredit lattice_credit(const Layout& layout, const Domain& domain, const Bars& bars,
                             const std::vector<Vec3>& left_out_at, const CreditGrid& grid,
                             const std::vector<char>* solid, int threads) {
  LatticeCredit out;
  const std::size_t nc = layout.cells.size();
  out.cell_credit.assign(nc, 1);
  out.cell_rho.assign(nc, 0.0);
  std::vector<char> why(nc, 0);   // 1 cut, 2 lost a bar, 3 out of band
  const std::shared_ptr<const CellIndex> own_index = layout.index ? nullptr : index_cells(layout);
  const CellIndex& ix = layout.index ? *layout.index : *own_index;

  // The bars the file left out, and the cells they were struts of: the cell of the bar's size and region whose cube
  // holds its middle (a strut on a face shared by two such cells costs both their credit).
  for (const Bar& b : bars.bars) {
    bool out_bar = false;
    for (const Vec3& s : left_out_at)
      if (bar_left_out_at(b, s)) { out_bar = true; break; }
    if (!out_bar) continue;
    const Vec3 m{0.5 * (b.a.x + b.b.x), 0.5 * (b.a.y + b.b.y), 0.5 * (b.a.z + b.b.z)};
    // The middle may sit on the index's own slot line: look in the slots a hair either side too.
    for (int dx = -1; dx <= 1; ++dx)
      for (int dy = -1; dy <= 1; ++dy)
        for (int dz = -1; dz <= 1; ++dz) {
          const Vec3 q{m.x + dx * 1e-6, m.y + dy * 1e-6, m.z + dz * 1e-6};
          const std::vector<std::uint32_t>* list = near_cells(ix, q);
          if (!list) continue;
          for (std::uint32_t ci : *list) {
            const Cell& c = layout.cells[ci];
            if (c.region != b.region || std::fabs(c.size - b.cell) > 1e-6 || why[ci]) continue;
            if (near_cube(layout, c, m, 1e-6)) why[ci] = 2;
          }
        }
  }
  // Each cell's density, and the old band.
  const double lo = lattice_rho_min(layout.topology), hi = lattice_rho_max(layout.topology);
  for (std::size_t ci = 0; ci < nc; ++ci) {
    const Cell& c = layout.cells[ci];
    double rho = 0.0;
    bool law = false;
    if (c.strut > 0.0 && c.size > 0.0) {
      try {
        rho = lattice_density_from_strut(layout.topology, c.size, 0.5 * c.strut);
        law = std::isfinite(rho);
      } catch (const std::exception&) {
        law = false;
      }
    }
    out.cell_rho[ci] = law ? rho : 0.0;
    if (c.cut) why[ci] = 1;
    else if (!why[ci] && (!law || rho < lo || rho > hi)) why[ci] = 3;
    if (why[ci]) {
      out.cell_credit[ci] = 0;
      ++out.cells_no_credit;
      (why[ci] == 1 ? out.cut : why[ci] == 2 ? out.lost_bar : out.out_of_band) += 1;
    } else {
      ++out.cells_credited;
    }
  }

  // Each voxel: the first cell, in layout order, whose lattice holds its centre.
  const std::size_t n = static_cast<std::size_t>(grid.nx) * grid.ny * grid.nz;
  out.cell.assign(n, -1);
  out.credited.assign(n, 0);
  if (nc == 0 || n == 0) return out;
  const int nt = std::max(1, std::min(grid.nz, threads > 0 ? threads
                                                           : static_cast<int>(std::thread::hardware_concurrency())));
  auto slab = [&](int k0, int k1) {
    const Domain::Probe probe = domain.probe();
    for (int k = k0; k < k1; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          const std::size_t e = (static_cast<std::size_t>(k) * grid.ny + j) * grid.nx + i;
          if (solid && (e >= solid->size() || !(*solid)[e])) continue;
          const Vec3 p{grid.origin.x + (i + 0.5) * grid.spacing, grid.origin.y + (j + 0.5) * grid.spacing,
                       grid.origin.z + (k + 0.5) * grid.spacing};
          const std::vector<std::uint32_t>* list = near_cells(ix, p);
          if (!list) continue;
          for (std::uint32_t ci : *list)   // in cell order
            if (cell_holds(layout, probe, layout.cells[ci], p)) {
              out.cell[e] = static_cast<std::int32_t>(ci);
              out.credited[e] = out.cell_credit[ci];
              break;
            }
        }
  };
  if (nt == 1) {
    slab(0, grid.nz);
  } else {
    std::vector<std::thread> pool;
    for (int t = 0; t < nt; ++t)
      pool.emplace_back(slab, grid.nz * t / nt, grid.nz * (t + 1) / nt);
    for (std::thread& t : pool) t.join();
  }
  return out;
}

}  // namespace topopt::lattice_layout
