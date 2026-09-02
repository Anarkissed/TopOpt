// Drive core's solve_coupled_lattice on a dumped lattice, with PARTIAL FILL.
//
// The hex mesh carries only the SOLID; the struts are beam elements. A strut runs
// THROUGH voxels, so a binary mask has two wrong answers for those: call the voxel
// solid and the strut is counted twice (stiffer than reality), or carve it out and
// real plastic is deleted (on a 3 mm lattice that fragmented the part into
// free-floating islands). This computes the fraction of each voxel the struts
// actually occupy and hands core the REMAINDER as the solid fraction.
#include "topopt/beam_network.hpp"
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <algorithm>
#include <vector>
using namespace topopt;

// ── ★ LIVE PROGRESS. Prints iteration, relative residual, the rate of change over
// the last window and an elapsed time -- and FLUSHES, because a buffered printf in
// a 40-minute solve is the same as no printf at all. The rate is what distinguishes
// "slow" from "stalled": a residual falling by 1% per 500 iterations will not reach
// 1e-8 in any practical time, and seeing that at minute two is worth an hour.
struct Prog {
  std::chrono::steady_clock::time_point t0 = std::chrono::steady_clock::now();
  double last = 1.0;
  int last_it = 0;
};

// Stage checkpoints: what the solver is doing, how long each part took, and how
// much of it there was. "Slow" only means something next to "how much".
static void stage_report(const char* name, double secs, double size, void* user) {
  (void)user;
  std::printf("  [stage] %-26s %8.2f s   (%.0f)\n", name, secs, size);
  std::fflush(stdout);
}

static bool report(int it, double rel, void* user) {
  Prog* p = static_cast<Prog*>(user);
  const double secs = std::chrono::duration<double>(
      std::chrono::steady_clock::now() - p->t0).count();
  const double drop = (p->last > 0.0) ? p->last / std::max(rel, 1e-300) : 1.0;
  std::printf("    [%6.1fs] iter %7d  residual %.3e   (x%.3g over the last %d)\n",
              secs, it, rel, drop, it - p->last_it);
  std::fflush(stdout);
  p->last = rel; p->last_it = it;
  return true;   // never abort; the caller sees the trend and can Ctrl-C
}

