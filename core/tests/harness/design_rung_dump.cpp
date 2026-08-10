// design_rung_dump — S2's second arm needs HIS OWN converged design as a
// starting point, so it needs the rung densities out of a `design.bin` as plain
// numbers.
//
// WHY THERE IS A SECOND ARM. Running GridapTopOpt from a hole-seeded start costs
// ~5 minutes per ALM iteration on his 1,473,696-DOF grid (§S2.5), and an ALM
// needs hundreds of iterations to bring its volume constraint home. Four rungs
// of that do not fit in this task's budget, and an unconverged design sits at
// the wrong volume fraction, where a surface comparison means nothing.
//
// The SEQUENTIAL arm is both cheaper and the thing §S4c actually asks about:
// take his SIMP rung, hand its 0.5 level set to the level-set optimiser as φ0,
// and let it refine only the boundary. The topology is already his, the volume
// constraint starts satisfied, and what comes out isolates the ONE thing under
// test — whether a level-set boundary on his part is smoother than a
// density-thresholded one at the same volume fraction.
//
//   cmake --build build --target design_rung_dump
//   ./build/design_rung_dump <design.bin> <out_dir>
//
// Writes, per rung, `rung_<vf>.f64` (nx*ny*nz float64, x-fastest — the design
// lattice, NOT the shipped tricubic one) and `rung_<vf>.meta` naming the grid
// and the rung's own recorded numbers. Nothing is interpolated, thresholded or
// rescaled here: this is a format change and nothing else.

#include "topopt/design_store.hpp"
#include "topopt/mesh.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <cstdio>
#include <fstream>
#include <string>

using namespace topopt;

int main(int argc, char** argv) {
  if (argc < 3) {
    std::printf("usage: design_rung_dump <design.bin> <out_dir> [--stl]\n");
    return 2;
  }
  const std::string in = argv[1], out = argv[2];
  // --stl also writes each rung's SHIPPED extraction (tricubic x2, MC at 0.5,
  // largest component) as binary STL. S3 needs it: PicoGK's bounding object for
  // the lattice is the optimizer's design, and an STL is how the two systems
  // hand geometry to each other in practice.
  bool want_stl = false;
  for (int i = 3; i < argc; ++i)
    if (std::string(argv[i]) == "--stl") want_stl = true;
  DesignStore store = read_design_file(in);
  std::printf("== design_rung_dump ==\n\n%s\ngrid %d x %d x %d, spacing %.17g mm, "
              "origin (%.17g, %.17g, %.17g)\n%zu rungs\n\n",
              in.c_str(), store.nx, store.ny, store.nz, store.spacing,
              store.origin.x, store.origin.y, store.origin.z,
              store.variants.size());

  for (const StoredDesign& d : store.variants) {
    // std::string, not a fixed char buffer: an out_dir longer than the buffer
    // silently truncates the PATH, and `snprintf` reports success while the
    // write lands somewhere else entirely. This is not hypothetical — the first
    // run of this program wrote four files into a truncated directory name.
    char vf[32];
    std::snprintf(vf, sizeof vf, "%.2f", d.requested_volume_fraction);
    const std::string stem = out + "/rung_" + vf;
    const std::string f64 = stem + ".f64";
    const std::string met = stem + ".meta";
    if (d.density.size() != store.voxel_count()) {
      std::printf("FATAL: rung %.2f has %zu densities, grid has %zu voxels\n",
                  d.requested_volume_fraction, d.density.size(),
                  store.voxel_count());
      return 2;
    }
    std::ofstream b(f64, std::ios::binary);
    b.write(reinterpret_cast<const char*>(d.density.data()),
            static_cast<std::streamsize>(d.density.size() * sizeof(double)));
    if (!b) { std::printf("FATAL: could not write %s\n", f64.c_str()); return 2; }

    std::size_t above = 0;
    for (double v : d.density) above += (v > 0.5);

    std::ofstream m(met);
    m.precision(17);
    // ★ `rung` IS A LABEL AND MUST BE WRITTEN AS ONE — TWO DECIMALS, NOT THE
    // FULL DOUBLE (task 2026-08-10-plsm-production).
    //
    // `external_field_surface_probe` matches an arm's rung against the SIMP rows
    // it formats itself with "%.2f", AS A STRING. At precision(17) this line
    // spells 0.68 as "0.68000000000000005", which never matches — and the probe
    // does not fail, it prints "NO SIMP ROW AT THIS RUNG — not compared" and
    // carries on. The measurement is correct and simply never gets a baseline
    // beside it, which is the most expensive kind of silent no-op: a comparison
    // that looks like it ran.
    //
    // PR 324 hit this from the other side and fixed `levelset_probe`'s writer;
    // this writer still carried it, so anything chaining design_rung_dump into
    // that probe lost its baseline. `requested_vf` below keeps FULL precision —
    // it is the number, not the label.
    char rung_label[32];
    std::snprintf(rung_label, sizeof rung_label, "%.2f",
                  d.requested_volume_fraction);
    m << "rung " << rung_label << "\n"
      << "requested_vf " << d.requested_volume_fraction << "\n"
      << "achieved_vf " << d.achieved_volume_fraction << "\n"
      << "iterations " << d.iterations << "\n"
      << "accepted " << (d.accepted ? 1 : 0) << "\n"
      << "margin_worst_case " << d.margin_worst_case << "\n"
      << "margin_effective " << d.margin_effective << "\n"
      << "max_von_mises_mpa " << d.max_von_mises_mpa << "\n"
      << "nx " << store.nx << "\nny " << store.ny << "\nnz " << store.nz << "\n"
      << "spacing " << store.spacing << "\n"
      << "ox " << store.origin.x << "\noy " << store.origin.y
      << "\noz " << store.origin.z << "\n"
      << "iso 0.5\nfactor 2\ninterp tricubic\nlattice design\n"
      << "voxels_above_iso " << above << "\n";

    std::printf("rung %.2f  achieved %.6f  iters %d  accepted %d  "
                "voxels>0.5 %zu  -> %s\n",
                d.requested_volume_fraction, d.achieved_volume_fraction,
                d.iterations, d.accepted ? 1 : 0, above, f64.c_str());

    if (want_stl) {
      VoxelGrid g;
      g.nx = store.nx; g.ny = store.ny; g.nz = store.nz;
      g.spacing = store.spacing; g.origin = store.origin;
      const TriangleMesh mesh = keep_largest_component(marching_cubes_resampled(
          g.nx, g.ny, g.nz, g.spacing, g.origin, d.density, 0.5, 2,
          ResampleInterp::Tricubic));
      const std::string stl = stem + ".stl";
      write_stl_file(stl, mesh);
      std::printf("           %zu verts / %zu tris  -> %s\n",
                  mesh.vertices.size(), mesh.triangles.size(), stl.c_str());
      m << "verts " << mesh.vertices.size() << "\ntris "
        << mesh.triangles.size() << "\n";
    }
  }
  return 0;
}
