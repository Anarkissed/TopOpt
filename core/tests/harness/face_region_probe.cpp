// face_region_probe — WHAT THE REGION LAYER ACTUALLY DOES ON A REAL PART
// (task 2026-08-14-face-regions, bars R2 / R3).
//
//   cmake --build build --target face_region_probe
//   ./build/face_region_probe <part.step> <resolution>
//
// It answers, in order, the four questions section 0 of the handoff has to:
//
//   1. WHAT THE PART LOOKS LIKE to a selection: the face count, the area range,
//      and the voxel range — the "660x on one bracket" fact, measured.
//   2. WHAT THE BLEND HEURISTIC MATCHES, and what it misses or over-catches
//      against the honest reference (the small faces this part actually has).
//   3. THE TAP COUNT before and after: how many taps a 23-face load group takes
//      with expand-to-neighbours and with a filter+union.
//   4. ★ WHETHER LAYER 1 MOVED. Resolving a union and a 10x5 grid split, then
//      comparing `triangle_face`, `faces` and the CAD attribution digit for
//      digit against the untouched import. If any of those move, the region
//      layer has contaminated the layer projection stands on, and the whole
//      design is wrong.

#include "topopt/cad_project.hpp"
#include "topopt/face_region.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/part.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using namespace topopt;

namespace {

int g_failures = 0;

void check(bool ok, const char* what) {
  std::printf("  %-58s %s\n", what, ok ? "OK" : "*** FAILED ***");
  if (!ok) ++g_failures;
}

double median(std::vector<double> v) {
  if (v.empty()) return 0.0;
  std::sort(v.begin(), v.end());
  return v[v.size() / 2];
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: face_region_probe <part.step> <resolution>\n");
    return 2;
  }
  const std::string path = argv[1];
  const int resolution = std::atoi(argv[2]);

  StepModel model = import_part_file_resolved(path);
  const VoxelGrid grid = voxelize(model.mesh, resolution);

  // Keep a pristine copy of LAYER 1 so the last section can prove it never moved.
  const std::vector<int> triangle_face_before = model.triangle_face;
  const std::vector<StepFaceInfo> faces_before = model.faces;
  const int face_count_before = model.face_count;

  // ── 1. what the part looks like to a selection ────────────────────────────
  const std::vector<double> areas = face_areas_mm2(model);
  const double voxel_area = grid.spacing * grid.spacing;
  double amin = 0, amax = 0;
  bool first = true;
  std::vector<double> nonzero;
  for (double a : areas) {
    if (!(a > 0.0)) continue;
    nonzero.push_back(a);
    if (first) { amin = amax = a; first = false; }
    amin = std::min(amin, a);
    amax = std::max(amax, a);
  }
  std::printf("=== 1. THE PART ===\n");
  std::printf("part            %s\n", path.c_str());
  std::printf("resolution      %d   spacing %.6g mm   voxel face %.6g mm^2\n",
              resolution, grid.spacing, voxel_area);
  std::printf("faces           %d  (%zu with area)\n", model.face_count,
              nonzero.size());
  std::printf("area  min/med/max  %.4g / %.4g / %.4g mm^2\n", amin,
              median(nonzero), amax);
  std::printf("voxels min/med/max %.0f / %.0f / %.0f   (area / voxel face)\n",
              amin / voxel_area, median(nonzero) / voxel_area, amax / voxel_area);
  std::printf("RANGE           %.0fx\n", amax / std::max(amin, 1e-12));

  // ── 2. the blend heuristic ────────────────────────────────────────────────
  std::printf("\n=== 2. THE FILLET/CHAMFER FILTER ===\n");
  const double med = median(nonzero);
  RegionFilter blend;
  blend.max_area_mm2 = 0.25 * med;
  blend.min_larger_neighbours = 2;
  blend.larger_ratio = 2.0;
  const std::vector<int> blend_hit = match_region_filter(model, blend);

  RegionFilter size_only;
  size_only.max_area_mm2 = 0.25 * med;
  const std::vector<int> size_hit = match_region_filter(model, size_only);

