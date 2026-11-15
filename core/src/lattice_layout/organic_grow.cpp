// Lattice rebuild, Organic, Grown (rules G1 to G12): the owner's Grown placement, written new in this engine.
// See lattice_layout_organic.hpp and docs/design/lattice-rebuild/01-rules.md section 11. The old generator
// (core/src/mesh/organic_lattice.cpp, grow_organic_lattice) was read for its kept rules and numbers only; nothing of it
// is called. Nothing here decides an order by an unordered container: every list is walked in index order.
#include "topopt/lattice_layout_organic.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <map>
#include <stdexcept>
#include <tuple>
#include <utility>
#include <vector>

namespace topopt::lattice_layout {

void GrowReport::add(const GrowReport& o) {
  seeds_floor += o.seeds_floor; seeds_wall += o.seeds_wall;
  seeds_refused_room += o.seeds_refused_room; seeds_refused_support += o.seeds_refused_support;
  strands_grown += o.strands_grown; steps += o.steps; clamped += o.clamped;
  ended_edge += o.ended_edge; ended_unsupported += o.ended_unsupported; ended_joined += o.ended_joined;
  crowded_climbed_on += o.crowded_climbed_on;
  branches_offered += o.branches_offered; branches_grown += o.branches_grown; links += o.links;
  refused_region += o.refused_region; refused_support += o.refused_support;
  refused_crowded += o.refused_crowded; refused_room += o.refused_room;
  rewinds += o.rewinds; rewind_places += o.rewind_places; rewind_grew_on += o.rewind_grew_on;
  rewind_joined += o.rewind_joined; rewind_ended_on_joint += o.rewind_ended_on_joint;
  taken_back_mm += o.taken_back_mm;
  thinned += o.thinned; thinned_joined += o.thinned_joined;
  regrow_rounds = std::max(regrow_rounds, o.regrow_rounds);
  holes += o.holes; regrow_landed += o.regrow_landed; regrow_failed += o.regrow_failed;
  ties_seeded += o.ties_seeded; ties_laid += o.ties_laid; ties_refused_minor += o.ties_refused_minor;
  ties_refused_reach += o.ties_refused_reach; ties_refused_support += o.ties_refused_support;
  grown_mm += o.grown_mm; kept_mm += o.kept_mm;
  cut_outside_mm += o.cut_outside_mm; cut_unsupported_mm += o.cut_unsupported_mm; cut_nothing_mm += o.cut_nothing_mm;
  cut_crowded_mm += o.cut_crowded_mm; cut_repeat_mm += o.cut_repeat_mm;
  strands += o.strands; ms += o.ms;
}

namespace {

constexpr double kPi = 3.14159265358979323846;
// The old numbers, kept (organic_lattice.hpp and .cpp; map-grown-pruning.md section 1):
constexpr double kBlendHeading = 0.35, kBlendField = 0.65;   // G3: the heading follows the stress
constexpr double kUpwardBias = 0.25;                         // G3: the pull upward
constexpr double kConeDeg = 30.0;                            // G4: never flatter than this from level
constexpr double kSupportRadii = 1.25;                       // G4: material within 1.25 r under the underside
constexpr double kCrowdedRatio = 0.5;                        // G5: crowded = within 0.5 x the local spacing
constexpr double kJoinRunMm = 3.0;                           // G5, G6: a join (or a link) runs 3 mm or less
constexpr double kBranchEveryRatio = 0.5;                    // G6: a branch offered every 0.5 x spacing of climb
constexpr double kHoleRatio = 1.5;                           // G11: a hole is 1.5 x the local spacing from anything
constexpr int kRegrowRounds = 2;                             // G11
constexpr double kTieMinorRatio = 0.10;                      // G9: |sigma2| / |sigma1| at least this
constexpr double kTieReachRatio = 8.0;                       // G9: a tie walks at most 8 spacings
constexpr double kTieSwirlDeg = 28.0, kTieSwirlWavelengthRatio = 3.5;   // G9
constexpr double kTieThinRadii = 8.0;                        // G9: free tie vertices 8 r apart (4 x the 2 r merge)
// The new numbers (GR-REWIND, G5; G10):
constexpr double kRewindTurnDeg = 35.0;
constexpr int kRewindTries = 3;
constexpr double kRepeatMm = 0.02;

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

// One strand while it grows: its points, a stamp per segment (a segment taken back by a rewind loses its stamp, so
// its points in the boxes are no longer read), the strand it grew from (or landed on), its family, a tie or not.
struct Line {
  std::vector<Vec3> pts;
  std::vector<std::uint64_t> stamp;   // per segment
  std::vector<char> dead;             // per segment: dropped by the path's pruning (G11): no longer material
  int parent = -1;
  int family = 0;
  bool tie = false;
};

struct Near {
  bool found = false;
  double d = std::numeric_limits<double>::infinity();
  Vec3 hit{};
  int line = -1;
};

struct Tip {
  enum Kind { Floor, Wall, Branch, Regrow };
  Kind kind = Floor;
  Vec3 root{}, dir{}, target{};
  Vec3 from{};   // where growth begins: the root, or (a seed run into the solid) the point on the region's edge
  int parent = -1, family = 0;
};

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
  double layer_ = 0.2, width_ = 0.9, r_ = 0.45, lower_ = 3.0, sep_hi_ = 8.0, bed_ = 0.0, ds_ = 0.2;
  double cone_sin_ = 0.5, cone_cos_ = 0.0;
  double laid_mm_ = 0.0;
  std::uint64_t next_stamp_ = 1;
  Boxes boxes_;
  std::vector<Line> lines_;

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
  double stress_along(const Vec3& p, const Vec3& t) const {
    int i, j, k;
    if (!voxel(p, i, j, k)) return 0.0;
    const double* s = &field_.voigt[6 * field_.index(i, j, k)];
    return std::fabs(t.x * t.x * s[0] + t.y * t.y * s[1] + t.z * t.z * s[2] +
                     2.0 * (t.x * t.y * s[3] + t.y * t.z * s[4] + t.z * t.x * s[5]));
  }

