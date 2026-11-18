// OP12 (brief C2, E5): synthetic stress for the new engine. Declared in lattice_layout_organic.hpp.
// The owner: "Simulate stresses on unstressed walls" (Organic and Aesthetic only, a Number of foci per wall), and the
// samples that show ONE stress focus on a body with no solve. The old engine's rule for a wall without stress and its
// placing of the foci (organic_lattice.cpp, synthesize_focal_stress) are kept; the field and its magnitude are the
// lead's rulings (the field has three distinct principal stresses; a filled region peaks at the lay's reference).
#include <algorithm>
#include <array>
#include <cmath>
#include <string>
#include <vector>

#include "topopt/lattice_layout_organic.hpp"

namespace topopt::lattice_layout {
namespace {

double von_mises(const double* t) {
  const double a = t[0] - t[1], b = t[1] - t[2], d = t[2] - t[0];
  return std::sqrt(std::max(0.0, 0.5 * (a * a + b * b + d * d) + 3.0 * (t[3] * t[3] + t[4] * t[4] + t[5] * t[5])));
}
Vec3 cross3(const Vec3& a, const Vec3& b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
double norm3(const Vec3& a) { return std::sqrt(a.x * a.x + a.y * a.y + a.z * a.z); }
// v v^T times s, added in Voigt order [xx, yy, zz, xy, yz, zx].
void add_outer(double* T, const Vec3& v, double s) {
  T[0] += s * v.x * v.x;
  T[1] += s * v.y * v.y;
  T[2] += s * v.z * v.z;
  T[3] += s * v.x * v.y;
  T[4] += s * v.y * v.z;
  T[5] += s * v.z * v.x;
}
const OrganicGroup* group_of(const std::vector<OrganicGroup>& groups, int region, int* index) {
  for (std::size_t g = 0; g < groups.size(); ++g)
    if (std::find(groups[g].regions.begin(), groups[g].regions.end(), region) != groups[g].regions.end()) {
      if (index) *index = static_cast<int>(g);
      return &groups[g];
    }
  if (index) *index = -1;
  return nullptr;
}

}  // namespace

SyntheticStress organic_synthetic_stress(const Domain& domain, const TensorField& in,
                                         const std::vector<SyntheticWall>& walls,
                                         const std::vector<OrganicGroup>& groups, const SyntheticStressAsk& how) {
  SyntheticStress out;
  std::vector<int> weave;   // the domain's weave regions, in its order
  for (const Region& r : domain.spec().regions)
    if (r.role == Role::Lattice && r.weave) weave.push_back(r.id);
  // Refusals (E1's list): a count that is not 1 to 5, a region that is not a weave region.
  for (const SyntheticWall& w : walls) {
    if (std::find(weave.begin(), weave.end(), w.region) == weave.end()) {
      OrganicRefusal r;
      r.setting = "region";
      r.code = "not_a_weave_region";
      r.text = "Area " + std::to_string(w.region) + " is not an Organic area, so it cannot have stress simulated.";
      r.given = w.region;
      out.refused.push_back(r);
    }
    if (!(w.foci >= kSyntheticFociMin && w.foci <= kSyntheticFociMax)) {
      OrganicRefusal r;
      r.setting = "foci";
      r.code = "out_of_range";
      r.text = "Number of foci on area " + std::to_string(w.region) + ": it must be a whole number from 1 to 5.";
      r.given = w.foci;
      r.has_min = r.has_max = true;
      r.allowed_min = kSyntheticFociMin;
      r.allowed_max = kSyntheticFociMax;
      out.refused.push_back(r);
    }
  }
  if (!out.refused.empty()) return out;
  // The field: a copy of `in`, or with no input a zero field over the part's box, voxel = half the smallest spacing
  // asked for (over the groups), never over voxel_max_mm.
  out.from_empty = in.empty();
  if (out.from_empty) {
    double small = how.voxel_max_mm * 2.0;
    for (const OrganicGroup& g : groups) {
      const double s = g.ask.spacing_mm > 0.0 ? g.ask.spacing_mm : g.ask.spacing_min_mm;
      if (s > 0.0 && std::isfinite(s)) small = std::min(small, s);
    }
    const double h = std::min(how.voxel_max_mm, 0.5 * small);
    const Vec3 lo = domain.measure().lo(), hi = domain.measure().hi();
    TensorField& f = out.field;
    f.origin = lo;
    f.spacing = h;
    f.nx = std::max(1, static_cast<int>(std::ceil((hi.x - lo.x) / h - 1e-9)));
    f.ny = std::max(1, static_cast<int>(std::ceil((hi.y - lo.y) / h - 1e-9)));
    f.nz = std::max(1, static_cast<int>(std::ceil((hi.z - lo.z) / h - 1e-9)));
    f.voigt.assign(6 * static_cast<std::size_t>(f.nx) * f.ny * f.nz, 0.0);
  } else {
    out.field = in;
  }
  TensorField& f = out.field;
  const std::size_t n = static_cast<std::size_t>(f.nx) * f.ny * f.nz;
  // Each voxel's weave region (its centre lattice of a weave region, as the spacing reads it), and its real von Mises.
  std::vector<int> owner(n, -1);
  std::vector<double> vm(n, 0.0);
  const Domain::Probe probe = domain.probe();
  for (int k = 0; k < f.nz; ++k)
    for (int j = 0; j < f.ny; ++j)
      for (int i = 0; i < f.nx; ++i) {
        const Vec3 c{f.origin.x + (i + 0.5) * f.spacing, f.origin.y + (j + 0.5) * f.spacing,
                     f.origin.z + (k + 0.5) * f.spacing};
        const Where w = probe.where(c);
        if (!w.lattice() || std::find(weave.begin(), weave.end(), w.id) == weave.end()) continue;
        const std::size_t e = f.index(i, j, k);
        owner[e] = w.id;
        vm[e] = von_mises(&f.voigt[6 * e]);
        out.peak_mpa = std::max(out.peak_mpa, vm[e]);
      }
  // K2, the old rule: without stress when the region's p99 is at or under max(dead_fraction x peak, dead_floor).
  out.threshold_mpa = std::max(how.dead_fraction * out.peak_mpa, how.dead_floor_mpa);
  for (const int id : weave) {
    SyntheticRegionReport rep;
    rep.region = id;
    (void)group_of(groups, id, &rep.group);
    std::vector<double> v;
    for (std::size_t e = 0; e < n; ++e)
      if (owner[e] == id) v.push_back(vm[e]);
    rep.voxels = v.size();
    if (!v.empty()) {
      std::sort(v.begin(), v.end());
      rep.p99_mpa = v[static_cast<std::size_t>(std::llround(0.99 * static_cast<double>(v.size() - 1)))];
    }
    rep.threshold_mpa = out.threshold_mpa;
    rep.without_stress = out.from_empty || rep.p99_mpa <= out.threshold_mpa;
    rep.flagged = out.from_empty;
    rep.foci = out.from_empty ? kSyntheticFociDefault : 0;
    for (const SyntheticWall& w : walls)
      if (w.region == id) {
        rep.flagged = true;
        rep.foci = w.foci;
      }
    out.regions.push_back(rep);
  }
  // The reference each group's lay will use for the real field: the stated one, else its percentile of the real von
  // Mises over the group's regions that HAVE stress (O12's index); with none (or no input), 1 MPa.
  auto reference_of = [&](int group) {
    const OrganicAsk ask = group >= 0 ? groups[static_cast<std::size_t>(group)].ask : OrganicAsk{};
    if (ask.reference_mpa > 0.0) return ask.reference_mpa;
    if (out.from_empty) return 1.0;
    std::vector<double> seen;
    for (const SyntheticRegionReport& rep : out.regions) {
      if (rep.without_stress || (group >= 0 && rep.group != group)) continue;
      for (std::size_t e = 0; e < n; ++e)
        if (owner[e] == rep.region) seen.push_back(vm[e]);
    }
    if (seen.empty()) return 1.0;
    std::sort(seen.begin(), seen.end());
    const double q = std::clamp(ask.percentile, 0.0, 1.0);
    const double r = seen[static_cast<std::size_t>(std::floor(q * static_cast<double>(seen.size() - 1)))];
    return r > 0.0 ? r : 1.0;
  };
  // Fill each flagged region without stress.
  for (SyntheticRegionReport& rep : out.regions) {
    if (!rep.flagged || !rep.without_stress || rep.voxels == 0) continue;
    const OrganicGroup* g = group_of(groups, rep.region, nullptr);
    Vec3 up = g ? g->ask.build_dir : Vec3{0.0, 0.0, 1.0};
    const double ul = norm3(up);
    up = ul > 1e-12 ? Vec3{up.x / ul, up.y / ul, up.z / ul} : Vec3{0.0, 0.0, 1.0};
    // The region's box (its voxel centres), its centre, and its two largest extents.
    double lo[3] = {1e300, 1e300, 1e300}, hi[3] = {-1e300, -1e300, -1e300};
    for (int k = 0; k < f.nz; ++k)
      for (int j = 0; j < f.ny; ++j)
        for (int i = 0; i < f.nx; ++i) {
          if (owner[f.index(i, j, k)] != rep.region) continue;
          const double c[3] = {f.origin.x + (i + 0.5) * f.spacing, f.origin.y + (j + 0.5) * f.spacing,
                               f.origin.z + (k + 0.5) * f.spacing};
          for (int a = 0; a < 3; ++a) { lo[a] = std::min(lo[a], c[a]); hi[a] = std::max(hi[a], c[a]); }
        }
    const double ext[3] = {hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]};
    const double mid[3] = {0.5 * (lo[0] + hi[0]), 0.5 * (lo[1] + hi[1]), 0.5 * (lo[2] + hi[2])};
    int axes[3] = {0, 1, 2};
    std::stable_sort(axes, axes + 3, [&ext](int p, int q) { return ext[p] > ext[q]; });
    const int a1 = axes[0], a2 = axes[1];
    const double h1 = 0.5 * ext[a1], h2 = 0.5 * ext[a2];
    rep.soft_mm = how.soft_fraction * std::max({ext[0], ext[1], ext[2]});
    const double soft2 = rep.soft_mm * rep.soft_mm;
    std::vector<std::array<double, 3>> foci;
    std::vector<double> weight;
    for (int q = 0; q < rep.foci; ++q) {
      const double ang = 2.0 * 3.14159265358979323846 * q / rep.foci + how.angle0_rad;
      std::array<double, 3> p = {mid[0], mid[1], mid[2]};
      p[static_cast<std::size_t>(a1)] += how.ellipse * h1 * std::cos(ang);
      p[static_cast<std::size_t>(a2)] += how.ellipse * h2 * std::sin(ang);
      foci.push_back(p);
      weight.push_back(q % 2 == 0 ? 1.0 : -1.0);   // pull, push, alternating
    }
    // T at each voxel of the region; then one factor so that the region's largest von Mises is the reference.
    std::vector<std::size_t> at;
    std::vector<std::array<double, 6>> made;
    double top = 0.0;
    for (int k = 0; k < f.nz; ++k)
      for (int j = 0; j < f.ny; ++j)
        for (int i = 0; i < f.nx; ++i) {
          const std::size_t e = f.index(i, j, k);
          if (owner[e] != rep.region) continue;
          const Vec3 c{f.origin.x + (i + 0.5) * f.spacing, f.origin.y + (j + 0.5) * f.spacing,
                       f.origin.z + (k + 0.5) * f.spacing};
          std::array<double, 6> T{};
          for (std::size_t q = 0; q < foci.size(); ++q) {
            const Vec3 d{c.x - foci[q][0], c.y - foci[q][1], c.z - foci[q][2]};
            const double L = norm3(d);
            if (L < 1e-9) continue;
            const Vec3 r{d.x / L, d.y / L, d.z / L};
            Vec3 t1 = cross3(up, r);
            double l1 = norm3(t1);
            if (l1 < 1e-9) {   // r along the build direction: any unit vector across r
              const Vec3 other = std::fabs(r.x) < 0.9 ? Vec3{1.0, 0.0, 0.0} : Vec3{0.0, 1.0, 0.0};
              t1 = cross3(other, r);
              l1 = norm3(t1);
            }
            t1 = {t1.x / l1, t1.y / l1, t1.z / l1};
            const Vec3 t2 = cross3(r, t1);
            const double gq = weight[q] / (L * L + soft2);
            add_outer(T.data(), r, gq * how.radial);
            add_outer(T.data(), t1, gq * how.across_build);
            add_outer(T.data(), t2, gq * how.across_other);
          }
          const double v = von_mises(T.data());
          if (!(v > 0.0)) continue;   // keeps its real value
          top = std::max(top, v);
          at.push_back(e);
          made.push_back(T);
        }
    if (!(top > 0.0)) continue;
    rep.reference_mpa = reference_of(rep.group);
    rep.factor = rep.reference_mpa / top;
    for (std::size_t m = 0; m < at.size(); ++m)
      for (int c = 0; c < 6; ++c) f.voigt[6 * at[m] + static_cast<std::size_t>(c)] = rep.factor * made[m][static_cast<std::size_t>(c)];
    rep.filled = at.size();
    rep.peak_after_mpa = rep.factor * top;
  }
  return out;
}

SyntheticStress organic_synthetic_stress(Session& session, const Settings& settings, const TensorField& in,
                                         const std::vector<SyntheticWall>& walls,
                                         const std::vector<OrganicGroup>& groups, const SyntheticStressAsk& how) {
  // The domain the lay will lay in (with the groups' flat floor, as Session::lay_organic sets it), made and kept.
  Settings s = settings;
  if (!groups.empty() && groups.front().ask.bed_floor_mm > 0.0) {
    s.bed_floor_mm = groups.front().ask.bed_floor_mm;
    s.bed_up = groups.front().ask.build_dir;
  }
  (void)session.sweep_limits(s, 0.0);
  return organic_synthetic_stress(*session.domain(), in, walls, groups, how);
}

}  // namespace topopt::lattice_layout
