// S1 — WHICH MESH PRODUCERS ARE WOUND WHICH WAY, measured not read.
#include <cstdio>
#include <vector>
#include "topopt/mesh.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/voxel.hpp"
#include "topopt/stl.hpp"
#include <string>
#include <cmath>
using namespace topopt;

static void report(const char* name, const TriangleMesh& m, double expect_vol) {
  const double v = signed_volume(m);
  std::printf("  %-46s tris %8zu  signed_volume %+14.4f  -> %s",
              name, m.triangles.size(), v, v < 0 ? "INWARD" : "outward");
  if (expect_vol > 0)
    std::printf("   (|v| vs expected %.4f: %+.4f)", expect_vol, std::abs(v) - expect_vol);
  std::printf("\n");
}

int main(int argc, char** argv) {
  std::printf("S1 — mesh producer winding (signed_volume < 0 == INWARD by the STL convention)\n\n");

  // 1. marching_cubes over a solid block: 4x4x4 voxels of 1 mm at centres 3.5..6.5
  VoxelGrid g; g.nx=g.ny=g.nz=10; g.spacing=1.0; g.origin={0,0,0};
  g.tags.assign(1000, VoxelTag::Empty);
  std::vector<double> d(1000, 0.0);
  for (int k=3;k<=6;++k) for (int j=3;j<=6;++j) for (int i=3;i<=6;++i) {
    g.tags[g.index(i,j,k)] = VoxelTag::Interior; d[g.index(i,j,k)] = 1.0; }
  const TriangleMesh mc = marching_cubes(g, d, 0.5);
  report("marching_cubes(block)", mc, 0);
  report("keep_largest_component(marching_cubes)", keep_largest_component(mc), 0);
  const TriangleMesh mcr = marching_cubes_resampled(g.nx,g.ny,g.nz,g.spacing,g.origin,d,0.5,2,ResampleInterp::Tricubic);
  report("marching_cubes_resampled(factor 2, tricubic)", mcr, 0);

  // 2. the LATTICE generator's own primitives: one strut + one node in a 1-cell region
  {
    LatticeRegion R; R.origin={0,0,0}; R.nx=R.ny=R.nz=1; R.cell_mm=10.0; R.boundary=nullptr;
    LatticeRadiusField G; G.uniform_mm=1.0; G.nseg=8;
    LatticeSkinSpec skin; skin.mode=LatticeSkinMode::None;
    MeshSink sink;
    const LatticeGenStats st = generate_lattice(LatticeGenTopology::Octet, R, G, sink, skin);
    // MeshSink is an unshared soup; weld by coordinate for a meaningful volume.
    std::printf("  %-46s tris %8zu  signed_volume %+14.4f  -> %s   (struts %llu nodes %llu)\n",
                "generate_lattice(octet, 1 cell) [soup]", sink.mesh.triangles.size(),
                signed_volume(sink.mesh), signed_volume(sink.mesh) < 0 ? "INWARD" : "outward",
                (unsigned long long)st.struts, (unsigned long long)st.nodes);
  }

  // 3. an STL round trip: what the WRITER emits and the READER reads back.
  {
    const std::string path = std::string(argc>1?argv[1]:"/tmp/_w.stl");
    write_stl_file(path, mc);
    const StlMesh back = read_stl_file(path);
    report("  marching_cubes -> write_stl_file -> read_stl_file", back.mesh, 0);
  }
  return 0;
}
