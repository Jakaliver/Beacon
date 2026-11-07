// Non-spatial hot/cold audio for the Mac demo (Web Audio). Walking beacons use a simple
// stereo pan as a directional preview only; it does not verify Apple spatial audio.
export type Settings = { volume: number; near: number; far: number };

export class HotCold {
  ctx: AudioContext | null = null;
  settings: Settings = { volume: 0.5, near: 0.15, far: 3.0 };
  private master!: GainNode;
  private next = 0;
  private interval: number | null = null;
  private kind: "probe" | "waypoint" = "probe";
  private pan = 0;
  private pitch = 880;
  private timer = 0;

  start() {
    if (this.ctx) return;
    this.ctx = new AudioContext();
    this.master = this.ctx.createGain();
    this.master.connect(this.ctx.destination);
    this.timer = window.setInterval(() => this.schedule(), 25);
  }

  get ok() { return this.ctx?.state === "running"; }

  /** Smoothed pulse interval from phone-to-target distance, with a configurable range. */
  intervalFor(d: number) {
    const { near, far } = this.settings;
    const s = Math.min(1, Math.max(0, (d - near) / (far - near)));
    return 0.08 * Math.pow(1.2 / 0.08, s);
  }

  setProbe(distance: number) {
    const target = this.intervalFor(distance);
    // Hysteresis: ignore changes under 6% so the rhythm does not jitter.
    if (this.interval === null || this.kind !== "probe") this.interval = target;
    else if (Math.abs(target - this.interval) / this.interval > 0.06) this.interval += 0.3 * (target - this.interval);
    this.kind = "probe";
    this.pan = 0;
    const s = Math.min(1, Math.max(0, (distance - this.settings.near) / (this.settings.far - this.settings.near)));
    this.pitch = 1400 - 700 * s;
  }

  setWaypoint(interval: number, azimuth: number) {
    this.kind = "waypoint";
    this.interval = interval;
    this.pan = Math.max(-1, Math.min(1, Math.sin(azimuth)));
  }

  silence() { this.interval = null; }

  private schedule() {
    const ctx = this.ctx;
    if (!ctx || this.interval === null) return;
    this.master.gain.value = this.settings.volume;
    if (this.next < ctx.currentTime) this.next = ctx.currentTime + 0.02;
    while (this.next < ctx.currentTime + 0.1) {
      if (this.kind === "probe") this.blip(this.next, this.pitch, "sine", 0.05, 0);
      else this.blip(this.next, 330, "triangle", 0.09, this.pan);
      this.next += this.interval;
    }
  }

  private blip(t: number, freq: number, type: OscillatorType, dur: number, pan: number, gain = 0.6) {
    const ctx = this.ctx!;
    const o = ctx.createOscillator();
    const g = ctx.createGain();
    const p = ctx.createStereoPanner();
    o.type = type;
    o.frequency.value = freq;
    p.pan.value = pan;
    g.gain.setValueAtTime(0, t);
    g.gain.linearRampToValueAtTime(gain, t + 0.005);
    g.gain.exponentialRampToValueAtTime(0.001, t + dur);
    o.connect(g).connect(p).connect(this.master);
    o.start(t);
    o.stop(t + dur + 0.02);
  }

  cue(name: string) {
    const ctx = this.ctx;
    if (!ctx) return;
    const t = ctx.currentTime + 0.01;
    if (name === "confirm") [1047, 1319, 1568].forEach((f, i) => this.blip(t + i * 0.09, f, "sine", 0.25, 0, 0.7));
    else if (name === "stop") [440, 220].forEach((f, i) => this.blip(t + i * 0.18, f, "square", 0.22, 0, 0.35));
    else if (name === "rescan") [660, 660].forEach((f, i) => this.blip(t + i * 0.15, f, "triangle", 0.1, 0, 0.5));
  }
}
