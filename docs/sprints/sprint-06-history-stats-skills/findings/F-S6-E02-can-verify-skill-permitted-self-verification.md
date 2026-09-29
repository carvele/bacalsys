# F-S6-E02 — `can_verify_skill` as specified would let an officer-athlete verify their own skill

- **Class:** Bug (authorization gap in the frozen predicate text, closed before any hosted apply).
- **Found by:** the Executor, reading Section 13's `app_private.can_verify_skill` listing against the
  athlete/officer overlap the roadmap's own Rule A/D allow (a Vice President or President is also a training club
  member and can hold an `athlete_skill_status` row).

## Symptom (as specified)

Section 13's listed body:

```sql
SELECT app_private.is_active_member()
   AND app_private.has_permission('skills:verify')
   AND EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = p_athlete_id AND p.status = 'active')
   AND (
     (app_private.has_permission('training:view_org') AND app_private.same_organization(p_athlete_id))
     OR app_private.current_coach_can_view(p_athlete_id)
   );
```

has no term excluding `p_athlete_id = auth.uid()`. A Vice President or President who trains (holds `skills:verify` +
`training:view_org` + `same_organization(self) = true`, trivially) would satisfy every clause for
`p_athlete_id = their own id`, and so could call `review_skill_attempt`, `verify_skill_achievement` and
`revoke_skill_achievement` on their **own** milestones — an athlete self-attesting their own verified skill, which is
not review by anyone.

## Fix

`app_private.can_verify_skill` ([20260929000004_skills_and_history_helpers.sql](../../../../supabase/migrations/20260929000004_skills_and_history_helpers.sql))
adds `AND p_athlete_id IS DISTINCT FROM auth.uid()`. Verification is now structurally a third-party attestation for
every caller, including officers who also train.

## Regression test (failing-first)

`supabase/tests/017_skills_and_progressions.test.sql` §6 ("Self-verification is impossible", assertions #41–#43): a
Vice President who logs their own attempt is refused (`42501`) reviewing it, verifying it directly, and a peer
officer (President) successfully reviews it instead. Written and run against the fix (the predicate never existed
without the guard in this codebase, so there is no "before" state to demonstrate on — the finding is recorded from
reading the frozen text, not from a regression against previously-shipped code).

## Verification

pgTAP 017 assertions #41–#43. Not separately re-proven on `bacalsys-dev` (the pgTAP coverage is exhaustive here —
11-identity-matrix style, cheaper to prove offline than to script over HTTP).
