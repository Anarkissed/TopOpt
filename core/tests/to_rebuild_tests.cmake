# TO rebuild: the repo tests of docs/design/to-rebuild/04-tests.md, kept in this
# one file so the rebuild adds a single line to core/CMakeLists.txt.

# Test A: the exported surface of known shapes against the true shape. Measures
# only until stage 3 (today's export misses the 0.05 mm rule by design of the
# test); stage 3 adds --gate.
add_executable(test_to_surface_known_shapes tests/unit/test_to_surface_known_shapes.cpp)
target_link_libraries(test_to_surface_known_shapes PRIVATE topopt)
add_test(NAME to_surface_known_shapes COMMAND test_to_surface_known_shapes)

# Test E (first half): the strength number against a textbook stress, a plate
# with a hole pulled at an angle to the grid, at four resolutions. Drives
# analyze.cpp, so it is gated on Eigen like test_analyze_fixed_design. Measures
# only until stage 2, which adds --gate.
if(Eigen3_FOUND)
  add_executable(test_to_strength_known_stress tests/unit/test_to_strength_known_stress.cpp)
  target_link_libraries(test_to_strength_known_stress PRIVATE topopt)
  add_test(NAME to_strength_known_stress COMMAND test_to_strength_known_stress)
  # Second half: a thick ring with pressure on its curved inner face, put on by
  # stage 1's drawn-face loader. Measures only until stage 2.
  add_executable(test_to_strength_known_ring tests/unit/test_to_strength_known_ring.cpp)
  target_link_libraries(test_to_strength_known_ring PRIVATE topopt)
  add_test(NAME to_strength_known_ring COMMAND test_to_strength_known_ring)
  # One judge, evidence (a): textbook shapes through the file's fills against the certificate.
  add_executable(test_to_recheck_fill tests/unit/test_to_recheck_fill.cpp)
  target_link_libraries(test_to_recheck_fill PRIVATE topopt)
  # Long (about 20 minutes): every row at k = 1 to 16, gated at k = 8.  ctest -C Long -R to_recheck_fill
  add_test(NAME to_recheck_fill CONFIGURATIONS Long COMMAND test_to_recheck_fill --gate)
  set_tests_properties(to_recheck_fill PROPERTIES TIMEOUT 7200)
  # The thin-member rule: a beam in bending at 0.5, 1, 2 and 4 x the reading size.
  add_executable(test_to_strength_thin_member tests/unit/test_to_strength_thin_member.cpp)
  target_link_libraries(test_to_strength_thin_member PRIVATE topopt)
  add_test(NAME to_strength_thin_member COMMAND test_to_strength_thin_member)
  # The across-layer reading over a size, against Kirsch's tension along the pull.
  add_executable(test_to_strength_across_layers tests/unit/test_to_strength_across_layers.cpp)
  target_link_libraries(test_to_strength_across_layers PRIVATE topopt)
  add_test(NAME to_strength_across_layers COMMAND test_to_strength_across_layers)
  # The third shape (the reviewer's ruling 2026-11-26): an elliptical hole, a / b = 2,
  # Inglis peak 5 x. Judges "E x fill^2 at one voxel" on a shape it was not found on.
  add_executable(test_to_strength_known_ellipse tests/unit/test_to_strength_known_ellipse.cpp)
  target_link_libraries(test_to_strength_known_ellipse PRIVATE topopt)
  add_test(NAME to_strength_known_ellipse COMMAND test_to_strength_known_ellipse)
endif()

# Stage 2: printed grams at the user's walls and infill (ledger M-07).
if(Eigen3_FOUND)
  add_executable(test_to_printed_mass tests/unit/test_to_printed_mass.cpp)
  target_link_libraries(test_to_printed_mass PRIVATE topopt)
  add_test(NAME to_printed_mass COMMAND test_to_printed_mass)
endif()

# Stage 2, "one judge": how full of a file each voxel is (file_fill.hpp; not wired yet).
add_executable(test_to_file_fill tests/unit/test_to_file_fill.cpp)
target_link_libraries(test_to_file_fill PRIVATE topopt)
add_test(NAME to_file_fill COMMAND test_to_file_fill)

# Too small for the nozzle, and the automatic resolution (part_scale.hpp).
add_executable(test_to_part_scale tests/unit/test_to_part_scale.cpp)
target_link_libraries(test_to_part_scale PRIVATE topopt)
add_test(NAME to_part_scale COMMAND test_to_part_scale)

# Tests C and D: the area a load really lands on, and protection depth in mm.
# traction_loads lives in assembly.cpp (Eigen). Measures only until stage 1, which
# adds --gate.
if(Eigen3_FOUND)
  add_executable(test_to_true_loads tests/unit/test_to_true_loads.cpp)
  target_link_libraries(test_to_true_loads PRIVATE topopt)
  add_test(NAME to_true_loads COMMAND test_to_true_loads)
endif()

# Stage 5 (faster solves): the solver driven the way the Flexible bridge drives it
# (one thread, latch reset, multigrid then Jacobi-only, warm next step) on a soft
# graded field like the M2 stand's. Green before and after every solver change.
add_executable(test_to_solver_bridge_way tests/unit/test_to_solver_bridge_way.cpp)
target_link_libraries(test_to_solver_bridge_way PRIVATE topopt)
add_test(NAME to_solver_bridge_way COMMAND test_to_solver_bridge_way)

