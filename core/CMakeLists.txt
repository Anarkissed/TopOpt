cmake_minimum_required(VERSION 3.22)

project(topopt_core VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# CI configures with -DTOPOPT_REQUIRE_DEPS=ON so the pipeline proves the
# locked dependencies (ARCHITECTURE.md §4) are installed and findable.
option(TOPOPT_REQUIRE_DEPS "Fail configure unless OCCT, Eigen and lib3mf are found" OFF)
if(TOPOPT_REQUIRE_DEPS)
  find_package(OpenCASCADE CONFIG REQUIRED)
  find_package(Eigen3 CONFIG REQUIRED)
  find_package(lib3mf CONFIG REQUIRED)
else()
  # Optional locally: if OCCT is installed the STEP importer (M1.4) builds and
  # its test runs; if not, the OCCT-free targets (materials, STL) still build so
  # a dependency-light local checkout is usable. CI always has OCCT (DEPS=ON),
  # so step_import always runs in the pipeline that is the source of truth.
  find_package(OpenCASCADE CONFIG QUIET)
  # Same for Eigen: the global FEA assembly/solve (M2.2) needs it, so build that
  # translation unit and its test only when Eigen is present. CI has Eigen
  # (DEPS=ON), so fea_assembly always runs in the pipeline.
  find_package(Eigen3 CONFIG QUIET)
endif()

add_library(topopt
  src/version.cpp
  src/materials/materials.cpp
  src/io/stl.cpp
  src/mesh/mesh.cpp
  src/voxel/voxelize.cpp
  src/fea/hex_element.cpp)
target_include_directories(topopt PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)

# STEP import (M1.4) requires OCCT. Compile it into the library and link the
# needed OCCT toolkits only when OCCT is present. OCCT is LGPL 2.1 and its
# imported targets are SHARED (dynamic linking only, ARCHITECTURE.md §4/§10).
if(OpenCASCADE_FOUND)
  target_sources(topopt PRIVATE src/io/step.cpp)
  # SYSTEM: OCCT's own headers emit deprecation warnings we can't fix; keep them
  # out of our build log without suppressing warnings on our sources.
  target_include_directories(topopt SYSTEM PRIVATE ${OpenCASCADE_INCLUDE_DIR})
  target_link_libraries(topopt PRIVATE
    TKDESTEP TKXSBase TKDE       # STEP read
    TKMesh                       # BRepMesh tessellation
    TKTopAlgo TKGeomAlgo TKPrim  # BRepGProp volume, topology exploration
    TKBRep TKGeomBase TKG3d TKG2d TKMath TKernel)
endif()

# Global FEA assembly + Dirichlet BCs + loads + direct solve (M2.2). Uses Eigen
# (ARCHITECTURE §4) for the sparse system; the public API stays Eigen-free, so
# Eigen links PRIVATE. Compiled only when Eigen is found (always in CI).
if(Eigen3_FOUND)
  target_sources(topopt PRIVATE src/fea/assembly.cpp)
  target_link_libraries(topopt PRIVATE Eigen3::Eigen)
endif()

enable_testing()

add_executable(test_materials tests/unit/test_materials.cpp)
target_link_libraries(test_materials PRIVATE topopt)
# Inject the absolute path to the committed seed materials.json so the on-disk
# load test (M1.2b) does not depend on the working directory.
target_compile_definitions(test_materials PRIVATE
  MATERIALS_JSON_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/materials/materials.json")
add_test(NAME materials_loader COMMAND test_materials)

add_executable(test_stl tests/unit/test_stl.cpp)
target_link_libraries(test_stl PRIVATE topopt)
# Inject the absolute path to the committed STL fixtures so the import tests do
# not depend on the working directory ctest runs from.
target_compile_definitions(test_stl PRIVATE
  STL_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/stl")
add_test(NAME stl_import COMMAND test_stl)

add_executable(test_voxel tests/unit/test_voxel.cpp)
target_link_libraries(test_voxel PRIVATE topopt)
# The voxelizer test drives the STL cube/sphere fixtures (no OCCT needed), so it
# reuses the same injected fixture directory as the STL test.
target_compile_definitions(test_voxel PRIVATE
  STL_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/stl")
add_test(NAME voxelize COMMAND test_voxel)

# Hex element stiffness test (M2.1). Pure C++/std (no OCCT, no Eigen), so it
# builds and runs in every configuration. Asserts against the human-authored
# reference fixture, whose directory is injected here.
add_executable(test_fea tests/unit/test_fea.cpp)
target_link_libraries(test_fea PRIVATE topopt)
target_compile_definitions(test_fea PRIVATE
  FEA_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/fea")
add_test(NAME hex_element COMMAND test_fea)

# Global FEA assembly/solve test (M2.2). Builds its 2x1x1 grid in code (no
# fixture) and needs the fea_solve implementation, so it is gated on Eigen like
# assembly.cpp. CI configures with -DTOPOPT_REQUIRE_DEPS=ON, so it always runs.
if(Eigen3_FOUND)
  add_executable(test_assembly tests/unit/test_assembly.cpp)
  target_link_libraries(test_assembly PRIVATE topopt)
  add_test(NAME fea_assembly COMMAND test_assembly)
endif()

# STEP import test (M1.4). Requires OCCT; built only when it is available (always
# the case in CI, which configures with -DTOPOPT_REQUIRE_DEPS=ON).
if(OpenCASCADE_FOUND)
  add_executable(test_step tests/unit/test_step.cpp)
  target_link_libraries(test_step PRIVATE topopt)
  target_compile_definitions(test_step PRIVATE
    STEP_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/step")
  add_test(NAME step_import COMMAND test_step)

  # STEP face -> voxel tagging test (M1.6). Drives the STEP cube fixture, so it
  # needs OCCT to import the solid and read its per-face triangulation.
  add_executable(test_tag tests/unit/test_tag.cpp)
  target_link_libraries(test_tag PRIVATE topopt)
  target_compile_definitions(test_tag PRIVATE
    STEP_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/step")
  add_test(NAME face_tag COMMAND test_tag)
endif()
