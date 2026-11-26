// SHEETS on the lattice engine (notes28 sheets SPEC, revision 3): the field a laid sheet region carries, read by the
// file, the strength check and the iPad alike; the seams between two sheet regions; the solid wall's membrane; the
// bridge's flat form; sheet_cells.bin. See lattice_layout.hpp, SHEETS.
#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_file.hpp"

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstring>
#include <deque>
#include <fstream>
#include <limits>
#include <map>
#include <stdexcept>

#include "topopt/lattice.hpp"

namespace topopt::lattice_layout {

bool sheet_kind_of(LatticeTopology topo, TpmsKind* kind) {
  if (topo == LatticeTopology::Gyroid) {
    if (kind) *kind = TpmsKind::Gyroid;
    return true;
  }
  if (topo == LatticeTopology::SchwarzD) {
    if (kind) *kind = TpmsKind::SchwarzD;
    return true;
  }
  return false;
}

const char* lattice_family(LatticeTopology topo) { return sheet_kind_of(topo) ? "sheet" : "strut"; }

double sheet_auto_wall_mm(LatticeTopology topo, double cell_mm, double min_strut_mm) {
  if (!sheet_kind_of(topo))
    throw std::invalid_argument(std::string("sheet_auto_wall_mm: \"") + lattice_topology_name(topo) +
                                "\" is not a sheet type");
  return std::max(min_strut_mm, kSheetAutoShare * lattice_width_bounds(topo).open_look * cell_mm);
}

double sheet_structural_floor_cells(LatticeTopology topo) {
  // The bending study (tpms_probe bend, recorded in lattice.cpp): within 2.4 % of the averaged member only from 10
  // (gyroid) and 9 (Schwarz-D) cells across. Read from core's one place for it (the app's Structural count reads the
  // same), so builder D's re-measure (SPEC 3.2) lowers it there and it drops here by itself.
  return sheet_kind_of(topo) ? lattice_cells_per_member_min(topo) : 0.0;
}

double sheet_floor_cell_mm(LatticeTopology topo, double min_strut_mm) {
  if (!sheet_kind_of(topo)) return 0.0;
  return min_strut_mm / lattice_width_bounds(topo).open_look;
}

// ── the field ───────────────────────────────────────────────────────────────────────────────────────────────────
Vec3 sheet_local(const SheetField& s, const Vec3& p) {
  const Frame& f = s.axes;
  const Vec3 r{p.x - f.origin.x, p.y - f.origin.y, p.z - f.origin.z};
  return {r.x * f.ax[0].x + r.y * f.ax[0].y + r.z * f.ax[0].z, r.x * f.ax[1].x + r.y * f.ax[1].y + r.z * f.ax[1].z,
          r.x * f.ax[2].x + r.y * f.ax[2].y + r.z * f.ax[2].z};
}

double sheet_wall_at_local(const SheetField& s, const Vec3& q) {
  if (s.wall_mm.empty()) return 0.0;
  if (s.wall_mm.size() == 1 || !(s.cell_mm > 0.0)) return s.wall_mm.front();
  const double qq[3] = {q.x, q.y, q.z};
  int i0[3];
  double w[3];
  for (int k = 0; k < 3; ++k) {
    const int n = std::max(1, s.n[k]);
    double u = (qq[k] - s.lo[k]) / s.cell_mm;
    if (!(u > 0.0)) u = 0.0;   // also NaN
    if (u > n - 1) u = n - 1;
    int i = static_cast<int>(std::floor(u));
    if (i > n - 2) i = std::max(0, n - 2);
    i0[k] = i;
    w[k] = n > 1 ? u - i : 0.0;
  }
  const auto at = [&](int i, int j, int k) {
    i = std::min(i, s.n[0] - 1);
    j = std::min(j, s.n[1] - 1);
    k = std::min(k, s.n[2] - 1);
    return static_cast<double>(
        s.wall_mm[(static_cast<std::size_t>(k) * static_cast<std::size_t>(s.n[1]) + static_cast<std::size_t>(j)) *
                      static_cast<std::size_t>(s.n[0]) +
                  static_cast<std::size_t>(i)]);
  };
  double v = 0.0;
  for (int c = 0; c < 8; ++c) {
    const int dx = c & 1, dy = (c >> 1) & 1, dz = (c >> 2) & 1;
    const double wt = (dx ? w[0] : 1.0 - w[0]) * (dy ? w[1] : 1.0 - w[1]) * (dz ? w[2] : 1.0 - w[2]);
    if (wt != 0.0) v += wt * at(i0[0] + dx, i0[1] + dy, i0[2] + dz);
  }
  return v;
}

double sheet_wall_at(const SheetField& s, const Vec3& p) { return sheet_wall_at_local(s, sheet_local(s, p)); }

double sheet_param_at(const SheetField& s, const Vec3& p) {
  const double wall = sheet_wall_at(s, p);
  if (!(wall > 0.0) || !(s.cell_mm > 0.0)) return 0.0;
  return lattice_sheet_wall_param_mm(sheet_topology(s.kind), wall, s.cell_mm);
}

double sheet_print_wall_mm(double wall_mm, double floor_mm, double deviation_mm) {
  if (!(deviation_mm > 0.0) || !(floor_mm > 0.0)) return wall_mm;
  // The generator's bead guard is given B = floor / (1 - u): the mesh then sits at most half the wall's margin over B
  // inside it (max_in), and the field's own wall at most u thinner than its number, so the mesh's wall is at least
  // (1 - u) n - 2 max_in. Over (floor + 2 bound) / (1 - u) that is the floor with the whole bound inward; under it the
  // wall is contoured at n >= B + 1.2 bound (the guard keeps 0.6 of the bound inward: at a margin near 0 its refine runs
  // away), where (1 - u) n - (n - B) = B - u n stays at the floor to a micron.
  const double u = kSheetWallUnevenness, dev = deviation_mm;
  const double B = floor_mm / (1.0 - u), W1 = (floor_mm + 2.0 * dev) / (1.0 - u);
  if (wall_mm >= W1) return wall_mm;
  const double R = (B + 1.2 * dev) - floor_mm;
  return wall_mm + R * std::clamp((W1 - wall_mm) / (W1 - floor_mm), 0.0, 1.0);
}

double sheet_distance_at_local(const SheetField& s, const Vec3& q) {
  const double wall = sheet_wall_at_local(s, q);
  if (!(s.cell_mm > 0.0)) return std::numeric_limits<double>::infinity();
  const double t = wall > 0.0 ? lattice_sheet_wall_param_mm(sheet_topology(s.kind), wall, s.cell_mm) : 0.0;
  return tpms_wall_distance(s.kind, q.x - s.anchor[0], q.y - s.anchor[1], q.z - s.anchor[2], s.cell_mm, t);
}

double sheet_distance_at(const SheetField& s, const Vec3& p) { return sheet_distance_at_local(s, sheet_local(s, p)); }

double sheet_mid_distance_at(const SheetField& s, const Vec3& p) {
  if (!(s.cell_mm > 0.0)) return std::numeric_limits<double>::infinity();
  const Vec3 q = sheet_local(s, p);
  const TpmsValue v = tpms_eval(s.kind, q.x - s.anchor[0], q.y - s.anchor[1], q.z - s.anchor[2], s.cell_mm);
  const double g = std::sqrt(v.gx * v.gx + v.gy * v.gy + v.gz * v.gz);
  if (!(g > 1e-12)) return s.cell_mm;
  return v.f / g;
}

// ── seams ───────────────────────────────────────────────────────────────────────────────────────────────────────
// (sheet_seam_weight, sheet_seam_bump, sheet_blend_distance_at, sheet_seam_mm and sheet_seams_across: builder E's,
// sheet_blend.cpp.)

// ── the membrane (the Solid wall seam) ──────────────────────────────────────────────────────────────────────────
namespace {
struct MembraneNear {
  double pitch = 4.0;
  struct Box { int region = 0, partner = 0; double lo[3], hi[3]; };
  std::vector<Box> boxes;
  std::map<std::array<long long, 3>, std::vector<std::uint32_t>> grid;
};
const Vec3* membrane_dirs() {
  static const Vec3* dirs = [] {
    static Vec3 d[26];
    int k = 0;
    for (int x = -1; x <= 1; ++x)
      for (int y = -1; y <= 1; ++y)
        for (int z = -1; z <= 1; ++z) {
          if (!x && !y && !z) continue;
          const double l = std::sqrt(static_cast<double>(x * x + y * y + z * z));
          d[k++] = {x / l, y / l, z / l};
        }
    return d;
  }();
  return dirs;
}
}  // namespace

bool sheet_membrane_at(const Layout& layout, const Domain::Probe& probe, int region, const Vec3& p) {
  if (layout.membrane.empty() || !(layout.membrane_mm > 0.0)) return false;
  const MembraneNear* near = static_cast<const MembraneNear*>(layout.membrane_near.get());
  std::vector<int> partners;
  if (near) {
    const auto it = near->grid.find({static_cast<long long>(std::floor(p.x / near->pitch)),
                                     static_cast<long long>(std::floor(p.y / near->pitch)),
                                     static_cast<long long>(std::floor(p.z / near->pitch))});
    if (it == near->grid.end()) return false;
    for (std::uint32_t bi : it->second) {
      const MembraneNear::Box& b = near->boxes[bi];
      if (p.x < b.lo[0] || p.x > b.hi[0] || p.y < b.lo[1] || p.y > b.hi[1] || p.z < b.lo[2] || p.z > b.hi[2]) continue;
      if (std::find(partners.begin(), partners.end(), b.partner) == partners.end()) partners.push_back(b.partner);
    }
    if (partners.empty()) return false;
  }
  if (region < 0) {
    const Where w = probe.where(p);
    if (!w.lattice()) return false;
    region = w.id;
  }
  // The partners of `region` (those near p, when the index says).
  std::vector<int> mine;
  for (const auto& pr : layout.membrane) {
    const int other = pr[0] == region ? pr[1] : pr[1] == region ? pr[0] : -1;
    if (other < 0) continue;
    if (near && std::find(partners.begin(), partners.end(), other) == partners.end()) continue;
    mine.push_back(other);
  }
  if (mine.empty()) return false;
  const Vec3* d = membrane_dirs();
  const double r = layout.membrane_mm;
  bool weave = false;   // E: a weave partner's side gives no half, so the sheet's is read at two membranes too
  for (int o : mine) weave = weave || layout.is_weave(o);
  for (int ring = 1; ring <= (weave ? 2 : 1); ++ring)
    for (int k = 0; k < 26; ++k) {
      const double rr = ring * r;
      const Where w = probe.where({p.x + rr * d[k].x, p.y + rr * d[k].y, p.z + rr * d[k].z});
      if (!w.lattice()) continue;
      for (int o : mine)
        if (w.id == o && (ring == 1 || layout.is_weave(o))) return true;
    }
  return false;
}

namespace {
void cube_box(const Layout& layout, const Cell& c, double grow, double lo[3], double hi[3]) {
  const Frame& f = layout.frames[static_cast<std::size_t>(c.frame)];
  for (int a = 0; a < 3; ++a) { lo[a] = 1e300; hi[a] = -1e300; }
  for (int k = 0; k < 8; ++k) {
    const Vec3 v = f.at(c.lo[0] + ((k & 1) ? c.size : 0.0), c.lo[1] + ((k & 2) ? c.size : 0.0),
                        c.lo[2] + ((k & 4) ? c.size : 0.0));
    const double xyz[3] = {v.x, v.y, v.z};
    for (int a = 0; a < 3; ++a) { lo[a] = std::min(lo[a], xyz[a] - grow); hi[a] = std::max(hi[a], xyz[a] + grow); }
  }
}
// Files the index's boxes on its coarse grid.
void file_membrane_boxes(MembraneNear& near) {
  near.grid.clear();
  const auto slot = [&](double x) { return static_cast<long long>(std::floor(x / near.pitch)); };
  for (std::size_t i = 0; i < near.boxes.size(); ++i) {
    const MembraneNear::Box& b = near.boxes[i];
    for (long long x = slot(b.lo[0]); x <= slot(b.hi[0]); ++x)
      for (long long y = slot(b.lo[1]); y <= slot(b.hi[1]); ++y)
        for (long long z = slot(b.lo[2]); z <= slot(b.hi[2]); ++z)
          near.grid[{x, y, z}].push_back(static_cast<std::uint32_t>(i));
  }
}
}  // namespace

void set_sheet_membrane(Layout& layout, const std::vector<SheetSeamBand>& seams, const std::vector<SheetField>& sheets,
                        double half_mm) {
  layout.membrane.clear();
  layout.membrane_mm = 0.0;
  layout.membrane_near.reset();
  for (const SheetSeamBand& s : seams)
    if (s.solid_wall) layout.membrane.push_back({s.region_a, s.region_b});
  (void)sheets;
  if (layout.membrane.empty() || !(half_mm > 0.0)) {
    layout.membrane.clear();
    return;
  }
  layout.membrane_mm = half_mm;
  // The index: each paired region's cells, their cubes grown by twice the membrane, filed for the partner (a point of
  // the partner near one of these boxes may be within the membrane).
  auto near = std::make_shared<MembraneNear>();
  const double grow = 2.0 * half_mm + 1e-6;
  for (const auto& pr : layout.membrane)
    for (int side = 0; side < 2; ++side) {
      const int owner = pr[side], partner = pr[1 - side];
      for (const Cell& c : layout.cells) {
        if (c.region != owner) continue;
        MembraneNear::Box b;
        b.region = partner;    // a point of `partner` inside this box may be near `owner`'s space
        b.partner = owner;
        cube_box(layout, c, grow, b.lo, b.hi);
        near->boxes.push_back(b);
      }
    }
  file_membrane_boxes(*near);
  layout.membrane_near = near;
}

void set_sheet_weave_membrane(Layout& layout, const Domain& domain, const std::vector<SheetField>& sheets,
                              double half_mm) {
  if (sheets.empty() || layout.weave.empty() || !(half_mm > 0.0)) return;
  if (layout.membrane_mm > 0.0) half_mm = layout.membrane_mm;   // one membrane_mm for every pair
  auto near = std::make_shared<MembraneNear>();
  if (layout.membrane_near) {
    *near = *static_cast<const MembraneNear*>(layout.membrane_near.get());
  } else {   // pairs set with no index (none today): their cells, as set_sheet_membrane files them
    const double grow = 2.0 * half_mm + 1e-6;
    for (const auto& pr : layout.membrane)
      for (int side = 0; side < 2; ++side)
        for (const Cell& c : layout.cells) {
          if (c.region != pr[side]) continue;
          MembraneNear::Box b;
          b.region = pr[1 - side];
          b.partner = pr[side];
          cube_box(layout, c, grow, b.lo, b.hi);
          near->boxes.push_back(b);
        }
  }
  // The sheet's side is two lines: a point of the sheet within two membranes of the weave's box (read at up to
  // 2 x half, in 26 directions) may be in the wall.
  const double grow = 2.1 * half_mm + 1e-6;
  bool any = false;
  for (const Layout::Weave& wv : layout.weave) {
    const Region* reg = nullptr;
    for (const Region& r : domain.spec().regions)
      if (r.id == wv.region) reg = &r;
    if (!reg) continue;
    double lo[3] = {1e300, 1e300, 1e300}, hi[3] = {-1e300, -1e300, -1e300};
    const ClearanceGeometry& g = reg->prism;
    const bool flat = !reg->is_shell() && g.valid && !g.mask && g.kind == ClearanceKind::Face;
    if (flat) {
      double u0 = g.u_lo, u1 = g.u_hi, w0 = g.w_lo, w1 = g.w_hi;
      for (const auto& loop : g.outline_uv)   // the outline in (u, w), whichever way round the app's pair was written
        for (const auto& q : loop)
          for (double v : {q[0], q[1], -q[0], -q[1]}) {
            u0 = std::min(u0, v); u1 = std::max(u1, v); w0 = std::min(w0, v); w1 = std::max(w1, v);
          }
      const double e = std::max(0.0, reg->expand_mm);
      u0 -= e; u1 += e; w0 -= e; w1 += e;
      for (int k = 0; k < 8; ++k) {
        const double uu = (k & 1) ? u1 : u0, ww = (k & 2) ? w1 : w0, ss = (k & 4) ? g.depth : 0.0;
        const Vec3 v{g.origin.x + g.u.x * uu + g.w.x * ww + g.normal.x * ss,
                     g.origin.y + g.u.y * uu + g.w.y * ww + g.normal.y * ss,
                     g.origin.z + g.u.z * uu + g.w.z * ww + g.normal.z * ss};
        const double xyz[3] = {v.x, v.y, v.z};
        for (int a = 0; a < 3; ++a) { lo[a] = std::min(lo[a], xyz[a] - grow); hi[a] = std::max(hi[a], xyz[a] + grow); }
      }
    }
    for (const SheetField& f : sheets) {
      if (f.region == wv.region) continue;
      bool listed = false;
      for (const auto& pr : layout.membrane)
        listed = listed || (pr[0] == f.region && pr[1] == wv.region) || (pr[1] == f.region && pr[0] == wv.region);
      if (!listed) layout.membrane.push_back({f.region, wv.region});
      any = true;
      if (flat) {
        MembraneNear::Box b;
        b.region = f.region;   // a point of the sheet's region inside this box may be near the weave's space
        b.partner = wv.region;
        for (int a = 0; a < 3; ++a) { b.lo[a] = lo[a]; b.hi[a] = hi[a]; }
        near->boxes.push_back(b);
      } else {                 // a curved weave region: every cell of the sheet may be near it
        for (const Cell& c : layout.cells) {
          if (c.region != f.region || c.frame != f.frame) continue;
          MembraneNear::Box b;
          b.region = f.region;
          b.partner = wv.region;
          cube_box(layout, c, 1e-6, b.lo, b.hi);
          near->boxes.push_back(b);
        }
      }
    }
  }
  if (!any) return;
  layout.membrane_mm = half_mm;
  file_membrane_boxes(*near);
  layout.membrane_near = near;
}

// ── the fields of a layout ──────────────────────────────────────────────────────────────────────────────────────
std::vector<SheetField> sheet_fields(const Layout& layout) {
  std::vector<SheetField> out;
  TpmsKind kind;
  if (!sheet_kind_of(layout.topology, &kind)) return out;
  for (const RegionCells& rc : layout.regions) {
    std::vector<const Cell*> mine;
    for (const Cell& c : layout.cells)
      if (c.region == rc.region && c.frame == rc.frame) mine.push_back(&c);
    if (mine.empty()) continue;
    SheetField s;
    s.region = rc.region;
    s.frame = rc.frame;
    s.kind = kind;
    s.axes = layout.frames[static_cast<std::size_t>(rc.frame)];
    s.cell_mm = mine.front()->size;
    for (int k = 0; k < 3; ++k) s.anchor[k] = mine.front()->lo[k];
    s.cells = mine.size();
    // The grid places of the cells.
    long long mn[3] = {LLONG_MAX, LLONG_MAX, LLONG_MAX}, mx[3] = {LLONG_MIN, LLONG_MIN, LLONG_MIN};
    std::vector<std::array<long long, 3>> at(mine.size());
    for (std::size_t i = 0; i < mine.size(); ++i)
      for (int k = 0; k < 3; ++k) {
        at[i][k] = std::llround((mine[i]->lo[k] - s.anchor[k]) / s.cell_mm);
        mn[k] = std::min(mn[k], at[i][k]);
        mx[k] = std::max(mx[k], at[i][k]);
      }
    bool one = true;
    for (const Cell* c : mine) one = one && c->strut == mine.front()->strut;
    for (int k = 0; k < 3; ++k) s.lo[k] = s.anchor[k] + (static_cast<double>(mn[k]) + 0.5) * s.cell_mm;
    if (one) {
      s.wall_mm.assign(1, static_cast<float>(mine.front()->strut));
    } else {
      for (int k = 0; k < 3; ++k) s.n[k] = static_cast<int>(mx[k] - mn[k] + 1);
      const std::size_t total = static_cast<std::size_t>(s.n[0]) * s.n[1] * s.n[2];
      s.wall_mm.assign(total, 0.0f);
      std::vector<char> set(total, 0);
      const auto idx = [&](long long i, long long j, long long k) {
        return (static_cast<std::size_t>(k) * static_cast<std::size_t>(s.n[1]) + static_cast<std::size_t>(j)) *
                   static_cast<std::size_t>(s.n[0]) +
               static_cast<std::size_t>(i);
      };
      for (std::size_t i = 0; i < mine.size(); ++i) {
        const std::size_t x = idx(at[i][0] - mn[0], at[i][1] - mn[1], at[i][2] - mn[2]);
        if (!set[x]) {   // two cells at one place (none with one size): the first, in layout order
          s.wall_mm[x] = static_cast<float>(mine[i]->strut);
          set[x] = 1;
        }
      }
      // A breadth-first fill from the laid places, in index order.
      std::deque<std::size_t> q;
      for (std::size_t x = 0; x < total; ++x)
        if (set[x]) q.push_back(x);
      while (!q.empty()) {
        const std::size_t x = q.front();
        q.pop_front();
        const long long i = static_cast<long long>(x % s.n[0]);
        const long long j = static_cast<long long>((x / s.n[0]) % s.n[1]);
        const long long k = static_cast<long long>(x / (static_cast<std::size_t>(s.n[0]) * s.n[1]));
        const long long nb[6][3] = {{i - 1, j, k}, {i + 1, j, k}, {i, j - 1, k}, {i, j + 1, k}, {i, j, k - 1}, {i, j, k + 1}};
        for (const auto& b : nb) {
          if (b[0] < 0 || b[1] < 0 || b[2] < 0 || b[0] >= s.n[0] || b[1] >= s.n[1] || b[2] >= s.n[2]) continue;
          const std::size_t y = idx(b[0], b[1], b[2]);
          if (set[y]) continue;
          set[y] = 1;
          s.wall_mm[y] = s.wall_mm[x];
          q.push_back(y);
        }
      }
    }
    s.wall_min_mm = *std::min_element(s.wall_mm.begin(), s.wall_mm.end());
    s.wall_max_mm = *std::max_element(s.wall_mm.begin(), s.wall_mm.end());
    out.push_back(std::move(s));
  }
  return out;
}

std::vector<SheetSeamBand> sheet_seams(const Layout& layout, const std::vector<SheetField>& sheets, SheetSeam seam,
                                       double touch_mm) {
  std::vector<SheetSeamBand> out;
  if (sheets.size() < 2) return out;
  // Each field's cubes, grown by half the touch distance, filed on a coarse grid; two fields touch when a grown cube
  // of one meets a grown cube of the other.
  struct Box { std::size_t field; double lo[3], hi[3]; };
  std::vector<Box> boxes;
  std::map<std::pair<int, int>, std::size_t> field_of;   // (region, frame) -> field
  for (std::size_t i = 0; i < sheets.size(); ++i) field_of[{sheets[i].region, sheets[i].frame}] = i;
  for (const Cell& c : layout.cells) {
    const auto it = field_of.find({c.region, c.frame});
    if (it == field_of.end()) continue;
    Box b;
    b.field = it->second;
    cube_box(layout, c, 0.5 * touch_mm, b.lo, b.hi);
    boxes.push_back(b);
  }
  double pitch = 4.0;
  for (const SheetField& s : sheets) pitch = std::max(pitch, s.cell_mm);
  const auto slot = [&](double x) { return static_cast<long long>(std::floor(x / pitch)); };
  std::map<std::array<long long, 3>, std::vector<std::uint32_t>> grid;
  for (std::size_t i = 0; i < boxes.size(); ++i)
    for (long long x = slot(boxes[i].lo[0]); x <= slot(boxes[i].hi[0]); ++x)
      for (long long y = slot(boxes[i].lo[1]); y <= slot(boxes[i].hi[1]); ++y)
        for (long long z = slot(boxes[i].lo[2]); z <= slot(boxes[i].hi[2]); ++z)
          grid[{x, y, z}].push_back(static_cast<std::uint32_t>(i));
  std::vector<char> touch(sheets.size() * sheets.size(), 0);
  for (const auto& [key, list] : grid)
    for (std::size_t u = 0; u < list.size(); ++u)
      for (std::size_t v = u + 1; v < list.size(); ++v) {
        const Box& p = boxes[list[u]];
        const Box& q = boxes[list[v]];
        if (p.field == q.field) continue;
        const std::size_t a = std::min(p.field, q.field), b = std::max(p.field, q.field);
        if (touch[a * sheets.size() + b]) continue;
        bool meet = true;
        for (int k = 0; k < 3 && meet; ++k) meet = p.lo[k] <= q.hi[k] && q.lo[k] <= p.hi[k];
        if (meet) touch[a * sheets.size() + b] = 1;
      }
  for (std::size_t a = 0; a < sheets.size(); ++a)
    for (std::size_t b = a + 1; b < sheets.size(); ++b) {
      if (!touch[a * sheets.size() + b]) continue;
      SheetSeamBand s;
      s.a = static_cast<int>(a);
      s.b = static_cast<int>(b);
      s.region_a = sheets[a].region;
      s.region_b = sheets[b].region;
      s.band_mm = std::max(sheets[a].cell_mm, sheets[b].cell_mm);
      s.solid_wall = seam == SheetSeam::SolidWall;
      out.push_back(s);
    }
  return out;
}

// ── the bridge's flat form ──────────────────────────────────────────────────────────────────────────────────────
SheetsFlat flatten_sheets(const std::vector<SheetField>& sheets, const std::vector<SheetSeamBand>& seams) {
  SheetsFlat f;
  for (const SheetField& s : sheets) {
    f.region.push_back(s.region);
    f.frame.push_back(s.frame);
    f.kind.push_back(s.kind == TpmsKind::Gyroid ? 0 : 1);
    const Frame& a = s.axes;
    for (const Vec3& v : {a.origin, a.ax[0], a.ax[1], a.ax[2]})
      for (double x : {v.x, v.y, v.z}) f.axes.push_back(static_cast<float>(x));
    for (int k = 0; k < 3; ++k) f.anchor.push_back(static_cast<float>(s.anchor[k]));
    f.cell_mm.push_back(static_cast<float>(s.cell_mm));
    for (int k = 0; k < 3; ++k) f.n.push_back(s.n[k]);
    for (int k = 0; k < 3; ++k) f.lo.push_back(static_cast<float>(s.lo[k]));
    f.wall_count.push_back(static_cast<std::int32_t>(s.wall_mm.size()));
    f.wall_mm.insert(f.wall_mm.end(), s.wall_mm.begin(), s.wall_mm.end());
    f.wall_range.push_back(static_cast<float>(s.wall_min_mm));
    f.wall_range.push_back(static_cast<float>(s.wall_max_mm));
  }
  for (const SheetSeamBand& s : seams) {
    f.seam_ab.push_back(s.a);
    f.seam_ab.push_back(s.b);
    f.seam_band_mm.push_back(static_cast<float>(s.band_mm));
    f.seam_raise_mm.push_back(static_cast<float>(s.raise_mm));
    f.seam_solid.push_back(s.solid_wall ? 1 : 0);
    f.seam_fell_back.push_back(s.fell_back ? 1 : 0);
    f.seam_why.push_back(s.why);
  }
  return f;
}

// ── sheet_cells.bin ─────────────────────────────────────────────────────────────────────────────────────────────
SheetCellsFile sheet_cells_of(const Layout& layout, const PrintFrame& frame) {
  SheetCellsFile f;
  for (const Frame& fr : layout.frames) {
    Frame m = fr;
    if (frame.on) {
      m.origin = frame.point_to_model(fr.origin);
      for (int k = 0; k < 3; ++k) m.ax[k] = frame.dir_to_model(fr.ax[k]);
    }
    f.frames.push_back(m);
  }
  for (const Cell& c : layout.cells) {
    SheetCellRecord r;
    r.region = c.region;
    r.frame = c.frame;
    for (int k = 0; k < 3; ++k) r.lo[k] = static_cast<float>(c.lo[k]);
    r.size_mm = static_cast<float>(c.size);
    r.wall_mm = static_cast<float>(c.strut);
    r.margin = std::numeric_limits<float>::quiet_NaN();
    r.flags = c.cut ? SheetCellRecord::kCut : 0u;
    f.cells.push_back(r);
  }
  return f;
}

bool write_sheet_cells_file(const std::string& path, const SheetCellsFile& f) {
  std::ofstream o(path, std::ios::binary);
  if (!o) return false;
  o.write(kSheetCellsMagic, 8);
  const std::uint32_t head[3] = {static_cast<std::uint32_t>(f.frames.size()), static_cast<std::uint32_t>(f.cells.size()), 0u};
  o.write(reinterpret_cast<const char*>(head), sizeof head);
  for (const Frame& fr : f.frames) {
    float v[12];
    int k = 0;
    for (const Vec3& x : {fr.origin, fr.ax[0], fr.ax[1], fr.ax[2]}) {
      v[k++] = static_cast<float>(x.x);
      v[k++] = static_cast<float>(x.y);
      v[k++] = static_cast<float>(x.z);
    }
    o.write(reinterpret_cast<const char*>(v), sizeof v);
  }
  if (!f.cells.empty())
    o.write(reinterpret_cast<const char*>(f.cells.data()), static_cast<std::streamsize>(f.cells.size() * sizeof(SheetCellRecord)));
  return static_cast<bool>(o);
}

bool read_sheet_cells_file(const std::string& path, SheetCellsFile& out, std::string* why) {
  const auto no = [&](const std::string& w) {
    if (why) *why = w;
    return false;
  };
  std::ifstream in(path, std::ios::binary);
  if (!in) return no("the sheet cells file cannot be opened");
  std::string bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  if (bytes.size() < 20 || std::memcmp(bytes.data(), kSheetCellsMagic, 8) != 0) return no("not a sheet cells file");
  std::uint32_t head[3];
  std::memcpy(head, bytes.data() + 8, sizeof head);
  const std::size_t need = 20 + static_cast<std::size_t>(head[0]) * 48 + static_cast<std::size_t>(head[1]) * 40;
  if (bytes.size() != need) return no("the sheet cells file is not the size its counts need");
  SheetCellsFile f;
  std::size_t at = 20;
  for (std::uint32_t i = 0; i < head[0]; ++i, at += 48) {
    float v[12];
    std::memcpy(v, bytes.data() + at, sizeof v);
    for (float x : v)
      if (!std::isfinite(x)) return no("a frame of the sheet cells file is not finite");
    Frame fr;
    fr.origin = {v[0], v[1], v[2]};
    for (int k = 0; k < 3; ++k) fr.ax[k] = {v[3 + 3 * k], v[4 + 3 * k], v[5 + 3 * k]};
    f.frames.push_back(fr);
  }
  f.cells.resize(head[1]);
  if (head[1]) std::memcpy(f.cells.data(), bytes.data() + at, static_cast<std::size_t>(head[1]) * 40);
  for (const SheetCellRecord& r : f.cells) {
    if (r.frame < 0 || static_cast<std::uint32_t>(r.frame) >= head[0]) return no("a sheet cell names a frame that is not there");
    const float v[6] = {r.lo[0], r.lo[1], r.lo[2], r.size_mm, r.wall_mm, r.cells_across};
    for (float x : v)
      if (!std::isfinite(x)) return no("a sheet cell's number is not finite");
  }
  out = std::move(f);
  return true;
}

}  // namespace topopt::lattice_layout
