import { buildUpdateProgressionArgs, isProgressionDraftValid, progressionDraftFrom, validateProgressionDraft } from '../progression-form';

describe('progressionDraftFrom', () => {
  it('seeds the draft from a hold-based rung', () => {
    expect(progressionDraftFrom({ name: 'Tuck Planche', description: 'Hold it.', targetHoldSeconds: 15, targetReps: null })).toEqual({
      name: 'Tuck Planche',
      description: 'Hold it.',
      target: '15',
    });
  });
  it('seeds the draft from a rep-based rung with no description', () => {
    expect(progressionDraftFrom({ name: 'High Pull-Up', description: null, targetHoldSeconds: null, targetReps: 8 })).toEqual({
      name: 'High Pull-Up',
      description: '',
      target: '8',
    });
  });
});

describe('validateProgressionDraft', () => {
  const base = { name: 'Rung', description: '', target: '15' };
  it('requires a non-blank name under 120 characters', () => {
    expect(validateProgressionDraft('hold', { ...base, name: '' }).name).toBeDefined();
    expect(validateProgressionDraft('hold', { ...base, name: '   ' }).name).toBeDefined();
    expect(validateProgressionDraft('hold', { ...base, name: 'x'.repeat(121) }).name).toBeDefined();
    expect(isProgressionDraftValid(validateProgressionDraft('hold', base))).toBe(true);
  });
  it('caps the description at 2000 characters', () => {
    expect(validateProgressionDraft('hold', { ...base, description: 'x'.repeat(2001) }).description).toBeDefined();
  });
  it('requires a positive integer target', () => {
    expect(validateProgressionDraft('hold', { ...base, target: '' }).target).toBeDefined();
    expect(validateProgressionDraft('hold', { ...base, target: '0' }).target).toBeDefined();
    expect(validateProgressionDraft('reps', { ...base, target: '-1' }).target).toBeDefined();
  });
});

describe('buildUpdateProgressionArgs', () => {
  it('sends only the target matching the mode, trims text, and nulls a blank description', () => {
    expect(buildUpdateProgressionArgs('hold', { name: '  Tuck Planche  ', description: '  ', target: '15' }, 'rung-1')).toEqual({
      progressionId: 'rung-1',
      name: 'Tuck Planche',
      description: null,
      targetHoldSeconds: 15,
      targetReps: null,
    });
    expect(buildUpdateProgressionArgs('reps', { name: 'High Pull-Up', description: 'Explosive.', target: '8' }, 'rung-2')).toEqual({
      progressionId: 'rung-2',
      name: 'High Pull-Up',
      description: 'Explosive.',
      targetHoldSeconds: null,
      targetReps: 8,
    });
  });
});
