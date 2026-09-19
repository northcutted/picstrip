import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import YAML from 'yaml';

const generator = 'slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@v2.1.0';
export function validate(workflows) {
  const errors = [];
  const check = (condition, message) => { if (!condition) errors.push(message); };
  for (const [file, workflow] of Object.entries(workflows)) {
    check(workflow.permissions?.contents === 'read', `${file}: default token must be read-only`);
    check(Object.keys(workflow.permissions ?? {}).length === 1, `${file}: additional permissions belong only on the jobs that need them`);
    check(!workflow.on?.pull_request_target, `${file}: pull_request_target is not permitted`);
    for (const [name, job] of Object.entries(workflow.jobs ?? {})) {
      const label = `${file}/${name}`;
      if (job.uses) {
        check(job.uses.startsWith('./.github/workflows/') || job.uses === generator, `${label}: untrusted reusable workflow`);
        continue;
      }
      check(Number.isInteger(job['timeout-minutes']) && job['timeout-minutes'] <= 240, `${label}: bounded timeout required`);
      check(!JSON.stringify(job['runs-on']).includes('self-hosted'), `${label}: hosted runners required`);
      const steps = job.steps ?? [];
      const scripts = steps.map(step => step.run ?? '').join('\n');
      check(!/\$\{\{\s*(inputs\.|github\.event\.)/.test(scripts), `${label}: pass event/input data via environment`);
      check(!/OCSPStyle|Cache DerivedData|skip_waiting_for_build_processing:\s*false/.test(scripts), `${label}: forbidden insecure/stale setup`);
      for (const step of steps) {
        if (!step.uses) continue;
        check(/@[a-f0-9]{40}$/.test(step.uses), `${label}: action must be pinned by SHA`);
        if (step.uses.startsWith('actions/checkout@')) check(step.with?.['persist-credentials'] === false, `${label}: checkout credentials must not persist`);
        check(!step.uses.startsWith('actions/cache@'), `${label}: no opaque executable/build caches`);
      }
      if (/fastlane (build|test|analyze)|swiftlint lint/.test(scripts)) {
        check(!job.permissions?.['id-token'] && !job.permissions?.attestations, `${label}: compilation must not sign provenance`);
      }
      if (/fastlane build/.test(scripts)) {
        check(job.environment === 'signing', `${label}: signing environment required`);
        check(!JSON.stringify(steps).includes('APP_STORE_CONNECT_API_KEY'), `${label}: App Store key in compilation job`);
      }
      if (/fastlane request_review/.test(scripts)) {
        check(job.environment === 'production', `${label}: review requires production approval`);
        check(scripts.includes('download_release.sh'), `${label}: submission must reauthenticate release`);
        check(job.concurrency?.group === 'picstrip-app-store-mutations' && job.concurrency?.['cancel-in-progress'] === false, `${label}: shared submission lock required`);
      }
      if (file === 'pr.yml' || file === 'qa.yml') {
        check(!JSON.stringify(job).includes('secrets.'), `${label}: PR path must not receive secrets`);
        check(!job.environment && !job.permissions?.['id-token'], `${label}: privileged PR job`);
      }
    }
  }
  const main = workflows['main.yml'];
  check(![].concat(main.jobs.build.needs).includes('qa'), 'main: archive must run alongside QA');
  check(main.jobs.upload.needs.includes('verify'), 'main: upload bypasses verification');
  check(main.jobs.upload.if === "needs.version.outputs.publish == 'true'", 'main: upload bypasses distribution switch');
  check(workflows['pr.yml'].jobs.gate.name === 'CI Gate' && workflows['pr.yml'].jobs.gate.if === 'always()', 'PR gate must always report');
  check(workflows['app-store-deploy.yml'].on.release?.types.includes('published'), 'deploy must consume published releases');
  check(!workflows['app-store-deploy.yml'].on.push, 'deploy must not race tag publication');
  return errors;
}

export function loadWorkflows(root = '.github/workflows') {
  return Object.fromEntries(fs.readdirSync(root).filter(name => name.endsWith('.yml')).map(name => [name, YAML.parse(fs.readFileSync(path.join(root, name), 'utf8'))]));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const errors = validate(loadWorkflows());
  if (errors.length) { console.error(errors.join('\n')); process.exitCode = 1; }
  else console.log('Workflow security and release-gate policy passed.');
}
