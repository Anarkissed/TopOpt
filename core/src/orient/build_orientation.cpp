#include "topopt/build_orientation.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <functional>
#include <string>
#include <limits>
#include <stdexcept>

#include "topopt/analyze.hpp"         // KnockdownSpec, LatticePosture, gate_margin_effective
#include "topopt/lattice_gen.hpp"     // generate_lattice + LatticeGenObserver (S-e)
#include "topopt/orient.hpp"          // support_overhang_voxels, max_interlayer_tension
#include "topopt/report.hpp"          // compute_stress_margin
#include "topopt/strut_strength.hpp"  // evaluate_strut_strength

namespace topopt {

namespace {

// Number formatting for the receipt, matching run_job's json_num: %.10g, and a
// JSON-legal spelling for the infinities a margin legitimately carries (an
// unloaded failure mode has an UNBOUNDED margin, and writing 0 there would be a
// lie). ONE emitter now serves both the CLI and the on-device bridge, so the
// receipt a user reads is the same document whichever ran the job.
std::string json_num(double v) {
  if (!std::isfinite(v)) return v > 0.0 ? "1e999" : (v < 0.0 ? "-1e999" : "null");
  char buf[40];
  std::snprintf(buf, sizeof(buf), "%.10g", v);
  return std::string(buf);
}

constexpr double kPi = 3.14159265358979323846;

double dot3(const Vec3& a, const Vec3& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}
double norm3(const Vec3& a) { return std::sqrt(dot3(a, a)); }

Vec3 unit3(const Vec3& a) {
  const double n = norm3(a);
  if (!(n > 0.0) || !std::isfinite(n))
    throw std::invalid_argument(
        "score_build_orientations: a candidate direction is zero length or "
        "non-finite");
  return Vec3{a.x / n, a.y / n, a.z / n};
}

// Exactly PR 266's predicate (probe `on_cube_axis`), so the U7 cube-axis check
// partitions the candidate set the same way the probe's S2 check did.
bool on_cube_axis(const Vec3& n) {
  const double a = std::fabs(n.x), b = std::fabs(n.y), c = std::fabs(n.z);
  return (a > 1.0 - 1e-9 && b < 1e-9 && c < 1e-9) ||
         (b > 1.0 - 1e-9 && a < 1e-9 && c < 1e-9) ||
         (c > 1.0 - 1e-9 && a < 1e-9 && b < 1e-9);
}

// ── S-e: the strut axes, MEASURED from the PRODUCTION generator ──────────────
// PR 201 reported the octet as 24/36 struts at 45 deg and 12/36 HORIZONTAL for a
// +z build. Rather than transcribe that figure, tap generate_lattice with a
// read-only observer and derive the direction population from what the real
// generator actually emits — the same instrument PR 266 used, so the production
// S-e column is comparable to the probe's to the digit.
//
// The axes are a property of the TOPOLOGY, not of the part or the cell size (PR
// 266 verified the emitted fragment count is exactly 24n^3 + 12n^2 over an n^3
// block and reduces to six <110> face diagonals carrying 1/6 of the length each,
// at n = 1, 2, 3, 4, 6, 8). So a 2^3 block measures them for any run.
constexpr int kStrutAxisProbeCells = 2;
constexpr double kStrutAxisProbeCellMm = 1.0;  // axes are scale-invariant

struct StrutAxis {
  Vec3 dir;             // unit, sign-canonicalized (a strut has an axis, not a
                        // direction)
  double length = 0.0;  // total emitted centreline length in this direction
};

struct DiscardSink : TriangleSink {
  void add_triangle(const Vec3&, const Vec3&, const Vec3&) override {}
};

std::vector<StrutAxis> measure_strut_axes(LatticeTopology topo, bool* ok) {
  *ok = false;
  // Only the octet has both a measured strut law (PR 259) and a generator route.
  // Anything else reports S-e absent rather than borrowing octet's geometry.
  if (topo != LatticeTopology::Octet) return {};

  LatticeRegion region;
  region.origin = Vec3{0.0, 0.0, 0.0};
  region.nx = region.ny = region.nz = kStrutAxisProbeCells;
  region.cell_mm = kStrutAxisProbeCellMm;
  LatticeRadiusField radius;
  radius.uniform_mm = 0.12 * kStrutAxisProbeCellMm;

  std::vector<StrutAxis> axes;
  LatticeGenObserver obs;
  obs.on_element = [&axes](LatticeGenElement kind, const Vec3& a, const Vec3& b,
                           double) {
    if (kind != LatticeGenElement::InteriorStrut) return;  // nodes are balls
    const Vec3 d{b.x - a.x, b.y - a.y, b.z - a.z};
    const double len = norm3(d);
    if (len <= 1e-12) return;
    Vec3 u{d.x / len, d.y / len, d.z / len};
    // Sign-canonicalize: a strut axis is undirected, so +u and -u are one family.
    if (u.x < -1e-12 || (std::fabs(u.x) <= 1e-12 &&
                         (u.y < -1e-12 || (std::fabs(u.y) <= 1e-12 && u.z < 0))))
      u = Vec3{-u.x, -u.y, -u.z};
    for (StrutAxis& s : axes)
      if (std::fabs(dot3(s.dir, u)) > 1.0 - 1e-9) {
        s.length += len;
        return;
      }
    axes.push_back(StrutAxis{u, len});
  };

  DiscardSink sink;
  generate_lattice(LatticeGenTopology::Octet, region, radius, sink,
                   LatticeSkinSpec{}, &obs);
  // Deterministic ordering (longest family first) so the S-e numbers do not
  // depend on the generator's traversal order.
  std::stable_sort(axes.begin(), axes.end(),
                   [](const StrutAxis& a, const StrutAxis& b) {
                     return a.length > b.length;
                   });
  *ok = !axes.empty();
  return axes;
}

// Elevation of each strut family above the build plate for build direction `n`:
// phi = asin(|axis . n|). phi == 0 is a HORIZONTAL bridge (categorically needs
// support the lattice interior cannot give it); phi == 90 is a vertical column.
void strut_angles(const std::vector<StrutAxis>& axes, const Vec3& n,
                  OrientationCriteria* out) {
  double total_len = 0.0, horiz_len = 0.0, wsum = 0.0;
  double min_phi = 90.0;
  for (const StrutAxis& s : axes) {
    double c = std::fabs(dot3(s.dir, n));
    if (c > 1.0) c = 1.0;
    const double phi = std::asin(c) * 180.0 / kPi;
    total_len += s.length;
    if (phi <= kHorizontalStrutDeg + 1e-9) horiz_len += s.length;
    if (phi < min_phi) min_phi = phi;
    wsum += phi * s.length;
  }
  if (!(total_len > 0.0)) return;
  out->strut_angles_evaluated = true;
  out->horizontal_strut_length_fraction = horiz_len / total_len;
  out->flattest_strut_deg = min_phi;
  out->mean_strut_deg = wsum / total_len;
}

// ── S-f: the two build-frame printability numbers ────────────────────────────
// Layer count and first-layer footprint both move with `n` and both cost real
// print time / plate-adhesion risk. Min-feature (the V3 gate) does NOT move at
// all and is carried through unchanged to show that. Verbatim PR 266's
// build_frame_metrics.
void build_frame_metrics(const VoxelGrid& printed, const Vec3& n, int* height,
                         int* footprint) {
  double lo = std::numeric_limits<double>::infinity();
  double hi = -std::numeric_limits<double>::infinity();
  std::vector<double> s;
  s.reserve(printed.voxel_count());
  for (int k = 0; k < printed.nz; ++k)
    for (int j = 0; j < printed.ny; ++j)
      for (int i = 0; i < printed.nx; ++i) {
        if (!printed.solid(i, j, k)) continue;
        const double v = ((i + 0.5) * n.x + (j + 0.5) * n.y + (k + 0.5) * n.z) *
                         printed.spacing;
        s.push_back(v);
        lo = std::min(lo, v);
        hi = std::max(hi, v);
      }
  if (s.empty()) {
    *height = 0;
    *footprint = 0;
    return;
  }
  *height = static_cast<int>(std::ceil((hi - lo) / printed.spacing)) + 1;
  int fp = 0;
  for (double v : s)
    if (v - lo <= printed.spacing + 1e-9) ++fp;
  *footprint = fp;
}

// ── the recommendation: MAXIMIN over the MOVING criteria ─────────────────────
// Each moving criterion is normalized to [0,1] over the candidate set (1 = best
// on that criterion) and a candidate is ranked by its WORST standing. This is
// PR 266's rule, and it is deliberately NOT presented as "the score": a weighted
// sum would launder the trade-off (S-e opposes S-d, and the gated worst-case
// margin saturates) into one number that hides where the criteria disagree.
// A criterion that does not move over the set contributes 1.0 to every candidate
// and so cannot decide anything — which is exactly right for S-c.
struct Span {
  double lo = std::numeric_limits<double>::infinity();
  double hi = -std::numeric_limits<double>::infinity();
};

Span span_of(const std::vector<OrientationCriteria>& rows,
             const std::function<double(const OrientationCriteria&)>& get) {
  Span s;
  for (const OrientationCriteria& r : rows) {
    const double v = get(r);
    if (!std::isfinite(v)) continue;  // an unloaded mode's +inf margin carries
                                      // no preference; ignore it in the span
    s.lo = std::min(s.lo, v);
    s.hi = std::max(s.hi, v);
  }
  return s;
}

double normalized_standing(double v, const Span& s, bool lower_is_better) {
  if (!std::isfinite(v)) return 1.0;              // unloaded mode: best possible
  if (!(s.hi - s.lo > 0.0)) return 1.0;           // criterion does not move
  const double t = (v - s.lo) / (s.hi - s.lo);
  return lower_is_better ? 1.0 - t : t;           // 1 = best, 0 = worst
}

}  // namespace

BuildOrientationReport score_build_orientations(
    const BuildOrientationSolveFacts& facts,
    const std::vector<Vec3>& candidates, const Vec3& as_built,
    const Material& material, const KnockdownSpec& knockdown, double margin_stop,
    bool load_path_ok, bool inferred) {
  if (candidates.empty())
    throw std::invalid_argument(
        "score_build_orientations: the candidate set is empty");

  BuildOrientationReport rep;
  rep.evaluated = true;
  rep.build_direction_inferred = inferred;

  // The strut criteria need BOTH a posture and a topology with a measured law.
  const bool has_lattice =
      facts.lattice != nullptr && facts.lattice_mask != nullptr &&
      facts.lattice_voxels > 0 &&
      facts.lattice->topology == LatticeTopology::Octet;

  // S-e's instrument: ONE generator tap for the whole report, not one per
  // candidate. Timed separately from the sweep so bar U3's comparison against
  // PR 266's 0.5 / 1.6 ms is like-for-like.
  std::vector<StrutAxis> axes;
  bool axes_ok = false;
  {
    const auto t0 = std::chrono::steady_clock::now();
    if (has_lattice) axes = measure_strut_axes(facts.lattice->topology, &axes_ok);
    rep.strut_axis_measure_seconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
            .count();
  }

  // ── THE SWEEP. Every candidate, against the ONE solved field. No re-solve. ──
  const auto sweep_t0 = std::chrono::steady_clock::now();
  rep.candidates.reserve(candidates.size());
  for (const Vec3& raw : candidates) {
    const Vec3 n = unit3(raw);
    OrientationCriteria r;
    r.build_dir = n;
    r.on_cube_axis = on_cube_axis(n);

    // S-a — the PRODUCTION support proxy (orient.cpp), on the printed geometry.
    r.support_voxels = support_overhang_voxels(facts.printed_grid, n);

    // S-b — the PRODUCTION macro interlayer term and the PRODUCTION margin
    // definition. The in-plane term does not move with n; only this one does.
    r.macro_interlayer_tension_mpa =
        max_interlayer_tension(facts.grid, facts.stress, n);
    const StressMargin m = compute_stress_margin(
        material.yield_strength_mpa, material.z_knockdown, facts.max_von_mises,
        r.macro_interlayer_tension_mpa);
    r.macro_interlayer_margin = m.interlayer;
    r.macro_worst_case_margin = m.worst_case;
    // The GATE's number at this orientation, via THE ONE gate expression the
    // real verdict used. Reported; never assigned back to the analysis.
    r.margin_effective = gate_margin_effective(
        material.yield_strength_mpa, material.z_knockdown, facts.max_von_mises,
        knockdown.width_aware ? facts.max_von_mises_effective
                              : facts.max_von_mises,
        r.macro_interlayer_tension_mpa, knockdown);
    r.would_be_accepted = load_path_ok && (r.margin_effective >= margin_stop);

    // S-c / S-d — PR 263's callable evaluator, whose build direction is an
    // EXPLICIT parameter precisely so a scorer can call it N times against one
    // field (its bar L8). NOT reimplemented here.
    if (has_lattice) {
      const StrutStrengthReport sr = evaluate_strut_strength(
          facts.stress_tensor_field, *facts.lattice_mask,
          facts.lattice->relative_density, n, material.yield_strength_mpa,
          material.z_knockdown);
      r.strut_evaluated = sr.evaluated;
      r.strut_in_plane_margin = sr.margin_in_plane;
      r.strut_interlayer_margin = sr.margin_interlayer;
      r.strut_il_bound_mpa = sr.il_bound_max_mpa;
      r.strut_il_cross_factor = sr.il_cross_factor;
    }

    // S-e — the strut-angle population for this orientation.
    if (axes_ok) strut_angles(axes, n, &r);

    // S-f — printability. min-feature is carried from the V3 suite that already
    // ran; it is direction-INVARIANT and is reported to show that.
    r.min_feature_violations = facts.min_feature_violations;
    build_frame_metrics(facts.printed_grid, n, &r.build_height_layers,
                        &r.first_layer_footprint_voxels);

    rep.candidates.push_back(r);
  }
  rep.sweep_seconds =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - sweep_t0)
          .count();

