// Run: node tests/test_frontend_logic.js
const assert = require('assert');
const { buildUtterances, plainText, renderParts, markNumbers } = require('../static/app.js');

const T = (text, extra = {}) => ({ text, is_final: true, ...extra });
const O = (text, speaker, extra = {}) => T(text, { speaker, translation_status: 'original', ...extra });
const Z = (text, extra = {}) => T(text, { translation_status: 'translation', language: 'zh', ...extra });

// 1. Two speakers, each with its own translation.
let u = buildUtterances([
  O('Could', '1'), O(' you', '1'), O(' move', '1'), O(' these?', '1'),
  Z('你能'), Z('搬这些吗？'),
  T('<end>'),
  O('Sure.', '2'), Z('当然。'), T('<end>'),
]);
assert.strictEqual(u.length, 2);
assert.strictEqual(plainText(u[0].en), 'Could you move these?');
assert.strictEqual(plainText(u[0].zh), '你能搬这些吗？');
assert.strictEqual(u[0].speaker, '1');
assert.ok(u[0].ended);
assert.strictEqual(plainText(u[1].en), 'Sure.');
assert.strictEqual(plainText(u[1].zh), '当然。');

// 2. Speaker switches before the first translation arrives:
//    translation goes to the oldest untranslated utterance.
u = buildUtterances([
  O('Can you stay late?', '1'),
  O('Maybe.', '2'),
  Z('你能晚点走吗？'),
  Z('也许。'), // same run -> also goes to the first; acceptable limitation
]);
assert.strictEqual(plainText(u[0].zh), '你能晚点走吗？也许。');
// a later separate run goes to the next pending utterance
u = buildUtterances([
  O('Can you stay late?', '1'), Z('你能晚点走吗？'),
  O('Maybe.', '2'), O(' I', '2'), Z('也许。'),
]);
assert.strictEqual(plainText(u[0].zh), '你能晚点走吗？');
assert.strictEqual(plainText(u[1].zh), '也许。');

// 3. Same speaker after <end> starts a new utterance.
u = buildUtterances([O('Hi.', '1'), T('<end>'), O('Are you there?', '1')]);
assert.strictEqual(u.length, 2);

// 4. Non-final tokens without speaker stay with the current utterance.
u = buildUtterances([O('Hello', '1'), { text: ' there', is_final: false, translation_status: 'original' }]);
assert.strictEqual(u.length, 1);
assert.strictEqual(plainText(u[0].en), 'Hello there');

// 5. Rendering: pending marked, unsure marked, numbers highlighted, HTML escaped.
const html = renderParts([
  { text: 'Aisle', final: true, conf: 0.99 },
  { text: ' 5', final: true, conf: 0.4 },
  { text: ' <b>', final: false },
], { unsure: true });
assert.ok(html.includes('<span class="unsure"><mark>5</mark></span>'), html);
assert.ok(html.includes('<span class="pending"> &lt;b&gt;</span>'), html);
assert.strictEqual(markNumbers('at 6:30 pm'), 'at <mark>6:30 pm</mark>');
assert.strictEqual(markNumbers('六点半 18点'), '六点半 <mark>18点</mark>');

console.log('frontend logic: all tests passed');
