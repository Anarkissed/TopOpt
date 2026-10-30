# TopoptFingerprint.cmake — SCRIPT MODE (cmake -P). Stamps the core build
# fingerprint AT BUILD TIME (item 44). Run by the `topopt_fingerprint` custom
# target (cmake/TopoptFingerprintTarget.cmake) on EVERY build, so a rebuild after
# a new commit carries the new tree without re-running CMake's configure step.
#
#   -DTOPOPT_FP_SOURCE_DIR=<core dir>   the tree whose content is stamped
#   -DTOPOPT_FP_EXTRA_PATHS=<p1|p2|...> optional: more inputs that change the
#                                       built core, relative to the core dir
#                                       ("|"-separated; the core's CMakeLists
#                                       passes ../app/scripts/build_core.sh)
#   -DTOPOPT_FP_HEADER=<path>           generated C header (written only when its
#                                       content changes, so an unchanged
#                                       fingerprint recompiles nothing)
#   -DTOPOPT_FP_TEXT=<path>             optional: the fingerprint alone, one line
#                                       (read by app/scripts/build_core.sh)
#
# ★ THE FINGERPRINT IS A TREE HASH (item 44 follow-up): it names what the core is
# built FROM, not the commit it sits on. A docs-only or app-only commit leaves it
# unchanged; a commit that touches core/ or build_core.sh changes it. So an app
# and a worker CLI built from two commits with the same core agree, and two
# builds that differ in anything that changes the core never do.
#   <tree12>                   the first 12 hex of the SHA-1 of the object ids
#                              at HEAD, one per line: the core dir's tree, then
#                              each extra path's object ("-" when HEAD lacks it).
#                              By hand, from the repo root:
#                                printf '%s\n%s\n' "$(git rev-parse HEAD:core)" \
#                                  "$(git rev-parse HEAD:app/scripts/build_core.sh)" \
#                                  | shasum | cut -c1-12
#                              No uncommitted change to a tracked file under them;
#   <tree12>-dirty-<diff8>     tracked files under the core dir or an extra path
#                              differ from HEAD (staged or not); <diff8> = the
#                              first 8 hex of the SHA-1 of their status + `git diff
#                              HEAD`, so two different uncommitted trees on the
#                              same commit never share a fingerprint. Untracked
#                              files (build directories) are not part of it;
#   dev                        no git, or not a git checkout (never equals a real
#                              fingerprint, so the app's skew check fails safe).
# A failed `git status` counts as DIRTY (fail safe), never as clean.
# TOPOPT_BUILD_COMMIT stays the HEAD commit (12 hex), for the record only.
cmake_minimum_required(VERSION 3.22)

if(NOT TOPOPT_FP_SOURCE_DIR OR NOT TOPOPT_FP_HEADER)
  message(FATAL_ERROR "TopoptFingerprint.cmake: TOPOPT_FP_SOURCE_DIR and "
                      "TOPOPT_FP_HEADER are required")
endif()
set(fp_extra "")
if(TOPOPT_FP_EXTRA_PATHS)
  string(REPLACE "|" ";" fp_extra "${TOPOPT_FP_EXTRA_PATHS}")
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
    # The tree hash: HEAD's object id of the core dir ("HEAD:./", relative to
    # -C), then of each extra path. A path HEAD lacks hashes as "-" (a core
    # checked out without app/ still stamps; its fingerprint differs).
    set(fp_ids "")
    set(fp_tree_ok TRUE)
    foreach(p "." ${fp_extra})
      execute_process(
        COMMAND "${TOPOPT_FP_GIT}" -C "${TOPOPT_FP_SOURCE_DIR}" rev-parse --verify --quiet "HEAD:./${p}"
        OUTPUT_VARIABLE id OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET RESULT_VARIABLE rc_id)
      if(NOT rc_id EQUAL 0 OR id STREQUAL "")
        if(p STREQUAL ".")
          set(fp_tree_ok FALSE)  # the core dir itself is not in HEAD: "dev"
        endif()
        set(id "-")
      endif()
      string(APPEND fp_ids "${id}\n")
    endforeach()
    if(NOT fp_tree_ok)
      set(fp_commit "")
    endif()
  endif()
  if(NOT fp_commit STREQUAL "")
    string(SHA1 fp_sha "${fp_ids}")
    string(SUBSTRING "${fp_sha}" 0 12 fp_tree)
    # The pathspecs the dirty check reads: the core dir and every extra path.
    set(fp_specs "." ${fp_extra})
    # --no-optional-locks: never take the index lock (a concurrent git command
    # in the same checkout must not fail because a build is running).
    execute_process(
      COMMAND "${TOPOPT_FP_GIT}" --no-optional-locks -C "${TOPOPT_FP_SOURCE_DIR}"
              status --porcelain --untracked-files=no -- ${fp_specs}
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
                diff --no-ext-diff --binary HEAD -- ${fp_specs}
        OUTPUT_VARIABLE diff ERROR_QUIET)
    endif()
    if(fp_dirty EQUAL 1)
      string(SHA1 diff_sha "${st}${diff}")
      string(SUBSTRING "${diff_sha}" 0 8 diff8)
      set(fp "${fp_tree}-dirty-${diff8}")
    else()
      set(fp "${fp_tree}")
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
