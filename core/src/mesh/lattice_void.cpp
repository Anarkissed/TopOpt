#include "topopt/lattice_void.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

namespace topopt {
namespace {

// The three-way classification (see the header). Values are ordered so that
// `cls != Solid` IS the escape network — one comparison in the inner loop.
enum : unsigned char { kSolid = 0, kVoid = 1, kLatticed = 2 };

// The 6 face neighbours, in a fixed order. 6-CONNECTIVITY, deliberately — an
// edge or corner touch shares zero area and is not an aperture. See the header.
constexpr int kD[6][3] = {{-1, 0, 0}, {1, 0, 0},  {0, -1, 0},
                          {0, 1, 0},  {0, 0, -1}, {0, 0, 1}};

std::string fmt_num(double v) {
  char buf[64];
  std::snprintf(buf, sizeof(buf), "%.3f", v);
  return std::string(buf);
}

std::string fmt_vec(const Vec3& v) {
  return "(" + fmt_num(v.x) + ", " + fmt_num(v.y) + ", " + fmt_num(v.z) + ")";
}

}  // namespace

const char* grid_face_name(GridFace f) {
  switch (f) {
    case GridFace::NegX: return "-x";
    case GridFace::PosX: return "+x";
    case GridFace::NegY: return "-y";
    case GridFace::PosY: return "+y";
    case GridFace::NegZ: return "-z";
    case GridFace::PosZ: return "+z";
  }
  throw std::logic_error("grid_face_name: unnamed GridFace value");
}

LatticeVoidEscapeReport lattice_void_escape(
    const VoxelGrid& grid, const std::vector<double>& density, double iso,
    const std::vector<char>& lattice_mask, const Vec3& region_origin,
    double cell_mm, const std::vector<int>* voxel_region_id) {
  const std::size_t n = grid.voxel_count();
  if (density.size() != n)
    throw std::invalid_argument("lattice_void_escape: density size != grid.voxel_count()");
  if (lattice_mask.size() != n)
    throw std::invalid_argument(
        "lattice_void_escape: lattice_mask size != grid.voxel_count()");
  if (voxel_region_id && voxel_region_id->size() != n)
    throw std::invalid_argument(
        "lattice_void_escape: voxel_region_id size != grid.voxel_count()");
  if (!(cell_mm > 0.0))
    throw std::invalid_argument("lattice_void_escape: cell_mm must be > 0");

  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  LatticeVoidEscapeReport r;
  const double vv = grid.spacing * grid.spacing * grid.spacing;

  // ── classify ──────────────────────────────────────────────────────────────
  std::vector<unsigned char> cls(n, kSolid);
  for (std::size_t e = 0; e < n; ++e) {
    if (lattice_mask[e]) {
      cls[e] = kLatticed;
      ++r.latticed_voxels;
    } else if (density[e] >= iso) {
      cls[e] = kSolid;
      ++r.solid_voxels;
    } else {
      cls[e] = kVoid;
      ++r.void_voxels;
    }
  }
  r.escape_voxels = r.latticed_voxels + r.void_voxels;

  // The lattice CELL grid — keyed exactly as lattice_certification_mask keys it.
  const int ncx = std::max(1, static_cast<int>(std::ceil(nx * grid.spacing / cell_mm)));
  const int ncy = std::max(1, static_cast<int>(std::ceil(ny * grid.spacing / cell_mm)));
  const int ncz = std::max(1, static_cast<int>(std::ceil(nz * grid.spacing / cell_mm)));
  const std::size_t ncells =
      static_cast<std::size_t>(ncx) * static_cast<std::size_t>(ncy) *
      static_cast<std::size_t>(ncz);
  auto clampi = [](int v, int hi) { return v < 0 ? 0 : (v > hi ? hi : v); };
  auto owner_cell = [&](int i, int j, int k) {
    const double cx = grid.origin.x + (i + 0.5) * grid.spacing;
    const double cy = grid.origin.y + (j + 0.5) * grid.spacing;
    const double cz = grid.origin.z + (k + 0.5) * grid.spacing;
    const int ci = clampi(static_cast<int>(std::floor((cx - region_origin.x) / cell_mm)), ncx - 1);
    const int cj = clampi(static_cast<int>(std::floor((cy - region_origin.y) / cell_mm)), ncy - 1);
    const int ck = clampi(static_cast<int>(std::floor((cz - region_origin.z) / cell_mm)), ncz - 1);
    return (static_cast<std::size_t>(ck) * static_cast<std::size_t>(ncy) +
            static_cast<std::size_t>(cj)) *
               static_cast<std::size_t>(ncx) +
           static_cast<std::size_t>(ci);
  };

  // Distinct latticed cells (the denominator a sealed-cell count is read
  // against). -1 = unstamped; reused below per sealed component.
  std::vector<int> cell_stamp(ncells, -1);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (cls[grid.index(i, j, k)] != kLatticed) continue;
        const std::size_t c = owner_cell(i, j, k);
        if (cell_stamp[c] == -1) {
          cell_stamp[c] = 0;
          ++r.latticed_cells;
        }
      }
  std::fill(cell_stamp.begin(), cell_stamp.end(), -1);

