// Downsamples the microphone to 16 kHz mono and posts ~100 ms chunks of
// 16-bit PCM. 16 kHz is standard for speech recognition and uses about a
// third of the data of the phone's native 48 kHz (~115 MB per hour).
const TARGET_RATE = 16000;

class PcmWriter extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ratio = sampleRate / TARGET_RATE;      // input samples per output sample
    this.chunk = TARGET_RATE / 10;              // 100 ms of output
    this.out = new Int16Array(this.chunk);
    this.len = 0;
    this.acc = 0;                               // running sum for the current output sample
    this.count = 0;                             // input samples in it
    this.pos = 0;                               // input progress toward the next output sample
    this.peak = 0;
  }

  emit(value) {
    const s = Math.max(-1, Math.min(1, value));
    this.out[this.len++] = s < 0 ? s * 0x8000 : s * 0x7fff;
    const a = s < 0 ? -s : s;
    if (a > this.peak) this.peak = a;
    if (this.len === this.chunk) {
      const buf = this.out.buffer;
      this.port.postMessage({ pcm: buf, peak: this.peak }, [buf]);
      this.out = new Int16Array(this.chunk);
      this.len = 0;
      this.peak = 0;
    }
  }

  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (!ch) return true;
    if (this.ratio <= 1) {                      // device already at or below 16 kHz
      for (let i = 0; i < ch.length; i++) this.emit(ch[i]);
      return true;
    }
    // Box-filter decimation: average the input samples that fall into each
    // output sample (a simple low-pass that is plenty for speech).
    for (let i = 0; i < ch.length; i++) {
      this.acc += ch[i];
      this.count += 1;
      this.pos += 1;
      if (this.pos >= this.ratio) {
        this.emit(this.acc / this.count);
        this.acc = 0;
        this.count = 0;
        this.pos -= this.ratio;
      }
    }
    return true;
  }
}
registerProcessor('pcm-writer', PcmWriter);
