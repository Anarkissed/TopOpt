# test_build_fingerprint.cmake — ★ THE CORE FINGERPRINT IS TAKEN AT BUILD TIME
# (item 44). Run as a ctest (build_fingerprint_rebuild) in SCRIPT mode:
#
#   cmake -DCORE_DIR=<core> -DWORK_DIR=<scratch> -DGENERATOR=<gen> -DCXX=<c++>
#         -P tests/scripts/test_build_fingerprint.cmake
#
# A throwaway git repo whose core/ is a toy project wired through the SAME
# core/cmake/TopoptFingerprintTarget.cmake (and so the same stamping script) as
# topopt-cli, with an app/scripts/build_core.sh beside it passed as the extra
# path, as the core's CMakeLists does. The fingerprint is a TREE hash: the first
# 12 hex of SHA-1("<HEAD:core>\n<HEAD:app/scripts/build_core.sh>\n").
# CMake's configure step runs exactly ONCE; then:
#   1. build              -> fingerprint == the tree hash (12), dirty 0, and
#                            COMMIT == HEAD (12)
#   2. no-op build        -> the generated header is NOT rewritten
#   3. commit to core/, build -> a NEW tree hash (the old configure-time stamp
#                            kept the first one here: RED before)
#   3b. a docs-only commit, build -> the SAME fingerprint (COMMIT moves); the HEAD
#                            commit stamp moved here: RED before
#   3c. commit to build_core.sh, build -> a NEW tree hash
#   4. edit tracked file under core/ -> "<tree12>-dirty-<diff8>", dirty 1
#   5. a different edit   -> a different <diff8>
#   5b. restore it, edit build_core.sh uncommitted -> dirty too
#   6. restore it, edit a file OUTSIDE core/ and build_core.sh -> clean again
#   7. the .txt the app script reads == the header's fingerprint
#   8. configure ran once (no step above re-ran it)
cmake_minimum_required(VERSION 3.22)
foreach(v CORE_DIR WORK_DIR GENERATOR CXX)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "test_build_fingerprint: -D${v}= is required")
  endif()
endforeach()
find_program(GIT git)
if(NOT GIT)
  message(FATAL_ERROR "test_build_fingerprint: git not found")
endif()

set(failures 0)
set(checks 0)
function(expect ok msg)
  math(EXPR n "${checks} + 1")
  set(checks ${n} PARENT_SCOPE)
  if(ok)
    message(STATUS "ok:   ${msg}")
  else()
    message(STATUS "FAIL: ${msg}")
    math(EXPR f "${failures} + 1")
    set(failures ${f} PARENT_SCOPE)
  endif()
endfunction()

file(REMOVE_RECURSE "${WORK_DIR}")
set(REPO "${WORK_DIR}/repo")
set(SRC "${REPO}/core")
set(BUILD "${WORK_DIR}/build")
file(MAKE_DIRECTORY "${SRC}")

set(toy_cmake [=[
cmake_minimum_required(VERSION 3.22)
project(fp_toy LANGUAGES CXX)
file(APPEND "${CMAKE_BINARY_DIR}/configure_count.txt" "x")
include("@CORE_DIR@/cmake/TopoptFingerprintTarget.cmake")
topopt_add_fingerprint_target(toy_fingerprint "${CMAKE_CURRENT_SOURCE_DIR}"
                              "${CMAKE_BINARY_DIR}/generated/fingerprint"
                              "../app/scripts/build_core.sh")
add_executable(toy main.cpp)
topopt_use_fingerprint(toy toy_fingerprint)
]=])
string(REPLACE "@CORE_DIR@" "${CORE_DIR}" toy_cmake "${toy_cmake}")
file(WRITE "${SRC}/CMakeLists.txt" "${toy_cmake}")
file(WRITE "${SRC}/main.cpp" [=[
#include <cstdio>
#include "topopt_build_fingerprint.h"
int main() {
  std::printf("fingerprint=%s commit=%s dirty=%d\n", TOPOPT_BUILD_FINGERPRINT,
              TOPOPT_BUILD_COMMIT, TOPOPT_BUILD_DIRTY);
  return 0;
}
]=])
file(WRITE "${SRC}/tracked.txt" "one\n")
file(WRITE "${REPO}/app_side.txt" "outside core\n")
file(WRITE "${REPO}/app/scripts/build_core.sh" "#!/bin/bash\necho one\n")
file(WRITE "${REPO}/docs/notes.md" "docs one\n")

