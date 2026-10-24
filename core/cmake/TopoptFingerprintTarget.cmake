# TopoptFingerprintTarget.cmake — the BUILD-TIME core fingerprint (item 44).
#
#   topopt_add_fingerprint_target(<target> <source_dir> <out_dir>)
#       An always-run custom target that executes TopoptFingerprint.cmake on
#       every build: <out_dir>/topopt_build_fingerprint.h (rewritten only when
#       the fingerprint changes) and <out_dir>/topopt_build_fingerprint.txt.
#   topopt_use_fingerprint(<consumer> <target>)
#       <consumer> builds after <target> and can
#       `#include "topopt_build_fingerprint.h"` (TOPOPT_HAVE_BUILD_FINGERPRINT_H=1).
#
# The fingerprint used to be an execute_process at CONFIGURE time, so a rebuild
# after a new commit kept the OLD commit until someone re-ran cmake: a deployed
# binary could not prove which commit it was. The core's CMakeLists, its
# fingerprint test (tests/scripts/test_build_fingerprint.cmake) and — through
# the same target — app/scripts/build_core.sh all go through these functions.
set(TOPOPT_FINGERPRINT_SCRIPT "${CMAKE_CURRENT_LIST_DIR}/TopoptFingerprint.cmake")

function(topopt_add_fingerprint_target target source_dir out_dir)
  add_custom_target(${target}
    COMMAND "${CMAKE_COMMAND}"
            "-DTOPOPT_FP_SOURCE_DIR=${source_dir}"
            "-DTOPOPT_FP_HEADER=${out_dir}/topopt_build_fingerprint.h"
            "-DTOPOPT_FP_TEXT=${out_dir}/topopt_build_fingerprint.txt"
            -P "${TOPOPT_FINGERPRINT_SCRIPT}"
    BYPRODUCTS "${out_dir}/topopt_build_fingerprint.h"
               "${out_dir}/topopt_build_fingerprint.txt"
    COMMENT "Stamping the core build fingerprint (git HEAD + dirty marker)"
    VERBATIM)
  set_property(TARGET ${target} PROPERTY TOPOPT_FP_OUT_DIR "${out_dir}")
endfunction()

function(topopt_use_fingerprint consumer target)
  get_property(out_dir TARGET ${target} PROPERTY TOPOPT_FP_OUT_DIR)
  add_dependencies(${consumer} ${target})
  target_include_directories(${consumer} PRIVATE "${out_dir}")
  target_compile_definitions(${consumer} PRIVATE TOPOPT_HAVE_BUILD_FINGERPRINT_H=1)
endfunction()
