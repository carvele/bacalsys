# F-06: Web build would consider itself offline when served from a sub-path

- **Class:** Bug
- **Found by:** production web smoke test (sub-path build served locally), before deployment

**Symptom:** repeated `HEAD /` requests to the page origin returning 404.

**Root cause:** NetInfo's web default probes `HEAD /` on the origin and treats anything but HTTP 200 as "no internet".
Under GitHub Pages (`/bacalsys/`) the origin root is 404, so TanStack Query's `onlineManager` would have paused every
query after sign-in and left the app on a spinner. It never showed up in dev, where the origin root returns 200.

**Fix:** `src/lib/netinfo-config.ts`, where web reachability probes Supabase `/auth/v1/health` (GET + publishable key).
Cross-origin 200 was verified from a browser. Regression: `src/lib/__tests__/netinfo-config.test.ts` (4 tests).
Native reachability is unchanged.
