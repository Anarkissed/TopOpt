// faces_probe PART.stl: each planar face's id, normal and centroid (the ids a job names).
#include "topopt/part.hpp"
#include <cstdio>
using namespace topopt;
int main(int argc, char** argv) {
  const StepModel m = import_part(argv[1]).model;
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(f)];
    double c[3] = {0, 0, 0};
    int n = 0;
    for (std::size_t t = 0; t < m.mesh.triangles.size(); ++t) {
      if (m.triangle_face[t] != f) continue;
      for (int k = 0; k < 3; ++k) {
        const Vec3& v = m.mesh.vertices[static_cast<std::size_t>(m.mesh.triangles[t][k])];
        c[0] += v.x; c[1] += v.y; c[2] += v.z; ++n;
      }
    }
    std::printf("%d %.3f %.3f %.3f %.3f %.3f %.3f\n", f, fi.plane_normal.x, fi.plane_normal.y,
                fi.plane_normal.z, c[0] / n, c[1] / n, c[2] / n);
  }
}
