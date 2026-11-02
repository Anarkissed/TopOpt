// test_lattice_types — THE GO-LIVE BARS A STRUT TYPE MUST HOLD IN CORE (lattice types
// round 1, docs/design/lattice-types/02-core-spec.md §4), checked on every live type.
//
// What the measurement harness (tests/harness/lattice_types_probe.cpp) cannot keep
// true on its own, because it runs once and lands numbers:
//
//   1. OWNERSHIP on the production generator, for a region with holes in it: every
//      strut of the infinite tiling that touches an active cell is emitted EXACTLY
//      ONCE, every emitted strut belongs to an active cell, and every emitted node ball
//      sits on an emitted strut (no floating balls -- diamond's cell corners are why
//      this is asserted for every type, not assumed).
//   2. DETERMINISM: two runs, the same bytes.
//   3. PERCOLATION ON THE EMITTED MESH: a block is one solid-overlap component.
//   4. The facts the app reads (lattice_types.hpp), the print-tests loader against the
//      COMMITTED maintainer file, the sample block, and the job parse.
//
// Octet is the control on 1-3 (its generator is PR 201's and must pass the same bars).
//
// Self-contained CHECK harness (ARCHITECTURE §4).

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <map>
#include <numeric>
#include <set>
#include <stdexcept>
#include <string>
#include <tuple>
#include <vector>

#include "topopt/job.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/lattice_print_tests.hpp"
#include "topopt/lattice_sample.hpp"
#include "topopt/lattice_types.hpp"
#include "topopt/mesh.hpp"
#include "topopt/strut_cell.hpp"

using namespace topopt;

static int g_checks = 0, g_failures = 0;
#define CHECK(cond, msg)                                         \
  do {                                                           \
    ++g_checks;                                                  \
    if (!(cond)) {                                               \
      ++g_failures;                                              \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, msg);  \
    }                                                            \
  } while (0)

