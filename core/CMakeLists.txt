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
  # Same for lib3mf: the 3MF export/import (M6.1) needs it, so build that
  # translation unit and its round-trip test only when lib3mf is present. CI has
  # lib3mf (DEPS=ON), so the 3MF round-trip always runs in the pipeline; the STL
  # export/round-trip is pure C++/std and builds regardless.
  find_package(lib3mf CONFIG QUIET)
endif()

add_library(topopt
  src/version.cpp
  src/materials/materials.cpp
  src/io/stl.cpp
  src/mesh/mesh.cpp
  src/voxel/voxelize.cpp
  src/fea/hex_element.cpp
  src/orient/orient.cpp
  src/settings/settings.cpp
  src/settings/report.cpp
  src/cli/job.cpp)
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
  # minimize_plastic end-to-end driver (M5.3): self-weight + volume-fraction
  # ladder stopping at margin < 1.5. Drives simp_optimize / simp_compliance, so
  # it is gated on Eigen like simp.cpp. CI has Eigen (DEPS=ON), so it always
  # builds in CI.
  target_sources(topopt PRIVATE src/simp/minimize_plastic.cpp)
  target_link_libraries(topopt PRIVATE Eigen3::Eigen)
endif()

# 3MF export/import (M6.1) requires lib3mf. Compile it into the library and link
# lib3mf only when it is present. lib3mf is BSD (ARCHITECTURE §10) and its
# imported target is SHARED (dynamic). CI has lib3mf (DEPS=ON), so the 3MF
# translation unit and its round-trip test always build in the pipeline. STL
# export is pure C++/std and already lives in the always-built src/io/stl.cpp.
if(lib3mf_FOUND)
  target_sources(topopt PRIVATE src/io/threemf.cpp)
  target_link_libraries(topopt PRIVATE lib3mf::lib3mf)
  # Lets the M6.2 job runner (src/cli/run_job.cpp) call the 3MF writer; without
  # lib3mf it rejects mesh_format "3mf" with a diagnostic instead.
  target_compile_definitions(topopt PRIVATE TOPOPT_HAVE_3MF)
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

