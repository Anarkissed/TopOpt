// Brief E3a (lattice_layout_organic.hpp, rules OS10 to OS14): strengthening by adding. The operations a round adds, the
// file that keeps them, their replay after a lay with each round's hash checked, and the old-bar invariant.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
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

// ── OS18 (brief E8): the relief vine maker ─────────────────────────────────────────────────────────────────────────
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

ReliefVineMaker::ReliefVineMaker(const Bars& bars, const Domain& domain, const TensorField& field, const ReliefVineAsk& ask)
    : bars_(bars), domain_(domain), field_(field), ask_(ask) {
  for (const Bar& b : bars.bars)   // Leg I: the joints
    for (const Vec3& e : {b.a, b.b}) {
      Joint& j = ends_[{std::llround(e.x * 1e4), std::llround(e.y * 1e4), std::llround(e.z * 1e4)}];
      j.p = e;
      ++j.ends;
      if (std::find(j.strands.begin(), j.strands.end(), b.strand) == j.strands.end()) j.strands.push_back(b.strand);
    }
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    const Bar& b = bars.bars[i];
    const double r = 0.5 * b.width + 1.0;
    for (long long x = vine_cell(std::min(b.a.x, b.b.x) - r); x <= vine_cell(std::max(b.a.x, b.b.x) + r); ++x)
      for (long long y = vine_cell(std::min(b.a.y, b.b.y) - r); y <= vine_cell(std::max(b.a.y, b.b.y) + r); ++y)
        for (long long z = vine_cell(std::min(b.a.z, b.b.z) - r); z <= vine_cell(std::max(b.a.z, b.b.z) + r); ++z)
          grid_[{x, y, z}].push_back(i);
  }
}

