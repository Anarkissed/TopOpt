# Evidence — build direction becomes its own input (2026-08-01)

Handoff: `docs/handoffs/2026-08-01-build-direction-separation.md`

| file | bar | what it shows |
|---|---|---|
| `u1_byte_identity.txt` | **U1** | Raw sha256 of `report.json` / `fields.bin` / `variant_060.stl` from the changed build (twice) vs an INDEPENDENT worktree at `origin/main` `eca04d6` — all identical. Also: they stay identical with the scorer ARMED, and the new key provably DOES move `report.json` while leaving the mesh bit-identical (a post-solve input). |
| `u2_no_site_infers.txt` | **U2** | The three sites, each consuming `resolve_build_direction`; zero inline `-gravity_direction` derivations left; the ONE fallback; and the app's own copy of the conflation removed. |
| `u2_u4_u5_u7_test.txt` | **U2 U3 U4 U5 U7** | `test_build_direction`, 56 checks, 0 failures. PR 266's V5-hook table reproduced through the PRODUCTION post-pass (0.6968 / 1.3285 / 9.11x / 48 vs 0); the measured sweep cost at res 32 and 48; the as-built-verdict-stands assertions; the S-c / S-d invariants. |
| `u5_receipt_inferred.json` | **U5** | A real `build_orientation.json` from a CLI run with NO declared direction — note `"source": "assumed_from_gravity"` and the pre-composed `statement`. |
| `u5_receipt_declared_z.json` | **U5** | The same job with `"build_direction": [0,0,1]` — `"source": "declared"`. |
| `u1_job_unarmed.json`, `u1_job_declared_z.json` | U1 | The two job.json files behind the byte-identity comparison. |
| `u8_ctest.txt` | **U8** | Full ctest: 90/90, 100% passed. |
| `u8_app_tests.txt` | **U8** | Full app suite: 1024 tests, 3 failures — all three the pre-existing 3MF/lib3mf provisioning tests, verified failing identically on the untouched baseline worktree. |
