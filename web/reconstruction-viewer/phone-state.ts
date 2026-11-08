import type { PhoneFrame } from "./types";

type Vector3 = [number, number, number];
export type PhoneLocation = {
  position: Vector3 | null;
  forward: Vector3 | null;
  up: Vector3 | null;
  floorY: number | null;
  height: number | null;
  state: "live" | "stale" | "tracking" | "waiting";
  ageMs: number | null;
};

const vector = (value: unknown): Vector3 | null => Array.isArray(value) && value.length === 3
  && value.every(v => typeof v === "number" && Number.isFinite(v)) ? [...value] as Vector3 : null;
const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);

/** Phone freshness is independent of camera inference and the room point cloud. */
export class PhoneState {
  private identity: string | null = null;
  private retired = new Set<string>();
  private seq: number | null = null;
  private sourceTime: number | null = null;
  private position: Vector3 | null = null;
  private forward: Vector3 | null = null;
  private up: Vector3 | null = null;
  private floorY: number | null = null;
  private observedAt: number | null = null;
  private tracking: string | null = null;
  private sensorConnected = false;
  private valid = false;

  reset() {
    this.identity = null;
    this.retired.clear();
    this.clearPose();
  }

  private clearPose() {
    this.seq = this.sourceTime = this.observedAt = null;
    this.position = this.forward = this.up = null;
    this.floorY = this.tracking = null;
    this.sensorConnected = this.valid = false;
  }

  isCurrentWorld(frame: PhoneFrame): boolean {
    return this.identity === `${frame.scan_id ?? "legacy"}:${frame.epoch}`;
  }

  update(frame: PhoneFrame, now: number): { accepted: boolean; reset: boolean } {
    if (!Number.isInteger(frame.epoch) || !frame.phone || !frame.stats) return { accepted: false, reset: false };
    const identity = `${frame.scan_id ?? "legacy"}:${frame.epoch}`;
    const reset = this.identity !== identity;
    if (reset) {
      // A slow reconstruction job can finish after a new world/pose has arrived.
      if (this.retired.has(identity)) return { accepted: false, reset: false };
      if (this.identity !== null) this.retired.add(this.identity);
      if (this.retired.size > 16) this.retired.delete(this.retired.values().next().value!);
      this.clearPose();
      this.identity = identity;
    }
    const seq = finite(frame.phone.seq) ? frame.phone.seq : null;
    const t = finite(frame.phone.t) ? frame.phone.t : null;
    if (this.seq !== null && seq !== null && seq < this.seq
      || this.sourceTime !== null && t !== null && t < this.sourceTime) {
      return { accepted: false, reset: false };
    }
    if (seq !== null) this.seq = seq;
    if (t !== null) this.sourceTime = t;
    this.floorY = finite(frame.floor_y) ? frame.floor_y : null;
    this.sensorConnected = frame.stats.sensor_connected === true;
    this.tracking = frame.phone.tracking;
    const position = vector(frame.phone.position);
    const forward = vector(frame.phone.forward);
    const age = frame.stats.pose_age_ms;
    this.valid = !!position && !!forward && Math.hypot(...forward) > 1e-6
      && finite(age) && age >= 0;
    // Retain the last trustworthy position while ARKit is relocalising.
    if (this.valid && this.tracking === "normal") {
      this.position = position;
      this.forward = forward;
      const up = vector(frame.phone.up);
      this.up = up && Math.hypot(...up) > 1e-6 ? up : null;
      this.observedAt = now - (age as number);
    }
    return { accepted: true, reset };
  }

  location(now: number, connected: boolean): PhoneLocation {
    const ageMs = this.observedAt === null ? null : Math.max(0, now - this.observedAt);
    const state = !this.position ? "waiting"
      : !connected || !this.sensorConnected ? "stale"
      : this.tracking !== "normal" || !this.valid ? "tracking"
      : ageMs === null || ageMs >= 1000 ? "stale" : "live";
    const height = this.position && this.floorY !== null ? this.position[1] - this.floorY : null;
    const knownFloor = height !== null && height >= 0;
    return {
      position: this.position, forward: this.forward, up: this.up,
      floorY: knownFloor ? this.floorY : null,
      height: knownFloor ? height : null,
      state, ageMs,
    };
  }
}
