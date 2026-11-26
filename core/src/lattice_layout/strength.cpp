// Lattice rebuild, Install 3: the lattice the strength check sees (rule V4). See lattice_layout_file.hpp,
// LatticeCredit. The check itself is the old engine's (run_job.cpp, lattice_file_strength_check).
// SHEETS (notes28 sheets SPEC 1.4, 1.5, 1.6, 3.3; builder B): a sheet layout is credited by PLACE (its wall field),
// judged per cell for sheet_cells.bin, and its cells' margins come from the check's own stress by the type's law.
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <limits>
#include <map>
#include <stdexcept>
#include <thread>

#include "topopt/lattice.hpp"   // lattice_density_from_strut, lattice_rho_min / max
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice_layout_mesh.hpp"
#include "topopt/strut_strength.hpp"   // strut_law_measured, strut_law_at (the sheets' margins per voxel)

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

// The per-cell credit of a strut layout (Install 3, unchanged): a cut cell, a cell that lost a bar the file left out,
// or a density the old band refuses gets none.
void judge_strut_cells(const Layout& layout, const CellIndex& ix, const Bars& bars, const std::vector<Vec3>& left_out_at,
                       LatticeCredit& out) {
  const std::size_t nc = layout.cells.size();
  out.cell_credit.assign(nc, 1);
  out.cell_rho.assign(nc, 0.0);
  std::vector<char> why(nc, 0);   // 1 cut, 2 lost a bar, 3 out of band

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
}

int thread_count(int threads, std::size_t work) {
  const int all = threads > 0 ? threads : static_cast<int>(std::max(1u, std::thread::hardware_concurrency()));
  return static_cast<int>(std::max<std::size_t>(1, std::min<std::size_t>(static_cast<std::size_t>(all), work)));
}

// ── SHEETS ──────────────────────────────────────────────────────────────────────────────────────────────────────
// What crediting a sheet layout reads: its fields (sheet_fields: Outcome::sheets exactly), each cell's field, and
// the blend seams (every touching pair the membrane does not make a solid wall: the lay's Blend, not fallen back).
struct SheetSetup {
  bool on = false;
  std::vector<SheetField> sheets;
  std::vector<int> field_of_cell;                       // per layout cell, its field (-1: none)
  std::vector<SheetSeamBand> blends;
  std::vector<std::vector<std::size_t>> blends_of;      // per field, its blend seams
  double floor_cells = 0.0;
};

bool membrane_pair(const Layout& layout, int a, int b) {
  for (const auto& pr : layout.membrane)
    if ((pr[0] == a && pr[1] == b) || (pr[0] == b && pr[1] == a)) return true;
  return false;
}

SheetSetup sheet_setup(const Layout& layout, const Domain& domain) {
  SheetSetup s;
  if (!sheet_kind_of(layout.topology)) return s;
  s.on = true;
  s.sheets = sheet_fields(layout);
  s.floor_cells = sheet_structural_floor_cells(layout.topology);
  std::map<std::pair<int, int>, int> field;
  for (std::size_t i = 0; i < s.sheets.size(); ++i) field.emplace(std::make_pair(s.sheets[i].region, s.sheets[i].frame), static_cast<int>(i));
  s.field_of_cell.assign(layout.cells.size(), -1);
  for (std::size_t ci = 0; ci < layout.cells.size(); ++ci) {
    const auto it = field.find({layout.cells[ci].region, layout.cells[ci].frame});
    if (it != field.end()) s.field_of_cell[ci] = it->second;
  }
  // The touching pairs as the lay finds them (Session::lay: the line width), each a blend unless it is a solid wall.
  const double line = domain.spec().bead_mm > 0.0 ? domain.spec().bead_mm : layout.bead_mm;
  s.blends_of.assign(s.sheets.size(), {});
  for (const SheetSeamBand& b : sheet_seams(layout, s.sheets, SheetSeam::Blend, line)) {
    if (membrane_pair(layout, b.region_a, b.region_b)) continue;
    s.blends.push_back(b);
    s.blends_of[static_cast<std::size_t>(b.a)].push_back(s.blends.size() - 1);
    s.blends_of[static_cast<std::size_t>(b.b)].push_back(s.blends.size() - 1);
  }
  // E: where each blend's two regions meet, as the lay reads it (sheet_seam_mm reads +infinity without it).
  sheet_seams_across(domain, layout, s.sheets, s.blends);
  return s;
}

