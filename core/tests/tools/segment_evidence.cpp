// segment_evidence.cpp — handoff 134 evidence generator.
//
// 1. Builds/loads the three reference meshes.
// 2. Sweeps the dihedral threshold and prints region counts (the sweep the
//    shipped 35 deg value is chosen from).
// 3. Renders each mesh coloured by pseudo-face, with the region boundaries
//    drawn, so the segmentation is visible rather than asserted.
//
// Output: PPM (converted to PNG by the driver script) + a sweep table on stdout.

#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/segment.hpp"
#include "topopt/stl.hpp"
#include "topopt/step.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;

static const double kPi = 3.14159265358979323846;

// ---------------------------------------------------------------------------
// Reference mesh 2: a printables-style bracket — a flat mounting plate with a
// sharp rectangular outline and a cylindrical bolt bore. AUTHORED FOR THIS
// EVIDENCE: it is representative of the geometry class (flat flanges, sharp
// outline, a through bore) rather than a file downloaded from Printables.
static void add_quad(TriangleMesh& m, int a, int b, int c, int d) {
  m.triangles.push_back({a, b, c});
  m.triangles.push_back({a, c, d});
}

// A rectangular plate [-hx,hx] x [-hy,hy] x [z0,z1] with ONE central through
// bore of radius r. Sharp corners (a real bracket outline), a genuine
// cylindrical bore, flat top and bottom. The top/bottom faces are triangulated
// as a fan from the bore rim to the rectangle outline: each bore-rim vertex is
// joined to the rectangle point along the SAME ray, and the rectangle is
// sampled at those ray hits plus its four true corners, so the outline is an
// exact rectangle rather than a corner-cut polygon.
static TriangleMesh make_plate_with_bore(double hx, double hy, double z0,
                                         double z1, double r, int nseg) {
  TriangleMesh m;
  // Outline samples: for each of nseg rays, the rectangle hit; plus the four
  // exact corners, inserted in angular order so the outline is closed and sharp.
  struct P {
    double a, x, y;
    bool corner;
  };
  std::vector<P> outline;
  for (int i = 0; i < nseg; ++i) {
    const double a = 2.0 * kPi * i / nseg;
    const double ca = std::cos(a), sa = std::sin(a);
    double R = 1e30;
    if (std::fabs(ca) > 1e-12) R = std::min(R, hx / std::fabs(ca));
    if (std::fabs(sa) > 1e-12) R = std::min(R, hy / std::fabs(sa));
    outline.push_back({a, R * ca, R * sa, false});
  }
  const double corner_a[4] = {std::atan2(hy, hx), std::atan2(hy, -hx),
                              std::atan2(-hy, -hx) + 2 * kPi,
                              std::atan2(-hy, hx) + 2 * kPi};
  const double corner_x[4] = {hx, -hx, -hx, hx};
  const double corner_y[4] = {hy, hy, -hy, -hy};
  for (int k = 0; k < 4; ++k)
    outline.push_back({corner_a[k], corner_x[k], corner_y[k], true});
  std::sort(outline.begin(), outline.end(),
            [](const P& a, const P& b) { return a.a < b.a; });
  const int n = static_cast<int>(outline.size());

  // Vertices: bore rim (bottom, top) then outline (bottom, top). The bore rim
  // is re-sampled at the outline's angles so rim and outline correspond 1:1.
  const int rim_lo = 0;
  for (const P& p : outline)
    m.vertices.push_back(Vec3{r * std::cos(p.a), r * std::sin(p.a), z0});
  const int rim_hi = static_cast<int>(m.vertices.size());
  for (const P& p : outline)
    m.vertices.push_back(Vec3{r * std::cos(p.a), r * std::sin(p.a), z1});
  const int out_lo = static_cast<int>(m.vertices.size());
  for (const P& p : outline) m.vertices.push_back(Vec3{p.x, p.y, z0});
  const int out_hi = static_cast<int>(m.vertices.size());
  for (const P& p : outline) m.vertices.push_back(Vec3{p.x, p.y, z1});

  auto RL = [&](int i) { return rim_lo + (i % n); };
  auto RH = [&](int i) { return rim_hi + (i % n); };
  auto OL = [&](int i) { return out_lo + (i % n); };
  auto OH = [&](int i) { return out_hi + (i % n); };

  for (int i = 0; i < n; ++i) {
    add_quad(m, RL(i), RL(i + 1), OL(i + 1), OL(i));   // bottom face (-z)
    add_quad(m, RH(i), OH(i), OH(i + 1), RH(i + 1));   // top face (+z)
    add_quad(m, RL(i), RH(i), RH(i + 1), RL(i + 1));   // bore wall
    add_quad(m, OL(i), OL(i + 1), OH(i + 1), OH(i));   // outer wall
  }
  return m;
}

