// Lattice rebuild, stage E: what the app holds for one part (rule P2). See lattice_layout.hpp.
#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_organic.hpp"

#include <algorithm>
#include <set>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <typeinfo>
#if defined(__has_include)
#if __has_include(<cxxabi.h>)
#include <cxxabi.h>
#define TOPOPT_SB1_CXXABI 1
#endif
#endif

namespace topopt::lattice_layout {

// SB1 (leg Q): the refusal for an exception that is not a std::exception, its type named for the log.
OrganicRefusal core_stopped(const std::string& what) {
  OrganicRefusal r;
  r.code = "core_stopped";
  r.text = what + ": the engine stopped on an internal error. Try again; if it happens again, the log says what it was.";
  std::string type = "an exception of a type that cannot be named";
#ifdef TOPOPT_SB1_CXXABI
  if (const std::type_info* t = abi::__cxa_current_exception_type()) {
    int st = 0;
    char* d = abi::__cxa_demangle(t->name(), nullptr, nullptr, &st);
    type = std::string("a ") + (d ? d : t->name());
    std::free(d);
  }
#endif
  r.detail = type + " was thrown and is not a std::exception";
  return r;
}
namespace {
double ms_since(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}
// Every setting that decides WHERE lattice goes, written out exactly: two settings with
// the same text read the part the same way.
std::string where_text(const Settings& s) {
  std::string out;
  char buf[96];
  auto num = [&](double v) { std::snprintf(buf, sizeof buf, "%.17g,", v); out += buf; };
  auto whole = [&](long v) { std::snprintf(buf, sizeof buf, "%ld,", v); out += buf; };
  // D22: every piece, its faces and every number of its cuts, so a moved cut reads the part
  // again. Nothing is written for an ask with no pieces.
  auto pieces = [&](const std::vector<FacePiece>& list) {
    if (list.empty()) return;
    out += "Q";
    for (const FacePiece& p : list) {
      out += "F";
      for (int f : p.faces) whole(f);
      for (const FaceCut& c : p.cuts) {
        out += "C";
        num(c.point.x); num(c.point.y); num(c.point.z);
        num(c.normal.x); num(c.normal.y); num(c.normal.z);
        whole(c.strict ? 1 : 0);
      }
    }
  };
  whole(static_cast<long>(s.start));
  num(s.bead_mm); num(s.min_strut_lines); num(s.min_wall_mm); num(s.rim_mm); num(s.cover_mm);
  if (s.bed_floor_mm > 0.0) {   // K1 (written only when on: with no floor the text is as it was)
    out += "F";
    num(s.bed_floor_mm); num(s.bed_up.x); num(s.bed_up.y); num(s.bed_up.z);
  }
  out += "R";
  for (const Settings::RegionAsk& r : s.regions) {
    whole(r.id); whole(static_cast<long>(r.role)); num(r.depth_mm); num(r.expand_mm);
    if (r.weave) out += "w,";   // O1 (written only when on: with no weave the text is as it was)
    for (int f : r.faces) whole(f);
    pieces(r.pieces);
    // D21: every number of the zone, so a moved zone reads the part again.
    out += "Z";
    whole(static_cast<long>(r.zone.kind));
    num(r.zone.centre.x); num(r.zone.centre.y); num(r.zone.centre.z);
    for (const Vec3& a : r.zone.axis) { num(a.x); num(a.y); num(a.z); }
    for (double h : r.zone.half) num(h);
    // S13: a region's own rim and cover decide where lattice goes (its own skin does not).
    if (r.rim_mm) { out += "r"; num(*r.rim_mm); }
    if (r.cover_mm) { out += "c"; num(*r.cover_mm); }
    out += ";";
  }
  out += "P";
  for (const Settings::ProtectAsk& p : s.protect) {
    whole(p.id); num(p.depth_mm);
    if (p.chip) out += "k";   // D23: which entries are chips decides the domain read without them
    for (int f : p.faces) whole(f);
    pieces(p.pieces);
    out += ";";
  }
  return out;
}
}  // namespace

Session::Session(StepModel model) : model_(std::move(model)) {
  measure_ = std::make_unique<PartMeasure>(weld_mesh(model_.mesh, 1e-5, &open_edges_));
}

Outcome Session::lay(const Settings& settings, int threads, const std::atomic<bool>* stop) {
  try {   // SB1: nothing but a std::exception or a refusal leaves this call
  return lay_with(settings, nullptr, threads, stop);
  } catch (const LayCancelled&) {
    Outcome none;
    none.cancelled = true;
    return none;
  } catch (const std::exception&) {
    throw;
  } catch (...) {
    Outcome none;
    none.refused.push_back(core_stopped("The lattice could not be laid out"));
    return none;
  }
}

Outcome Session::lay_weave(const Settings& settings, const std::vector<Strand>& strands, int threads,
                           const std::atomic<bool>* stop) {
  return lay_with(settings, &strands, threads, stop);
}

void Session::ready_domain(const Settings& settings) {
  const std::string where = where_text(settings);
  if (!domain_ || where != where_) {
    DomainSpec spec;
    spec.start = settings.start;
    spec.bead_mm = settings.bead_mm;
    spec.min_strut_lines = settings.min_strut_lines;
    spec.min_wall_mm = settings.min_wall_mm;
    spec.rim_mm = settings.rim_mm;
    spec.cover_mm = settings.cover_mm;
    spec.bed_floor_mm = settings.bed_floor_mm;   // K1
    spec.bed_up = settings.bed_up;
    empty_regions_.clear();
    for (const Settings::RegionAsk& r : settings.regions) {
      bool ok = false;
      const bool zone = r.zone.kind != Zone::Kind::None;   // D21: a zone, in place of faces; both is refused
      const bool cut = !r.pieces.empty();                   // D22: pieces, in place of faces; with a zone refused
      Region region = zone ? (r.faces.empty() && !cut ? region_from_zone(r.zone, r.id, r.role, r.expand_mm, &ok)
                                                      : Region{})
                      : cut ? region_from_pieces(model_, r.pieces, r.id, r.role, r.depth_mm, r.expand_mm, &ok)
                            : region_from_faces(model_, r.faces, r.id, r.role, r.depth_mm, r.expand_mm, &ok);
      if (!ok) { empty_regions_.push_back(r.id); continue; }
      region.rim_mm = r.rim_mm;       // S13: its own, else the part's
      region.cover_mm = r.cover_mm;
      region.weave = r.weave;
      region.cover_open_face = r.weave && !zone;   // OJ2: an Organic area's Solid closes its open face only
      spec.regions.push_back(std::move(region));
    }
    for (const Settings::ProtectAsk& p : settings.protect)
      spec.protect.push_back({p.id, p.pieces.empty() ? faces_mesh(model_, p.faces) : pieces_mesh(model_, p.pieces),
                              p.depth_mm, p.pieces});
    // D23: with protect_chip entries, the same domain without them too (a place under a chip's answer stays listed).
    chip_ids_.clear();
    domain_no_chips_.reset();
    for (const Settings::ProtectAsk& p : settings.protect)
      if (p.chip) chip_ids_.push_back(p.id);
    if (!chip_ids_.empty()) {
      DomainSpec bare = spec;
      bare.protect.clear();
      for (std::size_t i = 0; i < settings.protect.size(); ++i)
        if (!settings.protect[i].chip) bare.protect.push_back(spec.protect[i]);
      domain_no_chips_ = std::make_unique<Domain>(*measure_, std::move(bare));
    }
    domain_ = std::make_unique<Domain>(*measure_, std::move(spec));
    where_ = where;
    unread_ = true;
    ref_kept_ = false;   // the reference is the new domain's to read again
    ref_field_.reset();
  }
}

Outcome Session::lay_with(const Settings& settings, const std::vector<Strand>* strands, int threads,
                          const std::atomic<bool>* stop, const WeaveFinish* finish) {
  Outcome out;
  const auto given_up = [] { Outcome none; none.cancelled = true; return none; };
  if (stop && stop->load(std::memory_order_relaxed)) return given_up();
  auto t0 = std::chrono::steady_clock::now();
  ready_domain(settings);
  out.read_again = unread_;   // a new domain, or one whose first reading was given up part way
  out.empty_regions = empty_regions_;
  // The domain watches the flag for this lay only (the flag need not outlive the call).
  struct Watch {
    Domain& d;
    Watch(Domain& domain, const std::atomic<bool>* s) : d(domain) { d.watch(s); }
    ~Watch() { d.watch(nullptr); }
  } watch(*domain_, stop);
  try {
    // (The reading itself happens inside the first lay_cells of a new domain.)
    CellSpec cells = settings.cells;
    // One switch for the quilt (R2). His per-part choice lets the CELLS go as small, and only the cells: the struts
    // are still set without the quilt, so a small cell carries the thinnest strut (set_struts: never under it).
    cells.allow_quilt = settings.struts.allow_quilt || settings.small_cells_in_thin_walls;
    cells.one_grid = settings.one_grid;   // "Let walls cut cells": the per-part switch is the session's
    // The stress the lattice is graded by (R16, R17), resolved ONCE, before the cells, for the cells (C22) and the
    // struts (By stress) alike: the stated reference, else the part's own, kept while the domain, the field and the
    // percentile are the same (a slider move never reads the field again). Resolved only when it is asked for: the
    // struts By stress, or cells by stress that would be applied (a field sent under Uniform is never read for it).
    const StressGrade& stress = settings.stress;
    const bool cells_want = cells.by_stress && !(cells.cell_mm > 0.0) &&
                            cells.algorithm != Algorithm::Uniform;   // C22's OFF list but for the field and the reference
    bool asked = settings.struts.mode == Density::ByStress || cells_want;
    // C23, R19: each Lattice region's own cells and struts. One that asks for the stress (its struts By stress, or its
    // cells by stress) without a reference of its own reads the part's, so the part's is resolved for it as well.
    AreaOwnMap own;
    for (const Settings::RegionAsk& r : settings.regions) {
      if (r.role != Role::Lattice || !r.own.any()) continue;
      own[r.id] = r.own;
      const CellSpec rc = region_cells(cells, r.own);
      const bool wants = (r.own.by_stress ? *r.own.by_stress : settings.struts.mode == Density::ByStress) ||
                         (rc.by_stress && !(rc.cell_mm > 0.0) && rc.algorithm != Algorithm::Uniform);
      if (wants && !(r.own.reference_mpa && *r.own.reference_mpa > 0.0)) asked = true;
    }
    const AreaOwnMap* own_or_none = own.empty() ? nullptr : &own;
    double reference = 0.0;
    if (stress.demand) {
      reference = asked ? stress.reference_mpa : 0.0;
      if (asked && !(reference > 0.0)) {
        if (!ref_kept_ || ref_field_ != stress.demand || ref_percentile_ != stress.percentile) {
          ref_kept_ = false;
          ref_mpa_ = stress_reference(*domain_, *stress.demand, stress.percentile, threads);
          ref_field_ = stress.demand;
          ref_percentile_ = stress.percentile;
          ref_kept_ = true;
        }
        reference = ref_mpa_;
      }
      cells.demand = stress.demand;
      cells.reference_mpa = reference;
      cells.response = stress.response;
    }
    out.cells_by_stress = stress_sizes_cells(cells);   // C22
    out.cells_no_stress = cells_want && (!cells.demand || cells.demand->empty() || !(cells.reference_mpa > 0.0));
    out.stress_reference_mpa = reference;
    out.step_held_at = step_held(cells);   // C24
    out.layout = lay_cells(*domain_, cells, threads, own_or_none);
    unread_ = false;
    if (strands)   // O2: each weave region carries the smallest spacing of its strands
      for (Layout::Weave& w : out.layout.weave)
        for (const Strand& s : *strands)
          if (s.region == w.region && s.spacing_mm > 0.0)
            w.spacing_mm = w.spacing_mm > 0.0 ? std::min(w.spacing_mm, s.spacing_mm) : s.spacing_mm;
    StrutSpec struts = settings.struts;
    if (stress.demand) {
      // By stress reads the field, the RESOLVED reference (the one the cells were laid with) and the response.
      struts.demand = stress.demand;
      struts.response = stress.response;
      struts.reference_mpa = reference;
    }
    out.struts = set_struts(out.layout, struts, own_or_none);
    const double laid = ms_since(t0);
    (out.read_again ? out.ms_read : out.ms_cells) = laid;
    last_cells_.regions = out.layout.regions;   // D23: what Session::places reads of this layout
    if (settings.bars) {
      t0 = std::chrono::steady_clock::now();
      domain_->check_stop();
      out.thin_solid = solidify_thin_cuts(out.layout, *domain_, threads);   // P8 (f): before any bar is laid
      out.bars = lay_bars(out.layout, *domain_, threads);
      if (strands) {   // O2: the weave's bars, cut at their crossings, after the cells'
        Bars weave = weave_bars(*domain_, *strands, threads);
        const bool cut = !(finish && finish->draft);   // brief L2, item 3: the draft has no cut at crossings (no links)
        const auto cut_and_brace = [&](Bars& part, const WeaveFinish::Group& g) {
          if (cut) split_at_crossings(part, g.light_mm, g.layer_mm, nullptr, g.link_width);   // S, S8
          if (g.brace.unbraced_max > 0.0) brace_weave(part, *domain_, g.brace);              // T
        };
        if (!finish || finish->groups.size() <= 1) {
          cut_and_brace(weave, finish && !finish->groups.empty() ? finish->groups.front() : WeaveFinish::Group{});
        } else {   // OP11 (brief C2, E7): each group's bars (by their strand) cut and braced alone, then in group order
          Bars all;
          all.stubs = weave.stubs;
          for (const WeaveFinish::Group& g : finish->groups) {
            Bars part;
            for (const Bar& b : weave.bars)
              if (b.strand >= 0 && static_cast<std::size_t>(b.strand) >= g.first &&
                  static_cast<std::size_t>(b.strand) < g.first + g.count)
                part.bars.push_back(b);
            cut_and_brace(part, g);
            const int at = static_cast<int>(all.bars.size());
            for (Bar& b : part.bars) {
              if (b.into_a >= 0) b.into_a += at;
              if (b.into_b >= 0) b.into_b += at;
            }
            all.stubs += part.stubs;
            all.bars.insert(all.bars.end(), part.bars.begin(), part.bars.end());
          }
          weave = std::move(all);
        }
        out.bars.stubs += weave.stubs;
        out.bars.bars.insert(out.bars.bars.end(), weave.bars.begin(), weave.bars.end());
      }
      const bool draft = finish && finish->draft;   // brief L2, item 3: no joining, merging or dropping
      if (settings.join_loose && !draft) join_loose_bars(out.bars, *domain_, threads, &out.layout);
      if (strands && !draft) {   // O2 (one bar per two points): a weave's bars laid more than once on the same two ends are one
        std::vector<int> weave_regions;
        for (const Layout::Weave& w : out.layout.weave) weave_regions.push_back(w.region);
        merge_repeated_bars(out.bars, weave_regions);
      }
      domain_->check_stop();
      // S13: the part's Skin, and each region's own where it states one.
      SkinSpec skin = settings.skin_spec;
      skin.on = settings.skin;
      bool any_skin = settings.skin;
      for (const Settings::RegionAsk& r : settings.regions) {
        if (!r.skin && !r.skin_width_mm && !r.skin_reach_cells) continue;
        skin.regions.push_back({r.id, r.skin.value_or(settings.skin), r.skin_width_mm.value_or(skin.width_mm),
                                r.skin_reach_cells.value_or(skin.reach_cells)});
        any_skin = any_skin || skin.regions.back().on;
      }
      if (any_skin) lay_skin(out.bars, *domain_, skin);
      domain_->check_stop();
      // Leg J item 1: Skin is each weave region's own (else the part's): `net_on` when any weave region's is Skin.
      const bool net_on = finish ? finish->net_on : settings.skin;
      if (net_on && finish && !draft && !finish->net_reach.empty() && !finish->prune.empty())
        prune_weave(out.bars, finish->prune);   // J2: the weave pruned before the net skin is laid on it
      if (net_on && finish && !finish->hold.empty())   // L2 d: after the growth and J2, before the net skin
        hold_up_weave(out.bars, *domain_, finish->hold);
      domain_->check_stop();
      // OG5 (brief E9): no weave bar outside the part or through protected solid, before the drop (which then takes what
      // the guard left hanging).
      std::vector<int> weave_ids;
      for (const Layout::Weave& w : out.layout.weave) weave_ids.push_back(w.region);
      if (strands) guard_bars(out.bars, *domain_, weave_ids, domain_->spec().bead_mm, &out.guard);
      // OJ8 (the lead's ruling, leg M): on a Skin region the vine ends cut at the open face are landings: the drop keeps
      // them (held as if in solid for the drop only, given back their Surface kind after it).
      std::vector<std::pair<std::size_t, int>> held_surface;
      if (net_on && finish && !finish->net_reach.empty() && settings.drop_loose && !draft)
        for (std::size_t i = 0; i < out.bars.bars.size(); ++i) {
          Bar& b = out.bars.bars[i];
          bool skin_region = false;
          for (const auto& nr : finish->net_reach) skin_region = skin_region || nr.first == b.region;
          if (!skin_region || b.net) continue;
          if (b.end_a == Bar::End::Surface) { b.end_a = Bar::End::Solid; held_surface.push_back({i, 0}); }
          if (b.end_b == Bar::End::Surface) { b.end_b = Bar::End::Solid; held_surface.push_back({i, 1}); }
        }
      std::vector<std::pair<Vec3, Vec3>> held_at;   // the held ends, by place (the drop renumbers bars)
      for (const auto& [i, e] : held_surface) held_at.push_back({e ? out.bars.bars[i].b : out.bars.bars[i].a, e ? out.bars.bars[i].a : out.bars.bars[i].b});
      if (settings.drop_loose && !draft) {
        drop_loose_bars(out.bars, finish && !finish->arrived.empty() ? &finish->arrived : nullptr);   // G11
        out.stepped_edges = stepped_edges(out.bars);
        out.pieces = drop_adrift_bars(out.bars, *domain_, &out.layout);
        if (finish && !finish->prune.empty()) prune_weave(out.bars, finish->prune);   // J2, where the dropping ends
      } else {
        out.pieces = count_pieces(out.bars, *domain_, nullptr, nullptr, &out.layout);
      }
      if (!held_at.empty()) {   // OJ8: the held ends are Surface ends again
        std::set<std::array<double, 6>> held;
        for (const auto& [p, q] : held_at) held.insert({p.x, p.y, p.z, q.x, q.y, q.z});
        for (Bar& b : out.bars.bars) {
          if (b.end_a == Bar::End::Solid && held.count({b.a.x, b.a.y, b.a.z, b.b.x, b.b.y, b.b.z})) b.end_a = Bar::End::Surface;
          if (b.end_b == Bar::End::Solid && held.count({b.b.x, b.b.y, b.b.z, b.a.x, b.a.y, b.a.z})) b.end_b = Bar::End::Surface;
        }
      }
      // OJ8 (leg M; the owner: "The check to place them inside the lattice shouldn't happen until AFTER we flatten out
      // the skin"): the net is laid after the prune and the drop, on the open face (its landings: the nodes of the
      // finished lattice near the face, as the old engine took them); then the inside check (OG5) runs, and reads the
      // net and its stems as inside.
      if (net_on && finish && !finish->net_reach.empty()) {   // O16: Finish Skin on a weave region, its own width
        NetSkinReport nr;
        const std::size_t n_ask = finish->net_reach.size();
        lay_net_skin(out.bars, *domain_, finish->net_reach, settings.skin_spec.width_mm,
                     finish->net_width.size() == n_ask ? &finish->net_width : nullptr,
                     finish->net_gap.size() == n_ask ? &finish->net_gap : nullptr, true, &out.net_kept_apart,
                     finish->net_density.size() == n_ask ? &finish->net_density : nullptr,
                     finish->net_sink.size() == n_ask ? &finish->net_sink : nullptr, &nr);
        out.net_stems = nr.stems;
        out.net_stem_longest_mm = nr.stem_longest_mm;
        out.net_crossing_joints = nr.joints_at_crossings;
        if (strands) guard_bars(out.bars, *domain_, weave_ids, domain_->spec().bead_mm, &out.guard);   // OG5, after
        // The Skin face's vine ends the net did not join are dropped now, as any loose end.
        if (settings.drop_loose && !draft && !held_at.empty())
          drop_loose_bars(out.bars, finish && !finish->arrived.empty() ? &finish->arrived : nullptr);
        // The stems as they stand in the finished lattice (the guard or the drop may have taken one).
        out.net_stems = 0;
        out.net_stem_longest_mm = 0.0;
        for (const Bar& b : out.bars.bars)
          if (b.stem)
            ++out.net_stems, out.net_stem_longest_mm =
                                 std::max(out.net_stem_longest_mm, std::sqrt((b.b.x - b.a.x) * (b.b.x - b.a.x) +
                                                                             (b.b.y - b.a.y) * (b.b.y - b.a.y) +
                                                                             (b.b.z - b.a.z) * (b.b.z - b.a.z)));
        domain_->check_stop();
      }
      if (!net_on && finish && !finish->hold.empty()) {   // L2 d: Skin off, after the growth and J2
        hold_up_weave(out.bars, *domain_, finish->hold);
        guard_bars(out.bars, *domain_, weave_ids, domain_->spec().bead_mm, &out.guard);   // OG5: the supports too
      }
      for (const Bar& b : out.bars.bars)
        if (b.net) {
          ++out.net_struts;
          out.net_mm += std::sqrt((b.b.x - b.a.x) * (b.b.x - b.a.x) + (b.b.y - b.a.y) * (b.b.y - b.a.y) +
                                  (b.b.z - b.a.z) * (b.b.z - b.a.z));
        }
      out.ms_bars = ms_since(t0);
    }
    domain_->check_stop();   // set during the last step: the answer is "cancelled", never a layout nobody waits for
  } catch (const LayCancelled&) {
    return given_up();
  }
  return out;
}

std::vector<Place> Session::places(const Settings& settings) const {
  if (!domain_ || where_text(settings) != where_) return {};
  const CellSpec& c = settings.cells;
  return find_places(model_, *domain_, domain_no_chips_.get(), chip_ids_, settings.regions, last_cells_,
                     c.cell_max_mm > 0.0 ? c.cell_max_mm : c.cell_mm);
}

}  // namespace topopt::lattice_layout
