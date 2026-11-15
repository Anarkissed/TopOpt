// Lattice rebuild, Organic, Grown (rules G1 to G13): the owner's Grown placement, written new in this engine, with
// the ORIGINAL Grown's own growing rules and numbers (brief G4; organic/map-grown-pruning.md section 1). See
// lattice_layout_organic.hpp and docs/design/lattice-rebuild/01-rules.md section 11. The original generator
// (core/src/mesh/organic_lattice.cpp, grow_organic_lattice) was read for its rules and numbers only; nothing of it is
// called. Nothing here decides an order by an unordered container, the clock or the thread count: the randomness is
// the ask's fixed seed number.
#include "topopt/lattice_layout_organic.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <map>
#include <set>
#include <array>
#include <stdexcept>
#include <tuple>
#include <utility>
#include <vector>

namespace topopt::lattice_layout {

void GrowReport::add(const GrowReport& o) {
  seeds_floor += o.seeds_floor; seeds_wall += o.seeds_wall; seeds_refused_support += o.seeds_refused_support;
  strands_grown += o.strands_grown; steps += o.steps; clamped += o.clamped;
  ended_edge += o.ended_edge; ended_unsupported += o.ended_unsupported; ended_joins += o.ended_joins;
  joins += o.joins; grew_on_after_join += o.grew_on_after_join; joins_refused_span += o.joins_refused_span;
  branches_offered += o.branches_offered; branches_grown += o.branches_grown; links += o.links;
  refused_region += o.refused_region; refused_support += o.refused_support; refused_crowded += o.refused_crowded;
  tips += o.tips; tip_budget_hit = std::max(tip_budget_hit, o.tip_budget_hit);
  bare_before = std::max(bare_before, o.bare_before); bare_after = std::max(bare_after, o.bare_after);
  reseed_voids += o.reseed_voids; reseed_landed += o.reseed_landed; reseed_failed += o.reseed_failed;
  reseed_mm += o.reseed_mm;
  ties_seeded += o.ties_seeded; ties_laid += o.ties_laid; ties_refused_minor += o.ties_refused_minor;
  ties_refused_reach += o.ties_refused_reach;
  feet_kept += o.feet_kept; feet_cut_at_joint += o.feet_cut_at_joint; vines_removed += o.vines_removed;
  feet_cut_mm += o.feet_cut_mm; feet_cut_high_mm += o.feet_cut_high_mm;
  feet_cut_high_strands += o.feet_cut_high_strands;
  joins_refused_outside += o.joins_refused_outside; links_refused_outside += o.links_refused_outside;
  grown_mm += o.grown_mm; kept_mm += o.kept_mm;
  cut_outside_mm += o.cut_outside_mm; cut_unsupported_mm += o.cut_unsupported_mm; cut_nothing_mm += o.cut_nothing_mm;
  cut_repeat_mm += o.cut_repeat_mm;
  strands += o.strands; ms += o.ms;
}

namespace {

constexpr double kPi = 3.14159265358979323846;
// The original Grown's numbers (organic_lattice.hpp and .cpp; map-grown-pruning.md section 1), kept as they were:
constexpr double kBlendHeading = 0.35, kBlendField = 0.65;   // G3: 0.35 x its own direction + 0.65 x the stress
constexpr double kUpwardBias = 0.25;                         // G3: the pull ("reach for the light")
constexpr double kConeDeg = 30.0;                            // G4: never flatter than this from level
constexpr double kSupportRadii = 1.25;                       // G4: material within 1.25 r under the underside
constexpr double kTestRatio = 0.5;                           // G5: crowded within 0.5 x the local spacing
constexpr double kRecordRadii = 6.0;                         // G5: a vertex recorded every 6 r of travel
constexpr double kJoinRunMm = 3.0;                           // G5, G6: a join or a link runs 3 mm or less
constexpr int kMaxJoins = 6;                                 // G5: a tip ends on its seventh join
constexpr double kBranchEveryRatio = 0.5;                    // G6: branches offered every 0.5 x spacing of climb
constexpr double kVoidRatio = 1.5;                           // G11: a bare place is 1.5 x the spacing from any vine
constexpr double kTieMinorRatio = 0.10;                      // G9: |sigma2| / |sigma1| at least this
constexpr double kTieReachRatio = 8.0;                       // G9: a tie reaches 8 spacings at most
constexpr double kTieSwirlDeg = 28.0, kTieSwirlWavelengthRatio = 3.5;   // G9: the swirl
// The limits the record shows were hit, raised (brief G4): tips, and the re-seeded stubs.
constexpr std::size_t kMaxTips = 200000;
constexpr std::size_t kReseedMax = 5000;
constexpr double kRepeatMm = 0.02;                           // G10: a repeat lies within 0.02 mm

Vec3 add(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 mul(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(const Vec3& a, const Vec3& b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
double len(const Vec3& a) { return std::sqrt(dot(a, a)); }
double dist(const Vec3& a, const Vec3& b) { return len(sub(a, b)); }
Vec3 unit(const Vec3& a) {
  const double l = len(a);
  return l > 1e-300 ? mul(a, 1.0 / l) : Vec3{0.0, 0.0, 0.0};
}
Vec3 closest_on(const Vec3& p, const Vec3& a, const Vec3& b) {
  const Vec3 d = sub(b, a);
  const double l2 = dot(d, d);
  const double t = l2 > 0.0 ? std::clamp(dot(sub(p, a), d) / l2, 0.0, 1.0) : 0.0;
  return add(a, mul(d, t));
}

// The principal stresses of a Voigt tensor [xx, yy, zz, xy, yz, zx] (true shear): cyclic Jacobi, values by size
// (largest |value| first, ties by column), each direction unit with its largest component positive (ties: lowest
// axis), so a direction is the same from voxel to voxel.
void principal(const double m[6], double ev[3], Vec3 vec[3]) {
  double a[3][3] = {{m[0], m[3], m[5]}, {m[3], m[1], m[4]}, {m[5], m[4], m[2]}};
  double v[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
  static const int pq[3][2] = {{0, 1}, {0, 2}, {1, 2}};
  for (int sweep = 0; sweep < 12; ++sweep)
    for (int t = 0; t < 3; ++t) {
      const int p = pq[t][0], q = pq[t][1];
      const double apq = a[p][q];
      if (std::fabs(apq) <= 1e-300) continue;
      const double theta = 0.5 * (a[q][q] - a[p][p]) / apq;
      const double tt = (theta >= 0.0 ? 1.0 : -1.0) / (std::fabs(theta) + std::sqrt(theta * theta + 1.0));
      const double c = 1.0 / std::sqrt(tt * tt + 1.0), s = tt * c;
      for (int k = 0; k < 3; ++k) {
        const double akp = a[k][p], akq = a[k][q];
        a[k][p] = c * akp - s * akq;
        a[k][q] = s * akp + c * akq;
      }
      for (int k = 0; k < 3; ++k) {
        const double apk = a[p][k], aqk = a[q][k];
        a[p][k] = c * apk - s * aqk;
        a[q][k] = s * apk + c * aqk;
      }
      for (int k = 0; k < 3; ++k) {
        const double vkp = v[k][p], vkq = v[k][q];
        v[k][p] = c * vkp - s * vkq;
        v[k][q] = s * vkp + c * vkq;
      }
    }
  int idx[3] = {0, 1, 2};
  const double lam[3] = {a[0][0], a[1][1], a[2][2]};
  std::stable_sort(idx, idx + 3, [&lam](int x, int y) { return std::fabs(lam[x]) > std::fabs(lam[y]); });
  for (int r = 0; r < 3; ++r) {
    const int c = idx[r];
    ev[r] = lam[c];
    Vec3 e = unit(Vec3{v[0][c], v[1][c], v[2][c]});
    const double comp[3] = {e.x, e.y, e.z};
    int big = 0;
    for (int k = 1; k < 3; ++k)
      if (std::fabs(comp[k]) > std::fabs(comp[big])) big = k;
    if (comp[big] < 0.0) e = mul(e, -1.0);
    vec[r] = e;
  }
}

// Points along every laid segment, in a grid of boxes: "what lies near here" without walking every strand.
struct Sample {
  int line = 0, seg = 0;
  std::uint64_t stamp = 0;
  Vec3 p{};
};
struct Boxes {
  Vec3 lo{};
  double cell = 2.0;
  int n[3] = {1, 1, 1};
  std::vector<std::vector<Sample>> box;
  void init(const Vec3& l, const Vec3& h, double c) {
    lo = l;
    cell = c;
    n[0] = std::max(1, static_cast<int>(std::ceil((h.x - l.x) / c)) + 1);
    n[1] = std::max(1, static_cast<int>(std::ceil((h.y - l.y) / c)) + 1);
    n[2] = std::max(1, static_cast<int>(std::ceil((h.z - l.z) / c)) + 1);
    box.assign(static_cast<std::size_t>(n[0]) * n[1] * n[2], {});
  }
  int at(double x, double l, int a) const {
    return std::clamp(static_cast<int>(std::floor((x - l) / cell)), 0, n[a] - 1);
  }
  void put(const Sample& s) {
    box[(static_cast<std::size_t>(at(s.p.z, lo.z, 2)) * n[1] + at(s.p.y, lo.y, 1)) * n[0] + at(s.p.x, lo.x, 0)]
        .push_back(s);
  }
  template <class F>
  void near(const Vec3& q, double R, F&& f) const {
    const int i0 = at(q.x - R, lo.x, 0), i1 = at(q.x + R, lo.x, 0);
    const int j0 = at(q.y - R, lo.y, 1), j1 = at(q.y + R, lo.y, 1);
    const int k0 = at(q.z - R, lo.z, 2), k1 = at(q.z + R, lo.z, 2);
    for (int k = k0; k <= k1; ++k)
      for (int j = j0; j <= j1; ++j)
        for (int i = i0; i <= i1; ++i)
          for (const Sample& s : box[(static_cast<std::size_t>(k) * n[1] + j) * n[0] + i]) f(s);
  }
  void clear() {
    for (auto& b : box) b.clear();
  }
};

// One strand while it grows: its points, a stamp per segment (a segment cut back loses its stamp, so its samples in
// the boxes are no longer read), which points are RECORDED (the separation test's vertices, G5), the strand it grew
// from, its family, a tie or not.
struct Line {
  std::vector<Vec3> pts;
  std::vector<std::uint64_t> stamp;   // per segment
  std::vector<char> dead;             // per segment: dropped by the path's pruning (G11): no longer material
  std::vector<char> rec;              // per point: a recorded vertex (G5)
  int parent = -1;
  int family = 0;
  bool tie = false;
  // G13: the line it was grown as (its index then: repeats split a line, its pieces keep it); a branch (G6) of
  // `parent`; a floor seed's strand (`seed_no` its seed's order, `root0` its root, `floor_pt` where it leaves the floor).
  int origin = -1;
  bool branch = false;
  bool floor_seed = false;
  int seed_no = -1;
  Vec3 root0{}, floor_pt{};
};

struct Near {
  bool found = false;
  double d = std::numeric_limits<double>::infinity();
  Vec3 hit{};
  int line = -1;
};

struct Tip {
  enum Kind { Floor, Wall, Branch, Reseed };
  Kind kind = Floor;
  Vec3 root{}, dir{};
  Vec3 from{};   // where growth begins: the root, or (a seed run into the solid) the point on the region's edge
  int parent = -1, family = 0;
  int line = -1;   // a re-seeded tip grows on from the top of its stub (that line)
  int seed_no = -1;   // a floor seed: its order
};

// A fixed, stated randomness (G2): splitmix64 of the ask's seed and the place, never the clock, never the order.
std::uint64_t mix(std::uint64_t x) {
  x += 0x9E3779B97F4A7C15ULL;
  x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
  x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
  return x ^ (x >> 31);
}
double rnd(std::uint64_t seed, std::uint64_t what, long long a, long long b, int k) {
  std::uint64_t h = mix(seed);
  h = mix(h ^ what);
  h = mix(h ^ static_cast<std::uint64_t>(a));
  h = mix(h ^ static_cast<std::uint64_t>(b));
  h = mix(h ^ static_cast<std::uint64_t>(k));
  return static_cast<double>(h >> 11) * (1.0 / 9007199254740992.0);
}

class Grower {
 public:
  Grower(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask, GrowReport& rep)
      : domain_(domain), region_(region), field_(field), ask_(ask), rep_(rep), probe_(domain.probe()) {}

  std::vector<Strand> run();

 private:
  const Domain& domain_;
  int region_;
  const TensorField& field_;
  const OrganicAsk& ask_;
  GrowReport& rep_;
  Domain::Probe probe_;
  OrganicSpacing sp_;
  Vec3 up_{}, u_{}, v_{};
  double layer_ = 0.2, width_ = 0.9, r_ = 0.45, sep_hi_ = 8.0, median_ = 5.0, bed_ = 0.0, ds_ = 0.2;
  double cone_sin_ = 0.5, cone_cos_ = 0.0;
  double laid_mm_ = 0.0;
  std::uint64_t next_stamp_ = 1;
  Boxes boxes_;   // samples along every laid segment (support, pruning)
  Boxes rec_;     // the recorded vertices (the separation test, G5)
  std::vector<Line> lines_;
  std::vector<Vec3> light_;   // G3: per voxel, the nearest point of the region's boundary that is not its floor
  std::vector<char> lit_;
  std::size_t tips_ = 0;

  double h(const Vec3& p) const { return dot(p, up_); }
  Vec3 level(const Vec3& d) const { return sub(d, mul(up_, dot(d, up_))); }
  bool inreg(const Vec3& p) const {
    const Where w = probe_.where(p);
    return w.lattice() && w.id == region_;
  }
  bool solid(const Vec3& p) const {
    const Where w = probe_.where(p);
    return w.why != Why::Outside && !w.lattice();
  }
  bool voxel(const Vec3& p, int& i, int& j, int& k) const {
    i = static_cast<int>(std::floor((p.x - field_.origin.x) / field_.spacing));
    j = static_cast<int>(std::floor((p.y - field_.origin.y) / field_.spacing));
    k = static_cast<int>(std::floor((p.z - field_.origin.z) / field_.spacing));
    return i >= 0 && j >= 0 && k >= 0 && i < field_.nx && j < field_.ny && k < field_.nz;
  }
  Vec3 centre(int i, int j, int k) const {
    return {field_.origin.x + (i + 0.5) * field_.spacing, field_.origin.y + (j + 0.5) * field_.spacing,
            field_.origin.z + (k + 0.5) * field_.spacing};
  }
  // The local spacing (O12's, per voxel): the voxel's own; off the candidates, the first candidate neighbour's (in
  // axis order); else the widest.
  double sep(const Vec3& p) const {
    int i, j, k;
    if (!voxel(p, i, j, k)) return sep_hi_;
    const std::size_t e = field_.index(i, j, k);
    if (sp_.candidate[e]) return sp_.spacing_mm[e];
    for (int dk = -1; dk <= 1; ++dk)
      for (int dj = -1; dj <= 1; ++dj)
        for (int di = -1; di <= 1; ++di) {
          const int a = i + di, b = j + dj, c = k + dk;
          if (a < 0 || b < 0 || c < 0 || a >= field_.nx || b >= field_.ny || c >= field_.nz) continue;
          const std::size_t f = field_.index(a, b, c);
          if (sp_.candidate[f]) return sp_.spacing_mm[f];
        }
    return sep_hi_;
  }
  bool frame(const Vec3& p, double ev[3], Vec3 vec[3]) const {
    int i, j, k;
    if (!voxel(p, i, j, k)) return false;
    principal(&field_.voigt[6 * field_.index(i, j, k)], ev, vec);
    return std::fabs(ev[0]) > 0.0;
  }
  // G3: the major principal direction, turned to point up; false where there is no stress.
  bool stress_dir(const Vec3& p, Vec3& f) const {
    double ev[3];
    Vec3 vec[3];
    if (!frame(p, ev, vec)) return false;
    f = dot(vec[0], up_) < 0.0 ? mul(vec[0], -1.0) : vec[0];
    return true;
  }
  // G3, the pull (the owner's OR35): toward the nearest point of the region's boundary that is not its floor; up
  // where there is none (off the candidates, or on that point).
  Vec3 light(const Vec3& p) const {
    int i, j, k;
    if (!voxel(p, i, j, k)) return up_;
    const std::size_t e = field_.index(i, j, k);
    if (!lit_[e]) return up_;
    const Vec3 d = sub(light_[e], p);
    return len(d) > 1e-9 ? unit(d) : up_;
  }
  // 3 (brief G5): the line from a to b stays on the region's candidates (read every ds between its ends).
  bool on_candidates(const Vec3& a, const Vec3& b) const {
    const int n = std::max(1, static_cast<int>(std::ceil(dist(a, b) / ds_)));
    for (int t = 1; t < n; ++t) {
      int i, j, k;
      if (!voxel(add(a, mul(sub(b, a), static_cast<double>(t) / n)), i, j, k) || !sp_.candidate[field_.index(i, j, k)])
        return false;
    }
    return true;
  }
  // A uniformly random direction over the cap from the cone (30 degrees from level) up to the build direction.
  Vec3 cap(std::uint64_t what, long long a, long long b) const {
    const double z = cone_sin_ + (1.0 - cone_sin_) * rnd(ask_.seed, what, a, b, 0);
    const double az = 2.0 * kPi * rnd(ask_.seed, what, a, b, 1);
    const double s = std::sqrt(std::max(0.0, 1.0 - z * z));
    return add(mul(up_, z), add(mul(u_, s * std::cos(az)), mul(v_, s * std::sin(az))));
  }

  // A sample of a segment still on its line (not cut back).
  bool current(const Sample& s) const {
    const Line& L = lines_[static_cast<std::size_t>(s.line)];
    return static_cast<std::size_t>(s.seg) < L.stamp.size() && L.stamp[static_cast<std::size_t>(s.seg)] == s.stamp;
  }
  // ... and material: not dropped by the path's pruning.
  bool live(const Sample& s) const {
    return current(s) && !lines_[static_cast<std::size_t>(s.line)].dead[static_cast<std::size_t>(s.seg)];
  }
  // A recorded vertex still on its line (rec_: `seg` is the point's index).
  bool rec_current(const Sample& s) const {
    const Line& L = lines_[static_cast<std::size_t>(s.line)];
    const std::size_t k = static_cast<std::size_t>(s.seg);
    return k < L.pts.size() && L.rec[k] && L.pts[k].x == s.p.x && L.pts[k].y == s.p.y && L.pts[k].z == s.p.z;
  }
  void stamp_segment(int li, std::size_t seg) {
    Line& L = lines_[static_cast<std::size_t>(li)];
    const std::uint64_t st = next_stamp_++;
    if (L.stamp.size() <= seg) L.stamp.resize(seg + 1, 0);
    if (L.dead.size() <= seg) L.dead.resize(seg + 1, 0);
    L.stamp[seg] = st;
    const Vec3 a = L.pts[seg], b = L.pts[seg + 1];
    const int n = std::max(1, static_cast<int>(std::ceil(dist(a, b) / ds_)));
    for (int t = 0; t <= n; ++t)
      boxes_.put(Sample{li, static_cast<int>(seg), st, add(a, mul(sub(b, a), static_cast<double>(t) / n))});
  }
  // A new segment at the end of a line, to `b`; `record`: b is a recorded vertex.
  void lay(int li, const Vec3& b, bool record = false) {
    Line& L = lines_[static_cast<std::size_t>(li)];
    laid_mm_ += dist(L.pts.back(), b);
    L.pts.push_back(b);
    L.rec.push_back(record ? 1 : 0);
    stamp_segment(li, L.pts.size() - 2);
    if (record) rec_.put(Sample{li, static_cast<int>(L.pts.size() - 1), 0, b});
  }
  int new_line(const Vec3& root, int parent, int family, bool tie = false) {
    Line L;
    L.pts.push_back(root);
    L.rec.push_back(0);
    L.parent = parent;
    L.family = family;
    L.tie = tie;
    L.origin = static_cast<int>(lines_.size());
    lines_.push_back(std::move(L));
    return static_cast<int>(lines_.size()) - 1;
  }
  // Cut a line back to point `keep` (its segments after it are no longer material).
  double take_back(int li, std::size_t keep) {
    Line& L = lines_[static_cast<std::size_t>(li)];
    double mm = 0.0;
    for (std::size_t s = keep; s + 1 < L.pts.size(); ++s) mm += dist(L.pts[s], L.pts[s + 1]);
    L.pts.resize(keep + 1);
    L.rec.resize(keep + 1);
    L.stamp.resize(keep);
    L.dead.resize(keep);
    return mm;
  }
  void rebuild_boxes() {
    boxes_.clear();
    for (std::size_t li = 0; li < lines_.size(); ++li) {
      lines_[li].stamp.clear();
      lines_[li].dead.resize(lines_[li].pts.size() ? lines_[li].pts.size() - 1 : 0, 0);
      lines_[li].rec.resize(lines_[li].pts.size(), 0);
      for (std::size_t s = 0; s + 1 < lines_[li].pts.size(); ++s) stamp_segment(static_cast<int>(li), s);
    }
    rebuild_rec();
  }
  // The recorded vertices on what is still material (a vertex on a segment the path keeps).
  void rebuild_rec() {
    rec_.clear();
    for (std::size_t li = 0; li < lines_.size(); ++li) {
      const Line& L = lines_[li];
      for (std::size_t k = 0; k < L.pts.size(); ++k) {
        if (!L.rec[k]) continue;
        const bool on = (k > 0 && !L.dead[k - 1]) || (k + 1 < L.pts.size() && !L.dead[k]);
        if (on) rec_.put(Sample{static_cast<int>(li), static_cast<int>(k), 0, L.pts[k]});
      }
    }
  }

  // G5, the separation test (the original's, Jobard and Lefer's): the nearest recorded vertex of another strand
  // within 0.5 x the local spacing at q; not `self`, not `parent`, not one `spared` (a strand the tip has joined, until
  // it is past that distance from the join).
  Near too_close(const Vec3& q, int self, int parent, const std::vector<std::pair<int, Vec3>>* spared = nullptr) const {
    Near out;
    const double lim = kTestRatio * sep(q);
    rec_.near(q, lim, [&](const Sample& s) {
      if (s.line == self || s.line == parent || !rec_current(s)) return;
      if (spared)
        for (const auto& x : *spared)
          if (x.first == s.line) return;
      const double d = dist(q, s.p);
      if (d < lim && (d < out.d || (d == out.d && s.line < out.line))) {
        out.found = true;
        out.d = d;
        out.hit = s.p;
        out.line = s.line;
      }
    });
    return out;
  }
  // Any segment the path keeps within R of q.
  bool live_within(const Vec3& q, double R) const {
    bool found = false;
    boxes_.near(q, R + ds_, [&](const Sample& s) {
      if (found || !live(s)) return;
      const Line& L = lines_[static_cast<std::size_t>(s.line)];
      found = dist(q, closest_on(q, L.pts[static_cast<std::size_t>(s.seg)], L.pts[static_cast<std::size_t>(s.seg) + 1])) <= R;
    });
    return found;
  }

  // G4: is the underside of a strut centred at q held? Material (a strand, the part's solid, or the bed) within
  // r sideways and 1.25 r below the underside.
  bool supported(const Vec3& q) const {
    const double under = h(q) - r_, reach = kSupportRadii * r_;
    if (under - reach <= bed_ + 1e-9) return true;
    bool held = false;
    boxes_.near(q, 2.0 * r_ + reach + r_, [&](const Sample& s) {
      if (held || !live(s)) return;
      const double hs = h(s.p);
      if (hs - r_ > under + 1e-9 || hs + r_ < under - reach - 1e-9) return;
      if (len(level(sub(s.p, q))) <= 2.0 * r_ + 1e-9) held = true;
    });
    if (held) return true;
    const int K = std::max(1, static_cast<int>(std::ceil(reach / layer_ - 1e-9)));
    for (int k = 1; k <= K; ++k) {
      const Vec3 c = sub(q, mul(up_, r_ + std::min(reach, k * layer_)));
      if (solid(c)) return true;
      for (int a = 0; a < 8; ++a) {
        const double t = a * kPi / 4.0;
        if (solid(add(c, add(mul(u_, r_ * std::cos(t)), mul(v_, r_ * std::sin(t)))))) return true;
      }
    }
    return false;
  }
  // From `in` (in the region) along `d`: the distance to the region's edge, read every twentieth of a millimetre up
  // to `most`, then to a millionth; negative when there is none that near.
  double edge(const Vec3& in, const Vec3& d, double most) const {
    constexpr double kRead = 0.05;
    const int steps = static_cast<int>(std::floor(most / kRead + 1e-9));
    for (int k = 1; k <= steps; ++k) {
      const double s = k * kRead;
      if (inreg(add(in, mul(d, s)))) continue;
      double a = s - kRead, b = s;
      while (b - a > 1e-6) {
        const double m = 0.5 * (a + b);
        if (inreg(add(in, mul(d, m)))) a = m; else b = m;
      }
      return a;
    }
    return -1.0;
  }
  // As O4 ends a Traced strand: at the edge, and on by the strut's width where the part's solid lies past it, so
  // weave_bars finds the end Solid with its run-in made.
  Vec3 end_at_edge(const Vec3& in, const Vec3& d, double at) const {
    const bool past_solid = solid(add(in, mul(d, at + 3.0 * 0.02)));
    return add(in, mul(d, past_solid ? at + width_ : at));
  }

  void lighting();
  void seeds(std::vector<Tip>& tips);
  void grow(std::vector<Tip> tips);
  void grow_tip(const Tip& t, std::vector<Tip>& tips);
  void offer_branches(int li, const Vec3& p, const Vec3& dir, std::vector<Tip>& tips);
  void repeats();
  void feet(const std::vector<int>& parent, const std::vector<char>& branch, const std::vector<char>& seeded);
  void settle();
  struct Fate {
    std::vector<std::vector<char>> seg;   // per line, per segment: 0 kept, 1 outside, 2 nothing, 3 unsupported
    std::vector<double> bar_mm;           // per line: the length of its bars the path keeps (G12, ruling 5)
  };
  Fate pass();
  void prune();
  double bare() const;
  void account(const Fate& f);
  void reseed(std::vector<Tip>& tips);
  void ties(std::size_t from);
  std::vector<Strand> strands() const;
};

// G3, the pull's target: for every candidate voxel the nearest point of the region's boundary that is not its floor
// (the middle of a candidate's face whose neighbour across it is not a candidate, unless that face looks down along
// the build direction). Spread from those faces to their neighbours (26) in index order, each voxel keeping the
// nearest point any neighbour offers: the same answer every time.
void Grower::lighting() {
  const std::size_t n = static_cast<std::size_t>(field_.nx) * field_.ny * field_.nz;
  light_.assign(n, Vec3{});
  lit_.assign(n, 0);
  std::vector<double> best(n, std::numeric_limits<double>::infinity());
  std::vector<std::size_t> queue;
  static const int nb[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
  const double hv = field_.spacing;
  for (int k = 0; k < field_.nz; ++k)
    for (int j = 0; j < field_.ny; ++j)
      for (int i = 0; i < field_.nx; ++i) {
        const std::size_t e = field_.index(i, j, k);
        if (!sp_.candidate[e]) continue;
        const Vec3 c = centre(i, j, k);
        for (int f = 0; f < 6; ++f) {
          const int a = i + nb[f][0], b = j + nb[f][1], cc = k + nb[f][2];
          if (a >= 0 && b >= 0 && cc >= 0 && a < field_.nx && b < field_.ny && cc < field_.nz &&
              sp_.candidate[field_.index(a, b, cc)])
            continue;
          const Vec3 o{static_cast<double>(nb[f][0]), static_cast<double>(nb[f][1]), static_cast<double>(nb[f][2])};
          if (dot(o, up_) < -0.5) continue;   // the floor
          const Vec3 site = add(c, mul(o, 0.5 * hv));
          const double d = dist(site, c);
          if (d < best[e]) { best[e] = d; light_[e] = site; }
        }
        if (best[e] < std::numeric_limits<double>::infinity()) {
          lit_[e] = 1;
          queue.push_back(e);
        }
      }
  for (std::size_t q = 0; q < queue.size(); ++q) {
    const std::size_t e = queue[q];
    const int i = static_cast<int>(e % static_cast<std::size_t>(field_.nx));
    const int j = static_cast<int>((e / static_cast<std::size_t>(field_.nx)) % static_cast<std::size_t>(field_.ny));
    const int k = static_cast<int>(e / (static_cast<std::size_t>(field_.nx) * field_.ny));
    for (int dk = -1; dk <= 1; ++dk)
      for (int dj = -1; dj <= 1; ++dj)
        for (int di = -1; di <= 1; ++di) {
          const int a = i + di, b = j + dj, c = k + dk;
          if ((!di && !dj && !dk) || a < 0 || b < 0 || c < 0 || a >= field_.nx || b >= field_.ny || c >= field_.nz) continue;
          const std::size_t f = field_.index(a, b, c);
          if (!sp_.candidate[f]) continue;
          const double d = dist(light_[e], centre(a, b, c));
          if (d < best[f] - 1e-12) {
            best[f] = d;
            light_[f] = light_[e];
            lit_[f] = 1;
            queue.push_back(f);
          }
        }
  }
}

void Grower::seeds(std::vector<Tip>& tips) {
  const double hv = field_.spacing;
  // G2: the lowest candidate of each column, a column measured along the build direction.
  std::map<std::pair<long long, long long>, std::pair<double, Vec3>> low;
  for (int k = 0; k < field_.nz; ++k)
    for (int j = 0; j < field_.ny; ++j)
      for (int i = 0; i < field_.nx; ++i) {
        if (!sp_.candidate[field_.index(i, j, k)]) continue;
        const Vec3 c = centre(i, j, k);
        const std::pair<long long, long long> key{static_cast<long long>(std::floor(dot(c, u_) / hv)),
                                                  static_cast<long long>(std::floor(dot(c, v_) / hv))};
        auto it = low.find(key);
        if (it == low.end() || h(c) < it->second.first) low[key] = {h(c), c};
      }
  if (low.empty()) return;
  // G2 (brief G4; the owner, 2026-11-15: "I think we need to have LOADS of seeds, vines, and directions, then pruning
  // and a round of re-seeding in bare areas."): one seed per stride cell of the build plane (seed_stride x the median
  // spacing each way), placed at random inside its cell, seeded where its column has candidates: at the height of the
  // column's lowest, moved down to the region's edge. Its first heading is at random inside the cone.
  double ua = std::numeric_limits<double>::infinity(), ub = -ua, va = ua, vb = -ua;
  for (const auto& kv : low) {
    const Vec3 c = kv.second.second;
    ua = std::min(ua, dot(c, u_) - 0.5 * hv); ub = std::max(ub, dot(c, u_) + 0.5 * hv);
    va = std::min(va, dot(c, v_) - 0.5 * hv); vb = std::max(vb, dot(c, v_) + 0.5 * hv);
  }
  const double stride = ask_.seed_stride * median_;
  const long long na = static_cast<long long>(std::ceil((ub - ua) / stride - 1e-9));
  const long long nb = static_cast<long long>(std::ceil((vb - va) / stride - 1e-9));
  for (long long b = 0; b < nb; ++b)
    for (long long a = 0; a < na; ++a) {
      const double uu = ua + (a + rnd(ask_.seed, 1, a, b, 0)) * stride;
      const double vv = va + (b + rnd(ask_.seed, 1, a, b, 1)) * stride;
      auto it = low.find({static_cast<long long>(std::floor(uu / hv)), static_cast<long long>(std::floor(vv / hv))});
      if (it == low.end()) continue;
      const Vec3 cc = it->second.second;
      Vec3 c = add(cc, add(mul(u_, uu - dot(cc, u_)), mul(v_, vv - dot(cc, v_))));
      if (!inreg(c)) c = cc;
      const Vec3 down = mul(up_, -1.0);
      const double at = edge(c, down, 2.0 * hv);
      const Vec3 on = at >= 0.0 ? add(c, mul(down, at)) : c;
      Tip t;
      t.kind = Tip::Floor;
      t.dir = cap(2, a, b);
      // Its foot leaves the floor on that heading; its root runs back along it into the solid by its width (S4).
      t.root = at < 0.0 ? c : solid(sub(on, mul(t.dir, width_ + 0.06))) ? sub(on, mul(t.dir, width_)) : on;
      t.from = on;
      t.seed_no = static_cast<int>(rep_.seeds_floor);
      tips.push_back(t);
      ++rep_.seeds_floor;
    }
  if (!ask_.walls_out) return;
  // G2 (idea C): on the region's walls: a candidate whose neighbour across a side face (one that is not above or
  // below it) is the part's solid; one per stride cell (seed_stride x the median spacing, in the part's frame), the
  // wall candidate of the cell nearest a point placed at random in it.
  struct W { long long hk, a, b; int n; Vec3 c, w; };
  std::map<std::tuple<long long, long long, long long>, std::vector<W>> cells;
  static const int nb6[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
  for (int k = 0; k < field_.nz; ++k)
    for (int j = 0; j < field_.ny; ++j)
      for (int i = 0; i < field_.nx; ++i) {
        if (!sp_.candidate[field_.index(i, j, k)]) continue;
        const Vec3 c = centre(i, j, k);
        for (int n = 0; n < 6; ++n) {
          const Vec3 off{static_cast<double>(nb6[n][0]), static_cast<double>(nb6[n][1]), static_cast<double>(nb6[n][2])};
          if (std::fabs(dot(off, up_)) >= 0.5) continue;
          const int a = i + nb6[n][0], b = j + nb6[n][1], cc = k + nb6[n][2];
          if (a >= 0 && b >= 0 && cc >= 0 && a < field_.nx && b < field_.ny && cc < field_.nz &&
              sp_.candidate[field_.index(a, b, cc)])
            continue;
          if (!solid(add(c, mul(off, hv)))) continue;
          const auto key = std::make_tuple(static_cast<long long>(std::floor(h(c) / stride)),
                                           static_cast<long long>(std::floor(dot(c, u_) / stride)),
                                           static_cast<long long>(std::floor(dot(c, v_) / stride)));
          cells[key].push_back({std::llround(h(c) / hv), std::llround(dot(c, u_) / hv), std::llround(dot(c, v_) / hv), n,
                                c, unit(level(off))});
          break;
        }
      }
  for (const auto& kv : cells) {
    const long long ck = std::get<0>(kv.first), ca = std::get<1>(kv.first), cb = std::get<2>(kv.first);
    const Vec3 pick = add(mul(up_, (ck + rnd(ask_.seed, 3, ca, cb, static_cast<int>(ck) * 3)) * stride),
                          add(mul(u_, (ca + rnd(ask_.seed, 3, ca, cb, static_cast<int>(ck) * 3 + 1)) * stride),
                              mul(v_, (cb + rnd(ask_.seed, 3, ca, cb, static_cast<int>(ck) * 3 + 2)) * stride)));
    const W* best = nullptr;
    double bd = std::numeric_limits<double>::infinity();
    for (const W& w : kv.second) {
      const Vec3 c3{dot(w.c, u_), dot(w.c, v_), h(w.c)};
      const Vec3 p3{dot(pick, u_), dot(pick, v_), h(pick)};
      const double d = dist(c3, p3);
      if (d < bd) { bd = d; best = &w; }
    }
    if (!best) continue;
    const W& w = *best;
    const double at = edge(w.c, w.w, 2.0 * hv);
    if (at < 0.0) continue;
    const Vec3 on = add(w.c, mul(w.w, at));
    // No wall seed within one stride of a corner, where its wall meets another wall (LatticeReview's ruling).
    bool corner = false;
    const Vec3 along = unit(cross(up_, w.w));
    for (int sg = -1; sg <= 1 && !corner; sg += 2) {
      const Vec3 dir = mul(along, sg);
      const double e = edge(w.c, dir, stride);
      corner = e >= 0.0 && solid(add(w.c, mul(dir, e + 0.06)));
    }
    if (corner) continue;
    Tip t;
    t.kind = Tip::Wall;
    t.root = end_at_edge(w.c, w.w, at);
    t.dir = add(mul(w.w, -cone_cos_), mul(up_, cone_sin_));   // inward, at the cone
    t.from = on;
    tips.push_back(t);
    ++rep_.seeds_wall;
  }
}

// G6, the original's branches: across the heading, along whichever of the two minor principal directions is least
// along it, flattened out of the heading (a side axis where there is no stress), TWO branches, one to each side,
// leaving at the cone. Refused: out of the region, unsupported, or crowded (then a link to what crowded it when the
// run is 3 mm or less).
void Grower::offer_branches(int li, const Vec3& p, const Vec3& dir, std::vector<Tip>& tips) {
  double ev[3];
  Vec3 fr[3];
  Vec3 tr{0, 0, 0};
  if (frame(p, ev, fr)) {
    tr = std::fabs(dot(fr[1], dir)) <= std::fabs(dot(fr[2], dir)) ? fr[1] : fr[2];
    tr = sub(tr, mul(dir, dot(tr, dir)));
  }
  if (len(tr) <= 1e-9) tr = cross(dir, std::fabs(dot(dir, u_)) < std::fabs(dot(dir, v_)) ? u_ : v_);
  const Vec3 side = unit(level(tr));
  if (len(side) < 0.5) return;
  const Line& me = lines_[static_cast<std::size_t>(li)];
  const int family = (me.family + 1) % 3;
  for (int sgn = -1; sgn <= 1; sgn += 2) {
    const Vec3 bdir = add(mul(side, sgn * cone_cos_), mul(up_, cone_sin_));
    const Vec3 bq = add(p, mul(bdir, layer_));
    ++rep_.branches_offered;
    if (!inreg(bq)) { ++rep_.refused_region; continue; }
    if (!supported(bq)) { ++rep_.refused_support; continue; }
    const Near n = too_close(bq, li, -1);
    if (n.found) {
      ++rep_.refused_crowded;
      if (len(level(sub(n.hit, p))) <= kJoinRunMm && dist(n.hit, p) > 1e-9) {
        if (!on_candidates(p, n.hit)) {   // 3 (brief G5): a link that would leave the region is not made
          ++rep_.links_refused_outside;
          continue;
        }
        const int l = new_line(p, li, family);
        lay(l, n.hit);
        ++rep_.links;
      }
      continue;
    }
    if (tips_ >= kMaxTips) { rep_.tip_budget_hit = 1; continue; }
    Tip t;
    t.kind = Tip::Branch;
    t.root = t.from = p;
    t.dir = bdir;
    t.parent = li;
    t.family = family;
    tips.push_back(t);
    ++tips_;
  }
}

// G3 to G5, the original's tip loop, step by step.
void Grower::grow_tip(const Tip& t, std::vector<Tip>& tips) {
  const int li = t.line >= 0 ? t.line : new_line(t.root, t.parent, t.family);
  if (t.line < 0) {
    Line& L = lines_[static_cast<std::size_t>(li)];
    L.branch = t.kind == Tip::Branch;
    if (t.kind == Tip::Floor) {
      L.floor_seed = true;
      L.seed_no = t.seed_no;
      L.root0 = t.root;
      L.floor_pt = t.from;
    }
  }
  const int parent = t.parent;
  const Vec3 start = t.from;
  Vec3 p = start, dir = t.dir;
  double since_branch = 0.0, since_record = 0.0;
  // A floor seed's foot (S4): it climbs its first two widths straight on its first heading, so its first bar,
  // run into the solid by its width, crosses the region's edge in one line and is not a stub.
  double foot = t.kind == Tip::Floor ? 2.0 * width_ : 0.0;
  int joins_used = 0;
  std::vector<std::pair<int, Vec3>> spared;
  bool after_join = false, first = true;
  const int layers = static_cast<int>(std::ceil((domain_.measure().diagonal_mm() + 1.0) / layer_)) + 4;
  const long long guard = 16LL * layers;
  enum End { Edge, Unsupported, Joins, Guard } how = Guard;
  for (long long it = 0; it < guard; ++it) {
    Vec3 want;
    if (foot > 0.0) {
      want = dir;
    } else {
      Vec3 f;
      want = stress_dir(p, f) ? add(mul(dir, kBlendHeading), mul(f, kBlendField)) : dir;
      want = add(want, mul(light(p), kUpwardBias));   // the pull, toward the nearest face (OR35)   // the pull, toward the nearest face (OR35)
      if (!(len(want) > 1e-12)) { how = Unsupported; break; }
      want = unit(want);
      if (dot(want, up_) < cone_sin_) {
        ++rep_.clamped;
        const Vec3 side = unit(level(want));
        want = len(side) > 0.5 ? add(mul(side, cone_cos_), mul(up_, cone_sin_)) : up_;
      }
    }
    const Vec3 q = add(p, mul(want, layer_));
    if (!inreg(q)) {
      // G3: it leaves the region: it ends at the edge (on into the solid by its width where solid is past it).
      const double at = edge(p, want, layer_ + 0.05);
      const Vec3 e = end_at_edge(p, want, at >= 0.0 ? at : 0.0);
      if (dist(e, p) > 1e-9) lay(li, e);
      how = Edge;
      break;
    }
    if (!supported(q)) {
      if (first && (t.kind == Tip::Floor || t.kind == Tip::Wall)) {
        ++rep_.seeds_refused_support;
        laid_mm_ -= take_back(li, 0);   // nothing of a seed that cannot take its first step is laid
      }
      how = Unsupported;
      break;
    }
    if (foot <= 0.0) {
      const Near n = too_close(q, li, parent, &spared);
      if (n.found) {
        if (len(level(sub(n.hit, p))) > kJoinRunMm) {
          ++rep_.joins_refused_span;   // a longer run is no join: it climbs on as if uncrowded
        } else if (!on_candidates(p, n.hit)) {
          ++rep_.joins_refused_outside;   // 3 (brief G5): a join that would leave the region: as if out of reach
        } else {
          // JOIN the neighbour, move onto it, and DEFLECT: re-aimed away from where it came from, at the cone.
          if (dist(n.hit, p) > 1e-9) lay(li, n.hit);
          ++rep_.joins;
          if (++joins_used > kMaxJoins) { how = Joins; break; }
          Vec3 away = level(sub(p, n.hit));
          if (len(away) < 1e-9) away = level(cross(up_, dir));
          if (len(away) < 1e-9) away = u_;
          away = unit(away);
          dir = add(mul(away, cone_cos_), mul(up_, cone_sin_));
          p = n.hit;
          // A strand it joined does not crowd it again until it is past the separation from that join: else it would
          // join the same vertex at once, or bounce between two neighbours, and end there (the original's tip did;
          // the intent is that it goes on).
          spared.push_back({n.line, n.hit});
          since_record = kRecordRadii * r_;   // the deflection's first point is recorded
          after_join = true;
          continue;
        }
      }
    }
    since_record += layer_;
    const bool record = since_record >= kRecordRadii * r_;
    if (record) since_record = 0.0;
    lay(li, q, record);
    first = false;
    ++rep_.steps;
    if (after_join) { ++rep_.grew_on_after_join; after_join = false; }
    spared.erase(std::remove_if(spared.begin(), spared.end(),
                                [&](const std::pair<int, Vec3>& x) { return dist(q, x.second) >= kTestRatio * sep(x.second); }),
                 spared.end());
    p = q;
    dir = want;
    if (foot > 0.0) { foot -= layer_; continue; }
    since_branch += layer_;
    if (since_branch >= std::max(layer_, kBranchEveryRatio * sep(p))) {
      since_branch = 0.0;
      offer_branches(li, p, dir, tips);
    }
  }
  {
    // A tip that grew less than its own width is a stub (S4): taken back (a re-seeded one keeps its stub).
    Line& L = lines_[static_cast<std::size_t>(li)];
    double mm = 0.0;
    for (std::size_t k = 0; k + 1 < L.pts.size(); ++k) mm += dist(L.pts[k], L.pts[k + 1]);
    if (t.line < 0 && L.pts.size() >= 2 && mm < width_) laid_mm_ -= take_back(li, 0);
  }
  if (how == Edge) ++rep_.ended_edge;
  else if (how == Unsupported) ++rep_.ended_unsupported;
  else if (how == Joins) ++rep_.ended_joins;
  if (lines_[static_cast<std::size_t>(li)].pts.size() >= 2) {
    ++rep_.strands_grown;
    if (t.kind == Tip::Branch) ++rep_.branches_grown;
  }
}

void Grower::grow(std::vector<Tip> tips) {
  // A worklist: each tip grows to its end, and the branches it offers are grown after the tips before them.
  for (std::size_t i = 0; i < tips.size(); ++i) {
    const Tip t = tips[i];
    grow_tip(t, tips);
  }
}

// No vine ends in mid-air (LatticeReview's ruling 2): a strand (not a tie) whose upper end is neither past the
// region's edge a hair on nor on another strand is cut back to its last joint (the farthest point of it that is a
// point of another strand, or where another strand's end lies on it); with none, it goes. Repeated until nothing is
// loose.
void Grower::settle() {
  auto edge_held = [&](const Vec3& e) {
    static const Vec3 off[6] = {{0.05, 0, 0}, {-0.05, 0, 0}, {0, 0.05, 0}, {0, -0.05, 0}, {0, 0, 0.05}, {0, 0, -0.05}};
    for (const Vec3& o : off)
      if (!inreg(add(e, o))) return true;
    return false;
  };
  auto key = [](const Vec3& p) {
    return std::array<long long, 3>{std::llround(p.x * 1e6), std::llround(p.y * 1e6), std::llround(p.z * 1e6)};
  };
  for (;;) {
    std::map<std::array<long long, 3>, std::vector<int>> at;
    for (std::size_t l = 0; l < lines_.size(); ++l) {
      if (lines_[l].pts.size() < 2) continue;
      for (const Vec3& p : lines_[l].pts) {
        std::vector<int>& v = at[key(p)];
        if (v.empty() || v.back() != static_cast<int>(l)) v.push_back(static_cast<int>(l));
      }
    }
    // the back end of line l: held, or cut back to its last joint (true)
    auto cut_back = [&](std::size_t l) -> bool {
      Line& L = lines_[l];
      const Vec3 e = L.pts.back();
      if (edge_held(e) || at[key(e)].size() > 1) return false;
      bool on_other = false;
      boxes_.near(e, ds_, [&](const Sample& s) {
        if (on_other || s.line == static_cast<int>(l) || !current(s)) return;
        const Line& O = lines_[static_cast<std::size_t>(s.line)];
        on_other = dist(e, closest_on(e, O.pts[static_cast<std::size_t>(s.seg)], O.pts[static_cast<std::size_t>(s.seg) + 1])) < 1e-6;
      });
      if (on_other) return false;
      // the farthest joint: a point shared with another strand, or another strand's end lying on a segment
      double best = -1.0;
      Vec3 best_at{};
      for (std::size_t k = 0; k + 1 < L.pts.size(); ++k)
        if (at[key(L.pts[k])].size() > 1) { best = static_cast<double>(k); best_at = L.pts[k]; }
      for (std::size_t k = 0; k + 1 < L.pts.size(); ++k) {
        const Vec3 a = L.pts[k], b = L.pts[k + 1];
        boxes_.near(mul(add(a, b), 0.5), 0.5 * dist(a, b) + ds_, [&](const Sample& s) {
          if (s.line == static_cast<int>(l) || !current(s)) return;
          const Line& O = lines_[static_cast<std::size_t>(s.line)];
          for (const Vec3& x : {O.pts.front(), O.pts.back()}) {
            const Vec3 c = closest_on(x, a, b);
            if (dist(c, x) >= 1e-6) continue;
            const double ab = dist(a, b);
            const double f = ab > 0.0 ? dist(a, c) / ab : 0.0;
            if (f < 1.0 - 1e-9 && static_cast<double>(k) + f > best) { best = static_cast<double>(k) + f; best_at = x; }
          }
        });
      }
      double gone = 0.0;
      if (best < 0.0) {
        gone = take_back(static_cast<int>(l), 0);
      } else {
        const std::size_t seg = static_cast<std::size_t>(std::floor(best + 1e-12));
        const bool on_vertex = dist(L.pts[seg], best_at) < 1e-9;
        gone = take_back(static_cast<int>(l), on_vertex ? seg : seg + 1);
        if (!on_vertex) {
          Line& M = lines_[l];
          gone += dist(M.pts[seg], M.pts[seg + 1]) - dist(M.pts[seg], best_at);
          M.pts.back() = best_at;
          M.rec.back() = 0;
          stamp_segment(static_cast<int>(l), seg);
        }
      }
      rep_.cut_nothing_mm += gone;   // laid, then cut: leads to nothing
      return true;
    };
    // a line turned end for end (its samples stamped again)
    auto flip = [&](std::size_t l) {
      Line& L = lines_[l];
      std::reverse(L.pts.begin(), L.pts.end());
      std::reverse(L.rec.begin(), L.rec.end());
      std::reverse(L.dead.begin(), L.dead.end());
      for (std::size_t k = 0; k + 1 < L.pts.size(); ++k) stamp_segment(static_cast<int>(l), k);
    };
    bool changed = false;
    for (std::size_t l = 0; l < lines_.size(); ++l) {
      if (lines_[l].tie || lines_[l].pts.size() < 2) continue;
      if (cut_back(l)) changed = true;
      if (lines_[l].pts.size() < 2) continue;
      // its lower end too (brief G4: "no strand may end in mid-air"): turned, cut the same way, turned back
      flip(l);
      if (cut_back(l)) changed = true;
      if (lines_[l].pts.size() >= 2) flip(l);
    }
    if (!changed) break;
  }
}

// G10, pruning, merging repeats: a segment lying within 0.02 mm of a strand already kept, along its whole length, is a repeat
// and is left out (the strand is split there). Strands are read in order; the first keeps it. Because the strands
// returned are straightened (each within 0.25 r of its line), "within 0.02 mm" is read here as within 0.02 mm and
// the two straightenings (0.5 r).
void Grower::repeats() {
  const double near_mm = kRepeatMm + 0.5 * r_;
  std::vector<Line> out;
  Boxes kept = boxes_;
  kept.clear();
  std::vector<Line> keep_lines;
  std::vector<std::array<char, 2>> split;   // per kept piece: its front, its back left by a dropped repeat
  auto dist_to = [&](const Vec3& q, std::size_t line) {
    double best = std::numeric_limits<double>::infinity();
    kept.near(q, near_mm + ds_, [&](const Sample& s) {
      if (static_cast<std::size_t>(s.line) != line) return;
      const Line& L = keep_lines[line];
      if (L.dead[static_cast<std::size_t>(s.seg)]) return;
      best = std::min(best, dist(q, closest_on(q, L.pts[static_cast<std::size_t>(s.seg)],
                                              L.pts[static_cast<std::size_t>(s.seg) + 1])));
    });
    return best;
  };
  // the ends that stand on or join into another strand now (ruling 3)
  std::vector<Vec3> joints;
  for (std::size_t l = 0; l < lines_.size(); ++l) {
    const Line& L = lines_[l];
    if (L.pts.size() < 2) continue;
    for (const Vec3& e : {L.pts.front(), L.pts.back()}) {
      bool on = false;
      boxes_.near(e, ds_ + 1e-6, [&](const Sample& x) {
        if (on || static_cast<std::size_t>(x.line) == l || !current(x)) return;
        const Line& O = lines_[static_cast<std::size_t>(x.line)];
        on = dist(e, closest_on(e, O.pts[static_cast<std::size_t>(x.seg)], O.pts[static_cast<std::size_t>(x.seg) + 1])) < 1e-6;
      });
      if (on) joints.push_back(e);
    }
  }
  for (const Line& L : lines_) {
    if (L.pts.size() < 2) continue;
    std::vector<char> dup(L.pts.size() - 1, 0);
    for (std::size_t s = 0; s + 1 < L.pts.size(); ++s) {
      if (L.dead[s]) continue;   // the path drops it anyway
      const Vec3 a = L.pts[s], b = L.pts[s + 1];
      std::vector<std::size_t> cand;
      kept.near(a, near_mm + ds_, [&](const Sample& x) {
        const std::size_t l = static_cast<std::size_t>(x.line);
        if (std::find(cand.begin(), cand.end(), l) == cand.end()) cand.push_back(l);
      });
      std::sort(cand.begin(), cand.end());
      for (std::size_t l : cand) {
        bool all = true;
        for (int k = 0; k <= 4 && all; ++k) all = dist_to(add(a, mul(sub(b, a), k / 4.0)), l) <= near_mm;
        if (all) { dup[s] = 1; break; }
      }
    }
    std::size_t s = 0;
    while (s < dup.size()) {
      const std::size_t s0 = s;
      if (dup[s]) { rep_.cut_repeat_mm += dist(L.pts[s], L.pts[s + 1]); ++s; continue; }
      Line run;
      run.parent = -1;
      run.family = L.family;
      run.tie = L.tie;
      run.origin = L.origin;
      run.branch = L.branch;
      if (s0 == 0 && L.floor_seed) {   // the piece that keeps the seed's root is still its foot
        run.floor_seed = true;
        run.seed_no = L.seed_no;
        run.root0 = L.root0;
        run.floor_pt = L.floor_pt;
      }
      run.pts.push_back(L.pts[s]);
      run.rec.push_back(L.rec[s]);
      while (s < dup.size() && !dup[s]) {
        run.dead.push_back(L.dead[s]);
        run.pts.push_back(L.pts[++s]);
        run.rec.push_back(L.rec[s]);
      }
      const std::size_t id = keep_lines.size();
      keep_lines.push_back(run);
      split.push_back({static_cast<char>(s0 > 0 && dup[s0 - 1]), static_cast<char>(s < dup.size() && dup[s])});
      for (std::size_t k = 0; k + 1 < run.pts.size(); ++k) {
        const Vec3 a = run.pts[k], b = run.pts[k + 1];
        const int n = std::max(1, static_cast<int>(std::ceil(dist(a, b) / ds_)));
        for (int t = 0; t <= n; ++t)
          kept.put(Sample{static_cast<int>(id), static_cast<int>(k), 0, add(a, mul(sub(b, a), double(t) / n))});
      }
    }
  }
  lines_ = std::move(keep_lines);
  rebuild_boxes();
  // LatticeReview's ruling 3: the kept copy takes over every join and root that pointed at a dropped copy: an end that
  // lay on another strand before and lies on none now is moved onto the nearest strand within the repeat distance.
  // Moved until each such end lies on another strand (an end moved onto a strand whose own end then moves is moved
  // again), at most 8 times.
  std::vector<std::pair<std::size_t, int>> need;
  for (std::size_t l = 0; l < lines_.size(); ++l) {
    Line& L = lines_[l];
    if (L.pts.size() < 2) continue;
    for (int end = 0; end < 2; ++end) {
      const Vec3& e = end ? L.pts.back() : L.pts.front();
      bool was = split[l][static_cast<std::size_t>(end)] != 0;   // the piece went on along the dropped copy
      for (const Vec3& j : joints) was = was || dist(j, e) < 1e-9;
      if (was) need.push_back({l, end});
    }
  }
  for (int round = 0; round < 8; ++round) {
    bool moved = false;
    for (const auto& ne : need) {
      Line& L = lines_[ne.first];
      if (L.pts.size() < 2) continue;
      Vec3& e = ne.second ? L.pts.back() : L.pts.front();
      Near on;
      boxes_.near(e, near_mm + ds_, [&](const Sample& x) {
        if (static_cast<std::size_t>(x.line) == ne.first || !current(x)) return;
        const Line& O = lines_[static_cast<std::size_t>(x.line)];
        const Vec3 c = closest_on(e, O.pts[static_cast<std::size_t>(x.seg)], O.pts[static_cast<std::size_t>(x.seg) + 1]);
        const double dd = dist(c, e);
        if (dd <= near_mm + 1e-6 && dd < on.d) { on.found = true; on.d = dd; on.hit = c; }
      });
      if (on.found && on.d > 1e-9) {
        const Vec3 nb = ne.second ? L.pts[L.pts.size() - 2] : L.pts[1];
        laid_mm_ += dist(nb, on.hit) - dist(nb, e);   // the end moved onto the kept copy (G12: grown = kept + cuts)
        e = on.hit;
        moved = true;
      }
    }
    if (!moved) break;
    rebuild_boxes();
  }
}

std::vector<Strand> Grower::strands() const {
  // Joints are kept exact: a point of one strand that lies on another (a join, a link, a branch's root, a regrown
  // tip's root, a tie's weld) is a vertex of both, and is kept by the straightening.
  const std::size_t nl = lines_.size();
  std::vector<std::vector<char>> must(nl);
  std::vector<std::vector<std::vector<std::pair<double, Vec3>>>> put(nl);
  for (std::size_t l = 0; l < nl; ++l) {
    must[l].assign(lines_[l].pts.size(), 0);
    put[l].resize(lines_[l].pts.size() > 0 ? lines_[l].pts.size() - 1 : 0);
  }
  for (std::size_t l = 0; l < nl; ++l) {
    const Line& A = lines_[l];
    if (A.pts.size() < 2) continue;
    must[l].front() = must[l].back() = 1;
    for (std::size_t i = 0; i < A.pts.size(); ++i) {
      const Vec3 v = A.pts[i];
      boxes_.near(v, 1e-6 + ds_, [&](const Sample& s) {
        if (static_cast<std::size_t>(s.line) == l || !current(s)) return;
        const Line& B = lines_[static_cast<std::size_t>(s.line)];
        const Vec3 a = B.pts[static_cast<std::size_t>(s.seg)], b = B.pts[static_cast<std::size_t>(s.seg) + 1];
        if (dist(v, closest_on(v, a, b)) >= 1e-6) return;
        must[l][i] = 1;
        const double ab = dist(a, b);
        const double t = ab > 0.0 ? dot(sub(v, a), sub(b, a)) / (ab * ab) : 0.0;
        put[static_cast<std::size_t>(s.line)][static_cast<std::size_t>(s.seg)].push_back({t, v});
      });
    }
  }
  std::vector<Strand> out;
  for (std::size_t l = 0; l < nl; ++l) {
    const Line& L = lines_[l];
    if (L.pts.size() < 2) continue;
    std::vector<Vec3> pts;
    std::vector<char> keep;
    for (std::size_t k = 0; k < L.pts.size(); ++k) {
      if (!pts.empty() && dist(pts.back(), L.pts[k]) < kRepeatMm) {   // points this close are one
        keep.back() = keep.back() || must[l][k];
      } else {
        pts.push_back(L.pts[k]);
        keep.push_back(must[l][k]);
      }
      if (k + 1 == L.pts.size()) break;
      std::vector<std::pair<double, Vec3>> in = put[l][k];
      std::sort(in.begin(), in.end(), [](const std::pair<double, Vec3>& x, const std::pair<double, Vec3>& y) {
        return std::tie(x.first, x.second.x, x.second.y, x.second.z) < std::tie(y.first, y.second.x, y.second.y, y.second.z);
      });
      for (const auto& e : in) {
        if (dist(pts.back(), e.second) < kRepeatMm) { keep.back() = 1; continue; }
        if (dist(L.pts[k + 1], e.second) < kRepeatMm) { must[l][k + 1] = 1; continue; }
        pts.push_back(e.second);
        keep.push_back(1);
      }
    }
    Strand s;
    s.region = region_;
    // Straightened as the old run straightened (P9, kept): between joints, the fewest points within 0.25 x the radius.
    std::size_t from = 0;
    s.points.push_back(pts[0]);
    for (std::size_t k = 1; k < pts.size(); ++k) {
      if (!keep[k] && k + 1 < pts.size()) continue;
      const std::vector<Vec3> run(pts.begin() + static_cast<long>(from), pts.begin() + static_cast<long>(k) + 1);
      const std::vector<std::size_t> kept = straighten_points(run, 0.25 * r_);
      for (std::size_t q = 1; q < kept.size(); ++q) s.points.push_back(run[kept[q]]);
      from = k;
    }
    s.width_mm.assign(s.points.size(), width_);
    s.tie = L.tie;
    double sm = 0.0;
    for (const Vec3& p : s.points) {
      const double v = sep(p);
      sm = sm > 0.0 ? std::min(sm, v) : v;
    }
    s.spacing_mm = sm;
    out.push_back(std::move(s));
  }
  return out;
}

// The path's own pruning, run on the weave alone, as Session::lay_weave runs it. Each segment's fate: kept when a bar
// of it is left; else where its last bar went (cut to the region: outside the model; dropped loose: leads to nothing;
// dropped as a piece not joined to the part: unsupported).
Grower::Fate Grower::pass() {
  const std::vector<Strand> ss = strands();
  Fate f;
  f.seg.resize(lines_.size());
  for (std::size_t l = 0; l < lines_.size(); ++l)
    if (lines_[l].pts.size() >= 2) f.seg[l].assign(lines_[l].pts.size() - 1, 1);
  if (ss.empty()) return f;
  // A segment is still there when its middle lies on a bar (within the straightening's tolerance).
  const double tol = 0.25 * r_ + 1e-6;
  auto mark = [&](const Bars& bars, char value, char only) {
    Boxes bb = boxes_;
    bb.clear();
    for (std::size_t i = 0; i < bars.bars.size(); ++i) {
      const Vec3 a = bars.bars[i].a, b = bars.bars[i].b;
      const int n = std::max(1, static_cast<int>(std::ceil(dist(a, b) / ds_)));
      for (int t = 0; t <= n; ++t) bb.put(Sample{static_cast<int>(i), 0, 0, add(a, mul(sub(b, a), double(t) / n))});
    }
    for (std::size_t l = 0; l < lines_.size(); ++l)
      for (std::size_t k = 0; k < f.seg[l].size(); ++k) {
        if (f.seg[l][k] != only) continue;
        const Vec3 m = mul(add(lines_[l].pts[k], lines_[l].pts[k + 1]), 0.5);
        bool on = false;
        bb.near(m, tol + ds_, [&](const Sample& x) {
          const Bar& b = bars.bars[static_cast<std::size_t>(x.line)];
          on = on || dist(m, closest_on(m, b.a, b.b)) <= tol;
        });
        if (on) f.seg[l][k] = value;
      }
  };
  Bars bars = weave_bars(domain_, ss, 1);
  mark(bars, 2, 1);   // reached the bars: not cut at the model's edge
  split_at_crossings(bars);
  join_loose_bars(bars, domain_, 1, nullptr);
  const std::vector<int> arrived{region_};   // G11: a vine that reached the part's surface has arrived
  drop_loose_bars(bars, &arrived);
  mark(bars, 3, 2);   // survived the loose drop
  drop_adrift_bars(bars, domain_, nullptr);
  mark(bars, 0, 3);   // survived the adrift drop: kept
  // G12 (LatticeReview's ruling 5): what is kept is counted by each kept bar's own strand, so a bar end a joint moved
  // off its strand's line is not counted as cut.
  std::vector<std::size_t> line_of;
  for (std::size_t l = 0; l < lines_.size(); ++l)
    if (lines_[l].pts.size() >= 2) line_of.push_back(l);
  f.bar_mm.assign(lines_.size(), 0.0);
  for (const Bar& b : bars.bars)
    if (b.strand >= 0 && static_cast<std::size_t>(b.strand) < line_of.size())
      f.bar_mm[line_of[static_cast<std::size_t>(b.strand)]] += dist(b.a, b.b);
  return f;
}

// G13 (brief G5; the owner, 2026-11-15: "We seeded so much assuming a bunch of vines would get pruned out completely.
// ... Are we not pruning the entirety of the plant?"): the feet compete. A foot is a floor seed's strand; its worth the
// length still laid of everything that hangs on it (its own, its branches', theirs, and so on; not strands that merely
// join it). In order of worth (greatest first; ties by seed order) a foot is kept when no kept foot stands within
// foot_gap x the local spacing of its floor point, measured on the floor; else it is removed: cut from the floor up to
// its first joint with a strand of another plant that is not removed (a strand that is itself a removed foot counts
// only above its own cut), or, with none, taken whole. What hung on a removed foot is left to the mid-air pass that
// follows. `parent`, `branch`, `seeded`: per line as grown (before the repeats split them).
void Grower::feet(const std::vector<int>& parent, const std::vector<char>& branch, const std::vector<char>& seeded) {
  const std::size_t no = parent.size();
  std::vector<std::vector<int>> kids(no);
  for (std::size_t o = 0; o < no; ++o)
    if (branch[o] && parent[o] >= 0 && static_cast<std::size_t>(parent[o]) < no)
      kids[static_cast<std::size_t>(parent[o])].push_back(static_cast<int>(o));
  std::vector<int> plant(no, -1);   // per grown line: the floor seed's line it hangs on (by branches), or -1
  for (std::size_t o = 0; o < no; ++o) {
    if (!seeded[o]) continue;
    std::vector<int> stack{static_cast<int>(o)};
    while (!stack.empty()) {
      const int x = stack.back();
      stack.pop_back();
      if (plant[static_cast<std::size_t>(x)] >= 0) continue;
      plant[static_cast<std::size_t>(x)] = static_cast<int>(o);
      for (int c : kids[static_cast<std::size_t>(x)]) stack.push_back(c);
    }
  }
  auto plant_of = [&](std::size_t l) {
    const int o = lines_[l].origin;
    return o >= 0 && static_cast<std::size_t>(o) < no ? plant[static_cast<std::size_t>(o)] : -1;
  };
  std::vector<double> worth(no, 0.0);
  for (std::size_t l = 0; l < lines_.size(); ++l) {
    const int pl = plant_of(l);
    if (pl < 0) continue;
    const Line& L = lines_[l];
    for (std::size_t k = 0; k + 1 < L.pts.size(); ++k) worth[static_cast<std::size_t>(pl)] += dist(L.pts[k], L.pts[k + 1]);
  }
  struct Foot { std::size_t line; int seed_no; double worth; };
  std::vector<Foot> all;
  for (std::size_t l = 0; l < lines_.size(); ++l) {
    const Line& L = lines_[l];
    if (!L.floor_seed || L.pts.size() < 2 || dist(L.pts.front(), L.root0) > 1e-9) continue;
    all.push_back({l, L.seed_no, worth[static_cast<std::size_t>(L.origin)]});
  }
  std::sort(all.begin(), all.end(), [](const Foot& a, const Foot& b) {
    return a.worth != b.worth ? a.worth > b.worth : a.seed_no < b.seed_no;
  });
  std::vector<std::size_t> removed;
  std::vector<Vec3> kept;   // the kept feet's floor points
  for (const Foot& f : all) {
    const Vec3 fp = lines_[f.line].floor_pt;
    const double lim = ask_.foot_gap * sep(fp);
    bool near = false;
    for (const Vec3& k : kept) near = near || len(level(sub(k, fp))) < lim;
    if (near) {
      removed.push_back(f.line);
    } else {
      kept.push_back(fp);
      ++rep_.feet_kept;
    }
  }
  if (removed.empty()) return;
  std::sort(removed.begin(), removed.end());
  std::map<std::size_t, std::size_t> slot;   // a removed foot's line -> its place in `removed`
  for (std::size_t i = 0; i < removed.size(); ++i) slot[removed[i]] = i;
  auto key = [](const Vec3& p) {
    return std::array<long long, 3>{std::llround(p.x * 1e6), std::llround(p.y * 1e6), std::llround(p.z * 1e6)};
  };
  std::map<std::array<long long, 3>, std::vector<int>> at;
  for (std::size_t l = 0; l < lines_.size(); ++l) {
    if (lines_[l].pts.size() < 2) continue;
    for (const Vec3& p : lines_[l].pts) {
      std::vector<int>& v = at[key(p)];
      if (v.empty() || v.back() != static_cast<int>(l)) v.push_back(static_cast<int>(l));
    }
  }
  // where along line g (its segment index + the fraction) the point x lies
  auto along = [&](std::size_t g, const Vec3& x) {
    const Line& G = lines_[g];
    double best = std::numeric_limits<double>::infinity(), pos = 0.0;
    for (std::size_t k = 0; k + 1 < G.pts.size(); ++k) {
      const Vec3 c = closest_on(x, G.pts[k], G.pts[k + 1]);
      const double d = dist(c, x), ab = dist(G.pts[k], G.pts[k + 1]);
      if (d < best - 1e-12) { best = d; pos = static_cast<double>(k) + (ab > 0.0 ? dist(G.pts[k], c) / ab : 0.0); }
    }
    return pos;
  };
  struct Joint { double pos; std::size_t g; Vec3 x; double posg; };
  // The joints of line f with the strands of other plants, above the height `above`, in order along f.
  auto joints_of = [&](std::size_t f, double above) {
    const Line& L = lines_[f];
    const int mine = plant_of(f);
    std::vector<Joint> J;
    auto take = [&](double pos, std::size_t g, const Vec3& x) {
      if (g == f || lines_[g].pts.size() < 2 || plant_of(g) == mine || h(x) <= above) return;
      J.push_back({pos, g, x, slot.count(g) ? along(g, x) : 0.0});
    };
    for (std::size_t k = 0; k < L.pts.size(); ++k) {
      for (int g : at[key(L.pts[k])]) take(static_cast<double>(k), static_cast<std::size_t>(g), L.pts[k]);
      boxes_.near(L.pts[k], ds_ + 1e-6, [&](const Sample& sm) {   // a point of it on another strand's segment
        if (static_cast<std::size_t>(sm.line) == f || !current(sm)) return;
        const Line& O = lines_[static_cast<std::size_t>(sm.line)];
        const Vec3 a = O.pts[static_cast<std::size_t>(sm.seg)], b = O.pts[static_cast<std::size_t>(sm.seg) + 1];
        if (dist(L.pts[k], closest_on(L.pts[k], a, b)) < 1e-6) take(static_cast<double>(k), static_cast<std::size_t>(sm.line), L.pts[k]);
      });
      if (k + 1 == L.pts.size()) break;
      const Vec3 a = L.pts[k], b = L.pts[k + 1];
      const double ab = dist(a, b);
      boxes_.near(mul(add(a, b), 0.5), 0.5 * ab + ds_, [&](const Sample& sm) {   // another strand's end on a segment
        if (static_cast<std::size_t>(sm.line) == f || !current(sm)) return;
        const Line& O = lines_[static_cast<std::size_t>(sm.line)];
        for (const Vec3& x : {O.pts.front(), O.pts.back()}) {
          const Vec3 c = closest_on(x, a, b);
          if (dist(c, x) >= 1e-6) continue;
          take(static_cast<double>(k) + (ab > 0.0 ? dist(a, c) / ab : 0.0), static_cast<std::size_t>(sm.line), x);
        }
      });
    }
    std::sort(J.begin(), J.end(), [](const Joint& a, const Joint& b) {
      return std::tie(a.pos, a.g) < std::tie(b.pos, b.g);
    });
    return J;
  };
  std::vector<std::vector<Joint>> joints(removed.size());
  for (std::size_t r = 0; r < removed.size(); ++r)
    joints[r] = joints_of(removed[r], h(lines_[removed[r]].floor_pt) + 1e-6);
  // The cuts, to a fixed point. Each removed foot starts cut at its first joint; a joint HOLDS while the strand there
  // stays: it is not gone, and, when it is a removed foot, the joint lies above that foot's cut. A foot whose joint
  // does not hold is cut at its next one that does; with none it goes whole, and so does each strand of its plant
  // (its branches, theirs, and so on) with no joint that holds with another plant's strand: everything that hangs only
  // on it. Cuts only move up and what is gone only grows, so this ends.
  const double whole = std::numeric_limits<double>::infinity();
  std::vector<double> cut(removed.size(), whole);
  std::vector<long> at_joint(removed.size(), -1);
  std::vector<char> gone(lines_.size(), 0);
  for (std::size_t r = 0; r < removed.size(); ++r) {
    if (joints[r].empty()) {
      gone[removed[r]] = 1;
    } else {
      at_joint[r] = 0;
      cut[r] = joints[r][0].pos;
    }
  }
  auto holds = [&](const Joint& x) {
    if (gone[x.g]) return false;
    const auto it = slot.find(x.g);
    return it == slot.end() || (cut[it->second] < whole && x.posg > cut[it->second] + 1e-9);
  };
  std::map<int, std::vector<std::size_t>> members;   // per plant, its strands
  for (std::size_t l = 0; l < lines_.size(); ++l)
    if (lines_[l].pts.size() >= 2 && plant_of(l) >= 0) members[plant_of(l)].push_back(l);
  std::map<std::size_t, std::vector<Joint>> member_joints;
  for (bool changed = true; changed;) {
    changed = false;
    for (std::size_t r = 0; r < removed.size(); ++r) {
      if (at_joint[r] < 0) continue;
      std::size_t j = static_cast<std::size_t>(at_joint[r]);
      while (j < joints[r].size() && !holds(joints[r][j])) ++j;
      if (j == static_cast<std::size_t>(at_joint[r])) continue;
      changed = true;
      if (j < joints[r].size()) {
        at_joint[r] = static_cast<long>(j);
        cut[r] = joints[r][j].pos;
      } else {
        at_joint[r] = -1;
        cut[r] = whole;
        gone[removed[r]] = 1;
      }
    }
    for (std::size_t r = 0; r < removed.size(); ++r) {
      if (at_joint[r] >= 0) continue;
      for (std::size_t l : members[plant_of(removed[r])]) {
        if (gone[l]) continue;
        auto it = member_joints.find(l);
        if (it == member_joints.end())
          it = member_joints.emplace(l, joints_of(l, -std::numeric_limits<double>::infinity())).first;
        bool held = false;
        for (const Joint& x : it->second) held = held || holds(x);
        if (!held) {
          gone[l] = 1;
          changed = true;
        }
      }
    }
  }
  // What the cuts take above half the region's height (counted for the lead, brief G5): the length of a segment above
  // the middle height of the region's candidates.
  double hlo = std::numeric_limits<double>::infinity(), hhi = -hlo;
  for (int k = 0; k < field_.nz; ++k)
    for (int j = 0; j < field_.ny; ++j)
      for (int i = 0; i < field_.nx; ++i)
        if (sp_.candidate[field_.index(i, j, k)]) {
          hlo = std::min(hlo, h(centre(i, j, k)));
          hhi = std::max(hhi, h(centre(i, j, k)));
        }
  const double hmid = 0.5 * (hlo + hhi);
  auto high = [&](const Vec3& a, const Vec3& b) {
    const double ha = h(a), hb = h(b), l = dist(a, b);
    if (ha >= hmid && hb >= hmid) return l;
    if (ha <= hmid && hb <= hmid) return 0.0;
    return l * (std::max(ha, hb) - hmid) / std::fabs(hb - ha);
  };
  auto count_high = [&](const Line& L, std::size_t upto) {
    double mm = 0.0;
    for (std::size_t k = 0; k < upto && k + 1 < L.pts.size(); ++k) mm += high(L.pts[k], L.pts[k + 1]);
    if (mm > 0.0) {
      rep_.feet_cut_high_mm += mm;
      ++rep_.feet_cut_high_strands;
    }
  };
  for (std::size_t l = 0; l < lines_.size(); ++l) {
    if (!gone[l] || slot.count(l)) continue;
    Line& L = lines_[l];
    double mm = 0.0;
    for (std::size_t k = 0; k + 1 < L.pts.size(); ++k) mm += dist(L.pts[k], L.pts[k + 1]);
    count_high(L, L.pts.size());
    L.pts.resize(1);
    L.rec.resize(1);
    L.stamp.clear();
    L.dead.clear();
    rep_.feet_cut_mm += mm;
    rep_.cut_nothing_mm += mm;
  }
  for (std::size_t r = 0; r < removed.size(); ++r) {
    Line& L = lines_[removed[r]];
    L.floor_seed = false;
    double mm = 0.0;
    if (at_joint[r] < 0) {
      for (std::size_t k = 0; k + 1 < L.pts.size(); ++k) mm += dist(L.pts[k], L.pts[k + 1]);
      count_high(L, L.pts.size());
      L.pts.resize(1);
      L.rec.resize(1);
      ++rep_.vines_removed;
    } else {
      const Joint& x = joints[r][static_cast<std::size_t>(at_joint[r])];
      const std::size_t k = static_cast<std::size_t>(std::floor(x.pos + 1e-12));
      for (std::size_t s = 0; s < k; ++s) mm += dist(L.pts[s], L.pts[s + 1]);
      count_high(L, k);
      if (dist(L.pts[k], x.x) < 1e-9) {
        L.pts.erase(L.pts.begin(), L.pts.begin() + static_cast<long>(k));
        L.rec.erase(L.rec.begin(), L.rec.begin() + static_cast<long>(k));
      } else {
        mm += dist(L.pts[k], x.x);
        L.pts.erase(L.pts.begin(), L.pts.begin() + static_cast<long>(k) + 1);
        L.rec.erase(L.rec.begin(), L.rec.begin() + static_cast<long>(k) + 1);
        L.pts.insert(L.pts.begin(), x.x);
        L.rec.insert(L.rec.begin(), 0);
      }
      ++rep_.feet_cut_at_joint;
    }
    L.stamp.clear();
    L.dead.assign(L.pts.size() > 0 ? L.pts.size() - 1 : 0, 0);
    rep_.feet_cut_mm += mm;
    rep_.cut_nothing_mm += mm;   // counted under "leads to nothing" (G12)
  }
  rebuild_boxes();
}

// G10: the pruning, in order: repeats merged (the kept copy takes over what depended on a dropped one), no strand
// ending in mid-air, the feet competing (G13) and the mid-air pass again, then the path's own answer per segment (outside the model, the joining, the loose and adrift
// drops): what it leaves out is no longer material.
void Grower::prune() {
  std::vector<int> parent(lines_.size());
  std::vector<char> branch(lines_.size()), seeded(lines_.size());
  for (std::size_t l = 0; l < lines_.size(); ++l) {
    parent[l] = lines_[l].parent;
    branch[l] = lines_[l].branch;
    seeded[l] = lines_[l].floor_seed;
  }
  repeats();
  settle();
  feet(parent, branch, seeded);   // G13
  settle();
  const Fate f = pass();
  for (std::size_t l = 0; l < lines_.size(); ++l)
    for (std::size_t k = 0; k < f.seg[l].size(); ++k) lines_[l].dead[k] = f.seg[l][k] != 0;
  rebuild_rec();
}

// G11: the share of the region's candidate voxels with no strand the path keeps within 1.5 x their spacing. The
// distance from each voxel's centre to the nearest point of a kept segment (read every ds along it) is spread from
// the voxels those points lie in to their neighbours (26), each keeping the nearest point offered, in index order.
double Grower::bare() const {
  const std::size_t n = static_cast<std::size_t>(field_.nx) * field_.ny * field_.nz;
  std::vector<double> best(n, std::numeric_limits<double>::infinity());
  std::vector<Vec3> site(n);
  std::vector<std::size_t> queue;
  std::vector<char> queued(n, 0);
  for (std::size_t l = 0; l < lines_.size(); ++l) {
    const Line& L = lines_[l];
    for (std::size_t k = 0; k + 1 < L.pts.size(); ++k) {
      if (L.dead[k]) continue;
      const Vec3 a = L.pts[k], b = L.pts[k + 1];
      const int m = std::max(1, static_cast<int>(std::ceil(dist(a, b) / ds_)));
      for (int t = 0; t <= m; ++t) {
        const Vec3 p = add(a, mul(sub(b, a), static_cast<double>(t) / m));
        int i, j, kk;
        if (!voxel(p, i, j, kk)) continue;
        const std::size_t e = field_.index(i, j, kk);
        const double d = dist(p, centre(i, j, kk));
        if (d < best[e]) { best[e] = d; site[e] = p; }
        if (!queued[e]) { queued[e] = 1; queue.push_back(e); }
      }
    }
  }
  for (std::size_t q = 0; q < queue.size(); ++q) {
    const std::size_t e = queue[q];
    queued[e] = 0;
    const int i = static_cast<int>(e % static_cast<std::size_t>(field_.nx));
    const int j = static_cast<int>((e / static_cast<std::size_t>(field_.nx)) % static_cast<std::size_t>(field_.ny));
    const int k = static_cast<int>(e / (static_cast<std::size_t>(field_.nx) * field_.ny));
    for (int dk = -1; dk <= 1; ++dk)
      for (int dj = -1; dj <= 1; ++dj)
        for (int di = -1; di <= 1; ++di) {
          const int a = i + di, b = j + dj, c = k + dk;
          if ((!di && !dj && !dk) || a < 0 || b < 0 || c < 0 || a >= field_.nx || b >= field_.ny || c >= field_.nz) continue;
          const std::size_t f = field_.index(a, b, c);
          const double d = dist(site[e], centre(a, b, c));
          if (d < best[f] - 1e-12) {
            best[f] = d;
            site[f] = site[e];
            if (!queued[f]) { queued[f] = 1; queue.push_back(f); }
          }
        }
  }
  std::size_t cand = 0, bare_n = 0;
  for (std::size_t e = 0; e < n; ++e) {
    if (!sp_.candidate[e]) continue;
    ++cand;
    bare_n += best[e] > kVoidRatio * sp_.spacing_mm[e];
  }
  return cand ? static_cast<double>(bare_n) / static_cast<double>(cand) : 0.0;
}

// G12 (LatticeReview's ruling 5): a strand's kept length is the length of its bars the path keeps (at most its own
// length: a bar runs on into the solid by its width); what is not kept is cut, shared among the reasons its segments
// give (leads to nothing when they give none). Grown = kept + the cuts.
void Grower::account(const Fate& f) {
  for (std::size_t l = 0; l < lines_.size(); ++l) {
    const Line& L = lines_[l];
    double total = 0.0, why[4] = {0.0, 0.0, 0.0, 0.0};
    for (std::size_t k = 0; k + 1 < L.pts.size(); ++k) {
      const double m = dist(L.pts[k], L.pts[k + 1]);
      total += m;
      why[std::min<int>(3, f.seg[l][k])] += m;
    }
    if (total <= 0.0) continue;
    const double kept = std::min(total, f.bar_mm.empty() ? why[0] : f.bar_mm[l]);
    const double cut = total - kept, by = why[1] + why[2] + why[3];
    rep_.kept_mm += kept;
    if (by > 0.0) {
      rep_.cut_outside_mm += cut * why[1] / by;
      rep_.cut_nothing_mm += cut * why[2] / by;
      rep_.cut_unsupported_mm += cut * why[3] / by;
    } else {
      rep_.cut_nothing_mm += cut;
    }
  }
}

// G11, the original's void re-seeding (1.5), run ONCE after the first pruning (the owner, 2026-11-15: "then pruning
// and a round of re-seeding in bare areas"). Bare places: candidate voxel centres on a stride of half the median
// spacing with no strand the path keeps within 1.5 x their spacing, no two within that distance (first come). From
// each, a stub walks DOWN the candidate grid (to the neighbour, of the 26, that descends most; then the one the
// stress leans toward; then the shortest hop; never twice through a voxel), at most the region's height and two
// spacings, until it is within the strut's radius and a voxel of the floor's solid (or the bed), or, after more than
// two radii, within max(2 r, 0.5 x spacing) of a kept strand. Landed, it is a strand from its landing up to the bare
// place, and a new tip starts there with a random first heading inside the cone, grown by every rule above.
void Grower::reseed(std::vector<Tip>& tips) {
  const double hv = field_.spacing;
  const int stride = std::max(1, static_cast<int>(0.5 * median_ / hv));
  double hlo = std::numeric_limits<double>::infinity(), hhi = -hlo;
  for (int k = 0; k < field_.nz; ++k)
    for (int j = 0; j < field_.ny; ++j)
      for (int i = 0; i < field_.nx; ++i)
        if (sp_.candidate[field_.index(i, j, k)]) {
          hlo = std::min(hlo, h(centre(i, j, k)));
          hhi = std::max(hhi, h(centre(i, j, k)));
        }
  std::vector<std::array<int, 3>> voids;
  std::vector<Vec3> at;
  for (int k = 0; k < field_.nz; k += stride)
    for (int j = 0; j < field_.ny; j += stride)
      for (int i = 0; i < field_.nx; i += stride) {
        const std::size_t e = field_.index(i, j, k);
        if (!sp_.candidate[e]) continue;
        const Vec3 q = centre(i, j, k);
        const double lim = kVoidRatio * sp_.spacing_mm[e];
        if (live_within(q, lim)) continue;
        bool near = false;
        for (const Vec3& o : at) near = near || dist(o, q) < lim;
        if (near) continue;
        voids.push_back({i, j, k});
        at.push_back(q);
      }
  rep_.reseed_voids += voids.size();
  const Vec3 down = mul(up_, -1.0);
  for (std::size_t vi = 0; vi < voids.size(); ++vi) {
    if (rep_.reseed_landed + rep_.reseed_failed >= kReseedMax) break;
    int ci = voids[vi][0], cj = voids[vi][1], ck = voids[vi][2];
    const Vec3 sp = centre(ci, cj, ck);
    const double reach = (hhi - hlo) + 2.0 * sep(sp);
    const double land_r = std::max(2.0 * r_, kTestRatio * sep(sp));
    std::vector<Vec3> path{sp};
    std::set<std::size_t> visited{field_.index(ci, cj, ck)};
    Vec3 q = sp;
    double travelled = 0.0;
    bool landed = false;
    const int max_walk = static_cast<int>(reach / hv) + 8;
    for (int w = 0; w < max_walk && !landed; ++w) {
      Vec3 f = down;
      if (stress_dir(q, f)) f = mul(f, -1.0);   // the stress, turned to point down
      int bi = -1, bj = -1, bk = -1;
      double best = std::numeric_limits<double>::infinity();
      for (int dk = -1; dk <= 1; ++dk)
        for (int dj = -1; dj <= 1; ++dj)
          for (int di = -1; di <= 1; ++di) {
            if (!di && !dj && !dk) continue;
            const int i2 = ci + di, j2 = cj + dj, k2 = ck + dk;
            if (i2 < 0 || j2 < 0 || k2 < 0 || i2 >= field_.nx || j2 >= field_.ny || k2 >= field_.nz) continue;
            const std::size_t e2 = field_.index(i2, j2, k2);
            if (!sp_.candidate[e2] || visited.count(e2)) continue;
            const Vec3 o{static_cast<double>(di), static_cast<double>(dj), static_cast<double>(dk)};
            const double score = dot(o, up_) * 10.0 - dot(o, f) + 0.1 * (std::abs(di) + std::abs(dj) + std::abs(dk));
            if (score < best) { best = score; bi = i2; bj = j2; bk = k2; }
          }
      if (bi < 0) break;   // boxed in
      ci = bi; cj = bj; ck = bk;
      visited.insert(field_.index(ci, cj, ck));
      const Vec3 nq = centre(ci, cj, ck);
      travelled += dist(nq, q);
      q = nq;
      if (dist(q, path.back()) >= kRecordRadii * r_) path.push_back(q);
      const Vec3 below = sub(q, mul(up_, r_ + hv));
      if (h(below) <= bed_ || solid(below)) {
        if (dist(path.back(), q) > 1e-6) path.push_back(q);
        const double e = edge(q, down, 2.0 * (r_ + hv));
        if (e >= 0.0) path.push_back(end_at_edge(q, down, e));   // on into the floor's solid by its width
        landed = true;
        break;
      }
      if (travelled > 2.0 * r_) {
        Near hit;
        boxes_.near(q, land_r + ds_, [&](const Sample& s) {
          if (!live(s)) return;
          const Line& L = lines_[static_cast<std::size_t>(s.line)];
          for (std::size_t end = 0; end < 2; ++end) {   // onto a point of it (a vertex: a joint both keep)
            const Vec3 x = L.pts[static_cast<std::size_t>(s.seg) + end];
            const double d = dist(x, q);
            if (d <= land_r && (d < hit.d || (d == hit.d && s.line < hit.line))) {
              hit.found = true;
              hit.d = d;
              hit.hit = x;
              hit.line = s.line;
            }
          }
        });
        if (hit.found) {
          if (dist(hit.hit, path.back()) > 1e-6) path.push_back(hit.hit);
          landed = true;
          break;
        }
      }
      if (travelled > reach) break;   // out of reach
    }
    if (!landed || path.size() < 2) { ++rep_.reseed_failed; continue; }
    const int li = new_line(path.back(), -1, 0);
    for (std::size_t k = path.size() - 1; k-- > 0;) {
      rep_.reseed_mm += dist(path[k + 1], path[k]);
      lay(li, path[k], true);
    }
    ++rep_.reseed_landed;
    Tip t;
    t.kind = Tip::Reseed;
    t.line = li;
    t.root = t.from = sp;
    t.dir = cap(4, static_cast<long long>(vi), 0);
    tips.push_back(t);
    ++tips_;
  }
}

// G9, the original's transfer ties (1.6). Along every pillar (family 0) grown from `from` on, once per local spacing
// of its length, not within half a spacing of another tie, where the minor stress is at least 0.10 of the major: both
// ways along the second principal direction (midpoint steps of one layer, the sign kept), turned by the swirl (28
// degrees x tie_swirl x a fixed product of sines, wavelength 3.5 spacings, about the axis across it and the major
// direction), up to 8 spacings, stopping where it leaves the region. On the way it welds onto a recorded vertex of
// another strand within max(2 r, 0.75 layer) (more than 2 r from its last weld, not the strand it last welded to);
// after a spacing, within half a spacing of another tie's point, it welds there and stops. With no weld it is no tie.
// Its free points are thinned to 8 r apart (welds kept). A tie is a strut like any other: the path's support and
// bridge rules judge it.
void Grower::ties(std::size_t from) {
  std::vector<Vec3> tie_pts;
  Boxes tie_box = rec_;
  tie_box.clear();
  for (const Line& L : lines_)
    if (L.tie)
      for (const Vec3& p : L.pts) tie_box.put(Sample{0, 0, 0, p});
  auto near_tie = [&](const Vec3& q, double lim, Vec3* hit) {
    bool found = false;
    double best = lim;
    tie_box.near(q, lim, [&](const Sample& s) {
      const double d = dist(q, s.p);
      if (d < best) { best = d; found = true; if (hit) *hit = s.p; }
    });
    return found;
  };
  auto minor = [&](const Vec3& p, Vec3& e2, double& ratio, Vec3& e1) {
    double ev[3];
    Vec3 fr[3];
    if (!frame(p, ev, fr)) return false;
    e2 = fr[1];
    e1 = fr[0];
    ratio = std::fabs(ev[1]) / std::fabs(ev[0]);
    return len(e2) > 1e-9;
  };
  const std::size_t pillars = lines_.size();
  for (std::size_t ci = from; ci < pillars; ++ci) {
    if (lines_[ci].family != 0 || lines_[ci].tie || lines_[ci].pts.size() < 2) continue;
    double since = 0.0;
    const std::vector<Vec3> pc = lines_[ci].pts;
    for (std::size_t pi = 1; pi < pc.size(); ++pi) {
      since += dist(pc[pi], pc[pi - 1]);
      const Vec3 p = pc[pi];
      if (lines_[ci].dead[pi - 1]) continue;   // not on what the path drops
      if (since < sep(p)) continue;
      since = 0.0;
      if (near_tie(p, kTestRatio * sep(p), nullptr)) continue;
      Vec3 e2, e1;
      double ratio = 0.0;
      if (!minor(p, e2, ratio, e1)) continue;
      if (ratio < kTieMinorRatio) { ++rep_.ties_refused_minor; continue; }
      for (int sgn = -1; sgn <= 1; sgn += 2) {
        ++rep_.ties_seeded;
        const double max_reach = kTieReachRatio * sep(p);
        Vec3 dir = mul(e2, sgn);
        Vec3 q = p;
        double travelled = 0.0;
        std::vector<Vec3> path{p};
        std::vector<char> must{1};
        int joins = 0, last_line = static_cast<int>(ci);
        Vec3 last_join = p;
        while (travelled < max_reach) {
          Vec3 ea, em, xa, xm;
          double ra, rm;
          if (!minor(q, ea, ra, xa)) break;
          if (dot(ea, dir) < 0.0) ea = mul(ea, -1.0);
          const Vec3 mid = add(q, mul(ea, 0.5 * layer_));
          if (!minor(mid, em, rm, xm)) break;
          if (dot(em, dir) < 0.0) em = mul(em, -1.0);
          dir = unit(em);
          if (ask_.tie_swirl > 0.0) {
            const double lam = kTieSwirlWavelengthRatio * sep(q);
            const double k1 = 2.0 * kPi / lam, k2 = k1 * 0.618, k3 = k1 * 1.414;
            const double phase = std::sin(k1 * q.x + 0.7) * std::cos(k2 * q.z + 1.9) +
                                 0.5 * std::sin(k3 * (q.x + q.z) + 0.3) * std::cos(k1 * q.y + 2.4);
            const double ang = ask_.tie_swirl * kTieSwirlDeg * kPi / 180.0 * std::clamp(phase, -1.0, 1.0);
            const Vec3 axis = unit(cross(dir, xa));
            if (len(axis) > 1e-9) {
              const double c = std::cos(ang), sn = std::sin(ang);
              dir = unit(add(add(mul(dir, c), mul(cross(axis, dir), sn)), mul(axis, dot(axis, dir) * (1.0 - c))));
            }
          }
          const Vec3 nq = add(q, mul(dir, layer_));
          if (!inreg(nq)) break;
          q = nq;
          travelled += layer_;
          path.push_back(q);
          must.push_back(0);
          if (dist(q, last_join) > 2.0 * r_) {
            Near w;
            const double wr = std::max(2.0 * r_, 0.75 * layer_);
            rec_.near(q, wr, [&](const Sample& s) {
              if (s.line == static_cast<int>(ci) || !rec_current(s)) return;
              const double d = dist(q, s.p);
              if (d < wr && (d < w.d || (d == w.d && s.line < w.line))) { w.found = true; w.d = d; w.hit = s.p; w.line = s.line; }
            });
            if (w.found && w.line != last_line) {
              path.back() = w.hit;
              must.back() = 1;
              q = w.hit;
              ++joins;
              last_line = w.line;
              last_join = w.hit;
            }
          }
          Vec3 tv;
          if (travelled > sep(p) && near_tie(q, kTestRatio * sep(q), &tv)) {
            path.push_back(tv);
            must.push_back(1);
            ++joins;
            break;
          }
        }
        if (joins < 1) { ++rep_.ties_refused_reach; continue; }
        {
          const double keep_d = 8.0 * r_;
          std::vector<Vec3> thin;
          std::size_t next_must = 0;
          for (std::size_t k = 0; k < path.size(); ++k) {
            if (must[k]) { thin.push_back(path[k]); continue; }
            next_must = std::max(next_must, k);
            while (next_must < path.size() && !must[next_must]) ++next_must;
            const double to_next = next_must < path.size() ? dist(path[next_must], path[k]) : 1e9;
            if (dist(path[k], thin.back()) >= keep_d && to_next >= keep_d) thin.push_back(path[k]);
          }
          path.swap(thin);
        }
        if (path.size() < 2) { ++rep_.ties_refused_reach; continue; }
        const int l = new_line(path[0], static_cast<int>(ci), 1, true);
        for (std::size_t k = 1; k < path.size(); ++k)
          if (dist(path[k], lines_[static_cast<std::size_t>(l)].pts.back()) > 1e-9) lay(l, path[k]);
        for (const Vec3& v : path) tie_box.put(Sample{0, 0, 0, v});
        ++rep_.ties_laid;
      }
    }
  }
}

std::vector<Strand> Grower::run() {
  if (field_.empty()) return {};
  if (!(len(ask_.build_dir) > 1e-9) || !std::isfinite(len(ask_.build_dir)))
    throw std::invalid_argument("grow_strands: the build direction must not be zero");
  if (!(ask_.layer_mm > 0.0) || !std::isfinite(ask_.layer_mm))
    throw std::invalid_argument("grow_strands: layer_mm must be above 0");
  if (!(ask_.seed_stride > 0.0) || !std::isfinite(ask_.seed_stride))
    throw std::invalid_argument("grow_strands: seed_stride must be above 0");
  if (!(ask_.foot_gap > 0.0) || !std::isfinite(ask_.foot_gap))
    throw std::invalid_argument("grow_strands: foot_gap must be above 0");
  const double thinnest = domain_.spec().bead_mm * domain_.spec().min_strut_lines;
  if (ask_.width_mm != 0.0 && !(ask_.width_mm >= thinnest - 1e-12))
    throw std::invalid_argument("grow_strands: the strut width is under the thinnest strut (G8)");
  sp_ = organic_spacing(domain_, region_, field_, ask_);
  if (sp_.candidates == 0) return {};
  up_ = unit(ask_.build_dir);
  u_ = unit(cross(up_, std::fabs(up_.x) < 0.9 ? Vec3{1, 0, 0} : Vec3{0, 1, 0}));
  v_ = cross(up_, u_);
  layer_ = ask_.layer_mm;
  width_ = ask_.width_mm > 0.0 ? ask_.width_mm : thinnest;   // G8 (idea A): never under two lines
  r_ = 0.5 * width_;
  ds_ = std::min(layer_, 0.5 * r_);
  sep_hi_ = ask_.spacing_mm > 0.0 ? ask_.spacing_mm : ask_.spacing_max_mm;
  {
    std::vector<double> all;
    for (std::size_t e = 0; e < sp_.candidate.size(); ++e)
      if (sp_.candidate[e]) all.push_back(sp_.spacing_mm[e]);
    std::sort(all.begin(), all.end());
    median_ = all[all.size() / 2];
  }
  cone_sin_ = std::sin(kConeDeg * kPi / 180.0);
  cone_cos_ = std::cos(kConeDeg * kPi / 180.0);
  bed_ = std::numeric_limits<double>::infinity();
  for (const Vec3& p : domain_.measure().mesh().vertices) bed_ = std::min(bed_, h(p));
  {
    const Vec3 lo = sub(field_.origin, Vec3{sep_hi_, sep_hi_, sep_hi_});
    const Vec3 hi = add(field_.origin, Vec3{field_.nx * field_.spacing + sep_hi_, field_.ny * field_.spacing + sep_hi_,
                                            field_.nz * field_.spacing + sep_hi_});
    boxes_.init(lo, hi, 2.0);
    rec_.init(lo, hi, std::max(1e-3, kTestRatio * median_ * 2.0));
  }
  lighting();
  // The owner's order (2026-11-15): grow, prune, then one round of re-seeding in the bare areas, grown and pruned
  // the same way.
  std::vector<Tip> tips;
  seeds(tips);
  tips_ = tips.size();
  grow(std::move(tips));
  if (ask_.ties) ties(0);
  prune();
  rep_.bare_before = bare();
  const std::size_t first_new = lines_.size();
  std::vector<Tip> more;
  reseed(more);
  grow(std::move(more));
  if (ask_.ties) ties(first_new);
  repeats();
  settle();
  const Fate f = pass();
  account(f);
  for (std::size_t l = 0; l < lines_.size(); ++l)
    for (std::size_t k = 0; k < f.seg[l].size(); ++k) lines_[l].dead[k] = f.seg[l][k] != 0;
  rep_.bare_after = bare();
  rep_.tips = tips_;
  rep_.grown_mm = laid_mm_;
  std::vector<Strand> out = strands();
  rep_.strands = out.size();
  return out;
}

}  // namespace

std::vector<Strand> grow_strands(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask,
                                 GrowReport* report) {
  const auto t0 = std::chrono::steady_clock::now();
  GrowReport rep;
  Grower g(domain, region, field, ask, rep);
  std::vector<Strand> out = g.run();
  rep.ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  if (report) *report = rep;
  return out;
}

}  // namespace topopt::lattice_layout
