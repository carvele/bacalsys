---
name: offline-outbox
description: Implement and test BaCalSys SQLite offline workout mutation journaling, replay, idempotency, crash recovery, and sync correctness.
---

# BaCalSys Offline Outbox

Use for offline workout logging, mutation queues, retry logic, idempotency, reconciliation, or connectivity handling.

## Core invariant

If the athlete confirms a set locally, loss of network or app restart must not silently lose that mutation.

SQLite is the durable source for unsynchronized workout writes.

## Mutation record

Each mutation needs at least:
- stable UUID idempotency key
- mutation type
- entity/session identity
- payload
- creation timestamp
- attempt count
- last attempt timestamp
- sync state
- last error if useful

## Write path

1. Validate locally.
2. Persist mutation transactionally to SQLite.
3. Reflect local UI state.
4. Attempt remote delivery when appropriate.
5. Delete/mark-synced only after authoritative server acknowledgement.

Never use "network appears online" as proof of successful persistence.

## Replay

- Preserve ordering where domain dependencies require it.
- Retrying the same idempotency key must be safe.
- Duplicate delivery must not duplicate server effects.
- A partial queue failure must not drop later records accidentally.
- Use bounded retry/backoff behavior.
- Distinguish retryable from permanent validation/auth failures.
- Refresh auth where appropriate before classifying failure.

If the server lacks an idempotency contract, stop and surface that gap rather than pretending client UUIDs alone provide idempotency.

## Conflict handling

Do not silently overwrite server history.

For workout execution, prefer append/idempotent operations and explicit reconciliation over last-write-wins.

## Required tests

Test at least:
- offline set logged -> restart -> still queued
- duplicate replay
- connection drops during drain
- first mutation succeeds, second fails
- expired auth then retry
- server already processed key but client missed acknowledgement
- outbox empty after confirmed successful synchronization
