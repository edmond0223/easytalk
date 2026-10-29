'use strict';
/* EasyTalk phase 1 — phone page.
 * Mic → AudioWorklet (16-bit PCM) → Soniox WebSocket (temporary key from our server).
 * Soniox returns English tokens with speaker labels plus Chinese translation tokens.
 * When the other person finishes a turn (<end> token), we ask our server for
 * reply suggestions (ChatGPT plan). Nothing is stored; reload clears everything.
 */

const SONIOX_WS = 'wss://stt-rt.soniox.com/transcribe-websocket';
const UNSURE_CONFIDENCE = 0.55;
const MAX_RECONNECTS = 3;

const SCENE_DOMAIN = {
  work: 'Supermarket job in Canada: supervisor, coworkers, customers, aisles, shifts, breaks',
  hospital: 'Clinic, hospital or pharmacy in Canada: symptoms, appointments, medication, OHIP',
  school: "Parent talking with the child's school teacher or staff in Canada",
  shop: 'Shopping in Canada: prices, sizes, receipts, returns, exchanges',
  phone: 'Phone call with a company or office in Canada',
  daily: 'Everyday small talk in Canada',
};

const PHRASES = [
  ['请再说一遍', 'Sorry, could you say that again?'],
  ['请说慢一点', 'Could you speak a little slower, please?'],
  ['让我想一下', 'Let me think for a second.'],
  ['说简单一点', "Sorry, my English isn't great. Could you say it more simply?"],
  ['能写下来吗', 'Could you write that down for me, please?'],
  ['我明白了', 'Okay, I understand. Thank you.'],
];

/* ------------------------------------------------------------------ pure logic */