namespace {

// Integer key of a point on the generator's grid (units of L/S, the cell at origin 0).
using Key = std::tuple<long, long, long>;
Key key(const Vec3& p, double unit) {
  return {std::lround(p.x / unit), std::lround(p.y / unit), std::lround(p.z / unit)};
}

struct Tap {
  std::vector<std::pair<Key, Key>> struts;
  std::vector<Key> nodes;
};
Tap tap(LatticeGenTopology gt, const LatticeRegion& R, double radius, double unit,
        TriangleSink& sink) {
  Tap t;
  LatticeGenObserver obs;
  obs.on_element = [&](LatticeGenElement k, const Vec3& a, const Vec3& b, double) {
    if (k == LatticeGenElement::InteriorStrut) {
      Key ka = key(a, unit), kb = key(b, unit);
      if (kb < ka) std::swap(ka, kb);
      t.struts.push_back({ka, kb});
    } else if (k == LatticeGenElement::Node) {
      t.nodes.push_back(key(a, unit));
    }
  };
  LatticeRadiusField G;
  G.uniform_mm = radius;
  generate_lattice(gt, R, G, sink, LatticeSkinSpec{}, &obs);
  return t;
}

struct NullSink : TriangleSink {
  void add_triangle(const Vec3&, const Vec3&, const Vec3&) override {}
};
struct HashSink : TriangleSink {
  unsigned long long h = 1469598103934665603ull;
  void eat(double v) {
    unsigned char b[sizeof v];
    std::memcpy(b, &v, sizeof v);
    for (unsigned char c : b) h = (h ^ c) * 1099511628211ull;
  }
  void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override {
    for (const Vec3* p : {&a, &b, &c}) { eat(p->x); eat(p->y); eat(p->z); }
  }
};

// 1. Ownership against an independent expectation built from the canonical cell.
void check_ownership(LatticeGenTopology gt, LatticeTopology t) {
  const StrutCell& c = lattice_strut_cell(t);
  const double cell = 4.0, unit = cell / c.S;
  LatticeRegion R;
  R.nx = 4; R.ny = 3; R.nz = 3; R.cell_mm = cell;
  // Holes, an isolated cell and a ragged edge: the cases ownership has to get right.
  R.latticed = [](int i, int j, int k) {
    if (i == 1 && j == 1 && k == 1) return false;
    if (i == 3 && (j + k) % 2 == 0) return false;
    if (k == 2 && j == 0 && i < 2) return false;
    return true;
  };
  NullSink sink;
  const Tap got = tap(gt, R, 0.2, unit, sink);
  const std::string id = lattice_topology_name(t);

  // Expected: every closed-box strut of every active cell, as a set.
  std::set<std::pair<Key, Key>> want;
  std::set<Key> want_nodes_any;
  for (int k = 0; k < R.nz; ++k)
    for (int j = 0; j < R.ny; ++j)
      for (int i = 0; i < R.nx; ++i) {
        if (!R.latticed(i, j, k)) continue;
        for (const StrutCellStrut& s : strut_cell_closed_struts(c)) {
          Key a{s.a.x + long(i) * c.S, s.a.y + long(j) * c.S, s.a.z + long(k) * c.S};
          Key b{s.b.x + long(i) * c.S, s.b.y + long(j) * c.S, s.b.z + long(k) * c.S};
          if (b < a) std::swap(a, b);
          want.insert({a, b});
        }
      }
  std::map<std::pair<Key, Key>, int> count;
  for (const auto& s : got.struts) ++count[s];
  bool once = true, owned = true;
  for (const auto& kv : count) {
    if (kv.second != 1) once = false;
    if (!want.count(kv.first)) owned = false;
  }
  CHECK(once, (id + ": every emitted strut is emitted exactly once").c_str());
  CHECK(owned, (id + ": every emitted strut belongs to an active cell").c_str());
  CHECK(count.size() == want.size(),
        (id + ": every strut touching an active cell is emitted (none dropped)").c_str());

  std::set<Key> ends;
  for (const auto& s : got.struts) { ends.insert(s.first); ends.insert(s.second); }
  std::map<Key, int> ncount;
  for (const Key& n : got.nodes) ++ncount[n];
  bool node_once = true, node_on_strut = true;
  for (const auto& kv : ncount) {
    if (kv.second != 1) node_once = false;
    if (!ends.count(kv.first)) node_on_strut = false;
  }
  CHECK(node_once, (id + ": every node ball is emitted exactly once").c_str());
  CHECK(node_on_strut, (id + ": no floating node ball (each sits on an emitted strut)").c_str());
  CHECK(ncount.size() == ends.size(),
        (id + ": every strut end carries a node ball").c_str());
}

// 3. Solid-overlap components of whatever `run` emits (struts and balls; joined where
// the axes come within the sum of the inscribed radii).
int overlap_components(const std::function<void(const LatticeGenObserver*)>& run) {
  struct P { Vec3 a, b; double r; };
  std::vector<P> prims;
  LatticeGenObserver obs;
  obs.on_element = [&](LatticeGenElement k, const Vec3& a, const Vec3& b, double rr) {
    const bool ball = k == LatticeGenElement::Node || k == LatticeGenElement::AnchorNode;
    prims.push_back({a, b, ball ? rr * 0.79465 : rr * std::cos(M_PI / 8)});
  };
  run(&obs);
  const double cell = 1e30;  // the cheap reject below is set per call by the caller's scale
  auto segdist = [](const Vec3& p1, const Vec3& q1, const Vec3& p2, const Vec3& q2) {
    // sampled closest approach (exact enough for a connectivity count at this scale)
    double best = 1e30;
    for (int i = 0; i <= 16; ++i)
      for (int j = 0; j <= 16; ++j) {
        const double s = i / 16.0, t = j / 16.0;
        const double dx = p1.x + (q1.x - p1.x) * s - p2.x - (q2.x - p2.x) * t;
        const double dy = p1.y + (q1.y - p1.y) * s - p2.y - (q2.y - p2.y) * t;
        const double dz = p1.z + (q1.z - p1.z) * s - p2.z - (q2.z - p2.z) * t;
        best = std::min(best, std::sqrt(dx * dx + dy * dy + dz * dz));
      }
    return best;
  };
  std::vector<int> par(prims.size());
  std::iota(par.begin(), par.end(), 0);
  std::function<int(int)> f = [&](int x) { return par[x] == x ? x : par[x] = f(par[x]); };
  for (std::size_t i = 0; i < prims.size(); ++i)
    for (std::size_t j = i + 1; j < prims.size(); ++j) {
      (void)cell;
      const double gap = 9.0;  // cheap reject: every cell in these tests is <= 8 mm
      if (std::fabs(prims[i].a.x - prims[j].a.x) > gap ||
          std::fabs(prims[i].a.y - prims[j].a.y) > gap ||
          std::fabs(prims[i].a.z - prims[j].a.z) > gap)
        continue;
      if (segdist(prims[i].a, prims[i].b, prims[j].a, prims[j].b) <=
          prims[i].r + prims[j].r)
        par[f(int(i))] = f(int(j));
    }
  std::set<int> roots;
  for (std::size_t i = 0; i < prims.size(); ++i) roots.insert(f(int(i)));
  return int(roots.size());
}

}  // namespace

