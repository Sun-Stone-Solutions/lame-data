# CLAUDE.md

Conventions for working on this repo. Auto-loaded by Claude Code; also useful for any AI-assisted workflow.

## Parking ideas: `IDEAS.md`

When a good idea surfaces but isn't ready to implement (scope creep, tangential, "later"), park it in `IDEAS.md` at the repo root rather than kicking off the work or losing the thought.

Format for each entry:

```markdown
## <short title>

**Status:** not started | in progress | blocked

**Motivation:** Why this matters — the problem it solves or the pain it
relieves. One paragraph, no more.

**Sketch:** File-level or architectural outline of the approach, specific
enough that a future session can pick it up cold.

**Tests / Verification:** How you'd know it worked.

**Tradeoff:** The main cost of the approach, or the reason we didn't do it
right away.
```

When the idea gets built, either delete the entry or move it into the commit message. `IDEAS.md` is a parking lot, not a permanent record — keep it short.

## Plan-then-build for non-trivial work

For any feature beyond a typo-level change, propose a plan first — called-out decisions, tradeoffs, anything intentionally out of scope — before writing code. Use `AskUserQuestion` only for real branch points; don't pad plans with questions you can confidently recommend on. Once the plan is agreed, build against it.

This cadence matters because the code ships to a Raspberry Pi at a barn that's painful to SSH into. A bad design call costs a physical trip.

## Test gate for the Pi software

Any change under `software/raspberry-pi/` must keep `software/raspberry-pi/tests/` green. The suite uses Flask's `test_client()` with per-test monkeypatching of on-disk paths (see `tests/conftest.py`); UDP listener and cloud upload paths are intentionally not covered.

`upgrade.sh` runs `pytest -x` between `git pull` and `systemctl restart horse-recorder`, so a red suite is the difference between a deploy and a rolled-back commit. The same workflow runs in GitHub Actions on every push (`.github/workflows/test.yml`).

When adding a feature, add tests that pin the contracts downstream code depends on — the exact JSON shape the frontend reads, the exact CSV header strings a parser looks for. Locking behavior is more useful than just covering code paths.

## Latent bugs: pin, don't silently fix

If you find a pre-existing bug while working on something else, don't fix it silently. Pin the current behavior in a test with a comment pointing at the real fix (example: `tests/test_sessions_api.py` documents the `# Total Samples:` footer parser bug in `list_sessions()`). This keeps the scope of the current change honest and surfaces the bug as its own decision later.

## Navigation taxonomy

Top-level routes on the Pi web UI are for **primary user actions or live views**:

- `/` Recorder — the thing you actually do
- `/sessions` Review recorded data
- `/settings` Theme + system actions (upgrade, reboot, shutdown)

Domain entities that are edited less often but are first-class concepts get their own route *without* a top-nav link — reachable from where they're used:

- `/protocols` — reached via the "Manage protocols →" link on the Recorder

The nav bar stays short and frequent-use; rare-edit screens don't clutter it. If you add a new entity (e.g. horses, riders), follow the same pattern: its own route, a link from the surface where it's referenced, no top-nav entry unless it's part of the daily flow.

## Session-writing conventions

- Default to no comments in code. The existing codebase is sparse — match that. Only annotate the non-obvious *why* (a subtle invariant, a workaround for a specific bug, a surprising fact about the environment).
- Don't create planning or analysis documents unless asked. `IDEAS.md` is for parked ideas, not scratch notes.
- Prefer editing existing files to creating new ones. Single-purpose files (`conftest.py`, a new template) are fine; sprawling helper modules aren't.
