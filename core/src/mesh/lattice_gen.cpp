// Strut-lattice generator (handoff 2026-07-28-lattice-generation-production).
//
// Ported VERBATIM in algorithm from the proven Phase-0 harness
// core/tests/harness/octet_gen_probe.cpp (PR 201): same reference node/strut
// tables, same cell-local ownership, same swept-solid strut and icosahedral node,
// same fixed traversal order. Preserving the algorithm to the operation is what
// lets the production path reproduce the harness's measured output byte-for-byte
// (the golden cross-check in tests/unit/test_lattice_gen.cpp) and keeps peak RSS
// flat in output size (no global dedup set: each primitive is owned by exactly
// one cell).

#include "topopt/lattice_gen.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <vector>

namespace topopt {
namespace {

// --------------------------------------------------------------------------- vec
// Local Vec3 arithmetic (the harness used a private V3; production geometry is
// Vec3, so these operate on it). Kept file-local to avoid leaking operators.
Vec3 add(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 scale(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double norm(const Vec3& a) { return std::sqrt(dot(a, a)); }
Vec3 unit(const Vec3& a) {
  const double n = norm(a);
  return n > 0 ? scale(a, 1.0 / n) : Vec3{0, 0, 0};
}

// --------------------------------------------------------------------------- octet
// The 14 nodes of the reference cell in HALF-integer coordinates (units of L/2),
// so every component is an integer in {0,1,2}. Corners are even/even/even; face
// centres have exactly one even component. This integer keying makes cell-local
// ownership (dedup with NO global set) exact.
struct INode {
  int x, y, z;
};

bool is_corner(const INode& n) {
  return (n.x % 2 == 0) && (n.y % 2 == 0) && (n.z % 2 == 0);
}

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
//   OCTA : an octahedron edge (face-centre to face-centre); interior to the cell,
//          never shared, always owned by the cell.
//   LEG  : a tetrahedron leg (face-centre to cube corner); lies in ONE cube face
//          plane and is shared with the neighbour across that face. Owned by the
//          cell on the min side of that face (see owns_leg).
enum class Cls { OCTA, LEG };
struct RStrut {
  INode a, b;
  Cls cls;
  int face_axis;  // for LEG: 0=x,1=y,2=z
  int face_side;  // for LEG: 0 (min plane) or 2 (max plane)
};

std::vector<RStrut> ref_struts() {
  const auto nodes = ref_nodes();
  std::vector<INode> corners, faces;
  for (const auto& n : nodes) (is_corner(n) ? corners : faces).push_back(n);

  std::vector<RStrut> s;
  // 24 tetra legs: each face centre to the 4 corners sharing its face plane.
  for (const auto& f : faces) {
    const int axis = (f.x % 2 == 0) ? 0 : (f.y % 2 == 0) ? 1 : 2;
    const int side = (axis == 0) ? f.x : (axis == 1) ? f.y : f.z;  // 0 or 2
    for (const auto& c : corners) {
      const int cc = (axis == 0) ? c.x : (axis == 1) ? c.y : c.z;
      if (cc == side) s.push_back({f, c, Cls::LEG, axis, side});
    }
  }
  // 12 octahedron edges: face centres whose squared distance is 2, each pair once.
  for (std::size_t i = 0; i < faces.size(); ++i)
    for (std::size_t j = i + 1; j < faces.size(); ++j) {
      const int dx = faces[i].x - faces[j].x, dy = faces[i].y - faces[j].y,
                dz = faces[i].z - faces[j].z;
      if (dx * dx + dy * dy + dz * dz == 2)
        s.push_back({faces[i], faces[j], Cls::OCTA, -1, -1});
    }
  return s;
}

// --------------------------------------------------------------------------- region
bool cell_latticed(const LatticeRegion& R, int ci, int cj, int ck) {
  if (ci < 0 || cj < 0 || ck < 0) return false;
  if (ci >= R.nx || cj >= R.ny || ck >= R.nz) return false;
  return R.latticed ? R.latticed(ci, cj, ck) : true;
}

// Node-owner cell under the even/odd mapping, clamped to the grid. Even component
// (corner on that axis) -> coord/2; odd (face centre) -> (coord-1)/2 == coord/2.
void node_owner(const LatticeRegion& R, int gx, int gy, int gz, int& oi, int& oj,
                int& ok) {
  auto own = [](int g, int n) {
    int o = g / 2;
    if (o < 0) o = 0;
    if (o >= n) o = n - 1;
    return o;
  };
  oi = own(gx, R.nx);
  oj = own(gy, R.ny);
  ok = own(gz, R.nz);
}

// Does cell (ci,cj,ck) own this LEG? Min-side faces (side 0) are always owned;
// max-side faces (side 2) are owned only when there is no latticed neighbour on
// the + side (region boundary), so each shared leg is emitted exactly once.
bool owns_leg(const LatticeRegion& R, int ci, int cj, int ck, int axis, int side) {
  if (side == 0) return true;
  const int ni = ci + (axis == 0), nj = cj + (axis == 1), nk = ck + (axis == 2);
  if (ni >= R.nx || nj >= R.ny || nk >= R.nz) return true;  // grid boundary
  return !cell_latticed(R, ni, nj, nk);                     // fraction boundary
}

Vec3 node_pos(const LatticeRegion& R, int gx, int gy, int gz) {
  return {R.origin.x + gx * 0.5 * R.cell_mm, R.origin.y + gy * 0.5 * R.cell_mm,
          R.origin.z + gz * 0.5 * R.cell_mm};
}

// --------------------------------------------------------------------------- emit
// A capped n-gon prism (swept-solid strut) p0->p1, radius r. Wall: 2*nseg tris;
// two flat caps (fans): nseg each -> 4*nseg total. Each prism, welded in
// isolation, is a closed 2-manifold solid; consistent winding (not the sign) is
// what makes it so, so the caps match the wall winding.
void emit_strut(TriangleSink& sink, const Vec3& p0, const Vec3& p1, double r,
                int nseg) {
  const Vec3 axis = unit(sub(p1, p0));
  const Vec3 ref = std::fabs(axis.z) < 0.9 ? Vec3{0, 0, 1} : Vec3{1, 0, 0};
  const Vec3 u = unit(cross(axis, ref));
  const Vec3 v = cross(axis, u);
  std::vector<Vec3> ring0(nseg), ring1(nseg);
  for (int i = 0; i < nseg; ++i) {
    const double a = 2.0 * M_PI * i / nseg;
    const Vec3 off = add(scale(u, r * std::cos(a)), scale(v, r * std::sin(a)));
    ring0[i] = add(p0, off);
    ring1[i] = add(p1, off);
  }
  for (int i = 0; i < nseg; ++i) {
    const int j = (i + 1) % nseg;
    sink.add_triangle(ring0[i], ring1[i], ring1[j]);  // wall
    sink.add_triangle(ring0[i], ring1[j], ring0[j]);
    sink.add_triangle(p0, ring0[i], ring0[j]);  // cap 0 (fan)
    sink.add_triangle(p1, ring1[j], ring1[i]);  // cap 1 (fan)
  }
}

// An icosahedron of radius r at centre c (20 tris) — the node joint that makes
// the strut union a solid body at each vertex.
void emit_node(TriangleSink& sink, const Vec3& c, double r) {
  const double t = (1.0 + std::sqrt(5.0)) / 2.0;
  const double s = r / std::sqrt(1.0 + t * t);
  std::array<Vec3, 12> p = {{{-1, t, 0}, {1, t, 0}, {-1, -t, 0}, {1, -t, 0},
                             {0, -1, t}, {0, 1, t}, {0, -1, -t}, {0, 1, -t},
                             {t, 0, -1}, {t, 0, 1}, {-t, 0, -1}, {-t, 0, 1}}};
  for (auto& q : p) q = add(c, scale(q, s));
  static const int f[20][3] = {
      {0, 11, 5}, {0, 5, 1},   {0, 1, 7},   {0, 7, 10}, {0, 10, 11},
      {1, 5, 9},  {5, 11, 4},  {11, 10, 2}, {10, 7, 6}, {7, 1, 8},
      {3, 9, 4},  {3, 4, 2},   {3, 2, 6},   {3, 6, 8},  {3, 8, 9},
      {4, 9, 5},  {2, 4, 11},  {6, 2, 10},  {8, 6, 7},  {9, 8, 1}};
  for (const auto& tr : f) sink.add_triangle(p[tr[0]], p[tr[1]], p[tr[2]]);
}

double checked_radius(const LatticeRadiusField& G, const Vec3& mid) {
  const double r = G.radius_at(mid);
  if (!(r > 0.0))
    throw std::invalid_argument("generate_lattice: strut radius must be > 0");
  return r;
}

}  // namespace

const char* lattice_gen_topology_name(LatticeGenTopology topo) {
  switch (topo) {
    case LatticeGenTopology::Octet:
      return "octet";
  }
  return "octet";
}

long long latticed_cell_count(const LatticeRegion& R) {
  long long n = 0;
  for (int ck = 0; ck < R.nz; ++ck)
    for (int cj = 0; cj < R.ny; ++cj)
      for (int ci = 0; ci < R.nx; ++ci)
        if (cell_latticed(R, ci, cj, ck)) ++n;
  return n;
}

LatticeGenStats generate_lattice(LatticeGenTopology topo, const LatticeRegion& R,
                                 const LatticeRadiusField& G, TriangleSink& sink) {
  if (topo != LatticeGenTopology::Octet)
    throw std::invalid_argument("generate_lattice: only Octet is implemented");
  if (R.nx < 1 || R.ny < 1 || R.nz < 1 || !(R.cell_mm > 0.0))
    throw std::invalid_argument("generate_lattice: degenerate region");
  if (G.nseg < 3)
    throw std::invalid_argument("generate_lattice: nseg must be >= 3");

  static const std::vector<RStrut> RS = ref_struts();
  static const std::vector<INode> RN = ref_nodes();

  LatticeGenStats st;
  st.min_strut_diameter_mm = 1e30;
  st.max_strut_diameter_mm = 0.0;
  std::uint64_t tris = 0;

  for (int ck = 0; ck < R.nz; ++ck)
    for (int cj = 0; cj < R.ny; ++cj)
      for (int ci = 0; ci < R.nx; ++ci) {
        if (!cell_latticed(R, ci, cj, ck)) continue;
        ++st.latticed_cells;
        const int bx = 2 * ci, by = 2 * cj, bz = 2 * ck;

        // struts
        for (const auto& rs : RS) {
          if (rs.cls == Cls::LEG &&
              !owns_leg(R, ci, cj, ck, rs.face_axis, rs.face_side))
            continue;
          const Vec3 pa = node_pos(R, rs.a.x + bx, rs.a.y + by, rs.a.z + bz);
          const Vec3 pb = node_pos(R, rs.b.x + bx, rs.b.y + by, rs.b.z + bz);
          const double r = checked_radius(G, scale(add(pa, pb), 0.5));
          const std::uint64_t before = tris;
          emit_strut(sink, pa, pb, r, G.nseg);
          tris += 4ull * G.nseg;
          st.strut_triangles += tris - before;
          ++st.struts;
          st.min_strut_diameter_mm = std::min(st.min_strut_diameter_mm, 2 * r);
          st.max_strut_diameter_mm = std::max(st.max_strut_diameter_mm, 2 * r);
        }

        // nodes (own each candidate node whose owner is this cell; if the owner
        // cell is not latticed, fall back to the lex-smallest latticed sharer)
        for (const auto& rn : RN) {
          const int gx = rn.x + bx, gy = rn.y + by, gz = rn.z + bz;
          int oi, oj, ok;
          node_owner(R, gx, gy, gz, oi, oj, ok);
          bool own;
          if (cell_latticed(R, oi, oj, ok)) {
            own = (oi == ci && oj == cj && ok == ck);
          } else {
            own = true;
            for (int dk = -1; dk <= 0 && own; ++dk)
              for (int dj = -1; dj <= 0 && own; ++dj)
                for (int di = -1; di <= 0 && own; ++di) {
                  const int nci = (gx % 2 == 0 ? gx / 2 + di : gx / 2),
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
          const double r = checked_radius(G, node_pos(R, gx, gy, gz));
          emit_node(sink, node_pos(R, gx, gy, gz), r);
          tris += 20ull;
          st.node_triangles += 20ull;
          ++st.nodes;
        }
      }

  st.triangles = tris;
  if (st.struts == 0) {  // no latticed cells: leave diameters at 0, not 1e30
    st.min_strut_diameter_mm = 0.0;
    st.max_strut_diameter_mm = 0.0;
  }
  return st;
}

}  // namespace topopt