  // ── locate the AS-BUILT row. U5 rests on this: the report must be able to
  // point at the orientation the verdict actually describes. ──────────────────
  const Vec3 built = unit3(as_built);
  bool found = false;
  for (std::size_t i = 0; i < rep.candidates.size(); ++i)
    if (dot3(rep.candidates[i].build_dir, built) > 1.0 - 1e-9) {
      rep.as_built_index = i;
      found = true;
      break;
    }
  if (!found)
    throw std::invalid_argument(
        "score_build_orientations: the as-built direction is not in the "
        "candidate set — the report could not state which orientation the "
        "verdict describes");

  // ── U7 SELF-CHECKS, in production. PR 266's S2 invariants. ─────────────────
  if (has_lattice) {
    const double ip0 = rep.candidates.front().strut_in_plane_margin;
    for (const OrientationCriteria& r : rep.candidates)
      if (r.strut_in_plane_margin != ip0) rep.strut_in_plane_invariant = false;

    const OrientationCriteria* first_axis = nullptr;
    for (const OrientationCriteria& r : rep.candidates) {
      if (!r.on_cube_axis) continue;
      ++rep.cube_axes_scored;
      if (first_axis == nullptr) {
        first_axis = &r;
        continue;
      }
      if (r.strut_interlayer_margin != first_axis->strut_interlayer_margin ||
          r.strut_il_cross_factor != 0.0)
        rep.cube_axes_strut_interlayer_identical = false;
    }
    if (first_axis != nullptr && first_axis->strut_il_cross_factor != 0.0)
      rep.cube_axes_strut_interlayer_identical = false;
  } else {
    for (const OrientationCriteria& r : rep.candidates)
      if (r.on_cube_axis) ++rep.cube_axes_scored;
  }

