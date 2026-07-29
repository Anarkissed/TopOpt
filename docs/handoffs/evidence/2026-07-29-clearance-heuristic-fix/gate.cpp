// gate.cpp — MEASURE the proposed fastener-bore gate on every mesh fixture.
//
// For each fixture, runs import_part + segment_mesh_faces (the app's mesh path),
// then for every cylinder pseudo-face computes the three fastener discriminators
// the diagnosis identified (analyze.cpp): angular WRAP about the fitted axis,
// CONCAVITY (normals toward axis), and radius/bbox. It prints, per candidate
// bore, the OLD verdict (isCurved 5deg fan → any curved region is a bore) and the
// NEW verdict (the fastener gate), plus a summary count per fixture so a single
// run is the whole before/after C1 table.
//
// This is the exact logic mirrored in Swift FaceTopology.isFastenerBore.

#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/segment.hpp"
#include "topopt/step.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using namespace topopt;
static const double kPi = 3.14159265358979323846;

static Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x-b.x,a.y-b.y,a.z-b.z}; }
static double dot(const Vec3& a, const Vec3& b){ return a.x*b.x+a.y*b.y+a.z*b.z; }
static Vec3 cross(const Vec3& a,const Vec3& b){ return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}; }
static double len(const Vec3& a){ return std::sqrt(dot(a,a)); }
static Vec3 nrm(const Vec3& a){ double l=len(a); return l>0?Vec3{a.x/l,a.y/l,a.z/l}:Vec3{0,0,0}; }

static Vec3 tri_normal(const TriangleMesh& m, int t) {
  const auto& tr=m.triangles[(size_t)t];
  Vec3 e1=sub(m.vertices[(size_t)tr[1]],m.vertices[(size_t)tr[0]]);
  Vec3 e2=sub(m.vertices[(size_t)tr[2]],m.vertices[(size_t)tr[0]]);
  return nrm(cross(e1,e2));
}
static Vec3 tri_centroid(const TriangleMesh& m, int t) {
  const auto& tr=m.triangles[(size_t)t];
  const Vec3&a=m.vertices[(size_t)tr[0]];const Vec3&b=m.vertices[(size_t)tr[1]];const Vec3&c=m.vertices[(size_t)tr[2]];
  return {(a.x+b.x+c.x)/3,(a.y+b.y+c.y)/3,(a.z+b.z+c.z)/3};
}

// Max pairwise triangle-normal fan (deg): the app's isCurved metric (5deg).
static double face_max_fan_deg(const TriangleMesh& m,
                               const std::vector<int>& tri_face, int face) {
  std::vector<Vec3> ns;
  for (size_t t = 0; t < tri_face.size(); ++t)
    if (tri_face[t] == face) { Vec3 n=tri_normal(m,(int)t); if(n.x||n.y||n.z) ns.push_back(n); }
  if (ns.size() < 2) return -1.0;
  double worst = 0.0;
  for (size_t i=0;i<ns.size();++i) for (size_t j=i+1;j<ns.size();++j){
    double d=dot(ns[i],ns[j]); d=std::max(-1.0,std::min(1.0,d));
    worst=std::max(worst,std::acos(d)*180.0/kPi);
  }
  return worst;
}

struct Discrim { double wrap; bool concave; double rpct; };

// Angular wrap about the axis + concavity vote — the analyze.cpp measures, keyed
// off the fitted axis in StepFaceInfo. Mirror of Swift boreWrapAndConcavity.
static Discrim discrim(const TriangleMesh& mesh, const std::vector<int>& tris,
                       const StepFaceInfo& fi, double diag) {
  const Vec3 axP = fi.axis_point, axD = nrm(fi.axis_dir);
  Vec3 seed = std::fabs(axD.x)<0.9?Vec3{1,0,0}:Vec3{0,1,0};
  Vec3 u = nrm(sub(seed,{axD.x*dot(seed,axD),axD.y*dot(seed,axD),axD.z*dot(seed,axD)}));
  Vec3 v = nrm(cross(axD,u));
  std::vector<double> angs; double concave=0, convex=0;
  for (int t : tris) {
    Vec3 c=tri_centroid(mesh,t), rel=sub(c,axP);
    angs.push_back(std::atan2(dot(rel,v),dot(rel,u)));
    Vec3 radial=nrm(sub(rel,{axD.x*dot(rel,axD),axD.y*dot(rel,axD),axD.z*dot(rel,axD)}));
    if (dot(tri_normal(mesh,t),radial)<0) concave+=1; else convex+=1;
  }
  std::sort(angs.begin(),angs.end());
  double wrap=0;
  if (angs.size()>1){
    double maxgap=0;
    for(size_t i=1;i<angs.size();++i) maxgap=std::max(maxgap,angs[i]-angs[i-1]);
    maxgap=std::max(maxgap,(angs.front()+2*kPi)-angs.back());
    wrap=(2*kPi-maxgap)*180.0/kPi;
  }
  return {wrap, concave>convex, 100.0*fi.cylinder_radius_mm/diag};
}

// ---- The candidate gate (mirror of the shipping Swift predicate). --------
static const double kWrapMinDeg     = 300.0;  // through-hole wraps the axis
static const double kMaxRadiusFrac  = 0.40;   // r <= 0.40 * bbox diag (sanity)

