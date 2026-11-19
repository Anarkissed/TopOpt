// Brief E3a (lattice_layout_organic.hpp, rules OS10 to OS14): strengthening by adding. The operations a round adds, the
// file that keeps them, their replay after a lay with each round's hash checked, and the old-bar invariant.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <limits>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_organic.hpp"

namespace topopt::lattice_layout {
namespace {

std::uint64_t bits(double x) {
  std::uint64_t u = 0;
  std::memcpy(&u, &x, sizeof u);
  return u;
}
using Ends = std::array<std::uint64_t, 6>;
Ends ends_of(const Vec3& a, const Vec3& b) { return {bits(a.x), bits(a.y), bits(a.z), bits(b.x), bits(b.y), bits(b.z)}; }

// Non-link bars by their two ends exactly (either order); the first in list order.
std::map<Ends, std::size_t> by_ends(const Bars& bars) {
  std::map<Ends, std::size_t> m;
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    const Bar& b = bars.bars[i];
    if (b.link) continue;
    m.emplace(ends_of(b.a, b.b), i);
    m.emplace(ends_of(b.b, b.a), i);
  }
  return m;
}

using Key = std::array<long long, 3>;
Key end_key(const Vec3& p) {   // as bars.cpp's key_of (kSame 1e-5 mm)
  return {std::llround(p.x / 1e-5), std::llround(p.y / 1e-5), std::llround(p.z / 1e-5)};
}

double seg_dist(const Vec3& p, const Vec3& a, const Vec3& b, double* t_out) {
  const Vec3 d{b.x - a.x, b.y - a.y, b.z - a.z};
  const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
  const double t = l2 > 0.0 ? ((p.x - a.x) * d.x + (p.y - a.y) * d.y + (p.z - a.z) * d.z) / l2 : 0.0;
  if (t_out) *t_out = t;
  const double tc = std::clamp(t, 0.0, 1.0);
  const Vec3 q{a.x + d.x * tc - p.x, a.y + d.y * tc - p.y, a.z + d.z * tc - p.z};
  return std::sqrt(q.x * q.x + q.y * q.y + q.z * q.z);
}

void put_u64(std::ofstream& f, std::uint64_t v) { f.write(reinterpret_cast<const char*>(&v), 8); }
void put_i32(std::ofstream& f, std::int32_t v) { f.write(reinterpret_cast<const char*>(&v), 4); }

}  // namespace

std::uint64_t bars_hash(const Bars& bars) {
  std::uint64_t h = 1469598103934665603ULL;
  auto mix = [&](std::uint64_t v) {
    for (int k = 0; k < 8; ++k) {
      h ^= (v >> (8 * k)) & 0xffULL;
      h *= 1099511628211ULL;
    }
  };
  mix(bars.bars.size());
  for (const Bar& b : bars.bars) {
    for (const double x : {b.a.x, b.a.y, b.a.z, b.b.x, b.b.y, b.b.z, b.width}) mix(bits(x));
    mix(static_cast<std::uint64_t>(static_cast<int>(b.end_a)) | (static_cast<std::uint64_t>(static_cast<int>(b.end_b)) << 8));
    mix(static_cast<std::uint64_t>(static_cast<std::int64_t>(b.strand)));
    mix(static_cast<std::uint64_t>(static_cast<std::int64_t>(b.region)));
    mix((b.link ? 1u : 0u) | (b.brace ? 2u : 0u) | (b.net ? 4u : 0u) | (b.skin ? 8u : 0u) | (b.support ? 16u : 0u) |
        (b.level_tie ? 32u : 0u));
  }
  return h;
}