  // ── THE RECOMMENDATION (maximin over the moving criteria) ──────────────────
  const auto get_support = [](const OrientationCriteria& r) {
    return static_cast<double>(r.support_voxels);
  };
  const auto get_macro_il = [](const OrientationCriteria& r) {
    return r.macro_interlayer_margin;
  };
  const auto get_strut_il = [](const OrientationCriteria& r) {
    return r.strut_interlayer_margin;
  };
  const auto get_horiz = [](const OrientationCriteria& r) {
    return r.horizontal_strut_length_fraction;
  };
  const Span sa = span_of(rep.candidates, get_support);
  const Span sb = span_of(rep.candidates, get_macro_il);
  const Span sd = span_of(rep.candidates, get_strut_il);
  const Span se = span_of(rep.candidates, get_horiz);
  const auto standing = [&](const OrientationCriteria& r) {
    double worst = std::min(normalized_standing(get_support(r), sa, true),
                            normalized_standing(get_macro_il(r), sb, false));
    // The strut criteria join the maximin only when they were evaluated. With no
    // lattice they are absent, not zero — folding an unevaluated 0.0 in would
    // make every candidate tie at the bottom and silently disable the ranking.
    if (r.strut_evaluated)
      worst = std::min(worst, normalized_standing(get_strut_il(r), sd, false));
    if (r.strut_angles_evaluated)
      worst = std::min(worst, normalized_standing(get_horiz(r), se, true));
    return worst;
  };
  rep.recommended_index = 0;
  double best = standing(rep.candidates.front());
  for (std::size_t i = 1; i < rep.candidates.size(); ++i) {
    const double v = standing(rep.candidates[i]);
    if (v > best) {  // strict: ties keep the earlier candidate, and the as-built
      best = v;      // row is candidate 0, so a tie never displaces what was built
      rep.recommended_index = i;
    }
  }