  // A sample of a segment still on its line (not taken back).
  bool current(const Sample& s) const {
    const Line& L = lines_[static_cast<std::size_t>(s.line)];
    return static_cast<std::size_t>(s.seg) < L.stamp.size() && L.stamp[static_cast<std::size_t>(s.seg)] == s.stamp;
  }
  // ... and material: not dropped by the path's pruning.
  bool live(const Sample& s) const {
    return current(s) && !lines_[static_cast<std::size_t>(s.line)].dead[static_cast<std::size_t>(s.seg)];
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
  // A new segment at the end of a line, to `b`.
  void lay(int li, const Vec3& b) {
    Line& L = lines_[static_cast<std::size_t>(li)];
    laid_mm_ += dist(L.pts.back(), b);
    L.pts.push_back(b);
    stamp_segment(li, L.pts.size() - 2);
  }
  int new_line(const Vec3& root, int parent, int family, bool tie = false) {
    Line L;
    L.pts.push_back(root);
    L.parent = parent;
    L.family = family;
    L.tie = tie;
    lines_.push_back(std::move(L));
    return static_cast<int>(lines_.size()) - 1;
  }
  // Take a line back to point `keep` (its segments after it are no longer material).
  double take_back(int li, std::size_t keep) {
    Line& L = lines_[static_cast<std::size_t>(li)];
    double mm = 0.0;
    for (std::size_t s = keep; s + 1 < L.pts.size(); ++s) mm += dist(L.pts[s], L.pts[s + 1]);
    L.pts.resize(keep + 1);
    L.stamp.resize(keep);
    L.dead.resize(keep);
    return mm;
  }
  void rebuild_boxes() {
    boxes_.clear();
    for (std::size_t li = 0; li < lines_.size(); ++li) {
      lines_[li].stamp.clear();
      lines_[li].dead.resize(lines_[li].pts.size() ? lines_[li].pts.size() - 1 : 0, 0);
      for (std::size_t s = 0; s + 1 < lines_[li].pts.size(); ++s) stamp_segment(static_cast<int>(li), s);
    }
  }
  static double line_mm(const Line& L) {
    double mm = 0.0;
    for (std::size_t s = 0; s + 1 < L.pts.size(); ++s) mm += dist(L.pts[s], L.pts[s + 1]);
    return mm;
  }

  // The nearest point of any other strand within R of q: not `self`, not `parent`, not a strand grown from `self` (a
  // link it made) within the lower limit of where that starts. The first of equally near ones, in the boxes' order. Every strand of the plant counts (growth
  // keeps its spacing to all of them, those the path will drop included); `live_only`: only what the path keeps.
  Near nearest(const Vec3& q, double R, int self, int parent, bool ties_only = false, bool no_ties = false,
               bool live_only = false) const {
    Near out;
    boxes_.near(q, R + ds_, [&](const Sample& s) {
      if (s.line == self || s.line == parent || !(live_only ? live(s) : current(s))) return;
      const Line& L = lines_[static_cast<std::size_t>(s.line)];
      if ((ties_only && !L.tie) || (no_ties && L.tie)) return;
      const Vec3 c = closest_on(q, L.pts[static_cast<std::size_t>(s.seg)], L.pts[static_cast<std::size_t>(s.seg) + 1]);
      if (self >= 0 && L.parent == self && dist(c, L.pts.front()) <= lower_) return;   // its own link, at its root
      const double d = dist(q, c);
      if (d <= R && d < out.d) {
        out.found = true;
        out.d = d;
        out.hit = c;
        out.line = s.line;
      }
    });
    return out;
  }
  double to_line(const Vec3& q, int line, double R) const {
    double best = std::numeric_limits<double>::infinity();
    boxes_.near(q, R + ds_, [&](const Sample& s) {
      if (s.line != line || !live(s)) return;
      const Line& L = lines_[static_cast<std::size_t>(s.line)];
      best = std::min(best, dist(q, closest_on(q, L.pts[static_cast<std::size_t>(s.seg)],
                                              L.pts[static_cast<std::size_t>(s.seg) + 1])));
    });
    return best;
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

  void seeds(std::vector<Tip>& tips);
  void grow(std::vector<Tip> tips);
  void grow_tip(const Tip& t, std::vector<Tip>& tips);
  bool turn(const Vec3& at, int li, int parent, const Vec3& heading, const std::vector<Vec3>& tried, Vec3& out) const;
  void offer_branches(int li, const Vec3& p, const Vec3& dir, std::size_t& floor_idx, std::vector<Tip>& tips);
  std::vector<int> links_made_;   // by the tip growing now
  void repeats();
  void thin();
  struct Fate { std::vector<std::vector<char>> seg; };   // per line, per segment: 0 kept, 1 outside, 2 nothing, 3 unsupported
  Fate pass();
  void account(const Fate& f);
  void regrow_holes(std::vector<Tip>& tips);
  void ties();
  std::vector<Strand> strands() const;
};

void Grower::seeds(std::vector<Tip>& tips) {
  const double hv = field_.spacing;
  // G2 (idea B): the lowest candidate of each column, a column measured along the build direction.
  std::map<std::pair<long long, long long>, std::pair<double, Vec3>> low;
  for (int k = 0; k < field_.nz; ++k)
    for (int j = 0; j < field_.ny; ++j)
      for (int i = 0; i < field_.nx; ++i) {
        if (!sp_.candidate[field_.index(i, j, k)]) continue;
        const Vec3 c = centre(i, j, k);
        const std::pair<long long, long long> key{std::llround(dot(c, u_) / hv), std::llround(dot(c, v_) / hv)};
        auto it = low.find(key);
        if (it == low.end() || h(c) < it->second.first) low[key] = {h(c), c};
      }
  std::vector<Vec3> taken;   // the seeds' own points, for one per local spacing
  auto room_for = [&](const Vec3& p) {
    const double s = sep(p);
    for (const Vec3& q : taken)
      if (dist(p, q) < s) return false;
    return true;
  };
  for (const auto& kv : low) {
    const Vec3 c = kv.second.second;
    const Vec3 down = mul(up_, -1.0);
    const double at = edge(c, down, 2.0 * hv);
    const Vec3 on = at >= 0.0 ? add(c, mul(down, at)) : c;
    if (!room_for(on)) continue;
    taken.push_back(on);
    Tip t;
    t.kind = Tip::Floor;
    t.root = at >= 0.0 ? end_at_edge(c, down, at) : c;
    t.dir = up_;
    t.target = on;
    t.from = on;
    tips.push_back(t);
    ++rep_.seeds_floor;
  }
  if (!ask_.walls_out) return;
  // G2 (idea C): on the region's walls: a candidate whose neighbour across a side face (one that is not above or
  // below it) is the part's solid. Lowest first, then by column.
  struct W { long long hk, a, b; int n; Vec3 c, w; };
  std::vector<W> walls;
  static const int nb[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
  for (int k = 0; k < field_.nz; ++k)
    for (int j = 0; j < field_.ny; ++j)
      for (int i = 0; i < field_.nx; ++i) {
        if (!sp_.candidate[field_.index(i, j, k)]) continue;
        const Vec3 c = centre(i, j, k);
        for (int n = 0; n < 6; ++n) {
          const Vec3 off{static_cast<double>(nb[n][0]), static_cast<double>(nb[n][1]), static_cast<double>(nb[n][2])};
          if (std::fabs(dot(off, up_)) >= 0.5) continue;
          const int a = i + nb[n][0], b = j + nb[n][1], cc = k + nb[n][2];
          if (a >= 0 && b >= 0 && cc >= 0 && a < field_.nx && b < field_.ny && cc < field_.nz &&
              sp_.candidate[field_.index(a, b, cc)])
            continue;
          if (!solid(add(c, mul(off, hv)))) continue;
          walls.push_back({std::llround(h(c) / hv), std::llround(dot(c, u_) / hv), std::llround(dot(c, v_) / hv), n, c,
                           unit(level(off))});
          break;
        }
      }
  std::sort(walls.begin(), walls.end(), [](const W& x, const W& y) {
    return std::tie(x.hk, x.a, x.b, x.n) < std::tie(y.hk, y.a, y.b, y.n);
  });
  for (const W& w : walls) {
    const double at = edge(w.c, w.w, 2.0 * hv);
    if (at < 0.0) continue;
    const Vec3 on = add(w.c, mul(w.w, at));
    if (!room_for(on)) continue;
    taken.push_back(on);
    Tip t;
    t.kind = Tip::Wall;
    t.root = end_at_edge(w.c, w.w, at);
    t.dir = add(mul(w.w, -cone_cos_), mul(up_, cone_sin_));   // inward, at the cone
    t.target = on;
    t.from = on;
    tips.push_back(t);
    ++rep_.seeds_wall;
  }
}

// GR-REWIND's turn: among the directions within 35 degrees of the stress (the heading where there is none), on the
// cone or steeper, whose first step is in the region and supported, and not tried here before: the one whose point
// one local spacing ahead lies farthest from every other strand (the first of equals). False when none has room
// (that point within the lower limit of another strand).
bool Grower::turn(const Vec3& at, int li, int parent, const Vec3& heading, const std::vector<Vec3>& tried,
                  Vec3& out) const {
  Vec3 f;
  if (!stress_dir(at, f)) f = heading;
  f = unit(f);
  Vec3 a1 = unit(cross(f, std::fabs(f.x) < 0.9 ? Vec3{1, 0, 0} : Vec3{0, 1, 0}));
  Vec3 a2 = cross(f, a1);
  std::vector<Vec3> fan{f};
  for (double tilt : {0.5 * kRewindTurnDeg, kRewindTurnDeg})
    for (int k = 0; k < 8; ++k) {
      const double t = tilt * kPi / 180.0, az = k * kPi / 4.0;
      fan.push_back(add(mul(f, std::cos(t)), mul(add(mul(a1, std::cos(az)), mul(a2, std::sin(az))), std::sin(t))));
    }
  const double s = sep(at), look = 1.5 * sep_hi_;
  double best = -1.0;
  for (const Vec3& d : fan) {
    const double rise = dot(d, up_);
    if (rise < cone_sin_ - 1e-12) continue;
    bool seen = false;
    for (const Vec3& t : tried) seen = seen || dot(t, d) > 1.0 - 1e-9;
    if (seen) continue;
    const Vec3 q = add(at, mul(d, layer_ / rise));
    if (!inreg(q) || !supported(q)) continue;
    const Near n = nearest(add(at, mul(d, s)), look, li, parent);
    const double room = n.found ? n.d : look;
    if (room > best) {
      best = room;
      out = d;
    }
  }
  return best >= lower_;
}

void Grower::offer_branches(int li, const Vec3& p, const Vec3& dir, std::size_t& floor_idx, std::vector<Tip>& tips) {
  // G6: across the heading, along whichever of the two minor principal directions is least along it (a side axis
  // of the build plane where there is no stress), leaving at the cone.
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
  for (int sgn = -1; sgn <= 1; sgn += 2) {
    const Vec3 bdir = add(mul(side, sgn * cone_cos_), mul(up_, cone_sin_));
    const Vec3 bq = add(p, mul(bdir, layer_ / cone_sin_));
    ++rep_.branches_offered;
    if (!inreg(bq)) { ++rep_.refused_region; continue; }
    if (!supported(bq)) { ++rep_.refused_support; continue; }
    const Near c = nearest(bq, kCrowdedRatio * sep(bq), li, -1);
    if (c.found) {
      ++rep_.refused_crowded;
      // G6: a crowded branch whose run is short is a link to what crowded it.
      if (len(level(sub(c.hit, p))) <= kJoinRunMm && dist(c.hit, p) > 1e-9) {
        const int l = new_line(p, li, (me.family + 1) % 3);
        lay(l, c.hit);
        links_made_.push_back(l);
        ++rep_.links;
        floor_idx = lines_[static_cast<std::size_t>(li)].pts.size() - 1;
      }
      continue;
    }
    // G7 (idea D): room for one more strand one local spacing away.
    const double s = sep(p);
    const Vec3 target = add(p, mul(side, sgn * s));
    const Near room = nearest(target, s, li, -1);
    if (!inreg(target) || (room.found && room.d < s)) { ++rep_.refused_room; continue; }
    Tip t;
    t.kind = Tip::Branch;
    t.root = p;
    t.from = p;
    t.dir = bdir;
    t.target = target;
    t.parent = li;
    t.family = (me.family + 1) % 3;
    tips.push_back(t);
    floor_idx = lines_[static_cast<std::size_t>(li)].pts.size() - 1;
  }
}

void Grower::grow_tip(const Tip& t, std::vector<Tip>& tips) {
  // G7 (idea D), at its turn: room for one more strand where it is to go, and (a regrown tip) where it starts.
  {
    const double s = sep(t.target);
    const Near n = nearest(t.target, s, -1, t.parent);
    const double s0 = sep(t.from);
    const Near n0 = t.kind == Tip::Regrow ? nearest(t.from, s0, -1, t.parent) : Near{};
    if ((n.found && n.d < s) || (n0.found && n0.d < s0)) {
      if (t.kind == Tip::Branch) ++rep_.refused_room;
      else if (t.kind == Tip::Regrow) ++rep_.regrow_failed;
      else ++rep_.seeds_refused_room;
      return;
    }
  }
  const int li = new_line(t.root, t.parent, t.family);
  int parent = t.parent;
  // A seed starts on the region's edge; its first point is run into the solid by its width (as O4 runs an end), so
  // its first segment crosses the edge and weave_bars cuts it there and finds it Solid.
  const Vec3 start = t.from;
  Vec3 p = start, dir = t.dir;
  std::size_t floor_idx = 0;   // never rewound past (G5)
  double since_branch = 0.0;
  // The first step of a branch (and of a wall seed) is the direction it was offered in; a turn holds for one spacing.
  double hold = (t.kind == Tip::Branch || t.kind == Tip::Wall) ? 1e-9 : 0.0;
  Vec3 hold_dir = t.dir;
  std::map<std::size_t, std::vector<Vec3>> tried;
  long long open_place = -1;
  bool first = true;
  const int layers = static_cast<int>(std::ceil((domain_.measure().diagonal_mm() + 1.0) / layer_)) + 4;
  const long long guard = 16LL * layers;
  enum End { Edge, Unsupported, Joined, GaveUp, Guard } how = Guard;
  for (long long it = 0; it < guard; ++it) {
    Vec3 want;
    if (hold > 0.0) {
      want = hold_dir;
    } else {
      Vec3 f;
      want = stress_dir(p, f) ? add(mul(dir, kBlendHeading), mul(f, kBlendField)) : dir;
      want = add(want, mul(up_, kUpwardBias));
      want = unit(want);
      if (len(want) < 0.5) { how = Unsupported; break; }
      if (dot(want, up_) < cone_sin_) {
        ++rep_.clamped;
        const Vec3 side = unit(level(want));
        want = len(side) > 0.5 ? add(mul(side, cone_cos_), mul(up_, cone_sin_)) : up_;
      }
    }
    const double rise = std::max(dot(want, up_), 1e-9);
    const Vec3 q = add(p, mul(want, layer_ / rise));
    // A regrown tip starts on the strand it landed on: that strand is not counted against it for its first spacing.
    if (t.kind == Tip::Regrow && parent >= 0 && dist(q, start) > sep(start)) {
      parent = -1;
      lines_[static_cast<std::size_t>(li)].parent = -1;
    }
    if (!inreg(q)) {
      // G3: it leaves the region: it ends at the edge (on into the solid by its width where solid is past it).
      const double step = dist(p, q);
      const double at = edge(p, want, step + 0.05);
      const Vec3 e = end_at_edge(p, want, at >= 0.0 ? at : 0.0);
      if (dist(e, p) > 1e-9) lay(li, e);
      how = Edge;
      break;
    }
    // The tip's own root stands on what it started on (a seed's solid, the strand it grew from or landed on).
    const bool on_root = lines_[static_cast<std::size_t>(li)].pts.size() == 1 && len(level(sub(q, start))) <= 2.0 * r_ &&
                         h(start) <= h(q) && (t.kind == Tip::Regrow || t.kind == Tip::Branch);
    if (!on_root && !supported(q)) {
      if (first && (t.kind == Tip::Floor || t.kind == Tip::Wall)) {
        ++rep_.seeds_refused_support;
        laid_mm_ -= take_back(li, 0);   // nothing of a seed that cannot take its first step is laid
      }
      how = Unsupported;
      break;
    }
    const double s = sep(q);
    const Near n = nearest(q, std::max(lower_, kCrowdedRatio * s), li, parent);
    const bool crowded = n.found && n.d < kCrowdedRatio * s;
    if (n.found && (crowded || n.d < lower_)) {
      const double run = len(level(sub(n.hit, p)));
      if (crowded && run <= kJoinRunMm) {   // G5: an allowed join: the tip ends on its neighbour (a held end)
        if (dist(n.hit, p) > 1e-9) lay(li, n.hit);
        how = Joined;
        break;
      }
      if (n.d < lower_) {
        // GR-REWIND: back to the last point that had its local spacing to every other strand, never past the floor.
        Line& L = lines_[static_cast<std::size_t>(li)];
        std::size_t back = floor_idx;
        for (std::size_t k = L.pts.size() - 1; k > floor_idx; --k) {
          const double sk = sep(L.pts[k]);
          const Near m = nearest(L.pts[k], sk, li, parent);
          if (!m.found || m.d >= sk) { back = k; break; }
        }
        std::vector<Vec3>& here = tried[back];
        Vec3 d;
        const bool can = static_cast<int>(here.size()) < kRewindTries &&
                         turn(back == 0 ? start : L.pts[back], li, parent, dir, here, d);
        if (open_place != static_cast<long long>(back)) {
          if (open_place >= 0) ++rep_.rewind_grew_on;
          ++rep_.rewind_places;
          open_place = static_cast<long long>(back);
        }
        if (!can) {
          // No room: join the neighbour when the run is short, else end at the last joint (never a loose tail).
          if (run <= kJoinRunMm) {
            if (dist(n.hit, p) > 1e-9) lay(li, n.hit);
            ++rep_.rewind_joined;
            how = Joined;
          } else {
            rep_.cut_crowded_mm += take_back(li, floor_idx);
            ++rep_.rewind_ended_on_joint;
            how = GaveUp;
          }
          open_place = -1;
          break;
        }
        here.push_back(d);
        ++rep_.rewinds;
        const double mm = take_back(li, back);
        rep_.taken_back_mm += mm;
        laid_mm_ -= mm;
        p = lines_[static_cast<std::size_t>(li)].pts.size() == 1 ? start : lines_[static_cast<std::size_t>(li)].pts.back();
        dir = d;
        hold_dir = d;
        hold = sep(p);
        since_branch = 0.0;
        continue;
      }
      ++rep_.crowded_climbed_on;   // crowded, too far to join, still past the lower limit: climbs on (G5)
    }
    lay(li, q);
    first = false;
    ++rep_.steps;
    const double stepped = dist(p, q);
    since_branch += stepped;
    if (hold > 0.0) hold = std::max(0.0, hold - stepped);
    p = q;
    dir = want;
    if (since_branch >= std::max(stepped, kBranchEveryRatio * sep(p))) {
      since_branch = 0.0;
      offer_branches(li, p, dir, floor_idx, tips);
    }
  }
  if (open_place >= 0) ++rep_.rewind_grew_on;
  // A link the tip made is not kept where the tip itself went on to the same place (it would lie along the tip).
  for (int l : links_made_) {
    const Line& K = lines_[static_cast<std::size_t>(l)];
    if (K.pts.size() == 2 && to_line(K.pts.back(), li, width_) < width_) {
      laid_mm_ -= take_back(l, 0);
      --rep_.links;
    }
  }
  links_made_.clear();
  {
    // A tip that grew less than its own width is a stub (S4): taken back.
    Line& L = lines_[static_cast<std::size_t>(li)];
    double mm = 0.0;
    for (std::size_t k = 0; k + 1 < L.pts.size(); ++k) mm += dist(L.pts[k], L.pts[k + 1]);
    if (L.pts.size() >= 2 && mm < width_) {
      const double back = take_back(li, 0);
      laid_mm_ -= back;
      rep_.taken_back_mm += back;
    }
  }
  if (how == Edge) ++rep_.ended_edge;
  else if (how == Unsupported) ++rep_.ended_unsupported;
  else if (how == Joined) ++rep_.ended_joined;
  if (lines_[static_cast<std::size_t>(li)].pts.size() >= 2) ++rep_.strands_grown;
}

void Grower::grow(std::vector<Tip> tips) {
  // A worklist: each tip grows to its end, and the branches it offers are grown after the tips before them.
  for (std::size_t i = 0; i < tips.size(); ++i) {
    const Tip t = tips[i];
    grow_tip(t, tips);
  }
}

// G10, pruning step 1: a segment lying within 0.02 mm of a strand already kept, along its whole length, is a repeat
// and is left out (the strand is split there). Strands are read in order; the first keeps it. Because the strands
// returned are straightened (each within 0.25 r of its line), "within 0.02 mm" is read here as within 0.02 mm and
// the two straightenings (0.5 r).
void Grower::repeats() {
  const double near_mm = kRepeatMm + 0.5 * r_;
  std::vector<Line> out;
  Boxes kept = boxes_;
  kept.clear();
  std::vector<Line> keep_lines;
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
      if (dup[s]) { rep_.cut_repeat_mm += dist(L.pts[s], L.pts[s + 1]); ++s; continue; }
      Line run;
      run.parent = -1;
      run.family = L.family;
      run.tie = L.tie;
      run.pts.push_back(L.pts[s]);
      while (s < dup.size() && !dup[s]) { run.dead.push_back(L.dead[s]); run.pts.push_back(L.pts[++s]); }
      const std::size_t id = keep_lines.size();
      keep_lines.push_back(run);
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
}

// G10, pruning step 4, thinning to the window: where a stretch of one strand lies closer than the lower limit to
// another, away from any joint of the two (a place within the lower limit where they touch: a crossing, a branch's
// root, a join or a link), the strand carrying less stress along it (the mean of |t . sigma . t| over its length;
// the earlier of equals stays) is left out there; each end that leaves is joined into the other when the run is 3 mm
// or less, else cut.
void Grower::thin() {
  const std::size_t nl = lines_.size();
  std::vector<double> score(nl, 0.0);
  for (std::size_t l = 0; l < nl; ++l) {
    const Line& L = lines_[l];
    double s = 0.0, w = 0.0;
    for (std::size_t k = 0; k + 1 < L.pts.size(); ++k) {
      const double m = dist(L.pts[k], L.pts[k + 1]);
      s += m * stress_along(mul(add(L.pts[k], L.pts[k + 1]), 0.5), unit(sub(L.pts[k + 1], L.pts[k])));
      w += m;
    }
    score[l] = w > 0.0 ? s / w : 0.0;
  }
  auto stronger = [&](std::size_t a, std::size_t b) { return score[a] > score[b] || (score[a] == score[b] && a < b); };
  struct Cut { bool on = false; std::size_t by = 0; };
  std::vector<std::vector<Cut>> cut(nl);
  for (std::size_t l = 0; l < nl; ++l) {
    const Line& B = lines_[l];
    if (B.tie || B.pts.size() < 2) continue;
    cut[l].assign(B.pts.size() - 1, Cut{});
    for (std::size_t k = 0; k + 1 < B.pts.size(); ++k) {
      if (B.dead[k]) continue;   // the path drops it anyway
      const Vec3 a = B.pts[k], b = B.pts[k + 1];
      const int n = std::max(1, static_cast<int>(std::ceil(dist(a, b) / ds_)));
      for (int t = 0; t <= n && !cut[l][k].on; ++t) {
        const Vec3 x = add(a, mul(sub(b, a), double(t) / n));
        std::vector<int> others;
        boxes_.near(x, lower_ + ds_, [&](const Sample& s) {
          if (s.line == static_cast<int>(l) || !live(s) || lines_[static_cast<std::size_t>(s.line)].tie) return;
          if (std::find(others.begin(), others.end(), s.line) == others.end()) others.push_back(s.line);
        });
        std::sort(others.begin(), others.end());
        for (int A : others) {
          if (to_line(x, A, lower_) >= lower_) continue;
          // A joint of the two within the lower limit of here: a point of B, that near, touching A.
          bool joint = false;
          boxes_.near(x, lower_ + ds_, [&](const Sample& s) {
            if (joint || s.line != static_cast<int>(l) || !live(s) || dist(s.p, x) > lower_) return;
            if (to_line(s.p, A, width_) < width_) joint = true;
          });
          if (!joint) {
            boxes_.near(x, lower_ + ds_, [&](const Sample& s) {
              if (joint || s.line != A || !live(s) || dist(s.p, x) > lower_) return;
              if (to_line(s.p, static_cast<int>(l), width_) < width_) joint = true;
            });
          }
          if (joint) continue;
          if (stronger(static_cast<std::size_t>(A), l)) {
            cut[l][k] = Cut{true, static_cast<std::size_t>(A)};
            break;
          }
        }
      }
    }
  }
  std::vector<Line> out;
  for (std::size_t l = 0; l < nl; ++l) {
    const Line& B = lines_[l];
    if (B.pts.size() < 2) continue;
    if (cut[l].empty()) { out.push_back(B); continue; }
    auto join_end = [&](std::size_t by, const Vec3& e, Vec3& to) {
      double best = std::numeric_limits<double>::infinity();
      const Line& A = lines_[by];
      for (std::size_t k = 0; k + 1 < A.pts.size(); ++k) {
        const Vec3 c = closest_on(e, A.pts[k], A.pts[k + 1]);
        if (dist(c, e) < best) { best = dist(c, e); to = c; }
      }
      return best < std::numeric_limits<double>::infinity() && len(level(sub(to, e))) <= kJoinRunMm;
    };
    std::size_t k = 0;
    const std::size_t ns = B.pts.size() - 1;
    while (k < ns) {
      if (cut[l][k].on) {
        std::size_t e = k;
        while (e < ns && cut[l][e].on) { rep_.cut_crowded_mm += dist(B.pts[e], B.pts[e + 1]); ++e; }
        ++rep_.thinned;
        k = e;
        continue;
      }
      Line run;
      run.family = B.family;
      run.tie = B.tie;
      const std::size_t s0 = k;
      while (k < ns && !cut[l][k].on) ++k;
      for (std::size_t q = s0; q <= k; ++q) run.pts.push_back(B.pts[q]);
      for (std::size_t q = s0; q < k; ++q) run.dead.push_back(B.dead[q]);
      Vec3 to;
      if (s0 > 0 && join_end(cut[l][s0 - 1].by, run.pts.front(), to) && dist(to, run.pts.front()) > 1e-9) {
        laid_mm_ += dist(to, run.pts.front());
        run.pts.insert(run.pts.begin(), to);
        run.dead.insert(run.dead.begin(), 0);
        ++rep_.thinned_joined;
      }
      if (k < ns && join_end(cut[l][k].by, run.pts.back(), to) && dist(to, run.pts.back()) > 1e-9) {
        laid_mm_ += dist(to, run.pts.back());
        run.pts.push_back(to);
        run.dead.push_back(0);
        ++rep_.thinned_joined;
      }
      out.push_back(std::move(run));
    }
  }
  lines_ = std::move(out);
  rebuild_boxes();
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

// Steps 2 and 3: the path's own pruning, run on the weave alone, as Session::lay_weave runs it. Each segment's fate:
// kept when a bar of it is left; else where its last bar went (cut to the region: outside the model; dropped loose:
// leads to nothing; dropped as a piece not joined to the part: unsupported).
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
  drop_loose_bars(bars);
  mark(bars, 3, 2);   // survived the loose drop
  drop_adrift_bars(bars, domain_, nullptr);
  mark(bars, 0, 3);   // survived the adrift drop: kept
  return f;
}

void Grower::account(const Fate& f) {
  for (std::size_t l = 0; l < lines_.size(); ++l) {
    const Line& L = lines_[l];
    for (std::size_t k = 0; k + 1 < L.pts.size(); ++k) {
      const double m = dist(L.pts[k], L.pts[k + 1]);
      switch (f.seg[l][k]) {
        case 0: rep_.kept_mm += m; break;
        case 1: rep_.cut_outside_mm += m; break;
        case 2: rep_.cut_nothing_mm += m; break;
        default: rep_.cut_unsupported_mm += m; break;
      }
    }
  }
}

// G11, pruning step 5: holes the pruning leaves, regrown. A hole is a candidate voxel centre (on a stride of half the
// median spacing) with nothing within 1.5 x its spacing, one per 1.5 spacings. From each, straight down along the
// build direction to the first place a strut would be held (a strand, the solid, the bed), still in the region: a
// tip starts there (on the strand it landed on, as a branch of it) and grows up by every rule above.
void Grower::regrow_holes(std::vector<Tip>& tips) {
  std::vector<double> all;
  for (std::size_t e = 0; e < sp_.candidate.size(); ++e)
    if (sp_.candidate[e]) all.push_back(sp_.spacing_mm[e]);
  if (all.empty()) return;
  std::sort(all.begin(), all.end());
  const double median = all[all.size() / 2];
  const int stride = std::max(1, static_cast<int>(0.5 * median / field_.spacing));
  std::vector<Vec3> voids;
  for (int k = 0; k < field_.nz; k += stride)
    for (int j = 0; j < field_.ny; j += stride)
      for (int i = 0; i < field_.nx; i += stride) {
        if (!sp_.candidate[field_.index(i, j, k)]) continue;
        const Vec3 q = centre(i, j, k);
        const double lim = kHoleRatio * sep(q);
        if (nearest(q, lim, -1, -1, false, false, true).found) continue;
        bool near_void = false;
        for (const Vec3& o : voids) near_void = near_void || dist(o, q) < lim;
        if (!near_void) voids.push_back(q);
      }
  rep_.holes += voids.size();
  const double most = domain_.measure().diagonal_mm();
  for (const Vec3& q : voids) {
    bool landed = false;
    Vec3 x = q;
    for (int k = 1; k * layer_ <= most; ++k) {
      x = sub(q, mul(up_, k * layer_));
      if (supported(x)) { landed = true; break; }
      if (!inreg(x)) break;
    }
    if (!landed || !inreg(x)) { ++rep_.regrow_failed; continue; }
    Tip t;
    t.kind = Tip::Regrow;
    t.root = t.from = x;
    t.dir = up_;
    t.target = q;
    const Near on = nearest(x, 2.0 * r_ + kSupportRadii * r_ + r_, -1, -1, false, false, true);
    if (on.found) {   // on a strand: it starts on it
      t.parent = on.line;
      t.root = t.from = on.hit;
      t.family = (lines_[static_cast<std::size_t>(on.line)].family + 1) % 3;
    } else {          // on the solid (or the bed): it starts on the region's edge below, run into the solid as a seed
      const Vec3 down = mul(up_, -1.0);
      const double at = edge(x, down, 2.0 * (r_ + kSupportRadii * r_ + layer_));
      if (at >= 0.0) {
        t.from = add(x, mul(down, at));
        t.root = end_at_edge(x, down, at);
      }
    }
    tips.push_back(t);
    ++rep_.regrow_landed;
  }
}

// G9: the transfer ties, the old rules and numbers, laid only where they obey the rules of any strut: a tie runs from
// the strand it starts on to its welds; a stretch past its last weld leads to nothing and is not laid; a stretch
// between two welds whose lowest point is not one of its two ends would start in mid-air and is not laid.
void Grower::ties() {
  const double r0 = r_, step = layer_;
  const std::size_t pillars = lines_.size();
  auto minor = [&](const Vec3& p, Vec3& e2, double& ratio, Vec3* e1 = nullptr) {
    double ev[3];
    Vec3 vec[3];
    if (!frame(p, ev, vec)) return false;
    e2 = vec[1];
    ratio = std::fabs(ev[1]) / std::fabs(ev[0]);
    if (e1) *e1 = vec[0];
    return len(e2) > 1e-9;
  };
  for (std::size_t ci = 0; ci < pillars; ++ci) {
    if (lines_[ci].family != 0 || lines_[ci].tie || lines_[ci].pts.size() < 2) continue;
    double since = 0.0;
    const std::vector<Vec3> pc = lines_[ci].pts;
    for (std::size_t pi = 1; pi < pc.size(); ++pi) {
      since += dist(pc[pi], pc[pi - 1]);
      const Vec3 p = pc[pi];
      if (lines_[ci].dead[pi - 1]) continue;   // not on what the path drops
      if (since < sep(p)) continue;
      since = 0.0;
      if (nearest(p, kCrowdedRatio * sep(p), -1, -1, true).found) continue;   // not within half a spacing of a tie
      Vec3 e2;
      double ratio = 0.0;
      if (!minor(p, e2, ratio)) continue;
      if (ratio < kTieMinorRatio) { ++rep_.ties_refused_minor; continue; }
      for (int sgn = -1; sgn <= 1; sgn += 2) {
        ++rep_.ties_seeded;
        const double reach = kTieReachRatio * sep(p);
        Vec3 dir = mul(e2, sgn);
        Vec3 q = p;
        double travelled = 0.0;
        std::vector<Vec3> path{p};
        std::vector<char> must{1};
        int welds = 0, last_line = static_cast<int>(ci);
        Vec3 last_weld = p;
        while (travelled < reach) {
          Vec3 ea, em;
          double ra, rm;
          if (!minor(q, ea, ra)) break;
          if (dot(ea, dir) < 0.0) ea = mul(ea, -1.0);
          const Vec3 mid = add(q, mul(ea, 0.5 * step));
          Vec3 e1m;
          if (!minor(mid, em, rm, &e1m)) break;
          if (dot(em, dir) < 0.0) em = mul(em, -1.0);
          dir = unit(em);
          if (ask_.tie_swirl > 0.0) {
            const double lam = kTieSwirlWavelengthRatio * sep(q);
            const double k1 = 2.0 * kPi / lam, k2 = k1 * 0.618, k3 = k1 * 1.414;
            const double phase = std::sin(k1 * q.x + 0.7) * std::cos(k2 * q.z + 1.9) +
                                 0.5 * std::sin(k3 * (q.x + q.z) + 0.3) * std::cos(k1 * q.y + 2.4);
            const double ang = ask_.tie_swirl * kTieSwirlDeg * kPi / 180.0 * std::clamp(phase, -1.0, 1.0);
            double ev[3];
            Vec3 f3[3];
            if (frame(q, ev, f3)) {
              const Vec3 axis = unit(cross(dir, f3[0]));
              if (len(axis) > 1e-9) {
                const double c = std::cos(ang), sn = std::sin(ang);
                dir = unit(add(add(mul(dir, c), mul(cross(axis, dir), sn)), mul(axis, dot(axis, dir) * (1.0 - c))));
              }
            }
          }
          const Vec3 nq = add(q, mul(dir, step));
          if (!inreg(nq)) break;
          q = nq;
          travelled += step;
          path.push_back(q);
          must.push_back(0);
          // weld onto any other strand crossed (not a tie, not the one last welded to)
          if (dist(q, last_weld) > 2.0 * r0) {
            const Near w = nearest(q, std::max(2.0 * r0, 0.75 * step), static_cast<int>(ci), last_line, false, true, true);
            if (w.found && w.line != static_cast<int>(ci)) {
              path.back() = w.hit;
              must.back() = 1;
              q = w.hit;
              ++welds;
              last_line = w.line;
              last_weld = w.hit;
            }
          }
          // stop on another tie, welded to it
          if (travelled > sep(p)) {
            const Near tv = nearest(q, kCrowdedRatio * sep(q), -2, -2, true);
            if (tv.found) {
              path.push_back(tv.hit);
              must.push_back(1);
              ++welds;
              break;
            }
          }
        }
        double path_mm = 0.0;
        for (std::size_t k = 1; k < path.size(); ++k) path_mm += dist(path[k], path[k - 1]);
        laid_mm_ += path_mm;
        if (welds < 1) { ++rep_.ties_refused_reach; rep_.cut_nothing_mm += path_mm; continue; }
        // free vertices thinned to 8 r apart; welds always stay
        {
          const double keep_d = kTieThinRadii * r0;
          std::vector<Vec3> thin;
          std::vector<char> tm;
          std::size_t next_must = 0;
          for (std::size_t k = 0; k < path.size(); ++k) {
            if (must[k]) { thin.push_back(path[k]); tm.push_back(1); continue; }
            next_must = std::max(next_must, k);
            while (next_must < path.size() && !must[next_must]) ++next_must;
            const double to_next = next_must < path.size() ? dist(path[next_must], path[k]) : 1e9;
            if (dist(path[k], thin.back()) >= keep_d && to_next >= keep_d) { thin.push_back(path[k]); tm.push_back(0); }
          }
          // what thinning removes is not length cut: the thinned path is what is laid
          double thin_mm = 0.0;
          for (std::size_t k = 1; k < thin.size(); ++k) thin_mm += dist(thin[k], thin[k - 1]);
          laid_mm_ += thin_mm - path_mm;
          path.swap(thin);
          must.swap(tm);
        }
        // pieces between welds
        std::vector<std::size_t> at;
        for (std::size_t k = 0; k < path.size(); ++k)
          if (must[k]) at.push_back(k);
        double tail = 0.0;
        for (std::size_t k = at.back() + 1; k < path.size(); ++k) tail += dist(path[k], path[k - 1]);
        rep_.cut_nothing_mm += tail;
        bool any = false;
        int open = -1;
        for (std::size_t w = 0; w + 1 < at.size(); ++w) {
          double lowest = std::numeric_limits<double>::infinity(), piece = 0.0;
          for (std::size_t k = at[w] + 1; k < at[w + 1]; ++k) lowest = std::min(lowest, h(path[k]));
          for (std::size_t k = at[w] + 1; k <= at[w + 1]; ++k) piece += dist(path[k], path[k - 1]);
          const bool dip = lowest < std::min(h(path[at[w]]), h(path[at[w + 1]])) - 1e-9;
          if (dip) {
            ++rep_.ties_refused_support;
            rep_.cut_unsupported_mm += piece;
            open = -1;
            continue;
          }
          if (open < 0) {
            open = new_line(path[at[w]], static_cast<int>(ci), 1, true);
          }
          for (std::size_t k = at[w] + 1; k <= at[w + 1]; ++k) {
            Line& L = lines_[static_cast<std::size_t>(open)];
            L.pts.push_back(path[k]);
            stamp_segment(open, L.pts.size() - 2);
          }
          any = true;
        }
        if (any) ++rep_.ties_laid;
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
  lower_ = ask_.spacing_mm > 0.0 ? ask_.spacing_mm : ask_.spacing_min_mm;
  sep_hi_ = ask_.spacing_mm > 0.0 ? ask_.spacing_mm : ask_.spacing_max_mm;
  cone_sin_ = std::sin(kConeDeg * kPi / 180.0);
  cone_cos_ = std::cos(kConeDeg * kPi / 180.0);
  bed_ = std::numeric_limits<double>::infinity();
  for (const Vec3& p : domain_.measure().mesh().vertices) bed_ = std::min(bed_, h(p));
  {
    const Vec3 lo = sub(field_.origin, Vec3{sep_hi_, sep_hi_, sep_hi_});
    const Vec3 hi = add(field_.origin, Vec3{field_.nx * field_.spacing + sep_hi_, field_.ny * field_.spacing + sep_hi_,
                                            field_.nz * field_.spacing + sep_hi_});
    boxes_.init(lo, hi, 2.0);
  }
  std::vector<Tip> tips;
  seeds(tips);
  grow(std::move(tips));
  if (ask_.ties) ties();
  repeats();
  thin();
  for (int round = 0; round < kRegrowRounds; ++round) {
    // The path's pruning: what it drops is no longer material for the regrowth (it stays in the plant returned,
    // and the path drops it again).
    const Fate f = pass();
    for (std::size_t l = 0; l < lines_.size(); ++l)
      for (std::size_t k = 0; k < f.seg[l].size(); ++k) lines_[l].dead[k] = f.seg[l][k] != 0;
    std::vector<Tip> more;
    regrow_holes(more);
    if (more.empty()) break;
    ++rep_.regrow_rounds;
    grow(std::move(more));
    if (ask_.ties) ties();
    repeats();
    thin();
  }
  account(pass());   // what the path keeps of the strands returned, and what it cuts
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
