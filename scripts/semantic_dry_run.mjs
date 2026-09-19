#!/usr/bin/env node
// Read-only Conventional Commit analysis; never runs the git push preflight.
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
import {analyzeCommits} from '@semantic-release/commit-analyzer';
import {generateNotes} from '@semantic-release/release-notes-generator';
import semver from 'semver';

export async function analyze(cwd = process.cwd()) {
  const git = (...args) => execFileSync('git', args, {cwd, encoding: 'utf8'}).trim();
  const config = JSON.parse(fs.readFileSync(path.join(cwd, '.releaserc.json')));
  const source = git('rev-parse', 'HEAD');
  const tags = git('tag', '--merged', source).split('\n')
    .filter(tag => /^v\d+\.\d+\.\d+$/.test(tag) && semver.valid(tag.slice(1)))
    .sort((a, b) => semver.rcompare(a.slice(1), b.slice(1)));
  const tag = tags[0];
  const previous = tag ? {version: tag.slice(1), gitTag: tag, gitHead: git('rev-list', '-1', tag)} : {};
  const hashes = git('rev-list', tag ? `${tag}..${source}` : source).split('\n').filter(Boolean);
  const commits = hashes.map(hash => ({hash, message: git('show', '-s', '--format=%B', hash)}));
  const logger = {log() {}, error() {}, success() {}};
  const context = {cwd, env: process.env, logger, commits, lastRelease: previous,
    options: {repositoryUrl: 'https://github.com/northcutted/picstrip', tagFormat: 'v${version}'},
    branch: {name: 'main', type: 'release'}};
  const options = name => config.plugins.find(plugin => plugin[0] === name)?.[1] ?? {};
  const type = await analyzeCommits(options('@semantic-release/commit-analyzer'), context);
  const version = type ? (tag ? semver.inc(previous.version, type) : '1.0.0') : (previous.version || '1.0.0');
  const nextRelease = {version, gitTag: `v${version}`, gitHead: source};
  const notes = type ? await generateNotes(options('@semantic-release/release-notes-generator'), {...context, nextRelease}) : 'Verification build; no release changes.';
  return {will_release: Boolean(type), version, git_tag: `v${version}`, source_sha: source, notes};
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const result = await analyze();
  const output = process.argv[2] || 'build/semantic-release.json';
  fs.mkdirSync(path.dirname(output), {recursive: true});
  fs.writeFileSync(output, JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result));
}
