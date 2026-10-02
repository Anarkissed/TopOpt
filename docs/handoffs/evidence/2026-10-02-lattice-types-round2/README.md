# Lattice types round 2: evidence and how to reproduce it

The maintainer ruled on 2026-10-02 that the hash script, the store-snapshot procedure and the CLI-copy steps live in the repo. A session restart once wiped the scratchpad, and every snapshot, dump and CLI copy went with it. Rulings and status are in `PLAN.md`.

## Where the data lives

- **Tools:** `tools/`, committed.
- **Local evidence:** `scratch/evidence/` in the worktree.
  - This is his data: store snapshots, dumps, CLI copies.
  - `scratch/` is git-ignored, through `.git/info/exclude`. So a restart does not wipe it, and nothing of his is ever committed.
  - Override the location with `EVID=…` (see `tools/env.sh`).
- **His store:** the simulator container's `…/Library/Application Support/TopOpt/Projects`.
  - It is read only: the snapshot tool copies out of it and never writes into it.

## Procedure

1. **Snapshot the store before any byte claim:**
   ```
   zsh docs/handoffs/evidence/2026-10-02-lattice-types-round2/tools/snapshot_store.sh S<n>-<date>
   ```
   - The snapshot is read-only.
   - It records its copy time and a sha256 for each `project.json`. Compare those across snapshots to see which project he changed between them.
2. **Build the test products, never under a running suite:**
   ```
   cd app/TopOptKit && swift build --build-tests
   ```
3. **Dump the stage job for every project:**
   ```
   zsh …/tools/dump_stage_hashes.sh S<n>-<date> <arm>
   ```
   - Each project is opened from a FRESH writable copy, through the app's own serializer (`LatticeJobJSONDump`).
   - `SWIFT_DETERMINISTIC_HASHING` is unset.
   - The output is `ID ARM sha256[0:16]`, also written to `scratch/evidence/dumps/<arm>.hashes`.
4. **Compare two arms:**
   ```
   zsh …/tools/compare_hashes.sh <armA> <armB>
   ```
5. **Freeze a CLI before measuring with it:**
   ```
   zsh …/tools/copy_cli.sh <built topopt-cli> <name>
   ```
   - The copy is read-only.
   - Provenance comes from `--version`, the stderr fingerprint line, and the binary's sha256. It cannot come from `run_info.json`, whose fingerprint is "unknown" at the linked core.

## Snapshots and hashes (recorded here, so they survive a restart)

`hashes.md` holds, for each commit, the arm, the snapshot, and the seven hashes.
