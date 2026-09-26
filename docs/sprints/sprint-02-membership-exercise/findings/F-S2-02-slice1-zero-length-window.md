# F-S2-02: Hosted Slice 1 reassigned within one second

- **Class:** Bug (test harness only, no product change)
- **Found by:** SQL check of the scope helpers against the real rows from the first hosted Slice 1 run

**Symptom.** `former_coach_can_view(A, ended_at - interval '1 second')` returned `false` on real hosted rows, but the
spec expects `true`.

**Root cause.** `scripts/e2e/sprint2-slices.mjs` reassigned Athlete A only 0.998 s after assigning them. The window
`[started_at, ended_at)` was shorter than one second, so `ended_at - 1s` fell before `started_at`. The helper's answer
was mathematically correct. The pgTAP suite was unaffected, because it backdates the window by 30 days.

**Fix.** The E2E holds the Coach X assignment for 3 s before reassigning. The rerun on fresh fixtures had a
**4.463 s** window, and every boundary matched the spec: `started_at` true, `ended_at - 1s` true, `ended_at` false,
`ended_at + 1h` false.

**Regression test.** The `slice1` step now waits before reassigning, and the hosted helper check is recorded in
STATUS.md.