// Is p (lattice of field `fi`) inside one of its blend bands? (|sheet_seam_mm| under half the band: SPEC 1.5.)
bool in_blend(const SheetSetup& s, const Domain& domain, int fi, const Vec3& p) {
  if (fi < 0) return false;
  for (std::size_t k : s.blends_of[static_cast<std::size_t>(fi)]) {
    const SheetSeamBand& b = s.blends[k];
    const double m = sheet_seam_mm(domain, b, p);
    if (std::isfinite(m) && std::fabs(m) < 0.5 * b.band_mm) return true;
  }
  return false;
}

// The density a sheet's wall gives in a cell of `cell_mm` (NaN: no law there): lattice_density_from_strut exactly,
// remembered by (cell, wall). Inside the type's table the law is a lookup; past it (the open look itself sits a hair
// past the last row: lattice_width_bounds reads the wall at the band's top) it integrates the sheet's solid fraction
// over 2^20 points, so each wall is worked out once per thread (one wall over a region, or a cell's, repeats at every
// voxel). The same numbers with or without it.
struct RhoMemo {
  std::map<std::pair<double, double>, double> seen;
};
double sheet_rho(LatticeTopology topo, double cell_mm, double wall_mm, RhoMemo* memo = nullptr) {
  if (!(wall_mm > 0.0) || !(cell_mm > 0.0)) return std::numeric_limits<double>::quiet_NaN();
  if (memo) {
    const auto it = memo->seen.find({cell_mm, wall_mm});
    if (it != memo->seen.end()) return it->second;
  }
  double r = std::numeric_limits<double>::quiet_NaN();
  try {
    r = lattice_density_from_strut(topo, cell_mm, 0.5 * wall_mm);
    if (!std::isfinite(r)) r = std::numeric_limits<double>::quiet_NaN();
  } catch (const std::exception&) {
    r = std::numeric_limits<double>::quiet_NaN();
  }
  if (memo && memo->seen.size() < (1u << 16)) memo->seen.emplace(std::make_pair(cell_mm, wall_mm), r);
  return r;
}

// The cube's points a cell is read at: its centre and the centres of its eight octants (frame fractions 1/4, 3/4),
// then (for the membrane only) its six face centres and eight corners. Part coordinates.
std::vector<Vec3> cube_points(const Layout& layout, const Cell& c, bool boundary) {
  const Frame& f = layout.frames[static_cast<std::size_t>(c.frame)];
  std::vector<Vec3> out;
  const auto at = [&](double u, double v, double w) {
    out.push_back(f.at(c.lo[0] + u * c.size, c.lo[1] + v * c.size, c.lo[2] + w * c.size));
  };
  at(0.5, 0.5, 0.5);
  for (int k = 0; k < 8; ++k) at((k & 1) ? 0.75 : 0.25, (k & 2) ? 0.75 : 0.25, (k & 4) ? 0.75 : 0.25);
  if (boundary) {
    for (int a = 0; a < 3; ++a)
      for (int side = 0; side < 2; ++side) {
        double q[3] = {0.5, 0.5, 0.5};
        q[a] = side ? 1.0 : 0.0;
        at(q[0], q[1], q[2]);
      }
    for (int k = 0; k < 8; ++k) at((k & 1) ? 1.0 : 0.0, (k & 2) ? 1.0 : 0.0, (k & 4) ? 1.0 : 0.0);
  }
  return out;
}

