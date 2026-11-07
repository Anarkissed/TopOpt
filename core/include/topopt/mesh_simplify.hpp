#pragma once
// ── ★ BOUNDED SIMPLIFICATION OF A CONTOURED FIELD (Finding 8, ruling 2026-11-02) ──────
// A sheet lattice contoured on a uniform grid a third of its thinnest wall costs 16-19k
// triangles a cell against octet's 1,030 (Finding 8), because the grid is fine
// EVERYWHERE while the surface needs that resolution only where it bends. This removes
// the excess without moving the surface the printer sees by more than a stated bound.
//
// THE METHOD: edge collapse ordered by the quadric error metric (Garland & Heckbert,
// "Surface simplification using quadric error metrics", SIGGRAPH '97, doi
// 10.1145/258734.258849), under a HARD deviation bound checked against the TRUE surface.
// The quadric only orders the collapses; it never decides one. A collapse is taken only
// if every new triangle, sampled at `sample_spacing_mm`, lies within the band
//     -max_in(p) <= field(p) <= max_out_mm
// of the field the mesh was contoured from (negative inside the material, a distance
// estimate near its zero set). So the bound is measured on the exact surface, not on
// the mesh being simplified, and it cannot drift as collapses accumulate.
//
// WHY NOT ADAPTIVE DUAL CONTOURING (Schaefer, Ju & Warren, IEEE TVCG 13(3):610-619, 2007,
// doi 10.1109/TVCG.2007.1012), which the same contouring cites. Its merge test is the QEF
// RMS of the merged crossings, which bounds an AVERAGE distance, not the maximum one, and
// its octree needs the whole box in memory, where the sheet contouring streams one layer
// at a time. Edge collapse keeps both: a stated maximum, and a bounded buffer (below).
//
// THE WALL STAYS AT LEAST ONE BEAD. `max_in(p)` is how far the mesh may cut INTO the
// material at p. The caller sets it to half of (the true wall at p - the bead), capped
// at the bound, so a wall at the bead floor may only bulge outward and never prints
// thinner than one bead because of this pass.
//
// STREAMED. The contouring emits triangles one z-layer at a time. This buffers them,
// and every `slab_mm` of progress simplifies what it holds, emits every triangle that
// no future layer can touch (all vertices `front_margin_mm` below the front), and keeps
// the rest. A vertex shared by an emitted triangle and a kept one is frozen from then
// on, so the seam can never open. Memory is a slab of the part, never the part.
//
// MANIFOLD AND CLOSED. A collapse must pass the link condition (the two end vertices
// share exactly the two neighbours of the collapsed edge), must not flip or degenerate
// any triangle, and never moves a frozen vertex. Deterministic: a fixed collapse order
// (cost, then vertex ids), no threads, no randomness.
//
// ★ WHERE THE TRUE SURFACE STEPS. A run grades a sheet PER VOXEL (the wall is the owning
// voxel's), so its true field JUMPS at every voxel face where the density changes. No mesh
// follows a jump to within the bound, and the contouring leaves its own error there: the
// crossing's gradient is taken across the jump, and a vertex can land a micron inside the
// thinner wall. Where that wall is at the bead (max_in 0) such a triangle can never be
// mended. refine() split it to the micron, and the collapse passes then crawled through
// the slivers: the M2 stand's gyroid rung 0.52 ran 1.5 h without finishing (10 min for the
// whole run before Finding 8). A step is therefore treated like a cut: within reach of one
// (`step`) the mesh is never refined or held back, a collapse there must stay inside the
// band the walls in reach span, and what the contouring left outside it is kept as
// contoured. The step is measured and reported on its own.

#include <array>
#include <cstdint>
#include <functional>
#include <unordered_map>
#include <vector>

#include "topopt/mesh.hpp"

