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

// Group tokens into utterances: consecutive original tokens of one speaker,
// split at <end>. Translation tokens go to the oldest utterance whose
// originals have not been translated yet.
function buildUtterances(tokens) {
  const utts = [];
  let cur = null;          // utterance receiving original tokens
  let pending = [];        // utterances with untranslated originals
  let transTarget = null;  // utterance receiving the current translation run
  let inTrans = false;

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

function newUtt(speaker) {
  return { speaker, en: [], zh: [], ended: false, endFinal: false };
}

function plainText(parts) {
  return parts.map((p) => p.text).join('').replace(/\s+/g, ' ').trim();
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// Highlight numbers, times and amounts.
function markNumbers(html) {
  return html.replace(/(\$?\d[\d:.,/%]*(?:\s?(?:am|pm|AM|PM|点|号|元|块))?)/g, '<mark>$1</mark>');
}

function renderParts(parts, { unsure = false } = {}) {
  let html = '';
  let run = '';
  let runPending = null;
  const flush = () => {
    if (!run) return;
    const body = markNumbers(escapeHtml(run));
    html += runPending ? `<span class="pending">${body}</span>` : body;
    run = '';
  };
  for (const p of parts) {
    const isPending = !p.final;
    const isUnsure = unsure && p.final && typeof p.conf === 'number' && p.conf < UNSURE_CONFIDENCE && p.text.trim();
    if (isUnsure) {
      flush();
      const body = markNumbers(escapeHtml(p.text));
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
  module.exports = { buildUtterances, plainText, renderParts, markNumbers, escapeHtml };
}

/* ------------------------------------------------------------------ app */

if (typeof document !== 'undefined') {
  const $ = (id) => document.getElementById(id);

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
    if (!state.names.has(key)) state.names.set(key, `对方 ${state.names.size + 1}`);
    const n = state.names.get(key);
    return state.names.size === 1 ? '对方' : n;
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
    const shown = utts.slice(-60);
    let html = '';
    for (const u of shown) {
      const isMe = state.me.has(u.speaker);
      const en = renderParts(u.en, { unsure: !isMe });
      const zh = renderParts(u.zh);
      if (!en && !zh) continue;
      html += `<div class="utt ${isMe ? 'me' : 'them'}">`
        + `<button class="tag" data-speaker="${escapeHtml(u.speaker)}">${escapeHtml(speakerName(u.speaker))}${isMe ? ' · 不是我' : ' · 这是我?'}</button>`
        + `<div class="en">${en}</div><div class="zh">${zh}</div></div>`;
    }
    let list = box.querySelector('.list');
    if (!list) { list = document.createElement('div'); list.className = 'list'; box.appendChild(list); }
    list.innerHTML = html;
    if (nearBottom) box.scrollTop = box.scrollHeight;
  }

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

  function speak(text, onEnd) {
    if (!('speechSynthesis' in window)) { toast('这个浏览器不支持朗读'); return; }
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
    await ctx.audioWorklet.addModule('/static/pcm-worklet.js');
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
    return ctx.sampleRate;
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
      ws.send(JSON.stringify({
        model: 'stt-rt-v5',
        audio_format: 'pcm_s16le',
        sample_rate: sampleRate,
        num_channels: 1,
        language_hints: ['en'],
        enable_speaker_diarization: true,
        enable_endpoint_detection: true,
        max_endpoint_delay_ms: 1500,
        translation: { type: 'one_way', target_language: 'zh' },
        context: { general: [
          { key: 'domain', value: SCENE_DOMAIN[scene] || SCENE_DOMAIN.daily },
          { key: 'location', value: 'Mississauga, Ontario, Canada' },
        ] },
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
          openSession(state.audio.ctx.sampleRate).catch((err) => failStop(err));
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
    } catch {
      showLogin();
      $('login-error').textContent = '连不上服务器';
    }
    if ('speechSynthesis' in window) speechSynthesis.getVoices();
  })();
}