int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: %s <lattice.beam> [E] [nu] [regions.txt] [rim_mm] [edge_mm]\n", argv[0]); return 2; }
  const std::string path = argv[1];
  const double E = argc > 2 ? std::atof(argv[2]) : 3500.0;
  const double nu = argc > 3 ? std::atof(argv[3]) : 0.35;
  const std::string regions_path = argc > 4 ? argv[4] : std::string();
  const double rim_mm  = argc > 5 ? std::atof(argv[5]) : 2.0;
  const double edge_mm = argc > 6 ? std::atof(argv[6]) : 6.0;

  double ox=0, oy=0, oz=0, h=1; int nx=0, ny=0, nz=0;
  std::vector<BeamSegment> segs;
  struct P { double x,y,z; int c; double v; };
  std::vector<P> bc_raw, ld_raw;
  { std::ifstream f(path); std::string ln;
    while (std::getline(f, ln)) {
      std::istringstream is(ln); std::string t; is >> t;
      if (t == "GRID") is >> ox >> oy >> oz >> h >> nx >> ny >> nz;
      else if (t == "SEG") { BeamSegment s; double r;
        is >> s.a.x >> s.a.y >> s.a.z >> s.b.x >> s.b.y >> s.b.z >> r;
        s.radius_mm = r; segs.push_back(s); }
      else if (t == "BC") { P p; is >> p.x >> p.y >> p.z >> p.c >> p.v; bc_raw.push_back(p); }
      else if (t == "LOAD") { P p; is >> p.x >> p.y >> p.z >> p.c >> p.v; ld_raw.push_back(p); }
    } }
  if (nx == 0) { std::fprintf(stderr, "no GRID header\n"); return 2; }
  std::vector<unsigned char> mk(static_cast<std::size_t>(nx)*ny*nz);
  { std::ifstream f(path + ".mask", std::ios::binary);
    f.read(reinterpret_cast<char*>(mk.data()), static_cast<std::streamsize>(mk.size()));
    if (!f) { std::fprintf(stderr, "cannot read %s.mask\n", path.c_str()); return 2; } }

  VoxelGrid g; g.nx=nx; g.ny=ny; g.nz=nz; g.spacing=h; g.origin=Vec3{ox,oy,oz};
  g.tags.assign(mk.size(), VoxelTag::Empty);
  std::vector<char> hex_mask(mk.size(), 0);
  // ★ MESH THE DENSE MATERIAL, LEAVE THE SPARSE INTERIOR TO THE BEAMS.
  // A lattice region is not uniform: bit2 marks the GRADE-TO-SOLID SKIN, which is
  // real solid and belongs in the hex mesh, while the rest of the region is sparse
  // struts the beam elements already represent. Meshing the whole region counts
  // every strut twice; excluding the whole region deletes the skin the lattice
  // attaches to (measured: 166 of 22,252 nodes touching solid). Neither part needs
  // a finer grid -- the solid is chunky and the struts are beams.
  std::size_t nhex=0, nskin=0, nsparse=0;
  for (std::size_t e=0;e<mk.size();++e) {
    if (!(mk[e] & 1u)) continue;
    g.tags[e]=VoxelTag::Interior;
    const bool in_region = (mk[e] & 2u) != 0;
    const bool is_skin   = (mk[e] & 4u) != 0;
    const bool use_shells = !regions_path.empty();
    if (!in_region) { hex_mask[e]=1; ++nhex; }
    else if (is_skin && !use_shells) { hex_mask[e]=1; ++nhex; ++nskin; }
    else { ++nsparse; if (is_skin) ++nskin; }
  }
  std::printf("hex mesh: %zu elements; region holds %zu skin + %zu sparse voxels\n",
              nhex, nskin, nsparse - nskin);
  std::fflush(stdout);

  // ── ★ THE GRADE-TO-SOLID SKIN AS SHELLS ───────────────────────────────────
  // The region prism has two faces; the skin on each is a thin plate (2 mm on a
  // 194 mm span, 1/97) and only 1.17 voxels thick, which a single hex through the
  // thickness represents badly. Both patches use the SAME normal so they share the
  // face's (u, w) basis -- the loops are expressed in it, and flipping the normal
  // would silently reinterpret them. The far patch is placed by moving its origin.
  std::vector<ShellPatch> shells;
  // ★ "mask" = MESH THE SKIN THE GENERATOR ACTUALLY FLAGGED. Deriving the plates
  // from the region OUTLINE (the branch below) was measured wrong on this part by
  // 219% of skin volume, in the wrong places. The mask carries the exact cells.
  if (regions_path == "mask") {
    std::vector<char> skinmask(mk.size(), 0);
    std::size_t ns2 = 0;
    for (std::size_t e = 0; e < mk.size(); ++e)
      if (mk[e] & 4u) { skinmask[e] = 1; ++ns2; }
    ShellPatch sp2;
    sp2.mesh = mesh_skin_midsurface(g, skinmask);
    sp2.thickness_mm = 0.0;                    // per-facet thickness carries it
    double vol = 0.0;
    for (std::size_t t = 0; t < sp2.mesh.triangles.size(); ++t) {
      const Vec3& A = sp2.mesh.nodes[(std::size_t)sp2.mesh.triangles[t].a];
      const Vec3& B = sp2.mesh.nodes[(std::size_t)sp2.mesh.triangles[t].b];
      const Vec3& C = sp2.mesh.nodes[(std::size_t)sp2.mesh.triangles[t].c];
      const double ux=B.x-A.x, uy=B.y-A.y, uz=B.z-A.z;
      const double vx=C.x-A.x, vy=C.y-A.y, vz=C.z-A.z;
      const double cx=uy*vz-uz*vy, cy=uz*vx-ux*vz, cz=ux*vy-uy*vx;
      vol += 0.5*std::sqrt(cx*cx+cy*cy+cz*cz) * sp2.mesh.tri_thickness[t];
    }
    const double cellvol = double(ns2) * g.spacing * g.spacing * g.spacing;
    std::printf("skin from MASK: %zu flagged cells (%.0f mm^3) -> %zu nodes, %zu facets, "
                "%.0f mm^3 of plate (%.1f%% of the cells)\n",
                ns2, cellvol, sp2.mesh.nodes.size(), sp2.mesh.triangles.size(),
                vol, 100.0*vol/cellvol);
    // ★ DROP THE SKIN FRAGMENTS THAT REACH NOTHING. The flagged cells are not one
    // body: a few small clusters sit out in the sparse interior, touching neither
    // the kept solid nor a load-bearing strut. As plates they are free bodies, and
    // the solver says so ("2124 of 269877 free dof lie in 18 sub-assemblies that
    // reach NO support"). They carry no load, exactly like the corner-hinged solid
    // islands and the load-free beam members, so drop them and SAY how much.
    {
      std::vector<std::vector<int>> tri_of(sp2.mesh.nodes.size());
      for (std::size_t t = 0; t < sp2.mesh.triangles.size(); ++t) {
        tri_of[(std::size_t)sp2.mesh.triangles[t].a].push_back((int)t);
        tri_of[(std::size_t)sp2.mesh.triangles[t].b].push_back((int)t);
        tri_of[(std::size_t)sp2.mesh.triangles[t].c].push_back((int)t);
      }
      std::vector<int> comp(sp2.mesh.triangles.size(), -1);
      int nc = 0;
      for (std::size_t t0 = 0; t0 < comp.size(); ++t0) {
        if (comp[t0] >= 0) continue;
        const int c = nc++;
        std::vector<int> st{(int)t0}; comp[t0] = c;
        while (!st.empty()) {
          const int t = st.back(); st.pop_back();
          const int nd[3] = {sp2.mesh.triangles[(std::size_t)t].a,
                             sp2.mesh.triangles[(std::size_t)t].b,
                             sp2.mesh.triangles[(std::size_t)t].c};
          for (int q : nd)
            for (int t2 : tri_of[(std::size_t)q])
              if (comp[(std::size_t)t2] < 0) { comp[(std::size_t)t2] = c; st.push_back(t2); }
        }
      }
      // a component is anchored if any of its nodes sits inside a meshed hex voxel
      std::vector<char> anchored((std::size_t)nc, 0);
      for (std::size_t t = 0; t < comp.size(); ++t) {
        const int nd[3] = {sp2.mesh.triangles[t].a, sp2.mesh.triangles[t].b,
                           sp2.mesh.triangles[t].c};
        for (int q : nd) {
          const Vec3& P = sp2.mesh.nodes[(std::size_t)q];
          const int ii=int((P.x-ox)/h), jj=int((P.y-oy)/h), kk=int((P.z-oz)/h);
          if (ii<0||jj<0||kk<0||ii>=nx||jj>=ny||kk>=nz) continue;
          if (hex_mask[(std::size_t)(kk*(std::size_t)ny+jj)*nx+ii])
            anchored[(std::size_t)comp[t]] = 1;
        }
      }
      ShellMesh keep;
      keep.thickness_mm = sp2.mesh.thickness_mm;
      std::vector<int> remap(sp2.mesh.nodes.size(), -1);
      std::size_t dropped = 0;
      for (std::size_t t = 0; t < comp.size(); ++t) {
        if (!anchored[(std::size_t)comp[t]]) { ++dropped; continue; }
        int nd[3] = {sp2.mesh.triangles[t].a, sp2.mesh.triangles[t].b, sp2.mesh.triangles[t].c};
        for (int& q : nd) {
          if (remap[(std::size_t)q] < 0) {
            remap[(std::size_t)q] = (int)keep.nodes.size();
            keep.nodes.push_back(sp2.mesh.nodes[(std::size_t)q]);
          }
          q = remap[(std::size_t)q];
        }
        keep.triangles.push_back({nd[0], nd[1], nd[2]});
        keep.tri_thickness.push_back(sp2.mesh.tri_thickness[t]);
      }
      int unanch = 0; for (int c = 0; c < nc; ++c) if (!anchored[(std::size_t)c]) ++unanch;
      std::printf("  skin: %d connected piece(s); dropped %d reaching no solid "
                  "(%zu of %zu facets, %.1f%%)\n", nc, unanch, dropped,
                  comp.size(), 100.0*double(dropped)/double(comp.size()));
      sp2.mesh = keep;
    }
    if (!sp2.mesh.triangles.empty()) shells.push_back(sp2);
  } else if (!regions_path.empty()) {
    std::ifstream f(regions_path); std::string ln; std::getline(f, ln);
    const int nreg = std::atoi(ln.c_str());
    for (int r = 0; r < nreg; ++r) {
      std::getline(f, ln); std::istringstream is(ln);
      Vec3 org{}, nr{}; double hu=0, hw=0, dep=0; int nloops=0;
      is >> org.x>>org.y>>org.z >> nr.x>>nr.y>>nr.z >> hu >> hw >> dep >> nloops;
      std::vector<std::vector<std::array<double,2>>> loops;
      for (int L=0; L<nloops; ++L) {
        std::getline(f, ln); std::istringstream ls(ln); int n2; ls >> n2;
        std::vector<std::array<double,2>> loop;
        for (int i2=0;i2<n2;++i2){ double a2,b2; ls>>a2>>b2; loop.push_back({a2,b2}); }
        loops.push_back(loop);
      }
      const Vec3 far{org.x + nr.x*(dep-rim_mm), org.y + nr.y*(dep-rim_mm),
                     org.z + nr.z*(dep-rim_mm)};
      for (const Vec3& o2 : {org, far}) {
        ShellPatch sp2;
        sp2.mesh = mesh_face_region_midsurface(o2, nr, hu, hw, rim_mm, loops, edge_mm);
        sp2.thickness_mm = rim_mm;
        if (!sp2.mesh.triangles.empty()) shells.push_back(sp2);
      }
    }
    std::size_t sn=0, st=0;
    for (const ShellPatch& sp2 : shells){ sn+=sp2.mesh.nodes.size(); st+=sp2.mesh.triangles.size(); }
    std::printf("shell skin: %zu patch(es), %zu nodes, %zu triangles at %.1f mm edge, "
                "%.1f mm thick\n", shells.size(), sn, st, edge_mm, rim_mm);
    std::fflush(stdout);
  }

  // ── ★ THE STRUT VOLUME IN EACH VOXEL ────────────────────────────────────────
  // Walk every segment in short steps, depositing pi r^2 dL into the voxel the step
  // lands in. The solid fraction is then 1 - (strut volume / voxel volume), clamped:
  // the beams already carry that material, so leaving it in the hex would count it
  // twice. This is exact in the LIMIT of fine steps and needs no grid refinement --
  // which is the point, since one voxel per strut diameter needs ~224 (9.7 GB) or
  // 256 (14.6 GB, past a 16 GB machine).
  const double vvox = h*h*h;
  std::vector<double> strut_vol(mk.size(), 0.0);
  for (const BeamSegment& s : segs) {
    const double dx=s.b.x-s.a.x, dy=s.b.y-s.a.y, dz=s.b.z-s.a.z;
    const double len = std::sqrt(dx*dx+dy*dy+dz*dz);
    const int nst = std::max(2, int(len/(0.2*h))+1);
    const double dv = M_PI*s.radius_mm*s.radius_mm*len/nst;
    for (int t=0;t<nst;++t) {
      const double f=(t+0.5)/nst;
      const int i=int((s.a.x+dx*f-ox)/h), j=int((s.a.y+dy*f-oy)/h), k=int((s.a.z+dz*f-oz)/h);
      if (i<0||j<0||k<0||i>=nx||j>=ny||k>=nz) continue;
      strut_vol[(std::size_t(k)*ny + j)*nx + i] += dv;
    }
  }
  std::vector<double> frac(mk.size(), 1.0);
  std::size_t touched=0; double worst=1.0, sum=0.0;
  for (std::size_t e=0;e<mk.size();++e) {
    if (!hex_mask[e] || strut_vol[e] <= 0.0) continue;
    double f = 1.0 - strut_vol[e]/vvox;
    if (f < kHexFractionFloor) f = kHexFractionFloor;
    frac[e]=f; ++touched; sum+=f; worst=std::min(worst,f);
  }
  std::printf("partial fill: %zu voxels contain struts; mean solid fraction %.4f, "
              "lowest %.4f  (voxel %.3f mm^3, strut d %.2f mm)\n",
              touched, touched? sum/touched : 1.0, worst, vvox, 2*segs[0].radius_mm);

  const int NX=nx+1, NY=ny+1;
  auto node_of=[&](double x,double y,double z){
    const int i=int(std::lround((x-ox)/h)), j=int(std::lround((y-oy)/h)), k=int(std::lround((z-oz)/h));
    if (i<0||j<0||k<0||i>nx||j>ny||k>nz) return -1;
    return int((std::size_t(k)*NY + j)*NX + i); };
  std::vector<DirichletBC> bcs; std::vector<NodalLoad> lds;
  for (const P& p : bc_raw) { const int n=node_of(p.x,p.y,p.z); if (n>=0) bcs.push_back({n,p.c,p.v}); }
  for (const P& p : ld_raw) { const int n=node_of(p.x,p.y,p.z); if (n>=0) lds.push_back({n,p.c,p.v}); }

  auto t0=std::chrono::steady_clock::now();
  BeamNetwork net = build_beam_network(segs);
  auto t1=std::chrono::steady_clock::now();
  std::printf("network: %zu nodes, %zu members  [weld %.2f s]\n", net.node_count(),
              net.member_count(), std::chrono::duration<double>(t1-t0).count());
  std::fflush(stdout);

  Prog pstate;
  CgProgress prog; prog.fn = &report; prog.user = &pstate; prog.every = 250;
  SolveStage stg; stg.fn = &stage_report;
  for (int attempt=0; attempt<8; ++attempt) {
    pstate = Prog{};
    auto s0=std::chrono::steady_clock::now();
    const CoupledLatticeSolve r = solve_coupled_lattice(
        g, hex_mask, net, bcs, lds, E, nu, 0.9, 1e-8, 100000, nullptr,
        shells.empty() ? nullptr : &shells, &prog, &stg);
    const double secs=std::chrono::duration<double>(std::chrono::steady_clock::now()-s0).count();
    std::printf("  skin bonded to solid at %zu of %zu shell nodes\n",
                r.shell_nodes_tied, r.shell_nodes);
    std::printf("  attempt %d: tied %zu/%zu (%zu WELDED to skin)  components %zu (%zu untied, %zu underconstrained)"
                "  [%.2f s]\n", attempt, r.beam_nodes_tied, net.node_count(),
                r.beam_nodes_welded_to_shell, r.restraint.components_total, r.restraint.components_unrestrained,
                r.restraint.components_underconstrained, secs);
    if (r.residual_share_solid + r.residual_share_shell + r.residual_share_beam > 0.0)
      std::printf("  WHERE THE RESIDUAL LIVES: solid %.1f%%  shell %.1f%%  beam %.1f%%"
                  "   worst dof: %s node %d component %d\n",
                  100*r.residual_share_solid, 100*r.residual_share_shell,
                  100*r.residual_share_beam, r.worst_residual_family.c_str(),
                  r.worst_residual_node, r.worst_residual_component);
    if (!r.refusal.empty()) {
      std::printf("    REFUSED: %s\n", r.refusal.c_str());
      std::size_t drop=0;
      for (std::size_t i=0;i<net.members.size();++i)
        if (r.restraint.member_unrestrained[i] || r.restraint.member_load_free[i] ||
            r.restraint.member_underconstrained[i]) ++drop;
      if (!drop) return 3;
      BeamNetwork pruned; pruned.nodes = net.nodes;
      for (std::size_t i=0;i<net.members.size();++i)
        if (!r.restraint.member_unrestrained[i] && !r.restraint.member_load_free[i] &&
            !r.restraint.member_underconstrained[i]) pruned.members.push_back(net.members[i]);
      std::printf("    dropping %zu load-free member(s), retrying\n", drop);
      net = pruned; continue;
    }
    std::printf("  LOAD LANDED: %zu of %zu loads (%.2f%% of |F| dropped); "
                "%zu of %zu bcs\n", r.loads_applied, r.loads_applied + r.loads_dropped,
                100.0 * r.load_dropped_fraction, r.bcs_applied,
                r.bcs_applied + r.bcs_dropped);
    std::printf("  CONVERGED: residual %.3e in %d iterations  [%.2f s]\n",
                r.residual, r.iterations, secs);
    std::printf("  PEAK STRUT STRESS: %.6g MPa  (member %d)\n",
                r.peak_member_stress_mpa, r.peak_member);
    // ★ HOW STIFF IS THE WHOLE PART? Strut stress alone cannot say whether the
    // lattice is genuinely unloaded or whether the model has simply been made too
    // stiff overall. Peak solid deflection is the global control: if two models
    // deflect the same but load the struts differently, the difference is in how the
    // lattice attaches; if one barely deflects, its skin is carrying the part.
    {
      double umax = 0.0;
      for (std::size_t n = 0; n + 2 < r.solid_displacement.size(); n += 3) {
        const double m2 = r.solid_displacement[n]*r.solid_displacement[n] +
                          r.solid_displacement[n+1]*r.solid_displacement[n+1] +
                          r.solid_displacement[n+2]*r.solid_displacement[n+2];
        if (m2 > umax) umax = m2;
      }
      std::printf("  COMPLIANCE (F.u): %.6g N.mm    peak solid deflection %.6g mm\n",
                  r.compliance, std::sqrt(umax));
    }
    // ★ PRINT THE DISTRIBUTION, NOT ONE NUMBER. The peak is a MAX over ~16,500
    // members, so comparing peaks between two models compares two single members and
    // reads as a large disagreement even when the fields agree everywhere else.
    // Percentiles say whether two models differ throughout or only in one strut.
    {
      std::vector<double> ss;
      for (double v : r.member_stress_mpa) if (v > 0.0) ss.push_back(v);
      std::sort(ss.begin(), ss.end());
      auto q = [&](double f) { return ss.empty() ? 0.0 : ss[(std::size_t)(f * (ss.size() - 1))]; };
      std::printf("  STRUT STRESS MPa over %zu members: p50 %.4f  p95 %.4f  "
                  "p99 %.4f  p99.9 %.4f  max %.4f\n",
                  ss.size(), q(0.50), q(0.95), q(0.99), q(0.999),
                  ss.empty() ? 0.0 : ss.back());
    }
    return 0;
  }
  return 3;
}
