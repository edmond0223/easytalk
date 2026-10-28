// Collects microphone samples and posts ~100 ms chunks of 16-bit PCM (mono).
class PcmWriter extends AudioWorkletProcessor {
  constructor() {
    super();
    this.chunk = Math.round(sampleRate / 10);
    this.buf = new Float32Array(this.chunk);
    this.len = 0;
  }
  process(inputs) {
    const input = inputs[0];
    if (input && input[0]) {
      const ch = input[0];
      let i = 0;
      while (i < ch.length) {
        const n = Math.min(ch.length - i, this.chunk - this.len);
        this.buf.set(ch.subarray(i, i + n), this.len);
        this.len += n;
        i += n;
        if (this.len === this.chunk) {
          const out = new Int16Array(this.chunk);
          let peak = 0;
          for (let k = 0; k < this.chunk; k++) {
            const s = Math.max(-1, Math.min(1, this.buf[k]));
            out[k] = s < 0 ? s * 0x8000 : s * 0x7fff;
            const a = s < 0 ? -s : s;
            if (a > peak) peak = a;
          }
          this.port.postMessage({ pcm: out.buffer, peak }, [out.buffer]);
          this.len = 0;
        }
      }
    }
    return true;
  }
}
registerProcessor('pcm-writer', PcmWriter);