  // VACUOUS: no lattice at all ⇒ nothing to decide. Reported, not judged.
  if (r.latticed_voxels == 0) {
    r.decidable = false;
    return r;
  }
  r.decidable = true;

  // ── pass 1: connected components of the escape network, 6-connected ───────
  // One flood fill labels every component and accumulates, per component: its
  // size, its lattice content, its bounding box, its cells, its declared region
  // ids, and WHICH GRID FACES it touches. A component touching any face reaches
  // the exterior (everything outside the grid is exterior); a component touching
  // none is a sealed cavity.
  std::vector<int> comp(n, -1);
  std::vector<std::size_t> stack;
  int ncomp = 0;

  struct Comp {
    long long voxels = 0;
    long long latticed = 0;
    long long voidv = 0;
    unsigned faces = 0;
    int lo[3] = {0, 0, 0};
    int hi[3] = {0, 0, 0};
  };
  std::vector<Comp> comps;
  std::vector<std::vector<int>> comp_region_ids;
  std::vector<long long> comp_cells;

  for (int k0 = 0; k0 < nz; ++k0)
    for (int j0 = 0; j0 < ny; ++j0)
      for (int i0 = 0; i0 < nx; ++i0) {
        const std::size_t s = grid.index(i0, j0, k0);
        if (cls[s] == kSolid || comp[s] != -1) continue;
        const int id = ncomp++;
        Comp C;
        C.lo[0] = C.hi[0] = i0;
        C.lo[1] = C.hi[1] = j0;
        C.lo[2] = C.hi[2] = k0;
        comp[s] = id;
        stack.clear();
        stack.push_back(s);
        ++r.bfs_visits;
        std::vector<int> regions;
        long long cells_here = 0;
        while (!stack.empty()) {
          const std::size_t e = stack.back();
          stack.pop_back();
          const int i = static_cast<int>(e % static_cast<std::size_t>(nx));
          const int j = static_cast<int>((e / static_cast<std::size_t>(nx)) %
                                         static_cast<std::size_t>(ny));
          const int k = static_cast<int>(e / (static_cast<std::size_t>(nx) *
                                              static_cast<std::size_t>(ny)));
          ++C.voxels;
          if (cls[e] == kLatticed) {
            ++C.latticed;
            const std::size_t c = owner_cell(i, j, k);
            if (cell_stamp[c] != id) {
              cell_stamp[c] = id;
              ++cells_here;
            }
            if (voxel_region_id) {
              const int rid = (*voxel_region_id)[e];
              if (rid > 0 && std::find(regions.begin(), regions.end(), rid) ==
                                 regions.end())
                regions.push_back(rid);
            }
          } else {
            ++C.voidv;
          }
          C.lo[0] = std::min(C.lo[0], i); C.hi[0] = std::max(C.hi[0], i);
          C.lo[1] = std::min(C.lo[1], j); C.hi[1] = std::max(C.hi[1], j);
          C.lo[2] = std::min(C.lo[2], k); C.hi[2] = std::max(C.hi[2], k);
          // Which of the grid's six boundary planes this voxel lies on. The
          // exterior is everything OUTSIDE the grid, so lying on a plane IS
          // touching the exterior.
          if (i == 0) C.faces |= 1u << 0;
          if (i == nx - 1) C.faces |= 1u << 1;
          if (j == 0) C.faces |= 1u << 2;
          if (j == ny - 1) C.faces |= 1u << 3;
          if (k == 0) C.faces |= 1u << 4;
          if (k == nz - 1) C.faces |= 1u << 5;
          for (const auto& d : kD) {
            const int ni = i + d[0], nj = j + d[1], nk = k + d[2];
            if (ni < 0 || nj < 0 || nk < 0 || ni >= nx || nj >= ny || nk >= nz)
              continue;
            const std::size_t ne = grid.index(ni, nj, nk);
            if (cls[ne] == kSolid || comp[ne] != -1) continue;
            comp[ne] = id;
            stack.push_back(ne);
            ++r.bfs_visits;
          }
        }
        std::sort(regions.begin(), regions.end());
        comps.push_back(C);
        comp_region_ids.push_back(std::move(regions));
        comp_cells.push_back(cells_here);
      }