# Stage 5, B-05: the stable smoothers behind TOPOPT_SOLVER (per-level Jacobi and
# 4th-kind Chebyshev, three settings each): converge on multigrid without the l1
# retry, match a tight reference, identical bytes on a repeat, switch inert unset.
add_executable(test_to_solver_smoother tests/unit/test_to_solver_smoother.cpp)
target_link_libraries(test_to_solver_smoother PRIVATE topopt)
target_include_directories(test_to_solver_smoother PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
add_test(NAME to_solver_smoother COMMAND test_to_solver_smoother)
# Test K: the same job twice in one process, an unrelated solve between, same
# bytes. Runs the demo fixture through run_job, so it needs what test_cli needs.
# First result on record 2026-11-25 (same shape both times; only 3MF ids and
# wall-clock times differed, which the test blanks), so it runs as a gate.
# It takes over an hour while the demo part's solves fall back to the slow
# solver (handed to stage 5), so a plain ctest skips it. Run it with:
#   ctest -C Long -R to_same_job_twice
if(TARGET test_cli)
  add_executable(test_to_same_job_twice tests/validation/test_to_same_job_twice.cpp)
  target_link_libraries(test_to_same_job_twice PRIVATE topopt)
  target_compile_definitions(test_to_same_job_twice PRIVATE
    DEMO_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/demo"
    MATERIALS_JSON_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/materials/materials.json"
    SETTINGS_RULES_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/settings/rules.json"
    CLI_TMP_DIR="${CMAKE_CURRENT_BINARY_DIR}")
  add_test(NAME to_same_job_twice CONFIGURATIONS Long
           COMMAND test_to_same_job_twice --gate)
  set_tests_properties(to_same_job_twice PROPERTIES TIMEOUT 14400)
endif()

# Stage 1 against the LATTICE strength check (reviewer's ruling; LatticeReview's
# three made jobs): the stage switch off and on. Holds one rule, that the switch
# does not move the laid lattice; prints the rest for the stage report. Slow, so
# a plain ctest skips it:  ctest -C Long -R to_stage1_lattice_check
if(TARGET test_lattice_strength)
  add_executable(test_to_stage1_lattice_check tests/validation/test_to_stage1_lattice_check.cpp)
  target_link_libraries(test_to_stage1_lattice_check PRIVATE topopt)
  target_compile_definitions(test_to_stage1_lattice_check PRIVATE
    MATERIALS_JSON_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/materials/materials.json"
    SETTINGS_RULES_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/settings/rules.json"
    TMP_DIR="${CMAKE_CURRENT_BINARY_DIR}")
  add_test(NAME to_stage1_lattice_check CONFIGURATIONS Long COMMAND test_to_stage1_lattice_check)
  set_tests_properties(to_stage1_lattice_check PROPERTIES TIMEOUT 7200)
endif()

# Stage 5, E-01: one SolverSettings value and a SolverRunState passed into a solve; the
# old entry points byte-identical; runs isolated (test K).
add_executable(test_to_solver_settings tests/unit/test_to_solver_settings.cpp)
target_link_libraries(test_to_solver_settings PRIVATE topopt)
add_test(NAME to_solver_settings COMMAND test_to_solver_settings)
add_executable(test_to_solver_run_state tests/unit/test_to_solver_run_state.cpp)
target_link_libraries(test_to_solver_run_state PRIVATE topopt)
add_test(NAME to_solver_run_state COMMAND test_to_solver_run_state)
# Stage 5, S-05: the sensitivity loop on all cores; identical bytes at 1/3/6 threads.
add_executable(test_to_solve_threads tests/unit/test_to_solve_threads.cpp)
target_link_libraries(test_to_solve_threads PRIVATE topopt)
add_test(NAME to_solve_threads COMMAND test_to_solve_threads)
# Stage 5, B-06: the element product in the reduced system; identical bytes to the
# full-length product at 1/3/6 threads.
add_executable(test_to_solver_reduced_apply tests/unit/test_to_solver_reduced_apply.cpp)
target_link_libraries(test_to_solver_reduced_apply PRIVATE topopt)
target_include_directories(test_to_solver_reduced_apply PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
add_test(NAME to_solver_reduced_apply COMMAND test_to_solver_reduced_apply)
# Stage 5, THE CONNECTION RULE, support-only form (the reviewer's ruling 2026-11-26): a piece is held
# only through a support; a loose piece's registered weight leaves with it; an applied load on a
# loose piece refuses the solve at once (FeaLoadUnheld); outside the scope, today's bytes.
add_executable(test_to_solver_connection_rule tests/unit/test_to_solver_connection_rule.cpp)
target_link_libraries(test_to_solver_connection_rule PRIVATE topopt)
target_include_directories(test_to_solver_connection_rule PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
add_test(NAME to_solver_connection_rule COMMAND test_to_solver_connection_rule)

# Stage 1, M6 (LatticeReview for TOReview): on the strength grid, the protected skin against the lattice cubes, the
# switch off and `face` (jobs A and B as test_to_stage1_lattice_check makes them). Prints the counts, pins nothing.
#   ctest -C Long -R to_stage1_lattice_masks
if(TARGET test_lattice_strength)
  add_executable(test_to_stage1_lattice_masks tests/validation/test_to_stage1_lattice_masks.cpp)
  target_link_libraries(test_to_stage1_lattice_masks PRIVATE topopt)
  target_compile_definitions(test_to_stage1_lattice_masks PRIVATE
    MATERIALS_JSON_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/materials/materials.json"
    SETTINGS_RULES_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/settings/rules.json"
    TMP_DIR="${CMAKE_CURRENT_BINARY_DIR}")
  add_test(NAME to_stage1_lattice_masks CONFIGURATIONS Long COMMAND test_to_stage1_lattice_masks)
  set_tests_properties(to_stage1_lattice_masks PROPERTIES TIMEOUT 7200)
endif()

# A tool, not a test: writes the made sample part (an L-bracket with a filled
# corner) and its job, for the measurements his own parts cannot give.
add_executable(to_sample_part tests/tools/to_sample_part.cpp)
target_link_libraries(to_sample_part PRIVATE topopt)
