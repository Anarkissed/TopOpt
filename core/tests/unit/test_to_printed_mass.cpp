// TO rebuild stage 2: printed grams at the user's walls and infill (printed_mass.hpp).
#include <cmath>
#include <cstdio>
#include <vector>

#include <array>

#include "topopt/printed_mass.hpp"
#include "topopt/stress_measure.hpp"

static int g_fail = 0;
#define CHECK(c) do { if (!(c)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #c); } } while (0)

int main() {
  using namespace topopt;
  VoxelGrid g;
  g.nx = g.ny = g.nz = 10;
  g.spacing = 2.0;  // a 20 mm cube = 8 cm3
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(1000, VoxelTag::Interior);
  const std::vector<double> full(1000, 1.0);
  const double rho = 1.24, solid = 8.0 * rho;

  // Infill 100 %: the solid mass exactly, whatever the walls or widths.
  const PrintedMass a = printed_mass(g, full, 0.5, std::vector<double>(1000, 6.0), 0.9, 100.0, rho);
  CHECK(std::fabs(a.grams - solid) < 1e-9 && std::fabs(a.solid_grams - solid) < 1e-9);

  // A wide body (width not measurable) at 20 %: no wall share, a fifth of the solid.
  const PrintedMass b = printed_mass(g, full, 0.5, std::vector<double>(1000, 0.0), 0.9, 20.0, rho);
  CHECK(std::fabs(b.grams - 0.2 * solid) < 1e-9 && b.wall_share == 0.0);

  // Members thinner than two walls are all wall: solid, whatever the infill.
  const PrintedMass c = printed_mass(g, full, 0.5, std::vector<double>(1000, 1.6), 0.9, 15.0, rho);
  CHECK(std::fabs(c.grams - solid) < 1e-9 && std::fabs(c.wall_share - 1.0) < 1e-12);

  // A 6 mm member with a 0.9 mm ring: wall share 4 t (W - t) / W^2 = 0.51.
  const PrintedMass d = printed_mass(g, full, 0.5, std::vector<double>(1000, 6.0), 0.9, 20.0, rho);
  const double fw = 4.0 * 0.9 * (6.0 - 0.9) / 36.0;
  CHECK(std::fabs(d.wall_share - fw) < 1e-12);
  CHECK(std::fabs(d.grams - solid * (fw + (1.0 - fw) * 0.2)) < 1e-9);
  CHECK(d.grams > b.grams && d.grams < a.grams);

  // Voxels under the printed threshold count for nothing; a cut voxel counts by its fill.
  std::vector<double> half(1000, 0.0);
  for (int i = 0; i < 500; ++i) half[static_cast<std::size_t>(i)] = 1.0;
  half[500] = 0.6;
  half[501] = 0.4;  // not printed
  const PrintedMass e = printed_mass(g, half, 0.5, std::vector<double>(1000, 0.0), 0.9, 100.0, rho);
  CHECK(std::fabs(e.grams - (500.6 * 8.0 * 1e-3) * rho) < 1e-9);

  // Never more than the solid, never negative, monotone in infill.
  double last = 0.0;
  for (double infill : {0.0, 10.0, 35.0, 70.0, 100.0}) {
    const PrintedMass m = printed_mass(g, full, 0.5, std::vector<double>(1000, 6.0), 0.9, infill, rho);
    CHECK(m.grams >= last - 1e-12 && m.grams <= m.solid_grams + 1e-12);
    last = m.grams;
  }
  // The shell model. A 20 mm cube: infill 100 gives the solid mass; with a 2 mm
  // wall and no skins the core is a 16 x 16 mm column through the height, so the
  // printed share at 0 % infill is 1 - 16 * 16 / 400 = 0.36; with 2 mm skins too
  // the core is a 16 mm cube, share 1 - 16^3 / 8000 = 0.488.
  {
    const PrintedMass full100 = printed_mass_shell(g, full, 0.5, 2.0, 2.0, 2.0, 100.0, rho);
    CHECK(std::fabs(full100.grams - solid) < 1e-9);
    const PrintedMass walls = printed_mass_shell(g, full, 0.5, 2.0, 0.0, 0.0, 0.0, rho);
    CHECK(std::fabs(walls.grams / solid - 0.36) < 1e-9);
    const PrintedMass skins = printed_mass_shell(g, full, 0.5, 2.0, 2.0, 2.0, 0.0, rho);
    CHECK(std::fabs(skins.grams / solid - 0.488) < 1e-9);
    const PrintedMass half = printed_mass_shell(g, full, 0.5, 2.0, 2.0, 2.0, 50.0, rho);
    CHECK(std::fabs(half.grams / solid - (0.488 + 0.512 * 0.5)) < 1e-9);
    std::printf("[printed mass, shell] cube: walls only %.3f, walls and skins %.3f of solid\n",
                walls.grams / solid, skins.grams / solid);
  }

  // The across-layer tension per voxel (stress_measure.hpp): n . sigma . n, tension
  // only, zero outside the part; and read over a size it averages like any field.
  {
    std::vector<std::array<double, 6>> stress(1000, std::array<double, 6>{0, 0, 5.0, 0, 0, 0});
    stress[0] = {0, 0, -7.0, 0, 0, 0};  // compression across the layers does not count
    VoxelGrid gp = g;
    gp.tags[1] = VoxelTag::Empty;
    const std::vector<double> tz = interlayer_tension_field(gp, stress, Vec3{0, 0, 2.0});
    CHECK(tz[0] == 0.0 && tz[1] == 0.0 && std::fabs(tz[2] - 5.0) < 1e-12);
    const std::vector<double> tx = interlayer_tension_field(gp, stress, Vec3{1.0, 0, 0});
    CHECK(tx[2] == 0.0);
    // 45 degrees between z and x: n . sigma . n = 0.5 * szz.
    const std::vector<double> td = interlayer_tension_field(gp, stress, Vec3{1.0, 0, 1.0});
    CHECK(std::fabs(td[2] - 2.5) < 1e-12);
    // One hot voxel in a field of 5: its reading over 6 mm (three voxels) falls
    // toward the 5 around it; over nothing it is itself.
    std::vector<double> f(1000, 5.0);
    f[555] = 50.0;
    CHECK(peak_stress_over_size(g, f, full, 0.5, 0.0) == 50.0);
    const double over = peak_stress_over_size(g, f, full, 0.5, 6.0);
    CHECK(over > 5.0 && over < 15.0);
    std::printf("[across layers] one 50 in a field of 5 reads %.2f over 6 mm\n", over);
  }

  std::printf("[printed mass] solid %.3f g; 6 mm members at 20 %% infill %.3f g; wide body at 20 %% %.3f g; %d failure(s)\n",
              solid, d.grams, b.grams, g_fail);
  return g_fail == 0 ? 0 : 1;
}
