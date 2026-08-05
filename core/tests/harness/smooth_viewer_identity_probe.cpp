// smooth_viewer_identity_probe — V1 and V2 of task
// 2026-08-04-smoothing-viewer-and-ui, measured rather than argued.
//
// THE REPORT. The maintainer painted, pressed Re-certify, and every number on the
// receipt moved except one — "mass (mesh) 182.6 g → 182.6 g" — while the shape on
// screen did not change at all. Two questions follow, and this probe answers both
// on the maintainer's own bracket, through the SAME core calls the app's bridge
// makes (`constrained_taubin_smooth` under `loadcase`-resolved freeze regions).
//
//   V1  WHY DOES THE VIEWER NOT SHOW THE SMOOTHED MESH?
//       The app's Metal view re-uploads a mesh only when a SIGNATURE changes, and
//       that signature is (vertexCount, triangleCount, boundsMin, boundsMax) —
//       `meshSignature` in MetalMeshView.swift. Taubin smoothing preserves the
//       welded topology exactly (same vertices, same triangles) and a LOCAL brush
//       moves only the painted patch, so the bounding box is decided by vertices
//       that never moved. This probe computes that exact tuple, in float32, on
//       both meshes, and prints whether it separates them — alongside how many
//       vertices genuinely moved and by how much, so "the geometry really is
//       different" is a number and not an assumption.
//
//   V2  IS MESH MASS COMPUTED FROM THE ORIGINAL MESH?
//       The bridge derives it from the divergence-theorem volume of whatever mesh
//       it analysed (bridge.cpp's analyze_loadcase). If that is the smoothed mesh,
//       "unchanged" must be explained some other way. So this prints mesh volume
//       and mesh mass at FULL precision for both meshes, next to the voxelized
//       solid count and voxel mass on the same grid — and then prints both the way
//       the receipt formats them, at one decimal place.
//
// A HARNESS, not a ctest: it prints a table and writes evidence. It asserts only
// the preconditions that would make its own numbers meaningless.
//
//   cmake --build core/build --target smooth_viewer_identity_probe
//   ./core/build/smooth_viewer_identity_probe [mesh] [res] [evidence_dir]

#include "topopt/clearance.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/production.hpp"
#include "topopt/smooth.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;

