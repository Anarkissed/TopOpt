#include "topopt/flexible/recommend.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/flexible/squish.hpp"

namespace topopt {
namespace flexible {
namespace {

std::string fmt(double v, const char* f = "%.3g") {
  char b[40];
  std::snprintf(b, sizeof(b), f, v);
  return b;
}

std::string deg(double t) { return fmt(t, "%g") + " \xC2\xB0""C"; }

std::string label(const Candidate& c) { return c.topology + " at " + deg(c.temp_c); }

FaceFailure failure_of(const Stack& st, const FaceDesign& d, const Candidate& c) {
  FaceFailure f;
  f.face_region_id = st.face_region_id;
  f.topology = c.topology;
  f.temp_c = c.temp_c;
  bool first = true, nearest_first = true;
  for (std::size_t k = 0; k < d.columns.size(); ++k) {
    const ColumnDesign& cd = d.columns[k];
    const bool bad = cd.status == "too_firm" || cd.status == "too_soft" || cd.status == "beyond_data";
    if (!bad) continue;
    if (cd.status == "too_firm") ++f.too_firm;
    if (cd.status == "too_soft") ++f.too_soft;
    if (cd.status == "beyond_data") ++f.beyond_data;
    const StackColumn& sc = st.columns[k];
    if (first) {
      f.u_min_mm = f.u_max_mm = sc.u_mm;
      f.v_min_mm = f.v_max_mm = sc.v_mm;
      first = false;
    }
    f.u_min_mm = std::min(f.u_min_mm, sc.u_mm);
    f.u_max_mm = std::max(f.u_max_mm, sc.u_mm);
    f.v_min_mm = std::min(f.v_min_mm, sc.v_mm);
    f.v_max_mm = std::max(f.v_max_mm, sc.v_mm);
    if (cd.nearest_known) {
      if (nearest_first) {
        f.nearest_depth_min_mm = f.nearest_depth_max_mm = cd.nearest_depth_mm;
        nearest_first = false;
      }
      f.nearest_known = true;
      f.nearest_depth_min_mm = std::min(f.nearest_depth_min_mm, cd.nearest_depth_mm);
      f.nearest_depth_max_mm = std::max(f.nearest_depth_max_mm, cd.nearest_depth_mm);
    }
  }
  std::string what;
  if (f.too_firm)
    what += std::to_string(f.too_firm) + " columns cannot squish that deep (even the softest "
            "lattice is too firm)";
  if (f.too_soft)
    what += std::string(what.empty() ? "" : "; ") + std::to_string(f.too_soft) +
            " columns cannot stay that shallow (even the firmest squishes further)";
  if (f.beyond_data)
    what += std::string(what.empty() ? "" : "; ") + std::to_string(f.beyond_data) +
            " columns ask for more squish than the tests measured";
  f.text = label(c) + ", face " + std::to_string(f.face_region_id) + ": " + what + ", at u " +
           fmt(f.u_min_mm) + "-" + fmt(f.u_max_mm) + " mm, v " + fmt(f.v_min_mm) + "-" +
           fmt(f.v_max_mm) + " mm" +
           (f.nearest_known ? "; nearest achievable there " + fmt(f.nearest_depth_min_mm) + "-" +
                                  fmt(f.nearest_depth_max_mm) + " mm"
                            : "; the nearest achievable squish is itself past the data");
  return f;
}

// Order two candidates by the tiebreaks; returns the code that decided, "" if tied.
std::string tiebreak(const Candidate& a, const Candidate& b, bool& a_wins) {
  if (a.near_edge_columns != b.near_edge_columns) {
    a_wins = a.near_edge_columns < b.near_edge_columns;
    return "tiebreak_near_edge";
  }
  if (std::fabs(a.material_volume_mm3 - b.material_volume_mm3) >
      1e-9 * std::max(a.material_volume_mm3, b.material_volume_mm3)) {
    a_wins = a.material_volume_mm3 < b.material_volume_mm3;
    return "tiebreak_material";
  }
  if (a.insideness != b.insideness) {
    a_wins = a.insideness > b.insideness;
    return "tiebreak_inside_data";
  }
  a_wins = true;  // input order
  return "";
}

}  // namespace

Recommendation recommend(const FlexibleData& data, const std::string& material_id,
                         const std::vector<double>& temps,
                         const std::vector<std::string>& topologies, const std::string& feel,
                         int beads_per_wall, double bead_width_mm,
                         const std::vector<FaceRequest>& faces) {
  if (feel != "springy" && feel != "damped")
    throw FlexibleError("feel must be \"springy\" or \"damped\" (got \"" + feel + "\")");
  for (const std::string& t : topologies)
    if (t != "gyroid" && t != "honeycomb")
      throw FlexibleError("topology must be \"gyroid\" or \"honeycomb\" (got \"" + t + "\")");
  if (faces.empty()) throw FlexibleError("recommend: at least one loaded face is required");
  Recommendation r;
  r.feel = feel;
  const std::string preferred = feel == "springy" ? "gyroid" : "honeycomb";

  std::vector<int> side_faces;
  for (const FaceRequest& f : faces)
    if (f.stack->frame.side) side_faces.push_back(f.stack->face_region_id);

  for (const std::string& topo : topologies)
    for (double t : temps) {
      Candidate c;
      c.topology = topo;
      c.temp_c = t;
      if (topo == "honeycomb" && !side_faces.empty()) {
        c.eligible = false;
        c.refusal = Refusal{"honeycomb_side_stack",
                            "honeycomb is only tested pushed along its prisms (build Z "
                            "\xC2\xB1""15\xC2\xB0""); face " + std::to_string(side_faces[0]) +
                                " is pushed from the side, so it is gyroid-only (R6)"};
        r.candidates.push_back(c);
        continue;
      }
      const CurveSetResult cs = curve_set(data, material_id, t, topo);
      if (cs.refusal.refused()) {
        c.refusal = cs.refusal;
        r.candidates.push_back(c);
        continue;
      }
      c.has_data = true;
      const BuildParams build{topo, beads_per_wall, bead_width_mm};
      const double span = cs.set.density_max() - cs.set.density_min();
      double inside = 0.0;
      int n = 0;
      for (const FaceRequest& f : faces) {
        const TierBand tier = tier_band(data.catalogue.error_bands, cs.set.tier,
                                        f.stack->frame.side, beads_per_wall);
        const FaceDesign d = design_face(cs.set, *f.stack, f.map, f.weight_n, f.design_stamp,
                                         build, tier);
        const int bad = d.too_firm + d.too_soft + d.beyond_data;
        c.unreachable_columns += bad;
        c.near_edge_columns += d.near_edge;
        c.material_volume_mm3 += d.material_volume_mm3;
        for (const ColumnDesign& cd : d.columns) {
          if (cd.status == "no_lattice") continue;
          inside += std::min(cd.buildable_density - cs.set.density_min(),
                             cs.set.density_max() - cd.buildable_density) / span;
          ++n;
        }
        if (bad > 0) c.failures.push_back(failure_of(*f.stack, d, c));
      }
      c.insideness = n > 0 ? inside / n : 0.0;
      c.reachable = c.unreachable_columns == 0;
      r.candidates.push_back(c);
    }

  for (const Candidate& c : r.candidates)
    if (!c.eligible) {
      r.reasons.push_back({c.refusal.code, c.refusal.reason, side_faces.empty() ? -1 : side_faces[0]});
      break;
    }

  std::vector<const Candidate*> with_data, reach;
  for (const Candidate& c : r.candidates) {
    if (c.has_data) with_data.push_back(&c);
    if (c.has_data && c.reachable) reach.push_back(&c);
  }
  if (with_data.empty()) {
    for (const Candidate& c : r.candidates)
      if (c.eligible && c.refusal.refused()) {
        r.reasons.push_back({c.refusal.code, c.refusal.reason, -1});
        break;
      }
    r.sentence = "No recommendation: " +
                 (r.reasons.empty() ? std::string("no candidate has data") : r.reasons.back().text);
    return r;
  }

  // Step 3: the feel, among what reaches (or, if nothing reaches, among everything).
  std::vector<const Candidate*> pool = reach.empty() ? with_data : reach;
  if (reach.empty()) {
    // the closest: fewest unreachable columns first
    int best = pool.front()->unreachable_columns;
    for (const Candidate* c : pool) best = std::min(best, c->unreachable_columns);
    std::vector<const Candidate*> keep;
    for (const Candidate* c : pool)
      if (c->unreachable_columns == best) keep.push_back(c);
    pool = keep;
  }
  std::vector<const Candidate*> fam;
  for (const Candidate* c : pool)
    if (c->topology == preferred) fam.push_back(c);
  const std::string other = preferred == "gyroid" ? "honeycomb" : "gyroid";
  if (!fam.empty()) {
    bool other_weighed = false;
    for (const Candidate& c : r.candidates)
      if (c.topology == other) other_weighed = true;
    if (other_weighed)
      r.reasons.push_back({feel == "springy" ? "feel_springy_prefers_gyroid"
                                             : "feel_damped_prefers_honeycomb",
                           feel == "springy"
                               ? "springy: gyroid has the smallest loss and the best recovery "
                                 "(Chatpun 2025, Beloshenko 2021)"
                               : "damped: honeycomb has the larger loading/unloading loop "
                                 "(Chatpun 2025, Beloshenko 2021)",
                           -1});
    // Say why the other family lost when it was weighed on the data and missed.
    int other_best = -1;
    for (const Candidate& c : r.candidates)
      if (c.topology == other && c.eligible && c.has_data && !c.reachable &&
          (other_best < 0 || c.unreachable_columns < other_best))
        other_best = c.unreachable_columns;
    bool other_reaches = false;
    for (const Candidate* c : reach)
      if (c->topology == other) other_reaches = true;
    if (other_best >= 0 && !other_reaches && !reach.empty())
      r.reasons.push_back({"other_family_unreachable",
                           other + " cannot meet the map here (at best " +
                               std::to_string(other_best) + " columns out of reach)",
                           -1});
    pool = fam;
  } else if (!reach.empty()) {
    // The preferred family lost on the DATA (weighed and out of reach) or was never
    // eligible (its reason is already stated above); say which.
    bool preferred_weighed = false, preferred_eligible = false;
    for (const Candidate& c : r.candidates)
      if (c.topology == preferred) {
        preferred_weighed = true;
        if (c.eligible && c.has_data) preferred_eligible = true;
      }
    if (preferred_eligible)
      r.reasons.push_back({"only_family_reachable",
                           preferred + " (the " + feel + " choice) cannot meet the map here, so " +
                               pool.front()->topology + " is the only family that can",
                           -1});
    else if (preferred_weighed)
      r.reasons.push_back({"preferred_family_ineligible",
                           preferred + " (the " + feel + " choice) is not available for this "
                           "part, so " + pool.front()->topology + " is used",
                           -1});
  }

  // Step 4: tiebreaks.
  const Candidate* best = pool.front();
  std::string decided;
  for (std::size_t i = 1; i < pool.size(); ++i) {
    bool a_wins = true;
    const std::string code = tiebreak(*best, *pool[i], a_wins);
    if (!code.empty()) decided = code;
    if (!a_wins) best = pool[i];
  }
  if (pool.size() > 1 && !decided.empty()) {
    const char* text = decided == "tiebreak_near_edge"
                           ? "fewest columns near an edge of the table"
                           : decided == "tiebreak_material" ? "the least material"
                                                            : "its densities sit furthest inside the table";
    r.reasons.push_back({decided, label(*best) + ": " + text, -1});
  }
  r.chosen = true;
  r.topology = best->topology;
  r.temp_c = best->temp_c;
  r.reachable = best->reachable;
  if (!best->reachable) {
    r.failures = best->failures;
    r.reasons.push_back({"nothing_reachable",
                         "no candidate meets every face; " + label(*best) +
                             " comes closest (" + std::to_string(best->unreachable_columns) +
                             " columns out of reach)",
                         -1});
    for (const FaceFailure& f : best->failures)
      r.reasons.push_back({"face_unreachable", f.text, f.face_region_id});
    r.sentence = "Nothing fits every face: " + label(*best) + " comes closest; " +
                 best->failures.front().text;
    return r;
  }
  if (r.candidates.size() == 1)
    r.reasons.push_back({"only_candidate", label(*best) + " is the only option weighed", -1});
  std::string why;
  for (const Reason& x : r.reasons) why += (why.empty() ? "" : "; ") + x.text;
  r.sentence = label(*best) + " - " + (why.empty() ? std::string("fits every face") : why) +
               ". Every face's squish fits inside the data.";
  return r;
}

}  // namespace flexible
}  // namespace topopt
