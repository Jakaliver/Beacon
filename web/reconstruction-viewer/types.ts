export type Recon = {
  scan_id?: string;
  epoch: number; perception: string; mode: string; stop_reason: string | null; navigation: boolean;
  grid: { origin: [number, number]; res: number; w: number; h: number; cells: string };
  floor_y: number | null; points: string;
  point_colors?: string;
  points_version?: number;
  points_fused?: boolean;
  phone: { position: number[] | null; forward: number[] | null; tracking: string | null };
  listener: number[] | null;
  targets: { id: string; label: string; position: number[]; extent: number[]; sigma: number; age: number; valid: boolean; selected: boolean; injected: boolean; locked?: boolean }[];
  path: number[][]; waypoint: number[] | null;
  stats: Record<string, number | boolean | null>;
};
