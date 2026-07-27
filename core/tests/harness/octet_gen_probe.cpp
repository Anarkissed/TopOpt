// octet_gen_probe.cpp — measurement harness (NOT a CI test) for the octet-truss
// GENERATION COST Phase-0 study (handoff 2026-07-26-octet-generation-cost).
//
// READ-ONLY / MEASUREMENT ONLY. Builds NOTHING into production. It constructs an
// octet-truss lattice over a programmatically-defined region (the sanctioned
// cg_tol_probe / lattice_probe pattern — geometry built directly in code, no
// fixtures) and meshes each strut as a SWEPT SOLID (a capped n-gon prism) rather
// than by isosurface extraction on an occupancy field. This is the hypothesis the
// task tests: octet struts mesh far cheaper as swept solids than the 18-24 M
// triangles PR 184 measured via marching cubes.
//
// It measures, over the octet case only:
//   O1 TRIANGLES + MEMORY vs CELL SIZE  (4,6,8,12 mm over ~200 cm^3)
//   O2 REGION FRACTION                  (100/50/20 % latticed)
//   O3 STREAMING                        (slab-by-slab; peak RSS flat in output?)
//   O4 GRADED vs UNIFORM                (stress-field r(x) vs constant r)
//   O5 WATERTIGHTNESS AT THE SHELL      (manifold edges, components, self-isect)
//   O6 PRINTABILITY                     (strut-angle-from-vertical, min diameter)
//   B2 SELF-CHECK                       (one strut volume vs analytic prism)
//
// The generator is deterministic (fixed traversal order, no RNG, no threads), so
// the same inputs produce byte-identical output (B3).
//
// Build (standalone; NOT wired into CTest), from core/. See build_octet_probe.sh
// in the evidence dir for the exact command with the lib3mf paths resolved.
//
// Subcommands (argv[1]) — one process per case so getrusage(ru_maxrss), a
// monotonic high-water mark, reports that case's own peak:
//   selfcheck                         B2
//   case <L> <frac> <graded 0|1> <stream 0|1> <write 0|1>   one O1/O2/O3/O4 row
//   watertight <L>                    O5 detail on a small block
//   angles <L>                        O6 strut-angle + min-diameter distribution
// Env: OCTET_CSV=<path> appends a CSV row (case mode); OCTET_OUT=<dir> for files.

#include <sys/resource.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
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

// --------------------------------------------------------------------------- util
double peak_rss_mb() {
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  return static_cast<double>(ru.ru_maxrss) / (1024.0 * 1024.0);  // bytes on macOS
}

double now_s() {
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  double u = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec * 1e-6;
  double s = ru.ru_stime.tv_sec + ru.ru_stime.tv_usec * 1e-6;
  return u + s;
}