// An N-gon prism (closed): barrel + 2 caps. Its per-facet barrel turn is
// 360/N degrees — the LOWER bound on the threshold.
static TriangleMesh make_prism(int n, double r, double h) {
  TriangleMesh m;
  for (int i = 0; i < n; ++i) {
    const double a = 2.0 * kPi * i / n;
    m.vertices.push_back(Vec3{r * std::cos(a), r * std::sin(a), 0.0});
  }
  for (int i = 0; i < n; ++i) {
    const double a = 2.0 * kPi * i / n;
    m.vertices.push_back(Vec3{r * std::cos(a), r * std::sin(a), h});
  }
  const int cb = static_cast<int>(m.vertices.size());
  m.vertices.push_back(Vec3{0, 0, 0});
  const int ct = cb + 1;
  m.vertices.push_back(Vec3{0, 0, h});
  for (int i = 0; i < n; ++i) {
    const int j = (i + 1) % n;
    m.triangles.push_back({i, j, n + j});
    m.triangles.push_back({i, n + j, n + i});
    m.triangles.push_back({cb, j, i});
    m.triangles.push_back({ct, n + i, n + j});
  }
  return m;
}

// A box with one 45 deg chamfered edge — the UPPER bound on the threshold: the
// chamfer meets both neighbours at 45 deg and must survive as its own face.
static TriangleMesh make_chamfered_box() {
  TriangleMesh m;
  m.vertices = {{0, 0, 0},  {10, 0, 0},  {10, 10, 0}, {0, 10, 0},
                {0, 0, 10}, {7, 0, 10},  {7, 10, 10}, {0, 10, 10},
                {10, 0, 7}, {10, 10, 7}};
  m.triangles = {{0, 3, 2}, {0, 2, 1}, {4, 5, 6}, {4, 6, 7},
                 {5, 8, 9}, {5, 9, 6}, {1, 2, 9}, {1, 9, 8},
                 {0, 1, 8}, {0, 8, 5}, {0, 5, 4},
                 {3, 7, 6}, {3, 6, 9}, {3, 9, 2},
                 {0, 4, 7}, {0, 7, 3}};
  return m;
}

static TriangleMesh make_bracket() {
  // A 60 x 40 x 5 mounting plate with a central 5 mm bore: the flat flanges,
  // sharp outline and cylindrical bolt bore of a typical printed bracket.
  return make_plate_with_bore(30, 20, 0, 5, 2.5, 24);
}

// ---------------------------------------------------------------------------
// Reference mesh 3: an organic-ish blob — a smooth, everywhere-curved surface
// with no creases anywhere (a perturbed sphere). This is the case where a human
// would say "it's all one surface", and the segmenter must agree rather than
// shattering it.
static TriangleMesh make_blob(int stacks, int slices) {
  TriangleMesh m;
  auto radius = [](double phi, double th) {
    return 20.0 * (1.0 + 0.18 * std::sin(3.0 * th) * std::sin(2.0 * phi)
                       + 0.10 * std::cos(2.0 * phi));
  };
  m.vertices.push_back(Vec3{0, 0, radius(0, 0)});
  for (int i = 1; i < stacks; ++i) {
    const double phi = kPi * i / stacks;
    for (int j = 0; j < slices; ++j) {
      const double th = 2.0 * kPi * j / slices;
      const double r = radius(phi, th);
      m.vertices.push_back(Vec3{r * std::sin(phi) * std::cos(th),
                                r * std::sin(phi) * std::sin(th),
                                r * std::cos(phi)});
    }
  }
  const int bottom = static_cast<int>(m.vertices.size());
  m.vertices.push_back(Vec3{0, 0, -radius(kPi, 0)});
  auto ring = [&](int i, int j) { return 1 + (i - 1) * slices + (j % slices); };
  for (int j = 0; j < slices; ++j)
    m.triangles.push_back({0, ring(1, j), ring(1, j + 1)});
  for (int i = 1; i < stacks - 1; ++i)
    for (int j = 0; j < slices; ++j) {
      m.triangles.push_back({ring(i, j), ring(i + 1, j), ring(i + 1, j + 1)});
      m.triangles.push_back({ring(i, j), ring(i + 1, j + 1), ring(i, j + 1)});
    }
  for (int j = 0; j < slices; ++j)
    m.triangles.push_back({bottom, ring(stacks - 1, j + 1), ring(stacks - 1, j)});
  return m;
}

