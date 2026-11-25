// The sheets' laws per member width (sheets spec 2026-11-25 rev 3, section 3.2; builder D): core's
// tables are their evidence, TRANSCRIBED, and they read the way the spec says.
//
// §1 strength, every row of evidence/2026-11-25-sheet-laws-thin-members/<type>/kfit_widths.csv
//    (the K*_law columns) reproduced exactly at its anchor by sheet_strut_law_at; the widths are
//    the CSV's widths.
// §2 a narrower member is never credited more than a wider one: each coefficient rises (or stays)
//    as N falls, and never sits under today's law (strut_law_at, valid from 10 / 9 cells).
// §3 lookup: from lattice_cells_per_member_min it IS today's law; an unmeasured width reads the
//    widest measured width under it; under the narrowest it throws; a strut type has no table.
// §4 bending, every row of bend/<type>_vf*_vpc24_nc2-...-8/<type>_bend.csv reproduced at its anchor;
//    the stiffness scale is 1 / (1 + error) where the error is positive, 1 from the floor up.
// §5 the measured floor is steady.csv's verdict (2 when every criterion passes, else 3).
// Reads only CSVs: runs in about a second.
#include "topopt/lattice.hpp"
#include "topopt/sheet_width_law.hpp"
#include "topopt/strut_strength.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
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

void check_type(LatticeTopology topo, const std::string& id) {
  const std::string ev = EVIDENCE_DIR;
  char msg[256];
  CHECK(sheet_width_law_measured(topo), "a sheet has a per-width table");
  // §1 + §2
  const std::vector<Row> kf = read_csv(ev + "/" + id + "/kfit_widths.csv");
  CHECK(!kf.empty(), "kfit_widths.csv read");
  std::set<int> widths;
  std::map<double, std::map<int, StrutLawK>> byrho;
  for (const Row& r : kf) {
    const int n = (int)num(r, "N");
    const double rho = num(r, "rho_lib");
    widths.insert(n);
    bool cl = true;
    const StrutLawK k = sheet_strut_law_at(topo, n, rho, &cl);
    std::snprintf(msg, sizeof msg, "%s N%d rho %.5f: Kd %.4f / Kv %.4f / Kild %.4f / Kilv %.4f transcribed",
                  id.c_str(), n, rho, num(r, "Kd_law"), num(r, "Kv_law"), num(r, "Kild_law"), num(r, "Kilv_law"));
    CHECK(same(k.Kd, num(r, "Kd_law")) && same(k.Kv, num(r, "Kv_law")) &&
              same(k.Kild, num(r, "Kild_law")) && same(k.Kilv, num(r, "Kilv_law")),
          msg);
    CHECK(!cl, "an anchor row is not clamped");
    byrho[rho][n] = k;
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
  for (const auto& d : std::filesystem::directory_iterator(ev + "/bend")) {
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
  for (const Row& r : read_csv(ev + "/steady.csv"))
    if (r.at("type") == id) { seen = true; steady = steady && r.at("pass") == "1"; }
  CHECK(seen, "steady.csv names the type");
  CHECK(sheet_width_floor_measured(topo) == (steady ? 2 : 3), "the measured floor is steady.csv's verdict");
  std::printf("  %s: %zu strength rows, %d bending rows, widths", id.c_str(), kf.size(), nb);
  for (int w : core_w) std::printf(" %d", w);
  std::printf(", measured floor %d\n", sheet_width_floor_measured(topo));
}

}  // namespace

int main() {
  check_type(LatticeTopology::Gyroid, "gyroid");
  check_type(LatticeTopology::SchwarzD, "schwarz_d");
  CHECK(!sheet_width_law_measured(LatticeTopology::Octet), "a strut type has no per-width sheet table");
  bool threw = false;
  try { sheet_strut_law_at(LatticeTopology::Octet, 4, 0.3); } catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw, "a strut type throws");
  std::printf("test_sheet_width_law: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