std::vector<std::vector<std::size_t>> pieces_on(const Bars& after, const std::vector<Bar>& olds, double tol_mm) {
  std::vector<std::vector<std::size_t>> out(olds.size());
  if (olds.empty()) return out;
  const double pitch = 2.0;
  auto slot = [&](double x) { return static_cast<long long>(std::floor(x / pitch)); };
  std::map<Key, std::vector<std::size_t>> grid;   // after's bars by the cell of their a end
  for (std::size_t i = 0; i < after.bars.size(); ++i) {
    const Vec3& p = after.bars[i].a;
    grid[{slot(p.x), slot(p.y), slot(p.z)}].push_back(i);
  }
  const double tol = tol_mm * (1.0 + 1e-9) + 1e-12;
  for (std::size_t k = 0; k < olds.size(); ++k) {
    const Bar& B = olds[k];
    for (long long x = slot(std::min(B.a.x, B.b.x) - tol); x <= slot(std::max(B.a.x, B.b.x) + tol); ++x)
      for (long long y = slot(std::min(B.a.y, B.b.y) - tol); y <= slot(std::max(B.a.y, B.b.y) + tol); ++y)
        for (long long z = slot(std::min(B.a.z, B.b.z) - tol); z <= slot(std::max(B.a.z, B.b.z) + tol); ++z) {
          const auto it = grid.find({x, y, z});
          if (it == grid.end()) continue;
          for (std::size_t j : it->second) {
            const Bar& A = after.bars[j];
            if (A.link != B.link || A.strand != B.strand) continue;
            if (seg_dist(A.a, B.a, B.b, nullptr) > tol || seg_dist(A.b, B.a, B.b, nullptr) > tol) continue;
            const double la = std::sqrt((A.b.x - A.a.x) * (A.b.x - A.a.x) + (A.b.y - A.a.y) * (A.b.y - A.a.y) + (A.b.z - A.a.z) * (A.b.z - A.a.z));
            const double lb = std::sqrt((B.b.x - B.a.x) * (B.b.x - B.a.x) + (B.b.y - B.a.y) * (B.b.y - B.a.y) + (B.b.z - B.a.z) * (B.b.z - B.a.z));
            if (!(la > tol) && lb > tol) continue;   // a piece of no length on a bar of some length tells nothing
            out[k].push_back(j);
          }
        }
    std::sort(out[k].begin(), out[k].end());
  }
  return out;
}

std::string old_bars_kept(const Bars& before, const Bars& after, double tol_mm, std::size_t* split) {
  if (split) *split = 0;
  const std::vector<std::vector<std::size_t>> on = pieces_on(after, before.bars, tol_mm);
  const double tol = tol_mm * (1.0 + 1e-9) + 1e-12;
  for (std::size_t i = 0; i < before.bars.size(); ++i) {
    const Bar& B = before.bars[i];
    const double L = std::sqrt((B.b.x - B.a.x) * (B.b.x - B.a.x) + (B.b.y - B.a.y) * (B.b.y - B.a.y) + (B.b.z - B.a.z) * (B.b.z - B.a.z));
    const std::string which = "bar " + std::to_string(i) + (B.link ? " (a link)" : "");
    if (on[i].empty()) return which + " is gone";
    // Only pieces at least as wide count: another bar of its strand lying along it (a strand that runs back over
    // itself) may be thinner, and is not it.
    bool whole = false;
    double thinner = -1.0;
    std::vector<std::pair<double, double>> span;
    for (std::size_t j : on[i]) {
      const Bar& A = after.bars[j];
      if (A.width < B.width - 1e-12) { thinner = std::max(thinner, A.width); continue; }
      double ta = 0.0, tb = 0.0;
      seg_dist(A.a, B.a, B.b, &ta);
      seg_dist(A.b, B.a, B.b, &tb);
      span.push_back({std::min(ta, tb), std::max(ta, tb)});
      const bool same = (seg_dist(A.a, B.a, B.a, nullptr) <= tol && seg_dist(A.b, B.b, B.b, nullptr) <= tol) ||
                        (seg_dist(A.a, B.b, B.b, nullptr) <= tol && seg_dist(A.b, B.a, B.a, nullptr) <= tol);
      whole = whole || same;
    }
    if (whole) continue;
    const std::string thin = thinner >= 0.0 ? " (a thinner bar lies along it: " + std::to_string(thinner) + " < " + std::to_string(B.width) + ")" : "";
    if (span.empty()) return which + (thinner >= 0.0 ? " is thinner" + thin : " is gone");
    if (B.link) return which + " was cut or moved" + thin;
    if (!(L > 0.0)) continue;
    std::sort(span.begin(), span.end());
    const double gap = tol / L;
    double reach = 0.0;
    if (span.front().first > gap) return which + " lost its a end" + thin;
    for (const auto& [s0, s1] : span) {
      if (s0 > reach + gap) return which + " has a gap along it" + thin;
      reach = std::max(reach, s1);
    }
    if (reach < 1.0 - gap) return which + " lost its b end" + thin;
    if (split) ++*split;
  }
  return {};
}

