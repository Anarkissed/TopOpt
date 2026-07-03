cmake_minimum_required(VERSION 3.22)

project(topopt_core VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# CI configures with -DTOPOPT_REQUIRE_DEPS=ON so the pipeline proves the
# locked dependencies (ARCHITECTURE.md §4) are installed and findable.
# Nothing links against them yet; M1.2+ attaches them to targets.
option(TOPOPT_REQUIRE_DEPS "Fail configure unless OCCT, Eigen and lib3mf are found" OFF)
if(TOPOPT_REQUIRE_DEPS)
  find_package(OpenCASCADE CONFIG REQUIRED)
  find_package(Eigen3 CONFIG REQUIRED)
  find_package(lib3mf CONFIG REQUIRED)
endif()

add_library(topopt
  src/version.cpp
  src/materials/materials.cpp)
target_include_directories(topopt PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)

enable_testing()

add_executable(test_materials tests/unit/test_materials.cpp)
target_link_libraries(test_materials PRIVATE topopt)
add_test(NAME materials_loader COMMAND test_materials)
