# DECISIONS.md — Human-approved architecture changes

Append-only. Entries are written by the human maintainer (Nadim) only.

- 2026-07-03: Re handoff 001 (Blocked): GitHub remote created by Nadim.
  Agents will not be granted repo-creation or push-to-main permissions.
- 2026-07-03: Re handoff 002 (Blocked): PR #1 merged by Nadim. Standing
  process: agents work on branches and open PRs; the human merges after
  reviewer audit.
- 2026-07-03: Re handoff 003: workers must obtain CI evidence via branch + PR (per run 002's precedent) before handoff; local-only evidence is not sufficient for rule 5.
- 2026-07-03: Re handoffs 003/004 (CI evidence): local test output alone does
  NOT satisfy rule 5 ("all CI green before handoff"). Workers must push their
  work as a branch and open a PR (per run 002's precedent) so CI runs, and
  must paste the green run's URL in the handoff. "No push access to main" is
  not an accepted reason to skip this.
- 2026-07-03: Re M1.3 fixtures: files under core/tests/fixtures/ are authored
  and committed by the human maintainer only. Agents consume fixtures and
  assert against expected_values.json; they never create, edit, or regenerate
  fixture files.
