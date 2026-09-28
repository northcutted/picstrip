import fs from 'node:fs';import path from 'node:path';import {pathToFileURL} from 'node:url';import YAML from 'yaml';
const pin=JSON.parse(fs.readFileSync('.github/ios-release-platform.json','utf8'));
export function loadWorkflows(root='.github/workflows'){return Object.fromEntries(fs.readdirSync(root).filter(f=>f.endsWith('.yml')).map(f=>[f,YAML.parse(fs.readFileSync(path.join(root,f),'utf8'))]));}
export function validate(workflows){
 const errors=[];const check=(value,message)=>{if(!value)errors.push(message);};
 check(/^[a-f0-9]{40}$/.test(pin.revision),'Platform revision must be a full commit');
 for(const [file,w] of Object.entries(workflows)){
  check(JSON.stringify(w.permissions)==='{"contents":"read"}',file+': default token must be read-only');
  check(!w.on?.pull_request_target,file+': privileged PR events forbidden');
  for(const [name,j]of Object.entries(w.jobs||{})){
   const label=file+'/'+name;
   if(j.uses){
    check(j.uses.startsWith(pin.repository+'/.github/workflows/')&&j.uses.endsWith('@'+pin.revision),label+': reusable workflow differs from trusted platform pin');
    check(j.with?.platform_revision===pin.revision,label+': signer revision differs from workflow revision');
    const apple=['APP_STORE_CONNECT_API_KEY_ID','APP_STORE_CONNECT_API_KEY_ISSUER_ID','APP_STORE_CONNECT_API_KEY_CONTENT'];
    const required={ci:[],prepare:['MATCH_PASSWORD','MATCH_SSH_PRIVATE_KEY'],promote:[...apple,'RELEASE_APP_ID','RELEASE_APP_PRIVATE_KEY'],release:[...apple,'RELEASE_APP_ID','RELEASE_APP_PRIVATE_KEY'],deploy:apple,observe:apple}[j.uses.split('/').at(-1).split('.yml@')[0]];
    const bindings=j.secrets||{};
    check(required&&typeof bindings==='object'&&!Array.isArray(bindings)&&JSON.stringify(Object.keys(bindings).sort())===JSON.stringify([...required].sort())&&required.every(key=>bindings[key]==='${{ secrets.'+key+' }}'),label+': explicit environment secret bindings required; environment secrets must not be inherited/passed broadly');
    if(file==='pr.yml')check(!j.permissions?.['id-token'],label+': privileged PR call');
    continue;
   }
   check(Number.isInteger(j['timeout-minutes'])&&j['timeout-minutes']<=(file==='screenshots.yml'?240:90),label+': bounded timeout required');
   const scripts=(j.steps||[]).map(s=>s.run||'').join('\n');
   check(!/\$\{\{\s*(inputs\.|github\.event\.)/.test(scripts),label+': unsafe input interpolation');
   for(const s of j.steps||[])if(s.uses){
    check(/@[a-f0-9]{40}$/.test(s.uses),label+': action must be pinned by SHA');
    if(s.uses.startsWith('actions/checkout@'))check(s.with?.['persist-credentials']===false,label+': persisted checkout credentials');
    if(s.uses.startsWith(pin.repository+'/'))check(s.uses.endsWith('@'+pin.revision),label+': platform action revision drift');
   }
   if(file==='pr.yml')check(!JSON.stringify(j).includes('secrets.')&&!j.environment&&!j.permissions?.['id-token'],label+': PR path must not receive secrets');
   check(!/fastlane (request_review|app_store_stage|metadata_only|upload_testflight)|publish_release\.py/.test(scripts),label+': release administration belongs in pinned platform');
  }
 }
 check(!workflows['pr.yml'].jobs['gems-macos'], 'Platform and screenshot checks own Ruby dependency validation');
 const smoke=workflows['pr.yml'].jobs.screenshots;
 check(smoke.strategy?.matrix?.device==='${{ fromJSON(needs.changes.outputs.screenshot_devices) }}'&&smoke.strategy?.['fail-fast']===false,'Every configured screenshot device must run on a separate host and retain its result');
 check(smoke.steps.some(step=>step.env?.SCREENSHOT_DEVICE==='${{ matrix.device }}'&&step.run?.includes('--devices "$SCREENSHOT_DEVICE"')),'Screenshot capture must select exactly its matrix device');
 for(const file of ['pr.yml','screenshots.yml'])check(!/bundle (install|exec fastlane)/.test(JSON.stringify(workflows[file])), 'Screenshot tools must use the supported platform command and locked Ruby action');
 check(workflows['main.yml'].jobs.prepare.uses.includes('/prepare.yml@'),'Main must only prepare candidates');
 check(JSON.stringify(Object.keys(workflows['main.yml'].jobs).sort())===JSON.stringify(['changes','prepare']),'Main may only classify changes and prepare candidates');
 check(workflows['main.yml'].jobs.prepare.if==="needs.changes.outputs.prepare == 'true'",'Preparation must honor classified release inputs');
 check(!workflows['pr.yml'].on.pull_request.types.some(type=>['labeled','unlabeled'].includes(type)),'Unrelated labels must not restart PR checks');
 check(workflows['pr.yml'].jobs.gate.needs.includes('changes'),'CI Gate must require classification');
 for(const [job,flag] of [['qa','qa'],['screenshots','screenshots']])check(workflows['pr.yml'].jobs[job].if===`needs.changes.outputs.${flag} == 'true'`,job+': must honor conservative classification');
 check(workflows['promote.yml'].on.workflow_dispatch&&!workflows['promote.yml'].on.push,'Promotion must be explicit');
 check(workflows['pr.yml'].jobs.gate.name==='CI Gate'&&workflows['pr.yml'].jobs.gate.if==='always()','CI Gate must always report');
 check(workflows['app-store-deploy.yml'].on.release?.types.includes('published'),'Deploy must consume published release');
 check(workflows['promote.yml'].jobs.promote.uses.includes('/release.yml@'),'Release must use the verified selection interface');
 check(workflows['promote.yml'].on.workflow_dispatch.inputs.source.required,'Release must identify an explicit source');
 check(workflows['app-store-deploy.yml'].jobs.deploy.with.metadata_commit==='${{ needs.resolve.outputs.metadata_commit }}','Metadata updates must preserve the resolved exact commit');
 return errors;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){const errors=validate(loadWorkflows());if(errors.length){console.error(errors.join('\n'));process.exitCode=1;}else console.log('Consumer workflow policy passed.');}
