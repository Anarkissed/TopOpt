// Lattice rebuild, Organic, Grown (rules G1 to G13): the owner's Grown placement, written new in this engine, with
// the ORIGINAL Grown's own growing rules and numbers (brief G4; organic/map-grown-pruning.md section 1). See
// lattice_layout_organic.hpp and docs/design/lattice-rebuild/01-rules.md section 11. The original generator
// (core/src/mesh/organic_lattice.cpp, grow_organic_lattice) was read for its rules and numbers only; nothing of it is
// called. Nothing here decides an order by an unordered container, the clock or the thread count: the randomness is
// the ask's fixed seed number.
#include "topopt/lattice_layout_organic.hpp"
#include "topopt/grading.hpp"

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
  floor_stepped += o.floor_stepped; floor_ended_edge += o.floor_ended_edge;
  floor_ended_unsupported += o.floor_ended_unsupported; floor_ended_joins += o.floor_ended_joins;
  joins += o.joins; grew_on_after_join += o.grew_on_after_join; joins_refused_span += o.joins_refused_span;
  branches_offered += o.branches_offered; branches_grown += o.branches_grown; links += o.links;
  refused_region += o.refused_region; refused_support += o.refused_support; refused_crowded += o.refused_crowded;
  tips += o.tips; tip_budget_hit = std::max(tip_budget_hit, o.tip_budget_hit);
  bare_before = std::max(bare_before, o.bare_before); bare_after = std::max(bare_after, o.bare_after);
  reseed_voids += o.reseed_voids; reseed_landed += o.reseed_landed; reseed_failed += o.reseed_failed;
  reseed_mm += o.reseed_mm;
  reseed_from_vertex += o.reseed_from_vertex;
  reseed_voids_round.insert(reseed_voids_round.end(), o.reseed_voids_round.begin(), o.reseed_voids_round.end());
  wall_grown += o.wall_grown; wall_joins += o.wall_joins; wall_ended_edge += o.wall_ended_edge;
  wall_ended_unsupported += o.wall_ended_unsupported; wall_ended_joins += o.wall_ended_joins;
  wall_lines_joined.insert(wall_lines_joined.end(), o.wall_lines_joined.begin(), o.wall_lines_joined.end());
  wall_roots += o.wall_roots; wall_roots_kept += o.wall_roots_kept; wall_roots_cut_at_joint += o.wall_roots_cut_at_joint;
  wall_vines_removed += o.wall_vines_removed;
  cross_seeded += o.cross_seeded; cross_grown += o.cross_grown; cross_ended_side += o.cross_ended_side;
  cross_ended_top += o.cross_ended_top; cross_ended_noface += o.cross_ended_noface;
  cross_ended_unsupported += o.cross_ended_unsupported; cross_ended_guard += o.cross_ended_guard;
  cross_joins.insert(cross_joins.end(), o.cross_joins.begin(), o.cross_joins.end());
  cross_reach_mm.insert(cross_reach_mm.end(), o.cross_reach_mm.begin(), o.cross_reach_mm.end());
  d2_offered += o.d2_offered; d2_grown += o.d2_grown; d2_refused += o.d2_refused; d2_short += o.d2_short;
  for (int f = 0; f < 6; ++f) face_hits[f] += o.face_hits[f];
  stubs.insert(stubs.end(), o.stubs.begin(), o.stubs.end());
  ties_seeded += o.ties_seeded; ties_laid += o.ties_laid; ties_refused_minor += o.ties_refused_minor;
  ties_refused_reach += o.ties_refused_reach;
  feet_kept += o.feet_kept; feet_cut_at_joint += o.feet_cut_at_joint; vines_removed += o.vines_removed;
  hold_feet_kept += o.hold_feet_kept; hold_wall_roots_kept += o.hold_wall_roots_kept;   // L2 c
  feet_cut_mm += o.feet_cut_mm; feet_cut_high_mm += o.feet_cut_high_mm;
  feet_cut_high_strands += o.feet_cut_high_strands;
  joins_refused_outside += o.joins_refused_outside; links_refused_outside += o.links_refused_outside;
  grown_mm += o.grown_mm; kept_mm += o.kept_mm;
  cut_outside_mm += o.cut_outside_mm; cut_unsupported_mm += o.cut_unsupported_mm; cut_nothing_mm += o.cut_nothing_mm;
  cut_repeat_mm += o.cut_repeat_mm;
  strands += o.strands; ms += o.ms;
  wall_thirds.insert(wall_thirds.end(), o.wall_thirds.begin(), o.wall_thirds.end());   // M
  cross_thirds.insert(cross_thirds.end(), o.cross_thirds.begin(), o.cross_thirds.end());   // N
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
constexpr double kCrossMaxSin = 0.7071067811865476;          // F: a crossing vine climbs at 45 degrees from level at most
constexpr double kCrossGap = 2.5;                            // F: crossing vines start 2.5 x the local spacing apart
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
  bool d2 = false;   // D2: a branch made at a face, or a strand grown from one (they make no D2 branch)
  // G13: the line it was grown as (its index then: repeats split a line, its pieces keep it); a branch (G6) of
  // `parent`; a floor seed's strand (`seed_no` its seed's order, `root0` its root, `floor_pt` where it leaves the floor).
  int origin = -1;
  bool branch = false;
  bool floor_seed = false;
  int seed_no = -1;
  Vec3 root0{}, floor_pt{};
  bool wall_seed = false;   // E, wall_gap: a wall seed's strand (`seed_no`, `root0` as a foot's; `wall_pt` its wall point)
  Vec3 wall_pt{};
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
  int d2 = 0;         // D2: 2 the branch made at a face, 1 a tip descended from one
  Vec3 inward{};      // F: a wall seed's unit level direction straight away from its wall
  bool cross = false; // F: this wall seed is a crossing vine (the others stay ordinary wall vines)
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
  // G16a, for the tests (grown_light): set up as run() does, up to the lighting; false when nothing would grow.
  bool lit_up();
  Vec3 light_at(const Vec3& p) const { return light(p); }

 private:
  bool setup();
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
  std::vector<Vec3> aim_;     // G16a: per voxel, where the pull aims: that point moved out of the part (lighting())
  std::vector<char> lit_;
  std::vector<signed char> face_;   // D2: per voxel, the face (nb order: +x -x +y -y +z) its wall site was found across
  double sp_tight_ = 0.0, sp_wide_ = 0.0;   // D1: the spacing field's tightest and widest over the candidates
  std::size_t tips_ = 0;
  // G (brief G8): the strands that ended by leaving through the top face (line, end point), in the order they ended,
  // while the first growth runs (top_open_).
  std::vector<std::pair<int, Vec3>> top_ends_;
  bool top_open_ = false;

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
  // M (brief G19): O12's stress measure f (0 .. 1) at p, read exactly as sep reads the spacing: the voxel's own; off the
  // candidates, the first candidate neighbour's (in axis order); else 0 (sep's widest, the light end).
  double stress_f(const Vec3& p) const {
    int i, j, k;
    if (!voxel(p, i, j, k)) return 0.0;
    const std::size_t e = field_.index(i, j, k);
    if (sp_.candidate[e]) return sp_.stress_f[e];
    for (int dk = -1; dk <= 1; ++dk)
      for (int dj = -1; dj <= 1; ++dj)
        for (int di = -1; di <= 1; ++di) {
          const int a = i + di, b = j + dj, c = k + dk;
          if (a < 0 || b < 0 || c < 0 || a >= field_.nx || b >= field_.ny || c >= field_.nz) continue;
          const std::size_t f = field_.index(a, b, c);
          if (sp_.candidate[f]) return sp_.stress_f[f];
        }
    return 0.0;
  }
  bool frame(const Vec3& p, double ev[3], Vec3 vec[3]) const {
    int i, j, k;
    if (!voxel(p, i, j, k)) return false;
    principal(&field_.voigt[6 * field_.index(i, j, k)], ev, vec);
    return std::fabs(ev[0]) > 0.0;
  }
  // G3: the major principal direction, turned to point up; false where there is no stress.
  // I (brief G10): the stress share u(p), 0 .. 1, exactly O12's (organic_spacing): the von Mises of the tensor at p's
  // voxel over sp_'s reference; 0 off the field or with a reference of 0.
  double share(const Vec3& p) const {
    int i, j, k;
    if (!voxel(p, i, j, k)) return 0.0;
    const double* t = &field_.voigt[6 * field_.index(i, j, k)];
    const double a = t[0] - t[1], b = t[1] - t[2], d = t[2] - t[0];
    const double vm =
        std::sqrt(std::max(0.0, 0.5 * (a * a + b * b + d * d) + 3.0 * (t[3] * t[3] + t[4] * t[4] + t[5] * t[5])));
    return grading_demand_fraction(GradingIntent::Aesthetic, vm, sp_.reference_mpa, 1.0);
  }
  bool stress_dir(const Vec3& p, Vec3& f) const {
    double ev[3];
    Vec3 vec[3];
    if (!frame(p, ev, vec)) return false;
    f = dot(vec[0], up_) < 0.0 ? mul(vec[0], -1.0) : vec[0];
    return true;
  }
  // G3, the pull (the owner's OR35): toward the nearest point of the region's boundary that is not its floor, moved
  // out of the part by the local spacing (G16a: aim_); up where there is none (off the candidates, or on that point).
  Vec3 light(const Vec3& p) const {
    int i, j, k;
    if (!voxel(p, i, j, k)) return up_;
    const std::size_t e = field_.index(i, j, k);
    if (!lit_[e]) return up_;
    const Vec3 d = sub(aim_[e], p);
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
  void d2_branch(int li, const Vec3& p, const Vec3& o, std::vector<Tip>& tips);
  void repeats();
  void feet(const std::vector<int>& parent, const std::vector<char>& branch, const std::vector<char>& seeded,
            bool wall = false);
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
  // G (brief G8): top runs and roots, once, after ties(0) and before the pruning.
  void runs();
  std::size_t split_at(int li, std::size_t seg, const Vec3& x);
  enum RunEnd { RVine, RRun, RSolid, RDip, RAir, RReach, RNoFloor };
  RunEnd make_run(int vine, const Vec3& start, Vec3 dir, double max_len, bool root, Boxes& mine, int end_id,
                  double& mm);
  std::vector<Strand> strands() const;
};

