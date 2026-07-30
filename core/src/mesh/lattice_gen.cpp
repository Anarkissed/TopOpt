// Strut-lattice generator (handoff 2026-07-28-lattice-generation-production;
// boundary finish: handoff 2026-07-29-lattice-boundary-finish).
//
// Ported VERBATIM in algorithm from the proven Phase-0 harness
// core/tests/harness/octet_gen_probe.cpp (PR 201): same reference node/strut
// tables, same cell-local ownership, same swept-solid strut and icosahedral node,
// same fixed traversal order. Preserving the algorithm to the operation is what
// lets the production path reproduce the harness's measured output byte-for-byte
// (the golden cross-check in tests/unit/test_lattice_gen.cpp) and keeps peak RSS
// flat in output size (no global dedup set: each primitive is owned by exactly
// one cell).
//
// THE BOUNDARY FINISH (region.boundary != nullptr) adds, without touching the
// null-boundary path's bytes:
//   * activation by OVERLAP  — a cell is generated if the boundary cannot prove
//     it misses the allowed region, so partial boundary cells are emitted
//     rather than dropped whole (no see-through voids);
//   * SOLID-safe clipping    — every strut centreline is clipped to the allowed
//     region eroded by that strut's own radius (LatticeBoundary::clip_segment's
//     Lipschitz-certified spans), so the swept solid stays inside the part;
//   * a boundary SKIN        — anchor balls at the exact cut ends (landings),
//     a diagrid of skin struts linking neighbouring landings on each analytic
//     face, and rim loops (plane-pair lines, plane-bore tori) where faces meet.
//     The collar boss on a protected bore is this same skin on the bore wall.
// The skin is a SEPARATE pass that re-derives each cell's landings on demand
// (deterministic recompute, never a global landing set), so cell-local
// streaming — the property that keeps lattices affordable — survives (bar B8).

#include "topopt/lattice_gen.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <vector>

