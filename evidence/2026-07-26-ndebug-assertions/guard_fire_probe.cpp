// Standalone reproduction of the draft-quality parity guard from
// core/src/simp/simp.cpp:1798 (verbatim predicate shape + message), compiled
// with the topopt target's own NDEBUG flags to demonstrate assert liveness.
// A "draft" run is simulated where the certification tolerance has been
// loosened away from the tight trajectory floor — the exact situation the
// guard exists to abort. main() reaching "certified" means the guard was dead.
#include <cassert>
#include <cstdio>
int main() {
  const double tight_floor   = 1e-8;  // trajectory schedule's tight floor
  double certification_tol   = 1e-6;  // LOOSENED — violates the parity invariant
  assert(certification_tol == tight_floor &&
         "draft quality: certification tolerance must be the tight floor of the "
         "trajectory schedule");
  std::printf("REACHED: certified on tol=%g (guard was DEAD)\n", certification_tol);
  return 0;
}