// ---------------------------------------------------------------------------
// THE FAILURE MESH (handoff 2026-07-24, paint mode). A flat mounting plate with
// a bolt hole whose rim is ROUNDED — a quarter-round fillet from the flat top
// face down into the vertical bore, the way a real printed/CAD bracket hole
// looks. The fillet is what breaks pure dihedral segmentation: over its 90 deg
// turn, each of `nphi` facet steps is 90/nphi deg, well under the 35 deg
// threshold, so region growing walks the whole chain top-face -> fillet -> bore
// as ONE region. A single tap on the hole then also grabs the flat top face a
// user meant to make the Load. This is the committed, repeatable stand-in for
// "the shelf bracket that failed": a plate whose hole rim meets the flat face at
// an overall ~90 deg, but through a fillet rather than a knife edge.
//
// Built closed and manifold so it doubles as an import_part / run_job fixture;
// winding is left to the importer's unify_normals (belt-and-suspenders).
//
// An annular disc: outer radius `Rp`, central bore `r`, thickness z0..z1. The
// flat top is subdivided into `nflat` concentric rings so its INTERIOR triangles
// are flat in every direction (bordered only by other flat triangles) — that is
// what a real wide mounting face looks like, and it is what lets the planar-cone
// guard recognise the flat face and refuse to follow the fillet across the
// crease. A one-ring-wide flat face (every triangle touching the fillet) is NOT
// representative and would defeat the guard for the wrong reason.
static TriangleMesh make_filleted_bore_plate(double Rp, double z0, double z1,
                                             double r, double fr, int nseg,
                                             int nphi, int nflat) {
  TriangleMesh m;
  const double R_out = r + fr;  // where the flat top ends and the fillet begins

  auto ring_xy = [&](double rad, double z, int base) {
    for (int i = 0; i < nseg; ++i) {
      const double a = 2.0 * kPi * i / nseg;
      m.vertices.push_back(Vec3{rad * std::cos(a), rad * std::sin(a), z});
    }
    return base;
  };

  // Vertex bands, each nseg wide. Top rings run OUTER->inner: Rp .. R_out over
  // nflat bands, then the fillet ring 0 (== R_out/z1) .. nphi (== r / z1-fr),
  // then bore-bottom (r/z0) and outer-bottom (Rp/z0).
  std::vector<int> topRing(nflat + 1);
  for (int k = 0; k <= nflat; ++k) {
    const double rad = Rp + (R_out - Rp) * (static_cast<double>(k) / nflat);
    topRing[k] = static_cast<int>(m.vertices.size());
    ring_xy(rad, z1, topRing[k]);
  }
  std::vector<int> filletRing(nphi + 1);
  for (int mm = 0; mm <= nphi; ++mm) {
    const double phi = 0.5 * kPi * mm / nphi;  // 0 at top, 90 deg at bore wall
    const double rad = R_out - fr * std::sin(phi);
    const double zz = (z1 - fr) + fr * std::cos(phi);
    filletRing[mm] = static_cast<int>(m.vertices.size());
    ring_xy(rad, zz, filletRing[mm]);
  }
  const int boreB = static_cast<int>(m.vertices.size());
  ring_xy(r, z0, boreB);
  const int outB = static_cast<int>(m.vertices.size());
  ring_xy(Rp, z0, outB);

  auto A = [&](int base, int i) { return base + (i % nseg); };
  for (int i = 0; i < nseg; ++i) {
    for (int k = 0; k < nflat; ++k)  // flat top annulus (nflat concentric bands)
      add_quad(m, A(topRing[k], i), A(topRing[k], i + 1),
               A(topRing[k + 1], i + 1), A(topRing[k + 1], i));
    // fillet ring 0 == topRing[nflat] (both R_out/z1): stitch fillet from there
    add_quad(m, A(topRing[nflat], i), A(topRing[nflat], i + 1),
             A(filletRing[1], i + 1), A(filletRing[1], i));
    for (int mm = 1; mm < nphi; ++mm)  // remaining rounded fillet rings
      add_quad(m, A(filletRing[mm], i), A(filletRing[mm], i + 1),
               A(filletRing[mm + 1], i + 1), A(filletRing[mm + 1], i));
    add_quad(m, A(filletRing[nphi], i), A(boreB, i), A(boreB, i + 1),
             A(filletRing[nphi], i + 1));                          // bore wall
    add_quad(m, A(boreB, i), A(boreB, i + 1), A(outB, i + 1), A(outB, i)); // bottom
    add_quad(m, A(outB, i), A(outB, i + 1), A(topRing[0], i + 1),
             A(topRing[0], i));                                    // outer wall
  }
  return m;
}