// G3, the pull's target: for every candidate voxel the nearest point of the region's boundary that is not its floor
// (the middle of a candidate's face whose neighbour across it is not a candidate, unless that face looks down along
// the build direction). Spread from those faces to their neighbours (26) in index order, each voxel keeping the
// nearest point any neighbour offers: the same answer every time.
// G16a (brief G6; the owner, 2026-11-15: "the vines need to go to a face"): the light is outside the part. Which point
// is a voxel's nearest is found exactly as above; the pull AIMS at that point moved out across its face by the local
// spacing of the voxel it was found on (aim_), so at the wall the pull is through the wall, not along it.
void Grower::lighting() {
  const std::size_t n = static_cast<std::size_t>(field_.nx) * field_.ny * field_.nz;
  light_.assign(n, Vec3{});
  aim_.assign(n, Vec3{});
  face_.assign(n, -1);
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
          if (d < best[e]) {
            best[e] = d;
            light_[e] = site;
            aim_[e] = add(site, mul(o, sp_.spacing_mm[e]));
            face_[e] = static_cast<signed char>(f);
          }
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
            aim_[f] = aim_[e];
            face_[f] = face_[e];
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
  std::vector<Vec3> cross_kept;   // F: the wall points of the crossing vines made so far
  GrowReport::CrossThirds cthirds;   // N: the crossing vines chosen, by third of O12's measure at the wall point
  cthirds.region = region_;
  const bool cross_by_stress = ask_.wall_cross != 0 && ask_.cross_gap_heavy > 0.0;   // N
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
    // F (third form): the crossing vines are chosen BEFORE anything grows (a tie holds a crossing vine up, so no
    // competition after the growth can remove one): a wall seed with no crossing vine within kCrossGap x its local
    // spacing is one. Every other wall seed stays an ordinary wall vine, with every ordinary rule (they are what
    // draws the faces).
    // N: the gap is cross_gap (kCrossGap when not given), or by stress at `on` (rule M's twin).
    bool cross = ask_.wall_cross != 0;
    const double cgap = cross_by_stress ? ask_.cross_gap + (ask_.cross_gap_heavy - ask_.cross_gap) * stress_f(on)
                                        : ask_.cross_gap;
    for (const Vec3& k : cross_kept) cross = cross && !(dist(k, on) < cgap * sep(on));
    if (cross) {
      cross_kept.push_back(on);
      const double sf = stress_f(on);   // N: counted only
      ++cthirds.seeded[sf < 1.0 / 3.0 ? 0 : (sf < 2.0 / 3.0 ? 1 : 2)];
      ++cthirds.total;
    }
    Tip t;
    t.kind = Tip::Wall;
    t.root = end_at_edge(w.c, w.w, at);
    t.dir = add(mul(w.w, -cone_cos_), mul(up_, cone_sin_));   // inward, at the cone
    t.from = on;
    t.seed_no = static_cast<int>(rep_.seeds_wall);
    t.inward = unit(level(t.dir));   // F: the level part of its first heading
    t.cross = cross;
    tips.push_back(t);
    ++rep_.seeds_wall;
  }
  if (ask_.wall_cross != 0) rep_.cross_thirds.push_back(cthirds);   // N
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
    t.d2 = me.d2 ? 1 : 0;
    tips.push_back(t);
    ++tips_;
  }
}

