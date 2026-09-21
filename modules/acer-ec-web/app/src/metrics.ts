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

export interface Power {
  /** Whole-system draw, or null when nothing can measure it. */
  total: number | null;
  /** "battery" (real, discharging only) or "psys" (RAPL platform domain). */
  source: string | null;
  battery: {
    status: string | null;
    capacity: number | null;
    watts: number | null;
    ac: boolean | null;
  } | null;
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