  RegionFilter other_kind;
  other_kind.kind = "other";
  const std::vector<int> other_hit = match_region_filter(model, other_kind);

  RegionFilter cyl_kind;
  cyl_kind.kind = "cylinder";
  const std::vector<int> cyl_hit = match_region_filter(model, cyl_kind);

  std::printf("threshold        %.4g mm^2  (0.25 x median)\n", blend.max_area_mm2);
  std::printf("blend  (small + 2 larger)   %zu faces\n", blend_hit.size());
  std::printf("size   (small only)         %zu faces\n", size_hit.size());
  std::printf("kind == other               %zu faces   <- the NAIVE reading\n",
              other_hit.size());
  std::printf("kind == cylinder            %zu faces\n", cyl_hit.size());
  // What the naive `kind == other` reading would have MISSED and OVER-CAUGHT
  // against the blend filter — the correction §2 insists on, as two numbers.
  std::size_t missed = 0, over = 0;
  for (int f : blend_hit)
    if (std::find(other_hit.begin(), other_hit.end(), f) == other_hit.end()) ++missed;
  for (int f : other_hit)
    if (std::find(blend_hit.begin(), blend_hit.end(), f) == blend_hit.end()) ++over;
  std::printf("`other` MISSES              %zu of the blend matches\n", missed);
  std::printf("`other` OVER-CATCHES        %zu faces the blend filter rejects\n", over);
  std::printf("blend matches: ");
  for (std::size_t i = 0; i < blend_hit.size() && i < 40; ++i)
    std::printf("%d ", blend_hit[i]);
  std::printf("%s\n", blend_hit.size() > 40 ? "..." : "");

  // ── 3. the tap count ──────────────────────────────────────────────────────
  //
  // His captured load group (evidence/2026-08-04-protect-freeze-vs-solidity/
  // job_maintainer.json) names 22 face ids. TODAY that is 22 taps. Two
  // mechanisms reduce it, and both are measured here rather than claimed:
  //   * EXPAND-TO-NEIGHBOURS — how many CONNECTED COPLANAR clusters those faces
  //     fall into: one tap per cluster.
  //   * FILTER + UNION — one filter, one Combine: two taps for whatever the
  //     filter covers.
  const std::vector<int> his_group = {20, 1,  4,  19, 21, 22, 25, 26, 27, 32, 41,
                                      42, 43, 44, 45, 46, 47, 49, 75, 76, 24, 31};
  std::printf("\n=== 3. THE TAP COUNT (his captured load group) ===\n");
  std::vector<int> present;
  for (int f : his_group)
    if (f >= 0 && f < model.face_count) present.push_back(f);
  std::printf("declared faces   %zu  (%zu resolve on this import)\n",
              his_group.size(), present.size());

