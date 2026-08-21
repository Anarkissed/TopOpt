#include "topopt/lattice_algorithm.hpp"

#include <cstring>
#include <stdexcept>

namespace topopt {

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
