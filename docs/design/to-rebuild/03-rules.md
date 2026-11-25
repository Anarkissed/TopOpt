# TO rebuild: the rules

Numbered so code, tests and reviews can cite them. His words are quoted with their date; where a rule is a ruling or a finding, it says so. A rule changes only by his word or a reviewer ruling.

## What a result must be

1. **Lightest part that is strong enough.** "As long as it reaches the 150-200% strength requirement and the protected faces and their depths are respected, then any savings are great." (2026-11-20). This retires his 2026-08-14 ruling that a lattice's saving is spent on extra structure.
2. **Strength requirement.** The safety margin he sets, under EVERY load scenario; 150 % is the default and the floor. (brief, G3)
3. **Protected faces and their depths.** A depth is the millimetres he typed, at any resolution. (rule 1's words; ledger L-03)
4. **Weight means printed grams**, infill included, and infill is a lever the engine may offer. (reviewer ruling 2026-11-21, M-07)
5. **One strength number.** The loop, the certificate and the file check use the same measure, and it gives the same verdict at any resolution he picks. (reviewer ruling 3, 2026-11-20; ledger F)
6. **Loads and anchors act on the drawn face**, its true area, wherever the grid falls. (ledger V-01; his word 2026-11-20: "Keep it in the plan")

## How it must look

7. **Designed, not computed.** "I want it to look as if each result was specifically designed, with as few bumps and stairstepping as possible. I want each TO result to be as smooth as possible and the best research behind how we implement that." (brief, G2)
8. **Smoothness is the optimiser's job.** "not just stairstepping, but also the bumps making it feel unprofessional. I want the algorithm to reward smooth walls." A mesh filter after the fact does not count: four were measured to fail (PR 299, 303, 314, 315).
9. **Targets.** Stair-steps: worst distance from a fitted smooth patch (3 mm) at most 0.05 mm. Ripple at 1 to 10 mm wavelengths at most 0.05 mm, except what the drawing or the load path demands ("a fillet is fine; a ripple is not"). Drawn faces flat within 0.02 mm; holes round and true to size. (brief, Phase 2)
10. **Walls.** Nothing thinner than 2 lines (0.9 mm on his 0.4 mm nozzle); thickness changes gradually. Enforced by the optimiser, not patched on the mesh. (brief; ledger F-05, V-03)
11. **Print checks, before he sees a file:** flat footing on the bed; no mid-air starts; bridge reach within the limit; no paper-thin open slot; nothing thinner than 2 lines. (brief, standing rules)
12. **The drawing follows the print file. Always.** (his rule 2026-11-19) What the app shows is exactly what core builds ("Preview is the spec").

## What he is told

13. **One judge, and nothing unchecked on screen.** A version is shown only after its own print file has passed the check; one accept rule decides. (ledger R-07, R-08)
14. **Any gap gets one plain line, never silence.** A refusal says why: for example, the part as drawn does not carry the load. (brief; ledger A-05)
15. **No warning cards for engine shortfalls.** Plain words; pictures over numbers; never face numbers. On-screen wording and placement follow his UI rules and are #362's to build (caption at most 5 words; errors as centred pop-ups; never a note at the bottom).

## Lattice

16. **One button, two results.** "Both of which should be a single button with the same inputs that receive vastly different results." (brief, G4)
17. **TOGETHER.** "creates a model with both Optimization and Lattices in mind, taking into account (but not taking it as the 'bible') the placement of the lattices that the user placed." Every difference from his placement is reported in one plain line each.
18. **THEN.** "the Optimization first, THEN latticing the areas that were selected, merging them both together seamlessly." Where optimisation removed a selected face, say so in one plain line. The merged whole is one watertight part and is certified as a whole.
19. **Priced by the new lattice engine's own laws**, so what is optimised is what is built; never the textbook law (it over-predicts stiffness by 23 to 52 % at a few cells per member).
20. **Void inside any lattice reaches the exterior.** (his visibility rule)

## Code

21. **Clean.** "I want the code cleaned up, re-written where it requires it, and made better." In practice: one implementation of each thing; no switch ships unless the app sends it; a temporary switch dies in the stage that made it; history lives in docs, one line of "why" stays in code.
22. **Preview drives core.** "I want the preview to be the driving force of the core algorithm. What we see in preview should be exactly what we get in core." (2026-11-09) When the two disagree, core changes to build what is drawn; if it cannot, the preview shows what core builds and says why.

## How we decide

23. **Measured, on a Release build, on ALL reference parts, at three settings or more, in a table.** A Debug build once turned 28 s into 590 s and four decisions rested on it.
24. **The no-go bar.** Nobody reports "not possible", "not printable" or "not viable" unless every cited paper that bears on it is answered by name, it was built and measured per rule 23, and the report names the target that failed, by how much, and what meeting it would cost in strength, mass or time. Mesh filters alone, one part, one weight or a 2D example do not count as tried.
25. **Verify against today's code; read everything before concluding.** (his rules)
26. **The shared certificate changes only together with LatticeReview**, through the reviewer. (ruling 2026-11-20 23:23Z)
27. **Every release is #362's.** Each stage leaves the app working and is reviewed before the next.
