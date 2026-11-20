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
    // OS18 withdrawn (the owner, 2026-11-19: "Yes, remove it."): a new vine (kind 3) is no longer laid. The additions
    // file still reads it; applying it is refused, in a plain sentence.
    if (op.kind == 3)
      return no("it holds new vines, which strengthening no longer lays (removed 2026-11-19); strengthen the lattice again");
    if (op.kind != 1 && op.kind != 2)
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
    if (!pts.empty() && c.per_region.empty()) {
      WeaveBraceAsk ask;
      ask.light_mm = c.light_mm;
      ask.layer_mm = c.layer_mm;
      ask.link_width = c.link_width;
      rep.brace_points = pts.size();
      rep.braces = lay_braces(bars, domain, pts, ask, nullptr, &rep.braces_at);
    } else if (!pts.empty()) {   // OJ4: the points of each region with its group's widths, region by region
      rep.brace_points = pts.size();
      rep.braces_at.assign(pts.size(), 0);
      std::map<int, std::vector<std::size_t>> by_region;
      for (std::size_t q = 0; q < pts.size(); ++q) by_region[bars.bars[pts[q].bar].region].push_back(q);
      // The bars of later regions' points move when earlier braces cut bars: their points are found again by their
      // bar's two ends (as the ops name them), region by region.
      std::vector<std::pair<Ends, std::pair<double, double>>> named;
      for (const BracePoint& p : pts) {
        const Bar& b = bars.bars[p.bar];
        named.push_back({ends_of(b.a, b.b), {p.u, p.width}});
      }
      for (const auto& [region, idx] : by_region) {
        const std::map<Ends, std::size_t> at2 = by_ends(bars);
        std::vector<BracePoint> mine;
        std::vector<std::size_t> back;
        for (std::size_t q : idx) {
          const auto it = at2.find(named[q].first);
          if (it == at2.end()) continue;
          BracePoint bp = pts[q];
          bp.bar = it->second;
          mine.push_back(bp);
          back.push_back(q);
        }
        const auto pr = c.per_region.find(region);
        WeaveBraceAsk ask;
        ask.light_mm = pr != c.per_region.end() ? pr->second[0] : c.light_mm;
        ask.layer_mm = pr != c.per_region.end() ? pr->second[1] : c.layer_mm;
        ask.link_width = pr != c.per_region.end() ? pr->second[2] : c.link_width;
        std::vector<int> laid_at;
        rep.braces += lay_braces(bars, domain, mine, ask, nullptr, &laid_at);
        for (std::size_t k = 0; k < back.size() && k < laid_at.size(); ++k) rep.braces_at[back[k]] = laid_at[k];
      }
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
        const auto pr = c.per_region.find(l.region);   // OJ4
        const double lm = pr != c.per_region.end() ? pr->second[0] : c.light_mm, lw = pr != c.per_region.end() ? pr->second[2] : c.link_width;
        const double w = std::max(lm, std::min(lw * thin, thick));
        if (w > l.width + 1e-12) {
          l.width = w;
          ++rep.links_widened;
        }
      }
    }
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
    if (c.line_mm > 0.0) guard_bars(bars, domain, c.weave_regions, c.line_mm, c.guard, true);   // OG5, cut free pieces dropped
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

}  // namespace topopt::lattice_layout
