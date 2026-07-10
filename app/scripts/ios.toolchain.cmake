# ios.toolchain.cmake — a small, self-contained CMake toolchain for building the
# TopOpt C++ dependencies (OpenCASCADE, lib3mf) for Apple iOS (ROADMAP M7.1b).
#
# It is NOT a third-party toolchain (leetal/ios-cmake etc.) — it is hand-written
# so the repo pulls in no new dependency (ARCHITECTURE §4 / worker rule 7). It
# leans on CMake's native iOS support (CMAKE_SYSTEM_NAME=iOS, ≥ CMake 3.14) and
# only adds the cross-compilation hygiene OCCT's configure needs.
#
# Parameterise on the CMake command line (all have defaults):
#   -DIOS_SDK=iphoneos            # device  (arm64)         — the shipping iPad
#   -DIOS_SDK=iphonesimulator     # simulator (arm64/x86_64) — the sim gate
#   -DIOS_ARCHS=arm64             # ';'-separated arch list
#   -DIOS_DEPLOYMENT_TARGET=16.0  # must match Package.swift .iOS(.v16)
#
# Example (device slice):
#   cmake -S <src> -B <build> \
#     -DCMAKE_TOOLCHAIN_FILE=app/scripts/ios.toolchain.cmake \
#     -DIOS_SDK=iphoneos -DIOS_ARCHS=arm64
#
# LGPL note (ARCHITECTURE §10): this toolchain does nothing that forces static
# linking. OCCT is configured Shared by the build scripts; this file only sets
# the platform/sysroot/arch. Do not add -DBUILD_LIBRARY_TYPE=Static on top of it.

# --- guard against repeated inclusion (CMake includes toolchains twice) -------
if(DEFINED _TOPOPT_IOS_TOOLCHAIN_INCLUDED)
  return()
endif()
set(_TOPOPT_IOS_TOOLCHAIN_INCLUDED TRUE)

# --- parameters ---------------------------------------------------------------
if(NOT DEFINED IOS_SDK)
  set(IOS_SDK "iphoneos" CACHE STRING "iphoneos | iphonesimulator")
endif()
if(NOT DEFINED IOS_ARCHS)
  set(IOS_ARCHS "arm64" CACHE STRING "target architectures, ';'-separated")
endif()
if(NOT DEFINED IOS_DEPLOYMENT_TARGET)
  set(IOS_DEPLOYMENT_TARGET "16.0" CACHE STRING "minimum iOS version")
endif()

if(NOT IOS_SDK STREQUAL "iphoneos" AND NOT IOS_SDK STREQUAL "iphonesimulator")
  message(FATAL_ERROR "IOS_SDK must be 'iphoneos' or 'iphonesimulator' (got '${IOS_SDK}')")
endif()

# --- platform -----------------------------------------------------------------
# CMAKE_SYSTEM_NAME=iOS triggers CMake's built-in Apple-embedded support: it
# selects the Apple linker/ar/ranlib, sets MACOSX_RPATH, and knows how to emit
# iOS dylibs/frameworks. Setting it here (a toolchain file) — rather than on the
# command line — is what makes CMake treat this as a cross-compile from the
# first configure pass, so OCCT's platform detection sees iOS, not macOS.
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_VERSION "${IOS_DEPLOYMENT_TARGET}")
set(CMAKE_SYSTEM_PROCESSOR arm64)

set(CMAKE_OSX_ARCHITECTURES "${IOS_ARCHS}" CACHE STRING "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET "${IOS_DEPLOYMENT_TARGET}" CACHE STRING "" FORCE)

# Resolve the concrete SDK path via xcrun (keeps this file free of hard-coded
# Xcode paths, so it survives Xcode upgrades / non-default install locations).
execute_process(
  COMMAND xcrun --sdk "${IOS_SDK}" --show-sdk-path
  OUTPUT_VARIABLE _ios_sdk_path
  OUTPUT_STRIP_TRAILING_WHITESPACE
  RESULT_VARIABLE _ios_sdk_result)
if(NOT _ios_sdk_result EQUAL 0 OR _ios_sdk_path STREQUAL "")
  message(FATAL_ERROR
    "xcrun could not locate the '${IOS_SDK}' SDK. Is Xcode (not just the CLT) "
    "selected? Try: sudo xcode-select -s /Applications/Xcode.app")
endif()
set(CMAKE_OSX_SYSROOT "${_ios_sdk_path}" CACHE PATH "" FORCE)

# --- cross-compilation hygiene ------------------------------------------------
set(CMAKE_CROSSCOMPILING TRUE)

# Search target roots (the SDK) for libraries/headers, but keep host programs
# (cmake, xcrun, the compiler) resolvable. Eigen is header-only and lives at a
# host Homebrew prefix, so headers use BOTH — the build scripts pass its prefix
# on CMAKE_FIND_ROOT_PATH.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

# OCCT's configure runs feature checks. When cross-compiling, try_run() cannot
# execute an iOS binary on the host, and a full try_compile would need a code-
# signed executable. Building the check as a STATIC library sidesteps both: the
# compiler still validates the flags/headers, nothing has to link or run.
if(NOT DEFINED CMAKE_TRY_COMPILE_TARGET_TYPE)
  set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
endif()

# Bitcode has been removed from Xcode (14+); do not emit it. Embedded dynamic
# frameworks are the LGPL-clean iOS delivery (see build_occt_ios.sh).
set(CMAKE_XCODE_ATTRIBUTE_ENABLE_BITCODE NO)
