// The sheets' laws per member width (sheets spec 2026-11-25 rev 3, section 3.2; builder D), on the
// off-grip envelope of the reviewer's ruling of 2026-11-26 (item 3): core's tables are their
// evidence, TRANSCRIBED, and they read the way the ruling says.
//
// §1 strength, every row of evidence/2026-11-26-sheet-laws-envelope/<type>/kenv_widths.csv (the
//    K*_law columns) reproduced exactly at its anchor by sheet_strut_law_at; the widths are the CSV's.
// §2 a narrower member is never credited more than a wider one: each coefficient rises (or stays)
//    as N falls, and never sits under today's law (strut_law_at, valid from 10 / 9 cells).
// §3 lookup: from lattice_cells_per_member_min it IS today's law; an unmeasured width reads the
//    widest measured width under it; under the narrowest it throws; a strut type has no table.
// §4 bending, every row of the 11-25 folder's bend/<type>_vf*_vpc24_nc2-...-8/<type>_bend.csv
//    reproduced at its anchor; the stiffness scale is 1 / (1 + error) where the error is positive.
// §5 the measured floor is steady_env.csv's verdict (2 when every criterion passes, else 3).
// §6 (a) THE ENVELOPE RULE against every sweep point (<type>/kenv_sweep.csv, the law's populations at
//    their law pitch, and the bulk): monotone, and never above any sweep point at its width or wider,
//    every coefficient. RED controls run here: the raw envelope (no monotone rule) must fail the
//    monotone check; a law with one row lowered under its own sweep point must fail the other.
//    The generated pass flag is kenv_checks.csv's verdict; when it claims the sweep complete, every
//    voxel layer from half a cell up is there at N = 2, 3, 4 (checked here, independently).
// §7 (b) NO STRUCTURAL SHEET CREDIT UNTIL (a): the gate is the envelope verdict AND the reviewer's key;
//    closed today, and sheet_credit_law_at gives no law at any width. RED control: the gate opens
//    with both keys and only with both.
// Reads only CSVs: runs in about a second.
#include "topopt/lattice.hpp"
#include "topopt/sheet_width_law.hpp"
#include "topopt/strut_strength.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;
#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

using Row = std::map<std::string, std::string>;
std::vector<Row> read_csv(const std::string& path) {
  std::vector<Row> out;
  std::ifstream f(path);
  std::string line;
  std::vector<std::string> hdr;
  while (std::getline(f, line)) {
    // quote-aware split; a CRLF line end is tolerated
    std::vector<std::string> parts;
    std::string cell;
    bool quoted = false;
    for (char c : line) {
      if (c == '"') quoted = !quoted;
      else if (c == ',' && !quoted) { parts.push_back(cell); cell.clear(); }
      else if (c != '\r') cell.push_back(c);
    }
    parts.push_back(cell);
    if (hdr.empty()) { hdr = parts; continue; }
    if (parts.size() < hdr.size()) continue;
    Row r;
    for (std::size_t i = 0; i < hdr.size(); ++i) r[hdr[i]] = parts[i];
    out.push_back(r);
  }
  return out;
}
double num(const Row& r, const char* k) { return std::atof(r.at(k).c_str()); }

// the 4-decimal CSV value against core's double (the table is generated from the same text)
bool same(double core, double csv) { return std::fabs(core - csv) <= 5e-5; }

// One sweep point: a law population of one fixture at its law pitch (or the bulk, N = 0: every width).
struct Point {
  double rho;
  int N, layers, vpc;
  std::string what;
  double K[4];
};
double kq(const StrutLawK& k, int q) { return q == 0 ? k.Kd : q == 1 ? k.Kv : q == 2 ? k.Kild : k.Kilv; }
using Law = std::function<StrutLawK(int N, double rho)>;

// How many (row, point, coefficient) triples where the law credits MORE than a sweep point at its
// width or wider (the law's K under the point's). 4-decimal CSV text against doubles: 5e-5.
int never_above_violations(const Law& law, const std::vector<int>& widths, const std::vector<Point>& pts,
                           std::string* first) {
  int bad = 0;
  for (const Point& p : pts)
    for (int n : widths) {
      if (p.N != 0 && n > p.N) continue;
      const StrutLawK k = law(n, p.rho);
      for (int q = 0; q < 4; ++q)
        if (kq(k, q) < p.K[q] - 5e-5) {
          if (!bad && first) {
            char b[200];
            std::snprintf(b, sizeof b, "N%d rho %.5f coefficient %d: law %.4f under %s %.4f", n, p.rho, q,
                          kq(k, q), p.what.c_str(), p.K[q]);
            *first = b;
          }
          ++bad;
        }
    }
  return bad;
}
// How many (rho, narrower, wider, coefficient) where the narrower member is credited more.
int monotone_violations(const Law& law, const std::vector<int>& widths, const std::vector<double>& rhos) {
  int bad = 0;
  for (double rho : rhos)
    for (std::size_t i = 0; i < widths.size(); ++i)
      for (std::size_t j = i + 1; j < widths.size(); ++j) {
        const StrutLawK a = law(widths[i], rho), b = law(widths[j], rho);
        for (int q = 0; q < 4; ++q)
          if (kq(a, q) < kq(b, q) - 1e-9) ++bad;
      }
  return bad;
}