namespace topopt {

struct BoundedSimplifyOptions {
  double max_out_mm = 0.02;                       // allowed distance on the air side
  std::function<double(const Vec3&)> max_in_mm;   // on the material side; null => max_out_mm
  double sample_spacing_mm = 0.1;                 // the deviation check's sample spacing
  double slab_mm = 0.0;                           // progress between flushes (0 => one flush)
  double front_margin_mm = 0.0;                   // a vertex this close to the front is live
  double min_normal_dot = 0.2;                    // a collapse may not turn a face further
  // Where the surface is CUT (the field's clip term within reach): the mesh there is kept
  // as contoured. A cut is a crease the contouring places no vertex on (it can slice the
  // corner off by up to half a cell), and no collapse or split can repair that, so the
  // bound is held on the sheet's own surface and the cut is measured and reported on its
  // own. In a run every cut lies under solid: the part's shell, or the solid beside a
  // pocket. null => no cuts.
  std::function<bool(const Vec3&)> at_cut;
  // > 0: a cut is not frozen but simplified within +-cut_tol_mm of the true surface (a
  // band of its own, about what the contouring already leaves there), and never refined.
  double cut_tol_mm = 0.0;
  // ★ A STEP (see the header), asked only of a point outside its own band: negative when no
  // step is in reach; otherwise how far the point lies outside the band the surfaces in
  // reach span (no further than max_out outside the outermost, nor deeper than the
  // innermost one's own max_in inside it, so no wall is thinned below its floor), 0 inside
  // it. null => no steps.
  std::function<double(const Vec3&)> step;
};

struct BoundedSimplifyStats {
  long long triangles_in = 0, triangles_out = 0;
  long long collapses = 0;
  long long splits = 0;
  long long flips = 0, smoothed = 0;  // improve(): between collapse passes
  long long snapped = 0;  // contoured vertices pulled onto the band  // refine(): triangles that left the band as contoured
  long long rejected_deviation = 0, rejected_topology = 0;
  long long flushes = 0;
  // Measured on EVERY emitted triangle at the sample spacing: the furthest a sample sits
  // off the true surface on each side, and how many samples cut into the material by more
  // than the caller's max_in allows (0 means no wall was thinned below its floor by any
  // triangle, collapsed or as contoured).
  double max_out_measured_mm = 0.0, max_in_measured_mm = 0.0;
  long long samples = 0, samples_past_max_in = 0;
  double worst_excess_mm = 0.0;  // the furthest any SHEET sample sits outside the band
  Vec3 worst_at{0, 0, 0};
  // The cuts, measured on their own (kept as contoured).
  long long cut_samples = 0;
  double cut_max_out_mm = 0.0, cut_max_in_mm = 0.0;
  // The steps, measured on their own: the samples off their own surface's band but within
  // reach of a step, how far they sit from their OWN true surface (up to about half the
  // step), and those outside the step's band too (as contoured: no collapse makes one) with
  // the furthest any sits outside it. Inward, that is how far a wall is under its floor.
  long long step_samples = 0, step_samples_outside_band = 0;
  double step_max_out_mm = 0.0, step_max_in_mm = 0.0;
  double step_worst_outside_band_mm = 0.0;
  double seconds = 0.0;
};

class BoundedSimplifySink : public TriangleSink {
 public:
  BoundedSimplifySink(TriangleSink& out, std::function<double(const Vec3&)> field,
                      BoundedSimplifyOptions opt);
  void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override;
  // Simplify and emit everything still held. Call once, after the last triangle.
  void finish();
  const BoundedSimplifyStats& stats() const { return st_; }

 private:
  struct Quadric { double q[10] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0}; };
  int vertex_of(const Vec3& p);
  void flush(bool final);
  void simplify();
  void refine();
  void snap_vertices();
  bool in_band(const Vec3& p) const;
  void improve();
  bool try_collapse(int u, int v);
  Vec3 onto_surface(const Vec3& m, double reach) const;
  bool fan_complete(int x) const;
  bool triangle_ok(const Vec3& a, const Vec3& b, const Vec3& c, bool sheet_only = false) const;
  bool sheet_ok(const Vec3& p, double f, bool sheet_only) const;
  void measure_and_emit(int t);
  double max_in(const Vec3& p) const;

  TriangleSink& out_;
  std::function<double(const Vec3&)> field_;
  BoundedSimplifyOptions opt_;
  BoundedSimplifyStats st_;

  std::vector<Vec3> P_;
  std::vector<std::uint8_t> vflag_;  // 1 removed, 2 live (near the front), 4 frozen
  std::vector<std::uint32_t> stamp_;
  std::vector<std::vector<int>> vt_;  // vertex -> triangles
  std::vector<std::array<int, 3>> T_;
  std::vector<std::uint8_t> tdead_;
  std::unordered_map<std::uint64_t, std::vector<int>> weld_;  // hash -> candidate vertices
  double front_z_ = -1e300, last_flush_z_ = -1e300;
  bool started_ = false;
};

}  // namespace topopt