namespace {

// ── the app's own two signatures, reproduced exactly ──────────────────────────

// `ViewerMesh` stores positions as Float (float32) and derives `bounds` from
// them, so the tuple MetalMeshView compares is a float32 quantity. Computing it
// in double here would be a different question from the one being asked.
struct FloatBounds {
  float lo[3] = {0, 0, 0};
  float hi[3] = {0, 0, 0};
  bool operator==(const FloatBounds& o) const {
    return std::memcmp(lo, o.lo, sizeof(lo)) == 0 &&
           std::memcmp(hi, o.hi, sizeof(hi)) == 0;
  }
};

FloatBounds float_bounds(const TriangleMesh& m) {
  FloatBounds b;
  if (m.vertices.empty()) return b;
  for (int a = 0; a < 3; ++a) {
    const Vec3& v = m.vertices[0];
    b.lo[a] = b.hi[a] = static_cast<float>(a == 0 ? v.x : (a == 1 ? v.y : v.z));
  }
  for (const Vec3& v : m.vertices) {
    const float p[3] = {static_cast<float>(v.x), static_cast<float>(v.y),
                        static_cast<float>(v.z)};
    for (int a = 0; a < 3; ++a) {
      if (p[a] < b.lo[a]) b.lo[a] = p[a];
      if (p[a] > b.hi[a]) b.hi[a] = p[a];
    }
  }
  return b;
}

// THE SHIPPED (pre-fix) SIGNATURE: counts + bounds. What MetalMeshView compares.
struct CountBoundsSignature {
  std::size_t vertices = 0;
  std::size_t triangles = 0;
  FloatBounds bounds;
  bool operator==(const CountBoundsSignature& o) const {
    return vertices == o.vertices && triangles == o.triangles &&
           bounds == o.bounds;
  }
};

CountBoundsSignature count_bounds_signature(const TriangleMesh& m) {
  return CountBoundsSignature{m.vertices.size(), m.triangles.size(),
                              float_bounds(m)};
}

// THE CONTENT SIGNATURE the fix installs: FNV-1a over the float32 bit patterns of
// every position, then over every index. Deterministic by construction — a fixed
// basis, a fixed prime, a fixed traversal order, no hashing container and no
// process-seeded hasher (bar B6).
uint64_t content_hash(const TriangleMesh& m) {
  uint64_t h = 1469598103934665603ULL;
  auto mix = [&h](uint32_t word) {
    for (int b = 0; b < 4; ++b) {
      h ^= static_cast<uint64_t>((word >> (8 * b)) & 0xFFu);
      h *= 1099511628211ULL;
    }
  };
  for (const Vec3& v : m.vertices) {
    const float p[3] = {static_cast<float>(v.x), static_cast<float>(v.y),
                        static_cast<float>(v.z)};
    for (int a = 0; a < 3; ++a) {
      uint32_t bits = 0;
      std::memcpy(&bits, &p[a], sizeof(bits));
      mix(bits);
    }
  }
  for (const auto& t : m.triangles)
    for (int c = 0; c < 3; ++c) mix(static_cast<uint32_t>(t[c]));
  return h;
}

// ── how far the geometry actually moved ───────────────────────────────────────

struct Motion {
  std::size_t moved = 0;       // vertices whose bytes differ (memcmp, doubles)
  std::size_t identical = 0;   // bit-for-bit unchanged
  double max_shift_mm = 0.0;
  double mean_shift_mm = 0.0;  // over the moved ones
};

Motion motion(const TriangleMesh& a, const TriangleMesh& b) {
  Motion mo;
  double sum = 0.0;
  for (std::size_t i = 0; i < a.vertices.size(); ++i) {
    const Vec3& p = a.vertices[i];
    const Vec3& q = b.vertices[i];
    if (std::memcmp(&p, &q, sizeof(Vec3)) == 0) {
      ++mo.identical;
      continue;
    }
    ++mo.moved;
    const double d = std::sqrt((p.x - q.x) * (p.x - q.x) +
                               (p.y - q.y) * (p.y - q.y) +
                               (p.z - q.z) * (p.z - q.z));
    sum += d;
    if (d > mo.max_shift_mm) mo.max_shift_mm = d;
  }
  if (mo.moved > 0) mo.mean_shift_mm = sum / static_cast<double>(mo.moved);
  return mo;
}

// ── the mass pair, on one grid ────────────────────────────────────────────────

struct MassReading {
  double mesh_volume_mm3 = 0.0;   // divergence theorem, exactly bridge.cpp's sum
  double mesh_mass_g = 0.0;
  std::size_t solid_voxels = 0;
  double voxel_mass_g = 0.0;
};

// The bridge's own mesh-volume sum, copied verbatim from analyze_loadcase so this
// measures the shipped arithmetic rather than a second derivation of it.
double bridge_mesh_volume_mm3(const TriangleMesh& m) {
  double v6 = 0.0;
  for (const auto& tri : m.triangles) {
    const Vec3& a = m.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& c = m.vertices[static_cast<std::size_t>(tri[2])];
    v6 += a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) +
          a.z * (b.x * c.y - b.y * c.x);
  }
  return std::fabs(v6) / 6.0;
}

MassReading mass_of(const TriangleMesh& m, const VoxelGrid& model_grid,
                    double density_g_cm3) {
  MassReading r;
  r.mesh_volume_mm3 = bridge_mesh_volume_mm3(m);
  r.mesh_mass_g = density_g_cm3 * r.mesh_volume_mm3 / 1000.0;
  const VoxelGrid g = voxelize_onto_grid(m, model_grid);
  for (std::size_t i = 0; i < g.tags.size(); ++i)
    if (g.tags[i] != VoxelTag::Empty) ++r.solid_voxels;
  r.voxel_mass_g = density_g_cm3 *
                   (static_cast<double>(r.solid_voxels) * g.voxel_volume()) /
                   1000.0;
  return r;
}

double axis_of(const Vec3& v, int a) { return a == 0 ? v.x : (a == 1 ? v.y : v.z); }

}  // namespace

