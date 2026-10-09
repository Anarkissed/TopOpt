# The S0 set, FROZEN for the angled-press track (task 2026-10-07, AP0 fix-up, copied 2026-10-08T02:33Z)

The 11 S0 projects that are not already committed, copied byte for byte so the stage-job base rows and
the A1 run-job goldens can be rebuilt by S1 and every later batch from inputs that cannot move:

  his7/  his 7-project store copy: the read-only snapshot S1-2026-10-02 of the lattice-stage frontend
         worktree (scratch/evidence/snapshots, copied there 2026-10-02 17:27; its own
         S1-2026-10-02.sha256 lists the same project.json hashes).
  a1/    the four A1 projects (A1000001-…-0001 … -0004) from the simulator's LIVE store
         (147E56A1…/Application Support/TopOpt/Projects), which an app open rewrites (savedAt).

Before copying, every source's project.json and model file matched the 16-hex SHA-256 recorded in
../stage_job_hashes_base.txt at AP0 (11 of 11). SHA256SUMS holds the full SHA-256 of every file here.

Who reads them:
  ../stage_job_hashes.sh       defaults S0_HIS / S0_A1 to his7/ and a1/ and STOPS (exit 2) when a file
                               differs from SHA256SUMS, before any row is dumped;
  FlexibleAngledGoldenTests    restores a1/…-0002, -0003 and -0004 for their run-job, scene-job and
                               lattice-subtree goldens, and reads his7/92A8016E (his 'l bracket 3') for its
                               frame golden — each folder's files checked against SHA256SUMS first.

git keeps the bytes (no file here has a CR; the binaries are detected as binary). Never edit or re-save
anything in this folder: a changed byte is a different input, and the checks above go red.
r3 / r5 are the committed copies his_project_0004 and his_project_0004_r5 (one folder up the tree).
