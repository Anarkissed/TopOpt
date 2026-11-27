#!/usr/bin/env python3
# R6 measurement: where did core LAY each stepped cell? Core's receipts carry no cell
# positions, so the observable is the emitted STL. Two measures:
#  - byte identity: a job's STL equals the STL of the same cell SENT at the predicted laid spot;
#  - the lattice-only bounding box: the run's triangles minus the shell + solid companion
#    (the triangles common to two runs whose cells share no node), whose extent is the cube
#    plus the strut radius.
import struct, glob, collections, os, sys, hashlib, json
w = sys.argv[1] if len(sys.argv) > 1 else '.'
def stl(j): return glob.glob(os.path.join(w, 'run_' + j, '*.stl'))[0]
def sha(j): return hashlib.sha256(open(stl(j), 'rb').read()).hexdigest()
def tris(j):
    b = open(stl(j), 'rb').read(); n = struct.unpack('<I', b[80:84])[0]; assert 84 + 50 * n == len(b)
    return collections.Counter(b[84 + 50 * i + 12: 84 + 50 * i + 48] for i in range(n))
def bbox(c):
    vs = [struct.unpack('<9f', t) for t in c.elements()]
    return ' '.join('%s [%.4f, %.4f]' % (n, min(v[i] for v in vs for i in (a, a + 3, a + 6)),
                                          max(v[i] for v in vs for i in (a, a + 3, a + 6)))
                    for a, n in ((0, 'x'), (1, 'y'), (2, 'z')))
def section(title, jobs, base_pair):
    print('\n## ' + title)
    T = {j: tris(j) for j in jobs}
    base = tris(base_pair[0]) & tris(base_pair[1])
    for j in jobs:
        lat = T[j] - base
        print('%-28s sha256 %s  lattice tris %5d  %s' % (j, sha(j)[:16], sum(lat.values()), bbox(lat)))
    return T, base
def check(label, ok): print('  %s %s' % ('TRUE ' if ok else 'FALSE', label))
def base_cell(j):   # the any-step base core derived for region 1 (run_info.json)
    r = json.load(open(os.path.join(w, 'run_' + j, 'run_info.json')))
    return r['grading']['stepped']['region_cell_mm'][0]

section('R6: a BASE cell off its own grid (doubled, region 1 slot origin (18,12,8), 3 mm cell)',
        ['R6_base_off_grid', 'R6_ref_at_18', 'R6_control_on_grid', 'R6_off_grid_plus2', 'R6_far_cell'],
        ('R6_ref_at_18', 'R6_far_cell'))
check('sent x=19 is laid at x=18: STL byte-identical to the cell sent at x=18', sha('R6_base_off_grid') == sha('R6_ref_at_18'))
check('positive control: the on-grid cell sent at x=21 is NOT the x=18 STL', sha('R6_control_on_grid') != sha('R6_ref_at_18'))
check('sent x=20 is laid at x=21 (nearest own-grid point): STL byte-identical to the control', sha('R6_off_grid_plus2') == sha('R6_control_on_grid'))

section('R6b: a 1.5 mm (S/2) cell on the S/4 family tile, not its own grid (doubled)',
        ['R6b_half_on_quarter_grid', 'R6b_ref_half_at_22_5', 'R6b_control_half_at_21'],
        ('R6_ref_at_18', 'R6_far_cell'))
check('sent x=21.75 is laid at x=22.5: STL byte-identical to the cell sent at x=22.5', sha('R6b_half_on_quarter_grid') == sha('R6b_ref_half_at_22_5'))
check('positive control: the 1.5 mm cell sent at x=21 is NOT the x=22.5 STL', sha('R6b_control_half_at_21') != sha('R6b_ref_half_at_22_5'))

print('  core-derived any-step base cell (run_info grading.stepped.region_cell_mm[0]):',
      {j: base_cell(j) for j in ('R6c_anystep_off_own_grid', 'R6d_anystep_second_slot')})
T, base = section('R6c: a 3-tile cell at a 1-tile offset (any-step, base 14.5, tile 14.5/6)',
        ['R6c_anystep_off_own_grid', 'R6c_control_mirror', 'R6c_ref_big_at_18', 'R6c_ref_tile_at_18', 'R6c_ref_tile_at_25_25', 'R6c_far_tile'],
        ('R6c_ref_tile_at_18', 'R6c_far_tile'))
L = {j: c - base for j, c in T.items()}
check('failing lattice == (7.25 at x18) + (tile at x18), triangle for triangle: the 7.25 was laid ON the tile',
      L['R6c_anystep_off_own_grid'] == L['R6c_ref_big_at_18'] + L['R6c_ref_tile_at_18'])
check('control lattice == (7.25 at x18) + (tile at x25.25): laid where sent',
      L['R6c_control_mirror'] == L['R6c_ref_big_at_18'] + L['R6c_ref_tile_at_25_25'])

section('R6d: an 8.7 mm cell at the START of the second 14.5 mm slot (any-step)',
        ['R6d_anystep_second_slot', 'R6d_ref_at_25_4', 'R6d_control_first_slot'],
        ('R6d_anystep_second_slot', 'R6d_control_first_slot'))
check('sent z=22.5 is laid at z=25.4: STL byte-identical to the cell sent at z=25.4', sha('R6d_anystep_second_slot') == sha('R6d_ref_at_25_4'))
check('positive control: the same cell sent at z=8 (first slot) is NOT the z=25.4 STL', sha('R6d_control_first_slot') != sha('R6d_ref_at_25_4'))

T, base = section('R2x: a 3 mm cell one layer IN FRONT of the -y face (sent y 12..15; prism y 0..12; part y 0..12)',
        ['R2x_outside_face_accepted', 'R6_ref_at_18'], ('R6_ref_at_18', 'R6_far_cell'))
lat = T['R2x_outside_face_accepted'] - base
ys = [v for t in lat.elements() for v in struct.unpack('<9f', t)[1::3]]
check('R2x lays lattice ONLY in a band round the part face y=12 (every lattice vertex y in [11.5, 12.5])',
      bool(ys) and min(ys) >= 11.5 and max(ys) <= 12.5)
