# K4 — the print-tests loader: the accepted id set (recorded before the code)

Reviewer's heads-up, 2026-09-30, and the committed file confirms it. The ten keys in
`core/src/materials/lattice_print_tests.json` are:

    octet  bccz  sc  bcc  fcc  diamond  kelvin  rhombic  gyroid  schwarz_d

**`gyroid` and `schwarz_d` are not `LatticeTopology` ids.** The enum carries octet, sc,
bcc, fcc, diamond, kelvin, rhombic, bccz, fccz, reentrant — so a loader that validated
keys against the enum would **refuse the maintainer's own file** today, which is
forbidden. The two sheet ids only become core ids at K2.

**The rule, as given:** accept the round's named ids — the eight round-1 types plus
`bccz` and `octet` — and refuse anything else by name. That set is exactly the file's
present keys, so the committed file loads. The loader will be tested against the
committed file directly, not against a copy.

## ★ One question this raises, not decided here

The accepted set as specified does **not** include `fccz` or `reentrant`. Both are
`LatticeTopology` ids today, both had their constants measured on 2026-07-29, and
`01-types.md` §C names them as waiting only on Q4's tetragonal path. So if the
maintainer ever prints an FCCZ-family sample and adds a row for it — the same thing he
already did for `bccz` — a loader restricted to the specified ten would refuse his
file. That collides with "it must never refuse the maintainer's own file".

The narrower alternative that cannot do that: accept **every `LatticeTopology` id plus
`gyroid` and `schwarz_d`**, which is the specified set plus exactly `fccz` and
`reentrant`, and still refuses everything else by name.

I am **not** widening it on my own — the set is the reviewer's call and this is a
ruling, not a gap. Implementing as specified at K4, with this noted; one line either
way settles it.

## SETTLED (reviewer, 2026-09-30): the accepted set is DERIVED, not listed

"Never refuse the maintainer's own file" wins, and the set must not need editing every
time a type lands. So the loader accepts:

1. **every `LatticeTopology` id**, obtained by running `lattice_topology_name` over the
   enum — so a type added to the enum later is accepted automatically, with no edit
   here and no chance of this list drifting from the enum;
2. **plus `"gyroid"` and `"schwarz_d"`**, the two sheet ids that are not enum values
   yet. This extra list is **deleted at K2**, when the enum gains them.

Anything else is refused **by name**, so a typo says which key is wrong (`"Gyroid"`
names `Gyroid`, not "a bad file").

This is the specified set **plus `fccz` and `reentrant`**, which closes the hole I
raised: the maintainer can add a row for either — as he already did for `bccz` — and
the loader accepts it.

### Tests owed at K4
- the **committed file**, loaded directly (not a copy): all ten keys accepted;
- a **synthetic file carrying an `fccz` row**: accepted, which is the regression guard
  for the narrow set;
- a **synthetic file with a misspelled key** (e.g. `"Gyroid"`): refused, and the
  message names that key.
