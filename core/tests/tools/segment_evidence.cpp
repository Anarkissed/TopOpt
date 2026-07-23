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
  return 0;
}
