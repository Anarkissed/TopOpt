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
  crowded_climbed_on += o.crowded_climbed_on; joined_dense += o.joined_dense; leaned += o.leaned;
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
constexpr double kCrowdedRatio = 0.5;                        // G9: a tie is not seeded within 0.5 x spacing of a tie
constexpr double kJoinRunMm = 3.0;                           // G5: GR-REWIND's join, when no turn has room, runs 3 mm or less
constexpr double kBranchEveryRatio = 0.5;                    // G6: a branch offered every 0.5 x spacing of climb
constexpr double kHoleRatio = 1.5;                           // G11: a hole is 1.5 x the local spacing from anything
constexpr int kRegrowRounds = 4;                             // G11 (LatticeReview's ruling 4, 2026-11-15)
constexpr double kTieMinorRatio = 0.10;                      // G9: |sigma2| / |sigma1| at least this
constexpr double kTieSwirlDeg = 28.0, kTieSwirlWavelengthRatio = 3.5;   // G9, G3 (rule F's lean)
// The new numbers (GR-REWIND, G5; G10):
constexpr double kRewindTurnDeg = 35.0;
constexpr int kRewindTries = 3;
constexpr double kRepeatMm = 0.02;
// The rulings of 2026-11-15 (brief G3, rules A to H):
constexpr double kDenseRatio = 0.6;        // G5 (rule C): too dense for the place = within 0.6 x d, where that is over L
constexpr double kBranchRoomRatio = 0.9;   // G6 (rule D): room = nothing within 0.9 x d of the point one d out
constexpr double kSteepestDeg = 78.0;      // G3 (rule F): a vine never steeper than this from level (leans 12 degrees)
constexpr double kTieClimbDeg = 35.0;      // G9 (rule G): a tie climbs at least this from level
constexpr double kTieLengthRatio = 1.5;    // G9 (rule G): a tie no longer than 1.5 x d
// LatticeReview's rulings of 2026-11-15 (after the third build's first report):
constexpr double kBranchLeaveDeg = 45.0;   // G6 (rule E as amended): a branch leaves its parent at 45 degrees or more
constexpr double kBranchClearRatio = 1.5;  // G6 (rule E as amended): L clear of its parent within 1.5 x d of the fork
constexpr double kSeedStrideRatio = 1.15;  // G2 (rule A): seeds 1.15 x L apart, so a 12 degree lean keeps fresh neighbours past L
constexpr double kLeanTurnPeriod = 4.0;    // G3 (rule F): with no level stress to lean toward, the lean turns once per 4 d

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
  double hold = 0.0;   // a regrown branch holds its aim this far (G11, ruling 4)
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
  double cone_sin_ = 0.5, cone_cos_ = 0.0, steep_sin_ = 1.0, steep_cos_ = 0.0;
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

  // The nearest point of any other strand within R of q: not `self`, not a strand grown from `self` within the lower
  // limit of where that starts. `parent`: with no `part`, not that strand at all; with `part` (growth, G5 rule E), not
  // the parent, nor a sibling (a strand of the same parent starting at the same point), within one local spacing of
  // `part`, the point where they part; beyond that they count as any strand. The first of equally near ones, in the
  // boxes' order. Every strand of the plant counts (growth keeps its spacing to all of them, those the path will drop
  // included); `live_only`: only what the path keeps.
  Near nearest(const Vec3& q, double R, int self, int parent, bool ties_only = false, bool no_ties = false,
               bool live_only = false, const Vec3* part = nullptr) const {
    Near out;
    const double part_sep = part ? sep(*part) : 0.0;
    boxes_.near(q, R + ds_, [&](const Sample& s) {
      if (s.line == self || (!part && s.line == parent) || !(live_only ? live(s) : current(s))) return;
      const Line& L = lines_[static_cast<std::size_t>(s.line)];
      if ((ties_only && !L.tie) || (no_ties && L.tie)) return;
      const Vec3 c = closest_on(q, L.pts[static_cast<std::size_t>(s.seg)], L.pts[static_cast<std::size_t>(s.seg) + 1]);
      if (self >= 0 && L.parent == self && dist(c, L.pts.front()) <= lower_) return;   // grown from it, at its root
      if (part && parent >= 0 &&
          (s.line == parent || (L.parent == parent && !L.pts.empty() && dist(L.pts.front(), *part) < 1e-6)) &&
          dist(c, *part) <= part_sep)
        return;   // its parent or a sibling, near where they part (rule E)
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

  // The distance from q to strand `line` (its segments still on it), looked for within R; infinity beyond.
  // The distance from q to the nearest other strand than `self` (not ties excepted), its segments still on it, within 1 mm.
  double to_current_other(const Vec3& q, int self) const {
    double best = std::numeric_limits<double>::infinity();
    boxes_.near(q, 1.0 + ds_, [&](const Sample& s) {
      if (s.line == self || !current(s)) return;
      const Line& L = lines_[static_cast<std::size_t>(s.line)];
      best = std::min(best, dist(q, closest_on(q, L.pts[static_cast<std::size_t>(s.seg)], L.pts[static_cast<std::size_t>(s.seg) + 1])));
    });
    return best;
  }
  double to_current(const Vec3& q, int line, double R) const {
    double best = std::numeric_limits<double>::infinity();
    boxes_.near(q, R + ds_, [&](const Sample& s) {
      if (s.line != line || !current(s)) return;
      const Line& L = lines_[static_cast<std::size_t>(s.line)];
      best = std::min(best, dist(q, closest_on(q, L.pts[static_cast<std::size_t>(s.seg)], L.pts[static_cast<std::size_t>(s.seg) + 1])));
    });
    return best;
  }
  // G5 (rule C): where a tip at p joins strand `line`: its nearest point within `most` of p that lies at the cone or
  // steeper above p. False when there is none.
  bool landing(const Vec3& p, int line, double most, Vec3& at) const {
    double best = std::numeric_limits<double>::infinity();
    boxes_.near(p, most + ds_, [&](const Sample& s) {
      if (s.line != line || !current(s)) return;
      const double d = dist(p, s.p);
      if (d > most || d < 1e-9 || dot(sub(s.p, p), up_) < cone_sin_ * d - 1e-12) return;
      if (d < best) { best = d; at = s.p; }
    });
    return best < std::numeric_limits<double>::infinity();
  }
  // G9, G3 (rule F): the transfer tie's direction at p, the old code's closed form: the second principal direction
  // (sign as `principal` gives it) turned by the swirl (28 degrees x tie_swirl x the phase, wavelength 3.5 spacings)
  // about the axis across it and the major direction. False where there is no stress.
  bool swirl(const Vec3& p, Vec3& dir) const {
    double ev[3];
    Vec3 f3[3];
    if (!frame(p, ev, f3)) return false;
    dir = f3[1];
    if (ask_.tie_swirl > 0.0) {
      const double lam = kTieSwirlWavelengthRatio * sep(p);
      const double k1 = 2.0 * kPi / lam, k2 = k1 * 0.618, k3 = k1 * 1.414;
      const double phase = std::sin(k1 * p.x + 0.7) * std::cos(k2 * p.z + 1.9) +
                           0.5 * std::sin(k3 * (p.x + p.z) + 0.3) * std::cos(k1 * p.y + 2.4);
      const double ang = ask_.tie_swirl * kTieSwirlDeg * kPi / 180.0 * std::clamp(phase, -1.0, 1.0);
      const Vec3 axis = unit(cross(dir, f3[0]));
      if (len(axis) > 1e-9) {
        const double c = std::cos(ang), sn = std::sin(ang);
        dir = unit(add(add(mul(dir, c), mul(cross(axis, dir), sn)), mul(axis, dot(axis, dir) * (1.0 - c))));
      }
    }
    return len(dir) > 1e-9;
  }
  // G3 (rule F, the owner's OR23: "The struts shouldn't be going straight up"): a heading steeper than 78 degrees from
  // level is held at 78, leaning toward the level part of the stress direction at p; where that is under a tenth of
  // it (or there is no stress), toward the direction turned about the build direction by 2 pi (x + y) / (4 d) from the
  // first in-plane axis (x, y the point's in-plane coordinates, d the local spacing; LatticeReview's ruling 2), so
  // neighbours lean different ways and cross.
  Vec3 lean(const Vec3& want, const Vec3& p) {
    if (dot(want, up_) <= steep_sin_ + 1e-12) return want;
    Vec3 hdir{0, 0, 0}, f;
    if (stress_dir(p, f) && len(level(f)) >= 0.1 * len(f)) hdir = unit(level(f));
    if (len(hdir) < 0.5) {
      const double a = 2.0 * kPi * (dot(p, u_) + dot(p, v_)) / (kLeanTurnPeriod * sep(p));
      hdir = add(mul(u_, std::cos(a)), mul(v_, std::sin(a)));
    }
    ++rep_.leaned;
    return add(mul(up_, steep_sin_), mul(hdir, steep_cos_));
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
  bool turn(const Vec3& at, int li, int parent, const Vec3& part, const Vec3& heading, const std::vector<Vec3>& tried,
            Vec3& out) const;
  void offer_branches(int li, const Vec3& p, const Vec3& dir, std::size_t& floor_idx, std::vector<Tip>& tips);
  std::vector<int> links_made_;   // by the tip growing now
  void repeats();
  void thin();
  void settle();
  struct Fate {
    std::vector<std::vector<char>> seg;   // per line, per segment: 0 kept, 1 outside, 2 nothing, 3 unsupported
    std::vector<double> bar_mm;           // per line: the length of its bars the path keeps (G12, ruling 5)
  };
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
        const std::pair<long long, long long> key{static_cast<long long>(std::floor(dot(c, u_) / hv)),
                                                  static_cast<long long>(std::floor(dot(c, v_) / hv))};
        auto it = low.find(key);
        if (it == low.end() || h(c) < it->second.first) low[key] = {h(c), c};
      }
  // G2 (amended 2026-11-15, rule A; the owner's OR31: "Might it be important to seed more than what you expect to
  // have, assuming a lot will be pruned? There are so few seeds on the base. It needs to be filled."): seeds on rows
  // L apart across the build plane, L apart along a row, alternate rows offset by half of it (L the window's lower
  // limit, whatever the local spacing). A point is seeded where its column (the nearest one) has candidates: at the
  // height of the column's lowest, moved down to the region's edge. No room test.
  if (low.empty()) return;
  double ua = std::numeric_limits<double>::infinity(), ub = -ua, va = ua, vb = -ua;
  for (const auto& kv : low) {
    const Vec3 c = kv.second.second;
    ua = std::min(ua, dot(c, u_) - 0.5 * hv); ub = std::max(ub, dot(c, u_) + 0.5 * hv);
    va = std::min(va, dot(c, v_) - 0.5 * hv); vb = std::max(vb, dot(c, v_) + 0.5 * hv);
  }
  const double stride = kSeedStrideRatio * lower_;
  std::vector<Vec3> taken;   // the seeds' own points (the walls keep L from them)
  const int rows = static_cast<int>(std::floor((vb - va) / stride + 1e-9));
  for (int r = 0; r <= rows; ++r) {
    const double vv = va + 0.5 * stride + r * stride;
    if (vv > vb) break;
    const double off = (r % 2) ? 0.5 * stride : 0.0;
    for (double uu = ua + 0.5 * stride + off; uu <= ub + 1e-9; uu += stride) {
      auto it = low.find({static_cast<long long>(std::floor(uu / hv)), static_cast<long long>(std::floor(vv / hv))});
      if (it == low.end()) continue;
      const Vec3 cc = it->second.second;
      Vec3 c = add(cc, add(mul(u_, uu - dot(cc, u_)), mul(v_, vv - dot(cc, v_))));
      if (!inreg(c)) c = cc;
      const Vec3 down = mul(up_, -1.0);
      const double at = edge(c, down, 2.0 * hv);
      const Vec3 on = at >= 0.0 ? add(c, mul(down, at)) : c;
      taken.push_back(on);
      Tip t;
      t.kind = Tip::Floor;
      // Its foot leaves the floor in its first heading (G3: the stress, the pull upward, the cone, rule F's lean) and
      // its root runs back along it into the solid by its width.
      Vec3 f;
      Vec3 w = stress_dir(on, f) ? add(mul(up_, kBlendHeading), mul(f, kBlendField)) : up_;
      w = unit(add(w, mul(up_, kUpwardBias)));
      if (dot(w, up_) < cone_sin_) {
        const Vec3 side = unit(level(w));
        w = len(side) > 0.5 ? add(mul(side, cone_cos_), mul(up_, cone_sin_)) : up_;
      }
      t.dir = lean(w, on);
      t.root = at < 0.0 ? c : solid(sub(on, mul(t.dir, width_ + 0.06))) ? sub(on, mul(t.dir, width_)) : on;
      t.target = on;
      t.from = on;
      tips.push_back(t);
      ++rep_.seeds_floor;
    }
  }
  if (!ask_.walls_out) return;
  auto room_for = [&](const Vec3& p) {   // rule A on the walls: no two seeds closer than L
    for (const Vec3& q : taken)
      if (dist(p, q) < stride - 1e-9) return false;
    return true;
  };
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
    // Rule A (LatticeReview's ruling, 2026-11-15): no wall seed within one stride of a corner, where its wall meets
    // another wall: along the wall, either way, the region's edge with the solid past it lies that near.
    bool corner = false;
    const Vec3 along = unit(cross(up_, w.w));
    for (int sg = -1; sg <= 1 && !corner; sg += 2) {
      const Vec3 dir = mul(along, sg);
      const double e = edge(w.c, dir, stride);
      corner = e >= 0.0 && solid(add(w.c, mul(dir, e + 0.06)));
    }
    if (corner) continue;
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
bool Grower::turn(const Vec3& at, int li, int parent, const Vec3& part, const Vec3& heading,
                  const std::vector<Vec3>& tried, Vec3& out) const {
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
    const Near n = nearest(add(at, mul(d, s)), look, li, parent, false, false, false, &part);
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
  // of the build plane where there is no stress), leaving at the cone. One branch is offered, to the side with the
  // more room (rule D).
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
  const double d = sep(p);
  ++rep_.branches_offered;
  int best_sgn = 0, why = 0;   // why: 1 out of the region, 2 unsupported
  double best_room = -1.0;
  Vec3 best_dir{}, best_target{};
  for (int sgn = -1; sgn <= 1; sgn += 2) {
    const Vec3 bdir = add(mul(side, sgn * cone_cos_), mul(up_, cone_sin_));
    // G6 (rule E as amended, LatticeReview's ruling 1): a branch leaves its parent at 45 degrees or more from the
    // parent's direction at the fork.
    if (dot(bdir, unit(dir)) > std::cos(kBranchLeaveDeg * kPi / 180.0) + 1e-12) { why = std::max(why, 1); continue; }
    const Vec3 bq = add(p, mul(bdir, layer_ / cone_sin_));
    const Vec3 target = add(p, mul(bdir, d));
    if (!inreg(bq) || !inreg(target)) { why = std::max(why, 1); continue; }
    if (!supported(bq)) { why = 2; continue; }
    // G6 (rule D): room = no other strand within 0.9 x d of the point one d out along its first direction; the strand
    // it grows from is its parent (rule E).
    const double look = kBranchRoomRatio * d;
    const Near n = nearest(target, look, li, -1);
    const double room = n.found ? n.d : look + 1.0;
    if (room > best_room) {
      best_room = room;
      best_sgn = sgn;
      best_dir = bdir;
      best_target = target;
    }
  }
  if (best_sgn == 0) {
    if (why == 2) ++rep_.refused_support; else ++rep_.refused_region;
    return;
  }
  if (best_room < kBranchRoomRatio * d) { ++rep_.refused_room; return; }
  Tip t;
  t.kind = Tip::Branch;
  t.root = p;
  t.from = p;
  t.dir = best_dir;
  t.target = best_target;
  t.parent = li;
  t.family = (me.family + 1) % 3;
  tips.push_back(t);
  floor_idx = lines_[static_cast<std::size_t>(li)].pts.size() - 1;
}

void Grower::grow_tip(const Tip& t, std::vector<Tip>& tips) {
  // G7 (rule D), asked again at its turn for a branch or a regrown tip: no other strand (its parent and siblings
  // near where they part not counted, rule E) within 0.9 x d of the point one d out along its first direction (a
  // regrown tip's: up). A seed has no room test (rule A).
  if (t.kind == Tip::Branch || t.kind == Tip::Regrow) {
    const double d = sep(t.from);
    const Vec3 ahead = add(t.from, mul(unit(t.dir), d));
    const Near n = nearest(ahead, kBranchRoomRatio * d, -1, t.parent, false, false, false, &t.from);
    if (n.found) {
      if (t.kind == Tip::Branch) ++rep_.refused_room;
      else ++rep_.regrow_failed;
      return;
    }
  }
  // A branch (or a regrown branch) whose fork is no longer on its parent (taken back since it was offered) does not grow.
  const bool branchy = t.kind == Tip::Branch || (t.kind == Tip::Regrow && t.parent >= 0);
  if (branchy && !(to_current(t.from, t.parent, 1e-6) < 1e-6)) {
    if (t.kind == Tip::Branch) ++rep_.refused_room;
    else ++rep_.regrow_failed;
    return;
  }
  const int li = new_line(t.root, t.parent, t.family);
  int parent = t.parent;
  // G6 (rule E as amended, LatticeReview's ruling 1): a branch is exempt from its parent only until it is first L from
  // it; while exempt it holds its first direction and its distance to the parent never shrinks; not L clear within
  // 1.5 x d of the fork: taken back, it does not grow.
  bool exempt = branchy, aborted = false;
  double parent_gap = 0.0;
  // A seed starts on the region's edge; its first point is run into the solid by its width (as O4 runs an end), so
  // its first segment crosses the edge and weave_bars cuts it there and finds it Solid.
  const Vec3 start = t.from;
  Vec3 p = start, dir = t.dir;
  std::size_t floor_idx = 0;   // never rewound past (G5)
  double since_branch = 0.0;
  // The first step of a branch (and of a wall seed) is the direction it was offered in; a turn holds for one spacing.
  double hold = (t.kind == Tip::Branch || t.kind == Tip::Wall) ? 1e-9 : 0.0;
  Vec3 hold_dir = t.dir;
  // A tip that starts on the floor's solid (a floor seed, or a regrown tip that landed on the solid) climbs its first two widths
  // straight on in its seed's direction (its foot): its first segment, run into the solid by its width, then crosses
  // the region's edge in one line and leaves a piece in the lattice longer than its width, so weave_bars finds that
  // end Solid and does not drop it as a stub (S4). It is never rewound past its foot.
  bool foot = t.kind == Tip::Floor || (t.kind == Tip::Regrow && t.parent < 0);
  if (foot) hold = 2.0 * width_;
  if (t.hold > 0.0) hold = t.hold;
  std::map<std::size_t, std::vector<Vec3>> tried;
  long long open_place = -1;
  bool first = true;
  const int layers = static_cast<int>(std::ceil((domain_.measure().diagonal_mm() + 1.0) / layer_)) + 4;
  const long long guard = 16LL * layers;
  enum End { Edge, Unsupported, Joined, GaveUp, Guard } how = Guard;
  for (long long it = 0; it < guard; ++it) {
    Vec3 want;
    if (exempt) {
      want = lean(hold_dir, p);
    } else if (hold > 0.0) {
      want = foot ? hold_dir : lean(hold_dir, p);
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
      want = lean(want, p);   // G3 (rule F)
    }
    const double rise = std::max(dot(want, up_), 1e-9);
    const Vec3 q = add(p, mul(want, layer_ / rise));
    if (exempt) {
      const double g = to_current(q, t.parent, lower_ + 1.0);
      if (g < parent_gap - 1e-9 || dist(q, start) > kBranchClearRatio * sep(start)) {
        aborted = true;
        break;
      }
      parent_gap = g;
      if (g >= lower_) {   // L clear: from here parent and branch are judged as any two strands
        exempt = false;
        parent = -1;
        lines_[static_cast<std::size_t>(li)].parent = -1;
      }
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
    const double dense = kDenseRatio * s;
    const Near n = nearest(q, std::max(lower_, dense), li, parent, false, false, false, &start);
    if (n.found && (n.d < lower_ || (dense > lower_ && n.d < dense))) {
      const double run = len(level(sub(n.hit, p)));
      if (n.d >= lower_) {
        // G5 (rule C): too dense for the place. The tip joins the neighbour where the run to it is at most d and
        // climbs at the cone or steeper, and ends there (two vines merge into one); else it grows on.
        Vec3 at;
        if (landing(p, n.line, s, at)) {
          lay(li, at);
          ++rep_.joined_dense;
          how = Joined;
          break;
        }
        ++rep_.crowded_climbed_on;
      } else if (exempt) {
        aborted = true;   // a branch still leaving its parent is not rewound: it does not grow
        break;
      } else {
        // GR-REWIND: back to the last point that had its local spacing to every other strand, never past the floor.
        Line& L = lines_[static_cast<std::size_t>(li)];
        std::size_t back = floor_idx;
        for (std::size_t k = L.pts.size() - 1; k > floor_idx; --k) {
          const double sk = sep(L.pts[k]);
          const Near m = nearest(L.pts[k], sk, li, parent, false, false, false, &start);
          if (!m.found || m.d >= sk) { back = k; break; }
        }
        std::vector<Vec3>& here = tried[back];
        Vec3 d;
        const bool can = static_cast<int>(here.size()) < kRewindTries &&
                         turn(back == 0 ? start : L.pts[back], li, parent, start, dir, here, d);
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
            // LatticeReview's ruling 2: back to its seed (or the fork it grew from); the branches it offered grow only
            // after it, so none has grown yet, and those it offered on what is taken back do not grow.
            rep_.cut_crowded_mm += take_back(li, 0);
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
        if (foot && lines_[static_cast<std::size_t>(li)].pts.size() == 1) {
          // Rewound to its seed: its foot is laid again in the new direction (held to 78 degrees, rule F), its root
          // run back along it into the solid.
          hold_dir = dir = lean(d, start);
          hold = 2.0 * width_;
          Vec3& root = lines_[static_cast<std::size_t>(li)].pts[0];
          if (dist(root, start) > 1e-9) root = sub(start, mul(dir, width_));
        }
        since_branch = 0.0;
        continue;
      }
    }
    lay(li, q);
    first = false;
    ++rep_.steps;
    const double stepped = dist(p, q);
    since_branch += stepped;
    if (hold > 0.0) hold = std::max(0.0, hold - stepped);
    if (foot && hold <= 0.0) {
      foot = false;
      floor_idx = lines_[static_cast<std::size_t>(li)].pts.size() - 1;
    }
    p = q;
    dir = want;
    if (since_branch >= std::max(stepped, kBranchEveryRatio * sep(p))) {
      since_branch = 0.0;
      offer_branches(li, p, dir, floor_idx, tips);
    }
  }
  if (aborted) {
    laid_mm_ -= take_back(li, 0);
    if (t.kind == Tip::Branch) ++rep_.refused_room;
    else ++rep_.regrow_failed;
    links_made_.clear();
    return;
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
  settle();
}

// LatticeReview's ruling 2: a vine never ends in mid-air with nothing joined to it. A strand (not a tie) whose upper
// end is not held (past the region's edge a hair on, or on another strand) is cut back to its last joint: the
// farthest place along it where another strand's end lies on it; with none, the strand goes. Repeated until no cut
// leaves another end loose.
void Grower::settle() {
  auto edge_held = [&](const Vec3& e) {
    static const Vec3 off[6] = {{0.05, 0, 0}, {-0.05, 0, 0}, {0, 0.05, 0}, {0, -0.05, 0}, {0, 0, 0.05}, {0, 0, -0.05}};
    for (const Vec3& o : off)
      if (!inreg(add(e, o))) return true;
    return false;
  };
  for (int round = 0; round < 8; ++round) {
    bool changed = false;
    for (std::size_t l = 0; l < lines_.size(); ++l) {
      Line& L = lines_[l];
      if (L.tie || L.pts.size() < 2) continue;
      const Vec3 e = L.pts.back();
      if (edge_held(e) || to_current_other(e, static_cast<int>(l)) < 1e-6) continue;
      // the farthest joint along it: another strand's end on one of its segments
      std::size_t seg = 0;
      double tt = -1.0;
      Vec3 at{};
      for (std::size_t o = 0; o < lines_.size(); ++o) {
        if (o == l || lines_[o].pts.size() < 2) continue;
        for (const Vec3& x : {lines_[o].pts.front(), lines_[o].pts.back()})
          for (std::size_t k = 0; k + 1 < L.pts.size(); ++k) {
            const Vec3 c = closest_on(x, L.pts[k], L.pts[k + 1]);
            if (dist(c, x) >= 1e-6) continue;
            const double ab = dist(L.pts[k], L.pts[k + 1]);
            const double f = ab > 0.0 ? dist(L.pts[k], c) / ab : 0.0;
            if (static_cast<double>(k) + f > static_cast<double>(seg) + tt) { seg = k; tt = f; at = x; }
          }
      }
      double gone = 0.0;
      if (tt < 0.0) {
        gone = take_back(l, 0);
      } else {
        gone = take_back(l, seg + 1);   // keeps points 0..seg+1, then ends it at the joint
        Line& M = lines_[l];
        gone += dist(M.pts[seg], M.pts[seg + 1]) - dist(M.pts[seg], at);
        M.pts.back() = at;
        stamp_segment(static_cast<int>(l), seg);
        if (dist(M.pts[seg], at) < 1e-9) { M.pts.pop_back(); M.stamp.pop_back(); M.dead.pop_back(); }
      }
      rep_.cut_nothing_mm += gone;   // laid, then cut: leads to nothing
      changed = true;
    }
    if (!changed) break;
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
  // LatticeReview's ruling 3: the kept copy takes over every join and root that pointed at a dropped copy: an end that
  // lay on another strand before and lies on none now is moved onto the nearest strand within the repeat distance.
  bool moved = false;
  for (std::size_t l = 0; l < lines_.size(); ++l) {
    Line& L = lines_[l];
    if (L.pts.size() < 2) continue;
    for (int end = 0; end < 2; ++end) {
      Vec3& e = end ? L.pts.back() : L.pts.front();
      bool was = false;
      for (const Vec3& j : joints) was = was || dist(j, e) < 1e-9;
      if (!was) continue;
      Near on;
      boxes_.near(e, near_mm + ds_, [&](const Sample& x) {
        if (static_cast<std::size_t>(x.line) == l || !current(x)) return;
        const Line& O = lines_[static_cast<std::size_t>(x.line)];
        const Vec3 c = closest_on(e, O.pts[static_cast<std::size_t>(x.seg)], O.pts[static_cast<std::size_t>(x.seg) + 1]);
        const double dd = dist(c, e);
        if (dd <= near_mm + 1e-6 && dd < on.d) { on.found = true; on.d = dd; on.hit = c; }
      });
      if (on.found && on.d > 1e-6) { e = on.hit; moved = true; }
    }
  }
  if (moved) rebuild_boxes();
}

// G10, pruning step 4, thinning to the window: where a stretch of one strand lies closer than the lower limit to
// another, away from any joint of the two (a place within the lower limit where they touch: a crossing, a branch's
// root, a join or a link), the strand carrying less stress along it (the mean of |t . sigma . t| over its length;
// the earlier of equals stays) is left out there; each end that leaves is joined into the other when the run is 3 mm
// or less, else cut. LatticeReview's ruling 3 (2026-11-15): a strand another strand stands on or has joined into (an
// end of it lies on this one: a join, a branch's root, a tie, a regrown tip) is never cut; of two too close, the one
// nothing depends on goes (both carrying others: neither). An end a cut leaves that is not joined is cut back to its
// last joint (a place another strand touches it); no joint: the piece goes. No loose end remains.
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
  std::vector<char> carries(nl, 0);
  for (std::size_t l = 0; l < nl; ++l) {
    const Line& E = lines_[l];
    if (E.pts.size() < 2) continue;
    for (const Vec3& e : {E.pts.front(), E.pts.back()})
      boxes_.near(e, ds_ + 1e-6, [&](const Sample& x) {
        if (static_cast<std::size_t>(x.line) == l || !live(x)) return;
        const Line& O = lines_[static_cast<std::size_t>(x.line)];
        if (dist(e, closest_on(e, O.pts[static_cast<std::size_t>(x.seg)], O.pts[static_cast<std::size_t>(x.seg) + 1])) < 1e-6)
          carries[static_cast<std::size_t>(x.line)] = 1;
      });
  }
  // of the pair: does `l` go for `a`?
  auto goes = [&](std::size_t l, std::size_t a) { return !carries[l] && (carries[a] || stronger(a, l)); };
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
          if (goes(l, static_cast<std::size_t>(A))) {
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
      if (!(best < std::numeric_limits<double>::infinity() && len(level(sub(to, e))) <= kJoinRunMm)) return false;
      // Ruling 3: the join keeps the lower limit to every other strand (it is a strut like any other); else the end is
      // cut back instead.
      const int n = std::max(1, static_cast<int>(std::ceil(dist(e, to) / ds_)));
      for (int q = 0; q <= n; ++q)
        if (nearest(add(e, mul(sub(to, e), static_cast<double>(q) / n)), lower_, static_cast<int>(l), static_cast<int>(by),
                    false, true, true).found)
          return false;
      return true;
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
      bool loose_front = false, loose_back = false;
      if (s0 > 0) {
        if (join_end(cut[l][s0 - 1].by, run.pts.front(), to) && dist(to, run.pts.front()) > 1e-9) {
          laid_mm_ += dist(to, run.pts.front());
          run.pts.insert(run.pts.begin(), to);
          run.dead.insert(run.dead.begin(), 0);
          ++rep_.thinned_joined;
        } else {
          loose_front = true;
        }
      }
      if (k < ns) {
        if (join_end(cut[l][k].by, run.pts.back(), to) && dist(to, run.pts.back()) > 1e-9) {
          laid_mm_ += dist(to, run.pts.back());
          run.pts.push_back(to);
          run.dead.push_back(0);
          ++rep_.thinned_joined;
        } else {
          loose_back = true;
        }
      }
      // Ruling 3: a loose end is cut back to the run's last joint.
      auto joint = [&](const Vec3& x) {
        bool j = false;
        boxes_.near(x, width_ + ds_, [&](const Sample& y) {
          if (j || static_cast<std::size_t>(y.line) == l || !live(y)) return;
          const Line& O = lines_[static_cast<std::size_t>(y.line)];
          j = dist(x, closest_on(x, O.pts[static_cast<std::size_t>(y.seg)], O.pts[static_cast<std::size_t>(y.seg) + 1])) < width_;
        });
        return j;
      };
      std::size_t lo = 0, hi = run.pts.size() - 1;
      if (loose_front) {
        while (lo < hi && !joint(run.pts[lo])) ++lo;
      }
      if (loose_back) {
        while (hi > lo && !joint(run.pts[hi])) --hi;
      }
      if (lo > 0 || hi + 1 < run.pts.size()) {
        double gone = 0.0;
        for (std::size_t q = 0; q + 1 < run.pts.size(); ++q)
          if (q < lo || q >= hi) gone += dist(run.pts[q], run.pts[q + 1]);
        rep_.cut_crowded_mm += gone;
        if (hi <= lo) continue;
        Line keep;
        keep.family = run.family;
        keep.tie = run.tie;
        keep.pts.assign(run.pts.begin() + static_cast<long>(lo), run.pts.begin() + static_cast<long>(hi) + 1);
        keep.dead.assign(run.dead.begin() + static_cast<long>(lo), run.dead.begin() + static_cast<long>(hi));
        run = std::move(keep);
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

// G11, pruning step 5: holes the pruning leaves, regrown (up to 4 rounds, LatticeReview's ruling 4). A hole is a
// candidate voxel centre (on a stride of half the median spacing) with nothing within 1.5 x its spacing, one per 1.5
// spacings. Into each, a branch from the nearest point of a kept strand (not a tie) below the hole's centre, aimed at
// the centre (held up to the cone where the aim is flatter), holding that aim to the centre (at most one spacing);
// judged by rule D's room test at its far end only, then grown by every rule above. With no kept strand below: as
// before, straight down along the build direction to the first place a strut would be held, a tip starting there.
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
    {
      const double d = sep(q);
      const double look = 4.0 * d;
      Near best;
      int best_seg = -1;
      boxes_.near(q, look + ds_, [&](const Sample& x) {
        if (!live(x) || lines_[static_cast<std::size_t>(x.line)].tie || h(x.p) > h(q) - layer_) return;
        const double dd = dist(x.p, q);
        if (dd <= look && dd < best.d) { best.found = true; best.d = dd; best.hit = x.p; best.line = x.line; best_seg = x.seg; }
      });
      if (best.found) {
        Vec3 aim = unit(sub(q, best.hit));
        // Rule E as amended: nearer the parent's direction at the fork than 45 degrees, it is turned to 45 degrees, on
        // the hole's side; then held up to the cone.
        const Line& P = lines_[static_cast<std::size_t>(best.line)];
        const Vec3 pd = unit(sub(P.pts[static_cast<std::size_t>(best_seg) + 1], P.pts[static_cast<std::size_t>(best_seg)]));
        const double c45 = std::cos(kBranchLeaveDeg * kPi / 180.0);
        if (dot(aim, pd) > c45) {
          Vec3 across = sub(aim, mul(pd, dot(aim, pd)));
          if (len(across) < 1e-9) across = cross(pd, std::fabs(dot(pd, u_)) < 0.9 ? u_ : v_);
          aim = unit(add(mul(pd, c45), mul(unit(across), std::sin(kBranchLeaveDeg * kPi / 180.0))));
        }
        if (dot(aim, up_) < cone_sin_) {
          const Vec3 side = unit(level(aim));
          aim = len(side) > 0.5 ? add(mul(side, cone_cos_), mul(up_, cone_sin_)) : up_;
        }
        if (dot(aim, pd) > c45 + 1e-9) { ++rep_.regrow_failed; continue; }
        Tip t;
        t.kind = Tip::Regrow;
        t.root = t.from = best.hit;
        t.dir = aim;
        t.target = q;
        t.parent = best.line;
        t.family = (lines_[static_cast<std::size_t>(best.line)].family + 1) % 3;
        t.hold = std::min(best.d, d);
        tips.push_back(t);
        ++rep_.regrow_landed;
        continue;
      }
    }
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

// G9 (amended 2026-11-15, rule G): the transfer ties. Along every pillar (family 0) once per local spacing, not within
// half a spacing of another tie, where the minor stress is at least 0.10 of the major: both ways along the tie's
// direction there (the second principal direction turned by the swirl, the old closed form), a tie leaves the pillar
// and lands on a neighbouring vine at a point HIGHER up it: of the points of other vines (not ties; only what the path
// keeps, from the first regrowth on) on that side, within 1.5 x d of where it leaves and climbing to them at 35
// degrees or more from level, each vine's nearest; of those the vine lying most nearly along the tie's direction. The
// tie is straight; its ends are not moved (the vine it lands on is cut at the landing point, as every joint is). No
// such point: no tie.
void Grower::ties() {
  const std::size_t pillars = lines_.size();
  const double climb = std::sin(kTieClimbDeg * kPi / 180.0);
  for (std::size_t ci = 0; ci < pillars; ++ci) {
    if (lines_[ci].family != 0 || lines_[ci].tie || lines_[ci].pts.size() < 2) continue;
    double since = 0.0;
    const std::vector<Vec3> pc = lines_[ci].pts;
    for (std::size_t pi = 1; pi < pc.size(); ++pi) {
      since += dist(pc[pi], pc[pi - 1]);
      const Vec3 p = pc[pi];
      if (lines_[ci].dead[pi - 1]) continue;   // not on what the path drops
      const double d = sep(p);
      if (since < d) continue;
      since = 0.0;
      if (nearest(p, kCrowdedRatio * d, -1, -1, true).found) continue;   // not within half a spacing of a tie
      double ev[3];
      Vec3 fr[3];
      if (!frame(p, ev, fr)) continue;
      if (std::fabs(ev[1]) / std::fabs(ev[0]) < kTieMinorRatio) { ++rep_.ties_refused_minor; continue; }
      Vec3 tdir;
      if (!swirl(p, tdir)) continue;
      const Vec3 th = unit(level(tdir));
      for (int sgn = -1; sgn <= 1; sgn += 2) {
        ++rep_.ties_seeded;
        const double most = kTieLengthRatio * d;
        // per vine, its nearest landing point on this side
        std::map<int, std::pair<double, Vec3>> per;
        boxes_.near(p, most + ds_, [&](const Sample& x) {
          if (x.line == static_cast<int>(ci) || !live(x) || lines_[static_cast<std::size_t>(x.line)].tie) return;
          const Vec3 w = sub(x.p, p);
          const double l = len(w);
          if (l > most || l < 2.0 * width_ || dot(w, up_) < climb * l - 1e-12) return;
          if (len(th) > 0.5 && sgn * dot(level(w), th) <= 0.0) return;
          auto it = per.find(x.line);
          if (it == per.end() || l < it->second.first) per[x.line] = {l, x.p};
        });
        int pick = -1;
        double align = -2.0;
        Vec3 at{};
        for (const auto& kv : per) {   // in vine order: the first of equals
          const Vec3 lw = unit(level(sub(kv.second.second, p)));
          const double a = len(th) > 0.5 && len(lw) > 0.5 ? sgn * dot(lw, th) : 0.0;
          if (a > align + 1e-12) { align = a; pick = kv.first; at = kv.second.second; }
        }
        if (pick < 0) { ++rep_.ties_refused_reach; continue; }
        // the tie stays in the region along its length
        bool in = true;
        const int n = std::max(2, static_cast<int>(std::ceil(dist(p, at) / 0.5)));
        for (int k = 1; k < n && in; ++k) in = inreg(add(p, mul(sub(at, p), static_cast<double>(k) / n)));
        if (!in) { ++rep_.ties_refused_reach; continue; }
        const int l = new_line(p, static_cast<int>(ci), 1, true);
        lay(l, at);
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
  steep_sin_ = std::sin(kSteepestDeg * kPi / 180.0);
  steep_cos_ = std::cos(kSteepestDeg * kPi / 180.0);
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
  settle();
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
    settle();
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