static bool fastener_gate(const StepFaceInfo& fi, const Discrim& d, double diag) {
  if (fi.kind != StepSurfaceKind::Cylinder || fi.cylinder_radius_mm <= 0) return false;
  if (!d.concave) return false;
  if (d.wrap < kWrapMinDeg) return false;
  if (fi.cylinder_radius_mm > kMaxRadiusFrac * diag) return false;
  return true;
}

static void probe(const std::string& label, const std::string& path, int realHoles) {
  std::printf("\n============================================================\n");
  std::printf("FIXTURE: %s\n", label.c_str());
  PartModel pm;
  try { pm = import_part(path); }
  catch (const std::exception& e) { std::printf("  IMPORT FAILED: %s\n", e.what()); return; }
  const StepModel& sm = pm.model; const TriangleMesh& mesh = sm.mesh;
  Vec3 lo,hi; bounding_box(mesh,lo,hi); double diag=len(sub(hi,lo));
  std::printf("  %zu tris, %d faces, bbox diag %.1f mm | real holes = %d\n",
              mesh.triangles.size(), sm.face_count, diag, realHoles);
  std::vector<std::vector<int>> byface((size_t)sm.face_count);
  for (size_t t=0;t<sm.triangle_face.size();++t){int f=sm.triangle_face[t];if(f>=0&&f<sm.face_count)byface[(size_t)f].push_back((int)t);}

  int old_bore=0, old_blank=0, new_bore=0;
  std::printf("  %-4s %-6s %8s %7s %6s %-8s | %-10s | %s\n",
              "face","kind","fitR","r/bbox%","wrap","concave","OLD","NEW gate");
  for (int f=0; f<sm.face_count; ++f) {
    const StepFaceInfo& fi = sm.faces[(size_t)f];
    double fan = face_max_fan_deg(mesh, sm.triangle_face, f);
    bool oldBore = fan > 5.0;              // isCurved
    bool oldCyl  = fi.kind==StepSurfaceKind::Cylinder && fi.cylinder_radius_mm>0;
    if (oldBore) { old_bore++; if(!oldCyl) old_blank++; }
    Discrim d = (fi.kind==StepSurfaceKind::Cylinder)
                ? discrim(mesh, byface[(size_t)f], fi, diag) : Discrim{-1,false,0};
    bool newBore = fastener_gate(fi, d, diag);
    if (newBore) new_bore++;
    if (oldBore || newBore) {
      char rb[16]; if(oldCyl) std::snprintf(rb,sizeof rb,"%8.2f",fi.cylinder_radius_mm); else std::snprintf(rb,sizeof rb,"%8s","-");
      std::printf("  %-4d %-6s %s %7.1f %6.0f %-8s | %-10s | %s\n",
                  f, fi.kind==StepSurfaceKind::Cylinder?"Cyl":(fi.kind==StepSurfaceKind::Plane?"Plane":"Other"),
                  rb, d.rpct, d.wrap, (fi.kind==StepSurfaceKind::Cylinder?(d.concave?"concave":"convex"):"-"),
                  oldBore?(oldCyl?"bore":"BLANK-Auto"):"-", newBore?"BORE":"-");
    }
  }
  std::printf("  SUMMARY  OLD: %d bores (%d blank-Auto)  |  NEW: %d bores  |  real holes: %d\n",
              old_bore, old_blank, new_bore, realHoles);
  std::printf("  %s\n", (new_bore==realHoles ? "  [OK] new count == real holes"
                        : (new_bore<realHoles ? "  [under] new < real (escape hatch)"
                                              : "  [OVER] new > real")));
}

int main(int argc, char** argv) {
  const std::string root = argc>1?argv[1]:".";
  struct F { std::string label, rel; int holes; };
  const std::vector<F> fx = {
    {"WallMount_ShelfBracket", "core/tests/fixtures/mesh/WallMount_ShelfBracket.stl", 3},
    {"plate_bore", "core/tests/fixtures/mesh/plate_bore.stl", 1},
    {"filleted_bore_plate", "core/tests/fixtures/mesh/filleted_bore_plate.stl", 1},
    {"l-bracket", "docs/handoffs/evidence/2026-07-25-mesh-job-params/l-bracket.stl", 2},
    {"hook", "core/tests/fixtures/orient/hook.stl", 0},
    {"sphere_r10mm", "core/tests/fixtures/stl/sphere_r10mm.stl", 0},
    {"cube_10mm", "core/tests/fixtures/stl/cube_10mm.stl", 0},
    {"sample_cube", "app/TopOpt/Resources/sample_cube.stl", 0},
    {"bracket_clean", "docs/handoffs/evidence/2026-07-24-mesh-repair/bracket_clean.stl", 1},
    {"bracket_small_hole", "docs/handoffs/evidence/2026-07-24-mesh-repair/bracket_small_hole.stl", 1},
  };
  std::printf("GATE: wrap>=%.0f deg, concave, radius<=%.2f*diag\n", kWrapMinDeg, kMaxRadiusFrac);
  for (auto& f : fx) probe(f.label, root+"/"+f.rel, f.holes);
  return 0;
}
