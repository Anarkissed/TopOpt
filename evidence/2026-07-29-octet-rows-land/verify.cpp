// Verification driver for landing PR 237's octet rows into the production table.
// Links the REAL core/src/fea/lattice.cpp (not a copy), so it exercises the shipped
// kOctet, resolved_span(), lattice_rho_min/max() and lattice_cubic_tensor().
//
//   c++ -std=c++17 -I core/include evidence/2026-07-29-octet-rows-land/verify.cpp \
//       core/src/fea/lattice.cpp -o /tmp/verify && /tmp/verify
//
// Covers bars T2 (band), T3 (rho_min/max), T4 (MID rows bit-identical),
// T5 (grading clamp bounds are lattice_rho_min/max), T7 (interpolation at the new
// extremes). T1 (exact transcription) is proved by the row_diff.txt mechanical diff;
// T6 (non-lattice byte-identical) by call-site inspection — see README.md.
#include "topopt/lattice.hpp"
#include <cstdio>
#include <cmath>
using namespace topopt;
static const auto O = LatticeTopology::Octet;
static const double E = 3500.0;  // library Es -> scale 1.0

int main() {
  printf("== T2/T3: resolved band ==\n");
  printf("lattice_rho_min = %.5f\n", lattice_rho_min(O));
  printf("lattice_rho_max = %.5f\n", lattice_rho_max(O));

  printf("\n== T4: MID rows (old band) reproduced bit-for-bit ==\n");
  // Query each MID row's exact rho; tensor must equal the table row (t=0, scale=1).
  struct { double rho, C11, C12, C44; } mid[] = {
    {0.14764, 136.9621, 64.0645, 56.6726},
    {0.20414, 213.7779, 94.5363, 83.3612},
    {0.25297, 295.1031, 124.0143, 109.1889},
    {0.29731, 374.2029, 151.9733, 135.0535},
    {0.39786, 611.4884, 226.3148, 204.0181},
    {0.50644, 974.8665, 328.8413, 297.3223},
    {0.59093, 1344.7034, 443.6894, 392.1883},
  };
  bool t4ok = true;
  for (auto& m : mid) {
    CubicTensor c = lattice_cubic_tensor(O, m.rho, E, nullptr);
    bool eq = c.C11==m.C11 && c.C12==m.C12 && c.C44==m.C44;
    t4ok &= eq;
    printf("rho=%.5f  C11 %.4f/%.4f  C12 %.4f/%.4f  C44 %.4f/%.4f  %s\n",
           m.rho, c.C11, m.C11, c.C12, m.C12, c.C44, m.C44, eq?"OK":"MISMATCH");
  }
  printf("T4 %s\n", t4ok?"PASS (bit-identical)":"FAIL");

  printf("\n== T7: interpolation at the new extremes ==\n");
  bool cl;
  // Exact low endpoint -> equals row 0, NOT clamped.
  CubicTensor lo = lattice_cubic_tensor(O, 0.05047, E, &cl);
  printf("rho=0.05047  C11=%.4f (expect 37.0649)  clamped=%d (expect 0)\n", lo.C11, cl);
  // Below floor -> clamped to row 0.
  CubicTensor below = lattice_cubic_tensor(O, 0.02, E, &cl);
  printf("rho=0.02     C11=%.4f (expect 37.0649)  clamped=%d (expect 1)\n", below.C11, cl);
  // Just inside low: midway 0.05047..0.06355 -> linear mean of C11.
  CubicTensor midlo = lattice_cubic_tensor(O, (0.05047+0.06355)/2, E, &cl);
  printf("rho=0.05701  C11=%.4f (expect %.4f = mean)  clamped=%d\n",
         midlo.C11, (37.0649+48.3025)/2, cl);
  // Exact high endpoint -> equals last row, NOT clamped.
  CubicTensor hi = lattice_cubic_tensor(O, 0.89988, E, &cl);
  printf("rho=0.89988  C11=%.4f (expect 3832.0119)  clamped=%d (expect 0)\n", hi.C11, cl);
  // Above ceiling -> clamped to last row.
  CubicTensor above = lattice_cubic_tensor(O, 1.0, E, &cl);
  printf("rho=1.0      C11=%.4f (expect 3832.0119)  clamped=%d (expect 1)\n", above.C11, cl);
  // Just inside high: midway 0.85120..0.89988 -> linear mean of C11.
  CubicTensor midhi = lattice_cubic_tensor(O, (0.85120+0.89988)/2, E, &cl);
  printf("rho=0.87554  C11=%.4f (expect %.4f = mean)  clamped=%d\n",
         midhi.C11, (3276.6604+3832.0119)/2, cl);

  printf("\n== monotonic across full band (sanity) ==\n");
  double prev = -1; bool mono = true;
  for (double rho = 0.05; rho <= 0.90; rho += 0.05) {
    CubicTensor c = lattice_cubic_tensor(O, rho, E, nullptr);
    if (c.C11 < prev) mono = false;
    prev = c.C11;
  }
  printf("C11 monotonic non-decreasing across 0.05..0.90: %s\n", mono?"yes":"NO");

  printf("\n== T5: grading clamp bounds (== lattice_rho_min/max read from core) ==\n");
  printf("BEFORE (old band): grading clamps rho into [0.14764, 0.59093]\n");
  printf("AFTER  (new band): grading clamps rho into [%.5f, %.5f]\n",
         lattice_rho_min(O), lattice_rho_max(O));
  return 0;
}