// The per-cell judgement of a sheet layout (the voxel pass reads `may`: the cells whose voxels may be credited).
void judge_sheet_cells(const Layout& layout, const Domain& domain, const SheetSetup& s, int threads, LatticeCredit& out,
                       std::vector<char>& may) {
  const std::size_t nc = layout.cells.size();
  const LatticeTopology topo = layout.topology;
  const double lo = lattice_rho_min(topo), hi = lattice_rho_max(topo);
  out.cell_credit.assign(nc, 0);
  out.cell_rho.assign(nc, 0.0);
  out.cell_across.assign(nc, 0);
  out.cell_room_mm.assign(nc, std::numeric_limits<float>::quiet_NaN());
  out.cell_flags.assign(nc, 0u);
  out.floor_cells = s.floor_cells;
  may.assign(nc, 0);
  std::vector<char> why(nc, 0);   // 1 cut, 3 out of band, 4 under the floor
  std::atomic<std::size_t> next{0};
  auto work = [&] {
    const Domain::Probe probe = domain.probe();
    RhoMemo memo;
    for (;;) {
      const std::size_t ci = next.fetch_add(1);
      if (ci >= nc) break;
      const Cell& c = layout.cells[ci];
      std::uint32_t flags = c.cut ? SheetCellRecord::kCut : 0u;
      const double rho = sheet_rho(topo, c.size, c.strut, &memo);
      const bool law = std::isfinite(rho);
      // The cells across the member there (SPEC 3.3): the narrowest room through the cell's lattice, over its cell.
      double room = std::numeric_limits<double>::infinity();
      const std::vector<Vec3> pts = cube_points(layout, c, false);
      for (const Vec3& p : pts)
        if (cell_holds(layout, probe, c, p)) room = std::min(room, probe.room_through(p));
      const int across = std::isfinite(room) && c.size > 0.0
                             ? static_cast<int>(std::floor(room / c.size + 1e-9))
                             : 0;
      out.cell_across[ci] = across;
      if (std::isfinite(room)) out.cell_room_mm[ci] = static_cast<float>(room);
      // Read (some point of the cell's lattice measured): a member thinner than one cell is under the floor too (0 across).
      const bool under = s.floor_cells > 0.0 && std::isfinite(room) && across < s.floor_cells;
      const int fi = s.field_of_cell[ci];
      bool blend = false;
      for (const Vec3& p : pts)
        if (in_blend(s, domain, fi, p)) { blend = true; break; }
      bool by_membrane = false;
      if (!layout.membrane.empty())
        for (const Vec3& p : cube_points(layout, c, true))
          if (sheet_membrane_at(layout, probe, c.region, p)) { by_membrane = true; break; }
      if (under) flags |= SheetCellRecord::kUnderFloor;
      if (!law || rho < lo || rho > hi) flags |= SheetCellRecord::kOutOfBand;
      if (blend) flags |= SheetCellRecord::kBlendBand;
      if (by_membrane) flags |= SheetCellRecord::kMembrane;
      char w = 0;
      if (c.cut && !kSheetCutCellsCredited) w = 1;
      else if (under) w = 4;
      else if (flags & SheetCellRecord::kOutOfBand) w = 3;
      if (!w) flags |= SheetCellRecord::kCredited;
      why[ci] = w;
      may[ci] = (w == 0 || w == 3) && law ? 1 : 0;   // banded per voxel (SPEC 1.4): a voxel may be in band
      out.cell_rho[ci] = law ? rho : 0.0;
      out.cell_credit[ci] = w == 0 ? 1 : 0;
      out.cell_flags[ci] = flags;
    }
  };
  const int nt = thread_count(threads, nc);
  std::vector<std::thread> pool;
  for (int t = 1; t < nt; ++t) pool.emplace_back(work);
  work();
  for (std::thread& t : pool) t.join();
  for (std::size_t ci = 0; ci < nc; ++ci) {
    if (!why[ci]) {
      ++out.cells_credited;
      continue;
    }
    ++out.cells_no_credit;
    (why[ci] == 1 ? out.cut : why[ci] == 4 ? out.under_floor : out.out_of_band) += 1;
  }
}

// Von Mises and pressure of a Voigt [xx yy zz xy yz zx] tensor with true shear (strut_strength.cpp's own).
double voigt_vm(const double s[6]) {
  const double dxy = s[0] - s[1], dyz = s[1] - s[2], dzx = s[2] - s[0];
  const double v2 = 0.5 * (dxy * dxy + dyz * dyz + dzx * dzx) + 3.0 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5]);
  return std::sqrt(v2 > 0.0 ? v2 : 0.0);
}

std::string num(double x) {
  if (!std::isfinite(x)) return "null";
  char b[48];
  std::snprintf(b, sizeof b, "%.9g", x);
  return b;
}

}  // namespace

LatticeCredit lattice_credit_cells(const Layout& layout, const Domain& domain, int threads) {
  LatticeCredit out;
  const SheetSetup s = sheet_setup(layout, domain);
  if (!s.on) return out;
  std::vector<char> may;
  judge_sheet_cells(layout, domain, s, threads, out, may);
  return out;
}

