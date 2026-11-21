// The lattice volume check (topopt/lattice_volume_check.hpp states the contract).

#include "topopt/lattice_volume_check.hpp"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <deque>

#include "topopt/lattice_gen.hpp"

namespace topopt {

namespace {

struct CaptureSink : TriangleSink {
  std::vector<std::array<Vec3, 3>> tris;
  void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override {
    tris.push_back({a, b, c});
  }
};

double radical_inverse(std::uint64_t i, std::uint64_t base) {
  double f = 1.0, r = 0.0;
  while (i > 0) {
    f /= static_cast<double>(base);
    r += f * static_cast<double>(i % base);
    i /= base;
  }
  return r;
}

std::uint64_t splitmix64(std::uint64_t x) {
  x += 0x9E3779B97F4A7C15ull;
  x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
  x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
  return x ^ (x >> 31);
}

double unit(std::uint64_t x) { return static_cast<double>(x >> 11) * 0x1.0p-53; }

}  // namespace

void LatticeSolidProbe::add_triangles(const std::vector<std::array<Vec3, 3>>& tris) {
  Piece pc;
  pc.lo = {1e300, 1e300, 1e300};
  pc.hi = {-1e300, -1e300, -1e300};
  Vec3 c{0, 0, 0};
  std::size_t nv = 0;
  for (const auto& t : tris)
    for (const Vec3& v : t) {
      pc.lo = {std::min(pc.lo.x, v.x), std::min(pc.lo.y, v.y), std::min(pc.lo.z, v.z)};
      pc.hi = {std::max(pc.hi.x, v.x), std::max(pc.hi.y, v.y), std::max(pc.hi.z, v.z)};
      c = {c.x + v.x, c.y + v.y, c.z + v.z};
      ++nv;
    }
  if (nv == 0) return;
  c = {c.x / nv, c.y / nv, c.z / nv};
  // One half-space per distinct face plane, oriented so the piece's centroid is inside
  // (the pieces are convex, so this is exact whichever way the emitter winds them).
  for (const auto& t : tris) {
    const Vec3 u{t[1].x - t[0].x, t[1].y - t[0].y, t[1].z - t[0].z};
    const Vec3 w{t[2].x - t[0].x, t[2].y - t[0].y, t[2].z - t[0].z};
    Vec3 n{u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x};
    const double l = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (!(l > 1e-18)) continue;
    n = {n.x / l, n.y / l, n.z / l};
    double d = n.x * t[0].x + n.y * t[0].y + n.z * t[0].z;
    if (n.x * c.x + n.y * c.y + n.z * c.z > d) {
      n = {-n.x, -n.y, -n.z};
      d = -d;
    }
    bool dup = false;
    for (const auto& q : pc.planes)
      if (q[0] * n.x + q[1] * n.y + q[2] * n.z > 1.0 - 1e-12 && std::abs(q[3] - d) < 1e-12) {
        dup = true;
        break;
      }
    if (!dup) pc.planes.push_back({n.x, n.y, n.z, d});
  }
  pieces_.push_back(std::move(pc));
}

void LatticeSolidProbe::add_strut(const Vec3& a, const Vec3& b, double r, int nseg) {
  CaptureSink s;
  lattice_emit_strut(s, a, b, r, nseg);
  add_triangles(s.tris);
}

void LatticeSolidProbe::add_prism(const Vec3& a, const Vec3& b, double circumradius, int nseg) {
  CaptureSink s;
  lattice_emit_prism(s, a, b, circumradius, nseg);
  add_triangles(s.tris);
}

void LatticeSolidProbe::add_ball(const Vec3& c, double r) {
  CaptureSink s;
  lattice_emit_node(s, c, r);
  add_triangles(s.tris);
}

bool LatticeSolidProbe::inside_piece(std::size_t i, const Vec3& p) const {
  const Piece& pc = pieces_[i];
  if (p.x < pc.lo.x || p.y < pc.lo.y || p.z < pc.lo.z || p.x > pc.hi.x || p.y > pc.hi.y ||
      p.z > pc.hi.z)
    return false;
  for (const auto& q : pc.planes)
    if (q[0] * p.x + q[1] * p.y + q[2] * p.z > q[3]) return false;
  return true;
}

namespace {

// Both entry points: sample the probe (frac_in null) or read a measured fraction per voxel
// (frac_in set); either way group the pockets and judge them against the certificate.
LatticeVolumeCheck check_impl(const VoxelGrid& grid, const std::vector<char>& mask,
                              const std::function<double(std::size_t)>& certified_rho,
                              const LatticeSolidProbe* probe_ptr,
                              const std::vector<double>* frac_in,
                              std::vector<double>* frac_out, double judge_min_mm3) {
  const auto t0 = std::chrono::steady_clock::now();
  LatticeVolumeCheck out;
  out.judge_min_mm3 = judge_min_mm3;
  if (mask.size() != grid.voxel_count()) return out;
  if (frac_in ? frac_in->size() != grid.voxel_count() : !(probe_ptr && probe_ptr->has_geometry()))
    return out;
  out.ran = true;
  if (frac_out) frac_out->assign(grid.voxel_count(), 0.0);
  static const LatticeSolidProbe kNoProbe;
  const LatticeSolidProbe& probe = probe_ptr ? *probe_ptr : kNoProbe;
  const double s = grid.spacing, vv = s * s * s;

  // Compact ids for the latticed voxels.
  std::vector<int> id(grid.voxel_count(), -1);
  std::vector<std::size_t> vox;
  for (std::size_t e = 0; e < mask.size(); ++e)
    if (mask[e]) {
      id[e] = static_cast<int>(vox.size());
      vox.push_back(e);
    }
  if (vox.empty()) return out;

  // Pockets: face-connected components, seeded in voxel order (deterministic).
  std::vector<int> pocket(vox.size(), -1);
  int npk = 0;
  for (std::size_t v0 = 0; v0 < vox.size(); ++v0) {
    if (pocket[v0] >= 0) continue;
    std::deque<std::size_t> q{v0};
    pocket[v0] = npk;
    while (!q.empty()) {
      const std::size_t v = q.front();
      q.pop_front();
      const std::size_t e = vox[v];
      const int i = static_cast<int>(e % grid.nx), j = static_cast<int>((e / grid.nx) % grid.ny),
                k = static_cast<int>(e / (static_cast<std::size_t>(grid.nx) * grid.ny));
      static const int d6[6][3] = {{-1, 0, 0}, {1, 0, 0}, {0, -1, 0},
                                   {0, 1, 0},  {0, 0, -1}, {0, 0, 1}};
      for (const auto& d : d6) {
        const int a = i + d[0], b = j + d[1], c = k + d[2];
        if (a < 0 || b < 0 || c < 0 || a >= grid.nx || b >= grid.ny || c >= grid.nz) continue;
        const int n = id[grid.index(a, b, c)];
        if (n < 0 || pocket[static_cast<std::size_t>(n)] >= 0) continue;
        pocket[static_cast<std::size_t>(n)] = npk;
        q.push_back(static_cast<std::size_t>(n));
      }
    }
    ++npk;
  }
  out.pockets.assign(static_cast<std::size_t>(npk), LatticePocketVolume{});
  for (std::size_t v = 0; v < vox.size(); ++v)
    ++out.pockets[static_cast<std::size_t>(pocket[v])].voxels;
  for (LatticePocketVolume& pk : out.pockets) {
    pk.points_per_voxel =
        static_cast<int>(std::clamp<long long>((1LL << 16) / std::max(1LL, pk.voxels), 256, 4096));
    pk.lo = {1e300, 1e300, 1e300};
    pk.hi = {-1e300, -1e300, -1e300};
  }

  // Bin the pieces into the latticed voxels their boxes touch (CSR).
  const auto& P = probe.piece_list();
  auto vrange = [&](double lo, double hi, double o, int n, int* a, int* b) {
    *a = std::max(0, static_cast<int>(std::floor((lo - o) / s)));
    *b = std::min(n - 1, static_cast<int>(std::floor((hi - o) / s)));
  };
  std::vector<std::size_t> start(vox.size() + 1, 0);
  std::vector<int> bins;
  for (int pass = frac_in ? 1 : 0; pass < 2; ++pass) {
    std::vector<std::size_t> fill;
    if (pass == 1 && !frac_in) {
      fill.assign(start.begin(), start.end() - 1);
      bins.assign(start.back(), 0);
    }
    for (std::size_t pi = 0; pi < (frac_in ? 0 : P.size()); ++pi) {
      int i0, i1, j0, j1, k0, k1;
      vrange(P[pi].lo.x, P[pi].hi.x, grid.origin.x, grid.nx, &i0, &i1);
      vrange(P[pi].lo.y, P[pi].hi.y, grid.origin.y, grid.ny, &j0, &j1);
      vrange(P[pi].lo.z, P[pi].hi.z, grid.origin.z, grid.nz, &k0, &k1);
      for (int k = k0; k <= k1; ++k)
        for (int j = j0; j <= j1; ++j)
          for (int i = i0; i <= i1; ++i) {
            const int n = id[grid.index(i, j, k)];
            if (n < 0) continue;
            if (pass == 0)
              ++start[static_cast<std::size_t>(n) + 1];
            else
              bins[fill[static_cast<std::size_t>(n)]++] = static_cast<int>(pi);
          }
    }
    if (pass == 0)
      for (std::size_t v = 0; v < vox.size(); ++v) start[v + 1] += start[v];
    if (pass == 1) {
      // Sample every latticed voxel.
      for (std::size_t v = 0; v < vox.size(); ++v) {
        const std::size_t e = vox[v];
        LatticePocketVolume& pk = out.pockets[static_cast<std::size_t>(pocket[v])];
        const int i = static_cast<int>(e % grid.nx), j = static_cast<int>((e / grid.nx) % grid.ny),
                  k = static_cast<int>(e / (static_cast<std::size_t>(grid.nx) * grid.ny));
        const Vec3 o{grid.origin.x + i * s, grid.origin.y + j * s, grid.origin.z + k * s};
        pk.lo = {std::min(pk.lo.x, o.x), std::min(pk.lo.y, o.y), std::min(pk.lo.z, o.z)};
        pk.hi = {std::max(pk.hi.x, o.x + s), std::max(pk.hi.y, o.y + s),
                 std::max(pk.hi.z, o.z + s)};
        pk.certified_mm3 += certified_rho(e) * vv;
        if (frac_in) {
          pk.exported_mm3 += vv * (*frac_in)[e];
          continue;
        }
        const std::uint64_t h0 = splitmix64(e), h1 = splitmix64(h0), h2 = splitmix64(h1);
        const double sx = unit(h0), sy = unit(h1), sz = unit(h2);
        const int n = pk.points_per_voxel;
        long long in = 0;
        for (int m = 1; m <= n; ++m) {
          double fx = radical_inverse(static_cast<std::uint64_t>(m), 2) + sx;
          double fy = radical_inverse(static_cast<std::uint64_t>(m), 3) + sy;
          double fz = radical_inverse(static_cast<std::uint64_t>(m), 5) + sz;
          fx -= std::floor(fx);
          fy -= std::floor(fy);
          fz -= std::floor(fz);
          const Vec3 p{o.x + fx * s, o.y + fy * s, o.z + fz * s};
          bool hit = false;
          if (probe.inside_fn()) {
            hit = probe.inside_fn()(p);
          } else {
            for (std::size_t b = start[v]; b < start[v + 1] && !hit; ++b)
              hit = probe.inside_piece(static_cast<std::size_t>(bins[b]), p);
          }
          if (hit) ++in;
        }
        out.points += n;
        pk.exported_mm3 += vv * static_cast<double>(in) / n;
        if (frac_out) (*frac_out)[e] = static_cast<double>(in) / n;
      }
    }
  }

  for (std::size_t p = 0; p < out.pockets.size(); ++p) {
    LatticePocketVolume& pk = out.pockets[p];
    pk.gap = pk.certified_mm3 > 0.0 ? pk.exported_mm3 / pk.certified_mm3 - 1.0 : 0.0;
    out.certified_mm3 += pk.certified_mm3;
    out.exported_mm3 += pk.exported_mm3;
    if (static_cast<double>(pk.voxels) * vv < judge_min_mm3) {
      pk.judged = false;
      ++out.small_pockets;
      out.small_certified_mm3 += pk.certified_mm3;
      out.small_exported_mm3 += pk.exported_mm3;
      continue;
    }
    if (out.worst < 0 || pk.gap < out.worst_gap) {
      out.worst = static_cast<int>(p);
      out.worst_gap = pk.gap;
    }
    if (out.highest < 0 || pk.gap > out.highest_gap) {
      out.highest = static_cast<int>(p);
      out.highest_gap = pk.gap;
    }
  }
  out.seconds =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  return out;
}

}  // namespace

LatticeVolumeCheck lattice_volume_check(const VoxelGrid& grid, const std::vector<char>& mask,
                                        const std::function<double(std::size_t)>& certified_rho,
                                        const LatticeSolidProbe& probe, double judge_min_mm3,
                                        std::vector<double>* exported_fraction) {
  return check_impl(grid, mask, certified_rho, &probe, nullptr, exported_fraction,
                    judge_min_mm3);
}

LatticeVolumeCheck lattice_volume_judge(const VoxelGrid& grid, const std::vector<char>& mask,
                                        const std::function<double(std::size_t)>& certified_rho,
                                        const std::vector<double>& exported_fraction,
                                        double judge_min_mm3) {
  return check_impl(grid, mask, certified_rho, nullptr, &exported_fraction, nullptr,
                    judge_min_mm3);
}

LatticeShippedPosture lattice_certify_shipped(const std::vector<char>& mask,
                                              const std::function<double(std::size_t)>& law_rho,
                                              const std::vector<double>& exported_fraction,
                                              double band_min, double voxel_mm3) {
  LatticeShippedPosture r;
  r.relative_density.assign(mask.size(), 0.0);
  for (std::size_t e = 0; e < mask.size(); ++e) {
    if (!mask[e]) continue;
    const double law = law_rho(e);
    const double f = e < exported_fraction.size() ? exported_fraction[e] : 0.0;
    double rho = std::min(law, f);
    r.law_mm3 += law * voxel_mm3;
    if (f < law) ++r.voxels_lowered;
    if (rho < band_min) {
      rho = band_min;
      ++r.voxels_at_floor;
    }
    r.relative_density[e] = rho;
    r.certified_mm3 += rho * voxel_mm3;
  }
  return r;
}

std::string lattice_volume_refusal(const LatticeVolumeCheck& c) {
  if (!c.refused()) return {};
  const LatticePocketVolume& pk = c.pockets[static_cast<std::size_t>(c.worst)];
  char buf[640];
  std::snprintf(
      buf, sizeof buf,
      "the lattice written in one latticed pocket (%lld voxels, x %.1f-%.1f, y %.1f-%.1f, "
      "z %.1f-%.1f mm) holds %.0f mm3 where the certificate counts %.0f mm3 (%+.1f %%, "
      "limit -%.0f %%). The certificate would be judging material the file does not "
      "have, so no lattice is exported for this design.",
      pk.voxels, pk.lo.x, pk.hi.x, pk.lo.y, pk.hi.y, pk.lo.z, pk.hi.z, pk.exported_mm3,
      pk.certified_mm3, 100.0 * pk.gap, 100.0 * kLatticeVolumeGapLimit);
  return buf;
}

}  // namespace topopt
