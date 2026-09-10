// See topopt/lattice_union_volume.hpp for why this measures the set rather than a surface.
#include "topopt/lattice_union_volume.hpp"

#include <algorithm>
#include <cmath>
#include <unordered_map>
#include <vector>

namespace topopt {
namespace {

inline Vec3 sub(const Vec3& a, const Vec3& b) { return Vec3{a.x - b.x, a.y - b.y, a.z - b.z}; }
inline Vec3 add(const Vec3& a, const Vec3& b) { return Vec3{a.x + b.x, a.y + b.y, a.z + b.z}; }
inline Vec3 mul(const Vec3& a, double s) { return Vec3{a.x * s, a.y * s, a.z * s}; }
inline double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }

// squared distance from p to the segment [a,b]
inline double seg_dist2(const Vec3& p, const Vec3& a, const Vec3& ab, double ab2) {
  const Vec3 ap = sub(p, a);
  double t = ab2 > 0.0 ? dot(ap, ab) / ab2 : 0.0;
  t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
  const Vec3 d = sub(ap, mul(ab, t));
  return dot(d, d);
}

// SplitMix64: a small, well-distributed generator, so the draw is reproducible
struct Rng {
  std::uint64_t s;
  explicit Rng(std::uint64_t seed) : s(seed) {}
  std::uint64_t next() {
    std::uint64_t z = (s += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
  }
  double uniform() { return static_cast<double>(next() >> 11) * (1.0 / 9007199254740992.0); }
};

struct Cap {
  Vec3 a{0, 0, 0}, ab{0, 0, 0};
  double r = 0.0, r2 = 0.0, ab2 = 0.0, len = 0.0, vol = 0.0;
  Vec3 lo{0, 0, 0}, hi{0, 0, 0};
};

}  // namespace

LatticeUnionVolume lattice_union_volume(const std::vector<OrganicSpan>& spans,
                                        std::size_t samples, std::uint64_t seed) {
  LatticeUnionVolume out;
  std::vector<Cap> caps;
  caps.reserve(spans.size());
  for (const OrganicSpan& sp : spans) {
    Cap c;
    c.a = sp.a; c.ab = sub(sp.b, sp.a);
    c.ab2 = dot(c.ab, c.ab);
    c.len = std::sqrt(c.ab2);
    c.r = sp.r; c.r2 = sp.r * sp.r;
    if (!(c.r > 0.0)) continue;                     // a zero-radius span has no volume
    c.vol = M_PI * c.r2 * c.len + (4.0 / 3.0) * M_PI * c.r2 * c.r;
    c.lo = Vec3{std::min(sp.a.x, sp.b.x) - c.r, std::min(sp.a.y, sp.b.y) - c.r,
                std::min(sp.a.z, sp.b.z) - c.r};
    c.hi = Vec3{std::max(sp.a.x, sp.b.x) + c.r, std::max(sp.a.y, sp.b.y) + c.r,
                std::max(sp.a.z, sp.b.z) + c.r};
    caps.push_back(c);
  }
  out.capsules = caps.size();
  if (caps.empty()) return out;

  double total = 0.0, rmax = 0.0;
  for (const Cap& c : caps) { total += c.vol; rmax = std::max(rmax, c.r); }
  out.naive_sum_mm3 = total;
  if (!(total > 0.0)) return out;

  // ── a uniform spatial hash, so "which capsules could contain p" is O(1) ─────
  // The cell is sized on the LARGEST capsule radius: any capsule containing p must have
  // its axis within r of p, so only the cells within one cell of p need consulting.
  const double cell = std::max(2.0 * rmax, 1e-6);
  // ★ INJECTIVE, NOT A HASH: a colliding key would hand a sample another cell's capsule
  // list, so an overlap could go unseen and the volume would come out HIGH. 21 bits per
  // axis is exact for any grid this code can build.
  auto key_of = [&](long long i, long long j, long long k) {
    constexpr long long kBias = 1LL << 20;
    return (((i + kBias) & 0x1FFFFF) << 42) | (((j + kBias) & 0x1FFFFF) << 21) |
           ((k + kBias) & 0x1FFFFF); };
  std::unordered_map<long long, std::vector<int>> grid;
  grid.reserve(caps.size() * 2);
  for (std::size_t n = 0; n < caps.size(); ++n) {
    const Cap& c = caps[n];
    const long long i0 = static_cast<long long>(std::floor(c.lo.x / cell));
    const long long i1 = static_cast<long long>(std::floor(c.hi.x / cell));
    const long long j0 = static_cast<long long>(std::floor(c.lo.y / cell));
    const long long j1 = static_cast<long long>(std::floor(c.hi.y / cell));
    const long long k0 = static_cast<long long>(std::floor(c.lo.z / cell));
    const long long k1 = static_cast<long long>(std::floor(c.hi.z / cell));
    for (long long i = i0; i <= i1; ++i)
      for (long long j = j0; j <= j1; ++j)
        for (long long k = k0; k <= k1; ++k) grid[key_of(i, j, k)].push_back(static_cast<int>(n));
  }

  Rng rng(seed);
  double vol = 0.0, var = 0.0;
  std::size_t drawn = 0, owned_total = 0;
  for (std::size_t n = 0; n < caps.size(); ++n) {
    const Cap& c = caps[n];
    // budget in proportion to volume, but never fewer than a handful: a thin capsule
    // still needs an estimate, and its contribution to the total is small either way.
    std::size_t take = static_cast<std::size_t>(
        std::llround(static_cast<double>(samples) * (c.vol / total)));
    take = std::max<std::size_t>(take, 16);
    std::size_t owned = 0;
    for (std::size_t s = 0; s < take; ++s) {
      // draw uniformly inside this capsule: pick the barrel or a cap in proportion to
      // volume, then a uniform point within that piece
      const double cyl = M_PI * c.r2 * c.len;
      Vec3 p;
      if (c.len > 0.0 && rng.uniform() < cyl / c.vol) {
        // uniform in the cylinder: uniform along the axis, uniform in the disc
        const double t = rng.uniform();
        const double rr = c.r * std::sqrt(rng.uniform());
        const double th = 2.0 * M_PI * rng.uniform();
        // any orthonormal pair perpendicular to the axis will do
        Vec3 u = std::fabs(c.ab.z) < 0.9 * c.len ? Vec3{0, 0, 1} : Vec3{1, 0, 0};
        const Vec3 axis = c.len > 0.0 ? mul(c.ab, 1.0 / c.len) : Vec3{0, 0, 1};
        Vec3 e1{axis.y * u.z - axis.z * u.y, axis.z * u.x - axis.x * u.z,
                axis.x * u.y - axis.y * u.x};
        const double e1l = std::sqrt(dot(e1, e1));
        e1 = e1l > 0.0 ? mul(e1, 1.0 / e1l) : Vec3{1, 0, 0};
        const Vec3 e2{axis.y * e1.z - axis.z * e1.y, axis.z * e1.x - axis.x * e1.z,
                      axis.x * e1.y - axis.y * e1.x};
        p = add(add(c.a, mul(c.ab, t)),
                add(mul(e1, rr * std::cos(th)), mul(e2, rr * std::sin(th))));
      } else {
        // uniform in a ball of radius r, then attached to whichever end
        double x, y, z, q;
        do {
          x = 2.0 * rng.uniform() - 1.0; y = 2.0 * rng.uniform() - 1.0;
          z = 2.0 * rng.uniform() - 1.0; q = x * x + y * y + z * z;
        } while (q > 1.0 || q == 0.0);
        const Vec3 d{x * c.r, y * c.r, z * c.r};
        const bool far_end = dot(d, c.ab) > 0.0;     // put it on the end it points at
        p = add(far_end ? add(c.a, c.ab) : c.a, d);
      }
      // ★ OWNERSHIP: this point counts only if no EARLIER capsule already holds it.
      // That is what makes the pieces disjoint, and hence the sum exact.
      bool mine = true;
      const long long ci = static_cast<long long>(std::floor(p.x / cell));
      const long long cj = static_cast<long long>(std::floor(p.y / cell));
      const long long ck = static_cast<long long>(std::floor(p.z / cell));
      for (long long i = ci - 1; i <= ci + 1 && mine; ++i)
        for (long long j = cj - 1; j <= cj + 1 && mine; ++j)
          for (long long k = ck - 1; k <= ck + 1 && mine; ++k) {
            auto it = grid.find(key_of(i, j, k));
            if (it == grid.end()) continue;
            for (int m : it->second) {
              if (static_cast<std::size_t>(m) >= n) continue;   // only EARLIER capsules
              const Cap& o = caps[static_cast<std::size_t>(m)];
              if (seg_dist2(p, o.a, o.ab, o.ab2) <= o.r2) { mine = false; break; }
            }
          }
      if (mine) ++owned;
    }
    const double pn = static_cast<double>(owned) / static_cast<double>(take);
    vol += c.vol * pn;
    // binomial variance of the estimate for this capsule, scaled by its volume
    var += c.vol * c.vol * pn * (1.0 - pn) / static_cast<double>(take);
    drawn += take;
    owned_total += owned;
  }
  out.volume_mm3 = vol;
  out.std_error_mm3 = std::sqrt(var);
  out.samples = drawn;
  out.samples_owned = owned_total;
  out.overlap_fraction = total > 0.0 ? 1.0 - vol / total : 0.0;
  return out;
}

}  // namespace topopt
