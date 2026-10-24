# TopoptFingerprint.cmake — SCRIPT MODE (cmake -P). Stamps the core build
# fingerprint AT BUILD TIME (item 44). Run by the `topopt_fingerprint` custom
# target (cmake/TopoptFingerprintTarget.cmake) on EVERY build, so a rebuild after
# a new commit carries the new commit without re-running CMake's configure step.
#
#   -DTOPOPT_FP_SOURCE_DIR=<core dir>   the tree whose commit is stamped
#   -DTOPOPT_FP_HEADER=<path>           generated C header (written only when its
#                                       content changes, so an unchanged
#                                       fingerprint recompiles nothing)
#   -DTOPOPT_FP_TEXT=<path>             optional: the fingerprint alone, one line
#                                       (read by app/scripts/build_core.sh)
#
# The fingerprint:
#   <sha12>                    HEAD of the core tree, no uncommitted change to a
#                              tracked file under it;
#   <sha12>-dirty-<diff8>      tracked files under the core tree differ from HEAD
#                              (staged or not); <diff8> = the first 8 hex of the
#                              SHA-1 of `git diff HEAD -- .`, so two different
#                              uncommitted trees on the same commit never share a
#                              fingerprint. Untracked files (build directories)
#                              are not part of it;
#   dev                        no git, or not a git checkout (never equals a real
#                              fingerprint, so the app's skew check fails safe).
# A failed `git status` counts as DIRTY (fail safe), never as clean.
cmake_minimum_required(VERSION 3.22)

if(NOT TOPOPT_FP_SOURCE_DIR OR NOT TOPOPT_FP_HEADER)
  message(FATAL_ERROR "TopoptFingerprint.cmake: TOPOPT_FP_SOURCE_DIR and "
                      "TOPOPT_FP_HEADER are required")
endif()

find_program(TOPOPT_FP_GIT git)
set(fp_commit "")
set(fp_dirty -1)  # -1 = unknown (no git)
set(fp "dev")
if(TOPOPT_FP_GIT)
  execute_process(
    COMMAND "${TOPOPT_FP_GIT}" -C "${TOPOPT_FP_SOURCE_DIR}" rev-parse --short=12 HEAD
    OUTPUT_VARIABLE fp_commit OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET RESULT_VARIABLE rc)
  if(NOT rc EQUAL 0 OR fp_commit STREQUAL "")
    set(fp_commit "")
  else()
    # --no-optional-locks: never take the index lock (a concurrent git command
    # in the same checkout must not fail because a build is running).
    execute_process(
      COMMAND "${TOPOPT_FP_GIT}" --no-optional-locks -C "${TOPOPT_FP_SOURCE_DIR}"
              status --porcelain --untracked-files=no -- .
      OUTPUT_VARIABLE st ERROR_QUIET RESULT_VARIABLE rc_st)
    if(NOT rc_st EQUAL 0)
      set(fp_dirty 1)
      set(diff "git status failed (${rc_st})")
    elseif(st STREQUAL "")
      set(fp_dirty 0)
    else()
      set(fp_dirty 1)
      execute_process(
        COMMAND "${TOPOPT_FP_GIT}" --no-optional-locks -C "${TOPOPT_FP_SOURCE_DIR}"
                diff --no-ext-diff --binary HEAD -- .
        OUTPUT_VARIABLE diff ERROR_QUIET)
    endif()
    if(fp_dirty EQUAL 1)
      string(SHA1 diff_sha "${st}${diff}")
      string(SUBSTRING "${diff_sha}" 0 8 diff8)
      set(fp "${fp_commit}-dirty-${diff8}")
    else()
      set(fp "${fp_commit}")
    endif()
  endif()
endif()

set(content
"// GENERATED at BUILD time by core/cmake/TopoptFingerprint.cmake. DO NOT EDIT.
#ifndef TOPOPT_BUILD_FINGERPRINT_H
#define TOPOPT_BUILD_FINGERPRINT_H
#define TOPOPT_BUILD_FINGERPRINT \"${fp}\"
#define TOPOPT_BUILD_COMMIT \"${fp_commit}\"
#define TOPOPT_BUILD_DIRTY ${fp_dirty}
#endif
")

get_filename_component(hdr_dir "${TOPOPT_FP_HEADER}" DIRECTORY)
file(MAKE_DIRECTORY "${hdr_dir}")
set(old_content "")
if(EXISTS "${TOPOPT_FP_HEADER}")
  file(READ "${TOPOPT_FP_HEADER}" old_content)
endif()
if(NOT old_content STREQUAL content)
  if(EXISTS "${TOPOPT_FP_HEADER}")
    # macOS /usr/bin/make (GNU Make 3.81) compares mtimes to the WHOLE SECOND:
    # a header rewritten in the same second as the object that includes it was
    # compiled looks up to date, and the binary keeps the OLD fingerprint
    # (seen in tests/scripts/test_build_fingerprint.cmake). So a CHANGED
    # fingerprint is written only once the clock has entered a new second
    # (<= 1 s, and only when it changes).
    string(TIMESTAMP s0 "%s")
    string(TIMESTAMP s1 "%s")
    while(s1 STREQUAL s0)
      execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 0.05)
      string(TIMESTAMP s1 "%s")
    endwhile()
  endif()
  set(tmp "${TOPOPT_FP_HEADER}.tmp")
  file(WRITE "${tmp}" "${content}")
  file(RENAME "${tmp}" "${TOPOPT_FP_HEADER}")
endif()
if(TOPOPT_FP_TEXT)
  set(ttmp "${TOPOPT_FP_TEXT}.tmp")
  file(WRITE "${ttmp}" "${fp}\n")
  file(COPY_FILE "${ttmp}" "${TOPOPT_FP_TEXT}" ONLY_IF_DIFFERENT)
  file(REMOVE "${ttmp}")
endif()
message(STATUS "core build fingerprint: ${fp}")
