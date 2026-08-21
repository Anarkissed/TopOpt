// BRIDGE-SPAN TEST COUPON, task 2026-08-20-lattice-only-grading.
//
// WHY THIS EXISTS. The scope for GRADED was gated on a 45-degrees-from-vertical
// overhang rule taken from the brief and applied to STRUTS. That was wrong: 45
// degrees is a heuristic for overhanging SURFACES, while a strut between two
// anchored nodes is a BRIDGE, governed by unsupported SPAN, not angle. The
// maintainer has printed a bridged octet lattice successfully, which is the
// counter-evidence. This coupon replaces both guesses with a measurement.
//
// ★ THE SPECIMENS ARE PRODUCTION GEOMETRY. Every strut here is emitted by
// `generate_lattice` — the shipped octet generator (swept n-gon prisms + icosahedral
// nodes, cell-local ownership, fixed traversal). Nothing about the strut shape is
// re-derived for the test, so a result transfers to production without an asterisk.
// The only geometry this file authors is the BASE SLAB under each specimen, which
// anchors the bottom nodes so the first layer is not eight isolated points. The base
// is a fixture, not the thing under test.
//
// WHAT IT SWEEPS. The octet cell carries struts at exactly two angles — 45 deg
// (24 of 36) and 90 deg, horizontal (12 of 36) — and the horizontal ones span
// 0.7071 x cell. So sweeping CELL SIZE sweeps bridge span directly, and each
// specimen tests both angles at once:
//
//     cell 2 mm -> 1.41 mm span      cell 24 mm -> 16.97 mm span
//     cell 4 mm -> 2.83 mm span      cell 32 mm -> 22.63 mm span
//     cell 8 mm -> 5.66 mm span      cell 48 mm -> 33.94 mm span
//     cell 16 mm -> 11.31 mm span
//
// Row A holds each cell at a PRODUCTION-TYPICAL strut radius for its size; row B
// holds every cell at the THINNEST printable strut (half the stated extrusion
// width), which is the worst case the band can emit; row C is a 2x2x2 block at the
// three cell sizes his own part actually used, as the positive control that must
// print — it is the geometry he has already printed successfully.
//
// Deterministic: fixed order, no RNG. Same arguments -> byte-identical STL.

#include <algorithm>
#include <map>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "topopt/lattice.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/mesh.hpp"
#include "topopt/stl.hpp"
#include "topopt/lattice.hpp"

using namespace topopt;

namespace {

void add_box(TriangleSink& sink, const Vec3& lo, const Vec3& hi) {
  const Vec3 p[8] = {{lo.x, lo.y, lo.z}, {hi.x, lo.y, lo.z}, {hi.x, hi.y, lo.z},
                     {lo.x, hi.y, lo.z}, {lo.x, lo.y, hi.z}, {hi.x, lo.y, hi.z},
                     {hi.x, hi.y, hi.z}, {lo.x, hi.y, hi.z}};
  const int f[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7},
                        {0, 1, 5}, {0, 5, 4}, {1, 2, 6}, {1, 6, 5},
                        {2, 3, 7}, {2, 7, 6}, {3, 0, 4}, {3, 4, 7}};
  for (const auto& t : f) sink.add_triangle(p[t[0]], p[t[1]], p[t[2]]);
}

struct Solid { Vec3 a, b; double r; bool ball; };

struct Specimen {
  std::string label;
  double cell_mm;
  int nx, ny, nz;
  double radius_mm;
};

}  // namespace

