// notes30 (option D, his 2026-11-26: "The strut engine hands over its struts while it works, the way Organic's engine
// does, so the floors rise in step with the real work."): the strut stream's own parts, private to core's lattice layout.
// The plan: agent-scratch/organic1/notes30/strut-stream/scope.md (3.2); the API: notes30/strut-stream/api.md.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <vector>

#include "topopt/lattice_layout.hpp"

namespace topopt::lattice_layout {

// RED controls for core's own tests (test_lattice_layout_stream), bits of stream_control(); 0 in every other lay.
inline constexpr int kStreamControlAsMade = 1;           // T2: hand over every bar as lay_bars made it (no certificate)
inline constexpr int kStreamControlSlotOrder = 2;        // T3: the slots laid highest first (top down)
inline constexpr int kStreamControlSyncRounds = 4;       // T3: the stream's rounds run in the laying thread (deterministic)
inline constexpr int kStreamControlNoRestart = 8;        // T5: StrutTap::start keeps the last lay's struts
inline constexpr int kStreamControlMapEarly = 16;        // T7: the map made before the cells are laid
inline constexpr int kStreamControlAssembleJobs = 32;    // T1: the slots put in the layout in the order they were laid
std::atomic<int>& stream_control();

// C4: the solid view's map for `layout` in `domain` (the bridge's lattice_layout_grid, byte for byte): every voxel of
// `ask` on `threads` (0: all). Null when `stop` is set part way.
std::shared_ptr<LayoutMap> make_layout_map(const Layout& layout, const Domain& domain, const MapAsk& ask, int threads,
                                           const std::atomic<bool>* stop);

// cell_holds_at's first question (cells.cpp): is the point q (the cell's frame) lattice of the cell's own region and wall?
// `other`: it is lattice of ANOTHER region (not a weave's): only then can the layout's other cells change what
// cell_holds_at answers (D14b, a cell takes in what no cell of its own holds, first in layout order).
bool cell_owns_at(const Layout& layout, const Domain::Probe& probe, const Cell& cell, const double q[3], bool* other);

// ── C2: set_struts' rule, cell by cell ───────────────────────────────────────────────────────────────────────────────
// Made from the layout's limits (bead, thinnest strut, open look, touch, type), the strut settings, the regions' own
// settings and the largest cells (`part_ref` of the whole layout, `region_ref` per region: the dial is read on them, R10,
// R19); `report` (may be null) receives what making it reports (By stress with no field or reference). set_struts makes it
// from the laid cells and sets every cell's strut with width(); the stream makes it once those largest cells are certain.
class StrutRule {
 public:
  StrutRule(const Layout& layout, const StrutSpec& spec, const AreaOwnMap* own, double part_ref,
            const std::map<int, double>& region_ref, StrutReport* report);
  // The strut width of `c` (frames: its layout's, for a by-stress cell's cube); `report` (may be null) counts as
  // set_struts counts.
  double width(const Cell& c, const std::vector<Frame>& frames, StrutReport* report) const;
  bool knows(int region) const;   // a rule was made for this region (it was in region_ref)
  // What one region's cells are set by (R19): the part's settings, with the region's stated values over them.
  struct Rule {
    bool by_stress = false, in_mm = false, graded = false;
    double ratio = 0.0;                     // not by stress: strut / cell
    double width_mm = 0.0;                  // R11
    double r_light = 0.0, r_heavy = 0.0, w_light = 0.0, w_heavy = 0.0;
    double reference = 0.0, response = 1.0;
    double amount = 1.0;                    // G4
  };