  const std::vector<std::vector<int>> adj = face_adjacency(model);
  // Cluster the group by "edge-adjacent AND same outward direction within 1 deg".
  auto face_normal = [&](int f) {
    Vec3 n{0, 0, 0};
    for (std::size_t t = 0; t < model.mesh.triangles.size(); ++t) {
      if (model.triangle_face[t] != f) continue;
      const auto& tri = model.mesh.triangles[t];
      const Vec3& a = model.mesh.vertices[static_cast<std::size_t>(tri[0])];
      const Vec3& b = model.mesh.vertices[static_cast<std::size_t>(tri[1])];
      const Vec3& c = model.mesh.vertices[static_cast<std::size_t>(tri[2])];
      const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z};
      const Vec3 v{c.x - a.x, c.y - a.y, c.z - a.z};
      n.x += u.y * v.z - u.z * v.y;
      n.y += u.z * v.x - u.x * v.z;
      n.z += u.x * v.y - u.y * v.x;
    }
    const double l = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    return l > 1e-12 ? Vec3{n.x / l, n.y / l, n.z / l} : Vec3{0, 0, 0};
  };
  std::vector<char> seen(static_cast<std::size_t>(model.face_count), 0);
  const double cos1 = std::cos(1.0 * 3.14159265358979323846 / 180.0);
  int clusters = 0;
  for (int seed : present) {
    if (seen[static_cast<std::size_t>(seed)]) continue;
    ++clusters;
    const Vec3 sn = face_normal(seed);
    std::vector<int> stack{seed};
    seen[static_cast<std::size_t>(seed)] = 1;
    while (!stack.empty()) {
      const int f = stack.back();
      stack.pop_back();
      for (int n : adj[static_cast<std::size_t>(f)]) {
        if (seen[static_cast<std::size_t>(n)]) continue;
        const Vec3 nn = face_normal(n);
        if (sn.x * nn.x + sn.y * nn.y + sn.z * nn.z >= cos1) {
          seen[static_cast<std::size_t>(n)] = 1;
          stack.push_back(n);
        }
      }
    }
  }
  // The same clustering with the COPLANARITY test dropped, so the two numbers
  // separate "these faces do not touch" from "they touch but are not coplanar".
  // Without that separation an expand-to-neighbours result of "no improvement"
  // is unreadable — it could mean either.
  std::vector<char> seen2(static_cast<std::size_t>(model.face_count), 0);
  int touching = 0;
  {
    const std::vector<char> in_group = [&] {
      std::vector<char> g(static_cast<std::size_t>(model.face_count), 0);
      for (int f : present) g[static_cast<std::size_t>(f)] = 1;
      return g;
    }();
    for (int seed : present) {
      if (seen2[static_cast<std::size_t>(seed)]) continue;
      ++touching;
      std::vector<int> stack{seed};
      seen2[static_cast<std::size_t>(seed)] = 1;
      while (!stack.empty()) {
        const int f = stack.back();
        stack.pop_back();
        for (int n : adj[static_cast<std::size_t>(f)]) {
          if (seen2[static_cast<std::size_t>(n)] || !in_group[static_cast<std::size_t>(n)])
            continue;
          seen2[static_cast<std::size_t>(n)] = 1;
          stack.push_back(n);
        }
      }
    }
  }
  std::printf("TODAY            %zu taps (one per face)\n", present.size());
  std::printf("adjacency groups %d  (his faces that touch each other at all)\n",
              touching);
  std::printf("expand-coplanar  %d taps (one per connected coplanar cluster)\n",
              clusters);
  // ★ AND THE SAME COUNT UNDER SAME-KIND EXPANSION — a connected run of faces
  // sharing a surface class (a bore OCCT split into cylinder + cone, a fillet
  // chain). This is the expansion that can help on a B-rep, where coplanar
  // expansion cannot: a B-rep already merges coplanar surface into ONE face, so
  // two adjacent planar faces are adjacent precisely BECAUSE they are not
  // coplanar.
  int kind_clusters = 0;
  {
    std::vector<char> in_group(static_cast<std::size_t>(model.face_count), 0);
    for (int f : present) in_group[static_cast<std::size_t>(f)] = 1;
    std::vector<char> vis(static_cast<std::size_t>(model.face_count), 0);
    for (int seed : present) {
      if (vis[static_cast<std::size_t>(seed)]) continue;
      ++kind_clusters;
      const StepSurfaceKind k = model.faces[static_cast<std::size_t>(seed)].kind;
      std::vector<int> stack{seed};
      vis[static_cast<std::size_t>(seed)] = 1;
      while (!stack.empty()) {
        const int f = stack.back();
        stack.pop_back();
        for (int n : adj[static_cast<std::size_t>(f)]) {
          if (vis[static_cast<std::size_t>(n)] || !in_group[static_cast<std::size_t>(n)])
            continue;
          if (model.faces[static_cast<std::size_t>(n)].kind != k) continue;
          vis[static_cast<std::size_t>(n)] = 1;
          stack.push_back(n);
        }
      }
    }
  }
  std::printf("expand-same-kind %d taps (one per connected same-class cluster)\n",
              kind_clusters);
  std::printf("filter + Combine 2 taps (pick a preset, press Combine)\n");

  // And what expand-to-neighbours does on the part's OWN largest surfaces —
  // the case it was built for — so the mechanism is measured even when his
  // particular group does not benefit from it.
  {
    std::vector<std::pair<double, int>> by_area;
    for (int f = 0; f < model.face_count; ++f)
      by_area.push_back({areas[static_cast<std::size_t>(f)], f});
    std::sort(by_area.rbegin(), by_area.rend());
    std::printf("\nexpand-coplanar on the five largest faces (1 tap each):\n");
    for (std::size_t i = 0; i < 5 && i < by_area.size(); ++i) {
      const int seed = by_area[i].second;
      const Vec3 sn = face_normal(seed);
      std::vector<char> vis(static_cast<std::size_t>(model.face_count), 0);
      vis[static_cast<std::size_t>(seed)] = 1;
      std::vector<int> stack{seed};
      int n_faces = 1;
      while (!stack.empty()) {
        const int f = stack.back();
        stack.pop_back();
        for (int n : adj[static_cast<std::size_t>(f)]) {
          if (vis[static_cast<std::size_t>(n)]) continue;
          const Vec3 nn = face_normal(n);
          if (sn.x * nn.x + sn.y * nn.y + sn.z * nn.z >= cos1) {
            vis[static_cast<std::size_t>(n)] = 1;
            ++n_faces;
            stack.push_back(n);
          }
        }
      }
      std::printf("  face %-3d (%.4g mm^2)  1 tap -> %d faces\n", seed,
                  by_area[i].first, n_faces);
    }
  }

  // ── 4. ★ DID LAYER 1 MOVE? ────────────────────────────────────────────────
  std::printf("\n=== 4. LAYER 1, BEFORE AND AFTER A UNION + A 10x5 GRID SPLIT ===\n");
  // The CAD attribution + projection statistics on the UNTOUCHED import.
  CadProjectOptions po = cad_project_options_for_grid(grid.spacing);
  po.enabled = true;
  // ★ THE CAD ERROR ITSELF: attribute the surface, project it onto the analytic
  // faces, and measure how flat the flats and how round the bores came out. This
  // is the 0.3232 mm figure PR 326 reported, computed here on the imported
  // tessellation so it is comparable before and after the region edits.
  const CadAttribution att_before = attribute_to_cad_faces(model.mesh, model, po);
  CadProjectionStats stats_before;
  const TriangleMesh proj_before =
      project_onto_cad_faces(model.mesh, model, po, att_before, &stats_before);
  const std::vector<FaceFlatness> flat_before =
      measure_flats(proj_before, model, att_before);
  const std::vector<BoreRoundness> bore_before =
      measure_bores(proj_before, model, att_before);

  // Union whatever the blend filter matched (falling back to the two smallest
  // faces on a part with no blends), then grid-split the LARGEST face 10 x 5.
  std::vector<int> union_members = blend_hit;
  if (union_members.size() < 2) {
    std::vector<std::pair<double, int>> by_area;
    for (int f = 0; f < model.face_count; ++f)
      if (areas[static_cast<std::size_t>(f)] > 0.0)
        by_area.push_back({areas[static_cast<std::size_t>(f)], f});
    std::sort(by_area.begin(), by_area.end());
    union_members.clear();
    for (std::size_t i = 0; i < 2 && i < by_area.size(); ++i)
      union_members.push_back(by_area[i].second);
    std::sort(union_members.begin(), union_members.end());
  }
  int biggest = 0;
  for (int f = 1; f < model.face_count; ++f)
    if (areas[static_cast<std::size_t>(f)] > areas[static_cast<std::size_t>(biggest)])
      biggest = f;

  FaceRegionSpec u;
  u.id = 100;
  u.name = "blends";
  u.filter = blend;
  u.filter_matched_at_author = static_cast<int>(blend_hit.size());
  // ★ THE FILTER IS THE MEMBERSHIP. Its matches are deliberately NOT copied
  // into `add` — that would make the union a stale id list wearing a filter's
  // clothes, and §5 below is what caught it: doing so grew a 24-face union to
  // 32 across a simulated CAD edit. `add` carries only a hand correction.
  if (!blend.any()) u.add = union_members;
  FaceRegionSpec parent;
  parent.id = 200;
  parent.name = "wall";
  parent.add = {biggest};
  std::vector<FaceRegionSpec> specs{u, parent};

  std::vector<ResolvedFaceRegion> resolved = resolve_face_regions(model, specs);
  const RegionFrame frame = region_frame(model, resolved[1]);
  const std::vector<GridSplitCell> cells = grid_split_cells(frame, 10, 5);
  const std::vector<int> parent_voxels =
      region_member_voxels(grid, model, resolved[1], 1);
  const std::vector<std::size_t> cell_counts =
      grid_split_voxel_counts(grid, parent_voxels, cells);
  const SliverVerdict v =
      check_sliver(cell_counts, cells, parent_voxels.size());
  int id = 300;
  for (const GridSplitCell& c : cells) {
    FaceRegionSpec s = parent;
    s.id = id++;
    s.parent_id = parent.id;
    s.cuts = c.cuts;
    specs.push_back(s);
  }
  resolved = resolve_face_regions(model, specs);

  std::printf("union            region 100, %zu member faces, %.4g mm^2\n",
              resolved[0].member_faces.size(), resolved[0].area_mm2);
  std::printf("grid parent      face %d, %zu voxels, frame %s\n", biggest,
              parent_voxels.size(),
              frame.cylindrical ? "CYLINDRICAL (shared axis)" : "PCA (no shared axis)");
  std::size_t total_cells = 0;
  for (std::size_t c : cell_counts) total_cells += c;
  std::printf("10x5 split       %zu cells, voxels %zu of %zu (%s)\n", cells.size(),
              total_cells, parent_voxels.size(),
              total_cells == parent_voxels.size() ? "PARTITIONS" : "*** LEAKS ***");
  std::printf("smallest cell    %zu voxels  floor %zu  -> %s\n",
              v.min_cell_voxels, v.floor_voxels, v.ok ? "ACCEPTED" : "REFUSED");
  if (!v.ok) std::printf("refusal          %s\n", v.reason.c_str());

  const CadAttribution att_after = attribute_to_cad_faces(model.mesh, model, po);
  CadProjectionStats stats_after;
  const TriangleMesh proj_after =
      project_onto_cad_faces(model.mesh, model, po, att_after, &stats_after);
  const std::vector<FaceFlatness> flat_after =
      measure_flats(proj_after, model, att_after);
  const std::vector<BoreRoundness> bore_after =
      measure_bores(proj_after, model, att_after);
  auto worst_flat = [](const std::vector<FaceFlatness>& v) {
    double m = 0.0;
    for (const FaceFlatness& f : v) m = std::max(m, f.max_abs_mm);
    return m;
  };
  auto worst_bore = [](const std::vector<BoreRoundness>& v) {
    double m = 0.0;
    for (const BoreRoundness& b : v) m = std::max(m, b.out_of_roundness_mm);
    return m;
  };

  std::printf("\n  LAYER 1 CHECKS\n");
  check(model.triangle_face == triangle_face_before,
        "triangle_face unchanged (every voxel keeps its CAD face)");
  check(model.face_count == face_count_before, "face_count unchanged");
  check(model.faces.size() == faces_before.size(),
        "the analytic surface table is the same size");
  bool same_faces = model.faces.size() == faces_before.size();
  for (std::size_t i = 0; same_faces && i < model.faces.size(); ++i) {
    const StepFaceInfo& a = model.faces[i];
    const StepFaceInfo& b = faces_before[i];
    same_faces = a.kind == b.kind && a.cylinder_radius_mm == b.cylinder_radius_mm &&
                 a.axis_dir.x == b.axis_dir.x && a.axis_dir.y == b.axis_dir.y &&
                 a.axis_dir.z == b.axis_dir.z &&
                 a.plane_normal.x == b.plane_normal.x &&
                 a.plane_normal.y == b.plane_normal.y &&
                 a.plane_normal.z == b.plane_normal.z;
  }
  check(same_faces, "every analytic surface identical, bit for bit");
  check(att_after.face_of_vertex == att_before.face_of_vertex,
        "CAD attribution per vertex identical");
  check(att_after.attributed == att_before.attributed,
        "CAD-ATTRIBUTED VERTEX COUNT identical");
  check(stats_after.max_move_mm == stats_before.max_move_mm &&
            stats_after.rms_move_mm == stats_before.rms_move_mm &&
            stats_after.moved == stats_before.moved,
        "projection move (max/rms/count) identical to the digit");
  check(worst_flat(flat_after) == worst_flat(flat_before),
        "CAD ERROR — worst face flatness identical to the digit");
  check(worst_bore(bore_after) == worst_bore(bore_before),
        "CAD ERROR — worst bore out-of-roundness identical");
  check(proj_after.vertices.size() == proj_before.vertices.size(),
        "the projected mesh has the same vertex count");
  std::printf("\n  attributed vertices  %zu of %zu  (share %.9f)\n",
              att_after.attributed, model.mesh.vertices.size(),
              model.mesh.vertices.empty()
                  ? 0.0
                  : static_cast<double>(att_after.attributed) /
                        static_cast<double>(model.mesh.vertices.size()));
  std::printf("  projection max/rms   %.12g / %.12g mm\n", stats_after.max_move_mm,
              stats_after.rms_move_mm);
  std::printf("  CAD ERROR  flatness  %.12g mm (worst face, %zu measured)\n",
              worst_flat(flat_after), flat_after.size());
  std::printf("  CAD ERROR  roundness %.12g mm (worst bore, %zu measured)\n",
              worst_bore(bore_after), bore_after.size());

  // ── 5. ★ R6 — A RE-IMPORT AFTER A CAD EDIT ────────────────────────────────
  //
  // A CAD edit renumbers B-rep faces. Simulated here by DELETING one face from
  // the model and shifting every id above it down — which is exactly what
  // suppressing a feature does to OCCT's TopExp_Explorer order.
  //
  // The union is persisted as its FILTER plus an add/remove list, so what is
  // measured is: does the filter still find the same population, and is the
  // difference REPORTED? An id list would have silently pointed at whatever
  // inherited the number, and nothing downstream could have noticed.
  std::printf("\n=== 5. AFTER A CAD EDIT (one face deleted, ids renumbered) ===\n");
  {
    const int dropped = blend_hit.empty() ? 0 : blend_hit.front();
    StepModel edited;
    edited.mesh.vertices = model.mesh.vertices;
    edited.faces_are_fitted = model.faces_are_fitted;
    for (std::size_t t = 0; t < model.mesh.triangles.size(); ++t) {
      const int f = model.triangle_face[t];
      if (f == dropped) continue;
      edited.mesh.triangles.push_back(model.mesh.triangles[t]);
      edited.triangle_face.push_back(f > dropped ? f - 1 : f);
    }
    for (int f = 0; f < model.face_count; ++f)
      if (f != dropped) edited.faces.push_back(model.faces[static_cast<std::size_t>(f)]);
    edited.face_count = model.face_count - 1;

    FaceRegionSpec again = u;  // the SAME persisted definition
    const std::vector<int> matched_now = match_region_filter(edited, again.filter);
    // The stored add-list may now name an id past the end; a member that no
    // longer exists is refused loudly rather than resolved to the wrong face.
    std::vector<int> kept;
    for (int f : again.add)
      if (f < edited.face_count) kept.push_back(f);
    again.add = kept;
    const std::vector<ResolvedFaceRegion> after = resolve_face_regions(edited, {again});
    std::printf("deleted face     %d   (ids above it shift down by one)\n", dropped);
    std::printf("filter matched   %d at authoring -> %zu now   drift %+d\n",
                again.filter_matched_at_author, matched_now.size(),
                static_cast<int>(matched_now.size()) - again.filter_matched_at_author);
    std::printf("region members   %zu (was %zu)\n", after[0].member_faces.size(),
                resolved[0].member_faces.size());
    std::printf("reported?        %s\n",
                after[0].filter_drift_known ? "YES — filter_drift is carried on the "
                                              "resolved region and logged by the run"
                                            : "NO");
  }

  std::printf("\n%s (%d failed check%s)\n",
              g_failures == 0 ? "ALL LAYER-1 CHECKS PASSED" : "LAYER 1 MOVED",
              g_failures, g_failures == 1 ? "" : "s");
  return g_failures == 0 ? 0 : 1;
}
