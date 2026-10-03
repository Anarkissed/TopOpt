# Stage-job hashes, round 3

Made with round 2's `tools/dump_stage_hashes.sh` on snapshot S1-2026-10-02 (`SWIFT_DETERMINISTIC_HASHING` unset). Each value is the first 16 hex digits of the SHA-256 of the `lattice_part` job the app would send. Round 2's last arm, fo (3ba44c7d), is the baseline.

| arm | commit | 102117B9 | 68BF7B74 (stand) | 92A8016E (octet) | 570B38E2 | 3418E167 | AA4C7953 | 887AC498 |
|---|---|---|---|---|---|---|---|---|
| fo | round 2 end (3ba44c7d) | 3f19f920e5c96a5a | 6dbb48fab4029f78 | c4ca5d5ac009036d | 2baaf9cbb94027c7 | 7ba46796d87e3b34 | 3e6f162cb36212a9 | b457718dfc23ab42 |
| g | the one bridge guard + the stale-type gate | 3f19f920e5c96a5a | 6dbb48fab4029f78 | c4ca5d5ac009036d | 2baaf9cbb94027c7 | 7ba46796d87e3b34 | 3e6f162cb36212a9 | b457718dfc23ab42 |

g equals fo on all seven: the guard and the gate move no stage-job bytes.
