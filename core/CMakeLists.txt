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
  src/fea/hex_element.cpp
  src/orient/orient.cpp)
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
  # SIMP density interpolation + penalized compliance/sensitivities (M3.2). It
  # drives the graded fea_solve_cg overload in assembly.cpp, so it is gated on
  # Eigen the same way. CI has Eigen (DEPS=ON), so it always builds in CI.
  target_sources(topopt PRIVATE src/simp/simp.cpp)
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

# Orientation candidate generation + support-volume proxy metric (M4.3). Pure
# C++/std (no OCCT, no Eigen): builds its meshes and voxel grids in code, so it
# runs in every configuration like the hex-element test.
add_executable(test_orient tests/unit/test_orient.cpp)
target_link_libraries(test_orient PRIVATE topopt)
add_test(NAME orientation COMMAND test_orient)

# Global FEA assembly/solve test (M2.2). Builds its 2x1x1 grid in code (no
# fixture) and needs the fea_solve implementation, so it is gated on Eigen like
# assembly.cpp. CI configures with -DTOPOPT_REQUIRE_DEPS=ON, so it always runs.
if(Eigen3_FOUND)
  add_executable(test_assembly tests/unit/test_assembly.cpp)
  target_link_libraries(test_assembly PRIVATE topopt)
  add_test(NAME fea_assembly COMMAND test_assembly)

  # Jacobi-preconditioned CG solver test (M2.3). Builds its grids in code (incl.
  # a 64^3 convergence gate) and needs fea_solve_cg, so it is gated on Eigen like
  # assembly.cpp. CI configures with -DTOPOPT_REQUIRE_DEPS=ON, so it always runs.
  add_executable(test_cg tests/unit/test_cg.cpp)
  target_link_libraries(test_cg PRIVATE topopt)
  add_test(NAME fea_cg COMMAND test_cg)

  # V1 validation gate (M2.4): cantilever + simply-supported beams vs
  # Euler-Bernoulli with convergence across 3 resolutions, plus the von Mises
  # stress field output. Builds its beam grids in code (no fixture) and drives
  # fea_solve_cg / fea_von_mises_field, so it is gated on Eigen. CI configures
  # with -DTOPOPT_REQUIRE_DEPS=ON, so it always runs.
  add_executable(test_beam tests/validation/test_beam.cpp)
  target_link_libraries(test_beam PRIVATE topopt)
  add_test(NAME beam_validation COMMAND test_beam)

  # V4 validation gate (M4.2): self-weight loading (self_weight_loads) and the
  # column-under-gravity axial-stress check. Builds its grids in code (no
  # fixture) and drives self_weight_loads / fea_solve / hex8_stress, so it is
  # gated on Eigen. CI configures with -DTOPOPT_REQUIRE_DEPS=ON, so it always
  # runs.
  add_executable(test_v4 tests/validation/test_v4.cpp)
  target_link_libraries(test_v4 PRIVATE topopt)
  add_test(NAME gate_v4 COMMAND test_v4)

  # SIMP compliance + sensitivity test (M3.2). Builds its tiny grids in code (no
  # fixture) and drives simp_compliance (density field, penalized stiffness,
  # compliance, finite-difference sensitivity check), so it is gated on Eigen
  # like assembly.cpp / simp.cpp. CI configures with -DTOPOPT_REQUIRE_DEPS=ON, so
  # it always runs.
  add_executable(test_simp tests/unit/test_simp.cpp)
  target_link_libraries(test_simp PRIVATE topopt)
  add_test(NAME simp COMMAND test_simp)

  # MBB validation gate (M3.3): a 2D-equivalent MBB slice driven through the
  # density filter + Optimality-Criteria update reproduces the classic 99-line
  # MBB result pattern. Builds its grid in code (no fixture) and drives
  # make_density_filter / oc_update / simp_compliance, so it is gated on Eigen
  # like simp.cpp. CI configures with -DTOPOPT_REQUIRE_DEPS=ON, so it always runs.
  add_executable(test_mbb tests/validation/test_mbb.cpp)
  target_link_libraries(test_mbb PRIVATE topopt)
  add_test(NAME mbb_validation COMMAND test_mbb)

  # Gate V2 validation (M3.4): the full 3D volume-fraction-targeted SIMP loop
  # (simp_optimize) on the 3D cantilever + clamped-beam benchmarks vs the
  # human-authored reference values in tests/fixtures/benchmarks.json. Drives
  # make_density_filter / simp_compliance / oc_update / simp_optimize, so it is
  # gated on Eigen like simp.cpp. The fixture directory is injected so the test
  # does not depend on the working directory ctest runs from. CI configures with
  # -DTOPOPT_REQUIRE_DEPS=ON, so it always runs in the pipeline.
  add_executable(test_gate_v2 tests/validation/test_gate_v2.cpp)
  target_link_libraries(test_gate_v2 PRIVATE topopt)
  target_compile_definitions(test_gate_v2 PRIVATE
    BENCH_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures")
  add_test(NAME gate_v2 COMMAND test_gate_v2)

  # Gate V3 property suite (M3.5): marching cubes on the final density
  # (threshold 0.5) + mesh cleanup, and the §7 V3 property checks (watertight,
  # single connected component, Load/Fixture retention, min feature size) run on
  # a real SIMP optimizer output. The marching-cubes / cleanup / property
  # functions live in the always-built mesh + voxel TUs, but the end-to-end run
  # drives simp_optimize, so the test is gated on Eigen like the other optimizer
  # tests. CI configures with -DTOPOPT_REQUIRE_DEPS=ON, so it always runs.
  add_executable(test_v3 tests/property/test_v3.cpp)
  target_link_libraries(test_v3 PRIVATE topopt)
  add_test(NAME property_v3 COMMAND test_v3)

  # Multi-variant runner (M3.6): one job -> several volume fractions -> one
  # design + printable mesh per fraction + the per-variant compliance report
  # (simp_optimize_variants). Drives simp_optimize per fraction and the
  # marching-cubes / cleanup / check_v3 path, so it is gated on Eigen like the
  # other optimizer tests. CI configures with -DTOPOPT_REQUIRE_DEPS=ON, so it
  # always runs.
  add_executable(test_variants tests/unit/test_variants.cpp)
  target_link_libraries(test_variants PRIVATE topopt)
  add_test(NAME variants COMMAND test_variants)

  # Passive regions (M3.7): the per-voxel design mask (Active / FrozenSolid /
  # FrozenVoid) applied through the mask-aware make_density_filter + simp_optimize
  # overloads — keep-out channels come out void and worsen compliance, keep-in
  # regions stay full material, Load/Fixture voxels are structurally retained, and
  # the filter does not bleed across mask boundaries. Drives simp_optimize, so it
  # is gated on Eigen like the other optimizer tests. CI configures with
  # -DTOPOPT_REQUIRE_DEPS=ON, so it always runs.
  add_executable(test_mask tests/property/test_mask.cpp)
  target_link_libraries(test_mask PRIVATE topopt)
  add_test(NAME passive_regions COMMAND test_mask)
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

  # mask_step_face test (M3.7): the M1.6 slab selection generalized with a voxel
  # depth, writing a design mask instead of grid tags. Drives the STEP cube
  # fixture (mask_step_face lives in the OCCT-gated step.cpp), so it needs OCCT.
  add_executable(test_mask_face tests/unit/test_mask_face.cpp)
  target_link_libraries(test_mask_face PRIVATE topopt)
  target_compile_definitions(test_mask_face PRIVATE
    STEP_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/step")
  add_test(NAME mask_face COMMAND test_mask_face)
endif()