// Sentence ends, used to line translations up with their originals.
function countSentences(text, zh) {
  const re = zh ? /[。？！?!…]+/g : /[.?!…]+(?=\s|$|["')\]])/g;
  return (String(text).match(re) || []).length;
}

// Group tokens into utterances: consecutive original tokens of one speaker,
// split at <end>. Translation tokens fill the oldest utterance whose originals
// are not translated yet; once its Chinese has as many sentences as its
// English, the rest of the run moves on to the next waiting utterance
// (Soniox sometimes sends two segments' translations in one run).
function buildUtterances(tokens) {
  const utts = [];
  let cur = null;          // utterance receiving original tokens
  let pending = [];        // utterances with untranslated originals
  let transTarget = null;  // utterance receiving the current translation run
  let inTrans = false;
  const textOf = (parts) => parts.map((p) => p.text).join('');
  const translated = (u) => u.ended && u.zh.length > 0
    && countSentences(textOf(u.zh), true) >= Math.max(1, countSentences(textOf(u.en), false));

  for (const tok of tokens) {
    const text = tok.text || '';
    if (tok.translation_status === 'translation') {
      if (!inTrans) {
        inTrans = true;
        transTarget = pending[0] || cur || utts[utts.length - 1] || null;
        if (!transTarget) {
          transTarget = newUtt(tok.speaker || '?');
          utts.push(transTarget);
        }
      } else if (translated(transTarget)) {
        const i = pending.indexOf(transTarget);
        const next = pending[i + 1];
        if (next && /^\s*\S/.test(text)) {
          pending.splice(i, 1);
          transTarget = next;
        }
      }
      transTarget.zh.push({ text, final: !!tok.is_final });
      continue;
    }
    if (inTrans) {
      inTrans = false;
      const i = pending.indexOf(transTarget);
      if (i >= 0) pending.splice(i, 1);
    }
    if (text === '<end>') {
      if (cur) { cur.ended = true; cur.endFinal = !!tok.is_final; }
      cur = null;
      continue;
    }
    if (text === '<fin>') continue;
    const speaker = tok.speaker || (cur ? cur.speaker : '?');
    if (!cur || cur.speaker !== speaker) {
      cur = newUtt(speaker);
      utts.push(cur);
    }
    cur.en.push({ text, final: !!tok.is_final, conf: tok.confidence });
    if (tok.translation_status === 'original' && !pending.includes(cur)) pending.push(cur);
  }
  return utts;
}

// Parse the user's word list: one per line; "English = 中文" also fixes the translation.
const MAX_TERMS = 150;
function parseTerms(text) {
  const terms = [];
  const translationTerms = [];
  const seen = new Set();
  for (const raw of String(text || '').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const m = line.match(/^(.+?)\s*[=＝]\s*(.+)$/);
    const source = (m ? m[1] : line).trim().slice(0, 80);
    if (!source || seen.has(source.toLowerCase())) continue;
    seen.add(source.toLowerCase());
    terms.push(source);
    if (m) translationTerms.push({ source, target: m[2].trim().slice(0, 80) });
    if (terms.length >= MAX_TERMS) break;
  }
  return { terms, translationTerms };
}

function newUtt(speaker) {
  return { speaker, en: [], zh: [], ended: false, endFinal: false };
}

function plainText(parts) {
  return parts.map((p) => p.text).join('').replace(/\s+/g, ' ').trim();
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// Escape raw text and highlight numbers, times and amounts.
// Numbers are found in the raw text first, so HTML entities such as &#39;
// (from apostrophes) are never touched.
const NUMBER_RE = /(\$?\d[\d:.,/%]*(?:\s?(?:am|pm|AM|PM|点|号|元|块))?)/;
function markNumbers(raw) {
  return raw.split(NUMBER_RE)
    .map((part, i) => (i % 2 ? `<mark>${escapeHtml(part)}</mark>` : escapeHtml(part)))
    .join('');
}

// Soniox puts spaces between Chinese clauses ("出来， 而且"); drop spaces
// that sit between Chinese characters or after Chinese punctuation.
const CJK_SPACE_RE = /([\u3000-\u303f\uff00-\uffef\u4e00-\u9fff])\s+(?=[\u3000-\u303f\uff00-\uffef\u4e00-\u9fff“‘（《])/g;
function tidyCjk(text) {
  return text.replace(CJK_SPACE_RE, '$1');
}

function renderParts(parts, { unsure = false, cjk = false } = {}) {
  if (cjk) {
    // Tidy across token boundaries: join, then keep each token's pending flag.
    parts = parts.map((p, i) => {
      const next = parts[i + 1];
      let text = p.text;
      if (next && /^\s+$/.test(text) === false && /\s+$/.test(text) && /^[\u4e00-\u9fff“（《]/.test(next.text.trimStart())
          && /[\u3000-\u303f\uff00-\uffef\u4e00-\u9fff]\s+$/.test(text)) text = text.trimEnd();
      if (i > 0 && /^\s+/.test(text) && /[\u3000-\u303f\uff00-\uffef\u4e00-\u9fff]$/.test(parts[i - 1].text.trimEnd())
          && /^\s+[\u4e00-\u9fff“（《]/.test(text)) text = text.trimStart();
      return { ...p, text: tidyCjk(text) };
    });
  }
  let html = '';
  let run = '';
  let runPending = null;
  const flush = () => {
    if (!run) return;
    const body = markNumbers(run);
    html += runPending ? `<span class="pending">${body}</span>` : body;
    run = '';
  };
  for (const p of parts) {
    const isPending = !p.final;
    const isUnsure = unsure && p.final && typeof p.conf === 'number' && p.conf < UNSURE_CONFIDENCE && p.text.trim();
    if (isUnsure) {
      flush();
      const body = markNumbers(p.text);
      const lead = body.match(/^\s*/)[0];
      html += `${lead}<span class="unsure">${body.slice(lead.length)}</span>`;
      runPending = null;
      continue;
    }
    if (runPending !== null && runPending !== isPending) flush();
    runPending = isPending;
    run += p.text;
  }
  flush();
  return html.trim();
}

if (typeof module !== 'undefined') {
  module.exports = { buildUtterances, plainText, renderParts, markNumbers, escapeHtml, parseTerms, tidyCjk };
}

/* ------------------------------------------------------------------ app */

if (typeof document !== 'undefined') {
  const $ = (id) => document.getElementById(id);
  const store = {
    get(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : v; } catch { return d; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode */ } },
  };

  const state = {
    finals: [],
    nonFinals: [],
    me: new Set(),          // speaker keys marked as the user
    names: new Map(),       // speaker key -> 对方 N
    running: false,
    stopping: false,
    session: 0,
    reconnects: 0,
    ws: null,
    queue: [],
    audio: null,
    wakeLock: null,
    startedAt: 0,
    timer: null,
    suggestAbort: null,
    lastSuggestedKey: '',
    endCount: 0,
    mode: store.get('et-mode', 'chat') === 'lecture' ? 'lecture' : 'chat',
    topic: store.get('et-topic', ''),
    termsText: store.get('et-terms', ''),
    fontSize: Math.min(40, Math.max(18, Number(store.get('et-font', 24)) || 24)),
  };

  /* ---------- UI helpers ---------- */

  let toastTimer = null;
  function toast(msg, ms = 3500) {
    const el = $('toast');
    el.textContent = msg;
    el.classList.remove('hidden');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.add('hidden'), ms);
  }

  function setStatus(text, cls = '') {
    $('status-text').textContent = text;
    $('status').className = 'status ' + cls;
  }

  function speakerName(key) {
    if (state.me.has(key)) return '我';
    if (!state.names.has(key)) state.names.set(key, state.names.size + 1);
    const n = state.names.get(key);
    if (state.mode === 'lecture') return `发言人 ${n}`;
    return state.names.size === 1 ? '对方' : `对方 ${n}`;
  }

  /* ---------- auth ---------- */

  async function api(path, opts = {}) {
    const res = await fetch(path, { credentials: 'same-origin', ...opts });
    if (res.status === 401) { showLogin(); throw new Error('请先输入访问口令'); }
    return res;
  }

  function showLogin() {
    $('app').classList.add('hidden');
    $('login').classList.remove('hidden');
    $('passcode').focus();
  }

  function showApp() {
    $('login').classList.add('hidden');
    $('app').classList.remove('hidden');
  }

  $('login-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    $('login-error').textContent = '';
    const res = await fetch('/api/login', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ passcode: $('passcode').value }),
    });
    if (res.ok) { $('passcode').value = ''; showApp(); return; }
    const data = await res.json().catch(() => ({}));
    $('login-error').textContent = data.detail || '登录失败';
  });

  /* ---------- transcript rendering ---------- */

  let renderQueued = false;
  function scheduleRender() {
    if (renderQueued) return;
    renderQueued = true;
    requestAnimationFrame(() => { renderQueued = false; render(); });
  }

  function render() {
    const box = $('transcript');
    const nearBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 120;
    const utts = buildUtterances(state.finals.concat(state.nonFinals));
    $('empty-hint').classList.toggle('hidden', utts.length > 0);
    const lecture = state.mode === 'lecture';
    const shown = utts.slice(lecture ? -300 : -60);
    let html = '';
    if (lecture) {
      const speakers = new Set(utts.map((u) => u.speaker));
      for (const u of shown) {
        const en = renderParts(u.en);
        const zh = renderParts(u.zh, { cjk: true });
        if (!en && !zh) continue;
        const who = speakers.size > 1 ? `<div class="who">${escapeHtml(speakerName(u.speaker))}</div>` : '';
        html += `<div class="para">${who}<div class="zh">${zh}</div><div class="en">${en}</div></div>`;
      }
    }
    for (const u of lecture ? [] : shown) {
      const isMe = state.me.has(u.speaker);
      const en = renderParts(u.en, { unsure: !isMe });
      const zh = renderParts(u.zh, { cjk: true });
      if (!en && !zh) continue;
      html += `<div class="utt ${isMe ? 'me' : 'them'}">`
        + `<button class="tag" data-speaker="${escapeHtml(u.speaker)}">${escapeHtml(speakerName(u.speaker))}${isMe ? ' · 不是我' : ' · 这是我?'}</button>`
        + `<div class="en">${en}</div><div class="zh">${zh}</div></div>`;
    }
    let list = box.querySelector('.list');
    if (!list) { list = document.createElement('div'); list.className = 'list'; box.appendChild(list); }
    list.innerHTML = html;
    if (nearBottom) box.scrollTop = box.scrollHeight;
    $('jump').classList.toggle('hidden', nearBottom || !utts.length);
  }

  $('transcript').addEventListener('scroll', () => {
    const box = $('transcript');
    if (box.scrollHeight - box.scrollTop - box.clientHeight < 120) $('jump').classList.add('hidden');
  }, { passive: true });
  $('jump').addEventListener('click', () => {
    const box = $('transcript');
    box.scrollTop = box.scrollHeight;
    $('jump').classList.add('hidden');
  });

  $('transcript').addEventListener('click', (e) => {
    const btn = e.target.closest('.tag');
    if (!btn) return;
    const key = btn.dataset.speaker;
    if (state.me.has(key)) state.me.delete(key); else state.me.add(key);
    toast(state.me.has(key) ? '已标为「我」' : '已改回「对方」', 1500);
    render();
  });

  /* ---------- suggestions ---------- */

  function conversationTurns() {
    const utts = buildUtterances(state.finals.concat(state.nonFinals));
    return utts
      .map((u) => ({ who: state.me.has(u.speaker) ? 'me' : 'them', text: plainText(u.en), speaker: u.speaker }))
      .filter((t) => t.text)
      .slice(-12);
  }

  function maybeSuggest() {
    if (state.mode === 'lecture') return;
    const turns = conversationTurns();
    if (!turns.length) return;
    const last = turns[turns.length - 1];
    if (last.who === 'me') return;
    if (last.text.split(/\s+/).length < 2) return;
    const key = `${turns.length}|${last.text}`;
    if (key === state.lastSuggestedKey) return;
    state.lastSuggestedKey = key;
    requestSuggestions(turns);
  }

  async function requestSuggestions(turns) {
    if (state.suggestAbort) state.suggestAbort.abort();
    const ctrl = new AbortController();
    state.suggestAbort = ctrl;
    const list = $('suggest-list');
    $('suggest').classList.remove('hidden');
    $('suggest-meta').textContent = '思考中…';
    list.innerHTML = '<div class="sug skeleton"><div class="en">…</div></div>';
    let got = 0;
    try {
      const res = await api('/api/suggest', {
        method: 'POST', signal: ctrl.signal,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ scene: $('scene').value, turns: turns.map(({ who, text }) => ({ who, text })) }),
      });
      if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`);
      const reader = res.body.getReader();
      const dec = new TextDecoder();
      let buf = '';
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let i;
        while ((i = buf.indexOf('\n\n')) >= 0) {
          const chunk = buf.slice(0, i);
          buf = buf.slice(i + 2);
          if (!chunk.startsWith('data:')) continue;
          const ev = JSON.parse(chunk.slice(5));
          if (ev.type === 'suggestion') {
            if (got === 0) list.innerHTML = '';
            got += 1;
            const b = document.createElement('button');
            b.className = 'sug';
            b.dataset.en = ev.en;
            b.innerHTML = `<div class="en">${escapeHtml(ev.en)}</div><div class="zh">${escapeHtml(ev.zh || '')}</div>`;
            list.appendChild(b);
            if (got === 1) $('suggest-meta').textContent = `${(ev.ms / 1000).toFixed(1)}s`;
          } else if (ev.type === 'done') {
            $('suggest-meta').textContent = `${(ev.ms / 1000).toFixed(1)}s`;
          } else if (ev.type === 'error') {
            $('suggest-meta').textContent = '';
            list.innerHTML = `<div class="error">${escapeHtml(ev.message)}</div>`;
          }
        }
      }
    } catch (err) {
      if (err.name === 'AbortError') return;
      $('suggest-meta').textContent = '';
      list.innerHTML = `<div class="error">${escapeHtml('建议回复失败：' + err.message)}</div>`;
    }
  }

  $('suggest-list').addEventListener('click', (e) => {
    const b = e.target.closest('.sug');
    if (!b || !b.dataset.en) return;
    document.querySelectorAll('.sug.speaking').forEach((x) => x.classList.remove('speaking'));
    b.classList.add('speaking');
    speak(b.dataset.en, () => b.classList.remove('speaking'));
  });

  $('suggest-refresh').addEventListener('click', () => {
    const turns = conversationTurns();
    if (turns.length) { state.lastSuggestedKey = ''; requestSuggestions(turns); }
  });

  /* ---------- speech out ---------- */

  // Natural voice from Soniox TTS (via our server); the browser voice is the fallback.
  const player = new Audio();
  const ttsCache = new Map();
  let playerUnlocked = false;

  // iOS only lets audio play after a tap; play a tiny silent clip on the first one.
  function silentWavUrl() {
    const n = 800, buf = new ArrayBuffer(44 + n * 2), v = new DataView(buf);
    const w = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
    w(0, 'RIFF'); v.setUint32(4, 36 + n * 2, true); w(8, 'WAVE'); w(12, 'fmt ');
    v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
    v.setUint32(24, 8000, true); v.setUint32(28, 16000, true); v.setUint16(32, 2, true);
    v.setUint16(34, 16, true); w(36, 'data'); v.setUint32(40, n * 2, true);
    return URL.createObjectURL(new Blob([buf], { type: 'audio/wav' }));
  }
  document.addEventListener('pointerdown', () => {
    if (playerUnlocked) return;
    playerUnlocked = true;
    player.src = silentWavUrl();
    player.play().catch(() => { playerUnlocked = false; });
  }, true);

  async function speak(text, onEnd) {
    if ('speechSynthesis' in window) speechSynthesis.cancel();
    player.pause();
    try {
      let url = ttsCache.get(text);
      if (!url) {
        const res = await api('/api/tts', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ text }),
        });
        if (!res.ok) {
          const data = await res.json().catch(() => ({}));
          throw new Error(data.detail || `HTTP ${res.status}`);
        }
        url = URL.createObjectURL(await res.blob());
        ttsCache.set(text, url);
      }
      player.onended = onEnd || null;
      player.src = url;
      await player.play();
    } catch (err) {
      console.warn('Soniox TTS failed, using browser voice:', err);
      browserSpeak(text, onEnd);
    }
  }

  function browserSpeak(text, onEnd) {
    if (!('speechSynthesis' in window)) { toast('这个浏览器不支持朗读'); if (onEnd) onEnd(); return; }
    speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(text);
    const voices = speechSynthesis.getVoices();
    u.voice = voices.find((v) => v.lang === 'en-CA') || voices.find((v) => v.lang === 'en-US') || null;
    u.lang = u.voice ? u.voice.lang : 'en-US';
    u.rate = 0.95;
    if (onEnd) u.onend = onEnd;
    speechSynthesis.speak(u);
  }

  const phrases = $('phrases');
  for (const [zh, en] of PHRASES) {
    const b = document.createElement('button');
    b.textContent = zh;
    b.title = en;
    b.addEventListener('click', () => { speak(en); toast(en, 2500); });
    phrases.appendChild(b);
  }

  /* ---------- audio ---------- */

  // The AudioContext is created inside the tap handler (iOS only lets it run
  // when it is created during a user gesture), then handed in here.
  async function startAudio(ctx) {
    let stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: false, autoGainControl: true, channelCount: 1 },
      });
    } catch (err) {
      ctx.close().catch(() => {});
      throw err;
    }
    const v = document.querySelector('meta[name="asset-version"]')?.content || Date.now();
    await ctx.audioWorklet.addModule(`/static/pcm-worklet.js?v=${v}`);
    const src = ctx.createMediaStreamSource(stream);
    const node = new AudioWorkletNode(ctx, 'pcm-writer');
    const mute = ctx.createGain();
    mute.gain.value = 0;
    src.connect(node).connect(mute).connect(ctx.destination);
    node.port.onmessage = (e) => {
      const { pcm, peak } = e.data;
      $('level-bar').style.width = `${Math.min(100, Math.round(peak * 140))}%`;
      sendAudio(pcm);
    };
    if (ctx.state === 'suspended') await ctx.resume();
    state.audio = { stream, ctx, node };
    // The worklet downsamples to 16 kHz unless the device is already lower.
    return Math.min(ctx.sampleRate, 16000);
  }

  function stopAudio() {
    const a = state.audio;
    state.audio = null;
    if (!a) return;
    a.node.port.onmessage = null;
    a.stream.getTracks().forEach((t) => t.stop());
    a.ctx.close().catch(() => {});
    $('level-bar').style.width = '0';
  }

  function sendAudio(buf) {
    const ws = state.ws;
    if (ws && ws.readyState === WebSocket.OPEN && ws.configured) {
      ws.send(buf);
    } else if (state.running && state.queue.length < 300) {
      state.queue.push(buf);
    }
  }

  /* ---------- Soniox session ---------- */

  async function openSession(sampleRate) {
    state.session += 1;
    const sessionNo = state.session;
    const res = await api('/api/soniox-key', { method: 'POST' });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);

    const ws = new WebSocket(SONIOX_WS, ['soniox-api-key', data.api_key]);
    ws.binaryType = 'arraybuffer';
    ws.configured = false;
    state.ws = ws;

    ws.onopen = () => {
      const scene = $('scene').value;
      const general = state.mode === 'lecture'
        ? [{ key: 'domain', value: 'Meeting, lecture or presentation' },
           ...(state.topic ? [{ key: 'topic', value: state.topic }] : [])]
        : [{ key: 'domain', value: SCENE_DOMAIN[scene] || SCENE_DOMAIN.daily }];
      ws.send(JSON.stringify({
        model: 'stt-rt-v5',
        audio_format: 'pcm_s16le',
        sample_rate: sampleRate,
        num_channels: 1,
        language_hints: ['en'],
        enable_speaker_diarization: true,
        enable_endpoint_detection: true,
        max_endpoint_delay_ms: 1500,
        // Lectures run on with short pauses; ask for endpoints more readily
        // so captions break into readable paragraphs.
        ...(state.mode === 'lecture' ? { endpoint_latency_adjustment_level: 1, endpoint_sensitivity: 0.5 } : {}),
        translation: { type: 'one_way', target_language: 'zh' },
        context: (() => {
          const { terms, translationTerms } = parseTerms(state.termsText);
          const ctx = { general: [...general, { key: 'location', value: 'Mississauga, Ontario, Canada' }] };
          if (terms.length) ctx.terms = terms;
          if (translationTerms.length) ctx.translation_terms = translationTerms;
          return ctx;
        })(),
      }));
      ws.configured = true;
      while (state.queue.length) ws.send(state.queue.shift());
      state.reconnects = 0;
      setStatus('正在听', 'live');
    };

    ws.onmessage = (e) => {
      let msg;
      try { msg = JSON.parse(e.data); } catch { return; }
      if (msg.error_code) {
        // Stop everything right away: mic off, socket closed, button back to 开始.
        ws.failed = true;
        const hint = msg.error_code === 402 ? '（Soniox 余额不足，请到控制台充值）' : '';
        toast(`Soniox 错误 ${msg.error_code}${hint}：${msg.error_message || msg.error_type}`, 8000);
        state.stopping = true;
        state.ws = null;
        try { ws.close(); } catch {}
        finishStop();
        setStatus('出错', 'err');
        return;
      }
      const nonFinals = [];
      let sawEnd = false;
      for (const t of msg.tokens || []) {
        if (!t.text) continue;
        const tok = { ...t, speaker: t.speaker ? `${sessionNo}:${t.speaker}` : undefined };
        if (t.is_final) {
          state.finals.push(tok);
          if (t.text === '<end>') sawEnd = true;
        } else {
          nonFinals.push(tok);
        }
      }
      state.nonFinals = nonFinals;
      scheduleRender();
      if (sawEnd) maybeSuggest();
      if (msg.finished) ws.close();
    };

    ws.onclose = () => {
      if (state.ws !== ws) return;
      state.ws = null;
      state.nonFinals = [];
      scheduleRender();
      if (state.running && !state.stopping) {
        if (!ws.failed && state.reconnects < MAX_RECONNECTS && state.audio) {
          state.reconnects += 1;
          setStatus('重新连接…', 'warn');
          openSession(Math.min(state.audio.ctx.sampleRate, 16000)).catch((err) => failStop(err));
        } else {
          failStop(new Error('连接断开了'));
        }
      } else {
        finishStop();
      }
    };
  }

  /* ---------- start / stop ---------- */

  async function start() {
    if (state.running) return;
    state.running = true;
    state.stopping = false;
    state.queue = [];
    $('toggle').textContent = '停止';
    $('toggle').classList.add('stop');
    setStatus('连接中…', 'warn');
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    ctx.resume().catch(() => {});
    try {
      const rate = await startAudio(ctx);
      await openSession(rate);
      await keepAwake();
      state.startedAt = Date.now();
    } catch (err) {
      failStop(err);
    }
  }

  function stop() {
    if (!state.running) return;
    state.stopping = true;
    setStatus('正在收尾…', 'warn');
    stopAudio();
    const ws = state.ws;
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send('');
      setTimeout(() => { if (state.ws === ws) ws.close(); }, 4000);
    } else {
      finishStop();
    }
  }

  function finishStop() {
    state.running = false;
    state.stopping = false;
    state.ws = null;
    stopAudio();
    releaseAwake();
    $('toggle').textContent = '开始';
    $('toggle').classList.remove('stop');
    if (!$('status').classList.contains('err')) setStatus('已停止');
  }

  function failStop(err) {
    toast(err.message.includes('Permission') || err.name === 'NotAllowedError'
      ? '没有麦克风权限：请在 Safari 设置里允许这个网站使用麦克风'
      : `出错了：${err.message}`, 6000);
    setStatus('出错', 'err');
    state.stopping = true;
    if (state.ws) { try { state.ws.close(); } catch {} }
    finishStop();
    setStatus('出错', 'err');
  }

  $('toggle').addEventListener('click', () => (state.running ? stop() : start()));

  $('clear').addEventListener('click', () => {
    if (!confirm('清空当前对话记录？')) return;
    state.finals = [];
    state.nonFinals = [];
    state.me.clear();
    state.names.clear();
    state.lastSuggestedKey = '';
    $('suggest').classList.add('hidden');
    $('suggest-list').innerHTML = '';
    render();
  });

  /* ---------- modes ---------- */

  function applyMode() {
    const lecture = state.mode === 'lecture';
    document.querySelectorAll('.modes button').forEach((b) => b.classList.toggle('on', b.dataset.mode === state.mode));
    $('transcript').classList.toggle('lecture', lecture);
    $('transcript').style.setProperty('--lecture-zh', `${state.fontSize}px`);
    $('scene').classList.toggle('hidden', lecture);
    $('topic').classList.toggle('hidden', !lecture);
    $('topic').textContent = state.topic ? state.topic : '主题';
    $('phrases').classList.toggle('hidden', lecture);
    $('lecture-bar').classList.toggle('hidden', !lecture);
    if (lecture) $('suggest').classList.add('hidden');
    else if ($('suggest-list').children.length) $('suggest').classList.remove('hidden');
    render();
  }

  document.querySelector('.modes').addEventListener('click', (e) => {
    const b = e.target.closest('button[data-mode]');
    if (!b || b.dataset.mode === state.mode) return;
    if (state.running) { toast('请先点「停止」再切换模式'); return; }
    state.mode = b.dataset.mode;
    store.set('et-mode', state.mode);
    applyMode();
  });

  $('topic').addEventListener('click', () => {
    const v = prompt('会议或演讲的主题（可选，英文或中文都行），例如：Q3 sales review、糖尿病讲座', state.topic);
    if (v === null) return;
    state.topic = v.trim().slice(0, 120);
    store.set('et-topic', state.topic);
    applyMode();
    if (state.running) toast('主题会在下次点「开始」时生效');
  });

  $('zh-only').addEventListener('click', () => {
    const on = $('transcript').classList.toggle('zh-only');
    $('zh-only').classList.toggle('on', on);
  });

  function setFont(delta) {
    state.fontSize = Math.min(40, Math.max(18, state.fontSize + delta));
    store.set('et-font', String(state.fontSize));
    $('transcript').style.setProperty('--lecture-zh', `${state.fontSize}px`);
  }
  $('font-up').addEventListener('click', () => setFont(2));
  $('font-down').addEventListener('click', () => setFont(-2));

  $('export').addEventListener('click', () => {
    const utts = buildUtterances(state.finals.concat(state.nonFinals));
    const speakers = new Set(utts.map((u) => u.speaker));
    const lines = [];
    for (const u of utts) {
      const en = plainText(u.en);
      const zh = plainText(u.zh);
      if (!en && !zh) continue;
      if (speakers.size > 1) lines.push(`【${speakerName(u.speaker)}】`);
      if (en) lines.push(en);
      if (zh) lines.push(zh);
      lines.push('');
    }
    if (!lines.length) { toast('还没有内容可以导出'); return; }
    const d = new Date();
    const pad = (n) => String(n).padStart(2, '0');
    const stamp = `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}`;
    const title = state.mode === 'lecture' && state.topic ? `主题：${state.topic}\n` : '';
    const blob = new Blob([`EasyTalk ${d.toLocaleString()}\n${title}\n${lines.join('\n')}`], { type: 'text/plain;charset=utf-8' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `EasyTalk-${stamp}.txt`;
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
  });

  /* ---------- word list ---------- */

  function updateTermsButton() {
    const n = parseTerms(state.termsText).terms.length;
    $('terms-btn').textContent = n ? `词表 ${n}` : '词表';
  }

  $('terms-btn').addEventListener('click', () => {
    $('terms-text').value = state.termsText;
    const dlg = $('terms-dialog');
    if (typeof dlg.showModal === 'function') dlg.showModal(); else dlg.setAttribute('open', '');
  });

  $('terms-dialog').addEventListener('close', () => {
    if ($('terms-dialog').returnValue !== 'save') return;
    state.termsText = $('terms-text').value;
    store.set('et-terms', state.termsText);
    updateTermsButton();
    const n = parseTerms(state.termsText).terms.length;
    toast(state.running ? `已保存 ${n} 个词，下次点「开始」时生效` : `已保存 ${n} 个词`, 2500);
  });

  /* ---------- screen awake ---------- */

  async function keepAwake() {
    try {
      if ('wakeLock' in navigator) state.wakeLock = await navigator.wakeLock.request('screen');
    } catch { /* not critical */ }
  }

  function releaseAwake() {
    if (state.wakeLock) { state.wakeLock.release().catch(() => {}); state.wakeLock = null; }
  }

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && state.running) {
      keepAwake();
      if (state.audio && state.audio.ctx.state !== 'running') {
        state.audio.ctx.resume().catch(() => {});
        toast('页面切到后台时收音会中断。请保持 EasyTalk 在前台。', 5000);
      }
    }
  });

  /* ---------- boot ---------- */

  (async () => {
    try {
      const res = await fetch('/api/status', { credentials: 'same-origin' });
      const data = await res.json();
      if (data.authed) showApp(); else showLogin();
      applyMode();
      updateTermsButton();
    } catch {
      showLogin();
      $('login-error').textContent = '连不上服务器';
    }
    if ('speechSynthesis' in window) speechSynthesis.getVoices();
  })();
}