 private:
  double widest(double cell) const;
  double stress_t(const Cell& c, const Rule& u, const std::vector<Frame>& frames, StrutReport& rep) const;
  StrutSpec spec;
  double part_ref = 0.0;
  double line = 0.0, bead = 0.0, open_look = 0.0, touch = 0.0, ceiling = 0.0, gap = 0.0;
  std::map<int, Rule> rules;
};

// ── C1: lay_cells' plan, as its watch sees it ────────────────────────────────────────────────────────────────────────
// One base slot's cells as `place` laid them (lay_cells keeps them slot by slot and puts them in the layout in slot
// order, D18).
struct SlotCells {
  std::vector<Cell> cells, solid;
  std::vector<SolidWhy> why;
};
// lay_cells' PLAN (every pass in today's order, nothing laid), handed to its watch before any slot is laid. Valid until
// the watch's executed() returns.
struct CellPlan {
  // One lay of a pass over a box of its frame, in slots of `base` (lay_cells' `lay`): in plan order, which is the order
  // the layout puts their cells in.
  struct Lay {
    int region = 0, frame = 0, wall = -1;
    double base = 0.0, start[3] = {0, 0, 0};
    int count[3] = {0, 0, 0};
    bool steps = false;   // C24: in a size-step group (its cells are laid again before the layout is whole)
    const std::vector<SlotCells>* pieces = nullptr;   // per slot; a slot's entry is whole once its job is retired
    std::size_t slots() const { return static_cast<std::size_t>(count[0]) * count[1] * count[2]; }
    void slot(std::size_t i, double q[3]) const {
      const std::size_t a = i % count[0], b = (i / count[0]) % count[1],
                        c = i / (static_cast<std::size_t>(count[0]) * count[1]);
      q[0] = start[0] + a * base; q[1] = start[1] + b * base; q[2] = start[2] + c * base;
    }
  };
  // A base slot: `h`, the lowest point of its cube along the watch's up; jobs are laid in this order (ties by lay, then
  // slot) and retired in it.
  struct Job {
    double h = 0.0;
    std::uint32_t lay = 0, slot = 0;
  };
  const Layout* layout = nullptr;   // frames, walls and regions as the plan made them (no cell yet)
  bool absorb = false;              // D14b: the layout will take in slivers (CellSpec::absorb_slivers; Layout::absorb)
  std::vector<Lay> lays;
  std::vector<Job> jobs;
  // K5: per region, its count across (>= 3: a patch of fewer is made solid, drop_small_patches).
  std::function<int(int region)> k_of;
  // K8: the stretch regions' square ends (their frame, and the places on the face, frame coordinates), read before any
  // slot is laid.
  struct SquareEnd {
    int frame = 0, region = 0;
    double at[3] = {0, 0, 0};
  };
  std::vector<SquareEnd> square_ends;
  double square_reach = 0.0;   // a cell within this of a square end may be stretched (K8): its Max cell
};
// What watches lay_cells' EXECUTE (the stream's certificate). Called from lay_cells' threads.
class CellWatch {
 public:
  virtual ~CellWatch() = default;
  // The up the slots are laid along (unit, the layout's coordinates).
  virtual Vec3 up() const = 0;
  // After PLAN, before any slot is laid.
  virtual void planned(const CellPlan& plan) = 0;
  // Jobs [0, upto) of plan.jobs are laid; `line` the lowest h of a job not yet laid (+1e300: none). Called under
  // lay_cells' retire lock, in order, `upto` rising: keep it short.
  virtual void retired(std::size_t upto, double line) = 0;
  // EXECUTE is over (every job laid, or a stop asked): the plan's pieces are read for the last time before this returns.
  virtual void executed() = 0;
};

// ── C3: the stream (one strut lay's) ─────────────────────────────────────────────────────────────────────────────────
// Hands `tap` each whole strut of the lay the moment it is certain to be a bar of the finished lay, exactly (see
// StrutTap). Two stages:
//   1. while the cells are laid (CellWatch): behind the line, cells that no later rule can change are given their struts
//      by the lay's own rules (StrutRule, cell_bars); every cell that could lay a strut is read before the strut is
//      merged as lay_bars merges it; a strut is handed over once it is in the 2-core of the certain struts and its part of
//      that core holds a node touching solid (count_pieces' own test, read where the answer cannot change);
//   2. with the bars laid, joined and skinned (bars_laid, before the drop): every whole strut by the same 2-core and
//      held tests on the very bars, the layout whole.
// Everything not handed over lands with the lay. Nothing the lay makes reads anything here.
class StrutStream final : public CellWatch {
 public:
  // `struts`: the lay's strut settings as set_struts reads them (the stress resolved); `own` its regions' own.
  StrutStream(StrutTap& tap, const Domain& domain, const Vec3& up, const StrutSpec& struts, const AreaOwnMap* own,
              int threads);
  ~StrutStream() override;
  Vec3 up() const override { return up_; }
  void planned(const CellPlan& plan) override;
  void retired(std::size_t upto, double line) override;
  void executed() override;
  // Stage 2: the lay's bars, joined and skinned, the drop not yet run; `layout` the lay's (whole: thin cuts made).
  void bars_laid(const Bars& bars, const Layout& layout);
  std::size_t handed() const;   // struts handed over so far
  bool started() const { return started_; }   // the tap was started (planned() ran): this lay is the tap's
  struct Impl;

 private:
  std::unique_ptr<Impl> impl_;
  Vec3 up_;
  bool started_ = false;
};

}  // namespace topopt::lattice_layout
