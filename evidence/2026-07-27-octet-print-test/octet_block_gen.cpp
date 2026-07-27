// octet_block_gen.cpp — standalone generator for the octet PRINT-TEST blocks
// (handoff 2026-07-27-octet-print-test). NOT a CI test, NOT wired into CTest,
// builds NOTHING into production.
//
// This is a trimmed, fixed-geometry sibling of the PR-201 cost probe
// (core/tests/harness/octet_gen_probe.cpp): the SAME deterministic octet-truss
// swept-solid generator, but pinned to a 5x5x5-cell block at an 8 mm cell
// (40x40x40 mm) so the maintainer gets a concrete, printable test artifact
// instead of a ~58 mm cost-study cube. It reuses that probe's exact strut
// radius formula so the graded block reproduces PR-201's measured strut-
// diameter range (0.96-2.24 mm) byte-for-byte in intent.
//
// Subcommands:
//   uniform <dir>   write octet_uniform_40mm.stl + .3mf   (constant d = 1.60 mm)
//   graded  <dir>   write octet_graded_40mm.stl  + .3mf   (d = 0.96..2.24 mm along z)
//   report  <block> geometry report on the actual 40 mm block (uniform|graded):
//                   welded manifold status, components, node self-intersection
//                   scan, strut-angle-from-vertical histogram, diameter extremes.
//
// The generator is deterministic (fixed traversal order, no RNG, no threads).

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/stl.hpp"
#ifdef OCTET_HAVE_3MF
#include "topopt/threemf.hpp"
#endif

using namespace topopt;

