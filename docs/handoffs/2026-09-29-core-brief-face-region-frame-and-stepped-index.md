# Core brief (#358): two latent bugs found while carrying face walls to variants

2026-09-29. From the app's face-prism follow-up (`2026-09-29-variant-face-walls.md`).

> **STATUS (2026-09-30): both FIXED in #358's 12ff5880.** The in-plane frame check now fires at
> parse time, and stepped plans resolve region ids by include order. Core confirmed the app's
> frame construction (built from the unit normal) and its stepped ids (include order) both
> match, so nothing changes app-side. Once this branch syncs with #358, a stepped or any-step
> plan whose region list has an exclude wall before an include wall runs instead of being
> refused. The report below is kept as the record.

This task needed **no core change**, and neither bug blocked it. Both were found by reading core at
aecef72c, and the first was also run through a fresh `topopt-cli` (core aecef72c291a, built
2026-09-29 23:14:25). The app did not work around either one.

## 1. The "frame lies in the face plane" schema check can never fire

`core/src/cli/job.cpp`, the face lattice region parser:
- The check that `frame_u` and `frame_w` lie in the face plane (`u · n`, `w · n`, lines
  1466-1481) reads `reg.normal`.
- `reg.normal` is parsed later, at lines 1503-1505. At the check it is still `{0, 0, 0}`, so both
  dot products are 0 and the check always passes.

Evidence, from job J8 in the app's proof set (the `plate_bore.stl` fixture, a `lattice_variant`
forecast):
- The inputs are normal `(0, 0, −1)`, `frame_u (0, 0, 1)` and `frame_w (1, 0, 0)`. Both axes are
  unit length and perpendicular to each other, and `u · n = −1`.
- Expected: a schema refusal with "must lie IN the face plane".
- Actual: the job is **accepted**. `loadcase.json` is written, and the run then refuses with the
  run-time frame-conflict message ("do not match the in-plane basis",
  `resolve_clearance_manual`, clearance.cpp:265-276, raised at run_job.cpp:1008-1019).

Nothing wrong gets built: the run-time check catches it. But the refusal comes one stage late,
with the less specific message.

**Suggested fix:** move the in-plane block below the `normal` parse, or parse `normal` first. A
parse test with an out-of-plane frame should then fail at schema, with no `loadcase.json`.

## 2. The stepped plan indexes `lattice.regions` by an INCLUDE index

`core/src/cli/run_job.cpp:6813-6819` (the any-step plan, `R.stepped.cells` non-empty):

```cpp
const std::size_t idx = static_cast<std::size_t>(rc.region_id - 1);
if (idx < job.lattice.regions.size()) {
  const JobLatticeRegion& jr = job.lattice.regions[idx];
  pr.slot_origin = jr.origin; pr.normal = jr.normal; pr.depth_mm = jr.depth_mm;
}
```

- `region_id` is the 1-based **include** order: the comment at 6806-6808 says so, and so do the
  doubled branch below it (6851-6857, which skips non-includes) and the voxel region ids
  (5376-5381).
- The line above indexes the list of **all** regions, excludes included.
- So when an exclude region comes before an include in `lattice.regions`, every stepped cell after
  it takes its slot origin, normal and depth from the wrong region.

When the app sends that order:
- Regions are emitted group by group. Within a group the order is primitives, then faces, then
  face regions, and each carries its own resolved role.
- So an exclude group listed before an include group does it. So does a primitive set to Solid in
  the first include group.

This was not run (it needs a stepped grading run with an exclude first). The evidence is the read
above.

**Suggested fix:** count includes, as the doubled branch does, or map include index → region index
once and use it in both branches. A test: a stepped plan whose first region is an exclude.

## For the record: the depth tie now runs on a variant's job

No core change is asked here. A `lattice_variant` job carries each face wall as the stage's
prism **with** its `face_id`: the maintainer ruled on 2026-09-30 to keep it as provenance. The
depth tie (job.cpp:2419-2438) therefore runs on it, against the retained job's
`loads.face_protections`, and it is checked at parse, before any solve.

The app does not re-implement the tie. Its test sends variant documents through core's own
parser:
- a retained run that froze face 1 at 20 mm accepts a wall at 20 mm;
- the same run refuses a wall at 12 mm, with core's message;
- the same refused bytes pass once `face_id` is removed. That is why the id is kept.

A related finding the app has NOT acted on, because it needs the maintainer's ruling: on the
stage job, a protected and latticed face wall with an in-plane **expand** is refused by this same
tie today. The region sends depth + expand; the protection sends the depth alone. Verified through
core's parser on 2026-09-30: face 1 is protected at 20 mm and given a 1 mm expand, and core refuses
it with "the protection is 20.000000 mm and the lattice region is 21.000000 mm"; with no expand it
accepts. Either fix changes the stage's job bytes.
