'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {publicIPv4, prepare, verify} = require('./logic');
const config = {account_id: 'a'.repeat(32), group_id: '11111111-1111-1111-1111-111111111111', group_name: 'homelab-dynamic-home-ip', dry_run: true};
const group = () => ({success: true, result: {id: config.group_id, name: config.group_name, include: [{ip: {ip: '8.8.8.8/32'}}], exclude: [], require: []}});

test('dry run detects changes without permitting a write', () => {
  const p = prepare(config, '1.1.1.1', '1.1.1.1\n', group());
  assert.equal(p.changed, true); assert.equal(p.should_update, false);
});
test('unchanged address never permits a write', () => assert.equal(prepare({...config, dry_run: false}, '8.8.8.8', '8.8.8.8', group()).should_update, false));
test('explicit live mode creates a one-IP payload', () => {
  const p = prepare({...config, dry_run: false}, '1.1.1.1', '1.1.1.1', group());
  assert.equal(p.should_update, true); assert.deepEqual(p.payload.include, [{ip: {ip: '1.1.1.1/32'}}]);
});
test('disagreement, private, reserved, and malformed addresses fail closed', () => {
  assert.throws(() => prepare(config, '1.1.1.1', '8.8.8.8', group()));
  for (const ip of ['10.0.0.1','100.64.0.1','127.0.0.1','192.0.2.1','203.0.113.1','224.0.0.1','::1','8.8.8.8/0','08.8.8.8','1.1.1.256']) assert.throws(() => publicIPv4(ip));
});
test('shared or foreign selectors and group IDs are rejected', () => {
  for (const mutate of [g => g.result.id = 'other', g => g.result.name = 'existing-shared-group',
    g => g.result.require.push({everyone: {}}), g => g.result.exclude.push({everyone: {}}),
    g => g.result.include.push({everyone: {}}), g => g.result.include[0].ip.ip = '8.8.8.0/24',
    g => g.result.is_default = true, g => g.success = false]) {
    const g = group(); mutate(g); assert.throws(() => prepare(config, '1.1.1.1', '1.1.1.1', g));
  }
});
test('read-back verifies the expected IP', () => {
  assert.deepEqual(verify(config, {expected_ip:'8.8.8.8'}, group()), {updated:true,verified:true});
  assert.throws(() => verify(config, {expected_ip:'1.1.1.1'}, group()));
});
test('import starts inactive, dry-run, with no credential or object IDs', () => {
  const w = JSON.parse(fs.readFileSync(__dirname + '/workflow.json'));
  assert.equal(w.active, false);
  const configNode = w.nodes.find(n => n.name === 'Config');
  const c = vm.runInNewContext('(function(){'+configNode.parameters.jsCode+'})()')[0].json;
  assert.equal(c.dry_run, true); assert.equal(c.account_id, ''); assert.equal(c.group_id, '');
  assert.equal(w.nodes.filter(n=>n.parameters.method === 'PUT').length, 1);
  const update = w.nodes.find(n=>n.parameters.method === 'PUT');
  assert.equal(update.name, 'Update dedicated group');
  assert.deepEqual(w.connections['Write permitted'].main[0][0].node, update.name);
  assert.equal(w.settings.saveManualExecutions, false);
});
