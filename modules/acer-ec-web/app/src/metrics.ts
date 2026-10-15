// Client for /api/metrics — the read-only half of the backend, everything
// that is not the EC: /proc, powercap, the battery gauge, nvidia-smi.
//
// Mirrors the shapes built by sampler() in ../../acer-ec-web.nix. Every
// field is optional on purpose: the server reports null rather than
// guessing whenever a source is missing or unreadable (no discrete GPU, no
// permission on the RAPL counters, first poll after an idle pause), and the
// UI shows an em dash for those instead of a zero that looks like a reading.

import { api } from "./api";

export interface Cpu {
  /** 0–1 across all cores. */
  usage: number | null;
  /** 0–1 per core, core 0 first. */
  cores: number[];
  freq_mhz: number | null;
  temp: number | null;
  /** RAPL package-0, in watts. */
  watts: number | null;
}

export interface Mem {
  total: number;
  available: number;
  used: number;
  cached: number;
  swap_total: number;
  swap_used: number;
}

export interface Igpu {
  freq_mhz: number;
  min_mhz: number | null;
  max_mhz: number | null;
  /** RAPL uncore domain — the integrated GPU's own rail. */
  watts: number | null;
}

export interface Dgpu {
  present: boolean;
  /** PCI runtime power state: "active", "suspended", "suspending"… */
  state?: string | null;
  name?: string;
  usage?: number;
  mem_used?: number;
  mem_total?: number;
  watts?: number | null;
  temp?: number | null;
  freq_mhz?: number | null;
}

/** One non-overlapping slice of the platform's power draw. */
export interface Rail {
  key: string;
  label: string;
  watts: number;
}

export interface Battery {
  /** sysfs status: "Discharging", "Charging", "Full", "Not charging"… */
  status: string | null;
  /** 0–100. */
  capacity: number | null;
  /** sysfs capacity_level: "Normal", "Low", "Critical"… */
  level: string | null;
  /** Whole-system draw — set only while discharging. */
  watts: number | null;
  /** Instantaneous flow in either direction, null when idle on AC. */
  rate_w: number | null;
  ac: boolean | null;
  energy_wh: number | null;
  full_wh: number | null;
  design_wh: number | null;
  /** 0–1: what the pack holds now against what it held new. */
  health: number | null;
  cycles: number | null;
  voltage: number | null;
  technology: string | null;
  /** Seconds, from a ~1-minute average of the rate. */
  to_empty: number | null;
  /** Seconds until upower's power-off level, while discharging. */
  to_action: number | null;
  to_full: number | null;
  /** True for the first ~20 s after the average was (re)seeded. */
  settling: boolean;
  /** upower's percentages from power.nix; null when upower is off. */
  thresholds: { low: number | null; critical: number | null; action: number | null };
}

export interface Power {
  /** Whole-system draw, or null when nothing can measure it. */
  total: number | null;
  /** "battery" (real, discharging only) or "psys" (RAPL platform domain). */
  source: string | null;
  battery: Battery | null;
  rails: Rail[];
}

export interface AppRow {
  name: string;
  procs: number;
  /** Percent of the whole machine, so it sums towards the CPU meter. */
  cpu: number;
  rss: number;
  /** Estimated — see the note in the card. */
  watts: number | null;
  /** Percent of GPU SM time, when nvidia-smi could see it. */
  gpu: number | null;
}

export interface Metrics {
  /** False until the sampler has two readings to difference. */
  ready: boolean;
  cpu?: Cpu;
  mem?: Mem;
  igpu?: Igpu | null;
  dgpu?: Dgpu;
  power?: Power;
  apps?: AppRow[];
}

export const getMetrics = () => api<Metrics>("/api/metrics");

export function fmtBytes(n: number | null | undefined): string {
  if (n == null) return "—";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i += 1;
  }
  return `${v.toFixed(i === 0 || v >= 100 ? 0 : 1)} ${units[i]}`;
}

export function fmtWatts(w: number | null | undefined): string {
  if (w == null) return "—";
  return `${w >= 10 ? w.toFixed(1) : w.toFixed(2)} W`;
}

export function fmtPct(v: number | null | undefined): string {
  return v == null ? "—" : `${Math.round(v * 100)}%`;
}

/** Seconds → "2 h 05 min" / "45 min". Rounded to the minute: the estimate
 *  is not good to the second and should not look like it is. */
export function fmtDuration(s: number | null | undefined, compact = false): string {
  if (s == null || !Number.isFinite(s)) return "—";
  const m = Math.max(0, Math.round(s / 60));
  if (m < 60) return compact ? `${m}m` : `${m} min`;
  const h = Math.floor(m / 60);
  // Past a day the rate is near zero and the figure means nothing.
  if (h >= 24) return compact ? ">24h" : "> 24 h";
  const mm = String(m % 60).padStart(2, "0");
  return compact ? `${h}h${mm}m` : `${h} h ${mm} min`;
}