# Settings rule engine (M5.1). Pure C++/std (no OCCT, no Eigen): the engine
# consumes settings/rules.json and maps material + stress margin + part size to
# walls/top-bottom layers/infill + pattern (FDM) or a solid-print directive
# (resin). Runs in every configuration; the committed human-seeded rule table's
# absolute path is injected so the real-table boundary tests do not depend on
# the working directory.
add_executable(test_settings tests/unit/test_settings.cpp)
target_link_libraries(test_settings PRIVATE topopt)
target_compile_definitions(test_settings PRIVATE
  SETTINGS_RULES_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/settings/rules.json")
add_test(NAME settings COMMAND test_settings)

# Job report (M5.2). Pure C++/std (no OCCT, no Eigen): the report data model is
# serialized to a single JSON document and schema-validated. Runs in every
# configuration like the other pure-C++/std tests; no fixture injection (the
# test builds its reports and JSON documents in code).
add_executable(test_report tests/unit/test_report.cpp)
target_link_libraries(test_report PRIVATE topopt)
add_test(NAME report COMMAND test_report)

# STL export round-trip (M6.1). Pure C++/std (no OCCT, no Eigen, no lib3mf): the
# STL writer lives in the always-built src/io/stl.cpp, and the test builds its
# meshes via marching cubes and round-trips them through write_stl_file /
# read_stl_file. Runs in every configuration. EXPORT_TMP_DIR (the build dir) is
# injected so the test writes its temporary files independent of the working
# directory ctest runs from.
add_executable(test_export tests/unit/test_export.cpp)
target_link_libraries(test_export PRIVATE topopt)
target_compile_definitions(test_export PRIVATE
  EXPORT_TMP_DIR="${CMAKE_CURRENT_BINARY_DIR}")
add_test(NAME export_stl COMMAND test_export)

# Job-file schema (M6.2). Pure C++/std (no OCCT, no Eigen, no lib3mf): the
# parser lives in the always-built src/cli/job.cpp, so the schema test runs in
# every configuration. The committed demo fixture's directory is injected — the
# fixture DEFINES the schema (DECISIONS.md 2026-07-09) and the test asserts the
# on-disk job parses to exactly its committed values.
add_executable(test_job tests/unit/test_job.cpp)
target_link_libraries(test_job PRIVATE topopt)
target_compile_definitions(test_job PRIVATE
  DEMO_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/demo")
add_test(NAME job_schema COMMAND test_job)

# Global FEA assembly/solve test (M2.2). Builds its 2x1x1 grid in code (no
# fixture) and needs the fea_solve implementation, so it is gated on Eigen like
# assembly.cpp. CI configures with -DTOPOPT_REQUIRE_DEPS=ON, so it always runs.
if(Eigen3_FOUND)
  add_executable(test_assembly tests/unit/test_assembly.cpp)
  target_link_libraries(test_assembly PRIVATE topopt)
  add_test(NAME fea_assembly COMMAND test_assembly)

  # Uniform-traction surface load test (M7.6-core / MOD-F1 D7). Builds its grids
  # in code (no fixture) and drives traction_loads, which lives in assembly.cpp,
  # so it is gated on Eigen the same way. CI configures with
  # -DTOPOPT_REQUIRE_DEPS=ON, so it always runs.
  add_executable(test_traction tests/unit/test_traction.cpp)
  target_link_libraries(test_traction PRIVATE topopt)
  add_test(NAME traction_loads COMMAND test_traction)

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

  # V5 validation gate (M4.4): orientation scoring (score_orientations /
  # max_interlayer_tension) on the hook fixture — the support proxy combined with
  # the z_knockdown-penalized max tension across layer planes must rank the
  # correct build direction first. Imports hook.stl, voxelizes, tags the load
  # case, drives fea_solve + hex8_stress to build the stress field, then scores.
  # Needs the FEA solve, so it is gated on Eigen; the fixture directory is
  # injected so the test does not depend on the working directory. CI configures
  # with -DTOPOPT_REQUIRE_DEPS=ON, so it always runs.
  add_executable(test_v5 tests/validation/test_v5.cpp)
  target_link_libraries(test_v5 PRIVATE topopt)
  target_compile_definitions(test_v5 PRIVATE
    ORIENT_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/orient")
  add_test(NAME gate_v5 COMMAND test_v5)

  # SIMP compliance + sensitivity test (M3.2). Builds its tiny grids in code (no
  # fixture) and drives simp_compliance (density field, penalized stiffness,
  # compliance, finite-difference sensitivity check), so it is gated on Eigen
  # like assembly.cpp / simp.cpp. CI configures with -DTOPOPT_REQUIRE_DEPS=ON, so
  # it always runs.
  add_executable(test_simp tests/unit/test_simp.cpp)
  target_link_libraries(test_simp PRIVATE topopt)
  add_test(NAME simp COMMAND test_simp)

  # Physical filter radius (M7.rmin): the mm->voxel density-filter radius scaling
  # (physical_filter_radius) that makes the minimum member thickness resolution
  # independent. Pure arithmetic, but the symbol lives in simp.cpp (topopt), so
  # gate it on Eigen like test_simp. CI configures with -DTOPOPT_REQUIRE_DEPS=ON,
  # so it always runs.
  add_executable(test_rmin tests/unit/test_rmin.cpp)
  target_link_libraries(test_rmin PRIVATE topopt)
  add_test(NAME rmin COMMAND test_rmin)

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

  # minimize_plastic end-to-end driver (M5.3): self-weight + descending
  # volume-fraction ladder stopping at the first rung whose worst-case stress
  # margin < 1.5, assembling the M5.2 job report per accepted variant. Builds a
  # cantilever-bracket grid in code (DECISIONS.md reserves tests/fixtures/ to the
  # maintainer) and drives minimize_plastic (simp_optimize), so it is gated on
  # Eigen like the other optimizer tests. The settings rule table's absolute path
  # is injected (like test_settings) so the real table is used. CI configures
  # with -DTOPOPT_REQUIRE_DEPS=ON, so it always runs.
  add_executable(test_minimize_plastic tests/validation/test_minimize_plastic.cpp)
  target_link_libraries(test_minimize_plastic PRIVATE topopt)
  target_compile_definitions(test_minimize_plastic PRIVATE
    SETTINGS_RULES_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/settings/rules.json")
  add_test(NAME minimize_plastic COMMAND test_minimize_plastic)

  # M7.anchor-integrity — the diagnosis-064 policy/display fixes on the core
  # mechanisms: the design-mask structural PAD (FIX 1), the reduction-ladder
  # FLOOR (FIX 2, incl. the disabled==legacy byte-identity), and check_v3 /
  # keep_largest_and_marked_components never deleting a frozen anchor island
  # (FIX 3). Drives minimize_plastic (simp_optimize), so it is Eigen-gated like
  # the other optimizer tests; the real settings rule table is injected as in
  # test_minimize_plastic. Builds its parts in code (no fixtures).
  add_executable(test_anchor_integrity tests/validation/test_anchor_integrity.cpp)
  target_link_libraries(test_anchor_integrity PRIVATE topopt)
  target_compile_definitions(test_anchor_integrity PRIVATE
    SETTINGS_RULES_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/settings/rules.json")
  add_test(NAME anchor_integrity COMMAND test_anchor_integrity)

  # MMA updater (M7.mma.1): the Method of Moving Asymptotes design updater,
  # exposed behind SimpOptions.updater = MMA, reproduces the OC minimum-
  # compliance benchmarks (the Gate V2 cantilever + clamped-beam geometries)
  # within 2% at the same volume fraction, and is correctly scoped (projection /
  # passive-region masks rejected). Builds its grids in code (no fixture) and
  # drives simp_optimize, so it is gated on Eigen like the other optimizer
  # tests. CI configures with -DTOPOPT_REQUIRE_DEPS=ON, so it always runs.
  add_executable(test_mma tests/validation/test_mma.cpp)
  target_link_libraries(test_mma PRIVATE topopt)
  add_test(NAME mma COMMAND test_mma)

  # MMA projection-gate (Option B): after the M7.mma.4 switchover the run path
  # must NOT enable a Heaviside projection schedule under MMA (simp_optimize
  # rejects it). Pins the pure gate predicate (projection_supported) and both
  # loop configs it selects — MMA runs cleanly with projection skipped; OC keeps
  # projection byte-identically. Drives simp_optimize, so Eigen-gated like the
  # other optimizer tests.
  add_executable(test_mma_projection_gate
    tests/validation/test_mma_projection_gate.cpp)
  target_link_libraries(test_mma_projection_gate PRIVATE topopt)
  add_test(NAME mma_projection_gate COMMAND test_mma_projection_gate)

  # Stress-constrained optimization (M7.mma.2): the aggregated von Mises
  # constraint on the MMA path — a finite-difference check of the adjoint
  # sensitivity of simp_stress_aggregate, and the behavioral invariants (a)/(b)/
  # (c) of a stress-constrained run. Drives simp_stress_aggregate /
  # simp_optimize_stress (simp.cpp), so it is Eigen-gated like the other
  # optimizer tests. When OCCT is present it ALSO consumes the committed
  # L-bracket stress fixture (mma2_stress_fixture.json + l-bracket.step) to
  # assert the fixture's invariant (a); the fixture directory is injected and the
  # STEP path guarded by TOPOPT_HAVE_STEP. CI configures with
  # -DTOPOPT_REQUIRE_DEPS=ON (Eigen + OCCT), so both paths always run in CI.
  add_executable(test_stress tests/validation/test_stress.cpp)
  target_link_libraries(test_stress PRIVATE topopt)
  if(OpenCASCADE_FOUND)
    target_compile_definitions(test_stress PRIVATE
      TOPOPT_HAVE_STEP
      DEMO_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/demo")
  endif()
  add_test(NAME stress COMMAND test_stress)
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

# 3MF export/import round-trip (M6.1). Requires lib3mf (the writer/reader live in
# the lib3mf-gated src/io/threemf.cpp). Builds its meshes via marching cubes and
# round-trips them through write_3mf_file / read_3mf_file, asserting the same
# mesh-level V3 properties + volume-within-0.5% as the STL test. EXPORT_TMP_DIR
# (the build dir) is injected for the temporary files. CI configures with
# -DTOPOPT_REQUIRE_DEPS=ON (lib3mf present), so it always runs in the pipeline.
if(lib3mf_FOUND)
  add_executable(test_3mf tests/unit/test_3mf.cpp)
  target_link_libraries(test_3mf PRIVATE topopt)
  target_compile_definitions(test_3mf PRIVATE
    EXPORT_TMP_DIR="${CMAKE_CURRENT_BINARY_DIR}")
  add_test(NAME export_3mf COMMAND test_3mf)
endif()

# topopt-cli (M6.2): the canonical headless entry point driving the full §5
# pipeline (STEP import -> watertight -> voxelize -> geometric fixture-face
# selection -> minimize_plastic -> report + mesh export). The job runner
# (src/cli/run_job.cpp) drives import_step_file AND minimize_plastic, so both
# OCCT and Eigen are required; the 3MF output path additionally uses lib3mf via
# TOPOPT_HAVE_3MF (above) and is rejected with a diagnostic when absent. CI
# configures with -DTOPOPT_REQUIRE_DEPS=ON (all three present), so the CLI and
# its integration test always build and run in the pipeline.
if(OpenCASCADE_FOUND AND Eigen3_FOUND)
  target_sources(topopt PRIVATE src/cli/run_job.cpp)

  add_executable(topopt_cli src/cli/main.cpp)
  set_target_properties(topopt_cli PROPERTIES OUTPUT_NAME topopt-cli)
  target_link_libraries(topopt_cli PRIVATE topopt)
  # Dev/CI defaults for --materials / --rules: the committed files. The flags
  # override them; the integration test passes both explicitly.
  target_compile_definitions(topopt_cli PRIVATE
    TOPOPT_CLI_DEFAULT_MATERIALS="${CMAKE_CURRENT_SOURCE_DIR}/src/materials/materials.json"
    TOPOPT_CLI_DEFAULT_RULES="${CMAKE_CURRENT_SOURCE_DIR}/src/settings/rules.json")

  # M6.2 integration test: the maintainer-authored demo job in
  # tests/fixtures/demo/ end-to-end, asserting the geometry facts and run
  # invariants of tests/fixtures/demo/expected_values.json, plus cross-process
  # determinism through the real topopt-cli binary. With lib3mf (always in CI)
  # it runs the pristine 3MF fixture job; without it (some local builds) it
  # runs a byte-patched STL copy written to the build dir — the fixture is
  # never modified.
  add_executable(test_cli tests/validation/test_cli.cpp)
  target_link_libraries(test_cli PRIVATE topopt)
  target_compile_definitions(test_cli PRIVATE
    DEMO_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/demo"
    MATERIALS_JSON_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/materials/materials.json"
    SETTINGS_RULES_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/settings/rules.json"
    CLI_TMP_DIR="${CMAKE_CURRENT_BINARY_DIR}"
    TOPOPT_CLI_EXE="$<TARGET_FILE:topopt_cli>")
  if(lib3mf_FOUND)
    target_compile_definitions(test_cli PRIVATE TOPOPT_HAVE_3MF)
  endif()
  add_test(NAME cli_demo COMMAND test_cli)
endif()