struct V3 {
  double x, y, z;
};
V3 operator+(V3 a, V3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
V3 operator-(V3 a, V3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
V3 operator*(V3 a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double dot(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
V3 cross(V3 a, V3 b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double norm(V3 a) { return std::sqrt(dot(a, a)); }
V3 unit(V3 a) {
  double n = norm(a);
  return n > 0 ? a * (1.0 / n) : V3{0, 0, 0};
}

// --------------------------------------------------------------------------- octet
// The 14 nodes of the reference cell in HALF-integer coordinates (units of L/2),
// so every node component is an integer in {0,1,2}. Corners are even/even/even;
// face centres have exactly one even component (the face's fixed axis) and two
// odd. This integer keying is what makes cell-local ownership (dedup without a
// global set — the O3 streaming requirement) exact.
struct INode {
  int x, y, z;
};
bool operator==(INode a, INode b) { return a.x == b.x && a.y == b.y && a.z == b.z; }

std::vector<INode> ref_nodes() {
  std::vector<INode> n;
  for (int z = 0; z <= 2; z += 2)
    for (int y = 0; y <= 2; y += 2)
      for (int x = 0; x <= 2; x += 2) n.push_back({x, y, z});  // 8 corners
  n.push_back({1, 1, 0});  // face centres
  n.push_back({1, 1, 2});
  n.push_back({1, 0, 1});
  n.push_back({1, 2, 1});
  n.push_back({0, 1, 1});
  n.push_back({2, 1, 1});
  return n;
}

// A reference strut plus its dedup class.
//   OCTA  : an octahedron edge (face-centre to face-centre); interior to the
//           cell, never shared, always owned by the cell.
//   LEG   : a tetrahedron leg (face-centre to cube corner); lies in ONE cube
//           face plane and is shared with the neighbour across that face. Owned
//           by the cell on the min side of that face (see owns_leg).
enum class Cls { OCTA, LEG };
struct RStrut {
  INode a, b;
  Cls cls;
  int face_axis;  // for LEG: 0=x,1=y,2=z
  int face_side;  // for LEG: 0 (min plane) or 2 (max plane)
};

bool is_corner(INode n) {
  return (n.x % 2 == 0) && (n.y % 2 == 0) && (n.z % 2 == 0);
}
bool is_facecentre(INode n) { return !is_corner(n); }

std::vector<RStrut> ref_struts() {
  auto nodes = ref_nodes();
  std::vector<INode> corners, faces;
  for (auto n : nodes)
    (is_corner(n) ? corners : faces).push_back(n);

  std::vector<RStrut> s;
  // 24 tetra legs: each face centre to the 4 corners sharing its face plane.
  for (auto f : faces) {
    int axis = (f.x % 2 == 0) ? 0 : (f.y % 2 == 0) ? 1 : 2;  // the even (fixed) axis
    int side = (axis == 0) ? f.x : (axis == 1) ? f.y : f.z;  // 0 or 2
    for (auto c : corners) {
      int cc = (axis == 0) ? c.x : (axis == 1) ? c.y : c.z;
      if (cc == side) s.push_back({f, c, Cls::LEG, axis, side});
    }
  }
  // 12 octahedron edges: face centres whose squared distance is 2 (adjacent
  // faces), each pair once.
  for (std::size_t i = 0; i < faces.size(); ++i)
    for (std::size_t j = i + 1; j < faces.size(); ++j) {
      int dx = faces[i].x - faces[j].x, dy = faces[i].y - faces[j].y,
          dz = faces[i].z - faces[j].z;
      if (dx * dx + dy * dy + dz * dz == 2)
        s.push_back({faces[i], faces[j], Cls::OCTA, -1, -1});
    }
  return s;
}

// --------------------------------------------------------------------------- region
// A rectangular block of Nx*Ny*Nz cells, edge L mm. Region fraction keeps the
// cells within a centred sub-box of the target volume-fraction (a deterministic,
// contiguous sub-region — the realistic "lattice the core, leave a solid rim"
// case, not a random speckle).
struct Region {
  int nx, ny, nz;
  double L;
  double frac;  // 0..1 of cells latticed
};

// Is cell (ci,cj,ck) latticed? Centred axis-aligned sub-box scaled by frac^(1/3).
bool cell_latticed(const Region& R, int ci, int cj, int ck) {
  if (R.frac >= 1.0) return true;
  double t = std::cbrt(R.frac);
  auto in = [&](int c, int n) {
    double lo = 0.5 * n * (1.0 - t), hi = 0.5 * n * (1.0 + t);
    double m = c + 0.5;
    return m >= lo && m < hi;
  };
  return in(ci, R.nx) && in(cj, R.ny) && in(ck, R.nz);
}

// Node-owner cell under the even/odd mapping, clamped to the grid. Even component
// (corner on that axis) -> coord/2; odd (face centre) -> (coord-1)/2. A node
// shared by several cells resolves to exactly one owner.
void node_owner(const Region& R, int gx, int gy, int gz, int& oi, int& oj,
                int& ok) {
  auto own = [](int g, int n) {
    int o = g / 2;  // integer floor for the even case; (odd-1)/2 == odd/2
    if (o < 0) o = 0;
    if (o >= n) o = n - 1;
    return o;
  };
  oi = own(gx, R.nx);
  oj = own(gy, R.ny);
  ok = own(gz, R.nz);
}

// Does cell (ci,cj,ck) own this LEG? Min-side faces (side 0) are always owned by
// the cell; max-side faces (side 2) are owned only when there is no latticed
// neighbour on the + side (region boundary), so each shared leg is emitted once.
bool owns_leg(const Region& R, int ci, int cj, int ck, int axis, int side) {
  if (side == 0) return true;
  int ni = ci + (axis == 0), nj = cj + (axis == 1), nk = ck + (axis == 2);
  if (ni >= R.nx || nj >= R.ny || nk >= R.nz) return true;  // grid boundary
  return !cell_latticed(R, ni, nj, nk);                     // fraction boundary
}

// --------------------------------------------------------------------------- grading
// Synthetic "stress" field driving graded strut radius. A smooth field high near
// one loaded face and low at the far end — the load-transfer gradient that a
// slicer modifier CANNOT express without a seam. Returns r in [r_min, r_max].
struct Grade {
  bool on;
  double r_uniform;  // uniform radius (mm)
  double r_min, r_max;
  double span;  // region diagonal for normalisation
};
double strut_radius(const Grade& G, V3 mid) {
  if (!G.on) return G.r_uniform;
  // normalised height 0..1 along z, smootherstep for a continuous gradient
  double t = std::clamp(mid.z / G.span, 0.0, 1.0);
  double s = t * t * t * (t * (t * 6 - 15) + 10);
  return G.r_min + (G.r_max - G.r_min) * s;
}

// --------------------------------------------------------------------------- mesh emit
// A minimal triangle sink. Streaming mode flushes to a binary-STL body writer and
// keeps only the current cell's triangles; in-memory mode accumulates the whole
// TriangleMesh (for watertight checks and lib3mf, which is not streamable).
struct StreamStlWriter {
  std::ofstream os;
  std::uint32_t count = 0;
  bool open(const std::string& path) {
    os.open(path, std::ios::binary);
    if (!os) return false;
    char header[80] = {0};
    std::snprintf(header, sizeof(header), "octet-probe streaming binary STL");
    os.write(header, 80);
    std::uint32_t placeholder = 0;  // O3: header triangle count written now as a
    os.write(reinterpret_cast<char*>(&placeholder), 4);  // placeholder, patched
    return true;                                         // by seek-back at close.
  }
  void tri(V3 a, V3 b, V3 c) {
    V3 n = unit(cross(b - a, c - a));
    float rec[12] = {(float)n.x, (float)n.y, (float)n.z,
                     (float)a.x, (float)a.y, (float)a.z,
                     (float)b.x, (float)b.y, (float)b.z,
                     (float)c.x, (float)c.y, (float)c.z};
    os.write(reinterpret_cast<char*>(rec), 48);
    std::uint16_t attr = 0;
    os.write(reinterpret_cast<char*>(&attr), 2);
    ++count;
  }
  void close() {
    os.seekp(80, std::ios::beg);  // O3: seek-back to patch the header count
    os.write(reinterpret_cast<char*>(&count), 4);
    os.close();
  }
};

// Sink abstraction: either stream to disk or accumulate a TriangleMesh.
struct Sink {
  bool streaming;
  StreamStlWriter* sw = nullptr;
  TriangleMesh* mesh = nullptr;
  std::uint64_t tris = 0;
  void tri(V3 a, V3 b, V3 c) {
    ++tris;
    if (streaming) {
      sw->tri(a, b, c);
    } else {
      int base = (int)mesh->vertices.size();
      mesh->vertices.push_back({a.x, a.y, a.z});
      mesh->vertices.push_back({b.x, b.y, b.z});
      mesh->vertices.push_back({c.x, c.y, c.z});
      mesh->triangles.push_back({base, base + 1, base + 2});
    }
  }
};

// Emit a capped n-gon prism (swept-solid strut) from p0 to p1 with radius r.
// Wall: 2*nseg tris; two flat caps (fans): nseg tris each -> 4*nseg total. Each
// prism is individually a closed 2-manifold solid (self-check B2 relies on this).
void emit_strut(Sink& sink, V3 p0, V3 p1, double r, int nseg) {
  V3 axis = unit(p1 - p0);
  // an orthonormal frame perpendicular to the axis
  V3 ref = std::fabs(axis.z) < 0.9 ? V3{0, 0, 1} : V3{1, 0, 0};
  V3 u = unit(cross(axis, ref));
  V3 v = cross(axis, u);
  std::vector<V3> ring0(nseg), ring1(nseg);
  for (int i = 0; i < nseg; ++i) {
    double a = 2.0 * M_PI * i / nseg;
    V3 off = u * (r * std::cos(a)) + v * (r * std::sin(a));
    ring0[i] = p0 + off;
    ring1[i] = p1 + off;
  }
  // All triangles wound consistently (inward-facing here; signed_volume returns
  // -V, callers take the magnitude). Consistency — not the sign — is what makes
  // each prism a closed 2-manifold; the caps must match the wall winding.
  for (int i = 0; i < nseg; ++i) {
    int j = (i + 1) % nseg;
    sink.tri(ring0[i], ring1[i], ring1[j]);  // wall
    sink.tri(ring0[i], ring1[j], ring0[j]);
    sink.tri(p0, ring0[i], ring0[j]);  // cap 0 (fan), matches wall winding
    sink.tri(p1, ring1[j], ring1[i]);  // cap 1 (fan), matches wall winding
  }
}

// Emit an icosahedron of radius r at centre c (20 tris) — the node joint that
// makes the strut union a solid body at each vertex.
void emit_node(Sink& sink, V3 c, double r) {
  const double t = (1.0 + std::sqrt(5.0)) / 2.0;
  double s = r / std::sqrt(1.0 + t * t);
  std::array<V3, 12> p = {{{-1, t, 0}, {1, t, 0}, {-1, -t, 0}, {1, -t, 0},
                           {0, -1, t}, {0, 1, t}, {0, -1, -t}, {0, 1, -t},
                           {t, 0, -1}, {t, 0, 1}, {-t, 0, -1}, {-t, 0, 1}}};
  for (auto& q : p) q = c + q * s;
  static const int f[20][3] = {
      {0, 11, 5}, {0, 5, 1}, {0, 1, 7}, {0, 7, 10}, {0, 10, 11},
      {1, 5, 9},  {5, 11, 4}, {11, 10, 2}, {10, 7, 6}, {7, 1, 8},
      {3, 9, 4},  {3, 4, 2},  {3, 2, 6},  {3, 6, 8},  {3, 8, 9},
      {4, 9, 5},  {2, 4, 11}, {6, 2, 10}, {8, 6, 7},  {9, 8, 1}};
  for (auto& tr : f) sink.tri(p[tr[0]], p[tr[1]], p[tr[2]]);
}

// --------------------------------------------------------------------------- generate
struct GenStats {
  std::uint64_t tris = 0;
  std::uint64_t strut_tris = 0;
  std::uint64_t node_tris = 0;
  std::uint64_t struts = 0;
  std::uint64_t nodes = 0;
  double min_diam = 1e30;
  double max_diam = 0;
};

V3 node_pos(const Region& R, int gx, int gy, int gz) {
  return {gx * 0.5 * R.L, gy * 0.5 * R.L, gz * 0.5 * R.L};
}

// Walk cells in a fixed order; for each latticed cell emit the struts and nodes it
// owns. Cell-local ownership -> no global dedup set -> peak memory independent of
// region size when streaming.
GenStats generate(const Region& R, const Grade& G, int nseg, int node_res_unused,
                  Sink& sink) {
  (void)node_res_unused;
  static const std::vector<RStrut> RS = ref_struts();
  GenStats st;
  for (int ck = 0; ck < R.nz; ++ck)
    for (int cj = 0; cj < R.ny; ++cj)
      for (int ci = 0; ci < R.nx; ++ci) {
        if (!cell_latticed(R, ci, cj, ck)) continue;
        int bx = 2 * ci, by = 2 * cj, bz = 2 * ck;
        // struts
        for (const auto& rs : RS) {
          if (rs.cls == Cls::LEG &&
              !owns_leg(R, ci, cj, ck, rs.face_axis, rs.face_side))
            continue;
          INode a = {rs.a.x + bx, rs.a.y + by, rs.a.z + bz};
          INode b = {rs.b.x + bx, rs.b.y + by, rs.b.z + bz};
          V3 pa = node_pos(R, a.x, a.y, a.z);
          V3 pb = node_pos(R, b.x, b.y, b.z);
          double r = strut_radius(G, (pa + pb) * 0.5);
          std::uint64_t before = sink.tris;
          emit_strut(sink, pa, pb, r, nseg);
          st.strut_tris += sink.tris - before;
          ++st.struts;
          st.min_diam = std::min(st.min_diam, 2 * r);
          st.max_diam = std::max(st.max_diam, 2 * r);
        }
        // nodes (own each candidate node whose owner is this cell; if the owner
        // cell is not latticed, fall back to the lex-smallest latticed sharer)
        static const std::vector<INode> RN = ref_nodes();
        for (const auto& rn : RN) {
          int gx = rn.x + bx, gy = rn.y + by, gz = rn.z + bz;
          int oi, oj, ok;
          node_owner(R, gx, gy, gz, oi, oj, ok);
          bool own;
          if (cell_latticed(R, oi, oj, ok)) {
            own = (oi == ci && oj == cj && ok == ck);
          } else {
            // fallback: this cell owns it iff it is the lex-smallest latticed
            // cell touching the node
            own = true;
            for (int dk = -1; dk <= 0 && own; ++dk)
              for (int dj = -1; dj <= 0 && own; ++dj)
                for (int di = -1; di <= 0 && own; ++di) {
                  int nci = (gx % 2 == 0 ? gx / 2 + di : gx / 2),
                      ncj = (gy % 2 == 0 ? gy / 2 + dj : gy / 2),
                      nck = (gz % 2 == 0 ? gz / 2 + dk : gz / 2);
                  if (nci < 0 || ncj < 0 || nck < 0) continue;
                  if (nci >= R.nx || ncj >= R.ny || nck >= R.nz) continue;
                  if (!cell_latticed(R, nci, ncj, nck)) continue;
                  if (nci < ci || (nci == ci && ncj < cj) ||
                      (nci == ci && ncj == cj && nck < ck))
                    own = false;  // a smaller latticed cell will emit it
                }
          }
          if (!own) continue;
          double r = strut_radius(G, node_pos(R, gx, gy, gz));
          std::uint64_t before = sink.tris;
          emit_node(sink, node_pos(R, gx, gy, gz), r);
          st.node_tris += sink.tris - before;
          ++st.nodes;
        }
      }
  st.tris = sink.tris;
  return st;
}

// Count latticed cells (for the ACHIEVED region fraction — the discretised grid
// cannot hit an arbitrary target exactly).
long latticed_cells(const Region& R) {
  long n = 0;
  for (int ck = 0; ck < R.nz; ++ck)
    for (int cj = 0; cj < R.ny; ++cj)
      for (int ci = 0; ci < R.nx; ++ci)
        if (cell_latticed(R, ci, cj, ck)) ++n;
  return n;
}

// Region sized to ~200 cm^3 = 200000 mm^3, cube-ish, cells = round(edge/L).
Region region_200cc(double L, double frac) {
  double edge = std::cbrt(200000.0);  // ~58.48 mm
  int n = std::max(1, (int)std::llround(edge / L));
  return {n, n, n, L, frac};
}

// --------------------------------------------------------------------------- CSV
void csv_row(const std::string& tag, double L, double frac, double frac_actual,
             bool graded, bool streaming, const GenStats& st, double peak,
             double wall, long stl_bytes, long mf_bytes) {
  const char* path = std::getenv("OCTET_CSV");
  if (!path) return;
  bool exists = false;
  {
    std::ifstream f(path);
    exists = f.good() && f.peek() != std::ifstream::traits_type::eof();
  }
  std::ofstream f(path, std::ios::app);
  if (!exists)
    f << "tag,cell_mm,frac_target,frac_actual,graded,streaming,tris,strut_tris,"
         "node_tris,struts,nodes,peak_rss_mb,wall_s,stl_bytes,mf_bytes,"
         "min_diam_mm,max_diam_mm\n";
  f << tag << ',' << L << ',' << frac << ',' << frac_actual << ','
    << (graded ? 1 : 0) << ',' << (streaming ? 1 : 0) << ',' << st.tris << ','
    << st.strut_tris << ',' << st.node_tris << ',' << st.struts << ','
    << st.nodes << ',' << peak << ',' << wall << ',' << stl_bytes << ','
    << mf_bytes << ',' << st.min_diam << ',' << st.max_diam << '\n';
}

long file_size(const std::string& p) {
  std::ifstream f(p, std::ios::binary | std::ios::ate);
  return f ? (long)f.tellg() : -1;
}

// Weld geometrically-identical vertices (quantised to 1e-6 mm) so the shared-
// index topology check_watertight / count_components rely on is meaningful. The
// Sink emits 3 fresh vertices per triangle; this is the equivalent of what the
// STL reader does on re-import (weld by exact coordinate).
TriangleMesh weld(const TriangleMesh& in) {
  TriangleMesh out;
  std::map<std::array<long long, 3>, int> idx;
  auto key = [](const Vec3& v) {
    return std::array<long long, 3>{(long long)std::llround(v.x * 1e6),
                                    (long long)std::llround(v.y * 1e6),
                                    (long long)std::llround(v.z * 1e6)};
  };
  out.triangles.reserve(in.triangles.size());
  for (const auto& t : in.triangles) {
    std::array<int, 3> nt;
    for (int c = 0; c < 3; ++c) {
      const Vec3& v = in.vertices[t[c]];
      auto k = key(v);
      auto it = idx.find(k);
      if (it == idx.end()) {
        int id = (int)out.vertices.size();
        idx[k] = id;
        out.vertices.push_back(v);
        nt[c] = id;
      } else {
        nt[c] = it->second;
      }
    }
    out.triangles.push_back(nt);
  }
  return out;
}

// =========================================================================== modes
int mode_selfcheck() {
  // B2: one capped n-gon prism, mesh volume vs the analytic prism volume.
  const int nseg = 8;
  const double r = 1.0, L = 10.0;
  TriangleMesh raw;
  Sink sink{false, nullptr, &raw};
  emit_strut(sink, {0, 0, 0}, {0, 0, L}, r, nseg);
  TriangleMesh m = weld(raw);
  double vmesh = std::fabs(signed_volume(m));
  double vprism = nseg * 0.5 * std::sin(2 * M_PI / nseg) * r * r * L;  // exact n-gon
  double vcyl = M_PI * r * r * L;
  auto wt = check_watertight(m);
  std::printf("B2 SELF-CHECK — one capped %d-gon prism, r=%.3f L=%.3f mm\n", nseg,
              r, L);
  std::printf("   mesh signed volume  = %.6f mm^3\n", vmesh);
  std::printf("   analytic n-gon prism= %.6f mm^3   (rel err %.3e)\n", vprism,
              std::fabs(vmesh - vprism) / vprism);
  std::printf("   ideal round cylinder= %.6f mm^3   (tessellation deficit %.2f%%)\n",
              vcyl, 100.0 * (vcyl - vprism) / vcyl);
  std::printf("   triangles=%zu  watertight=%s (boundary=%d nonmanifold=%d)\n",
              m.triangle_count(), wt.watertight ? "YES" : "NO", wt.boundary_edges,
              wt.non_manifold_edges);
  bool ok = std::fabs(vmesh - vprism) / vprism < 1e-3;
  std::printf("   => %s (match to >=3 digits)\n", ok ? "PASS" : "FAIL");
  return ok ? 0 : 1;
}

int mode_case(int argc, char** argv) {
  if (argc < 7) {
    std::fprintf(stderr,
                 "usage: case <L_mm> <frac> <graded 0|1> <stream 0|1> <write 0|1>\n");
    return 2;
  }
  double L = std::atof(argv[2]);
  double frac = std::atof(argv[3]);
  bool graded = std::atoi(argv[4]) != 0;
  bool stream = std::atoi(argv[5]) != 0;
  bool write = std::atoi(argv[6]) != 0;

  Region R = region_200cc(L, frac);
  long ncells = (long)R.nx * R.ny * R.nz;
  long lcells = latticed_cells(R);
  double frac_actual = (double)lcells / ncells;
  double span = R.nz * L;
  // uniform radius: fix the volume fraction at a representative ~0.20 of solid at
  // 8mm by targeting r/L ~= 0.10; grading swings +-50% about it.
  double r_uniform = 0.10 * L;
  Grade G{graded, r_uniform, 0.6 * r_uniform, 1.4 * r_uniform, span};

  const int nseg = 8;
  std::string outdir = std::getenv("OCTET_OUT") ? std::getenv("OCTET_OUT") : ".";
  char base[256];
  std::snprintf(base, sizeof(base), "%s/octet_L%.0f_f%.0f_%s", outdir.c_str(), L,
                frac * 100, graded ? "graded" : "uniform");
  std::string stlpath = std::string(base) + ".stl";

  double t0 = now_s();
  GenStats st;
  long stl_bytes = -1, mf_bytes = -1;
  TriangleMesh mesh;  // only populated in non-streaming

  if (stream) {
    StreamStlWriter sw;
    if (!sw.open(stlpath)) {
      std::fprintf(stderr, "cannot open %s\n", stlpath.c_str());
      return 1;
    }
    Sink sink{true, &sw, nullptr};
    st = generate(R, G, nseg, 0, sink);
    sw.close();
    stl_bytes = file_size(stlpath);
    if (!write) std::remove(stlpath.c_str());
  } else {
    Sink sink{false, nullptr, &mesh};
    st = generate(R, G, nseg, 0, sink);
    if (write) {
      write_stl_file(stlpath, mesh, StlFormat::Binary);
      stl_bytes = file_size(stlpath);
#ifdef OCTET_HAVE_3MF
      std::string mfpath = std::string(base) + ".3mf";
      write_3mf_file(mfpath, mesh);
      mf_bytes = file_size(mfpath);
#endif
    } else {
      stl_bytes = 84 + 50 * (long)st.tris;  // exact binary-STL size
    }
  }
  double wall = now_s() - t0;
  double peak = peak_rss_mb();

  std::printf(
      "CASE L=%.0fmm frac=%.0f%%(actual %.0f%%, %ld/%ld cells) %s %s | "
      "cells=%dx%dx%d tris=%llu (strut=%llu node=%llu) struts=%llu nodes=%llu\n",
      L, frac * 100, frac_actual * 100, lcells, ncells,
      graded ? "graded" : "uniform", stream ? "STREAM" : "INMEM", R.nx, R.ny,
      R.nz, (unsigned long long)st.tris, (unsigned long long)st.strut_tris,
      (unsigned long long)st.node_tris, (unsigned long long)st.struts,
      (unsigned long long)st.nodes);
  std::printf(
      "   peak_rss=%.1f MB  wall=%.3f s  stl=%.2f MB  min_d=%.3f max_d=%.3f mm\n",
      peak, wall, stl_bytes / 1e6, st.min_diam, st.max_diam);
  if (mf_bytes > 0) std::printf("   3mf=%.2f MB\n", mf_bytes / 1e6);

  const char* tag = stream ? "stream" : "inmem";
  csv_row(tag, L, frac, frac_actual, graded, stream, st, peak, wall, stl_bytes,
          mf_bytes);
  return 0;
}

int mode_watertight(int argc, char** argv) {
  // O5: build a SMALL block (2x2x2 cells) fully in memory, report edge-manifold
  // status, connected components, and a bounded triangle-triangle self-
  // intersection scan at the shared nodes.
  double L = argc > 2 ? std::atof(argv[2]) : 8.0;
  Region R{2, 2, 2, L, 1.0};
  Grade G{false, 0.10 * L, 0, 0, R.nz * L};
  TriangleMesh raw;
  Sink sink{false, nullptr, &raw};
  GenStats st = generate(R, G, 8, 0, sink);
  TriangleMesh mesh = weld(raw);  // weld by coordinate == what the STL reader does

  auto wt = check_watertight(mesh);
  int comps = count_components(mesh);
  std::printf("O5 WATERTIGHTNESS — 2x2x2 octet block, L=%.0f mm\n", L);
  std::printf("   triangles=%llu  struts=%llu nodes=%llu\n",
              (unsigned long long)st.tris, (unsigned long long)st.struts,
              (unsigned long long)st.nodes);
  std::printf(
      "   The generator emits an STL-style UNSHARED triangle soup (every facet "
      "carries its own 3 vertices); topology is only defined after welding.\n");
  std::printf(
      "   WELDED by coordinate (%zu verts, exactly what an STL reader does on "
      "re-import):\n",
      mesh.vertices.size());
  std::printf("     boundary_edges   = %d\n", wt.boundary_edges);
  std::printf("     non_manifold_edges = %d  (edges shared by >2 faces)\n",
              wt.non_manifold_edges);
  std::printf("     connected components = %d\n", comps);
  std::printf("     check_watertight = %s\n", wt.watertight ? "PASS" : "FAIL");
  std::printf(
      "   Each prism/node, welded in isolation, IS a closed 2-manifold (see B2). "
      "Emitted together, the shared strut endpoints and node spheres weld into\n"
      "   non-manifold junctions, and the struts INTERPENETRATE — which the edge "
      "check alone cannot see. The intersection scan below proves the overlap.\n");

  // Bounded self-intersection probe: does any triangle from one primitive cross a
  // triangle from another near a node? Test all triangle pairs whose AABBs overlap
  // within a small box around the central node — O(k^2) on a tiny k.
  V3 centre = node_pos(R, 2, 2, 2);  // interior shared node (1,1,1)*L
  double win = 0.6 * L;
  std::vector<int> local;
  for (std::size_t t = 0; t < mesh.triangles.size(); ++t) {
    auto& tr = mesh.triangles[t];
    for (int c = 0; c < 3; ++c) {
      Vec3 v = mesh.vertices[tr[c]];
      if (std::fabs(v.x - centre.x) < win && std::fabs(v.y - centre.y) < win &&
          std::fabs(v.z - centre.z) < win) {
        local.push_back((int)t);
        break;
      }
    }
  }
  // segment-vs-triangle style: count intersecting coplanar-excluded pairs via a
  // simple Moller-style test on triangle edges vs the other triangle.
  auto vof = [&](int t, int i) {
    Vec3 p = mesh.vertices[mesh.triangles[t][i]];
    return V3{p.x, p.y, p.z};
  };
  auto seg_tri = [&](V3 p, V3 q, V3 a, V3 b, V3 c) {
    V3 e1 = b - a, e2 = c - a, d = q - p;
    V3 pv = cross(d, e2);
    double det = dot(e1, pv);
    if (std::fabs(det) < 1e-12) return false;
    double inv = 1.0 / det;
    V3 tv = p - a;
    double u = dot(tv, pv) * inv;
    if (u < 1e-9 || u > 1 - 1e-9) return false;
    V3 qv = cross(tv, e1);
    double vv = dot(d, qv) * inv;
    if (vv < 1e-9 || u + vv > 1 - 1e-9) return false;
    double tt = dot(e2, qv) * inv;
    return tt > 1e-9 && tt < 1 - 1e-9;
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
  std::printf(
      "   self-intersection scan around the central node: %ld intersecting "
      "triangle pairs of %ld tested (%zu local triangles)\n",
      isect, pairs, local.size());
  std::printf(
      "   => the swept-solid union is a %s: individually-closed primitives that "
      "INTERPENETRATE.\n",
      isect > 0 ? "self-intersecting soup" : "clean body");
  return 0;
}

int mode_angles(int argc, char** argv) {
  // O6: distribution of strut angle from vertical (z), and min strut diameter at
  // lowest graded density.
  double L = argc > 2 ? std::atof(argv[2]) : 8.0;
  Region R = region_200cc(L, 1.0);
  static const std::vector<RStrut> RS = ref_struts();
  std::map<int, long> hist;  // angle bucket (deg, rounded to nearest 5) -> count
  for (const auto& rs : RS) {
    V3 a = node_pos(R, rs.a.x, rs.a.y, rs.a.z);
    V3 b = node_pos(R, rs.b.x, rs.b.y, rs.b.z);
    V3 d = unit(b - a);
    double ang = std::acos(std::clamp(std::fabs(d.z), 0.0, 1.0)) * 180.0 / M_PI;
    int bucket = (int)(std::llround(ang / 5.0) * 5);
    hist[bucket]++;
  }
  std::printf("O6 PRINTABILITY — octet strut angle from VERTICAL (z), L=%.0f mm\n",
              L);
  std::printf("   (angle 0 = vertical/self-supporting; 90 = horizontal bridge)\n");
  long total = 0;
  for (auto& kv : hist) total += kv.second;
  for (auto& kv : hist)
    std::printf("   %2d deg : %ld struts (%.0f%%)\n", kv.first, kv.second,
                100.0 * kv.second / total);
  // FDM self-support threshold is ~45 deg from vertical.
  long unsup = 0;
  for (auto& kv : hist)
    if (kv.first > 45) unsup += kv.second;
  std::printf(
      "   struts steeper than 45 deg from vertical (overhang risk): %ld of %ld "
      "(%.0f%%)\n",
      unsup, total, 100.0 * unsup / total);
  double r_min = 0.6 * 0.10 * L;  // lowest graded density (see mode_case Grade)
  std::printf("   min strut diameter at lowest graded density = %.3f mm\n",
              2 * r_min);
  std::printf(
      "   *** NOT a printability verdict. The lattice has NO vertical struts: "
      "the face-diagonal legs sit at 45 deg from vertical (the borderline FDM\n"
      "   self-support limit) and one third are horizontal (90 deg) bridges that "
      "categorically need support. These numbers OWE a real FDM print test.\n");
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr,
                 "usage: %s {selfcheck|case|watertight|angles} ...\n", argv[0]);
    return 2;
  }
  std::string cmd = argv[1];
  if (cmd == "selfcheck") return mode_selfcheck();
  if (cmd == "case") return mode_case(argc, argv);
  if (cmd == "watertight") return mode_watertight(argc, argv);
  if (cmd == "angles") return mode_angles(argc, argv);
  std::fprintf(stderr, "unknown subcommand: %s\n", cmd.c_str());
  return 2;
}