LatticeCredit lattice_credit(const Layout& layout, const Domain& domain, const Bars& bars,
                             const std::vector<Vec3>& left_out_at, const CreditGrid& grid,
                             const std::vector<char>* solid, int threads) {
  LatticeCredit out;
  const std::size_t nc = layout.cells.size();
  const std::shared_ptr<const CellIndex> own_index = layout.index ? nullptr : index_cells(layout);
  const CellIndex& ix = layout.index ? *layout.index : *own_index;
  const SheetSetup sheet = sheet_setup(layout, domain);
  std::vector<char> may;   // SHEETS: per cell, may its voxels be credited (banded per voxel)

  if (sheet.on) judge_sheet_cells(layout, domain, sheet, threads, out, may);
  else judge_strut_cells(layout, ix, bars, left_out_at, out);

  // Each voxel: the first cell, in layout order, whose lattice holds its centre.
  const std::size_t n = static_cast<std::size_t>(grid.nx) * grid.ny * grid.nz;
  out.cell.assign(n, -1);
  out.credited.assign(n, 0);
  if (sheet.on) out.voxel_rho.assign(n, 0.0f);
  if (nc == 0 || n == 0) return out;
  const int nt = std::max(1, std::min(grid.nz, threads > 0 ? threads
                                                           : static_cast<int>(std::thread::hardware_concurrency())));
  // SHEETS: the voxel counts, per slab (summed in slab order: the same for any number of threads).
  std::vector<std::array<std::size_t, 3>> counts(static_cast<std::size_t>(nt), {0, 0, 0});   // credited, blend, membrane
  const LatticeTopology topo = layout.topology;
  const double band_lo = lattice_rho_min(topo), band_hi = lattice_rho_max(topo);
  auto slab = [&](int t, int k0, int k1) {
    const Domain::Probe probe = domain.probe();
    RhoMemo memo;
    std::array<std::size_t, 3>& cnt = counts[static_cast<std::size_t>(t)];
    for (int k = k0; k < k1; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          const std::size_t e = (static_cast<std::size_t>(k) * grid.ny + j) * grid.nx + i;
          if (solid && (e >= solid->size() || !(*solid)[e])) continue;
          const Vec3 p{grid.origin.x + (i + 0.5) * grid.spacing, grid.origin.y + (j + 0.5) * grid.spacing,
                       grid.origin.z + (k + 0.5) * grid.spacing};
          const std::vector<std::uint32_t>* list = near_cells(ix, p);
          std::int32_t held = -1;
          if (list)
            for (std::uint32_t ci : *list)   // in cell order
              if (cell_holds(layout, probe, layout.cells[ci], p)) { held = static_cast<std::int32_t>(ci); break; }
          if (held < 0) {
            // SHEETS: lattice the solid wall keeps from every cell (Layout::membrane): solid, and counted.
            if (sheet.on && !layout.membrane.empty() && sheet_membrane_at(layout, probe, -1, p)) ++cnt[2];
            continue;
          }
          out.cell[e] = held;
          const std::size_t ci = static_cast<std::size_t>(held);
          if (!sheet.on) {
            out.credited[e] = out.cell_credit[ci];
            continue;
          }
          // SHEETS: credit by place (SPEC 1.4, 1.5).
          if (!may[ci]) continue;
          const int fi = sheet.field_of_cell[ci];
          if (fi < 0) continue;
          if (in_blend(sheet, domain, fi, p)) { ++cnt[1]; continue; }
          const Cell& c = layout.cells[ci];
          const double rho = sheet_rho(topo, c.size, sheet_wall_at(sheet.sheets[static_cast<std::size_t>(fi)], p), &memo);
          if (!std::isfinite(rho) || rho < band_lo || rho > band_hi) continue;
          out.credited[e] = 1;
          out.voxel_rho[e] = static_cast<float>(rho);
          ++cnt[0];
        }
  };
  if (nt == 1) {
    slab(0, 0, grid.nz);
  } else {
    std::vector<std::thread> pool;
    for (int t = 0; t < nt; ++t)
      pool.emplace_back(slab, t, grid.nz * t / nt, grid.nz * (t + 1) / nt);
    for (std::thread& t : pool) t.join();
  }
  if (sheet.on)
    for (const auto& c : counts) {
      out.voxels_credited += c[0];
      out.blend_band += c[1];
      out.membrane += c[2];
    }
  return out;
}

