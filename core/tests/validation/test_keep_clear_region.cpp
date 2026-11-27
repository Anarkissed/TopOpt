// test_keep_clear_region.cpp — E4 (j), ruling 2026-11-07 19:55 item 4: Keep clear on a
// CUT PIECE clears that piece only.
//
// A cut piece is a face region: its parent faces plus half-space cuts. Before E4 a Keep
// clear could name only a whole face (or a hand-placed primitive), so the app had to send
// the PARENT face and the whole face was cleared. A clearance now gives "region_id", and
// what it clears is each member face's own Keep clear, clipped by the piece's cuts.
//
// On the demo l-bracket (OCCT):
//   (j1) the job parses "region_id"; exactly one of face_id / geometry / region_id; a
//        region that is not declared is refused, without its number;
//   (j2) the optimizer's FrozenVoid overlay for a FLAT piece (the largest plane, cut
//        through its middle) lies on the piece's side only, and is not empty; the
//        same Keep clear on the whole face reaches the other side (the control);
//        the receipt row names the region, not a face;
//   (j3) the same for a ROUND piece (a bore cut across its axis);
//   (j4) the lattice's keep-out (LatticeBoundary) forbids the piece's side and allows
//        the other side, and point_in_clearance_region agrees;
//   (j5) a bolt Keep clear on a piece with no round face is refused, in words.
#include "topopt/clearance.hpp"
#include "topopt/face_region.hpp"
#include "topopt/job.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

using namespace topopt;

namespace {
int g_failures = 0;
int g_checks = 0;
}  // namespace

#define CHECK(cond, msg)                \
  do {                                  \
    ++g_checks;                         \
    if (!(cond)) {                      \
      std::printf("FAIL: %s\n", msg);   \
      ++g_failures;                     \
    }                                   \
  } while (0)