  r.components = ncomp;
  for (int id = 0; id < ncomp; ++id) {
    const Comp& C = comps[static_cast<std::size_t>(id)];
    if (C.faces != 0u) {
      ++r.open_components;
      r.escape_reached += C.voxels;
      r.latticed_reached += C.latticed;
      if (C.latticed > 0)
        for (int f = 0; f < 6; ++f)
          if (C.faces & (1u << f)) r.face_escapes[f] = true;
      continue;
    }
    // SEALED.
    ++r.sealed_pockets_total;
    if (C.latticed > 0) {
      ++r.sealed_pockets_with_lattice;
      r.latticed_sealed += C.latticed;
      r.sealed_cells += comp_cells[static_cast<std::size_t>(id)];
      r.sealed_volume_mm3 += static_cast<double>(C.voxels) * vv;
    } else {
      ++r.sealed_pockets_without_lattice;
      r.sealed_volume_without_lattice_mm3 += static_cast<double>(C.voxels) * vv;
    }
    SealedVoidPocket P;
    P.voxels = C.voxels;
    P.latticed_voxels = C.latticed;
    P.void_voxels = C.voidv;
    P.cells = comp_cells[static_cast<std::size_t>(id)];
    P.volume_mm3 = static_cast<double>(C.voxels) * vv;
    P.latticed_volume_mm3 = static_cast<double>(C.latticed) * vv;
    for (int a = 0; a < 3; ++a) { P.lo[a] = C.lo[a]; P.hi[a] = C.hi[a]; }
    P.bbox_min = Vec3{grid.origin.x + C.lo[0] * grid.spacing,
                      grid.origin.y + C.lo[1] * grid.spacing,
                      grid.origin.z + C.lo[2] * grid.spacing};
    P.bbox_max = Vec3{grid.origin.x + (C.hi[0] + 1) * grid.spacing,
                      grid.origin.y + (C.hi[1] + 1) * grid.spacing,
                      grid.origin.z + (C.hi[2] + 1) * grid.spacing};
    P.region_ids = comp_region_ids[static_cast<std::size_t>(id)];
    r.pockets.push_back(std::move(P));
  }
  r.reachable_escape_volume_mm3 = static_cast<double>(r.escape_reached) * vv;

  // Largest trapped volume first; lattice-bearing pockets ALWAYS ahead of
  // lattice-free ones, so the cap can never drop a refusal reason in favour of
  // an observation. Ties broken on the voxel bbox so the order is deterministic.
  std::sort(r.pockets.begin(), r.pockets.end(),
            [](const SealedVoidPocket& a, const SealedVoidPocket& b) {
              const bool la = a.latticed_voxels > 0, lb = b.latticed_voxels > 0;
              if (la != lb) return la;
              if (a.voxels != b.voxels) return a.voxels > b.voxels;
              for (int i = 0; i < 3; ++i)
                if (a.lo[i] != b.lo[i]) return a.lo[i] < b.lo[i];
              return false;
            });
  if (r.pockets.size() > kMaxReportedSealedPockets)
    r.pockets.resize(kMaxReportedSealedPockets);

  // ── pass 2: HOW FAR IN the drain path runs ────────────────────────────────
  // A breadth-first fill from the grid's boundary planes, so level(v) is the
  // geodesic distance in 6-connected escape steps from the exterior. The level
  // at which the first latticed voxel appears is how deep under the surface the
  // open lattice's shortest path to the outside is.
  //
  // ★ NO "narrowest separator" IS REPORTED HERE, and that is deliberate. The
  // pre-flight's walk (voxel.hpp) can call its narrowest level set a separator
  // because its seed is a SMALL anchor set, so each level really is a cut. This
  // fill's seed is the entire boundary SHELL of the grid, so its level sets are
  // shells around the whole part and their sizes are not an aperture. Reporting
  // one would put a number in the receipt that reads like a channel width and
  // is not one.
  if (r.latticed_reached > 0) {
    std::vector<char> seen(n, 0);
    std::vector<std::size_t> frontier, next;
    auto push = [&](int i, int j, int k) {
      const std::size_t e = grid.index(i, j, k);
      if (seen[e] || cls[e] == kSolid) return;
      seen[e] = 1;
      next.push_back(e);
      ++r.bfs_visits;
    };
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) {
          if (i != 0 && i != nx - 1 && j != 0 && j != ny - 1 && k != 0 &&
              k != nz - 1)
            continue;
          push(i, j, k);
        }
    r.seed_voxels = static_cast<long long>(next.size());
    int level = 0;
    while (!next.empty() && r.lattice_escape_depth < 0) {
      frontier.swap(next);
      next.clear();
      for (const std::size_t e : frontier)
        if (cls[e] == kLatticed) { r.lattice_escape_depth = level; break; }
      if (r.lattice_escape_depth >= 0) break;
      for (const std::size_t e : frontier) {
        const int i = static_cast<int>(e % static_cast<std::size_t>(nx));
        const int j = static_cast<int>((e / static_cast<std::size_t>(nx)) %
                                       static_cast<std::size_t>(ny));
        const int k = static_cast<int>(e / (static_cast<std::size_t>(nx) *
                                            static_cast<std::size_t>(ny)));
        for (const auto& d : kD) {
          const int ni = i + d[0], nj = j + d[1], nk = k + d[2];
          if (ni < 0 || nj < 0 || nk < 0 || ni >= nx || nj >= ny || nk >= nz)
            continue;
          push(ni, nj, nk);
        }
      }
      ++level;
    }
  } else {
    // Still report the seed census even when no lattice is open — a zero seed
    // count is itself the explanation (a grid whose boundary is entirely solid).
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) {
          if (i != 0 && i != nx - 1 && j != 0 && j != ny - 1 && k != 0 &&
              k != nz - 1)
            continue;
          if (cls[grid.index(i, j, k)] != kSolid) ++r.seed_voxels;
        }
  }

  return r;
}

