// ★ lattice.beam -> STL. The compact form is 8.6 MB and its expansion is 944 MB, and
// the generator spends nine of its ten minutes producing the second. Splitting them
// lets a sweep pay ~2 minutes per configuration for the analysis it actually reads,
// and expand only the configurations worth looking at or printing.
//
// ★ WHAT THIS DOES *NOT* REPRODUCE, and it matters. lattice.beam is written BEFORE the
// region-net drop and the prune rounds (gc2.cpp:1924 against 2164 and 2392), so it is
// the PRE-PRUNE traced network. On the 3 mm run the generator went on to drop 16,413
// out-of-region solids and prune 5,803 struts before writing its STL. This tool
// therefore emits MORE material than the shipped part, and none of the boundary clip,
// the solid, the rim or the finish. It is a VIEWING and DIAGNOSTIC expansion of the
// beam network -- never a printable substitute for the generator's own out.stl.
#include "topopt/organic_lattice.hpp"
#include "topopt/stl.hpp"
#include "topopt/mesh.hpp"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <algorithm>
using namespace topopt;
int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr,
        "usage: %s <lattice.beam> <out.stl> [pitch_mm] [max_voxels] [floor_z]\n"
        "  pitch_mm    weld raster pitch (default 0.25)\n"
        "  max_voxels  cap on the weld raster (default 400000000)\n"
        "  floor_z     cut the solid flat at this z (default: no cut)\n", argv[0]);
    return 2;
  }
  const std::string in = argv[1], out = argv[2];
  const double pitch = argc > 3 ? std::atof(argv[3]) : 0.25;
  const long long cap = argc > 4 ? std::atoll(argv[4]) : 400000000LL;
  const double floor_z = argc > 5 ? std::atof(argv[5]) : -1e30;

  std::vector<OrganicSpan> spans;
  double lo[3] = {1e30,1e30,1e30}, hi[3] = {-1e30,-1e30,-1e30};
  { std::ifstream f(in);
    if (!f) { std::fprintf(stderr, "cannot open %s\n", in.c_str()); return 2; }
    std::string ln;
    while (std::getline(f, ln)) {
      std::istringstream is(ln); std::string t; is >> t;
      if (t != "SEG") continue;
      OrganicSpan s;
      is >> s.a.x >> s.a.y >> s.a.z >> s.b.x >> s.b.y >> s.b.z >> s.r;
      spans.push_back(s);
      const double px[6] = {s.a.x,s.a.y,s.a.z,s.b.x,s.b.y,s.b.z};
      for (int c = 0; c < 3; ++c) {
        lo[c] = std::min(lo[c], std::min(px[c], px[c+3]));
        hi[c] = std::max(hi[c], std::max(px[c], px[c+3]));
      }
    } }
  if (spans.empty()) { std::fprintf(stderr, "no SEG lines in %s\n", in.c_str()); return 2; }
  std::printf("%zu spans, bbox %.1f x %.1f x %.1f mm\n", spans.size(),
              hi[0]-lo[0], hi[1]-lo[1], hi[2]-lo[2]);
  // the weld raster is the cost here: cells go as (bbox / pitch)^3, so say what it
  // will be before spending it rather than after
  double cells = 1.0;
  for (int c = 0; c < 3; ++c) cells *= (hi[c]-lo[c]) / pitch + 2.0;
  std::printf("weld raster at %.3f mm pitch: %.3g cells (cap %lld)%s\n", pitch, cells,
              cap, cells > double(cap) ? "  -- OVER CAP, weld will coarsen" : "");
  std::fflush(stdout);

  OrganicWeldStats st;
  const TriangleMesh mesh = organic_weld(spans, pitch, cap, st, floor_z);
  // ★ REPORT THE PITCH THE WELD ACTUALLY USED, not the one asked for. organic_weld
  // COARSENS to fit max_voxels and says so in the stats; a tool that prints only the
  // requested pitch will quietly ship a surface far coarser than the caller believes.
  // Measured on c12: asking 0.30 mm produced 23,880 triangles where the strut surface
  // (13,591 mm^2) implies ~300,000 -- a 12x shortfall that is invisible unless the
  // effective pitch is printed.
  std::printf("welded: %zu triangles at pitch %.4f mm (asked %.4f), raster %dx%dx%d, "
              "%lld occupied, volume %.1f mm^3, watertight %s\n",
              mesh.triangles.size(), st.pitch_mm, pitch, st.nx, st.ny, st.nz,
              st.occupied_voxels, st.volume_mm3, st.watertight ? "yes" : "NO");
  if (st.pitch_mm > pitch * 1.01)
    std::printf("  NOTE: the weld COARSENED to %.4f mm to fit the %lld-voxel cap. "
                "Raise the cap for a finer surface.\n", st.pitch_mm, cap);
  // ★★ organic_weld IS THE SINGLE-BODY VERSION, AND ON A FRAGMENTED LATTICE THAT
  // DISCARDS MOST OF IT. Measured on c12, whose largest component is 4.14% of the
  // material: the raster occupied 126,700 voxels (3,421 mm^3, matching the 3,395 mm^3
  // the spans imply) but the mesh came back covering 40x16x31 mm of a 195x54x195 mm
  // lattice, 773 mm^2 of surface against the 13,591 mm^2 the struts have -- 5.7%,
  // which is the largest component and nothing else.
  //
  // That is the function behaving as documented, not a fault, and it is a useful
  // cross-check on the contiguity numbers. But a viewer fed this file sees ONE PIECE
  // and has no way to know the rest existed, so the discard is printed here. For a
  // fragmented lattice, read the fraction below before believing the picture.
  std::printf("  components: %d before weld, %d after, %d sealed cavities filled\n",
              st.components_before, st.components_after, st.sealed_cavities_filled);
  {
    double span_vol = 0.0;
    for (const OrganicSpan& s2 : spans) {
      const double dx = s2.b.x-s2.a.x, dy = s2.b.y-s2.a.y, dz = s2.b.z-s2.a.z;
      span_vol += 3.14159265358979 * s2.r * s2.r * std::sqrt(dx*dx+dy*dy+dz*dz);
    }
    const double occ_vol = double(st.occupied_voxels) * st.pitch_mm * st.pitch_mm * st.pitch_mm;
    std::printf("  spans imply %.0f mm^3; the raster occupied %.0f mm^3; "
                "the WRITTEN body is %.0f mm^3 (%.1f%% of the lattice)\n",
                span_vol, occ_vol, st.volume_mm3,
                span_vol > 0 ? 100.0 * st.volume_mm3 / span_vol : 0.0);
    if (span_vol > 0 && st.volume_mm3 < 0.9 * span_vol)
      std::printf("  ** THIS FILE IS NOT THE WHOLE LATTICE: organic_weld writes the "
                  "single connected body and drops the rest.\n");
  }
  if (mesh.triangles.empty()) { std::fprintf(stderr, "weld produced nothing\n"); return 3; }
  write_stl_file(out, mesh, StlFormat::Binary);
  std::printf("wrote %s\n", out.c_str());
  return 0;
}
