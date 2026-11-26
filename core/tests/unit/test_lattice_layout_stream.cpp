// notes30 (option D, his 2026-11-26: "The strut engine hands over its struts while it works, the way Organic's engine
// does, so the floors rise in step with the real work."): the strut stream's tests, each with its RED control.
//   T1 identity   the lay (every Outcome field) is the same with the stream on or off, threads 1 / 3 / all.
//                 RED: the slots put in the layout in the order they were laid -> differs.
//   T2 finality   every strut handed over is a bar of the finished lay, exactly (core's own landed check), over a sweep
//                 of the strut types, regions, finishes, grading, stress and the Structural count. RED: every bar handed
//                 over as lay_bars made it (no certificate) -> some are not in the finished lay.
//   T3 in step    the floors are handed over lowest first, the first early, most struts before the pieces passes.
//                 RED: the slots laid in plan order on a top-face region (top down) -> the lowest floor comes last.
//   T4 time       stream off: the lay no slower; stream on with the map in the lay: no slower than the lay and the map
//                 after it (generous here; the measured numbers are the harness's). Report only unless STREAM_TIMING=1.
//   T5 cancel     a lay stopped part way: the tap says so; the next lay's read holds that lay's struts only.
//                 RED: the tap keeps the last lay's struts -> the next read holds old ones.
//   T6 framed     a session opened standing in a print frame: each strut handed over, turned to the part's own
//                 coordinates, is a landed bar turned the same way, float for float. RED: not turned -> none is.
//   T7 map        the map made in the lay is the map made after it, byte for byte; the tap's is the Outcome's.
//                 RED: the map made before the cells are laid -> differs.
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <thread>

#include "lattice_stream_fixtures.hpp"
#include "stream.hpp"   // core's private: the RED controls, make_layout_map
#include "topopt/lattice_layout_file.hpp"   // open_in_print_frame, turn_outcome_to_model
#include "topopt/print_frame.hpp"

using namespace stream_fixtures;

