import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

const [apk, aapt2] = process.argv.slice(2);
assert(apk && aapt2, 'Usage: node scripts/check-android-backup-package.mjs APK AAPT2');
function dump(...args) {
  const result = spawnSync(aapt2, ['dump', ...args, apk], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  assert.equal(result.status, 0, 'Packaged Android resource inspection failed');
  return result.stdout;
}
function xml(path) {
  const result = spawnSync(aapt2, ['dump', 'xmltree', apk, '--file', path], { encoding: 'utf8' });
  assert.equal(result.status, 0, 'Required packaged XML resource is unavailable');
  const root = { name: 'document', attributes: {}, children: [], indent: -1 };
  const stack = [root];
  for (const line of result.stdout.split('\n')) {
    const element = /^(\s*)E: ([^ (]+)/.exec(line);
    if (element) {
      const node = { name: element[2], attributes: {}, children: [], indent: element[1].length };
      while (stack.at(-1).indent >= node.indent) stack.pop();
      stack.at(-1).children.push(node);
      stack.push(node);
    } else {
      const attribute = /^\s*A: (.+?)=(.*)$/.exec(line);
      if (!attribute) continue;
      const name = attribute[1].split(':').at(-1).replace(/\(.*/, '');
      const value = attribute[2].startsWith('"') ? JSON.parse(/^"(?:[^"\\]|\\.)*"/.exec(attribute[2])[0]) : attribute[2];
      stack.at(-1).attributes[name] = value;
    }
  }
  return root.children[0];
}
const manifest = xml('AndroidManifest.xml');
const application = manifest.children.find((node) => node.name === 'application');
assert.equal(application.attributes.allowBackup, 'false');
const resources = dump('resources');
for (const [field, name] of [['fullBackupContent', 'backup_rules'], ['dataExtractionRules', 'data_extraction_rules']]) {
  const reference = application.attributes[field];
  assert(/^@0x[0-9a-f]+$/.test(reference), `${field} must reference packaged exclusions`);
  assert(resources.includes(`resource ${reference.slice(1)} xml/${name}`), `${field} references the wrong resource`);
}
const domains = ['root', 'file', 'database', 'sharedpref', 'external', 'device_root', 'device_file', 'device_database', 'device_sharedpref'].sort();
function exclusions(node) {
  assert.deepEqual(node.children.map((child) => child.name), Array(9).fill('exclude'));
  assert.deepEqual(node.children.map((child) => child.attributes.domain).sort(), domains);
  assert(node.children.every((child) => child.attributes.path === '.'));
}
const legacy = xml('res/xml/backup_rules.xml');
assert.equal(legacy.name, 'full-backup-content');
exclusions(legacy);
const modern = xml('res/xml/data_extraction_rules.xml');
assert.equal(modern.name, 'data-extraction-rules');
assert.deepEqual(modern.children.map((child) => child.name).sort(), ['cloud-backup', 'device-transfer']);
modern.children.forEach(exclusions);
const digest = createHash('sha256').update(readFileSync(apk)).digest('hex');
console.log(`PASS: packaged backup disabled; all 9 domains excluded for legacy, cloud and device transfer; APK SHA-256 ${digest}`);