int main() {
  // The live strut types, generator id and certificate id. Octet is the control.
  const std::vector<std::pair<LatticeGenTopology, LatticeTopology>> live = {
      {LatticeGenTopology::Octet, LatticeTopology::Octet},
      {LatticeGenTopology::Fcc, LatticeTopology::Fcc},
      {LatticeGenTopology::Bcc, LatticeTopology::Bcc},
      {LatticeGenTopology::Diamond, LatticeTopology::Diamond},
      {LatticeGenTopology::Rhombic, LatticeTopology::Rhombic},
      {LatticeGenTopology::Kelvin, LatticeTopology::Kelvin},
  };

  for (const auto& [gt, t] : live) {
    const std::string id = lattice_topology_name(t);
    CHECK(lattice_gen_topology_name(gt) == id, (id + ": generator and certificate ids agree").c_str());
    CHECK(lattice_gen_certificate_topology(gt) == t, (id + ": generator -> certificate").c_str());
    CHECK(lattice_gen_topology_from_id(id) == gt, (id + ": id -> generator").c_str());
    check_ownership(gt, t);

    // 2. Determinism: same inputs, same bytes (a skinned, clipped run is octet's own
    //    test's business; this is the plain path every type shares).
    unsigned long long h[2];
    for (int run = 0; run < 2; ++run) {
      HashSink hs;
      LatticeRegion R;
      R.nx = 3; R.ny = 2; R.nz = 2; R.cell_mm = 6.0;
      LatticeRadiusField G;
      G.field = [](Vec3 p) { return 0.3 + 0.01 * p.x; };
      generate_lattice(gt, R, G, hs);
      h[run] = hs.h;
    }
    CHECK(h[0] == h[1], (id + ": two runs, identical bytes").c_str());

    // 3. Percolation on the emitted mesh, at the band's middle density.
    const double rho = 0.5 * (lattice_rho_min(t) + lattice_rho_max(t));
    const double r = 0.5 * lattice_strut_diameter_mm(t, rho, 8.0);
    NullSink sink;
    CHECK(overlap_components([&](const LatticeGenObserver* o) {
            LatticeRegion R;
            R.nx = R.ny = R.nz = 3; R.cell_mm = 8.0;
            LatticeRadiusField G; G.uniform_mm = r;
            generate_lattice(gt, R, G, sink, LatticeSkinSpec{}, o);
          }) == 1,
          (id + ": a 3x3x3 block is one connected solid").c_str());
    // ... and across a size step, through the production multilevel and stepped passes,
    // exactly as far as the type's R4 verdict says: a step the facts allow joins into one
    // solid, and a step they refuse is the one that was measured NOT to.
    const bool doubled_ok = lattice_type_doubled(t).allowed;
    CHECK((overlap_components([&](const LatticeGenObserver* o) {
            LatticeRegion base;
            base.nx = 6; base.ny = 2; base.nz = 2; base.cell_mm = 4.0;
            std::vector<LatticeLevelSpec> lv(2);
            lv[0].level = 0; lv[0].cell_mm = 4.0;
            lv[0].latticed = [](int i, int, int) { return i < 2; };
            lv[0].radius.uniform_mm = 0.5 * lattice_strut_diameter_mm(t, rho, 4.0);
            lv[1].level = 1; lv[1].cell_mm = 8.0;
            lv[1].latticed = [](int i, int, int) { return i >= 1; };
            lv[1].radius.uniform_mm = r;
            generate_lattice_multilevel(gt, base, lv, sink, {}, o);
          }) == 1) == doubled_ok,
          (id + ": a Doubled S|S/2 block is one solid exactly when Doubled is allowed").c_str());
    CHECK(doubled_ok || !lattice_type_doubled(t).reason.empty(),
          (id + ": a refused Doubled says why").c_str());
    const bool stepped_ok = lattice_type_stepped(t).allowed;
    CHECK((overlap_components([&](const LatticeGenObserver* o) {
            std::vector<LatticeSteppedPass> p(2);
            p[0].region.nx = p[0].region.ny = p[0].region.nz = 2;
            p[0].region.cell_mm = 6.0;
            p[0].radius.uniform_mm = 0.5 * lattice_strut_diameter_mm(t, rho, 6.0);
            p[1].region.origin = Vec3{12.0, 0, 0};
            p[1].region.nx = p[1].region.ny = p[1].region.nz = 3;
            p[1].region.cell_mm = 4.0;
            p[1].radius.uniform_mm = 0.5 * lattice_strut_diameter_mm(t, rho, 4.0);
            generate_lattice_stepped(gt, p, sink, {}, o);
          }) == 1) == stepped_ok,
          (id + ": a Stepped 6 mm | 4 mm interface is one solid exactly when Stepped is "
                "allowed").c_str());

    // The BOUNDARY FINISH on this type: clip to a box with a bore through it, Diagrid
    // skin. Every interior strut and node solid stays inside the part (the clip's
    // promise), every landing gets its anchor ball, and the run is deterministic.
    {
      LatticeBoundary B;
      B.add_box({1.3, 0.7, 0.9}, {22.1, 21.4, 19.7});
      LatticeRegion R;
      R.nx = R.ny = 3; R.nz = 3; R.cell_mm = 8.0; R.boundary = &B;
      LatticeRadiusField G; G.uniform_mm = 0.45;
      LatticeSkinSpec skin;
      skin.mode = LatticeSkinMode::Diagrid;
      skin.min_radius_mm = lattice_skin_min_radius_mm(0.42);
      double worst = 1e30;
      LatticeGenObserver obs;
      obs.on_element = [&](LatticeGenElement k, const Vec3& a, const Vec3& b, double rr) {
        if (k != LatticeGenElement::InteriorStrut && k != LatticeGenElement::Node) return;
        worst = std::min(worst, std::min(B.signed_distance(a), B.signed_distance(b)) - rr);
      };
      HashSink h1, h2;
      const LatticeGenStats st = generate_lattice(gt, R, G, h1, skin, &obs);
      generate_lattice(gt, R, G, h2, skin, nullptr);
      CHECK(st.clipped_struts > 0 && st.landings > 0,
            (id + ": the box clips struts and leaves landings").c_str());
      CHECK(st.anchor_nodes == st.landings,
            (id + ": every landing carries its anchor ball (Diagrid)").c_str());
      CHECK(st.skin_struts > 0, (id + ": the diagrid skin is laid").c_str());
      CHECK(worst > -1e-6, (id + ": no interior strut or node solid leaves the part").c_str());
      CHECK(h1.h == h2.h, (id + ": a clipped, skinned run is deterministic").c_str());
    }

    // ★ AND THE SKIN IS ONE PIECE on a face just off a node plane, where the landings
    // bunch around the nodes that send a strut across it. FCC, BCC and SC's are a full
    // cell apart (octet's 0.7071), and octet's 0.72-cell link radius left 9 to 25 islands
    // there until each type's radius scaled to its own gap (crossing_node_gap). Anchors
    // on the face's interior (a cell in from its edges) and the skin edges joining them
    // go into one union-find; the anchors must end up in one component.
    {
      const double rr = 0.45, x0 = 0.95 * 8.0 - rr;  // landings at 0.95 cell
      LatticeBoundary B;
      B.add_box({x0, 0.3, 0.3}, {39.7, 39.7, 39.7});
      LatticeRegion R;
      R.nx = R.ny = R.nz = 5; R.cell_mm = 8.0; R.boundary = &B;
      LatticeRadiusField G; G.uniform_mm = rr;
      LatticeSkinSpec skin;
      skin.mode = LatticeSkinMode::Diagrid;
      skin.min_radius_mm = lattice_skin_min_radius_mm(0.42);
      std::map<std::tuple<long, long, long>, int> key;
      std::vector<int> parent, anchors;
      auto node = [&](const Vec3& q) {
        const auto k = std::make_tuple(std::lround(q.x * 1e3), std::lround(q.y * 1e3),
                                       std::lround(q.z * 1e3));
        const auto it = key.find(k);
        if (it != key.end()) return it->second;
        const int n = static_cast<int>(parent.size());
        parent.push_back(n);
        key[k] = n;
        return n;
      };
      auto root = [&](int x) {
        while (parent[x] != x) x = parent[x] = parent[parent[x]];
        return x;
      };
      auto on_face = [&](const Vec3& q) { return q.x < x0 + 2.0; };
      LatticeGenObserver obs;
      obs.on_element = [&](LatticeGenElement k, const Vec3& a, const Vec3& b, double) {
        if (k == LatticeGenElement::AnchorNode && on_face(a) && a.y > 8.0 && a.y < 31.7 &&
            a.z > 8.0 && a.z < 31.7)
          anchors.push_back(node(a));
        if (k == LatticeGenElement::SkinStrut && on_face(a) && on_face(b))
          parent[root(node(a))] = root(node(b));
      };
      NullSink sink;
      (void)generate_lattice(gt, R, G, sink, skin, &obs);
      std::set<int> pieces;
      for (int n : anchors) pieces.insert(root(n));
      char msg[200];
      std::snprintf(msg, sizeof msg,
                    "%s: the diagrid skin on a face just off a node plane is ONE piece "
                    "(%zu pieces over %zu anchors)",
                    id.c_str(), pieces.size(), anchors.size());
      CHECK(anchors.size() >= 4 && pieces.size() == 1, msg);
    }
  }

  // Not-yet-live types are refused by the generator by name.
  for (const char* id : {"sc", "gyroid"}) {
    bool threw = false;
    try { (void)lattice_gen_topology_from_id(id); }
    catch (const std::invalid_argument& e) { threw = std::string(e.what()).find(id) != std::string::npos; }
    CHECK(threw, (std::string(id) + ": not generatable, refused by name").c_str());
  }

  // 4a. The facts.
  {
    const LatticeTypeFacts fcc = lattice_type_facts("fcc");
    CHECK(fcc.readiness == LatticeTypeReadiness::Live, "facts fcc: live");
    CHECK(fcc.family == "strut" && fcc.display_name == "FCC", "facts fcc: strut, named");
    CHECK(fcc.numbers_measured && fcc.cells_per_member_min == 5.0 &&
              fcc.percolation_cells_per_member_min == 0.75 &&
              fcc.aesthetic_hard_floor_cells == 2.0,
          "facts fcc: its own floors");
    CHECK(fcc.rho_min == lattice_rho_min(LatticeTopology::Fcc) &&
              fcc.rho_max == lattice_rho_max(LatticeTopology::Fcc),
          "facts fcc: its band");
    CHECK(fcc.outline.allowed && fcc.rim.allowed && fcc.diagrid.allowed,
          "facts fcc: every finish (R8)");
    CHECK(fcc.uniform.allowed && fcc.doubled.allowed && fcc.stepped.allowed,
          "facts fcc: every cell mode (R4 measured PASS)");
    CHECK(!fcc.directional, "facts fcc: not directional (R3 is SC and BCC)");
    CHECK(fcc.triangles_per_cell == 12 * 32 + 4 * 20, "facts fcc: triangles per cell");
    CHECK(!fcc.strut_strength_measured && !fcc.strut_strength_note.empty(),
          "facts fcc: strut strength not measured, said so (R10)");
    CHECK(std::isfinite(fcc.aesthetic_density_ceiling) && fcc.aesthetic_density_ceiling > 0.2 &&
              fcc.aesthetic_density_ceiling < 0.23,
          "facts fcc: the R11 ceiling through its own table");
    CHECK(std::fabs(fcc.printable_cell_per_bead * 0.42 -
                    lattice_min_printable_cell_mm(LatticeTopology::Fcc, 0.42, 0.0)) < 1e-9,
          "facts fcc: printable cell per bead");

    const LatticeTypeFacts kel = lattice_type_facts("sc");
    CHECK(kel.readiness == LatticeTypeReadiness::NotGeneratable, "facts sc: not live");
    CHECK(!kel.numbers_measured && std::isnan(kel.cells_per_member_min) &&
              std::isnan(kel.aesthetic_density_ceiling),
          "facts sc: no number is octet's (NaN until measured)");
    CHECK(!kel.doubled.allowed && !kel.doubled.reason.empty(), "facts sc: refused, with a reason");
    const LatticeTypeFacts sc = lattice_type_facts("sc");
    CHECK(sc.directional && !sc.directional_note.empty(), "facts sc: directional note (R3)");
    const LatticeTypeFacts gy = lattice_type_facts("gyroid");
    CHECK(gy.family == "sheet" && gy.readiness == LatticeTypeReadiness::NotEither,
          "facts gyroid: a planned sheet, not live");
    const LatticeTypeFacts no = lattice_type_facts("octopus");
    CHECK(no.readiness == LatticeTypeReadiness::UnknownId && no.family.empty(),
          "facts: an unknown id gets no facts");
    CHECK(lattice_type_ids().front() == "octet" && lattice_type_ids().size() == 9,
          "facts: octet first, nine types");
  }

  // 4b. The print-tests loader, on the COMMITTED maintainer file.
  {
    const LatticePrintTests pt = load_lattice_print_tests_file(LATTICE_PRINT_TESTS_PATH);
    CHECK(pt.size() == 10, "print tests: the committed file loads, ten rows");
    CHECK(lattice_print_status(pt, "octet").print_tested &&
              lattice_print_status(pt, "octet").date == "2026-07-27",
          "print tests: octet is tested, dated");
    CHECK(!lattice_print_status(pt, "fcc").print_tested, "print tests: fcc not yet");
    CHECK(!lattice_print_status(pt, "fccz").listed && !lattice_print_status(pt, "fccz").print_tested,
          "print tests: an absent id reads as not tested");
    auto refuses = [](const std::string& text, const std::string& names) {
      try { (void)parse_lattice_print_tests(text); }
      catch (const LatticePrintTestsError& e) { return std::string(e.what()).find(names) != std::string::npos; }
      return false;
    };
    const std::string head = R"({"schema_version": 1, "_comment": "x", "types": {)";
    CHECK(parse_lattice_print_tests(head + R"("fccz": {"print_tested": true, "date": "2026-11-01", "note": "ok"}}})")
              .at("fccz").print_tested,
          "print tests: a row for fccz (an enum id) is accepted");
    CHECK(refuses(head + R"("Gyroid": {"print_tested": false, "date": null, "note": null}}})", "Gyroid"),
          "print tests: a misspelt id is refused BY NAME");
    CHECK(refuses(head + R"("fcc": {"print_tested": false, "date": null}}})", "note"),
          "print tests: a missing key is refused, named");
    CHECK(refuses(head + R"("fcc": {"print_tested": false, "date": null, "note": null, "x": 1}}})", "\"x\""),
          "print tests: an unknown key is refused, named");
    CHECK(refuses(head + R"("fcc": {"print_tested": true, "date": null, "note": "a"}}})", "no date"),
          "print tests: tested without a date is refused");
    CHECK(refuses(R"({"schema_version": 2, "types": {}})", "schema_version"),
          "print tests: another schema version is refused");
    CHECK(refuses(head + R"("fcc": {"print_tested": false, "print_tested": true, "date": "2026-11-01", "note": null}}})",
                  "twice"),
          "print tests: a key repeated inside a row is refused");
    CHECK(refuses(head + R"("fcc": {"print_tested": false, "date": null, "note": null},
                            "fcc": {"print_tested": false, "date": null, "note": null}}})", "twice"),
          "print tests: a type listed twice is refused");
    CHECK(refuses(head + R"("fcc": {"print_tested": true, "date": "2026-13-45", "note": "x"}}})", "YYYY-MM-DD"),
          "print tests: an impossible date is refused");
  }

  // 4c. The sample block.
  {
    NullSink sink;
    LatticeSampleSpec s;
    s.topology = "fcc";
    const LatticeSampleReceipt r = write_lattice_sample(s, sink);
    CHECK(r.cells_per_side == 5 && r.rho_was_band_middle &&
              r.rho == 0.5 * (lattice_rho_min(LatticeTopology::Fcc) + lattice_rho_max(LatticeTopology::Fcc)),
          "sample: 5 cells per side at the band middle");
    CHECK(r.strut_diameter_mm == lattice_strut_diameter_mm(LatticeTopology::Fcc, r.rho, 8.0),
          "sample: the type's own law sizes the strut");
    CHECK(r.struts == 1800 && r.nodes == 666 && r.triangles == r.lattice_triangles + 12,
          "sample: the FCC block's 1,800 struts (450 cell faces x 4 legs), 666 nodes "
          "(216 corners + 450 face centres) and the 12-triangle plate");
    auto refused = [&](LatticeSampleSpec bad) {
      try { (void)write_lattice_sample(bad, sink); } catch (const std::invalid_argument&) { return true; }
      return false;
    };
    LatticeSampleSpec b1 = s; b1.size_mm = 42;  CHECK(refused(b1), "sample: a part cell is refused");
    LatticeSampleSpec b2 = s; b2.rho = 0.9;     CHECK(refused(b2), "sample: out of band is refused");
    LatticeSampleSpec b3 = s; b3.bead_mm = 3.0; CHECK(refused(b3), "sample: thinner than a bead is refused");
    LatticeSampleSpec b4 = s; b4.topology = "bccz"; CHECK(refused(b4), "sample: a type not live is refused");
    // R3: a directional type's receipt says so; every other type's has no such key.
    LatticeSampleSpec d = s; d.topology = "bcc";
    const std::string dj = lattice_sample_receipt_json(write_lattice_sample(d, sink));
    CHECK(dj.find("\"directional_note\": \"" + lattice_type_directional_note("bcc") + "\"") !=
              std::string::npos,
          "sample: a BCC receipt carries the R3 directional note");
    CHECK(lattice_sample_receipt_json(r).find("directional_note") == std::string::npos,
          "sample: an FCC receipt has no directional key");
    CHECK(lattice_type_directional_note("octet").empty() &&
              lattice_type_directional_note("fcc").empty() &&
              !lattice_type_directional_note("sc").empty() &&
              lattice_type_facts("bcc").directional_note == lattice_type_directional_note("bcc"),
          "R3: the note is SC's and BCC's only, and the facts read the same words");
  }

  // 4d. The job parse: a live type with organic is refused; a region density outside
  // the TYPE's band (but inside octet's) is refused, naming the type.
  {
    auto job = [](const std::string& topo) {
      return std::string(R"({
  "model": "part.step", "material": "PLA", "mode": "minimize_plastic", "resolution": 48,
  "output": { "report": "report.json", "mesh_format": "3mf", "mesh_prefix": "variant" },
  "grading": { "topology": ")") + topo + R"(", "cell_mm": 3.0, "min_extrudable_width_mm": 0.4,
               "algorithm": "organic", "intent": "aesthetic" },
  "loads": { "anchor_face_ids": [8], "groups": [ { "face_ids": [0], "force": [0,0,-50] } ] }
})";
    };
    // Positive control: the identical job with octet parses, so the refusal below is
    // about the type and nothing else.
    CHECK(parse_job(job("octet")).grading.algorithm == "organic",
          "job: organic with octet parses (control)");
    bool threw = false;
    try { (void)parse_job(job("fcc")); } catch (const JobError& e) {
      threw = std::string(e.what()).find("only with \"topology\": \"octet\"") != std::string::npos;
    }
    CHECK(threw, "job: organic with fcc is refused, saying why");

    // The two topology keys must still agree, now that a second type is live.
    bool conflict = false;
    try {
      (void)parse_job(R"({
  "model": "part.step", "material": "PLA", "mode": "minimize_plastic", "resolution": 48,
  "output": { "report": "report.json", "mesh_format": "3mf", "mesh_prefix": "variant" },
  "lattice": { "topology": "octet" },
  "grading": { "topology": "fcc", "cell_mm": 3.0, "min_extrudable_width_mm": 0.4 },
  "loads": { "anchor_face_ids": [8], "groups": [ { "face_ids": [0], "force": [0,0,-50] } ] }
})");
    } catch (const JobError& e) {
      const std::string w = e.what();
      conflict = w.find("\"octet\"") != std::string::npos && w.find("\"fcc\"") != std::string::npos;
    }
    CHECK(conflict, "job: lattice octet with grading fcc is refused, naming both");

    // A region density inside OCTET's band but outside FCC's is refused for FCC, by
    // name, and parses for octet (the control).
    auto region_job = [](const std::string& topo) {
      return std::string(R"({
  "model": "part.step", "material": "PLA", "mode": "minimize_plastic", "resolution": 48,
  "output": { "report": "report.json", "mesh_format": "3mf", "mesh_prefix": "variant" },
  "lattice": { "topology": ")") + topo + R"(", "regions": [ { "role": "include", "kind": "face",
     "relative_density": 0.07,
     "geometry": { "origin": [0,0,0], "normal": [0,0,1], "half_u_mm": 5, "half_w_mm": 5,
                   "depth_mm": 4 } } ] },
  "grading": { "topology": ")" + topo + R"(", "cell_mm": 3.0, "min_extrudable_width_mm": 0.4 },
  "loads": { "anchor_face_ids": [8], "groups": [ { "face_ids": [0], "force": [0,0,-50] } ] }
})";
    };
    bool octet_ok = true;
    try { (void)parse_job(region_job("octet")); } catch (const JobError& e) {
      octet_ok = false;
      std::printf("  (region control refused: %s)\n", e.what());
    }
    CHECK(octet_ok, "job: a region density of 0.07 parses for octet (control)");
    bool band = false;
    try { (void)parse_job(region_job("fcc")); } catch (const JobError& e) {
      band = std::string(e.what()).find("fcc's certifiable band") != std::string::npos;
    }
    CHECK(band, "job: the same region density is refused for fcc, naming its band");

    // R4 at the parse: a live type whose Doubled verdict is NOT a pass is refused a swept
    // grade, with the verdict's own words; one that passed parses. (Fit lays the same
    // ladder and goes through the same check in job.cpp; its job needs declared regions,
    // so it is not rebuilt here.)
    for (const std::string& gid : lattice_gen_topology_names()) {
      const LatticeTopology tt = lattice_topology_from_id(gid);
      const LatticeOption dv = lattice_type_doubled(tt);
      for (const char* mode : {"swept"}) {
        const std::string j = std::string(R"({
  "model": "part.step", "material": "PLA", "mode": "minimize_plastic", "resolution": 48,
  "output": { "report": "report.json", "mesh_format": "3mf", "mesh_prefix": "variant" },
  "grading": { "topology": ")") + gid + R"(", "min_extrudable_width_mm": 0.4,
               "cell_mode": ")" + mode + R"(", "cell_min_mm": 2.0, "cell_max_mm": 8.0 },
  "loads": { "anchor_face_ids": [8], "groups": [ { "face_ids": [0], "force": [0,0,-50] } ] }
})";
        bool refused = false;
        std::string why;
        try { (void)parse_job(j); } catch (const JobError& e) { refused = true; why = e.what(); }
        CHECK(refused != dv.allowed && (dv.allowed || why.find(dv.reason) != std::string::npos),
              (gid + " " + mode + ": parse follows the Doubled verdict" +
               (refused && dv.allowed ? " (unexpected refusal: " + why + ")" : ""))
                  .c_str());
      }
    }
  }

  std::printf("\n%s: %d checks, %d failures\n", g_failures == 0 ? "PASS" : "FAIL", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