// D2 (stress_goal, brief G6 step 3): a tip that left the region through a side face (`o` its wall site's outward
// direction): its strand stays, ending on the face; one local spacing (at its last point inside, `p`) back along it
// from its end, ONE branch is offered, leaving at the cone, its level direction straight away from the face, through
// the usual branch tests (in the region, supported, not crowded); refused: no branch, no link. A strand shorter than
// one spacing: no branch. Counted.
void Grower::d2_branch(int li, const Vec3& p, const Vec3& o, std::vector<Tip>& tips) {
  const Line& me = lines_[static_cast<std::size_t>(li)];
  const double S = sep(p);
  double left = S;
  Vec3 at{};
  bool found = false;
  for (std::size_t k = me.pts.size(); k-- > 1 && !found;) {
    const double l = dist(me.pts[k], me.pts[k - 1]);
    if (l >= left) {
      at = add(me.pts[k], mul(sub(me.pts[k - 1], me.pts[k]), l > 0.0 ? left / l : 0.0));
      found = true;
    } else {
      left -= l;
    }
  }
  if (!found) { ++rep_.d2_short; return; }
  ++rep_.d2_offered;
  const Vec3 side = unit(level(mul(o, -1.0)));
  if (len(side) < 0.5) { ++rep_.d2_refused; return; }
  const Vec3 bdir = add(mul(side, cone_cos_), mul(up_, cone_sin_));
  const Vec3 bq = add(at, mul(bdir, layer_));
  if (!inreg(bq) || !supported(bq) || too_close(bq, li, -1).found) { ++rep_.d2_refused; return; }
  if (tips_ >= kMaxTips) { rep_.tip_budget_hit = 1; return; }
  Tip t;
  t.kind = Tip::Branch;
  t.root = t.from = at;
  t.dir = bdir;
  t.parent = li;
  t.family = (me.family + 1) % 3;
  t.d2 = 2;
  tips.push_back(t);
  ++tips_;
}