bool apply_add_round(Bars& bars, const Domain& domain, const AddRound& round, const AddContext& c, AddReport* report,
                     std::string* why) {
  auto no = [&](const std::string& w) {
    if (why) *why = w;
    return false;
  };
  AddReport local;
  AddReport& rep = report ? *report : local;
  rep = AddReport{};
  for (const AddOp& op : round.ops) {
    if (op.kind == 1 && op.v.size() != 8) return no("a brace point has " + std::to_string(op.v.size()) + " numbers, not 8");
    if (op.kind == 2 && op.v.size() != 7) return no("a widening has " + std::to_string(op.v.size()) + " numbers, not 7");
    if (op.kind == 3 && (op.v.size() < 12 || op.v.size() != 6 + 3 * static_cast<std::size_t>(std::max(0.0, op.v[5]))))
      return no("a relief vine's numbers do not match its point count");
    if (op.kind != 1 && op.kind != 2 && op.kind != 3)
      return no("an addition of kind " + std::to_string(op.kind) + " is not one this engine knows");
    for (double x : op.v)
      if (!std::isfinite(x)) return no("an addition holds a number that is not finite");
  }
  // 1. The brace points, all in one call of rule T's brace maker.
  {
    const std::map<Ends, std::size_t> at = by_ends(bars);
    std::vector<BracePoint> pts;
    for (const AddOp& op : round.ops) {
      if (op.kind != 1) continue;
      const auto it = at.find(ends_of({op.v[0], op.v[1], op.v[2]}, {op.v[3], op.v[4], op.v[5]}));
      if (it == at.end()) return no("a brace point's bar is not in the lattice");
      const Bar& b = bars.bars[it->second];
      // u is along the bar from the a the operation states.
      const bool flipped = !(bits(b.a.x) == bits(op.v[0]) && bits(b.a.y) == bits(op.v[1]) && bits(b.a.z) == bits(op.v[2]));
      pts.push_back({it->second, flipped ? 1.0 - op.v[6] : op.v[6], op.v[7]});
    }
    if (!pts.empty()) {
      WeaveBraceAsk ask;
      ask.light_mm = c.light_mm;
      ask.layer_mm = c.layer_mm;
      ask.link_width = c.link_width;
      rep.brace_points = pts.size();
      rep.braces = lay_braces(bars, domain, pts, ask, nullptr, &rep.braces_at);
    }
  }
  // 2. The widenings, then the links at the widened bars' ends (S8, only wider).
  {
    const std::map<Ends, std::size_t> at = by_ends(bars);
    std::set<Key> touched;
    for (const AddOp& op : round.ops) {
      if (op.kind != 2) continue;
      const auto it = at.find(ends_of({op.v[0], op.v[1], op.v[2]}, {op.v[3], op.v[4], op.v[5]}));
      if (it == at.end()) return no("a widening's bar is not in the lattice");
      Bar& b = bars.bars[it->second];
      if (op.v[6] > b.width) {
        b.width = op.v[6];
        ++rep.widened;
        touched.insert(end_key(b.a));
        touched.insert(end_key(b.b));
      }
    }
    if (!touched.empty()) {
      for (Bar& l : bars.bars) {
        if (!l.link) continue;
        const Key ka = end_key(l.a), kb = end_key(l.b);
        if (!touched.count(ka) && !touched.count(kb)) continue;
        // S8 from the struts at its two ends (each end: the widest non-link bar ending there), as apply_width_floors.
        double x = 0.0, y = 0.0;
        for (const Bar& b : bars.bars) {   // (the widest at an end not touched is read here; few links touch)
          if (b.link) continue;
          if (end_key(b.a) == ka || end_key(b.b) == ka) x = std::max(x, b.width);
          if (end_key(b.a) == kb || end_key(b.b) == kb) y = std::max(y, b.width);
        }
        if (x <= 0.0 && y <= 0.0) continue;
        const double thin = x > 0.0 && y > 0.0 ? std::min(x, y) : std::max(x, y), thick = std::max(x, y);
        const double w = std::max(c.light_mm, std::min(c.link_width * thin, thick));
        if (w > l.width + 1e-12) {
          l.width = w;
          ++rep.links_widened;
        }
      }
    }
  }
  // 3. OS18 (brief E8): the relief vines, in op order, each laid onto the bars as they now are (lay_relief_vine).
  for (const AddOp& op : round.ops) {
    if (op.kind != 3) continue;
    const std::size_t n = static_cast<std::size_t>(op.v[5]);
    std::vector<Vec3> pts;
    for (std::size_t k = 0; k < n; ++k) pts.push_back({op.v[6 + 3 * k], op.v[7 + 3 * k], op.v[8 + 3 * k]});
    auto kind = [](double x) { return x > 0.5 ? Bar::End::Solid : Bar::End::Node; };
    WeaveBraceAsk ask;
    ask.light_mm = c.light_mm;
    ask.layer_mm = c.layer_mm;
    ask.link_width = c.link_width;
    rep.relief_bars += lay_relief_vine(bars, pts, op.v[1], op.v[2], static_cast<int>(op.v[0]), kind(op.v[3]), kind(op.v[4]), ask);
    ++rep.relief_vines;
  }
  return true;
}