#include "topopt/lattice_boundary.hpp"

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
// Composite cell activity: the caller's predicate AND (boundary finish) the
// overlap activation. BOTH the strut/node ownership rules and the emission
// tests use this ONE function, so a cell inactive under either rule looks
// identical to both sides of every ownership decision.
bool cell_active(const LatticeRegion& R, int ci, int cj, int ck) {
  if (ci < 0 || cj < 0 || ck < 0) return false;
  if (ci >= R.nx || cj >= R.ny || ck >= R.nz) return false;
  if (R.latticed && !R.latticed(ci, cj, ck)) return false;
  if (R.boundary) {
    const Vec3 cmin{R.origin.x + ci * R.cell_mm, R.origin.y + cj * R.cell_mm,
                    R.origin.z + ck * R.cell_mm};
    if (!R.boundary->cell_may_overlap(cmin, R.cell_mm)) return false;
  }
  return true;
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
// max-side faces (side 2) are owned only when there is no active neighbour on
// the + side (region boundary), so each shared leg is emitted exactly once.
bool owns_leg(const LatticeRegion& R, int ci, int cj, int ck, int axis, int side) {
  if (side == 0) return true;
  const int ni = ci + (axis == 0), nj = cj + (axis == 1), nk = ck + (axis == 2);
  if (ni >= R.nx || nj >= R.ny || nk >= R.nz) return true;  // grid boundary
  return !cell_active(R, ni, nj, nk);                       // fraction boundary
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

// ----------------------------------------------------------- analytic volumes
// Per-primitive solid volumes for the B9 accounting (soup basis: overlaps are
// not deducted, matching how the triangle counts are reported).
double ngon_prism_volume(double r, double len, int nseg) {
  return 0.5 * nseg * r * r * std::sin(2.0 * M_PI / nseg) * len;
}
double icosahedron_volume(double circumradius) {
  const double a = 4.0 * circumradius / std::sqrt(10.0 + 2.0 * std::sqrt(5.0));
  return (5.0 / 12.0) * (3.0 + std::sqrt(5.0)) * a * a * a;
}

// ------------------------------------------------------------ boundary finish
// A landing: the exact point where a clipped interior strut meets the eroded
// boundary — the skin's anchor site (bar B6). `r` is the interior strut's own
// radius there; `face` attributes it to the analytic face it landed on.
struct Landing {
  Vec3 pos;
  double r;
  int face;
};

struct CellCut {
  struct Frag {
    Vec3 a, b;
    double r;
  };
  std::vector<Frag> frags;
  std::vector<Landing> landings;
  std::uint64_t clipped = 0, dropped = 0, full = 0;
  long long uncertified = 0;
};

constexpr double kMinFragMm = 1e-3;   // shorter kept spans degenerate to slivers
constexpr double kLinkFactor = 0.72;  // diagrid link radius, in cell edges
// Diagrid degree bound: an edge is kept only when each endpoint ranks the
// other among its kSkinDegree nearest same-face landings (mutual-kNN). The
// radius rule alone degenerates into a near-clique where clipping drops whole
// surface-plane struts and their landings cluster densely — measured at 86% of
// all triangles on the evidence plate. Rings + both diagonal families need a
// degree of ~8 (4 ring + 4 diagonal neighbours), i.e. 8 mutual ranks.
constexpr int kSkinDegree = 8;
constexpr double kBoreStationRad = 0.30;  // collar edge angular subdivision
constexpr double kRimSagMm = 0.02;        // rim torus facet sag budget

// Deterministically recompute the clipped struts of ONE cell: the SAME
// ownership walk as the main emission loop (single source — the skin pass calls
// this for neighbour cells instead of keeping any global landing set, which is
// what preserves cell-local streaming). Returns nothing for inactive cells.
void cut_cell_struts(const LatticeRegion& R, const LatticeRadiusField& G,
                     const std::vector<RStrut>& RS, int ci, int cj, int ck,
                     CellCut& out) {
  out.frags.clear();
  out.landings.clear();
  out.clipped = out.dropped = out.full = 0;
  out.uncertified = 0;
  if (!cell_active(R, ci, cj, ck)) return;
  const LatticeBoundary* B = R.boundary;
  const int bx = 2 * ci, by = 2 * cj, bz = 2 * ck;
  const Vec3 centre{R.origin.x + (ci + 0.5) * R.cell_mm,
                    R.origin.y + (cj + 0.5) * R.cell_mm,
                    R.origin.z + (ck + 0.5) * R.cell_mm};
  const double half_diag = 0.5 * R.cell_mm * std::sqrt(3.0);
  const double sd_centre = B ? B->signed_distance(centre) : 0.0;

  for (const auto& rs : RS) {
    if (rs.cls == Cls::LEG && !owns_leg(R, ci, cj, ck, rs.face_axis, rs.face_side))
      continue;
    const Vec3 pa = node_pos(R, rs.a.x + bx, rs.a.y + by, rs.a.z + bz);
    const Vec3 pb = node_pos(R, rs.b.x + bx, rs.b.y + by, rs.b.z + bz);
    const double r = checked_radius(G, scale(add(pa, pb), 0.5));
    if (!B || sd_centre >= half_diag + r) {
      // Fast path: the Lipschitz bound proves the whole strut (and its solid)
      // is inside — deep-interior cells never pay for a clip.
      out.frags.push_back({pa, pb, r});
      ++out.full;
      continue;
    }
    const double len = norm(sub(pb, pa));
    const Vec3 dir = scale(sub(pb, pa), 1.0 / len);
    const auto spans = B->clip_segment(pa, pb, r, -1, -1, &out.uncertified);
    if (spans.empty()) {
      ++out.dropped;
      continue;
    }
    const bool whole = spans.size() == 1 && spans.front().t0 <= 1e-9 &&
                       spans.front().t1 >= len - 1e-9;
    if (whole) {
      out.frags.push_back({pa, pb, r});
      ++out.full;
      continue;
    }
    ++out.clipped;
    for (const auto& s : spans) {
      if (s.t1 - s.t0 < kMinFragMm) continue;
      const Vec3 qa = add(pa, scale(dir, s.t0));
      const Vec3 qb = add(pa, scale(dir, s.t1));
      out.frags.push_back({qa, qb, r});
      if (s.t0 > 1e-9)
        out.landings.push_back({qa, r, B->nearest_face(qa)});
      if (s.t1 < len - 1e-9)
        out.landings.push_back({qb, r, B->nearest_face(qb)});
    }
  }
}

double skin_radius_at(const LatticeRadiusField& G, const LatticeSkinSpec& skin,
                      const Vec3& p) {
  return std::max(checked_radius(G, p), skin.min_radius_mm);
}

// Track an emitted solid in the stats' diameter range.
void note_diameter(LatticeGenStats& st, double r) {
  st.min_strut_diameter_mm = std::min(st.min_strut_diameter_mm, 2 * r);
  st.max_strut_diameter_mm = std::max(st.max_strut_diameter_mm, 2 * r);
}

// Emit one diagrid skin edge between two landings on face `face_idx`, riding
// the face's offset surface at the LOCAL skin radius (the variable-offset
// contour bar B5 demands under grading), clipped against every OTHER primitive.
void emit_skin_edge(TriangleSink& sink, const LatticeRegion& R,
                    const LatticeRadiusField& G, const LatticeSkinSpec& skin,
                    int face_idx, const Landing& A, const Landing& Bl,
                    LatticeGenStats& st, const LatticeGenObserver* obs) {
  const LatticeBoundary* B = R.boundary;
  const LatticeBoundaryFace& F = B->faces()[static_cast<std::size_t>(face_idx)];
  std::vector<Vec3> stations;
  std::vector<double> rs;

  if (F.kind == LatticeBoundaryFace::Kind::Plane) {
    // Straight on the offset plane: each endpoint sits at ITS OWN local skin
    // radius above the face (graded skin => graded inset; the segment between
    // stays at >= min of the two by linearity).
    for (const Landing* L : {&A, &Bl}) {
      const double r_s = skin_radius_at(G, skin, L->pos);
      const double d = dot(sub(L->pos, F.origin), F.normal);
      stations.push_back(sub(L->pos, scale(F.normal, d + r_s)));
      rs.push_back(r_s);
    }
  } else {
    // Collar edge on a bore wall: stations along the shorter angular way,
    // pushed OUT to (R + r_s)/cos(step/2) so every prism vertex stays at radius
    // >= R + (r_s - r_e) >= R — geometry may touch the declared bore wall,
    // never cross it (bar B2).
    const Vec3 ax = F.axis_dir;
    const Vec3 ref = std::fabs(ax.z) < 0.9 ? Vec3{0, 0, 1} : Vec3{1, 0, 0};
    const Vec3 u = unit(cross(ax, ref));
    const Vec3 v = cross(ax, u);
    auto cylindrical = [&](const Vec3& p, double& theta, double& t) {
      const Vec3 d = sub(p, F.axis_point);
      t = dot(d, ax);
      const Vec3 rad = sub(d, scale(ax, t));
      theta = std::atan2(dot(rad, v), dot(rad, u));
    };
    double th_a, t_a, th_b, t_b;
    cylindrical(A.pos, th_a, t_a);
    cylindrical(Bl.pos, th_b, t_b);
    double dth = th_b - th_a;
    while (dth > M_PI) dth -= 2.0 * M_PI;
    while (dth < -M_PI) dth += 2.0 * M_PI;
    const int nst = 1 + static_cast<int>(std::ceil(std::fabs(dth) / kBoreStationRad));
    const double guard = std::cos(0.5 * std::fabs(dth) / nst);
    for (int i = 0; i <= nst; ++i) {
      const double f = static_cast<double>(i) / nst;
      const double th = th_a + f * dth;
      const double t = t_a + f * (t_b - t_a);
      const Vec3 radial = add(scale(u, std::cos(th)), scale(v, std::sin(th)));
      const Vec3 wall = add(F.axis_point,
                            add(scale(ax, t), scale(radial, F.radius)));
      const double r_s = skin_radius_at(G, skin, wall);
      stations.push_back(add(F.axis_point,
                             add(scale(ax, t),
                                 scale(radial, (F.radius + r_s) / guard))));
      rs.push_back(r_s);
    }
  }

  double r_e = 1e30;
  for (const double r : rs) r_e = std::min(r_e, r);

  for (std::size_t i = 0; i + 1 < stations.size(); ++i) {
    const auto spans = B->clip_segment(stations[i], stations[i + 1], r_e,
                                       face_idx, -1,
                                       &st.uncertified_spans_dropped);
    const double len = norm(sub(stations[i + 1], stations[i]));
    if (!(len > 0.0)) continue;
    const Vec3 dir = scale(sub(stations[i + 1], stations[i]), 1.0 / len);
    for (const auto& s : spans) {
      if (s.t1 - s.t0 < kMinFragMm) continue;
      const Vec3 qa = add(stations[i], scale(dir, s.t0));
      const Vec3 qb = add(stations[i], scale(dir, s.t1));
      emit_strut(sink, qa, qb, r_e, G.nseg);
      if (obs && obs->on_element)
        obs->on_element(LatticeGenElement::SkinStrut, qa, qb, r_e);
      ++st.skin_struts;
      st.skin_triangles += 4ull * G.nseg;
      st.triangles += 4ull * G.nseg;
      st.skin_volume_mm3 += ngon_prism_volume(r_e, s.t1 - s.t0, G.nseg);
      note_diameter(st, r_e);
    }
  }
}

// Emit the rim line where two boundary PLANES meet: the polyline of points at
// the LOCAL skin radius from both planes (the variable-offset contour), clipped
// against everything else. Deterministic station walk, O(stations) memory.
void emit_rim_line(TriangleSink& sink, const LatticeRegion& R,
                   const LatticeRadiusField& G, const LatticeSkinSpec& skin,
                   int fa, int fb, LatticeGenStats& st,
                   const LatticeGenObserver* obs) {
  const LatticeBoundary* B = R.boundary;
  const LatticeBoundaryFace& F1 = B->faces()[static_cast<std::size_t>(fa)];
  const LatticeBoundaryFace& F2 = B->faces()[static_cast<std::size_t>(fb)];
  const Vec3 n1 = F1.normal, n2 = F2.normal;
  const Vec3 d = cross(n1, n2);
  const double dn = norm(d);
  if (dn < 1e-9) return;  // parallel faces meet nowhere
  const Vec3 dir = scale(d, 1.0 / dn);
  const double g = dot(n1, n2);
  const double det = 1.0 - g * g;

  // The point nearest `near` with signed plane distances exactly (-r1, -r2).
  auto solve = [&](const Vec3& near, double r1, double r2) {
    const double c1 = -r1 - dot(sub(near, F1.origin), n1);
    const double c2 = -r2 - dot(sub(near, F2.origin), n2);
    const double alpha = (c1 - g * c2) / det;
    const double beta = (c2 - g * c1) / det;
    return add(near, add(scale(n1, alpha), scale(n2, beta)));
  };

  // Walk the line across the region block. Stations every half cell; each is
  // re-solved at its OWN local skin radius (two fixed iterations — the field
  // varies slowly at strut scale, and determinism needs a fixed count).
  const Vec3 lo = R.origin;
  const Vec3 hi{R.origin.x + R.nx * R.cell_mm, R.origin.y + R.ny * R.cell_mm,
                R.origin.z + R.nz * R.cell_mm};
  const Vec3 mid{0.5 * (lo.x + hi.x), 0.5 * (lo.y + hi.y), 0.5 * (lo.z + hi.z)};
  const double span = 0.5 * norm(sub(hi, lo)) + R.cell_mm;
  const double step = 0.5 * R.cell_mm;
  const int nst = static_cast<int>(std::ceil(2.0 * span / step));

  std::vector<Vec3> stations;
  std::vector<double> rs;
  const Vec3 anchor = solve(mid, skin.min_radius_mm > 0 ? skin.min_radius_mm : 0.0,
                            skin.min_radius_mm > 0 ? skin.min_radius_mm : 0.0);
  for (int i = 0; i <= nst; ++i) {
    const double s = -span + (2.0 * span * i) / nst;
    Vec3 q = add(anchor, scale(dir, s));
    double r_s = skin_radius_at(G, skin, q);
    q = solve(q, r_s, r_s);
    r_s = skin_radius_at(G, skin, q);
    q = solve(q, r_s, r_s);
    stations.push_back(q);
    rs.push_back(r_s);
  }

  for (std::size_t i = 0; i + 1 < stations.size(); ++i) {
    const double r_e = std::min(rs[i], rs[i + 1]);
    const auto spans = B->clip_segment(stations[i], stations[i + 1], r_e, fa, fb,
                                       &st.uncertified_spans_dropped);
    const double len = norm(sub(stations[i + 1], stations[i]));
    if (!(len > 0.0)) continue;
    const Vec3 sdir = scale(sub(stations[i + 1], stations[i]), 1.0 / len);
    bool any = false;
    for (const auto& s : spans) {
      if (s.t1 - s.t0 < kMinFragMm) continue;
      const Vec3 qa = add(stations[i], scale(sdir, s.t0));
      const Vec3 qb = add(stations[i], scale(sdir, s.t1));
      emit_strut(sink, qa, qb, r_e, G.nseg);
      if (obs && obs->on_element)
        obs->on_element(LatticeGenElement::RimStrut, qa, qb, r_e);
      any = true;
      st.rim_triangles += 4ull * G.nseg;
      st.triangles += 4ull * G.nseg;
      st.rim_volume_mm3 += ngon_prism_volume(r_e, s.t1 - s.t0, G.nseg);
      note_diameter(st, r_e);
    }
    if (any) ++st.rim_elements;
  }
}

// Emit the rim torus where a boundary PLANE meets a protected BORE (the collar's
// ring): centre circle at radius (bore R + tube r) about the bore axis, tube
// tangent to the plane, and the phi = pi vertex ring EXACTLY at the declared
// bore radius — the geometry touches the protected wall to the last bit and
// never crosses it (bar B2's min-radius clause). Only the orthogonal case is
// dressed; skew pairs are counted, never silently approximated.
void emit_rim_torus(TriangleSink& sink, const LatticeRegion& R,
                    const LatticeRadiusField& G, const LatticeSkinSpec& skin,
                    int f_plane, int f_bore, LatticeGenStats& st,
                    const LatticeGenObserver* obs) {
  const LatticeBoundary* B = R.boundary;
  const LatticeBoundaryFace& P = B->faces()[static_cast<std::size_t>(f_plane)];
  const LatticeBoundaryFace& C = B->faces()[static_cast<std::size_t>(f_bore)];
  const double g = dot(P.normal, C.axis_dir);
  if (std::fabs(g) < 0.999) {
    ++st.skipped_nonorthogonal_rims;
    return;
  }

  // Tube radius: the max local skin radius around the wall circle (a constant
  // tube keeps the torus exact; a locally larger inset only recedes inward).
  const Vec3 ax = C.axis_dir;
  const Vec3 ref = std::fabs(ax.z) < 0.9 ? Vec3{0, 0, 1} : Vec3{1, 0, 0};
  const Vec3 u = unit(cross(ax, ref));
  const Vec3 v = cross(ax, u);
  // Plane level along the axis, first at a nominal inset, then refined once the
  // tube radius is known (fixed two-step — deterministic).
  double r_t = skin.min_radius_mm;
  for (int pass = 0; pass < 2; ++pass) {
    const double t_star =
        (-std::max(r_t, 1e-6) - dot(sub(C.axis_point, P.origin), P.normal)) / g;
    double r_max = skin.min_radius_mm;
    for (int i = 0; i < 32; ++i) {
      const double th = 2.0 * M_PI * i / 32.0;
      const Vec3 radial = add(scale(u, std::cos(th)), scale(v, std::sin(th)));
      const Vec3 wall =
          add(C.axis_point, add(scale(ax, t_star), scale(radial, C.radius)));
      r_max = std::max(r_max, skin_radius_at(G, skin, wall));
    }
    r_t = r_max;
  }
  if (!(r_t > 0.0)) return;
  const double t_star =
      (-r_t - dot(sub(C.axis_point, P.origin), P.normal)) / g;
  if (t_star < C.t_lo - R.cell_mm || t_star > C.t_hi + R.cell_mm) return;

  const double rho_c = C.radius + r_t;
  const int n_phi = G.nseg;
  const double dth_max = 2.0 * std::acos(std::max(0.0, 1.0 - kRimSagMm / rho_c));
  const int n_th = std::max(24, static_cast<int>(std::ceil(2.0 * M_PI / dth_max)));
  const Vec3 centre = add(C.axis_point, scale(ax, t_star));

  // Station validity: the tube must clear every OTHER primitive.
  std::vector<char> ok(static_cast<std::size_t>(n_th), 0);
  std::vector<Vec3> radial_at(static_cast<std::size_t>(n_th));
  for (int i = 0; i < n_th; ++i) {
    const double th = 2.0 * M_PI * i / n_th;
    const Vec3 radial = add(scale(u, std::cos(th)), scale(v, std::sin(th)));
    radial_at[static_cast<std::size_t>(i)] = radial;
    const Vec3 cst = add(centre, scale(radial, rho_c));
    ok[static_cast<std::size_t>(i)] =
        B->signed_distance_excluding(cst, f_plane, f_bore) >= r_t - 1e-9 ? 1 : 0;
  }

  auto tube_vertex = [&](int i, int j) {
    const double phi = 2.0 * M_PI * j / n_phi;
    const Vec3& radial = radial_at[static_cast<std::size_t>(i % n_th)];
    return add(centre, add(scale(radial, rho_c + r_t * std::cos(phi)),
                           scale(ax, r_t * std::sin(phi))));
  };
  auto emit_quad_ring = [&](int i) {  // stations i -> i+1
    if (obs && obs->on_element) {
      const Vec3 a = add(centre, scale(radial_at[static_cast<std::size_t>(i % n_th)], rho_c));
      const Vec3 b = add(centre, scale(radial_at[static_cast<std::size_t>((i + 1) % n_th)], rho_c));
      obs->on_element(LatticeGenElement::RimTorusChord, a, b, r_t);
    }
    for (int j = 0; j < n_phi; ++j) {
      const int j1 = (j + 1) % n_phi;
      const Vec3 a = tube_vertex(i, j), b = tube_vertex(i + 1, j);
      const Vec3 c = tube_vertex(i + 1, j1), dq = tube_vertex(i, j1);
      sink.add_triangle(a, b, c);
      sink.add_triangle(a, c, dq);
      st.rim_triangles += 2;
      st.triangles += 2;
    }
  };
  auto emit_cap = [&](int i, bool flip) {  // seal a partial run's open end
    Vec3 c{0, 0, 0};
    for (int j = 0; j < n_phi; ++j) c = add(c, tube_vertex(i, j));
    c = scale(c, 1.0 / n_phi);
    for (int j = 0; j < n_phi; ++j) {
      const int j1 = (j + 1) % n_phi;
      if (flip)
        sink.add_triangle(c, tube_vertex(i, j1), tube_vertex(i, j));
      else
        sink.add_triangle(c, tube_vertex(i, j), tube_vertex(i, j1));
      st.rim_triangles += 1;
      st.triangles += 1;
    }
  };

  int emitted_runs = 0;
  int valid = 0;
  for (int i = 0; i < n_th; ++i) valid += ok[static_cast<std::size_t>(i)];
  if (valid == 0) return;
  if (valid == n_th) {
    for (int i = 0; i < n_th; ++i) emit_quad_ring(i);
    st.rim_volume_mm3 += 2.0 * M_PI * M_PI * rho_c * r_t * r_t;
    emitted_runs = 1;
  } else {
    // Contiguous valid runs around the circle, each sealed with flat caps.
    int start = 0;
    while (start < n_th && ok[static_cast<std::size_t>(start)]) ++start;
    // `start` is now an invalid station; walk runs beginning after it.
    for (int off = 0; off < n_th;) {
      const int i = (start + off) % n_th;
      if (!ok[static_cast<std::size_t>(i)]) {
        ++off;
        continue;
      }
      int len = 0;
      while (off + len < n_th &&
             ok[static_cast<std::size_t>((start + off + len) % n_th)])
        ++len;
      if (len >= 2) {
        const int first = (start + off) % n_th;
        for (int k = 0; k < len - 1; ++k) emit_quad_ring(first + k);
        emit_cap(first, true);
        emit_cap(first + len - 1, false);
        st.rim_volume_mm3 +=
            M_PI * r_t * r_t * rho_c * (2.0 * M_PI * (len - 1) / n_th);
        ++emitted_runs;
      }
      off += len;
    }
  }
  st.rim_elements += static_cast<std::uint64_t>(emitted_runs);
  note_diameter(st, r_t);
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
        if (cell_active(R, ci, cj, ck)) ++n;
  return n;
}

LatticeGenStats generate_lattice(LatticeGenTopology topo, const LatticeRegion& R,
                                 const LatticeRadiusField& G, TriangleSink& sink,
                                 const LatticeSkinSpec& skin,
                                 const LatticeGenObserver* obs) {
  if (topo != LatticeGenTopology::Octet)
    throw std::invalid_argument("generate_lattice: only Octet is implemented");
  if (R.nx < 1 || R.ny < 1 || R.nz < 1 || !(R.cell_mm > 0.0))
    throw std::invalid_argument("generate_lattice: degenerate region");
  if (G.nseg < 3)
    throw std::invalid_argument("generate_lattice: nseg must be >= 3");
  if (skin.mode != LatticeSkinMode::None && !R.boundary)
    throw std::invalid_argument(
        "generate_lattice: a skin needs region.boundary (the shared predicate)");

  static const std::vector<RStrut> RS = ref_struts();
  static const std::vector<INode> RN = ref_nodes();
  const LatticeBoundary* B = R.boundary;

  LatticeGenStats st;
  st.min_strut_diameter_mm = 1e30;
  st.max_strut_diameter_mm = 0.0;
  std::uint64_t tris = 0;

  CellCut cut;  // reused per cell — O(1) live memory
  for (int ck = 0; ck < R.nz; ++ck)
    for (int cj = 0; cj < R.ny; ++cj)
      for (int ci = 0; ci < R.nx; ++ci) {
        if (!cell_active(R, ci, cj, ck)) continue;
        ++st.latticed_cells;
        const int bx = 2 * ci, by = 2 * cj, bz = 2 * ck;

        // struts (clipped through the shared predicate when a boundary is set;
        // cut_cell_struts is the SAME walk the skin pass recomputes later)
        cut_cell_struts(R, G, RS, ci, cj, ck, cut);
        st.clipped_struts += cut.clipped;
        st.dropped_struts += cut.dropped;
        st.uncertified_spans_dropped += cut.uncertified;
        st.landings += static_cast<std::uint64_t>(cut.landings.size());
        if (obs && obs->on_landing)
          for (const auto& L : cut.landings) obs->on_landing(L.pos, L.r, L.face);
        for (const auto& fr : cut.frags) {
          const std::uint64_t before = tris;
          emit_strut(sink, fr.a, fr.b, fr.r, G.nseg);
          if (obs && obs->on_element)
            obs->on_element(LatticeGenElement::InteriorStrut, fr.a, fr.b, fr.r);
          tris += 4ull * G.nseg;
          st.strut_triangles += tris - before;
          ++st.struts;
          note_diameter(st, fr.r);
          st.interior_volume_mm3 +=
              ngon_prism_volume(fr.r, norm(sub(fr.b, fr.a)), G.nseg);
        }
        st.strut_fragments += cut.clipped == 0
                                  ? 0
                                  : static_cast<std::uint64_t>(cut.frags.size()) -
                                        cut.full;

        // nodes (own each candidate node whose owner is this cell; if the owner
        // cell is not active, fall back to the lex-smallest active sharer)
        for (const auto& rn : RN) {
          const int gx = rn.x + bx, gy = rn.y + by, gz = rn.z + bz;
          int oi, oj, ok;
          node_owner(R, gx, gy, gz, oi, oj, ok);
          bool own;
          if (cell_active(R, oi, oj, ok)) {
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
                  if (!cell_active(R, nci, ncj, nck)) continue;
                  if (nci < ci || (nci == ci && ncj < cj) ||
                      (nci == ci && ncj == cj && nck < ck))
                    own = false;  // a smaller active cell will emit it
                }
          }
          if (!own) continue;
          const Vec3 np = node_pos(R, gx, gy, gz);
          const double r = checked_radius(G, np);
          // Boundary finish: a node ball whose solid would breach the eroded
          // region is dropped — its incident struts were already clipped short
          // of it and their cut ends get anchor balls instead.
          if (B && B->signed_distance(np) < r) continue;
          emit_node(sink, np, r);
          if (obs && obs->on_element)
            obs->on_element(LatticeGenElement::Node, np, np, r);
          tris += 20ull;
          st.node_triangles += 20ull;
          ++st.nodes;
          st.interior_volume_mm3 += icosahedron_volume(r);
        }
      }
  st.triangles = tris;

  // ── the boundary skin (a SEPARATE pass; bar B8's streaming discipline) ─────
  if (B && skin.mode != LatticeSkinMode::None) {
    // Rim loops where analytic faces meet (both Rim and Diagrid modes).
    const auto& faces = B->faces();
    for (std::size_t i = 0; i < faces.size(); ++i)
      for (std::size_t j = i + 1; j < faces.size(); ++j) {
        const bool pi = faces[i].kind == LatticeBoundaryFace::Kind::Plane;
        const bool pj = faces[j].kind == LatticeBoundaryFace::Kind::Plane;
        if (pi && pj) {
          emit_rim_line(sink, R, G, skin, static_cast<int>(i),
                        static_cast<int>(j), st, obs);
        } else if (pi != pj) {
          const int fp = pi ? static_cast<int>(i) : static_cast<int>(j);
          const int fb = pi ? static_cast<int>(j) : static_cast<int>(i);
          if (faces[static_cast<std::size_t>(fb)].collar)
            emit_rim_torus(sink, R, G, skin, fp, fb, st, obs);
        }
        // bore-bore pairs meet nowhere a rim can ride; nothing to emit
      }

    // The anchored diagrid (Diagrid mode): anchor balls at every landing, skin
    // edges linking neighbouring landings on the same face. Each cell gathers
    // its 27-neighbourhood's landings by DETERMINISTIC RECOMPUTE — no global
    // landing set — and owns exactly the edges whose midpoint falls inside it.
    if (skin.mode == LatticeSkinMode::Diagrid) {
      CellCut ncut;
      std::vector<Landing> hood;
      for (int ck = 0; ck < R.nz; ++ck)
        for (int cj = 0; cj < R.ny; ++cj)
          for (int ci = 0; ci < R.nx; ++ci) {
            hood.clear();
            std::size_t own_landings = 0;
            for (int dk = -1; dk <= 1; ++dk)
              for (int dj = -1; dj <= 1; ++dj)
                for (int di = -1; di <= 1; ++di) {
                  const int ni = ci + di, nj = cj + dj, nk = ck + dk;
                  if (!cell_active(R, ni, nj, nk)) continue;
                  cut_cell_struts(R, G, RS, ni, nj, nk, ncut);
                  if (di == 0 && dj == 0 && dk == 0) {
                    // Anchor balls: one at each of THIS cell's landings, at the
                    // interior strut's own radius (contained by the clip
                    // certificate), welding the cut end to the skin (bar B6).
                    for (const auto& L : ncut.landings) {
                      emit_node(sink, L.pos, L.r);
                      if (obs && obs->on_element)
                        obs->on_element(LatticeGenElement::AnchorNode, L.pos,
                                        L.pos, L.r);
                      ++st.anchor_nodes;
                      st.skin_triangles += 20ull;
                      st.triangles += 20ull;
                      st.skin_volume_mm3 += icosahedron_volume(L.r);
                    }
                    own_landings = ncut.landings.size();
                  }
                  hood.insert(hood.end(), ncut.landings.begin(),
                              ncut.landings.end());
                }
            if (hood.empty() || (own_landings == 0 && hood.size() < 2)) continue;
            const double link = kLinkFactor * R.cell_mm;
            const Vec3 cmin{R.origin.x + ci * R.cell_mm,
                            R.origin.y + cj * R.cell_mm,
                            R.origin.z + ck * R.cell_mm};
            // Mutual-kNN rank within the hood: how many same-face landings sit
            // closer to `a` than `b` does (ties broken by index — the hood
            // order is deterministic, so ranks are too).
            auto rank = [&hood](std::size_t a, std::size_t b) {
              const Landing& A = hood[a];
              const double d_ab = norm(sub(hood[b].pos, A.pos));
              int r = 0;
              for (std::size_t c = 0; c < hood.size(); ++c) {
                if (c == a || c == b) continue;
                if (hood[c].face != A.face) continue;
                const double d = norm(sub(hood[c].pos, A.pos));
                if (d < d_ab - 1e-12 ||
                    (std::fabs(d - d_ab) <= 1e-12 && c < b))
                  ++r;
              }
              return r;
            };
            for (std::size_t a = 0; a < hood.size(); ++a)
              for (std::size_t b = a + 1; b < hood.size(); ++b) {
                const Landing& A = hood[a];
                const Landing& Bl = hood[b];
                if (A.face < 0 || A.face != Bl.face) continue;
                const LatticeBoundaryFace& F =
                    B->faces()[static_cast<std::size_t>(A.face)];
                if (F.kind == LatticeBoundaryFace::Kind::Bore && !F.collar)
                  continue;
                const double dist = norm(sub(Bl.pos, A.pos));
                if (dist < 1e-9 || dist > link) continue;
                const Vec3 mid = scale(add(A.pos, Bl.pos), 0.5);
                // midpoint ownership — each edge emitted by exactly one cell
                if (mid.x < cmin.x || mid.x >= cmin.x + R.cell_mm ||
                    mid.y < cmin.y || mid.y >= cmin.y + R.cell_mm ||
                    mid.z < cmin.z || mid.z >= cmin.z + R.cell_mm)
                  continue;
                // Degree bound (see kSkinDegree): both endpoints must rank the
                // other among their nearest, or the diagrid densifies into a
                // clique wherever landings cluster.
                if (rank(a, b) >= kSkinDegree || rank(b, a) >= kSkinDegree)
                  continue;
                emit_skin_edge(sink, R, G, skin, A.face, A, Bl, st, obs);
              }
          }
    }
    st.triangles = st.strut_triangles + st.node_triangles + st.skin_triangles +
                   st.rim_triangles;
  }

  if (st.struts == 0 && st.skin_struts == 0 && st.rim_elements == 0 &&
      st.anchor_nodes == 0) {
    // no emitted solids: leave diameters at 0, not 1e30
    st.min_strut_diameter_mm = 0.0;
    st.max_strut_diameter_mm = 0.0;
  } else if (st.min_strut_diameter_mm > 1e29) {
    st.min_strut_diameter_mm = 0.0;
  }
  return st;
}

}  // namespace topopt
