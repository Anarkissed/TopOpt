# The owner swap's parity proof on 68BF7B74 ("M2 verticalStand", Aesthetic Stepped)

`LatticeCoreOwnerParityProof`, on a fresh copy of snapshot S1-2026-10-02. One process, one scene and
one texel grid, through the app's renderer. App commit: the owner swap (core 36f5fdde). The model's
SHA-256 starts `bdf5646481e370ba`; it is the same STEP as 102117B9's.

`proof_summary.txt` is the proof's output, verbatim:
- **The bar.** Under core's owner, core's straddler predicate (stepped_plan.cpp:360-364) refuses
  0 of 1,787 cross-region overlapping pairs.
- **RED arms.** Under the Swift rule the app had, core refuses 62 of 1,729 pairs (17 owner 0,
  17 a third region, 32 the other region). Under declaration order it refuses 833 of 1,679.
- **Point by point.** At 47,997 points (cell centres and painted texel middles), the Swift rule and
  core agree on 47,593. They differ on 404: 294 where both name a different owner, and 110 where
  core names one and the Swift rule none.
- **Ruling (a).** 47 contested cells yielded because core gives their centre to no region, and 5
  because it gives it to a third region. That took 18 rounds: 1,764 cells stepped down and 3,771
  were dropped at the finest rung. The bake made 19 bridge calls for 9,355 points.
- **Ruling (b).** There were 1,218 shared texels. 1,215 went to core's owner's cell (8 of them to
  a third claimant), 1 was emptied for owner 0, and 2 were emptied because the owner had no cell
  there.

**A reporting error, corrected.** The last line, "plan sent (9938 cells)", is wrong. The
any-step test switch was not set for this Stepped project, so the job carried no plan, and the
proof read the writer's nil as "sent". The proof now sets the switch and asserts the cells ride.
That job is not committed. The Aesthetic Stepped plan for 68BF7B74 comes from the plan proof
(`tools/plan_proof.sh`).
