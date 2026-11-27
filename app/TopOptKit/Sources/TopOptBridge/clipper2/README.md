# Clipper2 2.0.1 (vendored)

Angus Johnson's Clipper2, polygon clipping and offsetting. Boost Software License 1.0 (see LICENSE).

- Source: https://github.com/AngusJohnson/Clipper2, tag `Clipper2_2.0.1`.
- Archive SHA-512: `ce753ae3…c3ed499a`. This equals the pin in this repo's `.vcpkg/ports/clipper2/portfile.cmake`.
- Vendored 2026-10-10, with the maintainer's approval.

It serves the lattice outline's boolean union: the reviewer's ruling P4 (2026-10-10) sends each region's outline to core as simple, non-overlapping loops. Only `CPP/Clipper2Lib`'s headers and the engine, offset and rectclip sources are copied. The triangulation unit is not copied because it is unused. The files are unmodified.