bool apply_additions(Bars& bars, const Domain& domain, const Additions& adds, const AddContext& c, std::string* why,
                     const std::function<std::string(Bars&)>& between) {
  for (std::size_t r = 0; r < adds.rounds.size(); ++r) {
    std::string w;
    if (!apply_add_round(bars, domain, adds.rounds[r], c, nullptr, &w)) {
      if (why) *why = "round " + std::to_string(r + 1) + ": " + w;
      return false;
    }
    if (c.line_mm > 0.0) guard_bars(bars, domain, c.weave_regions, c.line_mm, c.guard);   // OG5
    if (between) {
      w = between(bars);
      if (!w.empty()) {
        if (why) *why = "round " + std::to_string(r + 1) + ": " + w;
        return false;
      }
    }
    const std::uint64_t h = bars_hash(bars);
    if (h != adds.rounds[r].hash) {
      char b[96];
      std::snprintf(b, sizeof b, "round %zu: the lattice's hash is %016llx, the additions say %016llx", r + 1,
                    static_cast<unsigned long long>(h), static_cast<unsigned long long>(adds.rounds[r].hash));
      if (why) *why = b;
      return false;
    }
  }
  return true;
}

bool write_additions_file(const std::string& path, const Additions& adds) {
  std::ofstream f(path, std::ios::binary);
  if (!f) return false;
  f.write("TOADDS\0\0", 8);
  put_i32(f, 1);
  put_i32(f, static_cast<std::int32_t>(adds.rounds.size()));
  for (const AddRound& r : adds.rounds) {
    put_u64(f, r.hash);
    put_i32(f, static_cast<std::int32_t>(r.ops.size()));
    for (const AddOp& op : r.ops) {
      put_i32(f, op.kind);
      put_i32(f, static_cast<std::int32_t>(op.v.size()));
      f.write(reinterpret_cast<const char*>(op.v.data()), static_cast<std::streamsize>(8 * op.v.size()));
    }
  }
  return static_cast<bool>(f);
}

bool read_additions_file(const std::string& path, Additions& adds, std::string* why) {
  auto no = [&](const char* w) {
    if (why) *why = w;
    return false;
  };
  std::ifstream f(path, std::ios::binary);
  if (!f) return no("the additions file cannot be opened");
  char magic[8];
  std::int32_t version = 0, rounds = 0;
  f.read(magic, 8);
  f.read(reinterpret_cast<char*>(&version), 4);
  f.read(reinterpret_cast<char*>(&rounds), 4);
  if (!f || std::memcmp(magic, "TOADDS\0\0", 8) != 0) return no("the additions file is not one");
  if (version != 1) return no("the additions file's version is not 1");
  if (rounds < 0) return no("the additions file's round count is below 0");
  Additions out;
  for (std::int32_t r = 0; r < rounds; ++r) {
    AddRound R;
    std::int32_t n = 0;
    f.read(reinterpret_cast<char*>(&R.hash), 8);
    f.read(reinterpret_cast<char*>(&n), 4);
    if (!f || n < 0) return no("the additions file is shorter than its count");
    for (std::int32_t k = 0; k < n; ++k) {
      AddOp op;
      std::int32_t m = 0;
      f.read(reinterpret_cast<char*>(&op.kind), 4);
      f.read(reinterpret_cast<char*>(&m), 4);
      if (!f || m < 0 || m > 1000000) return no("the additions file is shorter than its count");
      op.v.resize(static_cast<std::size_t>(m));
      f.read(reinterpret_cast<char*>(op.v.data()), static_cast<std::streamsize>(8 * op.v.size()));
      if (!f) return no("the additions file is shorter than its count");
      R.ops.push_back(std::move(op));
    }
    out.rounds.push_back(std::move(R));
  }
  if (f.peek() != EOF) return no("the additions file is longer than its count");
  adds = std::move(out);
  return true;
}