# Hooks, signing and the user's identity are all switched off for this repo.
function(run_git)
  execute_process(
    COMMAND "${GIT}" -C "${REPO}" -c user.name=fp-test -c user.email=fp@test.invalid
            -c commit.gpgsign=false -c core.hooksPath=/dev/null
            -c init.defaultBranch=main ${ARGN}
    RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err
    OUTPUT_STRIP_TRAILING_WHITESPACE)
  if(NOT rc EQUAL 0)
    message(FATAL_ERROR "git ${ARGN} failed (${rc}): ${err}")
  endif()
  set(GIT_OUT "${out}" PARENT_SCOPE)
endfunction()
function(head12 outvar)
  run_git(rev-parse --short=12 HEAD)
  set(${outvar} "${GIT_OUT}" PARENT_SCOPE)
endfunction()
# The expected tree hash, computed here independently of the stamping script.
function(tree12 outvar)
  run_git(rev-parse HEAD:core)
  set(t "${GIT_OUT}")
  run_git(rev-parse HEAD:app/scripts/build_core.sh)
  string(SHA1 h "${t}\n${GIT_OUT}\n")
  string(SUBSTRING "${h}" 0 12 h)
  set(${outvar} "${h}" PARENT_SCOPE)
endfunction()

run_git(init -q)
run_git(add -A)
run_git(commit -q -m "first")
head12(sha1)
tree12(fp1)

execute_process(
  COMMAND "${CMAKE_COMMAND}" -S "${SRC}" -B "${BUILD}" -G "${GENERATOR}"
          "-DCMAKE_CXX_COMPILER=${CXX}"
  RESULT_VARIABLE rc OUTPUT_VARIABLE o ERROR_VARIABLE e)
if(NOT rc EQUAL 0)
  message(FATAL_ERROR "configure failed: ${o}${e}")
endif()

set(HDR "${BUILD}/generated/fingerprint/topopt_build_fingerprint.h")
set(TXT "${BUILD}/generated/fingerprint/topopt_build_fingerprint.txt")
# Build (NEVER configure) and run the toy: FP / COMMIT / DIRTY / TXT_FP.
function(build_and_read)
  execute_process(COMMAND "${CMAKE_COMMAND}" --build "${BUILD}"
                  RESULT_VARIABLE rc OUTPUT_VARIABLE o ERROR_VARIABLE e)
  if(NOT rc EQUAL 0)
    message(FATAL_ERROR "build failed: ${o}${e}")
  endif()
  execute_process(COMMAND "${BUILD}/toy" RESULT_VARIABLE rc OUTPUT_VARIABLE out
                  OUTPUT_STRIP_TRAILING_WHITESPACE)
  if(NOT rc EQUAL 0 OR NOT out MATCHES "^fingerprint=([^ ]*) commit=([^ ]*) dirty=(-?[0-9]+)$")
    message(FATAL_ERROR "toy printed an unparseable line: '${out}'")
  endif()
  set(FP "${CMAKE_MATCH_1}" PARENT_SCOPE)
  set(COMMIT "${CMAKE_MATCH_2}" PARENT_SCOPE)
  set(DIRTY "${CMAKE_MATCH_3}" PARENT_SCOPE)
  file(STRINGS "${TXT}" txt LIMIT_COUNT 1)
  set(TXT_FP "${txt}" PARENT_SCOPE)
  message(STATUS "      toy: ${out} | txt: ${txt}")
endfunction()

# 1. first build
build_and_read()
string(LENGTH "${fp1}" len1)
set(ok FALSE)
if("${FP}" STREQUAL "${fp1}" AND "${COMMIT}" STREQUAL "${sha1}" AND
   "${DIRTY}" STREQUAL "0" AND len1 EQUAL 12 AND NOT "${fp1}" STREQUAL "${sha1}")
  set(ok TRUE)
endif()
expect(${ok} "1. the first build stamps the tree hash (${fp1}), commit ${sha1}, clean")
set(ok FALSE)
if("${TXT_FP}" STREQUAL "${FP}")
  set(ok TRUE)
endif()
expect(${ok} "7. the .txt (app script) equals the header")

# 2. a no-op build does not rewrite the header (nothing recompiles)
file(TIMESTAMP "${HDR}" t_before "%s")
execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 1.2)
build_and_read()
file(TIMESTAMP "${HDR}" t_after "%s")
set(ok FALSE)
if("${t_before}" STREQUAL "${t_after}" AND "${FP}" STREQUAL "${fp1}")
  set(ok TRUE)
endif()
expect(${ok} "2. a no-op build leaves the generated header untouched")

