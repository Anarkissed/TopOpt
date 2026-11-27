// Lattice rebuild, Install 3: the places (rule D23). See lattice_layout.hpp, find_places.
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <map>
#include <optional>
#include <set>

#include "topopt/lattice_layout.hpp"

namespace topopt::lattice_layout {
namespace {

constexpr double kInsideMm = 0.05;     // the sample is read this far inside the surface
constexpr double kSampleMm = 0.5;      // samples are about this far apart on a face
constexpr int kMostPerEdge = 64;       // and never more than this many along a triangle's longest edge
const double kCos30 = std::sqrt(3.0) / 2.0;

Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double len(const Vec3& a) { return std::sqrt(dot(a, a)); }

struct Sample {
  Vec3 at{}, normal{};
  double area = 0.0;
};
struct FaceRead {
  double area = 0.0;          // the whole face
  double aligned = 0.0;       // with its outward normal within 30 degrees of the prism's inward direction
  double reached = 0.0;       // reached
  double deep = 0.0;          // reached and deep
  double chip = 0.0;          // reached through a protect_chip entry
  std::vector<Sample> deep_samples;
  Vec3 reached_sum{};         // area-weighted sum of reached sample points
};

// A vertex's place, to a micron: the unwelded mesh's faces meet at shared positions, not shared indices.
std::array<long long, 3> key_of(const Vec3& p) {
  return {std::llround(p.x * 1e6), std::llround(p.y * 1e6), std::llround(p.z * 1e6)};
}

}  // namespace

std::vector<Place> find_places(const StepModel& model, const Domain& domain, const Domain* without_chips,
                               const std::vector<int>& chip_ids, const std::vector<Settings::RegionAsk>& asks,
                               const Layout& layout, double fallback_cell_mm, const std::atomic<bool>* stop) {
  std::vector<Place> out;
  // ★ notes30 Q1: the next lay was asked — none, at once (read once per triangle; never part of a list)
  const auto stopped = [stop] { return stop && stop->load(std::memory_order_relaxed); };
  const TriangleMesh& mesh = model.mesh;
  if (mesh.triangles.empty() || model.triangle_face.size() != mesh.triangles.size()) return out;
  const Domain::Probe probe = domain.probe();
  std::optional<Domain::Probe> bare;
  if (without_chips) bare.emplace(without_chips->probe());
  const std::set<int> chips(chip_ids.begin(), chip_ids.end());

  // The faces: their triangles, and which faces share an edge (by position: the mesh is unwelded).
  std::map<int, std::vector<std::size_t>> tris_of;
  for (std::size_t t = 0; t < mesh.triangles.size(); ++t) tris_of[model.triangle_face[t]].push_back(t);
  std::map<std::pair<std::array<long long, 3>, std::array<long long, 3>>, std::set<int>> edge_faces;
  for (std::size_t t = 0; t < mesh.triangles.size(); ++t) {
    if (stopped()) return {};
    for (int e = 0; e < 3; ++e) {
      auto a = key_of(mesh.vertices[static_cast<std::size_t>(mesh.triangles[t][e])]);
      auto b = key_of(mesh.vertices[static_cast<std::size_t>(mesh.triangles[t][(e + 1) % 3])]);
      if (b < a) std::swap(a, b);
      edge_faces[{a, b}].insert(model.triangle_face[t]);
    }
  }
  std::map<int, std::set<int>> next_to;
  for (const auto& [edge, faces] : edge_faces)
    for (int f : faces)
      for (int g : faces)
        if (f != g) next_to[f].insert(g);

  // The regions it applies to, in id order (the domain's regions are sorted by id, D13).
  for (const Region& region : domain.spec().regions) {
    if (region.role != Role::Lattice || region.is_shell() || !region.prism.valid) continue;
    const Settings::RegionAsk* ask = nullptr;
    for (const Settings::RegionAsk& a : asks)
      if (a.id == region.id) ask = &a;
    if (!ask || ask->zone.kind != Zone::Kind::None) continue;          // a zone has no faces of its own
    if (ask->faces.empty() && ask->pieces.empty()) continue;
    if (domain.cover_depth_mm(&region) > 0.0) continue;               // Finish Covered decides every face
    std::set<int> own(ask->faces.begin(), ask->faces.end());
    for (const FacePiece& p : ask->pieces) own.insert(p.faces.begin(), p.faces.end());

    // The region's own cell: the largest it was laid with, else the cell setting.
    double cell = 0.0;
    for (const RegionCells& rc : layout.regions)
      if (rc.region == region.id) cell = std::max(cell, rc.base_cell_mm);
    if (!(cell > 0.0)) cell = fallback_cell_mm;

    const ClearanceGeometry& g = region.prism;
    const Vec3 in = g.normal;   // into the material
    // The prism's box, to skip faces nowhere near it: its outline (or u/w span) grown by Expand, over its depth.
    double ulo = g.u_lo, uhi = g.u_hi, wlo = g.w_lo, whi = g.w_hi;
    if (!g.outline_uv.empty()) {
      ulo = wlo = 1e300;
      uhi = whi = -1e300;
      for (const auto& loop : g.outline_uv)
        for (const auto& q : loop) {
          ulo = std::min(ulo, q[0]); uhi = std::max(uhi, q[0]);
          wlo = std::min(wlo, q[1]); whi = std::max(whi, q[1]);
        }
    }
    const double grow = std::max(0.0, region.expand_mm) + 1.0;
    Vec3 blo{1e300, 1e300, 1e300}, bhi{-1e300, -1e300, -1e300};
    for (int k = 0; k < 8; ++k) {
      const double u = (k & 1) ? uhi + grow : ulo - grow, w = (k & 2) ? whi + grow : wlo - grow,
                   d = (k & 4) ? g.depth + 1.0 : -1.0;
      const Vec3 p{g.origin.x + g.u.x * u + g.w.x * w + in.x * d, g.origin.y + g.u.y * u + g.w.y * w + in.y * d,
                   g.origin.z + g.u.z * u + g.w.z * w + in.z * d};
      blo = {std::min(blo.x, p.x), std::min(blo.y, p.y), std::min(blo.z, p.z)};
      bhi = {std::max(bhi.x, p.x), std::max(bhi.y, p.y), std::max(bhi.z, p.z)};
    }

    std::map<int, FaceRead> read;
    for (const auto& [face, tris] : tris_of) {
      if (own.count(face)) continue;
      // (a) first, from its triangles alone: the face straight opposite is latticed through and is never sampled.
      {
        double area = 0.0, aligned = 0.0;
        for (std::size_t t : tris) {
          const Vec3& a = mesh.vertices[static_cast<std::size_t>(mesh.triangles[t][0])];
          const Vec3 n2 = cross(sub(mesh.vertices[static_cast<std::size_t>(mesh.triangles[t][1])], a),
                                sub(mesh.vertices[static_cast<std::size_t>(mesh.triangles[t][2])], a));
          const double ar = 0.5 * len(n2);
          if (!(ar > 0.0)) continue;
          area += ar;
          if (dot(n2, in) >= kCos30 * 2.0 * ar) aligned += ar;
        }
        if (area > 0.0 && aligned >= 0.5 * area) continue;
      }
      FaceRead fr;
      bool near = false;
      for (std::size_t t : tris) {
        if (stopped()) return {};
        const Vec3& a = mesh.vertices[static_cast<std::size_t>(mesh.triangles[t][0])];
        const Vec3& b = mesh.vertices[static_cast<std::size_t>(mesh.triangles[t][1])];
        const Vec3& c = mesh.vertices[static_cast<std::size_t>(mesh.triangles[t][2])];
        const Vec3 n2 = cross(sub(b, a), sub(c, a));
        const double area = 0.5 * len(n2);
        if (!(area > 0.0)) continue;
        fr.area += area;
        const Vec3 n{n2.x / (2 * area), n2.y / (2 * area), n2.z / (2 * area)};
        if (dot(n, in) >= kCos30) fr.aligned += area;
        const double tlo[3] = {std::min({a.x, b.x, c.x}), std::min({a.y, b.y, c.y}), std::min({a.z, b.z, c.z})};
        const double thi[3] = {std::max({a.x, b.x, c.x}), std::max({a.y, b.y, c.y}), std::max({a.z, b.z, c.z})};
        if (thi[0] < blo.x || tlo[0] > bhi.x || thi[1] < blo.y || tlo[1] > bhi.y || thi[2] < blo.z || tlo[2] > bhi.z)
          continue;
        near = true;
        const double longest = std::max({len(sub(b, a)), len(sub(c, b)), len(sub(a, c))});
        const int m = std::clamp(static_cast<int>(std::ceil(longest / kSampleMm)), 1, kMostPerEdge);
        const double each = area / (static_cast<double>(m) * m);
        // The m*m small triangles' centres: m(m+1)/2 pointing one way, m(m-1)/2 the other.
        for (int i = 0; i < m; ++i)
          for (int j = 0; i + j < m; ++j)
            for (int flip = 0; flip < 2; ++flip) {
              if (flip && i + j + 1 >= m) continue;
              const double s = (i + (flip ? 2.0 : 1.0) / 3.0) / m, r = (j + (flip ? 2.0 : 1.0) / 3.0) / m;
              const Vec3 p{a.x + s * (b.x - a.x) + r * (c.x - a.x), a.y + s * (b.y - a.y) + r * (c.y - a.y),
                           a.z + s * (b.z - a.z) + r * (c.z - a.z)};
              const Vec3 q{p.x - n.x * kInsideMm, p.y - n.y * kInsideMm, p.z - n.z * kInsideMm};
              const Where wh = probe.where(q);
              bool reached = wh.lattice() && wh.id == region.id, by_chip = false;
              if (!reached && bare && wh.why == Why::ProtectSkin && chips.count(wh.id)) {
                const Where w0 = bare->where(q);
                by_chip = reached = w0.lattice() && w0.id == region.id;
              }
              if (!reached) continue;
              fr.reached += each;
              if (by_chip) fr.chip += each;
              fr.reached_sum = {fr.reached_sum.x + p.x * each, fr.reached_sum.y + p.y * each,
                                fr.reached_sum.z + p.z * each};
              const double below = dot(sub(q, g.origin), in);
              if (region_edge_distance(region, q) > cell && below > cell) {
                fr.deep += each;
                fr.deep_samples.push_back({p, n, each});
              }
            }
      }
      if (near && fr.reached > 0.0) read[face] = std::move(fr);
    }

    // (a) the face straight opposite is latticed through; seeds and joiners by their deep share.
    std::set<int> seeds, joiners;
    for (const auto& [face, fr] : read) {
      if (fr.aligned >= 0.5 * fr.area) continue;
      if (fr.deep >= 0.5 * fr.area) seeds.insert(face);
      else if (fr.deep >= 0.25 * fr.area) joiners.insert(face);
    }
    // Seeds joined across shared edges are one place (in ascending order of their lowest face).
    std::vector<std::vector<int>> groups;
    std::set<int> taken;
    for (int s : seeds) {
      if (taken.count(s)) continue;
      std::vector<int> group, todo{s};
      taken.insert(s);
      while (!todo.empty()) {
        const int f = todo.back();
        todo.pop_back();
        group.push_back(f);
        for (int g2 : next_to[f])
          if (seeds.count(g2) && !taken.count(g2)) { taken.insert(g2); todo.push_back(g2); }
      }
      std::sort(group.begin(), group.end());
      groups.push_back(group);
    }
    // A joiner joins the first place (in that order) it shares an edge with; it never starts one.
    std::vector<std::vector<int>> joined(groups.size());
    for (int j : joiners)
      for (std::size_t k = 0; k < groups.size(); ++k) {
        bool touches = false;
        for (int f : groups[k]) touches = touches || next_to[j].count(f);
        if (touches) { joined[k].push_back(j); break; }
      }
    for (std::size_t k = 0; k < groups.size(); ++k) {
      double seed_reached = 0.0;
      for (int f : groups[k]) seed_reached += read[f].reached;
      if (seed_reached < kPlaceMinMm2) continue;   // under 100 mm2: the rule keeps it lattice
      Place pl;
      pl.region = region.id;
      pl.faces = groups[k];
      std::sort(joined[k].begin(), joined[k].end());
      pl.faces.insert(pl.faces.end(), joined[k].begin(), joined[k].end());
      Vec3 sum{};
      double chip = 0.0;
      for (int f : pl.faces) {
        const FaceRead& fr = read[f];
        pl.area_mm2 += fr.reached;
        chip += fr.chip;
        sum = {sum.x + fr.reached_sum.x, sum.y + fr.reached_sum.y, sum.z + fr.reached_sum.z};
      }
      const Vec3 centre{sum.x / pl.area_mm2, sum.y / pl.area_mm2, sum.z / pl.area_mm2};
      double best = 1e300;
      for (int f : pl.faces)
        for (const Sample& smp : read[f].deep_samples) {
          const double d = len(sub(smp.at, centre));
          if (d < best) { best = d; pl.point = smp.at; pl.normal = smp.normal; }
        }
      // What the engine makes there today, read where the place is pointed at (or, under a chip, its answer).
      const Where at = probe.where({pl.point.x - pl.normal.x * kInsideMm, pl.point.y - pl.normal.y * kInsideMm,
                                    pl.point.z - pl.normal.z * kInsideMm});
      pl.now = chip > 0.5 * pl.area_mm2 ? "solid" : at.lattice() ? "lattice" : "solid";
      out.push_back(std::move(pl));
    }
  }
  return out;
}

}  // namespace topopt::lattice_layout
