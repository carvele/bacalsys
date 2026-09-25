---
name: workout-domain
description: Implement or review BaCalSys workout, assignment, session, skill, coaching, and feedback logic while preserving domain invariants.
---

# BaCalSys Workout Domain

Use whenever touching workout templates, versions, assignments, sessions, set logging, substitutions, coach access, feedback, skills, or attention indicators.

## Prescription vs actual

Prescription:
`workout_templates -> workout_versions -> workout_blocks -> workout_items -> workout_item_sets`

Actual execution:
`workout_sessions -> session_exercises -> session_sets`

Never overwrite prescription with actual values.

`session_sets.prescribed_item_set_id` can be null for added sets.

## Versioning

- Completed sessions stay pinned to the version performed.
- Started sessions stay pinned.
- Template updates create new versions.
- Future unstarted occurrences migrate only through the explicit policy selected by the coach.
- Never silently rewrite historical references.

## Substitution lineage

Every substituted exercise preserves:
- original workout item
- replacement exercise
- structured reason
- optional note

Do not reduce lineage to only original exercise ID; repeated exercises can exist in one workout.

## Assignment model

- `workout_assignments` = programming event
- `assignment_targets` = athletes
- `assignment_occurrences` = per-athlete scheduled units
- recurrence belongs to assignment
- missed is occurrence status
- session statuses are completed / partially_completed / abandoned
- do not invent an automatic percentage threshold for abandoned

## Coaching access

- athlete: own full history
- former coach: only sessions in assignment window
- current primary coach: full athlete history
- Leader/VP/President: organization-wide ordinary training visibility
- sensitive private feedback is more restricted

## Feedback

Ordinary:
- difficulty
- energy

Private:
- discomfort
- general area
- note to coach

Never merge private feedback into broad training queries without explicit authorization.

## Attention indicators

Return objective facts only:
- inactivity duration
- missed count
- repeated high RPE
- private discomfort flag only for authorized viewers
- prescribed-vs-actual deviation

Do not generate motivational/clinical judgments.

## Skills

Keep separate:
- current progression trained
- self-recorded attempts
- verified achievement

Self-recording must never automatically create verified achievement.