namespace {

double dot3(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 sub3(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 add3(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 mul3(const Vec3& a, double k) { return {a.x * k, a.y * k, a.z * k}; }
Vec3 unit3(const Vec3& a) { return mul3(a, 1.0 / std::sqrt(dot3(a, a))); }
Vec3 cross3(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

// The mean of a face's triangle vertices: a point on the face, near its middle.
Vec3 face_middle(const StepModel& m, int f) {
  Vec3 s{0.0, 0.0, 0.0};
  int n = 0;
  for (std::size_t t = 0; t < m.mesh.triangles.size(); ++t) {
    if (m.triangle_face[t] != f) continue;
    for (int v : m.mesh.triangles[t]) {
      s = add3(s, m.mesh.vertices[static_cast<std::size_t>(v)]);
      ++n;
    }
  }
  return n > 0 ? mul3(s, 1.0 / n) : s;
}

// The span of a face's vertices along `dir` from `p`.
void face_span(const StepModel& m, int f, const Vec3& p, const Vec3& dir, double& lo,
               double& hi) {
  lo = 1e300;
  hi = -1e300;
  for (std::size_t t = 0; t < m.mesh.triangles.size(); ++t) {
    if (m.triangle_face[t] != f) continue;
    for (int v : m.mesh.triangles[t]) {
      const double s = dot3(sub3(m.mesh.vertices[static_cast<std::size_t>(v)], p), dir);
      lo = std::min(lo, s);
      hi = std::max(hi, s);
    }
  }
}

ProductionLoadCase base_load_case(const StepModel& model) {
  ProductionLoadCase lc;
  ProductionLoadCase::LoadGroup g;
  for (int f = 0; f < model.face_count; ++f) {
    const auto& info = model.faces[static_cast<std::size_t>(f)];
    if (info.kind == StepSurfaceKind::Cylinder)
      lc.anchor_face_ids.push_back(f);
    else if (info.kind == StepSurfaceKind::Plane)
      g.face_ids.push_back(f);
  }
  g.force = Vec3{0.0, 0.0, -50.0};
  lc.load_groups.push_back(g);
  lc.minimize_plastic = true;
  lc.build_dir = Vec3{0.0, 0.0, 1.0};
  return lc;
}

struct Frozen {
  std::size_t total = 0;
  std::size_t behind = 0;  // centres on the cut-away side of the plane
};

// The overlay's FrozenVoid voxels, counted against one cut plane.
Frozen frozen_against(const ProductionRunSetup& s, const RegionCut& cut) {
  Frozen f;
  const DesignMask& m = s.options.clearance_void;
  const VoxelGrid& g = s.solved_grid;
  if (m.size() != g.voxel_count()) return f;
  const Vec3 n = unit3(cut.normal);
  const double eps = 1e-6 * g.spacing;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (m[g.index(i, j, k)] != MaskValue::FrozenVoid) continue;
        ++f.total;
        if (dot3(sub3(g.voxel_center(i, j, k), cut.point), n) < -eps) ++f.behind;
      }
  return f;
}

std::string job_json(const std::string& clearance) {
  return "{\"model\": \"p.step\", \"material\": \"PLA\", "
         "\"mode\": \"minimize_plastic\", \"resolution\": 32, "
         "\"output\": {\"report\": \"r.json\", \"mesh_format\": \"stl\", "
         "\"mesh_prefix\": \"v\"}, "
         "\"loads\": {\"anchor_face_ids\": [1], "
         "\"groups\": [{\"face_ids\": [2], \"force\": [0, 0, -1]}], "
         "\"face_regions\": [{\"id\": 107, \"name\": \"Top, right half\", "
         "\"add\": [16], \"cuts\": [{\"point\": [0, 0, 0], \"normal\": [1, 0, 0]}]}], "
         "\"clearances\": [" + clearance + "]}}";
}

}  // namespace

int main() {
  const StepModel model =
      import_step_file(std::string(DEMO_FIXTURE_DIR) + "/l-bracket.step");
  // 64: half a bore must clear the sliver guard's floor (at 32 it holds 8 voxels).
  const int resolution = 64;

  // ── (j1) THE JOB ──────────────────────────────────────────────────────────
  {
    bool parsed = false;
    try {
      const JobDescription job =
          parse_job(job_json("{\"region_id\": 107, \"kind\": \"face\"}"));
      parsed = job.loads.clearances.size() == 1 &&
               job.loads.clearances[0].region_id == 107 &&
               job.loads.clearances[0].face_id == -1 && !job.loads.clearances[0].manual;
    } catch (...) {
    }
    CHECK(parsed, "(j1) a clearance with region_id parses and keeps the id");

    bool both_refused = false;
    try {
      parse_job(job_json("{\"region_id\": 107, \"face_id\": 16, \"kind\": \"face\"}"));
    } catch (const JobError&) {
      both_refused = true;
    } catch (...) {
    }
    CHECK(both_refused, "(j1) region_id with face_id is refused (exactly one)");

    bool undeclared_refused = false, says_number = true;
    try {
      parse_job(job_json("{\"region_id\": 108, \"kind\": \"face\"}"));
    } catch (const JobError& e) {
      undeclared_refused = true;
      says_number = std::string(e.what()).find("108") != std::string::npos;
    } catch (...) {
    }
    CHECK(undeclared_refused && !says_number,
          "(j1) a region that is not declared is refused, without its number");
  }

  // ── (j2) A FLAT PIECE ─────────────────────────────────────────────────────
  // With no design box the solved grid is the part's own box, so a face on that box
  // clears nothing anyone could see. Each kind's face is the one whose WHOLE Keep clear
  // reaches the most open voxels inside the part's box.
  const ProductionRunSetup probe = build_production_loadcase(model, resolution,
                                                             base_load_case(model));
  auto open_voxels = [&](int f, const ClearanceParams& p) {
    const ClearanceGeometry g = resolve_clearance_from_face(model, f, p);
    std::size_t n = 0;
    if (!g.valid) return n;
    const VoxelGrid& G = probe.grid;
    for (int k = 0; k < G.nz; ++k)
      for (int j = 0; j < G.ny; ++j)
        for (int i = 0; i < G.nx; ++i)
          if (!G.solid(i, j, k) && point_in_clearance_region(g, G.voxel_center(i, j, k), 0.0))
            ++n;
    return n;
  };
  int plane = -1, bore = -1;
  std::size_t best_plane = 0, best_bore = 0;
  for (int f = 0; f < model.face_count; ++f) {
    const StepFaceInfo& info = model.faces[static_cast<std::size_t>(f)];
    if (info.kind == StepSurfaceKind::Plane) {
      const std::size_t n = open_voxels(f, default_face_clearance());
      if (n > best_plane) { best_plane = n; plane = f; }
    } else if (info.kind == StepSurfaceKind::Cylinder) {
      const std::size_t n = open_voxels(f, default_bolt_clearance(info.cylinder_radius_mm));
      if (n > best_bore) { best_bore = n; bore = f; }
    }
  }
  std::printf("[faces] flat face reaches %zu open voxels, round face %zu\n", best_plane,
              best_bore);
  CHECK(plane >= 0 && bore >= 0, "the l-bracket has a flat face and a round one");
  if (plane < 0 || bore < 0) {
    std::printf("%d/%d checks passed\n", g_checks - g_failures, g_checks);
    return 1;
  }

  const StepFaceInfo& P = model.faces[static_cast<std::size_t>(plane)];
  const Vec3 pn = unit3(P.plane_normal);
  const Vec3 in_plane =
      unit3(cross3(pn, std::fabs(pn.x) < 0.9 ? Vec3{1.0, 0.0, 0.0} : Vec3{0.0, 1.0, 0.0}));
  RegionCut flat_cut;
  flat_cut.point = face_middle(model, plane);
  flat_cut.normal = in_plane;

  auto with_region = [&](int face, const RegionCut& cut, bool bolt, bool as_region) {
    ProductionLoadCase lc = base_load_case(model);
    FaceRegionSpec spec;
    spec.id = 107;
    spec.name = "The piece";
    spec.add = {face};
    spec.cuts = {cut};
    lc.face_regions.push_back(spec);
    ProductionLoadCase::Clearance c;
    if (as_region)
      c.region_id = 107;
    else
      c.face_id = face;
    const double r = model.faces[static_cast<std::size_t>(face)].cylinder_radius_mm;
    c.params = bolt ? default_bolt_clearance(r) : default_face_clearance();
    lc.clearances.push_back(c);
    return build_production_loadcase(model, resolution, lc);
  };

  {
    const ProductionRunSetup piece = with_region(plane, flat_cut, false, true);
    const ProductionRunSetup whole = with_region(plane, flat_cut, false, false);
    const Frozen fp = frozen_against(piece, flat_cut);
    const Frozen fw = frozen_against(whole, flat_cut);
    std::printf("[j2] flat piece: %zu frozen, %zu behind the cut; whole face: %zu, %zu\n",
                fp.total, fp.behind, fw.total, fw.behind);
    CHECK(fw.behind > 0, "(j2) control: the WHOLE face's Keep clear reaches past the cut");
    CHECK(fp.total > 0, "(j2) the piece's Keep clear clears something");
    CHECK(fp.behind == 0, "(j2) the piece's Keep clear stays on the piece's side");
    CHECK(fp.total < fw.total, "(j2) the piece clears less than its whole face");
    const bool row = piece.clearance_reports.size() == 1 &&
                     piece.clearance_reports[0].region_id == 107 &&
                     piece.clearance_reports[0].face_id == -1;
    CHECK(row, "(j2) the receipt row names the region, not a face");
  }

  // ── (j3) A ROUND PIECE: a bore cut across its axis ────────────────────────
  {
    const StepFaceInfo& C = model.faces[static_cast<std::size_t>(bore)];
    const Vec3 ax = unit3(C.axis_dir);
    double lo = 0.0, hi = 0.0;
    face_span(model, bore, C.axis_point, ax, lo, hi);
    RegionCut across;
    across.point = add3(C.axis_point, mul3(ax, 0.5 * (lo + hi)));
    across.normal = ax;
    const ProductionRunSetup piece = with_region(bore, across, true, true);
    const ProductionRunSetup whole = with_region(bore, across, true, false);
    const Frozen fp = frozen_against(piece, across);
    const Frozen fw = frozen_against(whole, across);
    std::printf("[j3] round piece: %zu frozen, %zu behind the cut; whole bore: %zu, %zu\n",
                fp.total, fp.behind, fw.total, fw.behind);
    CHECK(fw.behind > 0, "(j3) control: the whole bore's Keep clear reaches past the cut");
    CHECK(fp.total > 0 && fp.behind == 0,
          "(j3) the round piece's Keep clear is its own half only, and not empty");
  }

  // ── (j4) THE LATTICE'S KEEP-OUT AND THE PREDICATE ─────────────────────────
  {
    ClearanceClip clip;
    clip.point = flat_cut.point;
    clip.normal = flat_cut.normal;
    const std::vector<ClearanceGeometry> gs = resolve_clearance_from_faces(
        model, {plane}, {clip}, default_face_clearance());
    CHECK(gs.size() == 1 && gs[0].valid, "(j4) the flat piece resolves to one Keep clear");
    if (gs.size() == 1) {
      // 1 mm in front of the face, 3 mm either side of the cut.
      double ulo = 0.0, uhi = 0.0;
      face_span(model, plane, flat_cut.point, in_plane, ulo, uhi);
      const double off = std::min(3.0, 0.4 * std::min(uhi, -ulo));
      const Vec3 front = add3(flat_cut.point, pn);
      const Vec3 on_piece = add3(front, mul3(in_plane, off));
      const Vec3 off_piece = add3(front, mul3(in_plane, -off));
      CHECK(point_in_clearance_region(gs[0], on_piece, 0.0),
            "(j4) a point in front of the piece is in its Keep clear");
      CHECK(!point_in_clearance_region(gs[0], off_piece, 0.0),
            "(j4) the same point past the cut is not");
      LatticeBoundary B;
      B.add_box(Vec3{-1e3, -1e3, -1e3}, Vec3{1e3, 1e3, 1e3});
      B.add_keep_out(gs[0], /*collar=*/false);
      CHECK(B.signed_distance(on_piece) < 0.0,
            "(j4) the lattice may not grow in front of the piece");
      CHECK(B.signed_distance(off_piece) > 0.0,
            "(j4) the lattice may grow past the cut");
      CHECK(B.in_keep_out(on_piece, 0.0) && !B.in_keep_out(off_piece, 0.0),
            "(j4) the lattice's keep-out membership agrees");
    }
  }

  // ── (j5) A BOLT ON A PIECE WITH NO ROUND FACE ─────────────────────────────
  {
    bool refused = false, words = false;
    try {
      with_region(plane, flat_cut, /*bolt=*/true, true);
    } catch (const std::invalid_argument& e) {
      refused = true;
      const std::string m = e.what();
      words = m.find("The piece") != std::string::npos &&
              m.find("107") == std::string::npos;
    } catch (...) {
    }
    CHECK(refused && words,
          "(j5) a bolt Keep clear on a flat piece is refused, naming the piece");
  }

  std::printf("%d/%d checks passed\n", g_checks - g_failures, g_checks);
  return g_failures == 0 ? 0 : 1;
}
