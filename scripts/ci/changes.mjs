#!/usr/bin/env node
// Only explicitly understood paths may skip expensive checks. Unknown changes
// and unavailable comparison history retain the complete validation path.
import fs from 'node:fs';
import {execFileSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';

export const full = () => ({qa: true, gems: true, screenshots: true, prepare: true, store: true});

export function classify(paths) {
  const result = {qa: false, gems: false, screenshots: false, prepare: false, store: false};
  if (!paths.length) return full();
  for (const path of paths) {
    if (!path || path.startsWith('/') || path.split('/').includes('..')) return full();
    if (/^(docs\/|\.github\/ISSUE_TEMPLATE\/)/.test(path)
        || /^(README|DEVELOPMENT|LICENSE|CHANGELOG)(\.md|\.txt)?$/.test(path)) continue;
    if (/^fastlane\/(metadata\/|screenshots\/processed\/)/.test(path)) {
      result.prepare = result.store = true;
      continue;
    }
    if (/^(PicStrip\/|PicStripShareExtension\/|PicStripTests\/|PicStripUITests\/|PicStripCore\/|PicStrip\.xcodeproj\/)/.test(path)
        || /^PicStrip-Info\.plist$/.test(path)) {
      result.qa = result.prepare = true;
      if (!path.startsWith('PicStripTests/')) result.screenshots = true;
      continue;
    }
    // CI, dependencies, developer tools, and unrecognized source all need the
    // full suite. This deliberately favors extra work over a false green.
    return full();
  }
  return result;
}

export function gate(jobs, selection) {
  for (const name of ['changes', 'policy']) {
    if (jobs[name]?.result !== 'success') throw new Error(`${name} did not pass`);
  }
  for (const flag of ['qa', 'gems', 'screenshots', 'store']) {
    if (!['true', 'false'].includes(selection[flag])) throw new Error(`Invalid ${flag} decision`);
  }
  for (const [job, flag] of [['qa', 'qa'], ['gems-macos', 'gems'], ['screenshots', 'screenshots']]) {
    const expected = selection[flag] === 'true' ? 'success' : 'skipped';
    if (jobs[job]?.result !== expected) throw new Error(`${job}: expected ${expected}, got ${jobs[job]?.result}`);
  }
}

export function compare(eventName, event, git = (...args) => execFileSync('git', args, {encoding: 'utf8'})) {
  if (eventName === 'workflow_dispatch') return {...full(), reason: 'Manual run requests every check'};
  let base, head;
  if (eventName === 'pull_request') {
    base = event.pull_request?.base?.sha;
    head = event.pull_request?.head?.sha;
  } else if (eventName === 'push') {
    base = event.before;
    head = event.after;
  } else return {...full(), reason: 'Unknown event'};
  if (![base, head].every(value => /^[a-f0-9]{40}$/.test(value || '') && !/^0+$/.test(value))) {
    return {...full(), reason: 'No reliable comparison commits'};
  }
  try {
    // --no-renames includes both removed and added names, so moving source into
    // a documentation folder cannot bypass source checks.
    const range = eventName === 'pull_request' ? `${base}...${head}` : `${base}..${head}`;
    const paths = git('diff', '--name-only', '--no-renames', '-z', range).split('\0').filter(Boolean);
    return {...classify(paths), reason: `${paths.length} changed paths`, paths};
  } catch {
    return {...full(), reason: 'Comparison unavailable; running every check'};
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv[2] === 'gate') {
    gate(JSON.parse(process.env.JOBS), JSON.parse(process.env.SELECTION));
    console.log('Required checks passed; every skip matches the change classification.');
  } else {
    const event = JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8'));
    const selection = compare(process.env.GITHUB_EVENT_NAME, event);
    fs.appendFileSync(process.env.GITHUB_OUTPUT, Object.entries(selection)
      .filter(([key]) => ['qa', 'gems', 'screenshots', 'prepare', 'store'].includes(key))
      .map(([key, value]) => `${key}=${value}\n`).join(''));
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,
      `Checks selected: QA=${selection.qa}, developer gems=${selection.gems}, UI smoke=${selection.screenshots}, release candidate=${selection.prepare}. ${selection.reason}.\n`);
  }
}