void check_type(LatticeTopology topo, const std::string& id) {
  const std::string ev = EVIDENCE_DIR, ev1125 = EVIDENCE_DIR_1125;
  char msg[320];
  CHECK(sheet_width_law_measured(topo), "a sheet has a per-width table");
  // §1 + §2
  const std::vector<Row> kf = read_csv(ev + "/" + id + "/kenv_widths.csv");
  CHECK(!kf.empty(), "kenv_widths.csv read");
  std::set<int> widths;
  std::set<double> rhos;
  std::map<double, std::map<int, StrutLawK>> byrho;
  std::map<std::pair<int, double>, StrutLawK> env;  // the raw envelope (before the monotone rule)
  for (const Row& r : kf) {
    const int n = (int)num(r, "N");
    const double rho = num(r, "rho_lib");
    widths.insert(n);
    rhos.insert(rho);
    bool cl = true;
    const StrutLawK k = sheet_strut_law_at(topo, n, rho, &cl);
    std::snprintf(msg, sizeof msg, "%s N%d rho %.5f: Kd %.4f / Kv %.4f / Kild %.4f / Kilv %.4f transcribed",
                  id.c_str(), n, rho, num(r, "Kd_law"), num(r, "Kv_law"), num(r, "Kild_law"), num(r, "Kilv_law"));
    CHECK(same(k.Kd, num(r, "Kd_law")) && same(k.Kv, num(r, "Kv_law")) &&
              same(k.Kild, num(r, "Kild_law")) && same(k.Kilv, num(r, "Kilv_law")),
          msg);
    CHECK(!cl, "an anchor row is not clamped");
    byrho[rho][n] = k;
    StrutLawK e;
    e.Kd = num(r, "Kd_env"); e.Kv = num(r, "Kv_env"); e.Kild = num(r, "Kild_env"); e.Kilv = num(r, "Kilv_env");
    env[{n, rho}] = e;
    const StrutLawK today = strut_law_at(topo, rho);
    std::snprintf(msg, sizeof msg, "%s N%d rho %.5f: never under today's law", id.c_str(), n, rho);
    CHECK(k.Kd >= today.Kd - 1e-9 && k.Kv >= today.Kv - 1e-9 && k.Kild >= today.Kild - 1e-9 &&
              k.Kilv >= today.Kilv - 1e-9,
          msg);
  }
  const std::vector<int> core_w = sheet_width_law_widths(topo);
  CHECK(std::vector<int>(widths.begin(), widths.end()) == core_w, "core's widths are the CSV's");
  for (auto& kv : byrho) {
    const StrutLawK* wider = nullptr;
    for (auto it = kv.second.rbegin(); it != kv.second.rend(); ++it) {
      if (wider) {
        std::snprintf(msg, sizeof msg, "%s rho %.5f N%d: not credited more than a wider member", id.c_str(),
                      kv.first, it->first);
        CHECK(it->second.Kd >= wider->Kd - 1e-9 && it->second.Kv >= wider->Kv - 1e-9 &&
                  it->second.Kild >= wider->Kild - 1e-9 && it->second.Kilv >= wider->Kilv - 1e-9,
              msg);
      }
      wider = &it->second;
    }
  }
  // §3
  const int floor_today = (int)std::lround(lattice_cells_per_member_min(topo));
  const double rho_mid = 0.35;
  {
    const StrutLawK a = sheet_strut_law_at(topo, floor_today, rho_mid);
    const StrutLawK b = strut_law_at(topo, rho_mid);
    CHECK(a.Kd == b.Kd && a.Kv == b.Kv && a.Kild == b.Kild && a.Kilv == b.Kilv,
          "from today's floor it is today's law");
  }
  for (int n = core_w.front(); n < floor_today; ++n) {
    int w = core_w.front();
    for (int x : core_w) if (x <= n) w = x;
    const StrutLawK a = sheet_strut_law_at(topo, n, rho_mid);
    const StrutLawK b = sheet_strut_law_at(topo, w, rho_mid);
    std::snprintf(msg, sizeof msg, "%s: %d cells read the %d-cell row", id.c_str(), n, w);
    CHECK(a.Kd == b.Kd && a.Kilv == b.Kilv, msg);
  }
  bool threw = false;
  try { sheet_strut_law_at(topo, core_w.front() - 1, rho_mid); } catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "under the narrowest measured width: no law (throws)");
  // §4
  int nb = 0;
  for (const auto& d : std::filesystem::directory_iterator(ev1125 + "/bend")) {
    const std::string name = d.path().filename().string();
    if (name.rfind(id + "_vf", 0) != 0 || name.find("_vpc24_nc2-3-4-5-6-7-8") == std::string::npos) continue;
    for (const Row& r : read_csv(d.path().string() + "/" + id + "_bend.csv")) {
      const int n = (int)num(r, "cells_across");
      const double rho = num(r, "cell_rho"), e = num(r, "bend_err_pct") / 100.0;
      if (n >= floor_today) continue;
      ++nb;
      std::snprintf(msg, sizeof msg, "%s bending N%d rho %.4f: %+.4f transcribed", id.c_str(), n, rho, e);
      CHECK(same(sheet_bending_error(topo, n, rho), e), msg);
      const double s = sheet_stiffness_scale(topo, n, rho);
      CHECK(e > 0 ? std::fabs(s - 1.0 / (1.0 + sheet_bending_error(topo, n, rho))) < 1e-12 : s == 1.0,
            "the stiffness scale is 1 / (1 + error) where the error is positive, else 1");
    }
  }
  CHECK(nb >= 3 * 6, "the bending rows of three densities read");
  CHECK(sheet_stiffness_scale(topo, floor_today, 0.4) == 1.0, "from today's floor the tensor is unscaled");
  // §5
  bool steady = true, seen = false;
  for (const Row& r : read_csv(ev + "/steady_env.csv"))
    if (r.at("type") == id) { seen = true; steady = steady && r.at("pass") == "1"; }
  CHECK(seen, "steady_env.csv names the type");
  CHECK(sheet_width_floor_measured(topo) == (steady ? 2 : 3), "the measured floor is steady_env.csv's verdict");

  // §6 (a): THE ENVELOPE RULE against every sweep point
  std::vector<Point> pts;
  std::map<double, std::map<int, std::set<int>>> og_layers;  // rho -> N -> off-grip cut layers (vpc units)
  std::map<double, std::map<int, std::set<double>>> og_cuts;  // rho -> N -> cuts asked
  std::map<double, int> law_vpc;
  for (const Row& r : read_csv(ev + "/" + id + "/kenv_sweep.csv")) {
    if (r.at("in_law") != "1") continue;
    Point p{num(r, "rho_lib"), (int)num(r, "N"), (int)num(r, "cut_layers"), (int)num(r, "vpc"),
            r.at("population") + " cut " + r.at("cut_asked") + " N" + r.at("N"),
            {num(r, "Kd"), num(r, "Kv"), num(r, "Kild"), num(r, "Kilv")}};
    pts.push_back(p);
    if (r.at("population") == "cut_off_grip") {
      og_layers[p.rho][p.N].insert(p.layers);
      og_cuts[p.rho][p.N].insert(num(r, "cut_asked"));
      law_vpc[p.rho] = p.vpc;
    }
  }
  for (const Row& r : kf)  // the bulk is a point at every width
    pts.push_back(Point{num(r, "rho_lib"), 0, 0, 0, "bulk",
                        {num(r, "Kd_bulk"), num(r, "Kv_bulk"), num(r, "Kild_bulk"), num(r, "Kilv_bulk")}});
  CHECK(pts.size() > kf.size(), "kenv_sweep.csv read");
  const std::vector<double> rv(rhos.begin(), rhos.end());
  const Law real = [&](int n, double rho) { return sheet_strut_law_at(topo, n, rho); };
  std::string first;
  int v = never_above_violations(real, core_w, pts, &first);
  std::snprintf(msg, sizeof msg, "%s: the law is never above any sweep point at its width or wider (%zu points; %s)",
                id.c_str(), pts.size(), v ? first.c_str() : "none under");
  CHECK(v == 0, msg);
  CHECK(monotone_violations(real, core_w, rv) == 0, "the law is monotone in the member's width");
  // RED A: the raw envelope, without the monotone rule, must fail the monotone check (it rises with N)
  const Law raw = [&](int n, double rho) { return env.at({n, rho}); };
  std::snprintf(msg, sizeof msg, "%s RED A: the raw envelope fails the monotone check (%d violations)",
                id.c_str(), monotone_violations(raw, core_w, rv));
  CHECK(monotone_violations(raw, core_w, rv) > 0, msg);
  // RED B: the law with ONE row lowered 1 % under its own strongest sweep point must fail
  {
    const Point* top = nullptr;
    for (const Point& p : pts)
      if (p.N == core_w.back() && (!top || p.K[0] > top->K[0])) top = &p;
    CHECK(top != nullptr, "a sweep point at the widest width");
    if (top) {
      const double rho0 = top->rho, kd0 = 0.99 * top->K[0];
      const Law lowered = [&](int n, double rho) {
        StrutLawK k = sheet_strut_law_at(topo, n, rho);
        if (n == core_w.back() && std::fabs(rho - rho0) < 1e-9) k.Kd = kd0;
        return k;
      };
      const int red = never_above_violations(lowered, core_w, pts, nullptr);
      std::snprintf(msg, sizeof msg, "%s RED B: N%d rho %.5f lowered to %.4f fails never-above (%d violations)",
                    id.c_str(), core_w.back(), rho0, kd0, red);
      CHECK(red > 0, msg);
    }
  }
  // the ruling's cuts: 0.5 and 0.6 at every width of every row
  for (double rho : rv)
    for (int n : core_w) {
      const auto& c = og_cuts[rho][n];
      std::snprintf(msg, sizeof msg, "%s rho %.5f N%d: the sweep holds 0.5 and 0.6 (off the grips)", id.c_str(), rho, n);
      CHECK(c.count(0.5) == 1 && c.count(0.6) == 1, msg);
    }
  // the generated pass flag is kenv_checks.csv's verdict; a claimed complete sweep is complete
  bool passes = true, seen_c = false, sweep_claimed = false;
  for (const Row& r : read_csv(ev + "/kenv_checks.csv"))
    if (r.at("type") == id) {
      seen_c = true;
      passes = passes && r.at("pass") == "1";
      if (r.at("check") == "sweep_complete" && r.at("rho").empty()) sweep_claimed = r.at("pass") == "1";
    }
  CHECK(seen_c, "kenv_checks.csv names the type");
  CHECK(sheet_envelope_law_passes(topo) == passes, "core's envelope verdict is kenv_checks.csv's");
  if (sweep_claimed)
    for (double rho : rv)
      for (int n : {2, 3, 4}) {
        const int vpc = law_vpc[rho];
        bool all = vpc > 0;
        for (int k = vpc / 2; k < vpc; ++k) all = all && og_layers[rho][n].count(k) == 1;
        std::snprintf(msg, sizeof msg, "%s rho %.5f N%d: every voxel layer from half a cell up (vpc %d)",
                      id.c_str(), rho, n, vpc);
        CHECK(all, msg);
      }

  // §7 (b): NO STRUCTURAL SHEET CREDIT UNTIL (a)
  CHECK(sheet_structural_credit_open(topo) == (passes && kSheetStructuralCreditReviewed),
        "the gate is the envelope verdict AND the reviewer's key");
  CHECK(!sheet_structural_credit_open(topo), "(b): Structural sheet credit is closed (until the reviewer opens it)");
  int given = 0;
  for (int n = 0; n <= 12; ++n)
    for (double rho : {lattice_rho_min(topo), 0.3, lattice_rho_max(topo)}) {
      bool cl = true;
      if (sheet_credit_law_at(topo, n, rho, &cl).has_value()) ++given;
      CHECK(!cl, "a refused law is not clamped");
    }
  std::snprintf(msg, sizeof msg, "%s (b): sheet_credit_law_at gives no law at any width while closed (%d given)",
                id.c_str(), given);
  CHECK(given == 0, msg);
  std::printf("  %s: %zu strength rows, %d bending rows, %zu sweep points, widths", id.c_str(), kf.size(), nb,
              pts.size());
  for (int w : core_w) std::printf(" %d", w);
  std::printf(", measured floor %d, envelope law %s, Structural credit %s\n", sheet_width_floor_measured(topo),
              passes ? "passes" : "does not pass", sheet_structural_credit_open(topo) ? "OPEN" : "closed");
}

}  // namespace

int main() {
  check_type(LatticeTopology::Gyroid, "gyroid");
  check_type(LatticeTopology::SchwarzD, "schwarz_d");
  CHECK(!sheet_width_law_measured(LatticeTopology::Octet), "a strut type has no per-width sheet table");
  bool threw = false;
  try { sheet_strut_law_at(LatticeTopology::Octet, 4, 0.3); } catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "a strut type throws");
  threw = false;
  try { sheet_credit_law_at(LatticeTopology::Octet, 4, 0.3); } catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "a strut type throws at the credit door too");
  // §7 RED control: the gate opens with both keys, and only with both
  CHECK(sheet_structural_credit_gate(true, true), "RED: both keys open the gate");
  CHECK(!sheet_structural_credit_gate(true, false), "the envelope alone does not open it");
  CHECK(!sheet_structural_credit_gate(false, true), "the reviewer's key alone does not open it");
  CHECK(!sheet_structural_credit_gate(false, false), "neither key: closed");
  std::printf("test_sheet_width_law: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
