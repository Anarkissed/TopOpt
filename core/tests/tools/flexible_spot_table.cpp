// Evidence tool, task 2026-09-28-flexible-squish-maths: print a Markdown table of
// core's squish lookup against Iacob et al. 2024 Table 2 (typed from the paper,
// papers/1-s2.0-S0142941824001946-main.pdf), for every row and both strains.
//
//   flexible_spot_table <flexible_materials.json>
//
// Built on request only (EXCLUDE_FROM_ALL). test_flexible_squish asserts the same
// agreement; this prints it for the handoff.

#include <algorithm>
#include <cmath>
#include <cstdio>

#include "topopt/flexible/squish.hpp"

using namespace topopt::flexible;

struct Row { int temp; int infill; double g10, g20, h10, h20; };
static const Row kTable2[] = {
    {190, 10, 0.42, 0.27, 1.65, 1.28}, {190, 15, 1.19, 0.71, 4.06, 3.26},
    {190, 20, 2.19, 1.46, 5.95, 5.79}, {190, 25, 3.2, 2.57, 6.87, 7.14},
    {190, 30, 4.35, 3.91, 8.18, 8.54}, {190, 35, 5.17, 4.88, 8.56, 9.08},
    {220, 10, 0.2, 0.14, 0.64, 0.54},  {220, 15, 0.43, 0.31, 1.47, 1.59},
    {220, 20, 0.77, 0.59, 1.62, 1.79}, {220, 25, 1.13, 0.97, 1.96, 2.26},
    {220, 30, 1.45, 1.33, 2.38, 2.76}, {220, 35, 1.68, 1.59, 2.6, 3.02},
    {240, 10, 0.18, 0.14, 0.74, 0.69}, {240, 15, 0.51, 0.4, 1.36, 1.46},
    {240, 20, 0.84, 0.75, 1.7, 1.84},  {240, 25, 1.19, 1.11, 2.25, 2.42},
    {240, 30, 1.47, 1.41, 2.82, 3.0},  {240, 35, 1.82, 1.75, 2.94, 3.19},
};

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <flexible_materials.json>\n", argv[0]);
    return 2;
  }
  const FlexibleData d = load_flexible_data(argv[1]);
  std::printf("Core looked up at core strain = nominal x 12.5 / (12.5 - 1.6): 0.1147 and 0.2294.\n\n");
  std::printf("| T (°C) | pattern | nominal | core ρ (%s) | Iacob E10 | σ(0.10) paper | σ(0.1147 core) core | "
              "Iacob E20 | σ(0.20) paper | σ(0.2294 core) core | max rel. diff |\n",
              "190 °C map");
  std::printf("|---|---|---|---|---|---|---|---|---|---|---|\n");
  double worst = 0.0;
  for (const Row& r : kTable2)
    for (int t = 0; t < 2; ++t) {
      const char* topo = t == 0 ? "gyroid" : "honeycomb";
      const CurveSet s = curve_set(d, "varioshore_tpu", r.temp, topo).set;
      const CurveRow* row = nullptr;
      for (const CurveRow& x : s.rows)
        if (std::fabs(x.nominal - r.infill / 100.0) < 1e-12) row = &x;
      const double e10 = t == 0 ? r.g10 : r.h10, e20 = t == 0 ? r.g20 : r.h20;
      // The loader works in CORE strain: nominal ε × 12.5 / (12.5 − 1.6).
      const double k = 12.5 / (12.5 - 1.6);
      const double a = stress_at(s, 0.10 * k, row->core_density).stress_mpa;
      const double b = stress_at(s, 0.20 * k, row->core_density).stress_mpa;
      const double diff = std::max(std::fabs(a - 0.1 * e10) / (0.1 * e10), std::fabs(b - 0.2 * e20) / (0.2 * e20));
      worst = std::max(worst, diff);
      std::printf("| %d | %s | %d %% | %.3f | %.2f | %.4f | %.4f | %.2f | %.4f | %.4f | %.1e |\n", r.temp, topo,
                  r.infill, row->core_density, e10, 0.1 * e10, a, e20, 0.2 * e20, b, diff);
    }
  std::printf("\nworst relative difference over 72 values: %.2e\n", worst);
  return worst <= 1e-9 ? 0 : 1;
}
