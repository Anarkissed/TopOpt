#include "topopt/lattice_lslt.hpp"
#include "topopt/lattice_union_volume.hpp"
#include "topopt/lattice_dc.hpp"
#include <cstdio>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include "topopt/mesh.hpp"
#include "topopt/stl.hpp"
using namespace topopt;
static void run(const char* name, const std::vector<OrganicSpan>& sp) {
  LsltOptions o; LsltStats st;
  TriangleMesh m = lattice_lslt(sp, o, st);
  std::printf("%-22s beams %3zu nodes %3zu N=%2d tris %6zu pushed %5zu holes %3zu "
              "boundary %zu watertight %s vol %.4f\n",
              name, st.beams, st.nodes, st.section_vertices, st.triangles,
              st.vertices_pushed, st.holes_filled, st.boundary_edges_left,
              st.watertight ? "YES" : "NO", st.volume_mm3);
}
static void vol_case(const char* name, const std::vector<OrganicSpan>& sp, double exact) {
  LatticeUnionVolume v = lattice_union_volume(sp, 400000);
  const double err = exact > 0 ? 100.0 * (v.volume_mm3 - exact) / exact : 0.0;
  std::printf("%-34s V = %10.4f +/- %.4f   exact %10.4f   %+6.3f %%   naive %10.4f (%.1f %% overlap)\n",
              name, v.volume_mm3, v.std_error_mm3, exact, err, v.naive_sum_mm3,
              100.0 * v.overlap_fraction);
}

