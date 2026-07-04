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
endif()

add_library(topopt
  src/version.cpp
  src/materials/materials.cpp
  src/io/stl.cpp
  src/mesh/mesh.cpp
  src/voxel/voxelize.cpp)
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

# STEP import test (M1.4). Requires OCCT; built only when it is available (always
# the case in CI, which configures with -DTOPOPT_REQUIRE_DEPS=ON).
if(OpenCASCADE_FOUND)
  add_executable(test_step tests/unit/test_step.cpp)
  target_link_libraries(test_step PRIVATE topopt)
  target_compile_definitions(test_step PRIVATE
    STEP_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/step")
  add_test(NAME step_import COMMAND test_step)
endif()
