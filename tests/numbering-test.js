// Pulls the desktop numbering functions out of MissionControl.qml and checks them.
// Run: node tests/numbering-test.js MissionControl.qml
const src = require('fs').readFileSync(process.argv[2], 'utf8');
const grab = name => { const i = src.indexOf('function ' + name + '('); let d = 0, j = src.indexOf('{', i);
  for (let k = j; ; k++) { if (src[k] === '{') d++; else if (src[k] === '}' && --d === 0) return src.slice(i, k + 1); } };
const root = { workspaceRules: [] };
const panel = { ruleIds: [], block: -1 };
eval(['parseWorkspaceRules','ruleIdsFor','parseBlocks','nextDesktopId','deskLabel'].map(grab).join('\n'));
const assert = require('assert');
// rules: hyprmoncfg-style, by name and by desc; layout-only rules are ignored
root.workspaceRules = parseWorkspaceRules(JSON.stringify([
  { workspaceString: 'special:qconsole', monitor: null },
  { workspaceString: '1', monitor: 'desc:Tianma TL134' }, { workspaceString: '3', monitor: 'desc:Tianma TL134' },
  { workspaceString: '2', monitor: 'desc:Tianma TL134' }, { workspaceString: '5', monitor: 'DP-1' },
  { workspaceString: '4', monitor: 'DP-1' }, { workspaceString: '7', layout: 'scrolling' }]));
assert.deepStrictEqual(ruleIdsFor({ name: 'eDP-1', description: 'Tianma TL134 serial' }), [1, 2, 3]);
assert.deepStrictEqual(ruleIdsFor({ name: 'DP-1', lastIpcObject: { description: 'X' } }), [4, 5]);
assert.deepStrictEqual(ruleIdsFor({ name: 'HDMI-A-1' }), []);
assert.deepStrictEqual(parseWorkspaceRules('not json'), []);
// blocks file: empty connector lines skipped
assert.deepStrictEqual(parseBlocks('0\teDP-1\tA\n1\tDP-1\tB\n2\t\tC\n'), { 'eDP-1': 0, 'DP-1': 1 });
// model 1: + takes a free rule id, then falls back to max + 1
panel.ruleIds = [4, 5, 6]; panel.block = -1;
assert.strictEqual(nextDesktopId({ 4: true, 5: true }, 24), 6);
assert.strictEqual(nextDesktopId({ 4: true, 5: true, 6: true }, 24), 25);
assert.strictEqual(deskLabel({ name: '4' }, 4), '4');
// model 2: second monitor, block 1 -> 11..20 shown 1..10; full block gives none
panel.ruleIds = []; panel.block = 1;
assert.strictEqual(deskLabel({ name: '11' }, 11), '1');
assert.strictEqual(deskLabel({ name: '20' }, 20), '10');
assert.strictEqual(deskLabel({ name: '24' }, 24), '24');      // outside the block: real id
assert.strictEqual(deskLabel({ name: 'mail' }, 12), 'mail');  // a user's name wins
assert.strictEqual(nextDesktopId({ 11: true, 12: true, 31: true }, 31), 13);
const full = {}; for (let i = 11; i <= 20; i++) full[i] = true;
assert.strictEqual(nextDesktopId(full, 20), -1);
// model 3: plain
panel.block = -1;
assert.strictEqual(deskLabel(null, 7), '7');
assert.strictEqual(nextDesktopId({ 1: true, 2: true }, 2), 3);
console.log('ok');
