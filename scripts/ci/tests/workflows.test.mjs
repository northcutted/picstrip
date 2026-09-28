import test from 'node:test';import assert from 'node:assert/strict';import {loadWorkflows,validate} from '../workflow_policy.mjs';
test('consumer workflows satisfy platform pin and approval boundaries',()=>assert.deepEqual(validate(loadWorkflows()),[]));
test('mutable platform calls and broad secret inheritance are rejected',()=>{const w=loadWorkflows();w['main.yml'].jobs.prepare.uses=w['main.yml'].jobs.prepare.uses.replace(/@[a-f0-9]{40}$/,'@main');w['main.yml'].jobs.prepare.secrets='inherit';const errors=validate(w).join('\n');assert.match(errors,/trusted platform pin/);assert.match(errors,/environment secrets/);});
test('PR secrets, unsafe interpolation and automatic promotion are rejected',()=>{const w=loadWorkflows();w['pr.yml'].jobs.policy.steps.push({run:'echo ${{ inputs.untrusted }}',env:{KEY:'${{ secrets.KEY }}'}});w['promote.yml'].on.push={};const errors=validate(w).join('\n');assert.match(errors,/PR path/);assert.match(errors,/unsafe input/);assert.match(errors,/explicit/);});

test('missing environment secret bindings fail before a signed rehearsal',()=>{const w=loadWorkflows();delete w['main.yml'].jobs.prepare.secrets.MATCH_SSH_PRIVATE_KEY;assert.match(validate(w).join('\n'),/explicit environment secret bindings/);});

test('unrelated label restarts and missing classification cannot silently return',()=>{
 const w=loadWorkflows();w['pr.yml'].on.pull_request.types.push('labeled');
 w['pr.yml'].jobs.gate.needs=w['pr.yml'].jobs.gate.needs.filter(name=>name!=='changes');
 const errors=validate(w).join('\n');assert.match(errors,/labels/);assert.match(errors,/require classification/);
});
test('release selection and exact metadata forwarding are required',()=>{
 const w=loadWorkflows();w['promote.yml'].on.workflow_dispatch.inputs.source.required=false;
 w['app-store-deploy.yml'].jobs.deploy.with.metadata_commit='main';
 const errors=validate(w).join('\n');assert.match(errors,/explicit source/);assert.match(errors,/resolved exact commit/);
});