ReliefVine ReliefVineMaker::make(const Bar& host, const Vec3& at, const std::vector<int>& own, double width) const {
  ReliefVine out;
  const Domain::Probe probe = domain_.probe();
  const double gap = ask_.gap_mm, w = width, spacing = host.cell > 0.0 ? host.cell : 2.0;
  const double step = ask_.step_ratio * spacing, longest = ask_.max_spacings * spacing;
  const double par_cos = std::cos(ask_.parallel_deg * 3.14159265358979323846 / 180.0);
  auto mine = [&](int strand) { return std::find(own.begin(), own.end(), strand) != own.end(); };
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
  Vec3 axis{host.b.x - host.a.x, host.b.y - host.a.y, host.b.z - host.a.z};
  const double al = std::sqrt(vdot(axis, axis));
  out.mid = closest_on(at, host.a, host.b);
  if (!(al > 0.0)) return out;
  axis = Vec3{axis.x / al, axis.y / al, axis.z / al};
  std::array<Vec3, 3> e;
  if (!principal_at(field_, out.mid, e)) return out;
  int along = 0;
  for (int k = 1; k < 3; ++k)
    if (std::fabs(vdot(e[static_cast<std::size_t>(k)], axis)) > std::fabs(vdot(e[static_cast<std::size_t>(along)], axis))) along = k;
  const double s_off = 0.5 * (host.width + w) + gap;
  std::vector<std::size_t> ids;
  auto clearance = [&](const Vec3& p) {   // the least surface distance from a vine of width w at p to any bar
    near(p, ids);
    double least = 1e300;
    for (std::size_t i : ids) {
      const Bar& b = bars_.bars[i];
      least = std::min(least, vdist(p, closest_on(p, b.a, b.b)) - 0.5 * b.width - 0.5 * w);
    }
    return least;
  };
  std::vector<std::pair<double, Vec3>> seeds;
  for (int k = 0; k < 3; ++k) {
    if (k == along) continue;
    for (int sg = -1; sg <= 1; sg += 2) {
      const Vec3 sd = vadd(out.mid, e[static_cast<std::size_t>(k)], sg * s_off);
      seeds.push_back({clearance(sd), sd});
    }
  }
  std::stable_sort(seeds.begin(), seeds.end(), [](const auto& a, const auto& b) { return a.first > b.first; });
  struct Half { bool ok = false, solid = false; std::vector<Vec3> pts; };
  for (const auto& cand : seeds) {
    const Vec3 seed = cand.second;
    ++out.tried;
    const Where ws = probe.where(seed);
    if (!ws.lattice() || ws.id != host.region) { ++out.seed_off; continue; }
    if (cand.first < gap - 1e-6) { ++out.seed_crowded; continue; }
    auto walk = [&](double sense) {
      Half h;
      Vec3 p = seed, head{axis.x * sense, axis.y * sense, axis.z * sense};
      const Vec3 start = head;
      double run = 0.0, parallel = 0.0;
      std::vector<std::size_t> ids2;
      h.pts.push_back(seed);
      while (run < longest + 1e-9) {
        std::array<Vec3, 3> ee;
        if (!principal_at(field_, p, ee)) { ++out.half_no_field; return h; }
        int kk = 0;
        for (int k = 1; k < 3; ++k)
          if (std::fabs(vdot(ee[static_cast<std::size_t>(k)], head)) > std::fabs(vdot(ee[static_cast<std::size_t>(kk)], head))) kk = k;
        Vec3 d = ee[static_cast<std::size_t>(kk)];
        if (vdot(d, head) < 0.0) d = Vec3{-d.x, -d.y, -d.z};
        if (vdot(d, start) < 0.0) { ++out.half_turned; return h; }   // turns back
        const Vec3 q = vadd(p, d, step);
        run += step;
        const Where wq = probe.where(q);
        if (!wq.lattice() || wq.id != host.region) {
          if (wq.why == Why::Outside || wq.lattice()) { ++out.half_left; return h; }   // into the air, or another region
          double a = 0.0, b = step;   // into the solid: its edge
          for (int it = 0; it < 30; ++it) {
            const double m = 0.5 * (a + b);
            const Where wm = probe.where(vadd(p, d, m));
            (wm.lattice() && wm.id == host.region ? a : b) = m;
          }
          h.pts.push_back(vadd(p, d, a));
          h.ok = h.solid = true;
          return h;
        }
        near(q, ids2);
        bool beside = false;
        double land = 1e300;
        Vec3 land_at{};
        int land_strand = -1;
        for (std::size_t i : ids2) {
          const Bar& b = bars_.bars[i];
          const Vec3 c = closest_on(q, b.a, b.b);
          const double surf = vdist(q, c) - 0.5 * b.width - 0.5 * w;
          if (!(surf < gap - 1e-6)) continue;
          const Vec3 bd{b.b.x - b.a.x, b.b.y - b.a.y, b.b.z - b.a.z};
          const double bl = std::sqrt(vdot(bd, bd));
          const bool par = bl > 0.0 && std::fabs(vdot(bd, d)) / bl > par_cos;
          if (par || b.link || mine(b.strand)) { beside = beside || par; continue; }
          if (surf < land) { land = surf; land_at = c; land_strand = b.strand; }   // a bar it crosses: it ends on its line
        }
        if (land < 1e299) {
          // Leg I (OS18b): a joint of the landed-on strand within snap x the spacing of the landing: the nearest.
          const double reach = ask_.snap_spacings * spacing;
          const Joint* J = nullptr;
          if (reach > 0.0) {
            double bj = reach + 1e-9;
            for (long long x = vine_cell(land_at.x - reach); x <= vine_cell(land_at.x + reach); ++x)
              for (long long y = vine_cell(land_at.y - reach); y <= vine_cell(land_at.y + reach); ++y)
                for (long long z = vine_cell(land_at.z - reach); z <= vine_cell(land_at.z + reach); ++z) {
                  const auto it = grid_.find({x, y, z});
                  if (it == grid_.end()) continue;
                  for (std::size_t i : it->second) {
                    const Bar& b = bars_.bars[i];
                    if (b.strand != land_strand) continue;
                    for (const Vec3& e : {b.a, b.b}) {
                      const auto jt = ends_.find({std::llround(e.x * 1e4), std::llround(e.y * 1e4), std::llround(e.z * 1e4)});
                      if (jt == ends_.end() || !(jt->second.ends >= 3 || jt->second.strands.size() >= 2)) continue;
                      const double dj = vdist(e, land_at);
                      if (dj < bj) { bj = dj; J = &jt->second; }
                    }
                  }
                }
          }
          if (J && vdist(J->p, land_at) > 1e-9) {
            // The last piece re-aimed from p at the joint: in the region's lattice, clear of every bar not at the joint
            // (by the gap), and not within the parallel angle of a bar at it.
            const Vec3 jd{J->p.x - p.x, J->p.y - p.y, J->p.z - p.z};
            const double jl = std::sqrt(vdot(jd, jd));
            bool good = jl > 1e-9;
            const int n = std::max(2, static_cast<int>(std::ceil(jl / 0.1)));
            std::vector<std::size_t> ids3;
            for (int k = 1; good && k < n; ++k) {
              const Vec3 s = vadd(p, jd, static_cast<double>(k) / n);
              const Where ws2 = probe.where(s);
              if (!ws2.lattice() || ws2.id != host.region) { good = false; break; }
              near(s, ids3);
              for (std::size_t i : ids3) {
                const Bar& b = bars_.bars[i];
                const bool at_joint = vdist(b.a, J->p) < 1e-4 || vdist(b.b, J->p) < 1e-4;
                if (at_joint || b.link || mine(b.strand)) continue;
                if (vdist(s, closest_on(s, b.a, b.b)) - 0.5 * b.width - 0.5 * w < gap - 1e-6) { good = false; break; }
              }
            }
            if (good) {
              near(J->p, ids3);
              for (std::size_t i : ids3) {
                const Bar& b = bars_.bars[i];
                if (!(vdist(b.a, J->p) < 1e-4 || vdist(b.b, J->p) < 1e-4)) continue;
                const Vec3 bd{b.b.x - b.a.x, b.b.y - b.a.y, b.b.z - b.a.z};
                const double bl = std::sqrt(vdot(bd, bd));
                if (bl > 0.0 && std::fabs(vdot(bd, jd)) / (bl * jl) > par_cos) { good = false; break; }
              }
            }
            if (!good) { ++out.snap_dropped; return h; }
            ++out.snapped;
            h.pts.push_back(J->p);
            h.ok = true;
            return h;
          }
          h.pts.push_back(q);
          if (vdist(q, land_at) > 1e-9) h.pts.push_back(land_at);
          h.ok = true;
          return h;
        }
        parallel = beside ? parallel + step : 0.0;
        if (parallel > spacing) { ++out.half_beside; return h; }
        h.pts.push_back(q);
        p = q;
        head = d;
      }
      ++out.half_long;
      return h;
    };
    const Half h1 = walk(-1.0), h2 = walk(1.0);
    if (!h1.ok || !h2.ok) continue;
    out.points.assign(h1.pts.rbegin(), h1.pts.rend());
    out.points.insert(out.points.end(), h2.pts.begin() + 1, h2.pts.end());
    out.solid_a = h1.solid;
    out.solid_b = h2.solid;
    out.laid = true;
    out.op.kind = 3;
    out.op.v = {static_cast<double>(host.region), w, spacing, h1.solid ? 1.0 : 0.0, h2.solid ? 1.0 : 0.0,
                static_cast<double>(out.points.size())};
    for (const Vec3& q : out.points) { out.op.v.push_back(q.x); out.op.v.push_back(q.y); out.op.v.push_back(q.z); }
    return out;
  }
  return out;
}

}  // namespace topopt::lattice_layout
