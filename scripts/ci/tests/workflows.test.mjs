import test from 'node:test';
import assert from 'node:assert/strict';
import {loadWorkflows, validate} from '../workflow_policy.mjs';

test('checked-in workflows satisfy security and dependency gates', () => assert.deepEqual(validate(loadWorkflows()), []));
test('alternate submission, PR secrets and unpinned actions fail policy', () => {
  const workflows = loadWorkflows();
  workflows['metadata-only.yml'].jobs.review.environment = 'app-store-staging';
  workflows['pr.yml'].jobs.policy.steps.push({run: 'echo secret', env: {KEY: '${{ secrets.KEY }}'}});
  workflows['main.yml'].jobs.build.steps[0].uses = 'actions/checkout@main';
  const errors = validate(workflows).join('\n');
  assert.match(errors, /review requires production approval/);
  assert.match(errors, /PR path must not receive secrets/);
  assert.match(errors, /action must be pinned by SHA/);
});
test('compilation cannot acquire attestation permission', () => {
  const workflows = loadWorkflows();
  workflows['main.yml'].jobs.build.permissions = {'id-token': 'write'};
  assert.match(validate(workflows).join('\n'), /compilation must not sign provenance/);
});
