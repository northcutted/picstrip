import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {collect, generatedFiles, run, checkLinks} from '../docs.mjs';

const repo = fileURLToPath(new URL('../../../', import.meta.url));
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'picstrip-docs-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  for (const file of ['.github/workflows', '.github/ios-release.json', '.github/ios-release-platform.json', '.ruby-version', 'scripts/ci/changes.mjs']) {
    fs.mkdirSync(path.dirname(path.join(root, file)), {recursive: true});
    fs.cpSync(path.join(repo, file), path.join(root, file), {recursive: true});
  }
  fs.mkdirSync(path.join(root, 'docs/ci-cd'), {recursive: true});
  for (const file of ['docs/release-pipeline.md', 'docs/ci-cd/architecture.md', 'docs/ci-cd/maintenance.md']) fs.writeFileSync(path.join(root, file), '# Guide\n');
  fs.writeFileSync(path.join(root, 'docs/ci-cd/operations.md'), '# Operations\n\n## Replacement builds\n');
  return root;
}

test('generation is deterministic and check mode reports drift without changing files', t => {
  const root = fixture(t);
  assert.deepEqual(run(root), []);
  const before = new Map(generatedFiles(root));
  assert.deepEqual(generatedFiles(root), before);
  assert.deepEqual(run(root, true), []);
  const file = path.join(root, '.github/workflows/promote.yml');
  fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('description: Release action', 'description: Choose a distribution action'));
  assert.equal(run(root, true).filter(error => error.includes('is stale; run make docs')).length, 2);
  for (const [file, text] of before) assert.equal(fs.readFileSync(path.join(root, file), 'utf8'), text);
  assert.deepEqual(run(root), []);
  assert.deepEqual(run(root, true), []);
  assert.notEqual(generatedFiles(root).get('docs/ci-cd/reference.md'), before.get('docs/ci-cd/reference.md'));
});

test('new workflow discovery preserves inputs and dependencies without copying executable steps', t => {
  const root = fixture(t);
  fs.writeFileSync(path.join(root, '.github/workflows/example.yaml'), `name: Example
on:
  workflow_dispatch:
    inputs:
      submit:
        description: Stage | submit
        type: boolean
        default: false
jobs:
  first:
    runs-on: ubuntu-24.04
    steps:
      - run: echo do-not-copy-step-code
  second:
    needs: first
    runs-on: ubuntu-24.04
    if: inputs.submit
`);
  const data = collect(root);
  const workflow = data.workflows.find(workflow => workflow.name === 'Example');
  assert.equal(workflow.inputs.submit.default, false);
  assert.deepEqual(workflow.jobs[1].needs, ['first']);
  assert.equal(workflow.jobs[1].condition, 'inputs.submit');
  assert.ok(data.sources.includes('.github/workflows/example.yaml'));
  const files = generatedFiles(root);
  assert.ok(!files.get('docs/ci-cd/reference.json').includes('do-not-copy-step-code'));
  assert.match(files.get('docs/ci-cd/reference.md'), /Stage &#124; submit/);
  assert.deepEqual(run(root), []);
});

test('configuration edits update the reference; malformed workflow YAML fails closed', t => {
  const root = fixture(t);
  const file = path.join(root, '.github/ios-release.json');
  const config = JSON.parse(fs.readFileSync(file, 'utf8'));
  config.xcode.version = '99.0';
  config.locales.push('test-locale');
  fs.writeFileSync(file, JSON.stringify(config));
  assert.match(generatedFiles(root).get('docs/ci-cd/reference.md'), /99\.0/);
  assert.equal(collect(root).configuration.expected_screenshots, config.locales.length * Object.keys(config.screenshot_classes).length * config.screens.length);
  fs.writeFileSync(path.join(root, '.github/workflows/broken.yml'), 'name: First\nname: Second\non: push\njobs: {}\n');
  assert.throws(() => collect(root), /unique/i);
});

test('link validation finds new pages and missing headings; fenced samples are not links', t => {
  const root = fixture(t);
  fs.mkdirSync(path.join(root, 'docs/ci-cd/new'), {recursive: true});
  fs.writeFileSync(path.join(root, 'docs/ci-cd/new/guide.md'), '# Guide\n\n[Missing](missing.md)\n[Bad heading](../operations.md#missing)\n[Good](../operations.md#replacement-builds)\n[External](https://example.invalid/)\n\n```md\n[Example](also-missing.md)\n```\n');
  const errors = checkLinks(root);
  assert.equal(errors.length, 2);
  assert.match(errors[0], /missing link missing.md/);
  assert.match(errors[1], /missing heading .*#missing/);
});
