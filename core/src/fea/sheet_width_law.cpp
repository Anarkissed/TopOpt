#include "topopt/sheet_width_law.hpp"

#include <algorithm>
#include <stdexcept>
#include <string>

namespace topopt {

namespace {

// One strength row: a width, a density, the four coefficients (strut_law_at's).
struct WidthLawRow {
  int n;
  double rho, Kd, Kv, Kild, Kilv;
};
// One bending row: a width, the cell's measured density, the error (fraction).
struct BendRow {
  int n;
  double rho, err;
};

// The measured tables, GENERATED from the evidence CSVs (never typed): see the file's head.
#include "sheet_width_law_tables.inc"

struct Tables {
  const WidthLawRow* law = nullptr;
  int nlaw = 0;
  const BendRow* bend = nullptr;
  int nbend = 0;
  int floor = 0;
  bool envelope_passes = false;
};

Tables tables(LatticeTopology topo) {
  switch (topo) {
    case LatticeTopology::Gyroid:
      return {kGyroidWidthLaw, int(sizeof kGyroidWidthLaw / sizeof kGyroidWidthLaw[0]),
              kGyroidBend, int(sizeof kGyroidBend / sizeof kGyroidBend[0]), kGyroidFloor,
              kGyroidEnvelopeLawPasses};
    case LatticeTopology::SchwarzD:
      return {kSchwarzDWidthLaw, int(sizeof kSchwarzDWidthLaw / sizeof kSchwarzDWidthLaw[0]),
              kSchwarzDBend, int(sizeof kSchwarzDBend / sizeof kSchwarzDBend[0]), kSchwarzDFloor,
              kSchwarzDEnvelopeLawPasses};
    default:
      return {};
  }
}

Tables tables_or_throw(LatticeTopology topo, const char* who) {
  const Tables t = tables(topo);
  if (!t.law)
    throw std::invalid_argument(std::string(who) + ": \"" + lattice_topology_name(topo) +
                                "\" has no per-width sheet law");
  return t;
}

// The widest measured width (in `rows`, member n) not above `cells_across`; throws under the
// narrowest.
template <class Row>
int width_row(const Row* rows, int n, int cells_across, const char* who) {
  int best = -1;
  for (int i = 0; i < n; ++i)
    if (rows[i].n <= cells_across && rows[i].n > best) best = rows[i].n;
  if (best < 0)
    throw std::invalid_argument(std::string(who) + ": a member " + std::to_string(cells_across) +
                                " cells across is under the narrowest measured width");
  return best;
}

}  // namespace

bool sheet_width_law_measured(LatticeTopology topo) { return tables(topo).law != nullptr; }

std::vector<int> sheet_width_law_widths(LatticeTopology topo) {
  const Tables t = tables_or_throw(topo, "sheet_width_law_widths");
  std::vector<int> out;
  for (int i = 0; i < t.nlaw; ++i)
    if (std::find(out.begin(), out.end(), t.law[i].n) == out.end()) out.push_back(t.law[i].n);
  std::sort(out.begin(), out.end());
  return out;
}

int sheet_width_floor_measured(LatticeTopology topo) {
  return tables_or_throw(topo, "sheet_width_floor_measured").floor;
}

StrutLawK sheet_strut_law_at(LatticeTopology topo, int cells_across, double rho, bool* clamped) {
  const Tables t = tables_or_throw(topo, "sheet_strut_law_at");
  if (cells_across >= lattice_cells_per_member_min(topo)) return strut_law_at(topo, rho, clamped);
  const int w = width_row(t.law, t.nlaw, cells_across, "sheet_strut_law_at");
  // that width's rows, ascending in rho (the table is generated sorted by width, then rho)
  std::vector<const WidthLawRow*> R;
  for (int i = 0; i < t.nlaw; ++i)
    if (t.law[i].n == w) R.push_back(&t.law[i]);
  const int n = int(R.size());
  bool cl = false;
  double r = rho;
  if (!(r > R[0]->rho)) {
    cl = r < R[0]->rho;
    r = R[0]->rho;
  } else if (!(r < R[n - 1]->rho)) {
    cl = r > R[n - 1]->rho;
    r = R[n - 1]->rho;
  }
  if (clamped) *clamped = cl;
  int a = 0;
  while (a + 2 < n && R[a + 1]->rho <= r) ++a;
  const WidthLawRow& r0 = *R[a];
  const WidthLawRow& r1 = *R[std::min(a + 1, n - 1)];
  const double f = r1.rho > r0.rho ? (r - r0.rho) / (r1.rho - r0.rho) : 0.0;
  // (1-f)/f form: an anchor row reproduces its measured value exactly (the pin test reads it)
  StrutLawK k;
  k.Kd = (1.0 - f) * r0.Kd + f * r1.Kd;
  k.Kv = (1.0 - f) * r0.Kv + f * r1.Kv;
  k.Kild = (1.0 - f) * r0.Kild + f * r1.Kild;
  k.Kilv = (1.0 - f) * r0.Kilv + f * r1.Kilv;
  return k;
}

bool sheet_envelope_law_passes(LatticeTopology topo) { return tables(topo).envelope_passes; }

bool sheet_structural_credit_open(LatticeTopology topo) {
  return sheet_structural_credit_gate(sheet_envelope_law_passes(topo), kSheetStructuralCreditReviewed);
}

std::optional<StrutLawK> sheet_credit_law_at(LatticeTopology topo, int cells_across, double rho,
                                             bool* clamped) {
  const Tables t = tables_or_throw(topo, "sheet_credit_law_at");
  if (clamped) *clamped = false;
  if (!sheet_structural_credit_open(topo)) return std::nullopt;
  if (cells_across < t.floor) return std::nullopt;
  return sheet_strut_law_at(topo, cells_across, rho, clamped);
}

double sheet_bending_error(LatticeTopology topo, int cells_across, double rho) {
  const Tables t = tables_or_throw(topo, "sheet_bending_error");
  if (cells_across >= lattice_cells_per_member_min(topo)) return 0.0;
  const int w = width_row(t.bend, t.nbend, cells_across, "sheet_bending_error");
  std::vector<const BendRow*> R;
  for (int i = 0; i < t.nbend; ++i)
    if (t.bend[i].n == w) R.push_back(&t.bend[i]);
  std::sort(R.begin(), R.end(), [](const BendRow* a, const BendRow* b) { return a->rho < b->rho; });
  const int n = int(R.size());
  if (rho <= R[0]->rho) return R[0]->err;
  if (rho >= R[n - 1]->rho) return R[n - 1]->err;
  int a = 0;
  while (a + 2 < n && R[a + 1]->rho <= rho) ++a;
  const double f = (rho - R[a]->rho) / (R[a + 1]->rho - R[a]->rho);
  return (1.0 - f) * R[a]->err + f * R[a + 1]->err;
}

double sheet_stiffness_scale(LatticeTopology topo, int cells_across, double rho) {
  const double e = sheet_bending_error(topo, cells_across, rho);
  return e > 0.0 ? 1.0 / (1.0 + e) : 1.0;
}

}  // namespace topopt
