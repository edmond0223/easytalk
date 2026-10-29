// Run: node tests/test_frontend_logic.js
const assert = require('assert');
const { buildUtterances, plainText, renderParts, markNumbers, parseTerms, tidyCjk } = require('../static/app.js');

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

// 2. Two segments translated in ONE run: split by sentence count (lecture bug).
u = buildUtterances([
  O('Considered various topics, and who is Big X?', '1'), T('<end>'),
  O('And where does he get off?', '1'), T('<end>'),
  Z('我考虑过各种话题，'), Z('还有谁是 Big X？'),
  Z('他凭什么'), Z('退出？'),
  O('But does it really matter?', '1'), T('<end>'),
  Z('但这真的重要吗？'),
]);
assert.strictEqual(plainText(u[0].zh), '我考虑过各种话题，还有谁是 Big X？');
assert.strictEqual(plainText(u[1].zh), '他凭什么退出？');
assert.strictEqual(plainText(u[2].zh), '但这真的重要吗？');
// An utterance with two sentences keeps both translated sentences.
u = buildUtterances([
  O('Hi. How are you?', '1'), T('<end>'), O('Fine.', '2'), T('<end>'),
  Z('你好。'), Z('你好吗？'), Z('很好。'),
]);
assert.strictEqual(plainText(u[0].zh), '你好。你好吗？');
assert.strictEqual(plainText(u[1].zh), '很好。');
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

// 6. Apostrophes are escaped once and never highlighted as numbers.
assert.strictEqual(markNumbers("That's fine"), 'That&#39;s fine');
assert.strictEqual(renderParts([{ text: "I'd like 2", final: true }]), 'I&#39;d like <mark>2</mark>');
assert.strictEqual(markNumbers('<b>5</b>'), '&lt;b&gt;<mark>5</mark>&lt;/b&gt;');

// 7. Word list parsing.
const parsed = parseTerms('due on Monday\n\n  night shift \n# comment\nOHIP = 安省医保\nMRI＝核磁共振\nDue on Monday\n');
assert.deepStrictEqual(parsed.terms, ['due on Monday', 'night shift', 'OHIP', 'MRI']);
assert.deepStrictEqual(parsed.translationTerms, [
  { source: 'OHIP', target: '安省医保' }, { source: 'MRI', target: '核磁共振' }]);
assert.deepStrictEqual(parseTerms(''), { terms: [], translationTerms: [] });

// 8. Chinese spacing tidy-up, English kept intact.
assert.strictEqual(tidyCjk('出来， 而且显然 是AI生成的'), '出来，而且显然是AI生成的');
assert.strictEqual(tidyCjk('ChatGPT 是 在说英语'), 'ChatGPT 是在说英语');
assert.strictEqual(renderParts([{ text: '出来，', final: true }, { text: ' 而且', final: true }], { cjk: true }), '出来，而且');

console.log('frontend logic: all tests passed');

// 9. Languages: spoken / translated language voted per utterance.
{
  const { countSentences, langPair } = require('../static/app.js');
  const L = (text, speaker, lang, extra = {}) => ({ text, is_final: true, speaker, translation_status: 'original', language: lang, ...extra });
  const Tr = (text, lang) => ({ text, is_final: true, translation_status: 'translation', language: lang });
  const u2 = buildUtterances([
    L('我熬夜了，', '1', 'zh'), L('所以有黑眼圈。', '1', 'zh'), Tr('I stayed up late, so I have dark circles.', 'en'),
    { text: '<end>', is_final: true },
    L('Vous restez ce soir ?', '2', 'fr'), Tr('你今晚留下吗？', 'zh'),
  ]);
  assert.strictEqual(u2[0].lang, 'zh');
  assert.strictEqual(u2[0].transLang, 'en');
  assert.strictEqual(u2[1].lang, 'fr');
  assert.strictEqual(u2[1].transLang, 'zh');
  assert.strictEqual(countSentences('Vous restez ce soir ? Oui.'), 2);
  assert.strictEqual(countSentences('你好。你好吗？'), 2);
  assert.deepStrictEqual(langPair('zh', 'zh'), ['zh', 'en']);
  assert.deepStrictEqual(langPair('en', 'en'), ['en', 'zh']);
  assert.deepStrictEqual(langPair('xx', 'fr'), ['zh', 'fr']);
  console.log('language logic: all tests passed');
}