// ── OS18 (amended 2026-11-19): the twin vine maker ─────────────────────────────────────────────────────────────────────────
namespace {
constexpr double kVineGrid = 2.0;   // mm: the bars' search grid (a search structure only: it changes no answer)
long long vine_cell(double x) { return static_cast<long long>(std::floor(x / kVineGrid)); }
double vdot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 vadd(const Vec3& a, const Vec3& b, double k) { return Vec3{a.x + b.x * k, a.y + b.y * k, a.z + b.z * k}; }
Vec3 closest_on(const Vec3& p, const Vec3& a, const Vec3& b) {
  const Vec3 d{b.x - a.x, b.y - a.y, b.z - a.z};
  const double l2 = vdot(d, d);
  const double t = l2 > 0.0 ? std::clamp(vdot(Vec3{p.x - a.x, p.y - a.y, p.z - a.z}, d) / l2, 0.0, 1.0) : 0.0;
  return vadd(a, d, t);
}
double vdist(const Vec3& a, const Vec3& b) { return std::sqrt(vdot(Vec3{a.x - b.x, a.y - b.y, a.z - b.z}, Vec3{a.x - b.x, a.y - b.y, a.z - b.z})); }
// The principal directions at p (its voxel's tensor, Jacobi), by |eigenvalue| down (ties by index); false off the grid
// or where the tensor is zero.
bool principal_at(const TensorField& F, const Vec3& p, std::array<Vec3, 3>& e) {
  const int I = static_cast<int>(std::floor((p.x - F.origin.x) / F.spacing)), J = static_cast<int>(std::floor((p.y - F.origin.y) / F.spacing)),
            K = static_cast<int>(std::floor((p.z - F.origin.z) / F.spacing));
  if (F.empty() || I < 0 || J < 0 || K < 0 || I >= F.nx || J >= F.ny || K >= F.nz) return false;
  const double* t = &F.voigt[6 * F.index(I, J, K)];
  double norm = 0.0;
  for (int q = 0; q < 6; ++q) norm += t[q] * t[q];
  if (!(norm > 0.0)) return false;
  double A[3][3] = {{t[0], t[3], t[5]}, {t[3], t[1], t[4]}, {t[5], t[4], t[2]}}, V[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
  for (int sweep = 0; sweep < 50; ++sweep)
    for (int a = 0; a < 3; ++a)
      for (int b = a + 1; b < 3; ++b) {
        if (std::fabs(A[a][b]) < 1e-18) continue;
        const double th = 0.5 * std::atan2(2 * A[a][b], A[b][b] - A[a][a]), cs = std::cos(th), sn = std::sin(th);
        for (int k = 0; k < 3; ++k) { const double x = A[k][a], y = A[k][b]; A[k][a] = cs * x - sn * y; A[k][b] = sn * x + cs * y; }
        for (int k = 0; k < 3; ++k) { const double x = A[a][k], y = A[b][k]; A[a][k] = cs * x - sn * y; A[b][k] = sn * x + cs * y; }
        for (int k = 0; k < 3; ++k) { const double x = V[k][a], y = V[k][b]; V[k][a] = cs * x - sn * y; V[k][b] = sn * x + cs * y; }
      }
  int o[3] = {0, 1, 2};
  std::sort(o, o + 3, [&](int i, int j) {
    return std::fabs(A[i][i]) > std::fabs(A[j][j]) || (std::fabs(A[i][i]) == std::fabs(A[j][j]) && i < j);
  });
  for (int k = 0; k < 3; ++k) e[static_cast<std::size_t>(k)] = Vec3{V[0][o[k]], V[1][o[k]], V[2][o[k]]};
  return true;
}
}  // namespace

TwinVineMaker::TwinVineMaker(const Bars& bars, const Domain& domain, const TensorField& field, const TwinAsk& ask)
    : bars_(bars), domain_(domain), field_(field), ask_(ask) {
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    const Bar& b = bars.bars[i];
    const double r = 0.5 * b.width + 1.0;
    for (long long x = vine_cell(std::min(b.a.x, b.b.x) - r); x <= vine_cell(std::max(b.a.x, b.b.x) + r); ++x)
      for (long long y = vine_cell(std::min(b.a.y, b.b.y) - r); y <= vine_cell(std::max(b.a.y, b.b.y) + r); ++y)
        for (long long z = vine_cell(std::min(b.a.z, b.b.z) - r); z <= vine_cell(std::max(b.a.z, b.b.z) + r); ++z)
          grid_[{x, y, z}].push_back(i);
  }
}

