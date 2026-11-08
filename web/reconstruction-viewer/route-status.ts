import type { Recon } from "./types";

export type RouteStatus = { visible: boolean; text: string; distance: number | null };
export type RouteFreshness = { connected: boolean; phoneLive: boolean; elapsedMs: number };

const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);
const age = (value: unknown): value is number => finite(value) && value >= 0;
// Match the renderer's coordinate and geometry limits in readRoute.
const coordinate = (value: unknown): value is number => finite(value) && Math.abs(value) <= 100_000;
const point = (value: unknown): value is [number, number] => Array.isArray(value)
  && value.length === 2 && value.every(coordinate);
const hidden = (text: string): RouteStatus => ({ visible: false, text, distance: null });

/** Display freshness only; this does not authorize motion or send navigation commands. */
export function routeStatus(recon: Recon | null, freshness: RouteFreshness): RouteStatus {
  if (!recon) return hidden("Waiting for route");
  if (recon.navigation !== true) return hidden("Pathfinding off");
  if (recon.mode === "stopped" || recon.stop_reason != null) return hidden("Route paused");

  const { connected, phoneLive, elapsedMs } = freshness;
  const observationAge = recon.stats?.observation_age_ms;
  const frameAge = recon.stats?.frame_age_ms;
  // These ages measure successive intervals: capture to processing, processing to
  // snapshot, then time since receipt. A new receipt cannot refresh old imagery.
  const fresh = connected && phoneLive && recon.phone?.tracking === "normal"
    && recon.stats?.sensor_connected === true
    && age(elapsedMs) && elapsedMs <= 1000 && age(observationAge) && age(frameAge)
    && observationAge + frameAge + elapsedMs <= 1500;
  if (!fresh) return hidden("Route paused");
  if (recon.mode === "probe") return hidden("Approaching object");
  if (recon.mode !== "walking") return hidden("Waiting for route");
  if (!coordinate(recon.floor_y) || !Array.isArray(recon.path) || recon.path.length < 2 || recon.path.length > 8192
    || !recon.path.every(point) || !point(recon.waypoint)) return hidden("Waiting for route");

  let distance = 0;
  let previous = recon.path[0];
  for (let i = 1; i < recon.path.length; i++) {
    const segment = Math.hypot(recon.path[i][0] - previous[0], recon.path[i][1] - previous[1]);
    if (segment <= 0.001) continue;
    distance += segment;
    previous = recon.path[i];
  }
  if (!Number.isFinite(distance) || distance <= 0) return hidden("Waiting for route");
  return { visible: true, text: `Planned route · ${distance.toFixed(1)} m`, distance };
}