# 3. a new commit under core/, rebuilt WITHOUT configure
file(WRITE "${SRC}/tracked.txt" "two\n")
run_git(commit -q -a -m "second")
head12(sha2)
tree12(fp2)
build_and_read()
set(ok FALSE)
if(NOT "${fp2}" STREQUAL "${fp1}" AND "${FP}" STREQUAL "${fp2}" AND
   "${COMMIT}" STREQUAL "${sha2}" AND "${DIRTY}" STREQUAL "0")
  set(ok TRUE)
endif()
expect(${ok} "3. a rebuild after a core commit stamps the NEW tree hash (${fp2}) without configure")

# 3b. a docs-only commit (outside core/ and build_core.sh): the SAME fingerprint
file(WRITE "${REPO}/docs/notes.md" "docs two\n")
run_git(commit -q -a -m "docs only")
head12(sha_docs)
build_and_read()
set(ok FALSE)
if(NOT "${sha_docs}" STREQUAL "${sha2}" AND "${FP}" STREQUAL "${fp2}" AND
   "${COMMIT}" STREQUAL "${sha_docs}" AND "${DIRTY}" STREQUAL "0")
  set(ok TRUE)
endif()
expect(${ok} "3b. a docs-only commit (${sha_docs}) keeps the fingerprint (${fp2})")

# 3c. a commit to build_core.sh changes it
file(WRITE "${REPO}/app/scripts/build_core.sh" "#!/bin/bash\necho two\n")
run_git(commit -q -a -m "build script")
head12(sha3)
tree12(fp3)
build_and_read()
set(ok FALSE)
if(NOT "${fp3}" STREQUAL "${fp2}" AND "${FP}" STREQUAL "${fp3}" AND
   "${COMMIT}" STREQUAL "${sha3}" AND "${DIRTY}" STREQUAL "0")
  set(ok TRUE)
endif()
expect(${ok} "3c. a build_core.sh commit stamps a NEW tree hash (${fp3})")

# 4. an uncommitted edit under core/
file(WRITE "${SRC}/tracked.txt" "two, edited\n")
build_and_read()
set(fp_dirty_a "${FP}")
set(ok FALSE)
if("${FP}" MATCHES "^${fp3}-dirty-[0-9a-f]+$" AND "${COMMIT}" STREQUAL "${sha3}"
   AND "${DIRTY}" STREQUAL "1")
  set(ok TRUE)
endif()
expect(${ok} "4. an uncommitted tracked edit stamps ${fp3}-dirty-<diff8>, dirty 1")
set(ok FALSE)
if("${TXT_FP}" STREQUAL "${FP}")
  set(ok TRUE)
endif()
expect(${ok} "7. the .txt follows the dirty stamp")

# 5. a different uncommitted edit -> a different marker
file(WRITE "${SRC}/tracked.txt" "two, edited differently\n")
build_and_read()
set(ok FALSE)
if("${FP}" MATCHES "^${fp3}-dirty-" AND NOT "${FP}" STREQUAL "${fp_dirty_a}")
  set(ok TRUE)
endif()
expect(${ok} "5. a different uncommitted tree gets a different dirty marker")

# 5b. restored under core/; an uncommitted build_core.sh edit is dirty too
run_git(checkout -q -- core/tracked.txt)
file(WRITE "${REPO}/app/scripts/build_core.sh" "#!/bin/bash\necho two, edited\n")
build_and_read()
set(ok FALSE)
if("${FP}" MATCHES "^${fp3}-dirty-[0-9a-f]+$" AND "${DIRTY}" STREQUAL "1")
  set(ok TRUE)
endif()
expect(${ok} "5b. an uncommitted build_core.sh edit stamps ${fp3}-dirty-<diff8>")

# 6. restored; an edit OUTSIDE core/ and build_core.sh does not make it dirty
run_git(checkout -q -- app/scripts/build_core.sh)
file(WRITE "${REPO}/app_side.txt" "outside core, edited\n")
file(WRITE "${REPO}/docs/notes.md" "docs two, edited\n")
build_and_read()
set(ok FALSE)
if("${FP}" STREQUAL "${fp3}" AND "${DIRTY}" STREQUAL "0")
  set(ok TRUE)
endif()
expect(${ok} "6. restored -> clean again; edits outside core/ and build_core.sh are not the core's")

# 8. configure ran exactly once
file(READ "${BUILD}/configure_count.txt" cfg)
set(ok FALSE)
if("${cfg}" STREQUAL "x")
  set(ok TRUE)
endif()
expect(${ok} "8. CMake configure ran exactly once across all builds")

if(failures GREATER 0)
  message(FATAL_ERROR "build_fingerprint_rebuild: ${failures} of ${checks} checks FAILED")
endif()
message(STATUS "build_fingerprint_rebuild: all ${checks} checks passed")