namespace {

// ---- geometry constants (mirror PR-201 mode_case Grade at L=8) --------------
constexpr double kCell = 8.0;       // cell edge, mm
constexpr int kCells = 5;           // 5 cells -> 40 mm block
constexpr int kNseg = 8;            // strut cross-section: octagonal prism
constexpr double kRUniform = 0.10 * kCell;        // 0.80 mm  -> d = 1.60 mm
constexpr double kRMin = 0.6 * kRUniform;         // 0.48 mm  -> d = 0.96 mm
constexpr double kRMax = 1.4 * kRUniform;         // 1.12 mm  -> d = 2.24 mm
constexpr double kSpan = kCells * kCell;          // 40 mm, grading normaliser

// --------------------------------------------------------------------- vec3
struct V3 { double x, y, z; };
V3 operator+(V3 a, V3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
V3 operator-(V3 a, V3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
V3 operator*(V3 a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double dot(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
V3 cross(V3 a, V3 b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double norm(V3 a) { return std::sqrt(dot(a, a)); }
V3 unit(V3 a) { double n = norm(a); return n > 0 ? a * (1.0 / n) : V3{0, 0, 0}; }

// --------------------------------------------------------------------- octet
// 14 reference nodes in half-integer coords (units of L/2): 8 corners + 6 face
// centres. Integer keying makes cell-local ownership exact (no global dedup).
struct INode { int x, y, z; };
std::vector<INode> ref_nodes() {
  std::vector<INode> n;
  for (int z = 0; z <= 2; z += 2)
    for (int y = 0; y <= 2; y += 2)
      for (int x = 0; x <= 2; x += 2) n.push_back({x, y, z});
  n.push_back({1, 1, 0}); n.push_back({1, 1, 2});
  n.push_back({1, 0, 1}); n.push_back({1, 2, 1});
  n.push_back({0, 1, 1}); n.push_back({2, 1, 1});
  return n;
}
enum class Cls { OCTA, LEG };
struct RStrut { INode a, b; Cls cls; int face_axis; int face_side; };
bool is_corner(INode n) { return (n.x % 2 == 0) && (n.y % 2 == 0) && (n.z % 2 == 0); }

std::vector<RStrut> ref_struts() {
  auto nodes = ref_nodes();
  std::vector<INode> corners, faces;
  for (auto n : nodes) (is_corner(n) ? corners : faces).push_back(n);
  std::vector<RStrut> s;
  for (auto f : faces) {  // 24 tetra legs
    int axis = (f.x % 2 == 0) ? 0 : (f.y % 2 == 0) ? 1 : 2;
    int side = (axis == 0) ? f.x : (axis == 1) ? f.y : f.z;
    for (auto c : corners) {
      int cc = (axis == 0) ? c.x : (axis == 1) ? c.y : c.z;
      if (cc == side) s.push_back({f, c, Cls::LEG, axis, side});
    }
  }
  for (std::size_t i = 0; i < faces.size(); ++i)  // 12 octahedron edges
    for (std::size_t j = i + 1; j < faces.size(); ++j) {
      int dx = faces[i].x - faces[j].x, dy = faces[i].y - faces[j].y,
          dz = faces[i].z - faces[j].z;
      if (dx * dx + dy * dy + dz * dz == 2)
        s.push_back({faces[i], faces[j], Cls::OCTA, -1, -1});
    }
  return s;
}

// A full N x N x N block is always latticed; a leg on a max-side face is owned
// only at the grid boundary (else the +neighbour owns it) so each is emitted once.
bool owns_leg(int ci, int cj, int ck, int axis, int side) {
  if (side == 0) return true;
  int ni = ci + (axis == 0), nj = cj + (axis == 1), nk = ck + (axis == 2);
  return (ni >= kCells || nj >= kCells || nk >= kCells);
}
void node_owner(int gx, int gy, int gz, int& oi, int& oj, int& ok) {
  auto own = [](int g) { int o = g / 2; return o < 0 ? 0 : (o >= kCells ? kCells - 1 : o); };
  oi = own(gx); oj = own(gy); ok = own(gz);
}

double strut_radius(bool graded, V3 mid) {
  if (!graded) return kRUniform;
  double t = std::clamp(mid.z / kSpan, 0.0, 1.0);
  double s = t * t * t * (t * (t * 6 - 15) + 10);  // smootherstep
  return kRMin + (kRMax - kRMin) * s;
}

// --------------------------------------------------------------------- emit
struct Sink {
  TriangleMesh* mesh;
  void tri(V3 a, V3 b, V3 c) {
    int base = (int)mesh->vertices.size();
    mesh->vertices.push_back({a.x, a.y, a.z});
    mesh->vertices.push_back({b.x, b.y, b.z});
    mesh->vertices.push_back({c.x, c.y, c.z});
    mesh->triangles.push_back({base, base + 1, base + 2});
  }
};

void emit_strut(Sink& s, V3 p0, V3 p1, double r, int nseg) {
  V3 axis = unit(p1 - p0);
  V3 ref = std::fabs(axis.z) < 0.9 ? V3{0, 0, 1} : V3{1, 0, 0};
  V3 u = unit(cross(axis, ref));
  V3 v = cross(axis, u);
  std::vector<V3> ring0(nseg), ring1(nseg);
  for (int i = 0; i < nseg; ++i) {
    double a = 2.0 * M_PI * i / nseg;
    V3 off = u * (r * std::cos(a)) + v * (r * std::sin(a));
    ring0[i] = p0 + off; ring1[i] = p1 + off;
  }
  for (int i = 0; i < nseg; ++i) {
    int j = (i + 1) % nseg;
    s.tri(ring0[i], ring1[i], ring1[j]);
    s.tri(ring0[i], ring1[j], ring0[j]);
    s.tri(p0, ring0[i], ring0[j]);
    s.tri(p1, ring1[j], ring1[i]);
  }
}

void emit_node(Sink& s, V3 c, double r) {
  const double t = (1.0 + std::sqrt(5.0)) / 2.0;
  double sc = r / std::sqrt(1.0 + t * t);
  std::array<V3, 12> p = {{{-1, t, 0}, {1, t, 0}, {-1, -t, 0}, {1, -t, 0},
                           {0, -1, t}, {0, 1, t}, {0, -1, -t}, {0, 1, -t},
                           {t, 0, -1}, {t, 0, 1}, {-t, 0, -1}, {-t, 0, 1}}};
  for (auto& q : p) q = c + q * sc;
  static const int f[20][3] = {
      {0, 11, 5}, {0, 5, 1}, {0, 1, 7}, {0, 7, 10}, {0, 10, 11},
      {1, 5, 9},  {5, 11, 4}, {11, 10, 2}, {10, 7, 6}, {7, 1, 8},
      {3, 9, 4},  {3, 4, 2},  {3, 2, 6},  {3, 6, 8},  {3, 8, 9},
      {4, 9, 5},  {2, 4, 11}, {6, 2, 10}, {8, 6, 7},  {9, 8, 1}};
  for (auto& tr : f) s.tri(p[tr[0]], p[tr[1]], p[tr[2]]);
}

V3 node_pos(int gx, int gy, int gz) {
  return {gx * 0.5 * kCell, gy * 0.5 * kCell, gz * 0.5 * kCell};
}

struct GenStats {
  std::uint64_t tris = 0, struts = 0, nodes = 0;
  double min_diam = 1e30, max_diam = 0;
};

GenStats generate(bool graded, Sink& sink) {
  static const std::vector<RStrut> RS = ref_struts();
  static const std::vector<INode> RN = ref_nodes();
  GenStats st;
  for (int ck = 0; ck < kCells; ++ck)
    for (int cj = 0; cj < kCells; ++cj)
      for (int ci = 0; ci < kCells; ++ci) {
        int bx = 2 * ci, by = 2 * cj, bz = 2 * ck;
        for (const auto& rs : RS) {
          if (rs.cls == Cls::LEG && !owns_leg(ci, cj, ck, rs.face_axis, rs.face_side))
            continue;
          V3 pa = node_pos(rs.a.x + bx, rs.a.y + by, rs.a.z + bz);
          V3 pb = node_pos(rs.b.x + bx, rs.b.y + by, rs.b.z + bz);
          double r = strut_radius(graded, (pa + pb) * 0.5);
          emit_strut(sink, pa, pb, r, kNseg);
          ++st.struts;
          st.min_diam = std::min(st.min_diam, 2 * r);
          st.max_diam = std::max(st.max_diam, 2 * r);
        }
        for (const auto& rn : RN) {
          int gx = rn.x + bx, gy = rn.y + by, gz = rn.z + bz;
          int oi, oj, ok; node_owner(gx, gy, gz, oi, oj, ok);
          if (!(oi == ci && oj == cj && ok == ck)) continue;  // full block: owner is exact
          double r = strut_radius(graded, node_pos(gx, gy, gz));
          emit_node(sink, node_pos(gx, gy, gz), r);
          ++st.nodes;
        }
      }
  st.tris = sink.mesh->triangles.size();
  return st;
}

// Weld geometrically-identical vertices (quantised to 1e-6 mm) — exactly what an
// STL reader does on re-import; only then is shared-index topology meaningful.
TriangleMesh weld(const TriangleMesh& in) {
  TriangleMesh out;
  std::map<std::array<long long, 3>, int> idx;
  auto key = [](const Vec3& v) {
    return std::array<long long, 3>{(long long)std::llround(v.x * 1e6),
                                    (long long)std::llround(v.y * 1e6),
                                    (long long)std::llround(v.z * 1e6)};
  };
  for (const auto& t : in.triangles) {
    std::array<int, 3> nt;
    for (int c = 0; c < 3; ++c) {
      const Vec3& v = in.vertices[t[c]];
      auto k = key(v);
      auto it = idx.find(k);
      if (it == idx.end()) { int id = (int)out.vertices.size(); idx[k] = id; out.vertices.push_back(v); nt[c] = id; }
      else nt[c] = it->second;
    }
    out.triangles.push_back(nt);
  }
  return out;
}

long file_size(const std::string& p) {
  std::ifstream f(p, std::ios::binary | std::ios::ate);
  return f ? (long)f.tellg() : -1;
}

int mode_write(bool graded, const std::string& dir) {
  TriangleMesh raw;
  Sink sink{&raw};
  GenStats st = generate(graded, sink);
  std::string base = dir + "/octet_" + (graded ? "graded" : "uniform") + "_40mm";
  std::string stlpath = base + ".stl";
  write_stl_file(stlpath, raw, StlFormat::Binary);
  long stl_bytes = file_size(stlpath);
  long mf_bytes = -1;
#ifdef OCTET_HAVE_3MF
  std::string mfpath = base + ".3mf";
  write_3mf_file(mfpath, raw);
  mf_bytes = file_size(mfpath);
#endif
  std::printf("%s block  40x40x40 mm, 5x5x5 cells @ %.0f mm\n",
              graded ? "GRADED " : "UNIFORM", kCell);
  std::printf("  triangles = %llu   struts = %llu   nodes = %llu\n",
              (unsigned long long)st.tris, (unsigned long long)st.struts,
              (unsigned long long)st.nodes);
  std::printf("  strut diameter = %.3f .. %.3f mm\n", st.min_diam, st.max_diam);
  std::printf("  STL = %s (%.2f MB)\n", stlpath.c_str(), stl_bytes / 1e6);
  if (mf_bytes > 0) std::printf("  3MF = %s.3mf (%.2f MB)\n", base.c_str(), mf_bytes / 1e6);
  else std::printf("  3MF = (lib3mf not linked)\n");
  return 0;
}

int mode_report(bool graded) {
  TriangleMesh raw; Sink sink{&raw};
  GenStats st = generate(graded, sink);
  TriangleMesh mesh = weld(raw);
  auto wt = check_watertight(mesh);
  int comps = count_components(mesh);
  Vec3 mn, mx; bounding_box(mesh, mn, mx);
  std::printf("GEOMETRY REPORT — octet %s 40 mm block (5x5x5 cells @ %.0f mm)\n",
              graded ? "GRADED" : "UNIFORM", kCell);
  std::printf("  bbox = [%.3f %.3f %.3f] .. [%.3f %.3f %.3f] mm\n",
              mn.x, mn.y, mn.z, mx.x, mx.y, mx.z);
  std::printf("  raw triangles (STL soup) = %llu   struts = %llu   nodes = %llu\n",
              (unsigned long long)st.tris, (unsigned long long)st.struts,
              (unsigned long long)st.nodes);
  std::printf("  strut diameter = %.3f .. %.3f mm\n", st.min_diam, st.max_diam);
  std::printf("  WELDED by coordinate: %zu verts, %zu tris\n",
              mesh.vertices.size(), mesh.triangles.size());
  std::printf("    boundary_edges     = %d\n", wt.boundary_edges);
  std::printf("    non_manifold_edges = %d  (edges shared by >2 faces)\n",
              wt.non_manifold_edges);
  std::printf("    connected components = %d\n", comps);
  std::printf("    check_watertight = %s\n", wt.watertight ? "PASS" : "FAIL");

  // Bounded self-intersection scan around one interior node (cell 2,2,2 corner).
  V3 centre = node_pos(2 * 2, 2 * 2, 2 * 2);
  double win = 0.6 * kCell;
  std::vector<int> local;
  for (std::size_t t = 0; t < mesh.triangles.size(); ++t) {
    auto& tr = mesh.triangles[t];
    for (int c = 0; c < 3; ++c) {
      Vec3 v = mesh.vertices[tr[c]];
      if (std::fabs(v.x - centre.x) < win && std::fabs(v.y - centre.y) < win &&
          std::fabs(v.z - centre.z) < win) { local.push_back((int)t); break; }
    }
  }
  auto vof = [&](int t, int i) { Vec3 p = mesh.vertices[mesh.triangles[t][i]]; return V3{p.x, p.y, p.z}; };
  auto seg_tri = [&](V3 p, V3 q, V3 a, V3 b, V3 c) {
    V3 e1 = b - a, e2 = c - a, d = q - p, pv = cross(d, e2);
    double det = dot(e1, pv);
    if (std::fabs(det) < 1e-12) return false;
    double inv = 1.0 / det; V3 tv = p - a; double u = dot(tv, pv) * inv;
    if (u < 1e-9 || u > 1 - 1e-9) return false;
    V3 qv = cross(tv, e1); double vv = dot(d, qv) * inv;
    if (vv < 1e-9 || u + vv > 1 - 1e-9) return false;
    double tt = dot(e2, qv) * inv; return tt > 1e-9 && tt < 1 - 1e-9;
  };
  long isect = 0, pairs = 0;
  for (std::size_t i = 0; i < local.size(); ++i)
    for (std::size_t j = i + 1; j < local.size(); ++j) {
      ++pairs;
      int ti = local[i], tj = local[j];
      V3 a0 = vof(ti, 0), a1 = vof(ti, 1), a2 = vof(ti, 2);
      V3 b0 = vof(tj, 0), b1 = vof(tj, 1), b2 = vof(tj, 2);
      bool hit = seg_tri(a0, a1, b0, b1, b2) || seg_tri(a1, a2, b0, b1, b2) ||
                 seg_tri(a2, a0, b0, b1, b2) || seg_tri(b0, b1, a0, a1, a2) ||
                 seg_tri(b1, b2, a0, a1, a2) || seg_tri(b2, b0, a0, a1, a2);
      if (hit) ++isect;
    }
  std::printf("  self-intersection scan @ one interior node: %ld intersecting "
              "pairs of %ld tested (%zu local tris)\n", isect, pairs, local.size());
  std::printf("    => swept-solid union is a %s\n",
              isect > 0 ? "SELF-INTERSECTING SOUP (union step owed)" : "clean body");

  // Strut-angle-from-vertical histogram (reference cell; identical per cell).
  static const std::vector<RStrut> RS = ref_struts();
  std::map<int, long> hist;
  for (const auto& rs : RS) {
    V3 a = node_pos(rs.a.x, rs.a.y, rs.a.z), b = node_pos(rs.b.x, rs.b.y, rs.b.z);
    V3 d = unit(b - a);
    double ang = std::acos(std::clamp(std::fabs(d.z), 0.0, 1.0)) * 180.0 / M_PI;
    hist[(int)(std::llround(ang / 5.0) * 5)]++;
  }
  long total = 0, unsup = 0;
  for (auto& kv : hist) total += kv.second;
  std::printf("  strut angle from VERTICAL (per reference cell, 0=vertical, 90=horizontal):\n");
  for (auto& kv : hist) {
    std::printf("    %2d deg : %ld struts (%.0f%%)\n", kv.first, kv.second, 100.0 * kv.second / total);
    if (kv.first > 45) unsup += kv.second;
  }
  std::printf("    steeper than 45 deg (overhang risk): %ld of %ld (%.0f%%)\n",
              unsup, total, 100.0 * unsup / total);
  std::printf("  NOT a printability verdict — the physical FDM print is owed to the maintainer.\n");
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s {uniform|graded} <dir> | report {uniform|graded}\n", argv[0]);
    return 2;
  }
  std::string cmd = argv[1];
  if (cmd == "uniform" || cmd == "graded") {
    std::string dir = argc > 2 ? argv[2] : ".";
    return mode_write(cmd == "graded", dir);
  }
  if (cmd == "report") {
    std::string which = argc > 2 ? argv[2] : "uniform";
    return mode_report(which == "graded");
  }
  std::fprintf(stderr, "unknown subcommand: %s\n", cmd.c_str());
  return 2;
}
