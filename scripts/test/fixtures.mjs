/**
 * Test-fixture tagging convention shared by the E2E scripts and the guarded
 * cleanup (scripts/test/cleanup-fixtures.mjs).
 *
 * A fixture account carries BOTH tags, so a real member can never be matched:
 *   * an e-mail in the non-routable FIXTURE_DOMAIN, and
 *   * user metadata { bacalsys_test_fixture: "true" }.
 */
import { randomBytes } from 'node:crypto';

export const FIXTURE_DOMAIN = 'e2e.bacalsys.local';
export const FIXTURE_METADATA_KEY = 'bacalsys_test_fixture';

export const fixtureEmail = (role, runId) => `${role}.${runId}@${FIXTURE_DOMAIN}`;
export const fixtureMetadata = (fullName) => ({ full_name: fullName, [FIXTURE_METADATA_KEY]: 'true' });
export const randomPassword = () => `Bx-${randomBytes(18).toString('base64url')}`;