// Pick a representative triangle for the flat TOP (Load) face: outward +z
// normal, highest, and at large radius so it is unambiguously the flat plateau
// and not a fillet facet. Returns -1 if none.
static int top_face_rep(const TriangleMesh& m) {
  int best = -1;
  double best_score = -1e30;
  for (std::size_t t = 0; t < m.triangles.size(); ++t) {
    const auto& tri = m.triangles[t];
    const Vec3& a = m.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& c = m.vertices[static_cast<std::size_t>(tri[2])];
    Vec3 n{(b.y - a.y) * (c.z - a.z) - (b.z - a.z) * (c.y - a.y),
           (b.z - a.z) * (c.x - a.x) - (b.x - a.x) * (c.z - a.z),
           (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)};
    const double nl = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (nl <= 0) continue;
    const double nz = std::fabs(n.z) / nl;  // |cos| to +z (winding-agnostic)
    if (nz < 0.98) continue;
    const double cx = (a.x + b.x + c.x) / 3, cy = (a.y + b.y + c.y) / 3;
    const double cz = (a.z + b.z + c.z) / 3;
    const double rad = std::sqrt(cx * cx + cy * cy);
    const double score = cz * 1000 + rad;  // topmost, then outermost
    if (score > best_score) { best_score = score; best = static_cast<int>(t); }
  }
  return best;
}

// Pick a representative BORE-WALL triangle: near-radial normal, centroid radius
// close to `r`, around mid-height. Returns -1 if none.
static int bore_rep(const TriangleMesh& m, double r) {
  int best = -1;
  double best_err = 1e30;
  for (std::size_t t = 0; t < m.triangles.size(); ++t) {
    const auto& tri = m.triangles[t];
    const Vec3& a = m.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& c = m.vertices[static_cast<std::size_t>(tri[2])];
    Vec3 n{(b.y - a.y) * (c.z - a.z) - (b.z - a.z) * (c.y - a.y),
           (b.z - a.z) * (c.x - a.x) - (b.x - a.x) * (c.z - a.z),
           (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)};
    const double nl = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (nl <= 0) continue;
    if (std::fabs(n.z) / nl > 0.2) continue;  // wall normal is ~horizontal
    const double cx = (a.x + b.x + c.x) / 3, cy = (a.y + b.y + c.y) / 3;
    const double rad = std::sqrt(cx * cx + cy * cy);
    const double err = std::fabs(rad - r);
    if (err < best_err) { best_err = err; best = static_cast<int>(t); }
  }
  return best;
}

// ---------------------------------------------------------------------------
// Renderer: z-buffered flat shading, colour keyed by pseudo-face id, with the
// region boundaries drawn from the face-id buffer.

struct Camera {
  double az = 0.6, el = 0.5;
};