int main(int argc, char** argv) {
  const std::string out = argc > 1 ? argv[1] : "bridge_coupon.stl";
  const std::string map = argc > 2 ? argv[2] : "bridge_coupon_MAP.txt";
  // The stated extrusion width his job carries; the thinnest printable strut is
  // half of it as a radius.
  const double w = argc > 3 ? std::atof(argv[3]) : 0.42;
  const double r_min = 0.5 * w;

  std::vector<Specimen> specs;
  // ── THE MATRIX: span (via cell size) x strut DIAMETER ───────────────────────
  // The two variables that decide whether a bridge succeeds. Tying diameter to
  // cell size (as production does) would confound them: a 48 mm cell at mid-band
  // density emits a 7.9 mm radius, which is a solid, not a bridge. So diameter is
  // swept INDEPENDENTLY here, across the range production actually emits on his
  // part (0.42 mm at the band floor up to 1.70 mm at the coarsest level).
  const double cells[] = {2.0, 4.0, 8.0, 16.0, 24.0, 32.0};
  const double diams[] = {0.42, 0.84, 1.68};
  const char* dname[] = {"A", "B", "C"};
  for (int di = 0; di < 3; ++di)
    for (double c : cells) {
      char buf[160];
      std::snprintf(buf, sizeof buf, "%s d%.2f cell%.0f span%.2f", dname[di],
                    diams[di], c, 0.70710678 * c);
      specs.push_back({buf, c, 1, 1, 1, 0.5 * diams[di]});
    }
  // ROW D — POSITIVE CONTROL: 2x2x2 blocks at the three cell sizes his part used,
  // at the radii his run actually emitted. This is geometry he has ALREADY printed
  // successfully; if it fails on the plate the coupon itself is suspect, not the
  // lattice.
  const double ctrl_cell[3] = {2.0, 4.0, 8.0};
  const double ctrl_r[3] = {0.420044030 / 2, 0.420666149 / 2, 0.730019000 / 2};
  for (int i = 0; i < 3; ++i) {
    char buf[160];
    std::snprintf(buf, sizeof buf, "D HIS-RUN cell%.0f span%.2f d%.3f",
                  ctrl_cell[i], 0.70710678 * ctrl_cell[i], 2 * ctrl_r[i]);
    specs.push_back({buf, ctrl_cell[i], 2, 2, 2, ctrl_r[i]});
  }

  MeshSink sink;
  std::vector<std::vector<Solid>> specimen_solids;
  std::vector<std::array<Vec3, 2>> specimen_slab;
  const double base_t = 1.2;      // base slab thickness (fixture, not under test)
  const double margin = 3.0;      // slab overhang past the cell footprint
  const double gap = 8.0;         // clear space between specimens

  std::FILE* mf = std::fopen(map.c_str(), "w");
  std::fprintf(mf,
               "BRIDGE-SPAN TEST COUPON — layout map\n"
               "Every strut is emitted by core's shipped generate_lattice (octet).\n"
               "The octet carries struts at 45 deg and at 90 deg (horizontal);\n"
               "the horizontal span is 0.7071 x cell, so cell size IS the span sweep.\n"
               "Base slabs are fixtures that anchor the bottom nodes; they are not\n"
               "under test.\n\n"
               "stated extrusion width: %.3f mm   thinnest strut radius: %.3f mm\n"
               "rows A/B/C sweep DIAMETER; within each row, cell size sweeps SPAN.\n"
               "row D is the positive control: geometry already printed successfully.\n"
               "THE BRIDGES UNDER TEST are the cell top-face horizontals and the four\n"
               "mid-height octahedron edges. The bottom-face horizontals rest ON the\n"
               "base slab and are not bridges - ignore them when scoring.\n\n"
               "%-34s %9s %9s %10s %9s %9s\n",
               w, r_min, "specimen", "cell_mm", "span_mm", "diam_mm", "org_x", "org_y");

  double x = 0.0;
  double row_y = 0.0;
  char last_row = specs.empty() ? 'A' : specs[0].label[0];
  double row_depth = 0.0;
  for (const Specimen& s : specs) {
    if (s.label[0] != last_row) {
      last_row = s.label[0];
      x = 0.0;
      row_y += row_depth + gap;
      row_depth = 0.0;
    }
    row_depth = std::max(row_depth, s.ny * s.cell_mm + 2 * margin);
    const double fx = s.nx * s.cell_mm, fy = s.ny * s.cell_mm;
    const Vec3 org{x + margin, row_y + margin, base_t};
    add_box(sink, Vec3{x, row_y, 0.0},
            Vec3{x + fx + 2 * margin, row_y + fy + 2 * margin, base_t});

    LatticeRegion region;
    region.origin = org;
    region.nx = s.nx; region.ny = s.ny; region.nz = s.nz;
    region.cell_mm = s.cell_mm;
    LatticeRadiusField rad;
    rad.uniform_mm = s.radius_mm;
    rad.nseg = 8;
    // Collect this specimen's solids from the generator's OWN element list, so the
    // welded body is built from exactly what production emitted.
    std::vector<Solid> sol;
    LatticeGenObserver obs;
    obs.on_element = [&](LatticeGenElement kind, const Vec3& a, const Vec3& b, double rr) {
      const bool ball = kind == LatticeGenElement::Node ||
                        kind == LatticeGenElement::AnchorNode;
      sol.push_back({a, ball ? a : b, rr, ball});
    };
    const LatticeGenStats st =
        generate_lattice(LatticeGenTopology::Octet, region, rad, sink, LatticeSkinSpec{}, &obs);
    specimen_solids.push_back(std::move(sol));
    specimen_slab.push_back({Vec3{x, row_y, 0.0},
                             Vec3{x + fx + 2 * margin, row_y + fy + 2 * margin, base_t}});

    std::fprintf(mf, "%-34s %9.1f %9.2f %10.3f %9.1f %9.1f  (%llu struts)\n",
                 s.label.c_str(), s.cell_mm, 0.70710678 * s.cell_mm,
                 2 * s.radius_mm, x, row_y, (unsigned long long)st.struts);
    x += fx + 2 * margin + gap;
  }
  std::fclose(mf);

  Vec3 lo, hi;
  bounding_box(sink.mesh, lo, hi);
  write_stl_file(out, sink.mesh);

  // ── ★ THE WELDED PLATE ──────────────────────────────────────────────────────
  // The soup above is production's emission format: every strut its own closed
  // prism, every node its own icosahedron. Measured on this plate: 483 shells, of
  // which 462 never touch the build plate — which is what a slicer reports as
  // FLOATING REGIONS. The material is fine; the MESH is 483 bodies.
  //
  // ★ EACH SPECIMEN IS WELDED SEPARATELY. This plate holds 21 INTENTIONALLY
  // separate test pieces, so keeping only the largest component (the fix used on
  // the graded coupon, which is one object) would delete 20 of them. Per specimen:
  // rasterise -> marching cubes -> keep that specimen's largest component, then
  // concatenate. Result: 21 watertight bodies, every one sitting on the plate.
  //
  // The raster is CONSERVATIVE and matches the emitted solid: flat caps (no capsule
  // extension) and the n-gon INRADIUS, never the circumradius.
  {
    const double kPrismIn = std::cos(M_PI / 8.0);
    const double kIcosaIn = 0.7946544722917661;
    // ★ ONE FILE PER ROW. The whole welded plate is ~166 MB, which is unwieldy to
    // move around and to load. The plate is 21 INDEPENDENT specimens, so splitting
    // by row costs nothing and lets the control row (D) be printed first.
    TriangleMesh plate;
    std::map<char, TriangleMesh> rows;
    std::size_t welded_bodies = 0;
    for (std::size_t si = 0; si < specimen_solids.size(); ++si) {
      const auto& sol = specimen_solids[si];
      const Vec3 slo = specimen_slab[si][0], shi = specimen_slab[si][1];
      double rmin = 1e9;
      Vec3 blo2 = slo, bhi2 = shi;
      for (const Solid& sd : sol) {
        rmin = std::min(rmin, sd.r);
        blo2 = Vec3{std::min(blo2.x, std::min(sd.a.x, sd.b.x) - sd.r),
                    std::min(blo2.y, std::min(sd.a.y, sd.b.y) - sd.r),
                    std::min(blo2.z, std::min(sd.a.z, sd.b.z) - sd.r)};
        bhi2 = Vec3{std::max(bhi2.x, std::max(sd.a.x, sd.b.x) + sd.r),
                    std::max(bhi2.y, std::max(sd.a.y, sd.b.y) + sd.r),
                    std::max(bhi2.z, std::max(sd.a.z, sd.b.z) + sd.r)};
      }
      // pitch tied to the THINNEST strut here, so a thin strut never breaks up in
      // the raster; fat specimens get a coarser pitch and cost far fewer triangles.
      // Pitch tied to the THINNEST strut so it never breaks up in the raster —
      // but CAPPED BY MEMORY: a 0.42 mm strut in a 32 mm cell wants a ~500^3 grid,
      // which is a gigabyte of doubles per specimen. Coarsen until it fits, and say
      // so, rather than silently thrashing or dying.
      double vx = std::min(0.30, std::max(0.10, 0.42 * rmin));
      int RX = 0, RY = 0, RZ = 0;
      Vec3 rlo{0, 0, 0};
      const long long kMaxVoxels = 24000000;
      for (;;) {
        rlo = Vec3{blo2.x - 2 * vx, blo2.y - 2 * vx, blo2.z - 2 * vx};
        RX = int((bhi2.x - rlo.x) / vx) + 4;
        RY = int((bhi2.y - rlo.y) / vx) + 4;
        RZ = int((bhi2.z - rlo.z) / vx) + 4;
        if (1LL * RX * RY * RZ <= kMaxVoxels) break;
        vx *= 1.25;
      }
      const double across = 2.0 * rmin / vx;   // voxels across the thinnest strut
      std::printf("  [%2zu/%2zu] %-34s vx %.3f mm  grid %dx%dx%d  thinnest strut %.1f vox\n",
                  si + 1, specimen_solids.size(), specs[si].label.c_str(), vx, RX, RY, RZ, across);
      std::fflush(stdout);
      std::vector<double> field(std::size_t(RX) * RY * RZ, 0.0);
      auto at = [&](int i, int j, int k) -> double& {
        return field[(std::size_t(k) * RY + j) * RX + i]; };
      for (const Solid& sd : sol) {
        const double rr = sd.r * (sd.ball ? kIcosaIn : kPrismIn);
        const Vec3 ab{sd.b.x - sd.a.x, sd.b.y - sd.a.y, sd.b.z - sd.a.z};
        const double L2 = ab.x * ab.x + ab.y * ab.y + ab.z * ab.z;
        const int i0 = std::max(0, int((std::min(sd.a.x, sd.b.x) - sd.r - rlo.x) / vx));
        const int i1 = std::min(RX - 1, int((std::max(sd.a.x, sd.b.x) + sd.r - rlo.x) / vx) + 1);
        const int j0 = std::max(0, int((std::min(sd.a.y, sd.b.y) - sd.r - rlo.y) / vx));
        const int j1 = std::min(RY - 1, int((std::max(sd.a.y, sd.b.y) + sd.r - rlo.y) / vx) + 1);
        const int k0 = std::max(0, int((std::min(sd.a.z, sd.b.z) - sd.r - rlo.z) / vx));
        const int k1 = std::min(RZ - 1, int((std::max(sd.a.z, sd.b.z) + sd.r - rlo.z) / vx) + 1);
        for (int k = k0; k <= k1; ++k) for (int j = j0; j <= j1; ++j) for (int i = i0; i <= i1; ++i) {
          const Vec3 q{rlo.x + (i + .5) * vx, rlo.y + (j + .5) * vx, rlo.z + (k + .5) * vx};
          if (sd.ball) {
            const double dx = q.x - sd.a.x, dy = q.y - sd.a.y, dz = q.z - sd.a.z;
            if (std::sqrt(dx*dx + dy*dy + dz*dz) <= rr) at(i, j, k) = 1.0;
            continue;
          }
          const double t = L2 > 1e-18
              ? ((q.x-sd.a.x)*ab.x + (q.y-sd.a.y)*ab.y + (q.z-sd.a.z)*ab.z) / L2 : 0.0;
          if (t < 0.0 || t > 1.0) continue;      // flat caps
          const double cx = sd.a.x + ab.x*t, cy = sd.a.y + ab.y*t, cz = sd.a.z + ab.z*t;
          const double dx = q.x-cx, dy = q.y-cy, dz = q.z-cz;
          if (std::sqrt(dx*dx + dy*dy + dz*dz) <= rr) at(i, j, k) = 1.0;
        }
      }
      for (int k = 0; k < RZ; ++k) for (int j = 0; j < RY; ++j) for (int i = 0; i < RX; ++i) {
        const Vec3 q{rlo.x + (i + .5) * vx, rlo.y + (j + .5) * vx, rlo.z + (k + .5) * vx};
        if (q.z >= 0 && q.z <= shi.z && q.x >= slo.x && q.x <= shi.x &&
            q.y >= slo.y && q.y <= shi.y) at(i, j, k) = 1.0;
      }
      TriangleMesh m = marching_cubes(RX, RY, RZ, vx, rlo, field, 0.5);
      const int comps_before = count_components(m);
      const double vol_before = std::fabs(signed_volume(m));
      m = keep_largest_component(m);
      const double vol_after = std::fabs(signed_volume(m));
      const double lost = vol_before > 1e-9 ? (vol_before - vol_after) / vol_before : 0.0;
      // ★ A THIN STRUT CAN BREAK UP IN THE RASTER, and keep_largest_component would
      // then DELETE it silently — the specimen would print missing exactly the
      // struts under test. Refuse instead. (Sealed cavities also raise the count,
      // so compare emitted volume rather than trusting the count alone.)
      // A sealed cavity is an INWARD surface: dropping it slightly RAISES the
      // volume. A broken strut LOWERS it. So the sign and size of the change tells
      // the two apart, which the component count alone cannot.
      if (comps_before > 1)
        std::printf("           %d components; volume %.3f -> %.3f mm^3 (%+.3f %%) %s\n",
                    comps_before, vol_before, vol_after, -100.0 * lost,
                    lost > 0.01 ? "  <-- ★ MATERIAL LOST: raster too coarse"
                                : "(cavities only)");
      if (lost > 0.01) { std::fprintf(stderr,
          "REFUSING: specimen %zu lost %.1f %% of its volume to keep_largest_component;\n"
          "a coupon missing the struts under test measures nothing.\n", si + 1, 100 * lost);
        return 3; }
      // ★ APPEND WITH A VERTEX OFFSET. TriangleMesh is vertices + INDEX TRIPLES;
      // copying triangles alone leaves every index pointing into another mesh's
      // vertex array. That crashed the writer (SIGSEGV) before this was fixed.
      auto append = [&](TriangleMesh& dst) {
        const int base_v = static_cast<int>(dst.vertices.size());
        dst.vertices.insert(dst.vertices.end(), m.vertices.begin(), m.vertices.end());
        for (const auto& t : m.triangles)
          dst.triangles.push_back({t[0] + base_v, t[1] + base_v, t[2] + base_v});
      };
      append(plate);
      append(rows[specs[si].label[0]]);
      ++welded_bodies;
    }
    const std::string stem = out.substr(0, out.find_last_of('.'));
    write_stl_file(stem + "_WELDED.stl", plate);
    std::printf("welded plate: %zu bodies, %zu triangles -> %s_WELDED.stl\n",
                welded_bodies, plate.triangles.size(), stem.c_str());
    for (auto& kv : rows) {
      const std::string rp = stem + "_WELDED_row" + std::string(1, kv.first) + ".stl";
      write_stl_file(rp, kv.second);
      std::printf("  row %c: %zu triangles -> %s\n", kv.first,
                  kv.second.triangles.size(), rp.c_str());
    }
  }
  std::printf("wrote %s\n  triangles : %zu\n  bounding box : %.1f x %.1f x %.1f mm\n",
              out.c_str(), sink.mesh.triangles.size(), hi.x - lo.x, hi.y - lo.y,
              hi.z - lo.z);
  std::printf("  map       : %s\n", map.c_str());
  return 0;
}