std::string lattice_void_refusal(const LatticeVoidEscapeReport& r) {
  if (!r.sealed()) return std::string();
  std::string s =
      "the void space inside this lattice does not reach the exterior. " +
      std::to_string(r.sealed_cells) + " of " + std::to_string(r.latticed_cells) +
      " lattice cells (" + std::to_string(r.latticed_sealed) + " of " +
      std::to_string(r.latticed_voxels) + " latticed voxels) sit in " +
      std::to_string(r.sealed_pockets_with_lattice) +
      " SEALED cavity/cavities holding " + fmt_num(r.sealed_volume_mm3) +
      " mm^3 of trapped space with no path out of the part. Nothing can ever be "
      "emptied from them — powder, resin or support placed there stays there.";
  int listed = 0;
  for (const SealedVoidPocket& P : r.pockets) {
    if (P.latticed_voxels == 0) continue;
    ++listed;
    s += " Cavity " + std::to_string(listed) + ": " +
         std::to_string(P.latticed_voxels) + " latticed voxels in " +
         std::to_string(P.cells) + " cells, " + fmt_num(P.volume_mm3) +
         " mm^3, bounding box " + fmt_vec(P.bbox_min) + " to " +
         fmt_vec(P.bbox_max) + " mm";
    if (!P.region_ids.empty()) {
      s += ", declared include region";
      s += P.region_ids.size() > 1 ? "s " : " ";
      for (std::size_t i = 0; i < P.region_ids.size(); ++i) {
        if (i) s += ", ";
        s += std::to_string(P.region_ids[i]);
      }
    }
    s += ".";
  }
  if (r.sealed_pockets_with_lattice > listed)
    s += " (" + std::to_string(r.sealed_pockets_with_lattice - listed) +
         " further sealed lattice cavities are counted above but not listed "
         "individually.)";
  // ★ HOW TO PROCEED — required, not decoration (task
  // 2026-08-06-arm-projection-and-void-check, S2b). This check is ARMED BY
  // DEFAULT now, so the first person to meet it did not opt in to it and has a
  // run that has stopped. A refusal that says only what is wrong is the
  // "painted door" defect this project has already shipped twice.
  //
  // ★ AND THE OLD REMEDY TEXT BECAME WRONG THE MOMENT THE DEFAULT FLIPPED. It
  // said "clear lattice.require_lattice_void_reaches_exterior" — advice that
  // was correct while the default was false and is now a loop: clearing the key
  // leaves it at the default, which is TRUE, and the next run refuses
  // identically. The remedy must name the explicit value to set.
  s += " NOTHING WAS AUTO-CORRECTED: opening a cavity would change geometry that "
       "was not asked to change. TO PROCEED, either (a) place the lattice so it "
       "reaches the surface or add a drain path — the cavity above tells you "
       "where — or (b) set \"require_lattice_void_reaches_exterior\": false in "
       "the job's \"lattice\" block to export anyway. THIS CHECK IS ON BY "
       "DEFAULT, so REMOVING the key does not turn it off; only an explicit "
       "false does. Exporting with it off ships a part with sealed lattice "
       "cavities: whatever ends up inside them — powder, resin or support — "
       "cannot be removed after printing, and the part's real mass will exceed "
       "the reported one by the mass of whatever stays in there.";
  return s;
}

}  // namespace topopt
