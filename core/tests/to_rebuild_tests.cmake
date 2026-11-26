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
endif()

# Tests C and D: the area a load really lands on, and protection depth in mm.
# traction_loads lives in assembly.cpp (Eigen). Measures only until stage 1, which
# adds --gate.
if(Eigen3_FOUND)
  add_executable(test_to_true_loads tests/unit/test_to_true_loads.cpp)
  target_link_libraries(test_to_true_loads PRIVATE topopt)
  add_test(NAME to_true_loads COMMAND test_to_true_loads)
endif()
