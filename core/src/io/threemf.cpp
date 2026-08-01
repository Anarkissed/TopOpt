#include "topopt/threemf.hpp"

#include <array>
#include <cstddef>
#include <string>
#include <vector>

#include "lib3mf_implicit.hpp"
#include "topopt/mesh.hpp"

// 3MF import/export via lib3mf (ROADMAP M6.1; ARCHITECTURE §4 "3MF primary
// (lib3mf)"). lib3mf is BSD (ARCHITECTURE §10) and is linked as a shared library
// by CMake. This translation unit is compiled only when lib3mf is found, exactly
// like the OCCT-gated step.cpp and the Eigen-gated FEA/SIMP sources.

namespace topopt {

void write_3mf_file(const std::string& path, const TriangleMesh& mesh) {
  try {
    Lib3MF::PWrapper wrapper = Lib3MF::CWrapper::loadLibrary();
    Lib3MF::PModel model = wrapper->CreateModel();
    Lib3MF::PMeshObject mesh_object = model->AddMeshObject();

    std::vector<Lib3MF::sPosition> vertices;
    vertices.reserve(mesh.vertices.size());
    for (const Vec3& v : mesh.vertices) {
      Lib3MF::sPosition p;
      p.m_Coordinates[0] = static_cast<Lib3MF_single>(v.x);
      p.m_Coordinates[1] = static_cast<Lib3MF_single>(v.y);
      p.m_Coordinates[2] = static_cast<Lib3MF_single>(v.z);
      vertices.push_back(p);
    }

    std::vector<Lib3MF::sTriangle> triangles;
    triangles.reserve(mesh.triangles.size());
    for (const std::array<int, 3>& t : mesh.triangles) {
      Lib3MF::sTriangle tri;
      tri.m_Indices[0] = static_cast<Lib3MF_uint32>(t[0]);
      tri.m_Indices[1] = static_cast<Lib3MF_uint32>(t[1]);
      tri.m_Indices[2] = static_cast<Lib3MF_uint32>(t[2]);
      triangles.push_back(tri);
    }

    mesh_object->SetGeometry(vertices, triangles);

    // A mesh object is only written if a build item references it. The transform
    // is the IDENTITY, deliberately and permanently.
    //
    // A 3MF build transform is ADVICE (handoff 2026-08-01-bake-build-
    // orientation): "place on bed", "auto-orient" and "arrange" all reset it,
    // and slicers do that routinely, sometimes on import. So an orientation that
    // lived here would be an orientation the slicer is free to discard, and the
    // certificate would describe an object it never produces. The certified
    // orientation is therefore baked into the VERTICES upstream of this function
    // (run_job rotates the mesh before handing it over) and this transform stays
    // identity as belt and braces: whatever the slicer does with it, the
    // geometry is already the right way up. Do NOT put a rotation here.
    Lib3MF::sTransform identity = wrapper->GetUniformScaleTransform(1.0f);
    model->AddBuildItem(mesh_object.get(), identity);

    Lib3MF::PWriter writer = model->QueryWriter("3mf");
    writer->WriteToFile(path);
  } catch (const Lib3MF::ELib3MFException& e) {
    throw ThreeMfError("3MF write failed for " + path + ": " + e.what());
  }
}

TriangleMesh read_3mf_file(const std::string& path) {
  try {
    Lib3MF::PWrapper wrapper = Lib3MF::CWrapper::loadLibrary();
    Lib3MF::PModel model = wrapper->CreateModel();
    Lib3MF::PReader reader = model->QueryReader("3mf");
    reader->ReadFromFile(path);

    Lib3MF::PMeshObjectIterator it = model->GetMeshObjects();
    if (!it->MoveNext()) {
      throw ThreeMfError("3MF file contains no mesh object: " + path);
    }
    Lib3MF::PMeshObject mesh_object = it->GetCurrentMeshObject();

    std::vector<Lib3MF::sPosition> vertices;
    std::vector<Lib3MF::sTriangle> triangles;
    mesh_object->GetVertices(vertices);
    mesh_object->GetTriangleIndices(triangles);

    TriangleMesh mesh;
    mesh.vertices.reserve(vertices.size());
    for (const Lib3MF::sPosition& p : vertices) {
      mesh.vertices.push_back(Vec3{static_cast<double>(p.m_Coordinates[0]),
                                   static_cast<double>(p.m_Coordinates[1]),
                                   static_cast<double>(p.m_Coordinates[2])});
    }
    mesh.triangles.reserve(triangles.size());
    for (const Lib3MF::sTriangle& tri : triangles) {
      mesh.triangles.push_back({static_cast<int>(tri.m_Indices[0]),
                                static_cast<int>(tri.m_Indices[1]),
                                static_cast<int>(tri.m_Indices[2])});
    }
    return mesh;
  } catch (const Lib3MF::ELib3MFException& e) {
    throw ThreeMfError("3MF read failed for " + path + ": " + e.what());
  }
}

}  // namespace topopt