int main(int argc, char** argv) {
  if (argc > 2 && std::strcmp(argv[1], "--overlap-vs-k") == 0) {
    std::vector<OrganicSpan> sp;
    std::ifstream f(argv[2]); std::string line;
    while (std::getline(f, line)) {
      if (line.rfind("SEG", 0) != 0) continue;
      std::istringstream is(line.substr(3));
      OrganicSpan s2;
      is >> s2.a.x >> s2.a.y >> s2.a.z >> s2.b.x >> s2.b.y >> s2.b.z >> s2.r;
      sp.push_back(s2);
    }
    std::printf("     k      union mm3     naive mm3   overlap %%\n");
    for (double k : {0.6, 0.8, 1.0, 1.2, 1.4}) {
      std::vector<OrganicSpan> q = sp;
      for (OrganicSpan& x : q) x.r *= k;
      LatticeUnionVolume v = lattice_union_volume(q, 2000000);
      std::printf("  %.2f   %10.1f    %10.1f   %8.2f\n",
                  k, v.volume_mm3, v.naive_sum_mm3, 100.0 * v.overlap_fraction);
    }
    return 0;
  }
  if (argc > 2 && std::strcmp(argv[1], "--dc") == 0) {
    // --dc <spans> [--uniform] [--tol T] <h> [h ...]
    std::vector<OrganicSpan> sp;
    std::ifstream f(argv[2]); std::string line;
    while (std::getline(f, line)) {
      if (line.rfind("SEG", 0) != 0) continue;
      std::istringstream is(line.substr(3));
      OrganicSpan s2;
      is >> s2.a.x >> s2.a.y >> s2.a.z >> s2.b.x >> s2.b.y >> s2.b.z >> s2.r;
      sp.push_back(s2);
    }
    const LatticeUnionVolume u = lattice_union_volume(sp, 8000000);
    std::printf("union volume %.1f +/- %.1f mm3 (the target this must reproduce)\n",
                u.volume_mm3, u.std_error_mm3);
    bool adaptive = true; double tol = 0.0; bool write = true;
    double mult = 8.0;
    for (int ai = 3; ai < argc; ++ai) {
      if (std::strcmp(argv[ai], "--uniform") == 0) { adaptive = false; continue; }
      if (std::strcmp(argv[ai], "--no-write") == 0) { write = false; continue; }
      if (std::strcmp(argv[ai], "--no-merge") == 0) { mult = 1.0; continue; }
      if (std::strcmp(argv[ai], "--mult") == 0 && ai + 1 < argc) { mult = std::atof(argv[++ai]); continue; }
      if (std::strcmp(argv[ai], "--tol") == 0 && ai + 1 < argc) { tol = std::atof(argv[++ai]); continue; }
      LatticeDcOptions o;
      o.cell_mm = std::atof(argv[ai]); o.adaptive = adaptive; o.simplify_tolerance_mm = tol;
      o.max_leaf_multiple = mult;
      LatticeDcStats st;
      TriangleMesh m = lattice_dual_contour(sp, o, st);
      std::printf("  %-7s h=%.3f tol=%.4f x%.0f  leaf %.3f-%.3f  visited %9zu act %8zu "
                  "split %5zu merged %7zu\n",
                  adaptive ? "octree" : "uniform", st.cell_mm, st.simplify_tolerance_mm, mult,
                  st.finest_leaf_mm, st.coarsest_leaf_mm, st.cells_visited,
                  st.cells_active, st.cells_split, st.cells_merged);
      std::printf("           tris %9zu (%.0f MB stl)  bnd %6zu  nonmf %6zu  drop %6zu  "
                  "%-9s  V %9.1f  %+6.2f %%  %6.1f s\n",
                  st.triangles, st.triangles * 50.0 / 1048576.0,
                  st.boundary_edges, st.nonmanifold_edges, st.quads_dropped,
                  st.manifold ? "MANIFOLD" : (st.watertight ? "closed" : "OPEN"),
                  st.volume_mm3, 100.0*(st.volume_mm3-u.volume_mm3)/u.volume_mm3, st.seconds);
      if (write) {
        char out[512];
        std::snprintf(out, sizeof out, "DC_%s_%.3f_%.4f.stl",
                      adaptive ? "oct" : "uni", st.cell_mm, st.simplify_tolerance_mm);
        write_stl_file(out, m);
      }
    }
    return 0;
  }
  if (argc > 1 && std::strcmp(argv[1], "--dc-controls") == 0) {
    auto run = [](const char* name, const std::vector<OrganicSpan>& sp, double h, bool adaptive) {
      LatticeDcOptions o; o.cell_mm = h; o.adaptive = adaptive; LatticeDcStats st;
      TriangleMesh m = lattice_dual_contour(sp, o, st);
      const LatticeUnionVolume u = lattice_union_volume(sp, 2000000);
      std::printf("%-22s %-8s h=%.3f  leaf %.3f-%.3f  act %7zu  tris %7zu  "
                  "bnd %5zu nonmf %5zu drop %4zu %-9s  V %9.4f vs %9.4f  %+6.2f %%\n",
                  name, adaptive ? "octree" : "uniform", st.cell_mm,
                  st.finest_leaf_mm, st.coarsest_leaf_mm, st.cells_active, st.triangles,
                  st.boundary_edges, st.nonmanifold_edges, st.quads_dropped,
                  st.manifold ? "MANIFOLD" : (st.watertight ? "closed" : "OPEN"),
                  st.volume_mm3, u.volume_mm3,
                  u.volume_mm3 > 0 ? 100.0*(st.volume_mm3-u.volume_mm3)/u.volume_mm3 : 0.0);
    };
    const std::vector<OrganicSpan> one = {{{0,0,0},{10,0,0},1.0}};
    const std::vector<OrganicSpan> cross = {{{-5,0,0},{5,0,0},1.0},{{0,-5,0},{0,5,0},1.0}};
    const std::vector<OrganicSpan> star = {{{0,0,0},{5,0,0},1.0},{{0,0,0},{-5,0,0},0.7},
                                           {{0,0,0},{0,5,0},1.0},{{0,0,0},{0,0,5},0.5},
                                           {{0,0,0},{3,3,3},0.8}};
    for (bool ad : {false, true}) {
      for (double h : {0.5, 0.25, 0.125}) run("one capsule", one, h, ad);
      for (double h : {0.5, 0.25, 0.125}) run("perpendicular cross", cross, h, ad);
      for (double h : {0.5, 0.25, 0.125}) run("5-way, mixed radii", star, h, ad);
    }
    return 0;
  }
  if (argc > 1 && std::strcmp(argv[1], "--volume-controls") == 0) {
    const double r = 1.0;
    const double ball = (4.0 / 3.0) * M_PI * r * r * r;
    vol_case("one capsule, L=10 r=1", {{{0,0,0},{10,0,0},1.0}}, M_PI*r*r*10.0 + ball);
    vol_case("the same capsule TWICE (all overlap)",
             {{{0,0,0},{10,0,0},1.0},{{0,0,0},{10,0,0},1.0}}, M_PI*r*r*10.0 + ball);
    vol_case("two collinear halves = one capsule",
             {{{0,0,0},{5,0,0},1.0},{{5,0,0},{10,0,0},1.0}}, M_PI*r*r*10.0 + ball);
    vol_case("two capsules far apart (no overlap)",
             {{{0,0,0},{10,0,0},1.0},{{0,50,0},{10,50,0},1.0}},
             2.0*(M_PI*r*r*10.0 + ball));
    return 0;
  }
  if (argc > 1) {   // run on a real SPANS file: lslt_probe <spans.txt> [out.stl] [chord]
    std::vector<OrganicSpan> sp;
    std::ifstream f(argv[1]);
    std::string line;
    while (std::getline(f, line)) {
      if (line.rfind("SEG", 0) != 0) continue;
      std::istringstream is(line.substr(3));
      OrganicSpan s2; 
      is >> s2.a.x >> s2.a.y >> s2.a.z >> s2.b.x >> s2.b.y >> s2.b.z >> s2.r;
      sp.push_back(s2);
    }
    LsltOptions o; LsltStats st;
    if (argc > 3) o.chord_error_ratio = std::atof(argv[3]);
    TriangleMesh m = lattice_lslt(sp, o, st);
    std::printf("spans %zu -> beams %zu nodes %zu sections %zu (max valence %d)\n",
                sp.size(), st.beams, st.nodes, st.sections, st.max_valence);
    std::printf("  N=%d at %.0f%% chord error | triangles %zu (%zu from hole fills)\n",
                st.section_vertices, 100*o.chord_error_ratio, st.triangles, st.hole_triangles);
    std::printf("  pushed %zu | holes filled %zu | boundary edges %zu | WATERTIGHT %s\n",
                st.vertices_pushed, st.holes_filled, st.boundary_edges_left,
                st.watertight ? "YES" : "NO");
    std::printf("  enclosed volume %.1f mm3\n", st.volume_mm3);
    if (argc > 2 && std::strcmp(argv[2], "-") != 0) {
      write_stl_file(argv[2], m); std::printf("  wrote %s\n", argv[2]);
    }
    for (std::size_t budget : {std::size_t(1000000), std::size_t(4000000), std::size_t(16000000)}) {
      LatticeUnionVolume v = lattice_union_volume(sp, budget);
      std::printf("  UNION VOLUME %10.1f +/- %.1f mm3 (%zu samples, %.1f %% of the naive "
                  "%.0f was overlap)\n",
                  v.volume_mm3, v.std_error_mm3, v.samples, 100.0 * v.overlap_fraction,
                  v.naive_sum_mm3);
    }
    return 0;
  }
  run("single beam", {{{0,0,0},{10,0,0},1.0}});
  run("straight pair", {{{0,0,0},{5,0,0},1.0},{{5,0,0},{10,0,0},1.0}});
  run("L (90 deg)", {{{0,0,0},{5,0,0},1.0},{{5,0,0},{5,5,0},1.0}});
  run("tee", {{{0,0,0},{5,0,0},1.0},{{5,0,0},{10,0,0},1.0},{{5,0,0},{5,5,0},1.0}});
  run("cross (4)", {{{5,0,0},{0,0,0},1.0},{{5,0,0},{10,0,0},1.0},
                    {{5,0,0},{5,5,0},1.0},{{5,0,0},{5,-5,0},1.0}});
  run("unequal radii", {{{0,0,0},{5,0,0},1.0},{{5,0,0},{10,0,0},0.5}});
  // an exact reference: one beam, volume should be near cylinder + two cone caps
  {
    LsltOptions o; LsltStats st;
    TriangleMesh m = lattice_lslt({{{0,0,0},{10,0,0},1.0}}, o, st);
    const double prism = 0.5 * st.section_vertices * std::sin(2*M_PI/st.section_vertices) * 10.0;
    std::printf("  single beam: mesh vol %.4f, inscribed prism %.4f, true cylinder %.4f\n",
                st.volume_mm3, prism, M_PI*10.0);
  }
  return 0;
}
