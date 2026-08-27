// Browser-side mirror of the effect engine in ../../acer-ec-web.nix.
//
// The keyboard is driven by the server, not by this file — nothing here
// ever reaches sysfs. What it does is reproduce the same curves at 60 fps
// so the on-screen keyboard preview shows what the real keys are doing
// without polling the API twenty times a second. The constants below are
// the ones in the Python engine; change them in both places or the preview
// drifts away from the hardware.

import type { Effect } from "./api";

/** Reactive mode: this and below is the green end of the hue sweep. */
export const COOL_C = 45;
/** Reactive mode: this and above is the red end. */
export const HOT_C = 85;

export type Rgb = [number, number, number];

export function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

export function hsvToRgb(h: number, s: number, v: number): Rgb {
  const hh = (((h % 1) + 1) % 1) * 6;
  const i = Math.floor(hh);
  const f = hh - i;
  const p = v * (1 - s);
  const q = v * (1 - f * s);
  const t = v * (1 - (1 - f) * s);
  const table: Rgb[] = [
    [v, t, p],
    [q, v, p],
    [p, v, t],
    [p, q, v],
    [t, p, v],
    [v, p, q],
  ];
  const c = table[i % 6];
  return [Math.round(c[0] * 255), Math.round(c[1] * 255), Math.round(c[2] * 255)];
}

export function hexToRgb(hex: string): Rgb {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

export function rgbToHex(c: Rgb): string {
  return "#" + c.map((v) => clamp(Math.round(v), 0, 255).toString(16).padStart(2, "0")).join("");
}

export function mixRgb(a: Rgb, b: Rgb, t: number): Rgb {
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
}

/** Hue in degrees, which is the unit the ThreeUI background tint wants. */
export function hueOf(hex: string): number {
  const [r, g, b] = hexToRgb(hex).map((v) => v / 255);
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const d = max - min;
  if (d === 0) return 220;
  let h: number;
  if (max === r) h = ((g - b) / d) % 6;
  else if (max === g) h = (b - r) / d + 2;
  else h = (r - g) / d + 4;
  return ((h * 60) % 360 + 360) % 360;
}

export interface Frame {
  /** The colour the keys are showing right now. */
  hex: string;
  /** 0–1 multiplier on the base brightness (only breathing moves it). */
  level: number;
}

/**
 * Where the effect is at `phase` seconds of accumulated, speed-scaled time.
 * The caller integrates phase itself (`phase += dt * effect.speed`) exactly
 * as the engine does, so a speed change bends the curve instead of jumping.
 */
export function frameAt(
  effect: Effect,
  baseHex: string,
  phase: number,
  temp: number | null,
): Frame {
  switch (effect.mode) {
    case "breathing": {
      const level = 0.5 - 0.5 * Math.cos(phase * 2 * Math.PI * 0.25);
      return { hex: baseHex, level: 0.05 + 0.95 * level };
    }
    case "hue":
      return { hex: rgbToHex(hsvToRgb(phase * 0.08, 1, 1)), level: 1 };
    case "palette": {
      const pal = effect.palette.length ? effect.palette : [baseHex];
      const step = phase * 0.5;
      const i = Math.floor(step) % pal.length;
      const frac = step - Math.floor(step);
      if (!effect.smooth || pal.length < 2) return { hex: pal[i], level: 1 };
      const t = clamp((frac - 0.65) / 0.35, 0, 1);
      const next = pal[(i + 1) % pal.length];
      return {
        hex: rgbToHex(
          mixRgb(hexToRgb(pal[i]), hexToRgb(next), t * t * (3 - 2 * t)) as Rgb,
        ),
        level: 1,
      };
    }
    case "reactive": {
      if (temp == null) return { hex: baseHex, level: 1 };
      const x = clamp((temp - COOL_C) / (HOT_C - COOL_C), 0, 1);
      return { hex: rgbToHex(hsvToRgb(0.45 * (1 - x), 1, 1)), level: 1 };
    }
    default:
      return { hex: baseHex, level: 1 };
  }
}

export const MODE_LABELS: { mode: Effect["mode"]; label: string; hint: string }[] = [
  { mode: "static", label: "Static", hint: "One colour, held." },
  { mode: "breathing", label: "Breathe", hint: "Brightness swings up and down." },
  { mode: "hue", label: "Cycle", hint: "Smooth lap around the colour wheel." },
  { mode: "palette", label: "Palette", hint: "Steps through your swatches." },
  { mode: "reactive", label: "Reactive", hint: "Green when cool, red when hot." },
];
