# TopOpt overlay of vcpkg's manifold port at tag 2026.06.24 (KEEP regions, the reviewer's
# ruling of 2026-10-25 03:58): the SAME pinned v3.5.1 source and SHA512, built SERIAL
# (MANIFOLD_PAR=OFF, no TBB) for the macOS worker and both iOS slices, with only the mesh
# boolean core (no cross-section, so no Clipper2; no C bindings).
vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO elalish/manifold
    REF "v${VERSION}"
    SHA512 10a3b1ecbe3f6f11f42e97dc22d0a2e7fcb6a66d4ae3ed95f56594477ac20ba91d6bcb5fe932e42c0dc431d262973813e67955919200f97337878416c9c7ec03
)

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        -DMANIFOLD_PAR=OFF
        -DMANIFOLD_TEST=OFF
        -DMANIFOLD_CROSS_SECTION=OFF
        -DMANIFOLD_CBIND=OFF
        -DMANIFOLD_PYBIND=OFF
        -DMANIFOLD_JSBIND=OFF
        -DMANIFOLD_STRICT=OFF
        -DMANIFOLD_EXPORT=OFF
)

vcpkg_cmake_install()
vcpkg_cmake_config_fixup(CONFIG_PATH lib/cmake/manifold)
vcpkg_fixup_pkgconfig()

file(REMOVE_RECURSE
    "${CURRENT_PACKAGES_DIR}/debug/include"
)

file(INSTALL "${CMAKE_CURRENT_LIST_DIR}/usage" DESTINATION "${CURRENT_PACKAGES_DIR}/share/${PORT}")
vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE")
