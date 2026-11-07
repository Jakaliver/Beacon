// Mac preview audio (Web Audio). With "spatial" on, every guidance sound is rendered with HRTF
// from where Trident estimates the target (or waypoint) is, relative to the simulated head.
// This previews the idea only; it does not verify Apple spatial audio or AirPods head tracking.
export type Settings = { volume: number; near: number; far: number; spatial: boolean };
type Vec3 = [number, number, number];

export class HotCold {
  ctx: AudioContext | null = null;
  settings: Settings = { volume: 0.6, near: 0.15, far: 3.0, spatial: true };
  private master!: GainNode;
  private panner!: PannerNode;
  private noise!: AudioBuffer;
  private next = 0;
  private interval: number | null = null;
  private kind: "probe" | "waypoint" = "probe";
  private pitch = 880;

  start() {
    if (this.ctx) return;
    const ctx = (this.ctx = new AudioContext());
    this.master = ctx.createGain();
    this.master.connect(ctx.destination);
    this.panner = new PannerNode(ctx, {
      panningModel: "HRTF", distanceModel: "inverse", refDistance: 0.6, rolloffFactor: 1, maxDistance: 20,
      positionX: 0, positionY: 0, positionZ: -1,
    });
    this.panner.connect(this.master);
    // Listener at the origin facing -Z (Web Audio default); sources arrive in head coordinates.
    this.noise = ctx.createBuffer(1, ctx.sampleRate * 0.1, ctx.sampleRate);
    const data = this.noise.getChannelData(0);
    for (let i = 0; i < data.length; i++) data[i] = Math.random() * 2 - 1;
    window.setInterval(() => this.schedule(), 25);
  }

  get ok() { return this.ctx?.state === "running"; }

  intervalFor(d: number) {
    const { near, far } = this.settings;
    const s = Math.min(1, Math.max(0, (d - near) / (far - near)));
    return 0.08 * Math.pow(1.2 / 0.08, s);
  }

  /** Where the sound comes from, in head coordinates (+x right, +y up, -z forward). */
  private place(source: Vec3 | null | undefined) {
    const ctx = this.ctx;
    if (!ctx) return;
    const [x, y, z] = this.settings.spatial && source ? source : [0, 0, -1];
    const t = ctx.currentTime;
    this.panner.positionX.setTargetAtTime(x, t, 0.03);
    this.panner.positionY.setTargetAtTime(y, t, 0.03);
    this.panner.positionZ.setTargetAtTime(z, t, 0.03);
  }

  setProbe(distance: number, source?: Vec3 | null) {
    const target = this.intervalFor(distance);
    // Hysteresis: ignore changes under 6% so the rhythm does not jitter.
    if (this.interval === null || this.kind !== "probe") this.interval = target;
    else if (Math.abs(target - this.interval) / this.interval > 0.06) this.interval += 0.3 * (target - this.interval);
    this.kind = "probe";
    const s = Math.min(1, Math.max(0, (distance - this.settings.near) / (this.settings.far - this.settings.near)));
    this.pitch = 1400 - 700 * s;
    this.place(source);
  }

  setWaypoint(interval: number, source?: Vec3 | null) {
    this.kind = "waypoint";
    this.interval = interval;
    this.place(source);
  }

  silence() { this.interval = null; }

  private schedule() {
    const ctx = this.ctx;
    if (!ctx || this.interval === null) return;
    this.master.gain.value = this.settings.volume;
    if (this.next < ctx.currentTime) this.next = ctx.currentTime + 0.02;
    while (this.next < ctx.currentTime + 0.1) {
      if (this.kind === "probe") this.tick(this.next, this.pitch, 0.06);
      else this.tick(this.next, 420, 0.12);
      this.next += this.interval;
    }
  }

  /** Broadband click plus a tone: HRTF localises noise far better than a pure sine. */
  private tick(t: number, freq: number, dur: number, out: AudioNode = this.panner, gain = 0.8) {
    const ctx = this.ctx!;
    const src = ctx.createBufferSource();
    src.buffer = this.noise;
    const band = new BiquadFilterNode(ctx, { type: "bandpass", frequency: freq * 2, Q: 0.8 });
    const g = ctx.createGain();
    g.gain.setValueAtTime(0, t);
    g.gain.linearRampToValueAtTime(gain, t + 0.003);
    g.gain.exponentialRampToValueAtTime(0.001, t + dur);
    src.connect(band).connect(g).connect(out);
    const o = ctx.createOscillator();
    o.frequency.value = freq;
    const og = ctx.createGain();
    og.gain.setValueAtTime(0, t);
    og.gain.linearRampToValueAtTime(gain * 0.4, t + 0.005);
    og.gain.exponentialRampToValueAtTime(0.001, t + dur);
    o.connect(og).connect(out);
    src.start(t); src.stop(t + dur + 0.02);
    o.start(t); o.stop(t + dur + 0.02);
  }

  /** Plays a click from the left, then from the right, to check headphone channels. */
  testEars(onSide: (side: string) => void) {
    const ctx = this.ctx;
    if (!ctx) return;
    const sides: [string, number][] = [["LEFT", -1.5], ["RIGHT", 1.5]];
    sides.forEach(([name, x], i) => {
      const p = new PannerNode(ctx, { panningModel: "HRTF", positionX: x, positionY: 0, positionZ: -0.2 });
      p.connect(this.master);
      const t = ctx.currentTime + 0.1 + i * 1.2;
      for (let k = 0; k < 4; k++) this.tick(t + k * 0.18, 900, 0.08, p);
      window.setTimeout(() => onSide(name), (0.1 + i * 1.2) * 1000);
    });
    window.setTimeout(() => onSide(""), 2600);
  }

  cue(name: string) {
    const ctx = this.ctx;
    if (!ctx) return;
    const t = ctx.currentTime + 0.01;
    // Cues come from the same place as the guidance sound, so the confirmation is "at" the object.
    if (name === "confirm") [1047, 1319, 1568].forEach((f, i) => this.tick(t + i * 0.09, f, 0.25));
    else if (name === "stop") [440, 220].forEach((f, i) => this.tick(t + i * 0.18, f, 0.25, this.master, 0.5));
    else if (name === "rescan") [660, 660].forEach((f, i) => this.tick(t + i * 0.15, f, 0.12, this.master, 0.5));
  }
}