namespace {
int g_fail = 0;
#define CHECK(cond, ...)                                     \
  do {                                                       \
    if (!(cond)) {                                           \
      ++g_fail;                                              \
      std::printf("  FAIL %s:%d: ", __FILE__, __LINE__);     \
      std::printf(__VA_ARGS__);                              \
      std::printf("\n");                                     \
    }                                                        \
  } while (0)

struct Control {   // a RED control, on for one scope
  explicit Control(int bits) { stream_control() = bits; }
  ~Control() { stream_control() = 0; }
};

std::size_t whole_of(const Outcome& o) {
  std::size_t n = 0;
  for (const Bar& b : o.bars.bars) n += !b.piece && !b.skin && b.end_a == Bar::End::Node && b.end_b == Bar::End::Node;
  return n;
}

// A lay with the stream on, its tap read as the app reads it (every few ms): what came in which phase, and the slots
// laid when each strut was read.
struct Watched {
  Outcome o;
  std::size_t total = 0, before_pieces = 0, in_cells = 0;
  std::vector<std::size_t> laid_at;   // per strut: slots laid when it was read
  std::vector<double> low;            // per strut: its lower end's height along the up
  std::size_t slots = 0;
  StrutTap::Read plan;
};
Watched watch_lay(Session& s, StrutTap& tap, Settings st, int threads, int poll_us = 500) {
  Watched w;
  st.stream = true;
  std::atomic<bool> done{false};
  std::thread reader([&] {
    std::size_t next = 0;
    std::uint64_t lay = 0;
    for (;;) {
      const bool last = done.load();
      const StrutTap::Read r = tap.read(next);
      if (r.lay != lay) { lay = r.lay; next = 0; w.laid_at.clear(); w.low.clear(); w.in_cells = w.before_pieces = 0; continue; }
      for (std::size_t i = 0; i < r.region.size(); ++i) {
        w.laid_at.push_back(r.laid);
        const double* p = &r.ab[6 * i];
        w.low.push_back(std::min(p[0] * r.up.x + p[1] * r.up.y + p[2] * r.up.z, p[3] * r.up.x + p[4] * r.up.y + p[5] * r.up.z));
        if (r.phase == StrutTap::kCells) ++w.in_cells;
        if (r.phase < StrutTap::kPieces) ++w.before_pieces;
      }
      next = r.next;
      w.plan = r;
      if (last) break;
      std::this_thread::sleep_for(std::chrono::microseconds(poll_us));
    }
  });
  w.o = s.lay(st, threads);
  done = true;
  reader.join();
  w.total = w.laid_at.size();
  w.slots = w.plan.slots;
  return w;
}

// ── T1 ──
void t1_identity(const Fixtures& fx) {
  std::printf("T1 identity (stream on = stream off, every Outcome field)\n");
  std::size_t lays = 0;
  for (const Case& c : identity_cases(fx)) {
    const bool all_threads = c.name.find("octet") == 0 || c.name.find("kelvin") == 0;
    for (int threads : {3, 1, 0}) {
      if (threads != 3 && !all_threads) continue;
      Session off(*c.model), on(*c.model);
      StrutTap tap;
      on.strut_tap(&tap);
      Settings st = c.settings;
      const Outcome a = off.lay(st, threads);
      st.stream = true;
      const Outcome b = on.lay(st, threads);
      ++lays;
      CHECK(digest_outcome(a) == digest_outcome(b), "%s t%d: stream on lays %016llx, off %016llx", c.name.c_str(),
            threads, static_cast<unsigned long long>(digest_outcome(b)), static_cast<unsigned long long>(digest_outcome(a)));
      CHECK(b.streamed_missing == 0, "%s t%d: %zu handed over not in the lay", c.name.c_str(), threads, b.streamed_missing);
    }
  }
  std::printf("  %zu lays compared\n", lays);
  {   // RED: put in the layout in the order laid
    const std::vector<Case> all = identity_cases(fx);
    const Case& c = all[1];   // octet whole stand
    Session off(*c.model), on(*c.model);
    StrutTap tap;
    on.strut_tap(&tap);
    Settings st = c.settings;
    const Outcome a = off.lay(st, 3);
    st.stream = true;
    Control red(kStreamControlAssembleJobs);
    const Outcome b = on.lay(st, 3);
    CHECK(digest_outcome(a) != digest_outcome(b), "RED control: assembled in the order laid and still the same layout");
    std::printf("  RED (assembled in the order laid): %s\n", digest_outcome(a) != digest_outcome(b) ? "differs, as it must" : "SAME");
  }
}

// ── T2 ──
void t2_finality(const Fixtures& fx) {
  std::printf("T2 finality sweep (every strut handed over is a bar of the finished lay)\n");
  struct Where_ { const char* name; const StepModel* m; std::function<void(Settings&)> set; };
  const std::vector<Where_> wheres = {
      {"whole part", &fx.stand.model, [](Settings& s) { s.start = Start::AllLattice; }},
      {"face region with pockets", &fx.stand.model,
       [&](Settings& s) { s.regions = {{1, Role::Lattice, {fx.top}, 30.0, 0.0}}; }},
      {"shell region", &fx.peb, [](Settings& s) { s.regions = {{1, Role::Lattice, {5}, 8.0, 0.0}}; }},
      {"zone", &fx.peb,
       [](Settings& s) {
         Settings::RegionAsk r;
         r.id = 1;
         r.zone.kind = Zone::Kind::Box;
         r.zone.axis[0] = {1, 0, 0}; r.zone.axis[1] = {0, 1, 0}; r.zone.axis[2] = {0, 0, 1};
         r.zone.half[0] = 18.0; r.zone.half[1] = 12.0; r.zone.half[2] = 30.0;
         s.regions = {r};
       }},
  };
  const char* finishes[] = {"none", "rim", "skin", "covered"};
  const Algorithm grades[] = {Algorithm::Uniform, Algorithm::DefaultGrade, Algorithm::Stepped};
  std::size_t lays = 0, handed = 0, whole = 0, bars = 0, bad = 0;
  std::size_t k = 0;
  const bool full = std::getenv("STREAM_SWEEP") != nullptr;
  for (const Where_& w : wheres)
    for (LatticeTopology t : strut_types())
      for (int f = 0; f < 4; ++f)
        for (Algorithm g : grades)
          for (int stress = 0; stress < 2; ++stress)
            for (int structural = 0; structural < 2; ++structural) {
              // ~300 of the 1,920: every type, region, finish and grade, the rest by turn (STREAM_SWEEP: all)
              if (!full && (++k % 6) != 0) continue;
              Settings s = base_settings(t, 6.0);
              w.set(s);
              if (f == 1) s.rim_mm = -1.0;
              if (f == 2) s.skin = true;
              if (f == 3) s.cover_mm = -1.0;
              s.cells.algorithm = g;
              if (stress) with_stress(s, *w.m);
              s.cells.min_cells_across = structural ? 5 : 1;
              Session ses(*w.m);
              StrutTap tap;
              ses.strut_tap(&tap);
              s.stream = true;
              const Outcome o = ses.lay(s, 0);
              ++lays;
              handed += o.streamed;
              whole += whole_of(o);
              bars += o.bars.bars.size();
              if (o.streamed_missing) {
                ++bad;
                std::printf("  FAIL %s %s %s %s stress %d structural %d: %zu of %zu handed over not in the lay\n", w.name,
                            lattice_topology_name(t), finishes[f], g == Algorithm::Uniform ? "uniform" : g == Algorithm::Stepped ? "stepped" : "default grade",
                            stress, structural, o.streamed_missing, o.streamed);
              }
            }
  CHECK(bad == 0, "%zu lays handed over a strut not in the finished lay", bad);
  std::printf("  %zu lays: %zu struts handed over of %zu whole (%.1f%%), %zu bars; %zu lays broke the promise\n", lays,
              handed, whole, 100.0 * handed / std::max<std::size_t>(1, whole), bars, bad);
  {   // RED: no certificate
    Settings s = base_settings(LatticeTopology::Octet, 8.0);
    s.regions = {{1, Role::Lattice, {fx.top}, 30.0, 0.0}};
    s.stream = true;
    Session ses(fx.stand.model);
    StrutTap tap;
    ses.strut_tap(&tap);
    Control red(kStreamControlAsMade);
    const Outcome o = ses.lay(s, 0);
    CHECK(o.streamed_missing > 0, "RED control: every bar handed over as made, and none missing");
    std::printf("  RED (handed over as made): %zu of %zu not in the finished lay\n", o.streamed_missing, o.streamed);
  }
}

// ── T3 ──
struct Floors {
  double first = 1.0;          // share of the slots laid when the lowest floor's last strut was read
  double last_first = 0.0;     // ... the same for the last floor
  bool rising = true;          // each floor's share at least the one below's (small slack)
  std::vector<double> share;
};
Floors floors_of(const Watched& w, int n) {
  Floors f;
  double lo = 1e300, hi = -1e300;
  for (double h : w.low) { lo = std::min(lo, h); hi = std::max(hi, h); }
  f.share.assign(static_cast<std::size_t>(n), 0.0);
  for (std::size_t i = 0; i < w.low.size(); ++i) {
    const int k = std::clamp(static_cast<int>((w.low[i] - lo) / std::max(1e-9, (hi - lo) / n)), 0, n - 1);
    f.share[static_cast<std::size_t>(k)] =
        std::max(f.share[static_cast<std::size_t>(k)], static_cast<double>(w.laid_at[i]) / std::max<std::size_t>(1, w.slots));
  }
  f.first = f.share.front();
  f.last_first = f.share.back();
  for (int k = 1; k < n; ++k) f.rising = f.rising && f.share[static_cast<std::size_t>(k)] + 0.05 >= f.share[static_cast<std::size_t>(k - 1)];
  return f;
}
void t3_in_step() {
  std::printf("T3 in step (one thread, the stream's rounds in the laying thread)\n");
  const StepModel peb = pebble(40.0, 25.0, 15.0, 0.25, 48);
  const GridModel stand = stand_block(1.0, 2.5);
  struct C { const char* name; const StepModel* m; Settings s; };
  std::vector<C> cs;
  {
    Settings s = base_settings(LatticeTopology::Octet, 6.0);
    s.start = Start::AllLattice;
    s.cover_mm = -1.0;
    cs.push_back({"curved, whole part Covered", &peb, s});
  }
  {
    Settings s = base_settings(LatticeTopology::Octet, 8.0);
    s.regions = {{1, Role::Lattice, {stand.face(2, 1, 40.0)}, 30.0, 0.0}};
    cs.push_back({"flat, top-face region", &stand.model, s});
  }
  {
    Settings s = base_settings(LatticeTopology::Octet, 6.0);
    s.start = Start::AllLattice;
    cs.push_back({"curved, whole part, Finish None (nothing solid)", &peb, s});
  }
  Control sync(kStreamControlSyncRounds);
  for (const C& c : cs) {
    Session ses(*c.m);
    StrutTap tap;
    ses.strut_tap(&tap);
    (void)ses.lay(c.s, 1);   // the part read once
    const Watched w = watch_lay(ses, tap, c.s, 1);
    const Floors f = floors_of(w, 5);
    const std::size_t whole = whole_of(w.o), all = w.o.bars.bars.size();
    std::printf("  %-48s handed %zu of %zu whole, %zu bars: %.0f%% of the bars before the pieces passes, %.0f%% while the "
                "cells were laid; floors done at", c.name, w.total, whole, all,
                100.0 * w.before_pieces / std::max<std::size_t>(1, all), 100.0 * w.in_cells / std::max<std::size_t>(1, all));
    for (double x : f.share) std::printf(" %.0f%%", 100 * x);
    std::printf(" of the slots\n");
    CHECK(w.o.streamed_missing == 0, "%s: %zu handed over not in the lay", c.name, w.o.streamed_missing);
    if (std::strstr(c.name, "nothing solid")) continue;   // reported: no piece can be told held before the pieces passes
    CHECK(f.rising, "%s: the floors are not handed over lowest first", c.name);
    CHECK(f.first < 0.4, "%s: the lowest floor is done at %.0f%% of the slots (over 40%%)", c.name, 100 * f.first);
    CHECK(w.before_pieces >= 0.8 * all, "%s: %zu of %zu bars handed over before the pieces passes (under 80%%)", c.name,
          w.before_pieces, all);
  }
  {   // RED: the slots in plan order, on the top-face region (its frame's third axis points down: laid top down)
    Control red(kStreamControlSyncRounds | kStreamControlSlotOrder);
    Session ses(*cs[1].m);
    StrutTap tap;
    ses.strut_tap(&tap);
    (void)ses.lay(cs[1].s, 1);
    const Watched w = watch_lay(ses, tap, cs[1].s, 1);
    const Floors f = floors_of(w, 5);
    std::printf("  RED (plan order) %-31s floors done at", cs[1].name);
    for (double x : f.share) std::printf(" %.0f%%", 100 * x);
    std::printf(" of the slots\n");
    CHECK(!(f.rising && f.first < 0.4), "RED control: plan order and still in step");
  }
}

// ── T4 ──
void t4_time() {
  std::printf("T4 time (best of 3)\n");
  const GridModel stand = stand_block(1.5, 2.5);
  Settings s = base_settings(LatticeTopology::Octet, 8.0);
  s.regions = {{1, Role::Lattice, {stand.face(2, 1, 40.0)}, 30.0, 0.0}};
  Session ses(stand.model);
  StrutTap tap;
  ses.strut_tap(&tap);
  (void)ses.lay(s, 3);
  const Vec3 lo = ses.measure().lo(), hi = ses.measure().hi();
  const float v = 0.5f;
  MapAsk ask;
  ask.nx = static_cast<int>((hi.x - lo.x) / v) + 3;
  ask.ny = static_cast<int>((hi.y - lo.y) / v) + 3;
  ask.nz = static_cast<int>((hi.z - lo.z) / v) + 3;
  const float ox = static_cast<float>(lo.x) - v, oy = static_cast<float>(lo.y) - v, oz = static_cast<float>(lo.z) - v;
  ask.at = [=](int x, int y, int z) { return Vec3{ox + v * x, oy + v * y, oz + v * z}; };
  double off = 1e300, off_map = 1e300, on = 1e300;
  for (int r = 0; r < 3; ++r) {
    auto t0 = std::chrono::steady_clock::now();
    const Outcome a = ses.lay(s, 3);
    const double lay = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    const auto m = make_layout_map(a.layout, *ses.domain(), ask, 3, nullptr);
    const double both = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    off = std::min(off, lay);
    off_map = std::min(off_map, both);
    Settings st = s;
    st.stream = true;
    st.map = ask;
    t0 = std::chrono::steady_clock::now();
    (void)ses.lay(st, 3);
    on = std::min(on, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
  }
  std::printf("  stream off: lay %.0f ms, lay + map after %.0f ms; stream on with the map in the lay: %.0f ms (%+.0f%%)\n",
              off, off_map, on, 100.0 * (on - off_map) / off_map);
  if (std::getenv("STREAM_TIMING")) CHECK(on <= 1.10 * off_map, "stream on: %.0f ms against %.0f ms", on, off_map);
}

// ── T5 ──
void t5_cancel(const Fixtures& fx) {
  std::printf("T5 cancel\n");
  Settings s = base_settings(LatticeTopology::Octet, 5.0);
  s.start = Start::AllLattice;
  s.stream = true;
  for (int red = 0; red < 2; ++red) {
    Control control(red ? kStreamControlNoRestart : 0);
    Session ses(fx.stand.model);
    StrutTap tap;
    ses.strut_tap(&tap);
    (void)ses.lay(s, 1);   // the first lay, whole
    std::atomic<bool> stop{false};
    const std::uint64_t before = tap.read(0, 1).lay;
    std::thread stopper([&] {   // stop the next lay once it has handed something over (or after a while)
      for (int i = 0; i < 20000 && !stop.load(); ++i) {
        const StrutTap::Read r = tap.read(0, 1);
        if (r.lay > before && r.total > 0) break;
        std::this_thread::sleep_for(std::chrono::microseconds(200));
      }
      stop = true;
    });
    Settings s2 = s;
    s2.cells.cell_max_mm = 20.0;   // another lay
    const Outcome cut = ses.lay(s2, 1, &stop);
    stopper.join();
    const StrutTap::Read after_cut = tap.read(0, 1);
    Settings s3 = s;
    s3.cells.cell_max_mm = 12.0;   // the next lay, unlike both before it
    const Outcome next = ses.lay(s3, 1);
    const StrutTap::Read r = tap.read(0);
    std::size_t marked = 0;   // the landed bars core found handed over
    for (std::uint8_t f : tap.landed_streamed()) marked += f;
    if (!red) {
      CHECK(cut.cancelled, "the stopped lay was not given up");
      CHECK(after_cut.phase == StrutTap::kCancelled, "the tap says phase %d after a stopped lay", after_cut.phase);
      CHECK(r.lay == after_cut.lay + 1, "the next lay is not a new one on the tap");
      CHECK(r.total == marked && next.streamed_missing == 0, "the next lay's read holds %zu struts, %zu of its bars were "
            "handed over (%zu missing)", r.total, marked, next.streamed_missing);
      std::printf("  stopped lay: cancelled %d, tap phase %d; the next lay: %zu struts read, %zu handed over, %zu missing\n",
                  cut.cancelled, after_cut.phase, r.total, next.streamed, next.streamed_missing);
    } else {
      CHECK(r.total != marked && next.streamed_missing > 0, "RED control: old struts kept and the read is clean");
      std::printf("  RED (struts kept): the next lay's read holds %zu struts, %zu of its bars handed over (%zu not in it)\n",
                  r.total, marked, next.streamed_missing);
    }
  }
}

// ── T6 ──
void t6_framed(const Fixtures& fx) {
  std::printf("T6 framed (a session standing in a print frame)\n");
  for (int red = 0; red < 2; ++red)
    for (const Vec3 up : {Vec3{1.0, 0.0, 0.0}, Vec3{0.0, 1.0, 1.0}}) {
      PrintFrame frame;
      CHECK(print_frame_for_up(up, frame), "print_frame_for_up");
      StepModel model = fx.stand.model;
      open_in_print_frame(frame, model);
      Session ses(model);
      StrutTap tap;
      ses.strut_tap(&tap);
      Settings s = base_settings(LatticeTopology::Octet, 8.0);
      s.regions = {{1, Role::Lattice, {fx.top}, 30.0, 0.0}};
      std::shared_ptr<const TensorField> none;
      turn_layout_inputs(frame, s, none);
      s.stream = true;
      s.stream_up = {0.0, 0.0, 1.0};   // the print's up, in the frame it is laid in
      Outcome o = ses.lay(s, 0);
      const StrutTap::Read r = tap.read(0);
      turn_outcome_to_model(frame, o);   // the landed bars as the bridge gives them (fill_shown)
      std::set<std::array<float, 7>> landed;
      for (const Bar& b : o.bars.bars)
        landed.insert({static_cast<float>(b.a.x), static_cast<float>(b.a.y), static_cast<float>(b.a.z),
                       static_cast<float>(b.b.x), static_cast<float>(b.b.y), static_cast<float>(b.b.z),
                       static_cast<float>(b.width)});
      std::size_t found = 0;
      for (std::size_t i = 0; i < r.region.size(); ++i) {
        Vec3 a{r.ab[6 * i], r.ab[6 * i + 1], r.ab[6 * i + 2]}, b{r.ab[6 * i + 3], r.ab[6 * i + 4], r.ab[6 * i + 5]};
        if (!red) { a = frame.point_to_model(a); b = frame.point_to_model(b); }   // the bridge's lattice_layout_strut_read
        found += landed.count({static_cast<float>(a.x), static_cast<float>(a.y), static_cast<float>(a.z),
                               static_cast<float>(b.x), static_cast<float>(b.y), static_cast<float>(b.z),
                               static_cast<float>(r.width[i])});
      }
      if (!red) {
        CHECK(found == r.region.size() && !r.region.empty(), "up (%g %g %g): %zu of %zu struts are landed bars", up.x, up.y,
              up.z, found, r.region.size());
        std::printf("  up (%g, %g, %g): %zu of %zu struts handed over are landed bars, float for float\n", up.x, up.y, up.z,
                    found, r.region.size());
      } else {
        CHECK(found < r.region.size(), "RED control: not turned and still the landed bars");
        std::printf("  RED (not turned), up (%g, %g, %g): %zu of %zu match\n", up.x, up.y, up.z, found, r.region.size());
      }
    }
}

// ── T7 ──
void t7_map(const Fixtures& fx) {
  std::printf("T7 the map made in the lay\n");
  std::vector<Case> cs;
  for (const Case& c : identity_cases(fx))
    if (c.name.find("octet top face") == 0 || c.name.find("octet whole stand") == 0 || c.name.find("octet pebble top shell") == 0 ||
        c.name.find("octet finish rim") == 0 || c.name.find("octet one grid region") == 0)
      cs.push_back(c);
  std::size_t reds = 0;
  for (int red = 0; red < 2; ++red)
    for (const Case& c : cs) {
      Control control(red ? kStreamControlMapEarly : 0);
      Session ses(*c.model);
      StrutTap tap;
      ses.strut_tap(&tap);
      Settings s = c.settings;
      s.stream = true;
      const Vec3 lo = ses.measure().lo(), hi = ses.measure().hi();
      const float v = 0.6f;
      s.map.nx = static_cast<int>((hi.x - lo.x) / v) + 3;
      s.map.ny = static_cast<int>((hi.y - lo.y) / v) + 3;
      s.map.nz = static_cast<int>((hi.z - lo.z) / v) + 3;
      const float ox = static_cast<float>(lo.x) - v, oy = static_cast<float>(lo.y) - v, oz = static_cast<float>(lo.z) - v;
      s.map.at = [=](int x, int y, int z) { return Vec3{ox + v * x, oy + v * y, oz + v * z}; };
      const Outcome o = ses.lay(s, 0);
      const auto after = make_layout_map(o.layout, *ses.domain(), s.map, 0, nullptr);   // the bridge's grid, after
      const bool same = o.map && after && o.map->rg == after->rg && o.map->asked == after->asked &&
                        o.map->unheld == after->unheld && o.map->nocell == after->nocell;
      const auto tapped = tap.map();
      if (!red) {
        CHECK(same, "%s: the map made in the lay is not the map after it", c.name.c_str());
        CHECK(tapped == o.map && tap.read(0, 1).map_state == 2, "%s: the tap's map is not the Outcome's", c.name.c_str());
        std::printf("  %-40s %s (%lld voxels asked, %lld unheld; thin cuts %zu, cells closed at the end %zu)\n", c.name.c_str(),
                    same ? "the same, byte for byte" : "DIFFERS", static_cast<long long>(after ? after->asked : 0),
                    static_cast<long long>(after ? after->unheld : 0), o.thin_solid, o.empty_solid);
      } else if (o.map && o.map->asked > 0) {
        ++reds;
        CHECK(!same, "RED control: %s: made before the cells and still the same", c.name.c_str());
        std::printf("  RED (before the cells) %-33s %s\n", c.name.c_str(), same ? "SAME" : "differs, as it must");
      }
    }
  CHECK(reds > 0, "RED control not run");
}
}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  const char* only = argc > 1 ? argv[1] : nullptr;
  const auto want = [&](const char* t) { return !only || std::strstr(only, t) != nullptr; };
  const Fixtures fx;
  if (want("T1")) t1_identity(fx);
  if (want("T2")) t2_finality(fx);
  if (want("T3")) t3_in_step();
  if (want("T4")) t4_time();
  if (want("T5")) t5_cancel(fx);
  if (want("T6")) t6_framed(fx);
  if (want("T7")) t7_map(fx);
  std::printf(g_fail ? "FAILED: %d\n" : "all passed\n", g_fail);
  return g_fail ? 1 : 0;
}