// G3 to G5, the original's tip loop, step by step.
void Grower::grow_tip(const Tip& t, std::vector<Tip>& tips) {
  const int li = t.line >= 0 ? t.line : new_line(t.root, t.parent, t.family);
  if (t.line < 0) {
    Line& L = lines_[static_cast<std::size_t>(li)];
    L.branch = t.kind == Tip::Branch;
    L.d2 = t.d2 != 0;
    if (t.kind == Tip::Floor) {
      L.floor_seed = true;
      L.seed_no = t.seed_no;
      L.root0 = t.root;
      L.floor_pt = t.from;
    }
    if (t.kind == Tip::Wall) {
      L.wall_seed = !t.cross;   // F: a crossing vine is not in the wall roots' competition
      L.seed_no = t.seed_no;
      L.root0 = t.root;
      L.wall_pt = t.from;
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
  // E, wall_connect: a wall seed's tip aims at the nearest live strand sample within 4 x the local spacing, not on its
  // own line nor on a line it has joined, in a direction rising at the cone or steeper (none: false).
  const bool connect = ask_.wall_connect && t.kind == Tip::Wall;
  // F, wall_cross: a wall seed's own strand is a crossing vine.
  const bool crossing = ask_.wall_cross != 0 && t.kind == Tip::Wall && t.cross;
  std::size_t cross_joins = 0;
  double since_tie = 0.0;
  std::vector<int> joined;
  auto target = [&](const Vec3& at, Vec3& x) {
    const double R = 4.0 * sep(at);
    bool found = false;
    double bd = std::numeric_limits<double>::infinity();
    int bl = -1, bs = -1;
    boxes_.near(at, R, [&](const Sample& s) {
      if (s.line == li || !live(s)) return;
      if (std::find(joined.begin(), joined.end(), s.line) != joined.end()) return;
      const double d = dist(s.p, at);
      if (!(d <= R) || d <= 1e-9 || dot(sub(s.p, at), up_) < cone_sin_ * d) return;
      if (d < bd || (d == bd && (s.line < bl || (s.line == bl && s.seg < bs)))) {
        found = true; bd = d; bl = s.line; bs = s.seg; x = s.p;
      }
    });
    return found;
  };
  const int layers = static_cast<int>(std::ceil((domain_.measure().diagonal_mm() + 1.0) / layer_)) + 4;
  const long long guard = 16LL * layers;
  enum End { Edge, Unsupported, Joins, Guard } how = Guard;
  for (long long it = 0; it < guard; ++it) {
    Vec3 want;
    if (foot > 0.0) {
      want = dir;
    } else {
      Vec3 f, x;
      const bool aim = connect && target(p, x);
      const bool has_f = !aim && stress_dir(p, f);
      // D1 (stress_goal): t = (widest - S(p)) / (widest - tightest) of the spacing field (0 when they are equal);
      // where t >= 0.1 and there is a stress direction the stress is the goal: no pull.
      const double tg = ask_.stress_goal && sp_wide_ > sp_tight_ ? (sp_wide_ - sep(p)) / (sp_wide_ - sp_tight_) : 0.0;
      if (crossing) {
        // F: its heading, the stress (where there is one) and straight away from its wall; no pull to a face. Its
        // climb is held between the cone and 45 degrees from level: the stress bends it, and it still crosses.
        Vec3 fc;
        want = mul(dir, kBlendHeading);
        if (stress_dir(p, fc)) want = add(want, mul(fc, kBlendField));
        want = add(want, mul(t.inward, kUpwardBias));
        if (len(want) > 1e-12) {
          want = unit(want);
          const Vec3 lv = level(want);
          const Vec3 side = len(lv) > 1e-6 ? unit(lv) : t.inward;
          const double s = std::min(std::max(dot(want, up_), cone_sin_), kCrossMaxSin);
          want = add(mul(side, std::sqrt(1.0 - s * s)), mul(up_, s));
        }
      } else if (aim) {
        want = add(mul(dir, kBlendHeading), mul(unit(sub(x, p)), kBlendField));   // E: toward the next strand
      } else if (ask_.stress_goal && has_f && tg >= 0.1) {
        want = add(mul(dir, kBlendHeading), mul(f, kBlendField));
      } else {
        want = has_f ? add(mul(dir, kBlendHeading), mul(f, kBlendField)) : dir;
        want = add(want, mul(light(p), kUpwardBias));   // the pull, toward the nearest face (OR35)
      }
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
    if (foot <= 0.0 && !crossing) {   // F: a crossing vine is never moved or turned by what it passes
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
          if (connect) {
            ++rep_.wall_joins;
            if (std::find(joined.begin(), joined.end(), n.line) == joined.end()) joined.push_back(n.line);
          }
          if (++joins_used > kMaxJoins) { how = Joins; break; }
          Vec3 nx;
          if (connect && target(n.hit, nx)) {
            // E: no deflection: it stays on the joint and re-aims at the next strand.
            dir = unit(sub(nx, n.hit));
            p = n.hit;
            spared.push_back({n.line, n.hit});
            since_record = kRecordRadii * r_;
            after_join = true;
            continue;
          }
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
    if (crossing) {
      // F (second form, 2026-11-16): it runs its own line through the plant. Where it passes within the crowding
      // distance of a strand it has not tied to yet, a branch stride after its last tie, the level run is 3 mm or less
      // and the segment stays on the candidates, it throws ONE tie from its own point to that strand (as a refused
      // branch's link is made) and goes on unmoved.
      since_tie += layer_;
      if (since_tie >= std::max(layer_, kBranchEveryRatio * sep(p))) {
        const Near n = too_close(p, li, parent);
        if (n.found && std::find(joined.begin(), joined.end(), n.line) == joined.end() && dist(n.hit, p) > 1e-9 &&
            len(level(sub(n.hit, p))) <= kJoinRunMm && on_candidates(p, n.hit)) {
          const int l = new_line(p, li, (lines_[static_cast<std::size_t>(li)].family + 1) % 3);
          lay(l, n.hit);
          ++rep_.links;
          ++cross_joins;
          joined.push_back(n.line);
          since_tie = 0.0;
        }
      }
    }
    if (!connect && since_branch >= std::max(layer_, kBranchEveryRatio * sep(p))) {
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
  if (how == Edge) {
    // D2: the face it left through (its last voxel's wall site); none off the lit candidates.
    int face = 5;
    int fi, fj, fk;
    if (voxel(p, fi, fj, fk) && lit_[field_.index(fi, fj, fk)]) face = face_[field_.index(fi, fj, fk)];
    ++rep_.face_hits[face];
    static const double nbv[5][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}};
    const Vec3 o = face < 5 ? Vec3{nbv[face][0], nbv[face][1], nbv[face][2]} : up_;
    if (ask_.stress_goal && !connect && !lines_[static_cast<std::size_t>(li)].d2 && dot(o, up_) <= 0.5)
      d2_branch(li, p, o, tips);
    if (crossing) ++(face < 4 ? rep_.cross_ended_side : face == 4 ? rep_.cross_ended_top : rep_.cross_ended_noface);
    // G: a strand that left through the top face: its line and end point, for its top runs.
    if (top_open_ && face == 4 && lines_[static_cast<std::size_t>(li)].pts.size() >= 2)
      top_ends_.push_back({li, lines_[static_cast<std::size_t>(li)].pts.back()});
  }
  if (crossing) {
    ++rep_.cross_seeded;
    if (how == Unsupported) ++rep_.cross_ended_unsupported;
    else if (how == Guard) ++rep_.cross_ended_guard;
    const Line& L = lines_[static_cast<std::size_t>(li)];
    if (L.pts.size() >= 2) {
      ++rep_.cross_grown;
      rep_.cross_joins.push_back(cross_joins);
      rep_.cross_reach_mm.push_back(len(level(sub(L.pts.back(), start))));
    }
  }
  if (connect) {
    rep_.wall_lines_joined.push_back(joined.size());
    if (how == Edge) ++rep_.wall_ended_edge;
    else if (how == Unsupported) ++rep_.wall_ended_unsupported;
    else if (how == Joins) ++rep_.wall_ended_joins;
    if (lines_[static_cast<std::size_t>(li)].pts.size() >= 2) ++rep_.wall_grown;
  }
  if (how == Edge) ++rep_.ended_edge;
  else if (how == Unsupported) ++rep_.ended_unsupported;
  else if (how == Joins) ++rep_.ended_joins;
  if (t.kind == Tip::Floor && !first) {
    ++rep_.floor_stepped;
    if (how == Edge) ++rep_.floor_ended_edge;
    else if (how == Unsupported) ++rep_.floor_ended_unsupported;
    else if (how == Joins) ++rep_.floor_ended_joins;
  }
  if (lines_[static_cast<std::size_t>(li)].pts.size() >= 2) {
    ++rep_.strands_grown;
    if (t.kind == Tip::Branch) ++rep_.branches_grown;
    if (t.d2 == 2) ++rep_.d2_grown;
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
      if (s0 == 0 && L.wall_seed) {   // E: likewise a wall seed's root
        run.wall_seed = true;
        run.seed_no = L.seed_no;
        run.root0 = L.root0;
        run.wall_pt = L.wall_pt;
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
// E, wall_gap (`wall`): the same for wall seeds' roots, by their own plants (`seeded` then marks wall seeds), their wall
// points, wall_gap, straight-line distance, joints from the wall on; their own counts. Feet and wall roots never
// remove each other.
void Grower::feet(const std::vector<int>& parent, const std::vector<char>& branch, const std::vector<char>& seeded,
                  bool wall) {
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
    if (!(wall ? L.wall_seed : L.floor_seed) || L.pts.size() < 2 || dist(L.pts.front(), L.root0) > 1e-9) continue;
    all.push_back({l, L.seed_no, worth[static_cast<std::size_t>(L.origin)]});
  }
  std::sort(all.begin(), all.end(), [](const Foot& a, const Foot& b) {
    return a.worth != b.worth ? a.worth > b.worth : a.seed_no < b.seed_no;
  });
  std::vector<std::size_t> removed;
  std::vector<Vec3> kept;   // the kept feet's floor points (wall: the kept wall roots' wall points)
  if (wall) rep_.wall_roots += all.size();
  // M: the wall gap by stress (on when wall_gap_heavy is above 0), and the counts by third, rule M off against on.
  const bool by_stress = wall && ask_.wall_gap_heavy > 0.0;
  auto third = [](double f) { return f < 1.0 / 3.0 ? 0 : (f < 2.0 / 3.0 ? 1 : 2); };
  auto exempt = [&](const Vec3& fp) {   // L2 c's zone, as below
    const double R2 = sp_.hold_reach_mm * sp_.hold_reach_mm;
    for (const Vec3& c : sp_.hold_centres) {
      const Vec3 d = sub(c, fp);
      if (dot(d, d) <= R2) return true;
    }
    return false;
  };
  GrowReport::WallThirds thirds;
  thirds.region = region_;
  if (wall) {   // rule M off: the same pass with wall_gap everywhere, counted only
    std::vector<Vec3> kept_off;
    for (const Foot& f : all) {
      const Vec3 fp = lines_[f.line].wall_pt;
      const int t = third(stress_f(fp));
      ++thirds.roots[t];
      const double lim = ask_.wall_gap * sep(fp);
      bool near = false;
      for (const Vec3& k : kept_off) near = near || dist(k, fp) < lim;
      if (near && !sp_.hold_centres.empty() && exempt(fp)) near = false;
      if (!near) { kept_off.push_back(fp); ++thirds.kept_off[t]; }
    }
  }
  for (const Foot& f : all) {
    const Vec3 fp = wall ? lines_[f.line].wall_pt : lines_[f.line].floor_pt;
    const double gap = by_stress ? ask_.wall_gap + (ask_.wall_gap_heavy - ask_.wall_gap) * stress_f(fp)
                                 : (wall ? ask_.wall_gap : ask_.foot_gap);   // M
    const double lim = gap * sep(fp);
    bool near = false;
    for (const Vec3& k : kept) near = near || (wall ? dist(k, fp) : len(level(sub(k, fp)))) < lim;
    if (near && !sp_.hold_centres.empty()) {   // L2 c: never thinned within the reach of a floating part's underside
      const double R2 = sp_.hold_reach_mm * sp_.hold_reach_mm;
      bool in_zone = false;
      for (const Vec3& c : sp_.hold_centres) {
        const Vec3 d = sub(c, fp);
        if (dot(d, d) <= R2) { in_zone = true; break; }
      }
      if (in_zone) { near = false; ++(wall ? rep_.hold_wall_roots_kept : rep_.hold_feet_kept); }
    }
    if (near) {
      removed.push_back(f.line);
    } else {
      kept.push_back(fp);
      ++(wall ? rep_.wall_roots_kept : rep_.feet_kept);
      if (wall) ++thirds.kept_on[third(stress_f(fp))];   // M
    }
  }
  if (wall) rep_.wall_thirds.push_back(thirds);   // M
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
    joints[r] = joints_of(removed[r], wall ? -std::numeric_limits<double>::infinity()
                                           : h(lines_[removed[r]].floor_pt) + 1e-6);
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
    if (mm > 0.0 && !wall) {
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
    if (!wall) rep_.feet_cut_mm += mm;
    rep_.cut_nothing_mm += mm;
  }
  for (std::size_t r = 0; r < removed.size(); ++r) {
    Line& L = lines_[removed[r]];
    (wall ? L.wall_seed : L.floor_seed) = false;
    double mm = 0.0;
    if (at_joint[r] < 0) {
      for (std::size_t k = 0; k + 1 < L.pts.size(); ++k) mm += dist(L.pts[k], L.pts[k + 1]);
      count_high(L, L.pts.size());
      L.pts.resize(1);
      L.rec.resize(1);
      ++(wall ? rep_.wall_vines_removed : rep_.vines_removed);
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
      ++(wall ? rep_.wall_roots_cut_at_joint : rep_.feet_cut_at_joint);
    }
    L.stamp.clear();
    L.dead.assign(L.pts.size() > 0 ? L.pts.size() - 1 : 0, 0);
    if (!wall) rep_.feet_cut_mm += mm;
    rep_.cut_nothing_mm += mm;   // counted under "leads to nothing" (G12)
  }
  rebuild_boxes();
}

// G10: the pruning, in order: repeats merged (the kept copy takes over what depended on a dropped one), no strand
// ending in mid-air, the feet competing (G13) and the mid-air pass again, then the path's own answer per segment (outside the model, the joining, the loose and adrift
// drops): what it leaves out is no longer material.
void Grower::prune() {
  std::vector<int> parent(lines_.size());
  std::vector<char> branch(lines_.size()), seeded(lines_.size()), walled(lines_.size());
  for (std::size_t l = 0; l < lines_.size(); ++l) {
    parent[l] = lines_[l].parent;
    branch[l] = lines_[l].branch;
    seeded[l] = lines_[l].floor_seed;
    walled[l] = lines_[l].wall_seed;
  }
  repeats();
  settle();
  if (ask_.foot_gap > 0.0) feet(parent, branch, seeded);   // G13 (0 or less: the feet do not compete)
  if (ask_.wall_gap > 0.0) feet(parent, branch, walled, true);   // E: the wall roots, the same way, by themselves
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
  std::vector<std::array<int, 3>> voids;
  std::vector<Vec3> at;
  for (int k = 0; k < field_.nz; k += stride)
    for (int j = 0; j < field_.ny; j += stride)
      for (int i = 0; i < field_.nx; i += stride) {
        const std::size_t e = field_.index(i, j, k);
        if (!sp_.candidate[e]) continue;
        const Vec3 q = centre(i, j, k);
        const double lim = ask_.void_ratio * sp_.spacing_mm[e];   // E: G11's kVoidRatio unless asked
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
    // G16c (brief G6): a bare place is filled from the nearest vine, not from the floor. First the vertices of what
    // the path keeps (a vertex: a joint both keep, as the landing below reads them) within 4 x the local spacing: one
    // may root the stub when the straight line from it up to the bare place rises at the cone or steeper and stays on
    // the region's candidates; the nearest (ties: lower line, then lower vertex). The stub is that straight line.
    const double reach = 4.0 * sep(sp);   // G16c: and the walk below travels this far at most
    const double land_r = std::max(2.0 * r_, kTestRatio * sep(sp));
    {
      bool found = false;
      double bd = std::numeric_limits<double>::infinity();
      int bl = -1;
      std::size_t bk = 0;
      Vec3 bx{};
      boxes_.near(sp, reach + ds_, [&](const Sample& s) {
        if (!live(s)) return;
        const Line& L = lines_[static_cast<std::size_t>(s.line)];
        for (std::size_t end = 0; end < 2; ++end) {
          const std::size_t k = static_cast<std::size_t>(s.seg) + end;
          const Vec3 x = L.pts[k];
          const double d = dist(x, sp);
          if (!(d <= reach) || d <= 1e-9) continue;
          if (!(d < bd || (d == bd && (s.line < bl || (s.line == bl && k < bk))))) continue;
          if (dot(sub(sp, x), up_) < cone_sin_ * d || !on_candidates(x, sp)) continue;
          found = true;
          bd = d;
          bl = s.line;
          bk = k;
          bx = x;
        }
      });
      if (found) {
        const int li = new_line(bx, -1, 0);
        rep_.reseed_mm += dist(bx, sp);
        lay(li, sp, true);
        ++rep_.reseed_landed;
        ++rep_.reseed_from_vertex;
        rep_.stubs.push_back({bx, sp, {bx, sp}, dist(bx, sp), sep(sp), land_r, true});
        Tip t;
        t.kind = Tip::Reseed;
        t.line = li;
        t.root = t.from = sp;
        t.dir = cap(4, static_cast<long long>(vi), 0);
        tips.push_back(t);
        ++tips_;
        continue;
      }
    }
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
      if (travelled > reach) break;   // out of reach (G16c: 4 x the local spacing at most, before it may land)
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
    }
    if (!landed || path.size() < 2) { ++rep_.reseed_failed; continue; }
    const int li = new_line(path.back(), -1, 0);
    double stub_mm = 0.0;
    for (std::size_t k = path.size() - 1; k-- > 0;) {
      rep_.reseed_mm += dist(path[k + 1], path[k]);
      stub_mm += dist(path[k + 1], path[k]);
      lay(li, path[k], true);
    }
    ++rep_.reseed_landed;
    rep_.stubs.push_back({path.back(), sp, std::vector<Vec3>(path.rbegin(), path.rend()), stub_mm, sep(sp), land_r, false});
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

// G (brief G8): put x, a point of segment `seg` of line li, in as a vertex of the line (nothing moves); its index.
std::size_t Grower::split_at(int li, std::size_t seg, const Vec3& x) {
  Line& L0 = lines_[static_cast<std::size_t>(li)];
  if (dist(x, L0.pts[seg]) <= 1e-9) return seg;
  if (dist(x, L0.pts[seg + 1]) <= 1e-9) return seg + 1;
  const std::vector<Vec3> pts = L0.pts;
  const std::vector<char> rec = L0.rec;
  laid_mm_ -= take_back(li, seg);
  lay(li, x, false);
  for (std::size_t k = seg + 1; k < pts.size(); ++k) lay(li, pts[k], rec[k] != 0);
  return seg + 1;
}

// G: one run (a top run, or a root) from `start`, a vertex of line `vine`, level at the start's height, leaving on
// `dir` (level, unit) and turned gradually onto the stress line (addendum B). Its endings (rule item 5, addendum D);
// made, it is a tie in every other respect (thinned as a tie, the tie flag); its points go into `mine` as end_id's.
Grower::RunEnd Grower::make_run(int vine, const Vec3& start, Vec3 dir, double max_len, bool root, Boxes& mine,
                                int end_id, double& mm) {
  const double s0 = sep(start), w = std::min(1.0, ask_.run_follow * layer_ / s0), wr = std::max(2.0 * r_, 0.75 * layer_);
  // H (brief G9): followable stress at x: in the region, a frame, the level part of the major direction 0.2 long or
  // more; its strength m = |ev0| x that length (0 where there is none).
  auto strength = [&](const Vec3& x) {
    if (!inreg(x)) return 0.0;
    double ev[3];
    Vec3 vec[3];
    if (!frame(x, ev, vec)) return 0.0;
    const double l = len(level(vec[0]));
    return l >= 0.2 ? std::fabs(ev[0]) * l : 0.0;
  };
  bool used_magnet = false;
  std::size_t& n_follow = root ? rep_.root_steps_follow : rep_.top_steps_follow;
  std::size_t& n_magnet = root ? rep_.root_steps_magnet : rep_.top_steps_magnet;
  std::size_t& n_none = root ? rep_.root_steps_none : rep_.top_steps_none;
  Vec3 q = start;
  double travelled = 0.0;
  std::vector<Vec3> path{start};
  std::vector<char> must{1};
  RunEnd how = RReach;
  while (true) {
    if (travelled >= max_len) {
      if (!root) return RReach;
      // D: it dips into the floor: one last segment along its direction and down at 45 degrees, ended in the floor's
      // solid as a tip that leaves the region into solid ends.
      const Vec3 d = unit(sub(dir, up_));
      const double at = edge(q, d, 2.0 * s0);
      if (at < 0.0 || !solid(add(q, mul(d, at + 3.0 * 0.02)))) return RNoFloor;
      path.push_back(end_at_edge(q, d, at));
      must.push_back(1);
      how = RDip;
      break;
    }
    // H1: the target T at q.
    Vec3 f, T{};
    bool target = false;
    if (inreg(q) && stress_dir(q, f) && len(level(f)) >= 0.2) {   // 1: q has a followable direction
      Vec3 lf = unit(level(f));
      if (dot(lf, dir) < 0.0) lf = mul(lf, -1.0);
      T = lf;
      if (ask_.run_seek > 0.0) {
        const Vec3 n = cross(up_, lf);
        const double a = strength(add(q, mul(n, s0 / 2.0))), b = strength(sub(q, mul(n, s0 / 2.0)));
        if (a + b > 0.0) T = unit(add(lf, mul(n, ask_.run_seek * ((a - b) / (a + b)))));
      }
      target = true;
      ++n_follow;
    } else if (ask_.run_pull > 0.0) {   // 2: the magnet, on rings round q at q's height
      const int rings = static_cast<int>(std::floor(4.0 * ask_.run_pull + 1e-9));
      for (int k = 1; k <= rings && !target; ++k) {
        const double rad = k * s0 / 4.0;
        double best = -2.0;
        for (int j = 0; j < 16; ++j) {
          const double ang = j * 22.5 * kPi / 180.0;
          const Vec3 d = add(mul(u_, std::cos(ang)), mul(cross(up_, u_), std::sin(ang)));
          if (strength(add(q, mul(d, rad))) <= 0.0) continue;
          const double dd = dot(d, dir);
          if (dd > best) { best = dd; T = d; target = true; }
        }
      }
      if (target) {
        ++n_magnet;
        if (!used_magnet) ++(root ? rep_.root_runs_magnet : rep_.top_runs_magnet);   // every run tried, made or not
        used_magnet = true;
      }
      else ++n_none;
    } else {
      ++n_none;
    }
    // H2: the turn.
    if (target) {
      const Vec3 s = add(mul(dir, 1.0 - w), mul(T, w));
      if (len(s) >= 1e-9) dir = unit(s);
    }
    const Vec3 nq = add(q, mul(dir, layer_));
    if (!inreg(nq)) {
      const double at = edge(q, dir, layer_ + 0.05);
      const double a = at >= 0.0 ? at : 0.0;
      if (!solid(add(q, mul(dir, a + 3.0 * 0.02)))) return RAir;
      path.push_back(end_at_edge(q, dir, a));
      must.push_back(1);
      how = RSolid;
      break;
    }
    q = nq;
    travelled += layer_;
    path.push_back(q);
    must.push_back(0);
    if (travelled >= ask_.run_min * s0) {   // H3 (a)
      Near n;
      rec_.near(q, wr, [&](const Sample& s) {
        if (s.line == vine || !rec_current(s)) return;
        const double d = dist(q, s.p);
        if (d < wr && (d < n.d || (d == n.d && s.line < n.line))) { n.found = true; n.d = d; n.hit = s.p; n.line = s.line; }
      });
      if (n.found) {
        path.back() = n.hit;
        must.back() = 1;
        how = RVine;
        break;
      }
    }
    if (travelled >= std::max(1.0, ask_.run_min) * s0) {   // H3 (b)
      const double lim = kTestRatio * sep(q);
      bool found = false;
      double best = lim;
      Vec3 hit{};
      mine.near(q, lim, [&](const Sample& s) {
        const double d = dist(q, s.p);
        if (d < best) { best = d; found = true; hit = s.p; }
      });
      if (found) {
        path.push_back(hit);
        must.push_back(1);
        how = RRun;
        break;
      }
    }
  }
  {
    const double keep_d = 8.0 * r_;   // thinned as a tie's free points are
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
  const int l = new_line(path[0], vine, 1, true);
  mm = 0.0;
  for (std::size_t k = 1; k < path.size(); ++k)
    if (dist(path[k], lines_[static_cast<std::size_t>(l)].pts.back()) > 1e-9) {
      mm += dist(path[k], lines_[static_cast<std::size_t>(l)].pts.back());
      lay(l, path[k]);
    }
  for (const Vec3& v : path) mine.put(Sample{end_id, 0, 0, v});
  return how;
}

// G (brief G8 and its addendum): every top end's runs, in the order the ends were recorded; then every floor seed's
// strand's roots, in line order.
void Grower::runs() {
  constexpr std::uint64_t kWhatN = 0x6701, kWhatA = 0x6702;
  const int nmax = std::max(1, ask_.run_max);
  auto draw_n = [&](int li, int kind) {
    if (nmax <= 1) return 1;
    const int n = 1 + static_cast<int>(std::floor(rnd(ask_.seed, kWhatN, li, kind, 0) * nmax));
    return std::min(nmax, std::max(1, n));
  };
  // I2, I3: with auto_by_stress, n = round(run_max x u(at)), 0 to run_max, in place of the random draw.
  auto count_n = [&](int li, int kind, const Vec3& at) {
    if (!ask_.auto_by_stress) return draw_n(li, kind);
    const long n = std::lround(static_cast<double>(nmax) * share(at));
    return static_cast<int>(std::min<long>(nmax, std::max<long>(0, n)));
  };
  auto turn = [&](const Vec3& v, double a) { return add(mul(v, std::cos(a)), mul(cross(up_, v), std::sin(a))); };
  if (ask_.top_run > 0.0) {
    Boxes mine = rec_;
    mine.clear();
    rep_.top_n.assign(static_cast<std::size_t>(nmax) + 1, 0);
    for (std::size_t e = 0; e < top_ends_.size(); ++e) {
      const int li = top_ends_[e].first;
      if (lines_[static_cast<std::size_t>(li)].pts.size() < 2 ||
          dist(lines_[static_cast<std::size_t>(li)].pts.back(), top_ends_[e].second) > 1e-9)
        continue;
      ++rep_.top_vines;
      const std::size_t np = lines_[static_cast<std::size_t>(li)].pts.size();
      const Vec3 a = lines_[static_cast<std::size_t>(li)].pts[np - 2], b = lines_[static_cast<std::size_t>(li)].pts[np - 1];
      Vec3 head = level(unit(sub(b, a)));
      const bool has_head = len(head) >= 0.2;
      if (!has_head && nmax <= 1) { ++rep_.top_refused_level; continue; }
      head = has_head ? unit(head) : u_;
      const double rise = h(b) - h(a);
      const Vec3 x = rise < r_ ? a : sub(b, mul(sub(b, a), r_ / rise));
      const int n = count_n(li, 0, top_ends_[e].second);
      ++rep_.top_n[static_cast<std::size_t>(n)];
      if (nmax > 1) head = turn(head, 2.0 * kPi * rnd(ask_.seed, kWhatA, li, 0, 0));
      bool split = false;
      Vec3 start = x;
      for (int k = 0; k < n; ++k) {
        bool ontop = false;
        if (ask_.run_gap > 0.0)
          mine.near(x, ask_.run_gap * sep(x), [&](const Sample& s) {
            if (s.line != static_cast<int>(e) && dist(x, s.p) < ask_.run_gap * sep(x)) ontop = true;
          });
        if (ontop) { ++rep_.top_refused_ontop; continue; }
        if (!split) {
          const std::size_t at = split_at(li, np - 2, x);
          start = lines_[static_cast<std::size_t>(li)].pts[at];
          split = true;
        }
        double mm = 0.0;
        const RunEnd r = make_run(li, start, unit(turn(head, 2.0 * kPi * k / n)), ask_.top_run * sep(start), false, mine,
                                  static_cast<int>(e), mm);
        if (r == RVine) ++rep_.top_runs_vine;
        else if (r == RRun) ++rep_.top_runs_run;
        else if (r == RSolid) ++rep_.top_runs_solid;
        else if (r == RAir) ++rep_.top_refused_air;
        else ++rep_.top_refused_reach;
        if (r == RVine || r == RRun || r == RSolid) rep_.top_run_mm.push_back(mm);
      }
    }
  }
  if (ask_.root_run > 0.0) {
    Boxes mine = rec_;
    mine.clear();
    rep_.root_n.assign(static_cast<std::size_t>(nmax) + 1, 0);
    const std::size_t count = lines_.size();
    for (std::size_t li = 0; li < count; ++li) {
      if (!lines_[li].floor_seed || lines_[li].tie || lines_[li].pts.size() < 2) continue;
      ++rep_.root_feet;
      const double H = h(lines_[li].floor_pt) + r_;
      std::size_t seg = 0;
      bool got = false;
      Vec3 x{};
      for (std::size_t k = 0; k + 1 < lines_[li].pts.size(); ++k) {
        const Vec3 a = lines_[li].pts[k], b = lines_[li].pts[k + 1];
        if (h(a) <= H && h(b) >= H && h(b) > h(a)) {
          x = add(a, mul(sub(b, a), (H - h(a)) / (h(b) - h(a))));
          seg = k;
          got = true;
          break;
        }
      }
      if (!got) { ++rep_.root_refused_nostart; continue; }
      const Vec3 a = lines_[li].pts[seg], b = lines_[li].pts[seg + 1];
      Vec3 head = level(unit(sub(b, a)));
      head = len(head) >= 0.2 ? unit(head) : u_;
      const int n = count_n(static_cast<int>(li), 1, lines_[li].floor_pt);
      ++rep_.root_n[static_cast<std::size_t>(n)];
      if (nmax > 1) head = turn(head, 2.0 * kPi * rnd(ask_.seed, kWhatA, static_cast<long long>(li), 1, 0));
      bool split = false;
      Vec3 start = x;
      for (int k = 0; k < n; ++k) {
        bool ontop = false;
        const double gap = ask_.root_gap >= 0.0 ? ask_.root_gap : ask_.run_gap;   // H4: the roots' own gap
        if (gap > 0.0)
          mine.near(x, gap * sep(x), [&](const Sample& s) {
            if (s.line != static_cast<int>(li) && dist(x, s.p) < gap * sep(x)) ontop = true;
          });
        if (ontop) { ++rep_.root_refused_ontop; continue; }
        if (!split) {
          start = lines_[li].pts[split_at(static_cast<int>(li), seg, x)];
          split = true;
        }
        double mm = 0.0;
        const RunEnd r = make_run(static_cast<int>(li), start, unit(turn(head, 2.0 * kPi * k / n)),
                                  ask_.root_run * sep(start), true, mine, static_cast<int>(li), mm);
        if (r == RVine) ++rep_.root_runs_vine;
        else if (r == RRun) ++rep_.root_runs_run;
        else if (r == RSolid) ++rep_.root_runs_solid;
        else if (r == RDip) ++rep_.root_runs_dip;
        else if (r == RAir) ++rep_.root_refused_air;
        else ++rep_.root_refused_nofloor;
        if (r == RVine || r == RRun || r == RSolid || r == RDip) rep_.root_run_mm.push_back(mm);
      }
    }
  }
}

bool Grower::setup() {
  if (field_.empty()) return false;
  if (!(len(ask_.build_dir) > 1e-9) || !std::isfinite(len(ask_.build_dir)))
    throw std::invalid_argument("grow_strands: the build direction must not be zero");
  if (!(ask_.layer_mm > 0.0) || !std::isfinite(ask_.layer_mm))
    throw std::invalid_argument("grow_strands: layer_mm must be above 0");
  if (!(ask_.seed_stride > 0.0) || !std::isfinite(ask_.seed_stride))
    throw std::invalid_argument("grow_strands: seed_stride must be above 0");
  if (!std::isfinite(ask_.foot_gap)) throw std::invalid_argument("grow_strands: foot_gap must be a number");
  if (!std::isfinite(ask_.wall_gap_heavy))
    throw std::invalid_argument("grow_strands: wall_gap_heavy must be a number (0 or less: off)");   // M
  if (ask_.wall_gap_heavy > 0.0 && !(ask_.wall_gap > 0.0))
    throw std::invalid_argument("grow_strands: wall_gap_heavy needs wall_gap");   // M
  if (ask_.wall_gap_heavy > ask_.wall_gap && ask_.wall_gap > 0.0)
    throw std::invalid_argument("grow_strands: wall_gap_heavy must be at most wall_gap");   // M
  if (ask_.wall_gap_heavy > 0.0 && (ask_.spacing_mm > 0.0 || !(ask_.spacing_max_mm > ask_.spacing_min_mm)))
    throw std::invalid_argument("grow_strands: wall_gap_heavy needs the spacing as a range (O12's measure)");   // M
  if (!(ask_.void_ratio > 0.0) || !std::isfinite(ask_.void_ratio))
    throw std::invalid_argument("grow_strands: void_ratio must be above 0");   // E
  if (ask_.wall_cross < 0 || ask_.wall_cross > 2)
    throw std::invalid_argument("grow_strands: wall_cross must be 0, 1 or 2");   // F
  if (ask_.wall_cross != 0 && !ask_.walls_out)
    throw std::invalid_argument("grow_strands: wall_cross needs walls_out");   // F
  if (ask_.wall_cross != 0 && ask_.wall_connect)
    throw std::invalid_argument("grow_strands: wall_cross and wall_connect cannot both be on");   // F
  if (!(ask_.cross_gap > 0.0) || !std::isfinite(ask_.cross_gap))
    throw std::invalid_argument("grow_strands: cross_gap must be above 0");   // N
  if (ask_.cross_gap != kCrossGap && ask_.wall_cross == 0)
    throw std::invalid_argument("grow_strands: cross_gap needs wall_cross");   // N
  if (!std::isfinite(ask_.cross_gap_heavy))
    throw std::invalid_argument("grow_strands: cross_gap_heavy must be a number (0 or less: off)");   // N
  if (ask_.cross_gap_heavy > 0.0 && ask_.wall_cross == 0)
    throw std::invalid_argument("grow_strands: cross_gap_heavy needs wall_cross");   // N
  if (ask_.cross_gap_heavy > ask_.cross_gap)
    throw std::invalid_argument("grow_strands: cross_gap_heavy must be at most cross_gap");   // N
  if (ask_.cross_gap_heavy > 0.0 && (ask_.spacing_mm > 0.0 || !(ask_.spacing_max_mm > ask_.spacing_min_mm)))
    throw std::invalid_argument("grow_strands: cross_gap_heavy needs the spacing as a range (O12's measure)");   // N
  if (!(ask_.top_run >= 0.0) || !std::isfinite(ask_.top_run))
    throw std::invalid_argument("grow_strands: top_run must be 0 or above");   // G
  if (!(ask_.root_run >= 0.0) || !std::isfinite(ask_.root_run))
    throw std::invalid_argument("grow_strands: root_run must be 0 or above");   // G
  if (!(ask_.run_gap >= 0.0) || !std::isfinite(ask_.run_gap))
    throw std::invalid_argument("grow_strands: run_gap must be 0 or above");   // G
  if (ask_.run_max < 1) throw std::invalid_argument("grow_strands: run_max must be 1 or more");   // G
  if (!(ask_.run_follow > 0.0) || !std::isfinite(ask_.run_follow))
    throw std::invalid_argument("grow_strands: run_follow must be above 0");   // H
  if (!(ask_.run_pull >= 0.0) || !std::isfinite(ask_.run_pull))
    throw std::invalid_argument("grow_strands: run_pull must be 0 or above");   // H
  if (!(ask_.run_seek >= 0.0) || !std::isfinite(ask_.run_seek))
    throw std::invalid_argument("grow_strands: run_seek must be 0 or above");   // H
  if (!(ask_.run_min >= 0.0) || !std::isfinite(ask_.run_min))
    throw std::invalid_argument("grow_strands: run_min must be 0 or above");   // H
  if (!std::isfinite(ask_.root_gap)) throw std::invalid_argument("grow_strands: root_gap must be a number");   // H
  const double thinnest = domain_.spec().bead_mm * domain_.spec().min_strut_lines;
  if (ask_.width_mm != 0.0 && !(ask_.width_mm >= thinnest - 1e-12))
    throw std::invalid_argument("grow_strands: the strut width is under the thinnest strut (G8)");
  {
    const double light = ask_.width_mm > 0.0 ? ask_.width_mm : thinnest;
    if (!(std::isfinite(ask_.width_heavy_mm) && (ask_.width_heavy_mm == 0.0 || ask_.width_heavy_mm >= light - 1e-12)))
      throw std::invalid_argument("grow_strands: width_heavy_mm must be 0 or at least the strand width");   // I
  }
  sp_ = organic_spacing(domain_, region_, field_, ask_);
  if (sp_.candidates == 0) return false;
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
  // D1: the spacing field's own tightest and widest values, over the candidates.
  sp_tight_ = std::numeric_limits<double>::infinity();
  sp_wide_ = 0.0;
  for (std::size_t e = 0; e < sp_.candidate.size(); ++e)
    if (sp_.candidate[e]) {
      sp_tight_ = std::min(sp_tight_, sp_.spacing_mm[e]);
      sp_wide_ = std::max(sp_wide_, sp_.spacing_mm[e]);
    }
  return true;
}

bool Grower::lit_up() { return setup(); }

std::vector<Strand> Grower::run() {
  if (!setup()) return {};
  // The owner's order (2026-11-15): grow, prune, then one round of re-seeding in the bare areas, grown and pruned
  // the same way.
  std::vector<Tip> tips;
  seeds(tips);
  tips_ = tips.size();
  top_open_ = ask_.top_run > 0.0;   // G: the top ends are recorded during this first growth only
  if (ask_.wall_cross != 0) {
    // F: the crossing vines (and all theirs) grown after everything else (1) or before it (2); everything else in
    // its usual order.
    std::vector<Tip> rest, cross;
    for (const Tip& t : tips) (t.cross ? cross : rest).push_back(t);
    if (ask_.wall_cross == 2) grow(std::move(cross));
    grow(std::move(rest));
    if (ask_.wall_cross == 1) grow(std::move(cross));
  } else if (ask_.wall_connect) {
    // E: the wall seeds' tips grow after every floor seed's tip and all its descendants (today they come after the
    // floor seeds but before the branches those push).
    std::vector<Tip> floor, wall;
    for (const Tip& t : tips) (t.kind == Tip::Wall ? wall : floor).push_back(t);
    grow(std::move(floor));
    grow(std::move(wall));
  } else {
    grow(std::move(tips));
  }
  top_open_ = false;
  if (ask_.ties) ties(0);
  if (ask_.top_run > 0.0 || ask_.root_run > 0.0) runs();   // G
  prune();
  rep_.bare_before = bare();
  // E: the re-seed step reseed_rounds times (G11: once); between rounds what the last pass cut is no longer material,
  // as after the first pruning.
  Fate f;
  for (int round = 0; round < std::max(0, ask_.reseed_rounds); ++round) {
    if (round > 0) {
      for (std::size_t l = 0; l < lines_.size(); ++l)
        for (std::size_t k = 0; k < f.seg[l].size(); ++k) lines_[l].dead[k] = f.seg[l][k] != 0;
      rebuild_rec();
    }
    const std::size_t first_new = lines_.size();
    const std::size_t voids0 = rep_.reseed_voids;
    std::vector<Tip> more;
    reseed(more);
    rep_.reseed_voids_round.push_back(rep_.reseed_voids - voids0);
    grow(std::move(more));
    if (ask_.ties) ties(first_new);
    repeats();
    settle();
    f = pass();
  }
  if (ask_.reseed_rounds <= 0) {
    repeats();
    settle();
    f = pass();
  }
  account(f);
  for (std::size_t l = 0; l < lines_.size(); ++l)
    for (std::size_t k = 0; k < f.seg[l].size(); ++k) lines_[l].dead[k] = f.seg[l][k] != 0;
  rep_.bare_after = bare();
  rep_.tips = tips_;
  rep_.grown_mm = laid_mm_;
  std::vector<Strand> out = strands();
  // I1: strut thickness by stress, on the widths handed back only (the growth and its own pruning used width_).
  if (ask_.width_heavy_mm > 0.0)
    for (Strand& s : out)
      for (std::size_t k = 0; k < s.points.size(); ++k)
        s.width_mm[k] = width_ + (ask_.width_heavy_mm - width_) * share(s.points[k]);
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

Vec3 grown_light(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask, const Vec3& p) {
  GrowReport rep;
  Grower g(domain, region, field, ask, rep);
  if (!g.lit_up()) {
    const double l = len(ask.build_dir);
    return l > 1e-9 ? mul(ask.build_dir, 1.0 / l) : Vec3{0.0, 0.0, 1.0};
  }
  return g.light_at(p);
}

}  // namespace topopt::lattice_layout
