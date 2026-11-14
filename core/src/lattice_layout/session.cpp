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
  whole(static_cast<long>(s.start));
  num(s.bead_mm); num(s.min_strut_lines); num(s.min_wall_mm); num(s.rim_mm); num(s.cover_mm);
  out += "R";
  for (const Settings::RegionAsk& r : s.regions) {
    whole(r.id); whole(static_cast<long>(r.role)); num(r.depth_mm); num(r.expand_mm);
    for (int f : r.faces) whole(f);
    out += ";";
  }
  out += "P";
  for (const Settings::ProtectAsk& p : s.protect) {
    whole(p.id); num(p.depth_mm);
    for (int f : p.faces) whole(f);
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
      Region region = region_from_faces(model_, r.faces, r.id, r.role, r.depth_mm, r.expand_mm, &ok);
      if (!ok) { empty_regions_.push_back(r.id); continue; }
      spec.regions.push_back(std::move(region));
    }
    for (const Settings::ProtectAsk& p : settings.protect)
      spec.protect.push_back({p.id, faces_mesh(model_, p.faces), p.depth_mm});
    domain_ = std::make_unique<Domain>(*measure_, std::move(spec));
    where_ = where;
    unread_ = true;
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
    out.layout = lay_cells(*domain_, cells, threads);
    unread_ = false;
    out.struts = set_struts(out.layout, settings.struts);
    const double laid = ms_since(t0);
    (out.read_again ? out.ms_read : out.ms_cells) = laid;
    if (settings.bars) {
      t0 = std::chrono::steady_clock::now();
      domain_->check_stop();
      out.bars = lay_bars(out.layout, *domain_, threads);
      if (settings.join_loose) join_loose_bars(out.bars, *domain_, threads, &out.layout);
      domain_->check_stop();
      if (settings.skin) lay_skin(out.bars, *domain_, settings.skin_spec);
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
