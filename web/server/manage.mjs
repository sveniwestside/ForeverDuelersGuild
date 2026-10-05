import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readFileSync, writeFileSync } from 'node:fs';
import { createStore } from './store.mjs';

const usage = `Local administrator tools (Node.js 24):
  node server/manage.mjs provision --guid Player-1-ABC --name Name --realm Realm --classFile MAGE --level 60 --maxLevel 60
  node server/manage.mjs revoke --guid Player-1-ABC
  node server/manage.mjs stats
  node server/manage.mjs link-character --guid Player-1-ABC --region eu --namespace profile-eu --realmSlug argent-dawn --characterName FullName --realmId 1 --characterId 2748
  node server/manage.mjs unlink-character --guid Player-1-ABC
  node server/manage.mjs models
  node server/manage.mjs audit
  node server/manage.mjs dataset-export --maxLevel 60 --dataCutoff 1791130000 --out dataset.json
  node server/manage.mjs analysis-publish --file report.json
  node server/manage.mjs model-activate --approve yes --file candidate.json --effectiveFrom 1791140000
Provision creates or rotates one character-bound token. The new token is printed once to stdout. Revocation invalidates that GUID's current token.
DB_PATH chooses the database; default: web/data/foreverduel.sqlite. Provisioning and character mapping are local administrator assertions, not proof of WoW ownership. Character mapping requires explicit region, namespace, API realm slug, full API name and numeric API IDs; never infer a retail match or API IDs for Forever. Forever profile support has not been verified.`;
export function manage(args, { store, output = console.log } = {}) {
  const [command, ...rest] = args, flags = {};
  for (let index = 0; index < rest.length; index += 2) {
    if (!/^--[A-Za-z]+$/u.test(rest[index]) || rest[index + 1] === undefined || rest[index + 1].startsWith('--') || flags[rest[index].slice(2)] !== undefined) throw new Error(usage);
    flags[rest[index].slice(2)] = rest[index + 1];
  }
  const allowed = command === 'provision' ? ['guid', 'name', 'realm', 'classFile', 'level', 'maxLevel'] : ['revoke', 'unlink-character'].includes(command) ? ['guid']
    : command === 'link-character' ? ['guid', 'region', 'namespace', 'realmSlug', 'characterName', 'realmId', 'characterId']
      : command === 'dataset-export' ? ['maxLevel', 'dataCutoff', 'out'] : command === 'analysis-publish' ? ['file']
        : command === 'model-activate' ? ['approve', 'file', 'effectiveFrom'] : [];
  if (Object.keys(flags).some((key) => !allowed.includes(key))) throw new Error(usage);
  if (command === 'provision') {
    const token = store.provision({ guid: flags.guid, name: flags.name, realm: flags.realm, classFile: flags.classFile, level: Number(flags.level), maxLevel: Number(flags.maxLevel) });
    output(token);
  } else if (command === 'revoke') { output(JSON.stringify({ guid: flags.guid, revoked: store.revoke(flags.guid) > 0 })); }
  else if (command === 'link-character') {
    const mapping = store.linkCharacter({ guid: flags.guid, region: flags.region, namespace: flags.namespace, realmSlug: flags.realmSlug,
      characterName: flags.characterName, ...(flags.realmId === undefined ? {} : { realmId: Number(flags.realmId) }),
      ...(flags.characterId === undefined ? {} : { characterId: Number(flags.characterId) }) });
    output(JSON.stringify({ linked: true, mapping }));
  } else if (command === 'unlink-character') output(JSON.stringify({ guid: flags.guid, unlinked: store.unlinkCharacter(flags.guid) > 0 }));
  else if (command === 'stats') output(JSON.stringify(store.stats(), null, 2));
  else if (command === 'models') output(JSON.stringify(store.models(), null, 2));
  else if (command === 'audit') output(JSON.stringify({ rulesetId: store.rulesetId, ...store.models().audit }, null, 2));
  else if (command === 'dataset-export') {
    if (!flags.out) throw new Error('--out is required for the offline dataset');
    const dataset = store.exportDataset({ ...(flags.maxLevel === undefined ? {} : { maxLevel: Number(flags.maxLevel) }), ...(flags.dataCutoff === undefined ? {} : { dataCutoff: Number(flags.dataCutoff) }) });
    writeFileSync(resolve(flags.out), `${JSON.stringify(dataset, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
    output(JSON.stringify({ file: resolve(flags.out), datasetHash: dataset.datasetHash, matches: dataset.matches.length, dataCutoff: dataset.dataCutoff }));
  } else if (command === 'analysis-publish') output(JSON.stringify(store.publishAnalysis(readJSON(flags.file))));
  else if (command === 'model-activate') output(JSON.stringify(store.activateModel(readJSON(flags.file), { approve: flags.approve, effectiveFrom: Number(flags.effectiveFrom) })));
  else throw new Error(usage);
}
function readJSON(path) {
  if (!path) throw new Error('--file is required');
  const content = readFileSync(resolve(path));
  if (content.length > 2 * 1024 * 1024) throw new Error('Administrator JSON file exceeds 2 MiB');
  return JSON.parse(content.toString('utf8'));
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (['--help', '-h'].includes(process.argv[2])) console.log(usage);
  else {
    let store;
    try {
      const path = resolve(process.env.DB_PATH || resolve(dirname(fileURLToPath(import.meta.url)), '../data/foreverduel.sqlite'));
      store = createStore({ path }); manage(process.argv.slice(2), { store });
    } catch (error) { console.error(error.message); process.exitCode = 1; }
    finally { store?.close(); }
  }
}
