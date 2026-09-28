import test from 'node:test';
import assert from 'node:assert/strict';
import {classify, compare, full, gate} from '../changes.mjs';

test('only known documentation paths skip candidate and simulator work', () => {
  assert.deepEqual(classify(['README.md', 'docs/release-pipeline.md']), {qa: false, screenshots: false, prepare: false, store: false});
  assert.deepEqual(classify(['docs/guide.md', 'unrecognized/config']), full());
  assert.deepEqual(classify([]), full());
  assert.deepEqual(classify(['docs/../PicStrip/App.swift']), full());
});
test('store assets still prepare candidates without running unrelated developer tools', () => {
  for (const path of ['fastlane/metadata/en-US/description.txt', 'fastlane/screenshots/processed/en-US/image.png']) {
    assert.deepEqual(classify([path]), {qa: false, screenshots: false, prepare: true, store: true});
  }
});
test('app changes run both toolchains and UI smoke; tooling and dependencies run everything', () => {
  assert.deepEqual(classify(['PicStrip/ContentView.swift']), {qa: true, screenshots: true, prepare: true, store: false});
  assert.deepEqual(classify(['PicStripTests/MetadataTests.swift']), {qa: true, screenshots: false, prepare: true, store: false});
  for (const path of ['scripts/ios_release.py', '.ruby-version', 'fastlane/Fastfile', '.github/ios-release-platform.json', '.github/workflows/pr.yml', 'scripts/helper.py']) {
    assert.deepEqual(classify([path]), full());
  }
});
test('PRs compare the full branch including drafts; pushes compare the exact changed range', () => {
  const base = 'a'.repeat(40), head = 'b'.repeat(40);
  for (const draft of [true, false]) {
    const result = compare('pull_request', {pull_request: {draft, base: {sha: base}, head: {sha: head}}}, (...args) => {
      assert.deepEqual(args, ['diff', '--name-only', '--no-renames', '-z', `${base}...${head}`]);
      return 'docs/readme.md\0PicStrip/ContentView.swift\0';
    });
    assert.equal(result.qa, true);
  }
  const result = compare('push', {before: base, after: head}, (...args) => {
    assert.equal(args.at(-1), `${base}..${head}`);
    return 'docs/readme.md\0';
  });
  assert.equal(result.prepare, false);
});
test('missing history, malformed commits, new branches and manual runs retain every check', () => {
  const result = compare('pull_request', {pull_request: {base: {sha: 'a'.repeat(40)}, head: {sha: 'b'.repeat(40)}}}, () => { throw new Error('missing'); });
  assert.equal(result.qa, true);
  for (const result of [compare('push', {before: '0'.repeat(40), after: 'a'.repeat(40)}), compare('pull_request', {}), compare('workflow_dispatch', {})]) {
    for (const [key, value] of Object.entries(full())) assert.equal(result[key], value);
  }
});
test('renaming app code into docs retains source checks', () => {
  assert.equal(classify(['PicStrip/ContentView.swift', 'docs/ContentView.swift']).qa, true);
});
test('gate rejects failed classification and unexpected skipped/cancelled/failed jobs', () => {
  const jobs = {changes: {result: 'success'}, policy: {result: 'success'}, qa: {result: 'skipped'}, screenshots: {result: 'skipped'}};
  const selection = {qa: 'false', screenshots: 'false', store: 'false'};
  assert.doesNotThrow(() => gate(jobs, selection));
  assert.throws(() => gate({...jobs, changes: {result: 'failure'}}, selection));
  assert.throws(() => gate(jobs, {...selection, qa: 'true'}));
  assert.throws(() => gate(jobs, {...selection, qa: ''}));
  for (const result of ['failure', 'cancelled']) assert.throws(() => gate({...jobs, policy: {result}}, selection));
  const passed = Object.fromEntries(Object.keys(jobs).map(name => [name, {result: 'success'}]));
  assert.doesNotThrow(() => gate(passed, {qa: 'true', screenshots: 'true', store: 'true'}));
});
