#pragma once

// S-1 (notes30, "count pieces once"): a lay's Outcome as one number, for the tests that hold two lays to be the same
// byte for byte (test_lattice_layout, test_lattice_quilt_holes).

#include <cstdint>
#include <cstring>
#include <vector>

#include "topopt/lattice_layout.hpp"

namespace lattice_outcome_print {

using namespace topopt;
using namespace topopt::lattice_layout;

struct Fnv {
  unsigned long long h = 1469598103934665603ULL;
  void eat(const void* p, std::size_t n) {
    const unsigned char* c = static_cast<const unsigned char*>(p);
    for (std::size_t i = 0; i < n; ++i) { h ^= c[i]; h *= 1099511628211ULL; }
  }
  void num(double v) { eat(&v, sizeof v); }   // bit for bit (a -0 or a NaN is its own)
  void whole(unsigned long long v) { eat(&v, sizeof v); }
  void vec(const Vec3& v) { num(v.x); num(v.y); num(v.z); }
};

// Every field of every bar, bit for bit, in order; the bars' counts and the cut ends drop_loose_bars left.
inline unsigned long long bars_print(const Bars& bars) {
  Fnv f;
  f.whole(bars.bars.size());
  for (const Bar& b : bars.bars) {
    f.vec(b.a); f.vec(b.b); f.num(b.width); f.num(b.cell); f.vec(b.flat);
    for (double v : {b.gap_cap_mm, b.local_mm, b.proud_a, b.proud_b, b.relief_a, b.relief_b, b.along_proud}) f.num(v);
    for (long long v : {static_cast<long long>(b.region), static_cast<long long>(b.end_a), static_cast<long long>(b.end_b),
                        static_cast<long long>(b.into_a), static_cast<long long>(b.into_b), static_cast<long long>(b.strand),
                        static_cast<long long>(b.along_face), static_cast<long long>(b.local_why),
                        static_cast<long long>(b.strengthened), static_cast<long long>(b.on_bed)})
      f.whole(static_cast<unsigned long long>(v));
    for (bool v : {b.piece, b.skin, b.net, b.support, b.level_tie, b.link, b.brace, b.relief, b.face_skin, b.stem})
      f.whole(v ? 1 : 0);
  }
  for (std::size_t v : {bars.stubs, bars.dropped, bars.joined, bars.repeats, bars.cut_in_air.size()}) f.whole(v);
  for (const Bars::CutEnd& c : bars.cut_in_air) {
    f.vec(c.at); f.whole(static_cast<unsigned long long>(c.region)); f.num(c.cell);
  }
  return f.h;
}

inline unsigned long long pieces_print(const Pieces& p) {
  Fnv f;
  for (std::size_t v : {p.pieces, p.adrift, p.adrift_bars}) f.whole(v);
  f.num(p.adrift_mm);
  f.num(p.largest_adrift_mm);
  return f.h;
}

// Every byte of an Outcome that the bars, the pieces or the drop can reach: the bars (bars_print), the pieces, the
// stepped edges, the notes29 counts, and the layout's cells, solids, their reasons and the regions' counts
// (solidify_empty_cells moves cells after the drop). Times (ms_*, CellSearch::ms) are left out: they are the only part
// that is not the same twice.
inline unsigned long long outcome_print(const Outcome& o) {
  Fnv f;
  f.whole(bars_print(o.bars));
  f.whole(pieces_print(o.pieces));
  f.whole(o.stepped_edges.size());
  for (const SteppedEdge& e : o.stepped_edges) {
    f.whole(static_cast<unsigned long long>(e.region)); f.vec(e.at); f.vec(e.lo); f.vec(e.hi); f.whole(e.ends);
  }
  for (std::size_t v : {o.cut_off_joined, o.empty_solid, o.thin_solid, o.layout.small_patch_cells}) f.whole(v);
  for (const std::vector<Cell>* cs : {&o.layout.cells, &o.layout.solid}) {
    f.whole(cs->size());
    for (const Cell& c : *cs) {
      f.whole(static_cast<unsigned long long>(c.region)); f.whole(static_cast<unsigned long long>(c.frame));
      f.whole(static_cast<unsigned long long>(c.wall));
      for (double v : {c.lo[0], c.lo[1], c.lo[2], c.size, c.strut, c.own, c.band, c.reach_lo[0], c.reach_lo[1],
                       c.reach_lo[2], c.reach_hi[0], c.reach_hi[1], c.reach_hi[2]})
        f.num(v);
      for (bool v : {c.cut, c.finest, c.absorbed}) f.whole(v ? 1 : 0);
    }
  }
  f.whole(o.layout.solid_why.size());
  for (const SolidWhy& w : o.layout.solid_why) {
    f.whole(static_cast<unsigned long long>(w.why)); f.num(w.have_mm); f.num(w.need_mm);
  }
  f.whole(o.layout.thin_solid.size());
  for (std::uint32_t v : o.layout.thin_solid) f.whole(v);
  f.whole(o.layout.regions.size());
  for (const RegionCells& r : o.layout.regions) {
    f.whole(static_cast<unsigned long long>(r.region)); f.whole(static_cast<unsigned long long>(r.frame));
    f.num(r.base_cell_mm); f.whole(r.cells); f.whole(r.solid);
  }
  return f.h;
}

}  // namespace lattice_outcome_print
