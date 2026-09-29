import { buildLogAttemptArgs, isAttemptDraftValid, rungMode, validateAttemptDraft } from '../attempt-form';

describe('rungMode', () => {
  it('asks for a hold when the rung has a hold target, otherwise reps', () => {
    expect(rungMode({ targetHoldSeconds: 15, targetReps: null })).toBe('hold');
    expect(rungMode({ targetHoldSeconds: null, targetReps: 8 })).toBe('reps');
  });
});

describe('validateAttemptDraft', () => {
  it('requires a positive integer metric', () => {
    expect(validateAttemptDraft('hold', { metric: '', videoUrl: '' }).metric).toBeDefined();
    expect(validateAttemptDraft('hold', { metric: '0', videoUrl: '' }).metric).toBeDefined();
    expect(validateAttemptDraft('hold', { metric: '-3', videoUrl: '' }).metric).toBeDefined();
    expect(validateAttemptDraft('hold', { metric: '3.5', videoUrl: '' }).metric).toBeDefined();
    expect(validateAttemptDraft('hold', { metric: 'abc', videoUrl: '' }).metric).toBeDefined();
    expect(isAttemptDraftValid(validateAttemptDraft('hold', { metric: '18', videoUrl: '' }))).toBe(true);
  });
  it('rejects an unreasonably large metric for each mode', () => {
    expect(validateAttemptDraft('hold', { metric: '99999', videoUrl: '' }).metric).toBeDefined();
    expect(validateAttemptDraft('reps', { metric: '5000', videoUrl: '' }).metric).toBeDefined();
  });
  it('an empty video link is fine; a non-http(s) one is rejected', () => {
    expect(isAttemptDraftValid(validateAttemptDraft('reps', { metric: '5', videoUrl: '' }))).toBe(true);
    expect(validateAttemptDraft('reps', { metric: '5', videoUrl: 'not-a-link' }).videoUrl).toBeDefined();
    expect(validateAttemptDraft('reps', { metric: '5', videoUrl: 'ftp://example.com' }).videoUrl).toBeDefined();
    expect(isAttemptDraftValid(validateAttemptDraft('reps', { metric: '5', videoUrl: 'https://youtube.com/watch?v=sample' }))).toBe(true);
  });
});

describe('buildLogAttemptArgs', () => {
  it('sends only the metric matching the mode, and null for an empty video link', () => {
    expect(buildLogAttemptArgs('hold', { metric: '18', videoUrl: '' }, 'rung-1')).toEqual({
      progressionId: 'rung-1',
      attemptDate: null,
      actualHoldSeconds: 18,
      actualReps: null,
      videoUrl: null,
    });
    expect(buildLogAttemptArgs('reps', { metric: '8', videoUrl: ' https://x.test ' }, 'rung-2')).toEqual({
      progressionId: 'rung-2',
      attemptDate: null,
      actualHoldSeconds: null,
      actualReps: 8,
      videoUrl: 'https://x.test',
    });
  });
});