std::vector<double> sheet_member_width_mm(const Layout& layout, const Domain& domain, const LatticeCredit& credit,
                                          const CreditGrid& grid, int threads) {
  std::vector<double> out;
  if (!sheet_kind_of(layout.topology) || credit.cell_room_mm.size() != layout.cells.size()) return out;
  const std::size_t n = credit.cell.size();
  out.assign(n, 0.0);
  if (n == 0 || grid.nx <= 0 || grid.ny <= 0) return out;
  const int nt = thread_count(threads, static_cast<std::size_t>(std::max(1, grid.nz)));
  auto slab = [&](int k0, int k1) {
    const Domain::Probe probe = domain.probe();
    for (int k = k0; k < k1; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          const std::size_t e = (static_cast<std::size_t>(k) * grid.ny + j) * grid.nx + i;
          if (e >= n || credit.cell[e] < 0) continue;
          const float room = credit.cell_room_mm[static_cast<std::size_t>(credit.cell[e])];
          if (std::isfinite(room)) {
            out[e] = room;
          } else {   // the cell's own points were none of them held: read the member at this voxel
            out[e] = probe.room_through({grid.origin.x + (i + 0.5) * grid.spacing, grid.origin.y + (j + 0.5) * grid.spacing,
                                         grid.origin.z + (k + 0.5) * grid.spacing});
          }
        }
  };
  if (nt == 1) {
    slab(0, grid.nz);
  } else {
    std::vector<std::thread> pool;
    for (int t = 0; t < nt; ++t) pool.emplace_back(slab, grid.nz * t / nt, grid.nz * (t + 1) / nt);
    for (std::thread& t : pool) t.join();
  }
  return out;
}

std::vector<float> lattice_voxel_margins(LatticeTopology topo, const LatticeCredit& credit,
                                         const std::vector<double>& stress_tensor_field, const Vec3& build_dir,
                                         double yield_mpa, double z_knockdown) {
  const std::size_t n = credit.cell.size();
  if (stress_tensor_field.size() != 6 * n || credit.credited.size() != n ||
      (!credit.voxel_rho.empty() && credit.voxel_rho.size() != n))
    throw std::invalid_argument("lattice_voxel_margins: the stress field is not 6 values per voxel of the credit");
  const float nan = std::numeric_limits<float>::quiet_NaN();
  std::vector<float> out(n, nan);
  if (!strut_law_measured(topo) || !(yield_mpa > 0.0) || !(z_knockdown > 0.0)) return out;
  const double bn = std::sqrt(build_dir.x * build_dir.x + build_dir.y * build_dir.y + build_dir.z * build_dir.z);
  if (!(bn > 0.0) || !std::isfinite(bn)) return out;
  const double nx = build_dir.x / bn, ny = build_dir.y / bn, nz = build_dir.z / bn;
  // The off-axis interlayer term, as evaluate_strut_strength resolves it (strut_strength.hpp).
  const double cross = (2.0 / std::sqrt(3.0)) * (std::fabs(nx * ny) + std::fabs(ny * nz) + std::fabs(nz * nx));
  for (std::size_t e = 0; e < n; ++e) {
    if (!credit.credited[e] || credit.cell[e] < 0) continue;
    const double rho = credit.voxel_rho.empty() ? credit.cell_rho[static_cast<std::size_t>(credit.cell[e])]
                                                : static_cast<double>(credit.voxel_rho[e]);
    double s[6];
    for (int c = 0; c < 6; ++c) s[c] = stress_tensor_field[6 * e + static_cast<std::size_t>(c)];
    const double vm = voigt_vm(s), p = std::fabs((s[0] + s[1] + s[2]) / 3.0);
    const StrutLawK K = strut_law_at(topo, rho);
    const double vm_bound = K.Kd * vm + K.Kv * p;
    const double il_bound = K.Kild * vm + K.Kilv * p + cross * vm_bound;
    const double inf = std::numeric_limits<double>::infinity();
    const double in_plane = vm_bound > 0.0 ? yield_mpa / vm_bound : inf;
    const double inter = il_bound > 0.0 ? z_knockdown * yield_mpa / il_bound : inf;
    out[e] = static_cast<float>(std::min(in_plane, inter));
  }
  return out;
}