int main(int argc, char** argv) {
  const std::string mesh_path =
      argc > 1 ? argv[1]
               : std::string(MESH_FIXTURE_DIR) + "/WallMount_ShelfBracket.stl";
  const int resolution = argc > 2 ? std::atoi(argv[2]) : 64;
  const std::string evidence_dir = argc > 3 ? argv[3] : "";

  std::printf("== smooth_viewer_identity_probe ==\n");
  std::printf("mesh       %s\n", mesh_path.c_str());
  std::printf("resolution %d\n\n", resolution);

  StepModel model = import_part_file_resolved(mesh_path);
  if (model.mesh.vertices.empty()) {
    std::printf("FATAL: the fixture imported empty — nothing to measure\n");
    return 2;
  }

  // The reference grid the min-feature constraint voxelizes against, built the
  // way the bridge builds it. No anchors or loads are declared: this probe asks a
  // GEOMETRY question, and the freeze set it needs is the app-supplied one.
  ProductionLoadCase lc;
  ProductionRunSetup setup = build_production_loadcase(model, resolution, lc);
  setup.options.bake_build_orientation = BakeBuildOrientation::Off;
  const VoxelGrid& grid = setup.grid;

  MaterialLibrary lib = load_materials_file(MATERIALS_JSON_PATH);
  auto it = lib.find("PLA");
  if (it == lib.end()) {
    std::printf("FATAL: PLA not in the material library\n");
    return 2;
  }
  const double density = it->second.density_g_cm3;

  // THE SUBJECT IS A VARIANT SURFACE, not the CAD solid. The page only ever
  // opens on an optimizer variant, whose mesh is a marching-cubes iso-surface:
  // terraced, high-frequency, thousands of min-feature violations — the surface
  // smoothing exists to act on. (Smoothing the prismatic CAD solid moves it by
  // microns and, at this grid, the min-feature constraint rejects the very first
  // pass pair, so measuring on it would answer nothing. Same construction as
  // `smooth_brush_probe`'s design under test.)
  std::vector<double> occ(grid.voxel_count(), 0.0);
  for (std::size_t i = 0; i < occ.size(); ++i)
    if (grid.tags[i] != VoxelTag::Empty) occ[i] = 1.0;
  const TriangleMesh original = marching_cubes(grid, occ);
  std::printf("subject: marching-cubes iso-surface of the %dx%dx%d voxelization "
              "— %zu verts, %zu tris\n\n",
              grid.nx, grid.ny, grid.nz, original.vertices.size(),
              original.triangles.size());
  if (original.vertices.empty()) {
    std::printf("FATAL: the iso-surface is empty — nothing to measure\n");
    return 2;
  }


  // ── the patches ──────────────────────────────────────────────────────────────
  //
  // TWO PLACEMENTS, because the shipped signature's behaviour DEPENDS on which
  // one you paint, and that dependence is the finding:
  //
  //   CORNER    centred on the vertex at the maximum of the longest axis — a
  //             patch that contains the part's own bounding-box extreme.
  //   INTERIOR  centred on the vertex CLOSEST to the mesh centroid, with the
  //             radius capped so the patch cannot reach any extreme. This is the
  //             maintainer's case: brushing a fillet or a rib in the middle of
  //             the part, nowhere near its outermost corner.
  //
  // Both are chosen by geometry and printed, so which vertices carry weight is on
  // the record rather than a magic index list.

  const FloatBounds fb = float_bounds(original);
  int long_axis = 0;
  for (int a = 1; a < 3; ++a)
    if (fb.hi[a] - fb.lo[a] > fb.hi[long_axis] - fb.lo[long_axis]) long_axis = a;
  double diag = 0.0;
  for (int a = 0; a < 3; ++a) {
    const double e = static_cast<double>(fb.hi[a]) - static_cast<double>(fb.lo[a]);
    diag += e * e;
  }
  diag = std::sqrt(diag);

  auto dist = [](const Vec3& p, const Vec3& q) {
    return std::sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y) +
                     (p.z - q.z) * (p.z - q.z));
  };

  struct Patch {
    const char* name;
    Vec3 centre;
    double radius;
  };
  std::vector<Patch> patches;

  {  // CORNER
    std::size_t seed = 0;
    for (std::size_t i = 1; i < original.vertices.size(); ++i)
      if (axis_of(original.vertices[i], long_axis) >
          axis_of(original.vertices[seed], long_axis))
        seed = i;
    patches.push_back({"corner", original.vertices[seed], 0.25 * diag});
  }
  {  // INTERIOR — nearest vertex to the centroid, radius capped short of every
     // extreme so the patch provably cannot move the bounding box.
    Vec3 centroid{0, 0, 0};
    for (const Vec3& v : original.vertices) {
      centroid.x += v.x;
      centroid.y += v.y;
      centroid.z += v.z;
    }
    const double n = static_cast<double>(original.vertices.size());
    centroid.x /= n;
    centroid.y /= n;
    centroid.z /= n;
    std::size_t seed = 0;
    for (std::size_t i = 1; i < original.vertices.size(); ++i)
      if (dist(original.vertices[i], centroid) < dist(original.vertices[seed], centroid))
        seed = i;
    const Vec3 c = original.vertices[seed];
    // Half the shortest distance from the centre to any bounding plane: every
    // painted vertex is then strictly inside the box with room to spare.
    double clearance = 1e30;
    for (int a = 0; a < 3; ++a) {
      clearance = std::fmin(clearance, axis_of(c, a) - static_cast<double>(fb.lo[a]));
      clearance = std::fmin(clearance, static_cast<double>(fb.hi[a]) - axis_of(c, a));
    }
    patches.push_back({"interior", c, std::fmax(0.5 * clearance, 0.0)});
  }

  // ── the sweep ────────────────────────────────────────────────────────────────

  const double strengths[] = {0.25, 0.50, 1.00};

  std::printf("-- THE SWEEP ------------------------------------------------------\n");
  std::printf("Every row is one shipped `constrained_taubin_smooth` call with the\n");
  std::printf("min-feature constraint ENFORCED, exactly as the bridge invokes it.\n\n");
  std::printf("%-9s %5s %7s %6s %8s   %-9s %-9s   %11s %11s\n", "patch",
              "str", "painted", "moved", "maxshift", "cnt+bounds", "content",
              "mesh dmass", "voxel dmass");
  std::printf("%-9s %5s %7s %6s %8s   %-9s %-9s   %11s %11s\n", "", "", "verts",
              "verts", "mm", "signature", "hash", "g", "g");

  const MassReading base_mass = mass_of(original, grid, density);
  const CountBoundsSignature base_sig = count_bounds_signature(original);
  const uint64_t base_hash = content_hash(original);

  struct Row {
    std::string patch;
    double strength;
    std::size_t painted;
    std::size_t moved;
    double max_shift;
    bool cnt_bounds_same;
    bool hash_same;
    double dmesh;
    double dvoxel;
    double mesh_after;
    double voxel_after;
    int applied;
    int requested;
  };
  std::vector<Row> rows;

  for (const Patch& p : patches) {
    std::vector<double> weights(original.vertices.size(), 0.0);
    std::size_t painted = 0;
    for (std::size_t i = 0; i < original.vertices.size(); ++i)
      if (dist(original.vertices[i], p.centre) <= p.radius) {
        weights[i] = 1.0;
        ++painted;
      }
    std::printf("\n[%s] centre (%.3f, %.3f, %.3f) radius %.3f mm — %zu of %zu "
                "vertices painted (%.1f%%)\n",
                p.name, p.centre.x, p.centre.y, p.centre.z, p.radius, painted,
                original.vertices.size(),
                100.0 * static_cast<double>(painted) /
                    static_cast<double>(original.vertices.size()));
    if (painted == 0) {
      std::printf("  (empty patch — skipped)\n");
      continue;
    }

    for (const double s : strengths) {
      TaubinParams params = taubin_params_for_strength(s);
      SmoothConstraints c;
      c.min_feature_grid = &grid;
      c.enforce_min_feature = true;  // the SHIPPED setting
      c.vertex_weight = weights;
      const SmoothResult sr = constrained_taubin_smooth(original, params, c);

      const Motion mo = motion(original, sr.mesh);
      const CountBoundsSignature sig = count_bounds_signature(sr.mesh);
      const uint64_t h = content_hash(sr.mesh);
      const MassReading m = mass_of(sr.mesh, grid, density);

      Row r;
      r.patch = p.name;
      r.strength = s;
      r.painted = painted;
      r.moved = mo.moved;
      r.max_shift = mo.max_shift_mm;
      r.cnt_bounds_same = (sig == base_sig);
      r.hash_same = (h == base_hash);
      r.dmesh = m.mesh_mass_g - base_mass.mesh_mass_g;
      r.dvoxel = m.voxel_mass_g - base_mass.voxel_mass_g;
      r.mesh_after = m.mesh_mass_g;
      r.voxel_after = m.voxel_mass_g;
      r.applied = sr.stats.applied_pairs;
      r.requested = sr.stats.requested_pairs;
      rows.push_back(r);

      std::printf("%-9s %5.2f %7zu %6zu %8.4f   %-9s %-9s   %+11.6f %+11.6f\n",
                  p.name, s, painted, mo.moved, mo.max_shift_mm,
                  r.cnt_bounds_same ? "IDENTICAL" : "differs",
                  r.hash_same ? "IDENTICAL" : "differs", r.dmesh, r.dvoxel);
    }
  }

  // ── V1, answered ─────────────────────────────────────────────────────────────

  std::size_t blind = 0, seen = 0, hash_blind = 0;
  for (const Row& r : rows) {
    if (r.moved == 0) continue;  // nothing to show; not the signature's fault
    ++seen;
    if (r.cnt_bounds_same) ++blind;
    if (r.hash_same) ++hash_blind;
  }
  std::printf("\n-- V1 ANSWERED ----------------------------------------------------\n");
  std::printf("rows where the geometry GENUINELY changed:            %zu\n", seen);
  std::printf("  ...of those, count+bounds signature IDENTICAL:      %zu  "
              "<- the view never re-uploads; the ORIGINAL stays on screen\n", blind);
  std::printf("  ...of those, content hash IDENTICAL:                %zu\n",
              hash_blind);
  std::printf("\nThe shipped signature is not merely weak, it is CONDITIONAL: it\n");
  std::printf("separates the two meshes only when the painted patch happens to\n");
  std::printf("contain the part's own bounding-box extreme. Brush the middle of\n");
  std::printf("the part — the maintainer's case — and the viewer shows nothing.\n");
  std::printf("determinism: content_hash(original) recomputed = %016llx (bar B6)\n",
              static_cast<unsigned long long>(content_hash(original)));

  // ── V2, answered ─────────────────────────────────────────────────────────────

  std::printf("\n-- V2 ANSWERED ----------------------------------------------------\n");
  std::printf("material PLA, density %.4f g/cm3, grid %dx%dx%d @ %.4f mm\n",
              density, grid.nx, grid.ny, grid.nz, grid.spacing);
  std::printf("BEFORE  mesh mass %.6f g   voxel mass %.6f g\n\n",
              base_mass.mesh_mass_g, base_mass.voxel_mass_g);
  std::printf("%-9s %5s %6s %14s %10s   %14s %10s\n", "patch", "str", "pairs",
              "mesh mass g", "receipt", "voxel mass g", "receipt");
  for (const Row& r : rows)
    std::printf("%-9s %5.2f %3d/%-2d %14.6f %9.1f%s %14.6f %9.1f%s\n",
                r.patch.c_str(), r.strength, r.applied, r.requested, r.mesh_after,
                r.mesh_after, std::fabs(r.dmesh) < 0.05 ? " *" : "  ",
                r.voxel_after, r.voxel_after,
                std::fabs(r.dvoxel) < 0.05 ? " *" : "  ");
  std::printf("\n* = rounds to the SAME string the receipt printed before smoothing.\n");
  std::printf("\nBoth columns are computed from the mesh that was ANALYSED, by the\n");
  std::printf("arithmetic copied verbatim out of bridge.cpp's analyze_loadcase.\n");
  std::printf("A mesh mass computed from the ORIGINAL would be constant at\n");
  std::printf("%.6f g down the whole column; it is not.\n", base_mass.mesh_mass_g);

  if (!evidence_dir.empty()) {
    const std::string out = evidence_dir + "/smooth_viewer_identity.txt";
    std::ofstream f(out);
    if (f) {
      f << "mesh " << mesh_path << "\nresolution " << resolution
        << "\nsubject marching_cubes_isosurface\nvertices "
        << original.vertices.size() << "\ntriangles " << original.triangles.size()
        << "\nbase_mesh_mass_g " << base_mass.mesh_mass_g
        << "\nbase_voxel_mass_g " << base_mass.voxel_mass_g
        << "\nbase_content_hash " << base_hash << "\n\n"
        << "patch strength painted moved max_shift_mm count_bounds_signature "
           "content_hash mesh_mass_g voxel_mass_g\n";
      for (const Row& r : rows)
        f << r.patch << " " << r.strength << " " << r.painted << " " << r.moved
          << " " << r.max_shift << " "
          << (r.cnt_bounds_same ? "IDENTICAL" : "differs") << " "
          << (r.hash_same ? "IDENTICAL" : "differs") << " " << r.mesh_after
          << " " << r.voxel_after << "\n";
      f << "\ngenuinely_changed_rows " << seen
        << "\ncount_bounds_blind_rows " << blind << "\ncontent_hash_blind_rows "
        << hash_blind << "\n";
      std::printf("\nevidence -> %s\n", out.c_str());
    }
  }
  return 0;
}