TwinVine TwinVineMaker::make(const std::vector<Vec3>& line, int region, double stretch_width, double width, double spacing,
                             const std::vector<Vec3>& avoid) const {
  TwinVine out;
  if (line.size() < 2) { out.no_room = "too_short"; return out; }
  const Domain::Probe probe = domain_.probe();
  const double gap = ask_.gap_mm, w = width;
  const double s = 0.5 * (stretch_width + w) + gap;
  out.offset_mm = s;
  // Arc length along the line.
  std::vector<double> u(line.size(), 0.0);
  for (std::size_t k = 1; k < line.size(); ++k) u[k] = u[k - 1] + vdist(line[k - 1], line[k]);
  const double L = u.back();
  auto at_u = [&](double x, Vec3& tangent) {
    std::size_t k = 1;
    while (k + 1 < line.size() && u[k] < x) ++k;
    const double l = u[k] - u[k - 1];
    const double t = l > 0.0 ? std::clamp((x - u[k - 1]) / l, 0.0, 1.0) : 0.0;
    tangent = Vec3{(line[k].x - line[k - 1].x) / (l > 0 ? l : 1), (line[k].y - line[k - 1].y) / (l > 0 ? l : 1),
                   (line[k].z - line[k - 1].z) / (l > 0 ? l : 1)};
    return vadd(line[k - 1], Vec3{line[k].x - line[k - 1].x, line[k].y - line[k - 1].y, line[k].z - line[k - 1].z}, t);
  };
  Vec3 tm;
  out.mid = at_u(0.5 * L, tm);
  if (L < 4.0 * s) { out.no_room = "too_short"; return out; }
  const Vec3 J0 = line.front(), Jn = line.back();
  auto on_line = [&](const Vec3& p) {   // within 1e-4 mm of the stretch's line
    for (std::size_t k = 1; k < line.size(); ++k)
      if (vdist(p, closest_on(p, line[k - 1], line[k])) < 1e-4) return true;
    return false;
  };
  auto ends_at = [&](const Bar& b, const Vec3& p) { return vdist(b.a, p) < 1e-4 || vdist(b.b, p) < 1e-4; };
  std::vector<std::size_t> ids;
  auto near = [&](const Vec3& p, std::vector<std::size_t>& out_ids) {
    out_ids.clear();
    for (long long x = vine_cell(p.x) - 1; x <= vine_cell(p.x) + 1; ++x)
      for (long long y = vine_cell(p.y) - 1; y <= vine_cell(p.y) + 1; ++y)
        for (long long z = vine_cell(p.z) - 1; z <= vine_cell(p.z) + 1; ++z) {
          const auto it = grid_.find({x, y, z});
          if (it != grid_.end()) out_ids.insert(out_ids.end(), it->second.begin(), it->second.end());
        }
    std::sort(out_ids.begin(), out_ids.end());
    out_ids.erase(std::unique(out_ids.begin(), out_ids.end()), out_ids.end());
  };
  // The bars on the stretch (exempt), and the bars that END on it between J0 and Jn (the cross vines): (bar, its end on
  // the line, the arc length there, its unit direction away from the line).
  std::set<std::size_t> on_stretch;
  struct Cross { std::size_t bar; Vec3 at; double u; Vec3 dir; double len; };
  std::vector<Cross> cross;
  {
    std::set<std::size_t> seen;
    for (std::size_t k = 0; k < line.size(); ++k) {
      near(line[k], ids);
      for (std::size_t i : ids) seen.insert(i);
      if (k + 1 < line.size()) {
        const int m = std::max(1, static_cast<int>(std::ceil(vdist(line[k], line[k + 1]) / 1.0)));
        for (int q = 1; q < m; ++q) {
          near(vadd(line[k], Vec3{line[k + 1].x - line[k].x, line[k + 1].y - line[k].y, line[k + 1].z - line[k].z}, double(q) / m), ids);
          for (std::size_t i : ids) seen.insert(i);
        }
      }
    }
    for (std::size_t i : seen) {
      const Bar& b = bars_.bars[i];
      const bool ia = on_line(b.a), ib = on_line(b.b);
      if (ia && ib) { on_stretch.insert(i); continue; }
      if (!ia && !ib) continue;
      const Vec3 e = ia ? b.a : b.b, f = ia ? b.b : b.a;
      if (vdist(e, J0) < 1e-4 || vdist(e, Jn) < 1e-4) continue;   // at J0 or Jn: exempt (handled by ends_at)
      double ue = 0.0;
      for (std::size_t k = 1; k < line.size(); ++k)
        if (vdist(e, closest_on(e, line[k - 1], line[k])) < 1e-4) { ue = u[k - 1] + vdist(line[k - 1], closest_on(e, line[k - 1], line[k])); break; }
      const double l = vdist(e, f);
      if (!(l > 0.0)) continue;
      cross.push_back({i, e, ue, Vec3{(f.x - e.x) / l, (f.y - e.y) / l, (f.z - e.z) / l}, l});
    }
  }
  // The sides: the two principal directions across the stretch at its middle, both senses.
  std::array<Vec3, 3> e;
  if (!principal_at(field_, out.mid, e)) { out.no_room = "no_free_side"; return out; }
  Vec3 axis{Jn.x - J0.x, Jn.y - J0.y, Jn.z - J0.z};
  const double al = std::sqrt(vdot(axis, axis));
  axis = al > 0.0 ? Vec3{axis.x / al, axis.y / al, axis.z / al} : tm;
  int along = 0;
  for (int k = 1; k < 3; ++k)
    if (std::fabs(vdot(e[static_cast<std::size_t>(k)], axis)) > std::fabs(vdot(e[static_cast<std::size_t>(along)], axis))) along = k;
  auto normal_at = [&](const Vec3& side, const Vec3& t, Vec3& n) {   // the side square to the local tangent
    n = vadd(side, t, -vdot(side, t));
    const double nl = std::sqrt(vdot(n, n));
    if (!(nl > 0.2)) return false;
    n = Vec3{n.x / nl, n.y / nl, n.z / nl};
    return true;
  };
  auto clearance = [&](const Vec3& p) {
    near(p, ids);
    double least = 1e300;
    for (std::size_t i : ids) {
      if (on_stretch.count(i)) continue;
      const Bar& b = bars_.bars[i];
      least = std::min(least, vdist(p, closest_on(p, b.a, b.b)) - 0.5 * b.width - 0.5 * w);
    }
    return least;
  };
  std::vector<std::pair<double, Vec3>> sides;
  for (int k = 0; k < 3; ++k) {
    if (k == along) continue;
    for (int sg = -1; sg <= 1; sg += 2) {
      const Vec3 sd{e[static_cast<std::size_t>(k)].x * sg, e[static_cast<std::size_t>(k)].y * sg, e[static_cast<std::size_t>(k)].z * sg};
      bool used = false;
      for (const Vec3& a : avoid) used = used || vdot(sd, a) > 0.7071;
      if (used) continue;
      Vec3 n;
      if (!normal_at(sd, tm, n)) continue;
      sides.push_back({clearance(vadd(out.mid, n, s)), sd});
    }
  }
  std::stable_sort(sides.begin(), sides.end(), [](const auto& a, const auto& b) { return a.first > b.first; });
  bool any_bar = false, any_outside = sides.empty();
  for (const auto& cand : sides) {
    ++out.sides_tried;
    const Vec3 side = cand.second;
    // The path: J0, the offset reached at 2 s, the offset at every vertex between, the offset at L - 2 s, Jn; and the
    // joined cross bars' points at the offset, in order along the stretch.
    std::vector<std::pair<double, Vec3>> path;
    bool ok = true;
    auto offset_point = [&](double x) {
      Vec3 t;
      const Vec3 p = at_u(x, t);
      Vec3 n;
      if (!normal_at(side, t, n)) { ok = false; return p; }
      return vadd(p, n, s);
    };
    path.push_back({0.0, J0});
    path.push_back({2.0 * s, offset_point(2.0 * s)});
    for (std::size_t k = 1; k + 1 < line.size(); ++k)
      if (u[k] > 2.0 * s + 1e-6 && u[k] < L - 2.0 * s - 1e-6) {
        const Vec3 t1{line[k].x - line[k - 1].x, line[k].y - line[k - 1].y, line[k].z - line[k - 1].z};
        const Vec3 t2{line[k + 1].x - line[k].x, line[k + 1].y - line[k].y, line[k + 1].z - line[k].z};
        const double l1 = std::sqrt(vdot(t1, t1)), l2 = std::sqrt(vdot(t2, t2));
        Vec3 t{t1.x / l1 + t2.x / l2, t1.y / l1 + t2.y / l2, t1.z / l1 + t2.z / l2};
        const double tl = std::sqrt(vdot(t, t));
        Vec3 n;
        if (!(tl > 0.0) || !normal_at(side, Vec3{t.x / tl, t.y / tl, t.z / tl}, n)) { ok = false; break; }
        path.push_back({u[k], vadd(line[k], n, s)});
      }
    for (double x = 2.0 * s + 1.0; x < L - 2.0 * s - 0.5; x += 1.0) path.push_back({x, offset_point(x)});   // every 1 mm
    path.push_back({L - 2.0 * s, offset_point(L - 2.0 * s)});
    path.push_back({L, Jn});
    if (!ok) continue;
    std::set<std::size_t> joined;
    for (const Cross& c : cross) {
      Vec3 t;
      (void)at_u(c.u, t);
      Vec3 n;
      if (!normal_at(side, t, n)) continue;
      const double cn = vdot(c.dir, n);
      if (!(cn > 0.3)) continue;
      const double reach = s / cn;
      if (reach > c.len + 1e-9) continue;   // the bar ends before the offset: judged by the gap below
      path.push_back({c.u, vadd(c.at, c.dir, reach)});
      joined.insert(c.bar);
    }
    std::stable_sort(path.begin(), path.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
    // The checks, every 0.1 mm.
    bool bar_near = false, outside = false;
    for (std::size_t k = 0; k + 1 < path.size() && !bar_near && !outside; ++k) {
      const Vec3 A = path[k].second, B = path[k + 1].second;
      const double l = vdist(A, B);
      const int m = std::max(1, static_cast<int>(std::ceil(l / 0.1)));
      for (int q = 0; q <= m && !bar_near && !outside; ++q) {
        const Vec3 p = vadd(A, Vec3{B.x - A.x, B.y - A.y, B.z - A.z}, double(q) / m);
        const bool by_end = vdist(p, J0) < w || vdist(p, Jn) < w;
        if (!by_end) {
          const Where wh = probe.where(p);
          if (!wh.lattice() || wh.id != region) { outside = true; break; }
        }
        // Within the lead of J0 or Jn (within 3 s of the joint) the eye converges on the joint: the stretch's bars and the bars
        // at that joint are passed there; everywhere else only the joined cross bars are.
        const bool at_end = vdist(p, J0) < 3.0 * s || vdist(p, Jn) < 3.0 * s;
        near(p, ids);
        for (std::size_t i : ids) {
          if (joined.count(i)) continue;
          const Bar& b = bars_.bars[i];
          if (at_end && (on_stretch.count(i) || ends_at(b, J0) || ends_at(b, Jn))) continue;
          if (vdist(p, closest_on(p, b.a, b.b)) - 0.5 * b.width - 0.5 * w < gap - 1e-6) {
            bar_near = true;
            break;
          }
        }
      }
    }
    if (bar_near) { any_bar = true; continue; }
    if (outside) { any_outside = true; continue; }
    out.laid = true;
    out.side = side;
    out.cross_joined = joined.size();
    for (const auto& pp : path)
      if (out.points.empty() || vdist(out.points.back(), pp.second) > 1e-9) out.points.push_back(pp.second);
    out.op.kind = 3;
    out.op.v = {static_cast<double>(region), w, spacing, 0.0, 0.0, static_cast<double>(out.points.size())};
    for (const Vec3& q : out.points) { out.op.v.push_back(q.x); out.op.v.push_back(q.y); out.op.v.push_back(q.z); }
    return out;
  }
  out.no_room = any_bar || !any_outside ? "no_free_side" : "outside_lattice";
  return out;
}

}  // namespace topopt::lattice_layout
