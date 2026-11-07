#include "topopt/lattice_algorithm.hpp"

#include <cstring>
#include <stdexcept>

namespace topopt {

// ── ★ WHICH CERTIFICATE RUNS (task 2026-09-28-lattice-types-core) ─────────────
// The decision lives here, not in an `if` inside run_job.cpp's anonymous namespace,
// because the app keys its Structural preview floor on it and because a key the schema
// accepts must name an instrument core actually uses.
LatticeCertificateKind lattice_certificate_kind(LatticeAlgorithm alg,
                                                bool any_step_plan) {
  switch (alg) {
    case LatticeAlgorithm::Organic:
      // Traced curves share no node grid at all: the tensor has never been offered.
      return LatticeCertificateKind::BeamNetwork;
    case LatticeAlgorithm::Stepped:
      // ANY-STEP ONLY. A plan interleaves families whose nodes do not line up, which
      // is exactly what the tensor cannot represent. Legacy Stepped -- one cell per
      // region, no plan -- keeps the tensor it has always used.
      return any_step_plan ? LatticeCertificateKind::BeamNetwork
                           : LatticeCertificateKind::HomogenisedTensor;
    case LatticeAlgorithm::Doubled:
      // The dyadic ladder keeps nodes SHARED by construction (cell_plan.hpp), so the
      // tensor's assumption holds and it stays.
      return LatticeCertificateKind::HomogenisedTensor;
  }
  throw std::logic_error("lattice_certificate_kind: unhandled LatticeAlgorithm");
}

std::vector<std::string> lattice_beam_network_certified_algorithms() {
  // Derived from the decision above rather than listed, so the two cannot drift.
  // `true` for the plan bit: an algorithm appears here if the beam network certifies
  // it in ANY configuration; `lattice_certificate_kind` answers the per-job question.
  std::vector<std::string> out;
  for (LatticeAlgorithm a : {LatticeAlgorithm::Doubled, LatticeAlgorithm::Stepped,
                             LatticeAlgorithm::Organic})
    if (lattice_certificate_kind(a, /*any_step_plan=*/true) ==
        LatticeCertificateKind::BeamNetwork)
      out.emplace_back(lattice_algorithm_name(a));
  return out;
}

const char* lattice_algorithm_name(LatticeAlgorithm a) {
  switch (a) {
    case LatticeAlgorithm::Doubled: return "doubled";
    case LatticeAlgorithm::Stepped: return "stepped";
    case LatticeAlgorithm::Organic: return "organic";
  }
  // NEVER a silent fallback: a new case must be named above before a job or a receipt
  // can carry it.
  throw std::logic_error("lattice_algorithm_name: unnamed LatticeAlgorithm");
}

bool lattice_algorithm_from_name(const char* name, LatticeAlgorithm& out) {
  if (!name) return false;
  if (std::strcmp(name, "doubled") == 0) { out = LatticeAlgorithm::Doubled; return true; }
  if (std::strcmp(name, "stepped") == 0) { out = LatticeAlgorithm::Stepped; return true; }
  if (std::strcmp(name, "organic") == 0) { out = LatticeAlgorithm::Organic; return true; }
  return false;
}

std::vector<std::string> lattice_algorithm_names() {
  return {"doubled", "stepped", "organic"};
}

}  // namespace topopt
