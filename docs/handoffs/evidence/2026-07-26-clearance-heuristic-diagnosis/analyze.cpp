// analyze.cpp — geometric ground-truth for the shelf bracket's cylinder faces.
//
// For every pseudo-face the segmenter classified Cylinder, measure whether it is
// actually a fastener HOLE or a misfit of a flat/gently-curved wall. Two decisive
// discriminators, both independent of the segmenter's own accept/reject logic:
//
//   radius/bbox : a real bolt hole is small relative to the part; a misfit fits a
//                 cylinder whose radius is a large fraction of the bounding box.
//   wrap        : a through-hole's wall wraps the full 360 deg around its axis;
//                 a flat wall that happened to fit a huge circle covers only a
//                 narrow arc.
//   concavity   : a hole is CONCAVE (surface normals point toward the axis); an
//                 outer rounded corner / boss is CONVEX (normals point away).
//
// This is the check the heuristic SHOULD be doing and is not.

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
static Vec3 norm(const Vec3& a){ double l=len(a); return l>0?Vec3{a.x/l,a.y/l,a.z/l}:Vec3{0,0,0}; }

static Vec3 tri_normal(const TriangleMesh& m, int t) {
  const auto& tr=m.triangles[(size_t)t];
  Vec3 e1=sub(m.vertices[(size_t)tr[1]],m.vertices[(size_t)tr[0]]);
  Vec3 e2=sub(m.vertices[(size_t)tr[2]],m.vertices[(size_t)tr[0]]);
  return norm(cross(e1,e2));
}
static Vec3 tri_centroid(const TriangleMesh& m, int t) {
  const auto& tr=m.triangles[(size_t)t];
  const Vec3&a=m.vertices[(size_t)tr[0]];const Vec3&b=m.vertices[(size_t)tr[1]];const Vec3&c=m.vertices[(size_t)tr[2]];
  return {(a.x+b.x+c.x)/3,(a.y+b.y+c.y)/3,(a.z+b.z+c.z)/3};
}

int main(int argc, char** argv) {
  const std::string root = argc > 1 ? argv[1] : ".";
  const std::string path = root + "/core/tests/fixtures/mesh/WallMount_ShelfBracket.stl";
  PartModel pm = import_part(path);
  const StepModel& sm = pm.model;
  const TriangleMesh& mesh = sm.mesh;
  Vec3 lo, hi; bounding_box(mesh, lo, hi);
  const double diag = len(sub(hi, lo));
  std::printf("WallMount_ShelfBracket: %zu tris, %d faces, bbox diag %.2f mm\n",
              mesh.triangles.size(), sm.face_count, diag);
  std::printf("bbox = [%.1f %.1f %.1f] .. [%.1f %.1f %.1f]\n",
              lo.x,lo.y,lo.z, hi.x,hi.y,hi.z);
  std::printf("\n%-4s %8s %7s %6s %8s %-9s  %s\n",
              "face","radius","r/bbox%","wrap","tris","shape","classification");

  // Group triangles by face.
  std::vector<std::vector<int>> byface((size_t)sm.face_count);
  for (size_t t=0;t<sm.triangle_face.size();++t){int f=sm.triangle_face[t];if(f>=0&&f<sm.face_count)byface[(size_t)f].push_back((int)t);}

  int real_holes=0;
  for (int f=0; f<sm.face_count; ++f) {
    const StepFaceInfo& fi = sm.faces[(size_t)f];
    if (fi.kind != StepSurfaceKind::Cylinder) continue;
    const Vec3 axP = fi.axis_point, axD = norm(fi.axis_dir);
    // basis perpendicular to axis
    Vec3 seed = std::fabs(axD.x)<0.9?Vec3{1,0,0}:Vec3{0,1,0};
    Vec3 u = norm(sub(seed, {axD.x*dot(seed,axD),axD.y*dot(seed,axD),axD.z*dot(seed,axD)}));
    Vec3 v = norm(cross(axD,u));
    // angular coverage + concavity vote
    std::vector<double> angs; double concave=0, convex=0;
    for (int t : byface[(size_t)f]) {
      Vec3 c = tri_centroid(mesh,t);
      Vec3 rel = sub(c, axP);
      double pu=dot(rel,u), pv=dot(rel,v);
      angs.push_back(std::atan2(pv,pu));
      Vec3 radial = norm(sub(rel, {axD.x*dot(rel,axD),axD.y*dot(rel,axD),axD.z*dot(rel,axD)}));
      double nd = dot(tri_normal(mesh,t), radial);  // >0 outward (convex), <0 inward (concave)
      if (nd < 0) concave += 1; else convex += 1;
    }
    std::sort(angs.begin(),angs.end());
    double wrap = 0;
    if (angs.size()>1){
      double maxgap=0;
      for(size_t i=1;i<angs.size();++i) maxgap=std::max(maxgap,angs[i]-angs[i-1]);
      maxgap=std::max(maxgap, (angs.front()+2*kPi)-angs.back());
      wrap = (2*kPi - maxgap)*180.0/kPi;
    }
    const double rpct = 100.0*fi.cylinder_radius_mm/diag;
    const char* shape = concave>convex ? "concave" : "convex";
    const bool full = wrap > 300;
    const bool small = rpct < 15;
    const bool hole = full && small && concave>convex;
    if (hole) real_holes++;
    std::printf("%-4d %8.2f %7.1f %6.0f %8d %-9s  %s\n",
                f, fi.cylinder_radius_mm, rpct, wrap, (int)byface[(size_t)f].size(),
                shape, hole?"REAL through-hole":"misfit / not-a-hole");
  }
  std::printf("\nGROUND TRUTH: %d real fastener holes (full 360 wrap, small radius, concave)\n", real_holes);
  return 0;
}
