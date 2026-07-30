# Byte-identity checksums (H1d / H4c / H5)

Parent binary: topopt-cli built at 21ce7ed (the merge of PR 254 — the task's
'today'). New binary: this branch. Same job, same fixture, SHA-256 over every
deterministic artifact. run_info.json / iterations.csv carry wall-clock fields
and are excluded (they differ even between two runs of the SAME binary).

## nolattice.json and uniform.json — parent vs new (bit-identical)
nolattice/report.json
  parent: 30cabb941dcc0dec4a72a0b19221c4cd7a470b3f74f751a6800f214ac058579f
  new:    30cabb941dcc0dec4a72a0b19221c4cd7a470b3f74f751a6800f214ac058579f
nolattice/variant_060.stl
  parent: 2f2432f7f7f2a2f4bdd63a30570e7309ef964bee9a0d65e222aec868492a20c1
  new:    2f2432f7f7f2a2f4bdd63a30570e7309ef964bee9a0d65e222aec868492a20c1
nolattice/fields.bin
  parent: bad3cce4d3c1cf798c319c4862323f9b78573cc73b44ac52821b7ab9d3494cc8
  new:    bad3cce4d3c1cf798c319c4862323f9b78573cc73b44ac52821b7ab9d3494cc8
uniform/report.json
  parent: 30cabb941dcc0dec4a72a0b19221c4cd7a470b3f74f751a6800f214ac058579f
  new:    30cabb941dcc0dec4a72a0b19221c4cd7a470b3f74f751a6800f214ac058579f
uniform/variant_060.stl
  parent: 2f2432f7f7f2a2f4bdd63a30570e7309ef964bee9a0d65e222aec868492a20c1
  new:    2f2432f7f7f2a2f4bdd63a30570e7309ef964bee9a0d65e222aec868492a20c1
uniform/variant_060_lattice.stl
  parent: 908aa5eb5b111f52b88bff3bb2221f39f0a0fbc480f2274802e7b19f84e2d3f2
  new:    908aa5eb5b111f52b88bff3bb2221f39f0a0fbc480f2274802e7b19f84e2d3f2
uniform/variant_060_lattice.report.json
  parent: 14ae5f0aa697de4ff84dd2ab8c45ac512c43e9c170848d2ac25364c173deeef5
  new:    14ae5f0aa697de4ff84dd2ab8c45ac512c43e9c170848d2ac25364c173deeef5
uniform/fields.bin
  parent: bad3cce4d3c1cf798c319c4862323f9b78573cc73b44ac52821b7ab9d3494cc8
  new:    bad3cce4d3c1cf798c319c4862323f9b78573cc73b44ac52821b7ab9d3494cc8

## Determinism (H5) — same binary, two runs, roles + graded
include_exclude/variant_060_lattice.stl
  run1: 37fdb2bc8c8de1789d8e3d3d1acead4292b97359e957b4c1c4e2d80d0e777811
  run2: 37fdb2bc8c8de1789d8e3d3d1acead4292b97359e957b4c1c4e2d80d0e777811
include_exclude/variant_060_lattice.report.json
  run1: c77a3ab72d724b9e7273f4e70928fa4294b9b070c4bcb019c89cc6d0f9bb9779
  run2: c77a3ab72d724b9e7273f4e70928fa4294b9b070c4bcb019c89cc6d0f9bb9779
include_exclude/report.json
  run1: 30cabb941dcc0dec4a72a0b19221c4cd7a470b3f74f751a6800f214ac058579f
  run2: 30cabb941dcc0dec4a72a0b19221c4cd7a470b3f74f751a6800f214ac058579f
graded/variant_100_lattice.stl
  run1: 28e313c4dd5f6dba119ef5b961f4bf9c545e7e6a2167623f1794ef6253fec480
  run2: 28e313c4dd5f6dba119ef5b961f4bf9c545e7e6a2167623f1794ef6253fec480
graded/variant_100_lattice.report.json
  run1: 796a8d54cdb1ba266ea6e14e451fc24873f54c93a3a73f86594b31f90fe3efca
  run2: 796a8d54cdb1ba266ea6e14e451fc24873f54c93a3a73f86594b31f90fe3efca
graded/report.json
  run1: 9506e834e424a647246ba0f70061ccc7436736987c3a304f1fece64a715ec81c
  run2: 9506e834e424a647246ba0f70061ccc7436736987c3a304f1fece64a715ec81c
graded/fields.bin
  run1: 54d409d763fe14b7e3c6eca7dfa1729feab63ad432398f1f9620e50d8533f939
  run2: 54d409d763fe14b7e3c6eca7dfa1729feab63ad432398f1f9620e50d8533f939

## Parent REFUSES the new vocabulary (the strict parser was live)
  exclude.json  -> topopt-cli: job.json: unknown key "regions" in lattice
  graded.json   -> topopt-cli: job.json: missing required key "cell_mm" in lattice