static void render(const TriangleMesh& mesh, const std::vector<int>& face,
                   int face_count, const std::string& out_ppm, int W = 900,
                   int H = 700) {
  Vec3 lo, hi;
  bounding_box(mesh, lo, hi);
  const Vec3 c{(lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2};
  const double span = std::max({hi.x - lo.x, hi.y - lo.y, hi.z - lo.z});

  const Camera cam;
  // Camera basis.
  const double ca = std::cos(cam.az), sa = std::sin(cam.az);
  const double ce = std::cos(cam.el), se = std::sin(cam.el);
  const Vec3 fwd{-ce * ca, -ce * sa, -se};      // looking toward the centre
  const Vec3 right{-sa, ca, 0};
  const Vec3 up{-se * ca, -se * sa, ce};
  const double scale = 0.34 * std::min(W, H) / (span * 0.5);

  std::vector<double> zbuf(static_cast<std::size_t>(W) * H, 1e30);
  std::vector<int> fbuf(static_cast<std::size_t>(W) * H, -1);
  std::vector<double> shade(static_cast<std::size_t>(W) * H, 0.0);

  auto project = [&](const Vec3& p, double& sx, double& sy, double& depth) {
    const Vec3 d{p.x - c.x, p.y - c.y, p.z - c.z};
    sx = W * 0.5 + scale * (d.x * right.x + d.y * right.y + d.z * right.z);
    sy = H * 0.5 - scale * (d.x * up.x + d.y * up.y + d.z * up.z);
    depth = d.x * fwd.x + d.y * fwd.y + d.z * fwd.z;
  };

  const Vec3 light{0.4, 0.3, 0.86};
  for (std::size_t t = 0; t < mesh.triangles.size(); ++t) {
    const auto& tri = mesh.triangles[t];
    const Vec3& p0 = mesh.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& p1 = mesh.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& p2 = mesh.vertices[static_cast<std::size_t>(tri[2])];
    const Vec3 e1{p1.x - p0.x, p1.y - p0.y, p1.z - p0.z};
    const Vec3 e2{p2.x - p0.x, p2.y - p0.y, p2.z - p0.z};
    Vec3 n{e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z,
           e1.x * e2.y - e1.y * e2.x};
    const double nl = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (nl <= 0) continue;
    n = Vec3{n.x / nl, n.y / nl, n.z / nl};
    double lam = n.x * light.x + n.y * light.y + n.z * light.z;
    lam = 0.35 + 0.65 * std::max(0.0, lam);

    double x0, y0, d0, x1, y1, d1, x2, y2, d2;
    project(p0, x0, y0, d0);
    project(p1, x1, y1, d1);
    project(p2, x2, y2, d2);

    const int minx = std::max(0, static_cast<int>(std::floor(std::min({x0, x1, x2}))));
    const int maxx = std::min(W - 1, static_cast<int>(std::ceil(std::max({x0, x1, x2}))));
    const int miny = std::max(0, static_cast<int>(std::floor(std::min({y0, y1, y2}))));
    const int maxy = std::min(H - 1, static_cast<int>(std::ceil(std::max({y0, y1, y2}))));
    const double area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);
    if (std::fabs(area) < 1e-12) continue;

    for (int py = miny; py <= maxy; ++py)
      for (int px = minx; px <= maxx; ++px) {
        const double fx = px + 0.5, fy = py + 0.5;
        double w0 = ((x1 - fx) * (y2 - fy) - (x2 - fx) * (y1 - fy)) / area;
        double w1 = ((x2 - fx) * (y0 - fy) - (x0 - fx) * (y2 - fy)) / area;
        double w2 = 1.0 - w0 - w1;
        if (w0 < 0 || w1 < 0 || w2 < 0) continue;
        const double z = w0 * d0 + w1 * d1 + w2 * d2;
        const std::size_t idx = static_cast<std::size_t>(py) * W + px;
        if (z >= zbuf[idx]) continue;
        zbuf[idx] = z;
        fbuf[idx] = face[t];
        shade[idx] = lam;
      }
  }

  // Distinct, deterministic hues per pseudo-face (golden-ratio hue rotation).
  auto colour = [&](int f, double lam, unsigned char rgb[3]) {
    const double h = std::fmod(f * 0.61803398875, 1.0);
    const double s = 0.55, v = 0.95 * lam;
    const int i = static_cast<int>(h * 6);
    const double ff = h * 6 - i;
    const double p = v * (1 - s), q = v * (1 - s * ff), tt = v * (1 - s * (1 - ff));
    double r = 0, g = 0, b = 0;
    switch (i % 6) {
      case 0: r = v; g = tt; b = p; break;
      case 1: r = q; g = v; b = p; break;
      case 2: r = p; g = v; b = tt; break;
      case 3: r = p; g = q; b = v; break;
      case 4: r = tt; g = p; b = v; break;
      case 5: r = v; g = p; b = q; break;
    }
    rgb[0] = static_cast<unsigned char>(255 * std::min(1.0, r));
    rgb[1] = static_cast<unsigned char>(255 * std::min(1.0, g));
    rgb[2] = static_cast<unsigned char>(255 * std::min(1.0, b));
  };

  std::ofstream out(out_ppm, std::ios::binary);
  out << "P6\n" << W << " " << H << "\n255\n";
  for (int py = 0; py < H; ++py)
    for (int px = 0; px < W; ++px) {
      const std::size_t idx = static_cast<std::size_t>(py) * W + px;
      unsigned char rgb[3] = {24, 26, 30};  // background
      if (fbuf[idx] >= 0) {
        // Boundary: a neighbouring pixel belongs to a different pseudo-face.
        bool edge = false;
        for (int dy = -1; dy <= 1 && !edge; ++dy)
          for (int dx = -1; dx <= 1 && !edge; ++dx) {
            const int qx = px + dx, qy = py + dy;
            if (qx < 0 || qy < 0 || qx >= W || qy >= H) continue;
            const int nf = fbuf[static_cast<std::size_t>(qy) * W + qx];
            if (nf != fbuf[idx]) edge = true;
          }
        if (edge) {
          rgb[0] = rgb[1] = rgb[2] = 10;  // black pseudo-face boundary
        } else {
          colour(fbuf[idx], shade[idx], rgb);
        }
      }
      out.write(reinterpret_cast<char*>(rgb), 3);
    }
  (void)face_count;
}

