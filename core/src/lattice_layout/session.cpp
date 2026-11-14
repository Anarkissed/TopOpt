// Lattice rebuild, stage E: what the app holds for one part (rule P2). See lattice_layout.hpp.
#include "topopt/lattice_layout.hpp"

#include <chrono>
#include <cstdio>

namespace topopt::lattice_layout {
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
  out += "R";
  for (const Settings::RegionAsk& r : s.regions) {
    whole(r.id); whole(static_cast<long>(r.role)); num(r.depth_mm); num(r.expand_mm);
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
  Outcome out;
  const auto given_up = [] { Outcome none; none.cancelled = true; return none; };
  if (stop && stop->load(std::memory_order_relaxed)) return given_up();
  auto t0 = std::chrono::steady_clock::now();
  const std::string where = where_text(settings);
  if (!domain_ || where != where_) {
    DomainSpec spec;
    spec.start = settings.start;
    spec.bead_mm = settings.bead_mm;
    spec.min_strut_lines = settings.min_strut_lines;
    spec.min_wall_mm = settings.min_wall_mm;
    spec.rim_mm = settings.rim_mm;
    spec.cover_mm = settings.cover_mm;
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
      spec.regions.push_back(std::move(region));
    }
    for (const Settings::ProtectAsk& p : settings.protect)
      spec.protect.push_back({p.id, p.pieces.empty() ? faces_mesh(model_, p.faces) : pieces_mesh(model_, p.pieces),
                              p.depth_mm});
    domain_ = std::make_unique<Domain>(*measure_, std::move(spec));
    where_ = where;
    unread_ = true;
    ref_kept_ = false;   // the reference is the new domain's to read again
    ref_field_.reset();
  }
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
    out.layout = lay_cells(*domain_, cells, threads, own_or_none);
    unread_ = false;
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
    if (settings.bars) {
      t0 = std::chrono::steady_clock::now();
      domain_->check_stop();
      out.thin_solid = solidify_thin_cuts(out.layout, *domain_, threads);   // P8 (f): before any bar is laid
      out.bars = lay_bars(out.layout, *domain_, threads);
      if (settings.join_loose) join_loose_bars(out.bars, *domain_, threads, &out.layout);
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
      if (settings.drop_loose) {
        drop_loose_bars(out.bars);
        out.stepped_edges = stepped_edges(out.bars);
        out.pieces = drop_adrift_bars(out.bars, *domain_, &out.layout);
      } else {
        out.pieces = count_pieces(out.bars, *domain_, nullptr, nullptr, &out.layout);
      }
      out.ms_bars = ms_since(t0);
    }
    domain_->check_stop();   // set during the last step: the answer is "cancelled", never a layout nobody waits for
  } catch (const LayCancelled&) {
    return given_up();
  }
  return out;
}

}  // namespace topopt::lattice_layout