  rep.recommendation_differs = rep.recommended_index != rep.as_built_index;
  // *** U5: the recommendation is priced against the verdict that actually
  // stands. This FLAG is the receipt's trigger to print both. ***
  rep.verdict_would_change =
      rep.candidates[rep.recommended_index].would_be_accepted !=
      rep.candidates[rep.as_built_index].would_be_accepted;
  return rep;
}

// ── THE BUILD-ORIENTATION RECEIPT (handoff 2026-08-01-build-direction-separation)
// A SEPARATE document, written only when the scorer was armed, so report.json /
// fields.bin / the meshes stay byte-identical whether it ran or not (bar U1).
//
// U5 IS THIS FUNCTION'S REASON TO EXIST. It states, in one place and in plain
// terms: which orientation the verdict describes, whether that orientation was
// DECLARED or ASSUMED from gravity, what the recommendation is, and — when the
// two would gate differently — BOTH verdicts side by side. It does not choose.
// Nothing downstream reads this to decide anything; a human does.
std::string build_orientation_report_json(const BuildOrientationReport& r,
                                          const Vec3& as_built_dir) {
  if (!r.evaluated || r.candidates.empty())
    throw std::invalid_argument(
        "build_orientation_report_json: the report was never evaluated");
  auto dir_json = [](const Vec3& v) {
    return "[" + json_num(v.x) + ", " + json_num(v.y) + ", " + json_num(v.z) +
           "]";
  };
  const OrientationCriteria& built = r.candidates[r.as_built_index];
  const OrientationCriteria& rec = r.candidates[r.recommended_index];

  std::string s = "{\n";
  s += "  \"_note\": \"A RECOMMENDATION. The verdict in report.json is computed "
       "from the orientation ACTUALLY USED (as_built below) and is never "
       "recomputed from the recommendation. If they disagree, both are stated "
       "and the choice is yours.\",\n";
  s += "  \"as_built\": {\n";
  s += "    \"build_direction\": " + dir_json(as_built_dir) + ",\n";
  // PR 266's S5 point 3: a fallback that is not reported is a lie by omission.
  s += "    \"source\": \"" +
       std::string(r.build_direction_inferred ? "assumed_from_gravity"
                                              : "declared") +
       "\",\n";
  s += "    \"margin_effective\": " + json_num(built.margin_effective) + ",\n";
  s += "    \"verdict\": \"" +
       std::string(built.would_be_accepted ? "ACCEPTED" : "REJECTED") + "\"\n";
  s += "  },\n";
  s += "  \"recommended\": {\n";
  s += "    \"build_direction\": " + dir_json(rec.build_dir) + ",\n";
  s += "    \"differs_from_as_built\": " +
       std::string(r.recommendation_differs ? "true" : "false") + ",\n";
  s += "    \"margin_effective\": " + json_num(rec.margin_effective) + ",\n";
  s += "    \"verdict\": \"" +
       std::string(rec.would_be_accepted ? "ACCEPTED" : "REJECTED") + "\",\n";
  s += "    \"rule\": \"maximin over the MOVING criteria, each normalized over "
       "the candidate set. Deliberately not a weighted sum: the criteria "
       "genuinely disagree and one collapsed number would hide where.\"\n";
  s += "  },\n";
  // *** The sentence U5 asks for, pre-composed so no front-end has to compose
  // it and risk composing it differently. ***
  s += "  \"verdict_would_change\": " +
       std::string(r.verdict_would_change ? "true" : "false") + ",\n";
  s += "  \"statement\": \"";
  if (r.verdict_would_change) {
    s += std::string("as built: ") +
         (built.would_be_accepted ? "ACCEPTED" : "REJECTED") +
         "; as recommended: " +
         (rec.would_be_accepted ? "ACCEPTED" : "REJECTED") +
         ". THE VERDICT THAT STANDS IS THE AS-BUILT ONE. Re-run with this "
         "build_direction to certify the recommended orientation.";
  } else if (r.recommendation_differs) {
    s += "a different orientation scores better on the criteria below, but the "
         "gate verdict is the same either way.";
  } else {
    s += "the orientation used is also the recommended one.";
  }
  s += "\",\n";
  // U7 — PR 266's invariants, checked in PRODUCTION and reported, so a drift is
  // visible on a real run and not only in a unit test.
  s += "  \"self_checks\": {\"strut_in_plane_invariant\": " +
       std::string(r.strut_in_plane_invariant ? "true" : "false") +
       ", \"cube_axes_strut_interlayer_identical\": " +
       std::string(r.cube_axes_strut_interlayer_identical ? "true" : "false") +
       ", \"cube_axes_scored\": " + std::to_string(r.cube_axes_scored) + "},\n";
  // U3 — the measured cost, on this build, in this run.
  s += "  \"sweep_seconds\": " + json_num(r.sweep_seconds) +
       ", \"strut_axis_measure_seconds\": " +
       json_num(r.strut_axis_measure_seconds) + ",\n";
  // THE SIX CRITERIA, ONE ROW PER CANDIDATE, NEVER COLLAPSED (bar U6).
  s += "  \"criteria\": [\"S-a support_voxels\", \"S-b macro interlayer "
       "margin\", \"S-c strut in-plane margin\", \"S-d strut interlayer "
       "margin\", \"S-e horizontal strut fraction\", \"S-f printability "
       "(layers, footprint, min-feature)\"],\n";
  s += "  \"candidates\": [\n";
  for (std::size_t i = 0; i < r.candidates.size(); ++i) {
    const OrientationCriteria& c = r.candidates[i];
    s += "    {\"build_direction\": " + dir_json(c.build_dir);
    s += ", \"on_cube_axis\": " + std::string(c.on_cube_axis ? "true" : "false");
    s += ", \"is_as_built\": " +
         std::string(i == r.as_built_index ? "true" : "false");
    s += ", \"is_recommended\": " +
         std::string(i == r.recommended_index ? "true" : "false");
    s += ", \"support_voxels\": " + std::to_string(c.support_voxels);
    s += ", \"macro_interlayer_tension_mpa\": " +
         json_num(c.macro_interlayer_tension_mpa);
    s += ", \"macro_interlayer_margin\": " + json_num(c.macro_interlayer_margin);
    s += ", \"macro_worst_case_margin\": " + json_num(c.macro_worst_case_margin);
    s += ", \"margin_effective\": " + json_num(c.margin_effective);
    s += ", \"would_be_accepted\": " +
         std::string(c.would_be_accepted ? "true" : "false");
    s += ", \"strut_evaluated\": " +
         std::string(c.strut_evaluated ? "true" : "false");
    if (c.strut_evaluated) {
      s += ", \"strut_in_plane_margin\": " + json_num(c.strut_in_plane_margin);
      s += ", \"strut_interlayer_margin\": " +
           json_num(c.strut_interlayer_margin);
      s += ", \"strut_interlayer_bound_mpa\": " + json_num(c.strut_il_bound_mpa);
      s += ", \"strut_interlayer_cross_factor\": " +
           json_num(c.strut_il_cross_factor);
    }
    if (c.strut_angles_evaluated) {
      s += ", \"horizontal_strut_length_fraction\": " +
           json_num(c.horizontal_strut_length_fraction);
      s += ", \"flattest_strut_deg\": " + json_num(c.flattest_strut_deg);
      s += ", \"mean_strut_deg\": " + json_num(c.mean_strut_deg);
    }
    s += ", \"min_feature_violations\": " +
         std::to_string(c.min_feature_violations);
    s += ", \"build_height_layers\": " + std::to_string(c.build_height_layers);
    s += ", \"first_layer_footprint_voxels\": " +
         std::to_string(c.first_layer_footprint_voxels);
    s += "}";
    if (i + 1 < r.candidates.size()) s += ",";
    s += "\n";
  }
  s += "  ]\n";
  s += "}\n";
  return s;
}


}  // namespace topopt