// ---------------------------------------------------------------------------

static void sweep(const std::string& name, const TriangleMesh& mesh) {
  std::printf("\n%s  (%zu triangles)\n", name.c_str(), mesh.triangles.size());
  std::printf("  threshold:");
  const double ts[] = {15, 20, 25, 30, 35, 40, 45, 50, 60};
  for (double t : ts) std::printf("%6.0f", t);
  std::printf("\n  regions:  ");
  for (double t : ts) {
    SegmentOptions o;
    o.dihedral_threshold_deg = t;
    std::printf("%6d", segment_mesh_faces(mesh, o).face_count);
  }
  std::printf("\n");
  SegmentOptions shipped;
  const MeshSegmentation s = segment_mesh_faces(mesh, shipped);
  int planes = 0, cyls = 0, other = 0;
  for (const auto& f : s.faces) {
    if (f.kind == StepSurfaceKind::Plane) ++planes;
    else if (f.kind == StepSurfaceKind::Cylinder) ++cyls;
    else ++other;
  }
  std::printf("  at 35 deg: %d regions (%d plane, %d cylinder, %d other)\n",
              s.face_count, planes, cyls, other);
}

int main(int argc, char** argv) {
  const std::string outdir = argc > 1 ? argv[1] : ".";
  const std::string fixtures = argc > 2 ? argv[2] : ".";

  struct Ref {
    std::string name;
    TriangleMesh mesh;
  };
  std::vector<Ref> refs;

  // 1. CAD-exported STL of an existing project part: the demo L-bracket STEP,
  //    tessellated and written out as STL, then re-imported through the mesh
  //    path — i.e. exactly what a user does when they export STL from CAD.
  {
    const std::string step = fixtures + "/demo/l-bracket.step";
    const std::string stl = outdir + "/ref1_l_bracket_cad_export.stl";
    try {
      const StepModel sm = import_step_file(step);
      write_stl_file(stl, sm.mesh, StlFormat::Binary);
      std::printf("wrote %s (from %s, %zu triangles)\n", stl.c_str(), step.c_str(),
                  sm.mesh.triangles.size());
      refs.push_back({"ref1: L-bracket, CAD-exported STL (project part)",
                      import_part(stl).model.mesh});
    } catch (const std::exception& e) {
      std::printf("ref1 SKIPPED: %s\n", e.what());
    }
  }

  // 2. Printables-style bracket (authored for this evidence).
  {
    const TriangleMesh b = make_bracket();
    const std::string stl = outdir + "/ref2_bracket.stl";
    write_stl_file(stl, b, StlFormat::Binary);
    refs.push_back({"ref2: bolted flange bracket (printables-style, authored)",
                    import_part(stl).model.mesh});
  }

  // 3. Organic-ish blob.
  {
    const TriangleMesh b = make_blob(40, 56);
    const std::string stl = outdir + "/ref3_blob.stl";
    write_stl_file(stl, b, StlFormat::Binary);
    refs.push_back({"ref3: organic blob (everywhere-curved)",
                    import_part(stl).model.mesh});
  }

  std::printf("\n================ DIHEDRAL THRESHOLD SWEEP ================\n");
  std::printf("\n-- reference meshes --\n");
  for (const auto& r : refs) sweep(r.name, r.mesh);

  // The reference meshes are FLAT across 20-60 deg: on real parts the choice is
  // not knife-edge, which is worth knowing but does not bound the threshold.
  // The bound comes from the two cases that pull in opposite directions, so
  // they are swept here alongside (and asserted in tests/unit/test_segment.cpp).
  std::printf("\n-- bounding cases (these are what fix the value) --\n");
  sweep("LOWER bound: 12-gon cylinder (30 deg/facet) — barrel must stay ONE face"
        " (want 3)",
        make_prism(12, 5.0, 20.0));
  sweep("      also: 8-gon cylinder (45 deg/facet) — the known caveat, fragments"
        " (8 strips + 2 caps = 10)",
        make_prism(8, 5.0, 20.0));
  sweep("UPPER bound: 45 deg chamfered box — the chamfer must stay its OWN face"
        " (want 7, not 6)",
        make_chamfered_box());

  std::printf("\n================ RENDERS ================\n");
  int i = 1;
  for (const auto& r : refs) {
    const MeshSegmentation s = segment_mesh_faces(r.mesh);
    const std::string ppm = outdir + "/ref" + std::to_string(i) + ".ppm";
    render(r.mesh, s.triangle_face, s.face_count, ppm);
    std::printf("wrote %s (%d pseudo-faces)\n", ppm.c_str(), s.face_count);
    ++i;
  }

  // -------------------------------------------------------------------------
  // THE FILLETED-BORE FAILURE + FIX (handoff 2026-07-24). Build the plate, write
  // it as a committed fixture, and show the leak vanish under the planar cone.
  std::printf("\n================ FILLETED-BORE FAILURE + FIX ================\n");
  const double r_bore = 4.0, fillet = 2.0;
  // Rp=22 disc, 6 mm thick, 4 mm bore, 2 mm rounded rim, 48 facets around, 8
  // fillet rings (11.25 deg/step, well under 35), flat top 4 rings wide.
  const TriangleMesh plate =
      make_filleted_bore_plate(22, 0, 6, r_bore, fillet, 48, 8, 4);
  // Commit the fixture into the repo (argv[2] = fixtures dir) AND drop a copy in
  // the evidence outdir. Round-trip through import_part so the committed bytes
  // are exactly what a downstream test re-reads (welded, unified winding).
  const std::string fixture = fixtures + "/mesh/filleted_bore_plate.stl";
  write_stl_file(fixture, plate, StlFormat::Binary);
  write_stl_file(outdir + "/filleted_bore_plate.stl", plate, StlFormat::Binary);
  const TriangleMesh mesh = import_part(fixture).model.mesh;  // welded + unified
  std::printf("wrote %s (%zu triangles, watertight=%d)\n", fixture.c_str(),
              mesh.triangles.size(),
              static_cast<int>(check_watertight(mesh).watertight));

  const int top = top_face_rep(mesh);
  const int bore = bore_rep(mesh, r_bore);
  auto report = [&](const char* label, const SegmentOptions& o,
                    const std::string& ppm) {
    const MeshSegmentation s = segment_mesh_faces(mesh, o);
    const bool leak = top >= 0 && bore >= 0 &&
                      s.triangle_face[static_cast<std::size_t>(top)] ==
                          s.triangle_face[static_cast<std::size_t>(bore)];
    std::printf("  %-28s regions=%3d  top#%d/bore#%d -> %s\n", label,
                s.face_count, top, bore,
                leak ? "SAME REGION (leak: tap on hole grabs Load face)"
                     : "separate regions (Load face selectable alone)");
    render(mesh, s.triangle_face, s.face_count, ppm);
  };
  SegmentOptions off;
  off.planar_region_cone_deg = 0.0;  // pure local dihedral = handoff-134 default
  report("BEFORE (cone off, 35 deg)", off, outdir + "/filleted_bore_before.ppm");
  SegmentOptions on;  // shipped default (planar cone 40 deg)
  report("AFTER  (shipped default)", on, outdir + "/filleted_bore_after.ppm");
  return 0;
}
