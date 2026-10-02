# Stage-job hashes, per commit (round 2)

**How the hashes are made.** Each value is the SHA-256 (first 16 hex digits) of the `lattice_part` job the app would send for that project.
- It comes from `tools/dump_stage_hashes.sh`, run with `SWIFT_DETERMINISTIC_HASHING` unset.
- Every project is opened from a fresh copy of the snapshot.

**Snapshot S1-2026-10-02** was copied at 2026-10-02 17:27:18 EDT. Its `project.json` SHA-256s (first 16 hex digits):

```
102117B9-DDD2-4597-9BDE-49DD47EBF393 6f4e44987a360d45
3418E167-8524-4831-A809-827B6B0742D0 78bd5ff4cac763e7
570B38E2-3C6E-46E0-BCF6-26BE1595D204 4d60412d56be5596
68BF7B74-3C2A-4ED6-A46D-AC040A9CA649 9a545225979bef8a
887AC498-5B5D-4475-B6CB-893DC69B5FD6 d010d42cc6904b29
92A8016E-FCCD-421D-B19E-4A1EC81C98A5 6e14e93f97da3249
AA4C7953-3152-4123-BCB5-EF5F8A08ABA3 a975ba0f83d9b383
```

**What changed against older snapshots:**
- S1 is identical to P3 (2026-10-01 18:09). 3418E167's `78bd5ff4cac7` matches P3's.
- The other six are unchanged since P1 (2026-10-01 00:09).

| arm | commit | 102117B9 | 68BF7B74 (stand) | 92A8016E (octet) | 570B38E2 | 3418E167 | AA4C7953 | 887AC498 |
|---|---|---|---|---|---|---|---|---|
| b | (b) frame-basis test | 3f19f920e5c96a5a | 3fd5d1b2388fe949 | 225865c83c64cb23 | 43a0828a8bbb1e1d | 169fe967ff734cfa | 3e6f162cb36212a9 | b457718dfc23ab42 |
| f1 | ruling (1): the floor keyed on the beam-network set | 3f19f920e5c96a5a | 3fd5d1b2388fe949 | 225865c83c64cb23 | 43a0828a8bbb1e1d | 169fe967ff734cfa | 3e6f162cb36212a9 | b457718dfc23ab42 |
| f3 | ruling (3): no beam_network on Stepped + Structural | 3f19f920e5c96a5a | 3fd5d1b2388fe949 | 225865c83c64cb23 | 43a0828a8bbb1e1d | **2ad491fb516877fd** | 3e6f162cb36212a9 | b457718dfc23ab42 |
| f5 | ruling (5): core's octet ceiling | 3f19f920e5c96a5a | **6dbb48fab4029f78** | **c4ca5d5ac009036d** | **2baaf9cbb94027c7** | **7ba46796d87e3b34** | 3e6f162cb36212a9 | b457718dfc23ab42 |
| fa | item (a): named() returns nil for an unknown id | 3f19f920e5c96a5a | 6dbb48fab4029f78 | c4ca5d5ac009036d | 2baaf9cbb94027c7 | 7ba46796d87e3b34 | 3e6f162cb36212a9 | b457718dfc23ab42 |
| f4a | ruling (4) R4: Default Grade packs halves by its algorithm | 3f19f920e5c96a5a | 6dbb48fab4029f78 | c4ca5d5ac009036d | 2baaf9cbb94027c7 | 7ba46796d87e3b34 | 3e6f162cb36212a9 | b457718dfc23ab42 |

The arm "b" equals the round-1 values: lt3/lt4 on P1 for the six unchanged projects, and p3base 169fe967ff734cfa for 3418E167. The script reproduces the old dumps.

f3 moves 3418E167 only (Stepped + Structural in S1). Its job differs from f1 in exactly one line, `"structural_certification" : "beam_network"` removed from `grading`; with that key popped the two jobs are equal.

f5 moves the four graded octet jobs: 68BF7B74, 92A8016E, 570B38E2 and 3418E167. In each, only `grading.max_relative_density` changes, from `0.21887144446372986` (the app's 24-step bisection, 7344107/2^25) to `0.21887141535615173` (core's `octet_aesthetic_density_ceiling()`, 200 steps). That is a change of −2.911e-8, and each job is otherwise identical. 102117B9 is organic and carries no cap; AA4C7953 and 887AC498 have no lattice block.