SheetCellsFile sheet_cells_judged(const Layout& layout, const LatticeCredit& credit,
                                  const std::vector<float>& voxel_margin, const PrintFrame& frame) {
  SheetCellsFile f = sheet_cells_of(layout, frame);
  const std::size_t nc = f.cells.size();
  std::vector<float> worst(nc, std::numeric_limits<float>::quiet_NaN());
  if (!voxel_margin.empty() && voxel_margin.size() == credit.cell.size())
    for (std::size_t e = 0; e < voxel_margin.size(); ++e) {
      const std::int32_t c = credit.cell[e];
      const float m = voxel_margin[e];
      if (c < 0 || static_cast<std::size_t>(c) >= nc || std::isnan(m)) continue;
      float& w = worst[static_cast<std::size_t>(c)];
      if (std::isnan(w) || m < w) w = m;
    }
  for (std::size_t i = 0; i < nc; ++i) {
    SheetCellRecord& r = f.cells[i];
    if (i < credit.cell_across.size()) r.cells_across = static_cast<float>(credit.cell_across[i]);
    if (i < credit.cell_flags.size()) r.flags = credit.cell_flags[i];
    r.margin = worst[i];
  }
  return f;
}

SheetCheckFiles write_sheet_check_files(const std::string& out_dir, const Layout& layout, const LatticeCredit& credit,
                                        const std::vector<float>& voxel_margin, const PrintFrame& frame) {
  SheetCheckFiles w;
  if (!sheet_kind_of(layout.topology)) return w;
  const SheetCellsFile f = sheet_cells_judged(layout, credit, voxel_margin, frame);
  if (!write_sheet_cells_file(out_dir + "/" + kSheetCellsName, f)) {
    w.ok = false;
    w.why = std::string("cannot write ") + kSheetCellsName;
    return w;
  }
  w.file = kSheetCellsName;
  std::size_t by[6] = {0, 0, 0, 0, 0, 0};   // cut, out of band, under the floor, blend band, membrane, credited
  for (const std::uint32_t fl : credit.cell_flags) {
    if (fl & SheetCellRecord::kCut) ++by[0];
    if (fl & SheetCellRecord::kOutOfBand) ++by[1];
    if (fl & SheetCellRecord::kUnderFloor) ++by[2];
    if (fl & SheetCellRecord::kBlendBand) ++by[3];
    if (fl & SheetCellRecord::kMembrane) ++by[4];
    if (fl & SheetCellRecord::kCredited) ++by[5];
  }
  const bool voxels = !credit.cell.empty();
  const auto count = [](std::size_t x) { return std::to_string(x); };
  w.keys = std::string("    \"sheet_cells\": \"") + kSheetCellsName + "\",\n";
  w.keys += "    \"sheet_credit\": {\"cells\": " + count(f.cells.size()) + ", \"cells_credited\": " + count(by[5]) +
            ", \"cells_cut\": " + count(by[0]) + ", \"cells_out_of_band\": " + count(by[1]) +
            ", \"cells_under_floor\": " + count(by[2]) + ", \"cells_in_blend_band\": " + count(by[3]) +
            ", \"cells_by_membrane\": " + count(by[4]) + ", \"floor_cells\": " + num(credit.floor_cells) +
            ", \"cut_cells_credited\": " + (kSheetCutCellsCredited ? "true" : "false") +
            ", \"voxels_credited\": " + (voxels ? count(credit.voxels_credited) : "null") +
            ", \"voxels_blend_band\": " + (voxels ? count(credit.blend_band) : "null") +
            ", \"voxels_membrane\": " + (voxels ? count(credit.membrane) : "null") +
            ", \"margins\": " + (voxel_margin.empty() ? "false" : "true") + "},\n";
  return w;
}

std::string strength_block_with(const std::string& block, const std::string& keys) {
  if (keys.empty()) return block;
  const std::size_t at = block.find('{');
  if (at == std::string::npos) return block;
  std::string out = block;
  if (at + 1 < out.size() && out[at + 1] == '\n') out.insert(at + 2, keys);
  else out.insert(at + 1, "\n" + keys);
  return out;
}

}  // namespace topopt::lattice_layout
