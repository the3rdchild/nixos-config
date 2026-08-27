// API client for the acer-ec-web backend. The contract here must stay
// byte-for-byte compatible with the Python server in ../../acer-ec-web.nix.

export type EffectMode =
  | "static"
  | "breathing"
  | "hue"
  | "palette"
  | "reactive";

export interface Effect {
  mode: EffectMode;
  /** 0.1 – 5.0. Multiplies the phase advance, so 2.0 is twice as fast. */
  speed: number;
  /** Palette mode only: cross-fade between swatches instead of cutting. */
  smooth: boolean;
  /** Palette swatches as "#rrggbb" — the server hands them over already hex. */
  palette: string[];
}

export interface FanSide {
  duty: string | null;
  rpm: string | null;
}

export interface Status {
  available: boolean;
  kbd: {
    /** The *base* brightness the user picked — the peak a breath swings to,
     *  not whatever the effect thread last wrote. */
    brightness: number;
    max_brightness: number;
    /** "r g b" — the base colour, likewise, not the live sysfs value. */
    color: string;
    effect: Effect;
  };
  fan: {
    profile: number;
    fan1: FanSide;
    fan2: FanSide;
    temp: number | null;
  };
}

export async function api<T>(path: string, body?: object): Promise<T> {
  const r = await fetch(
    path,
    body
      ? {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        }
      : undefined,
  );
  const j = await r.json();
  if (!r.ok) throw new Error(j.error || String(r.status));
  return j as T;
}

export const getStatus = () => api<Status>("/api/status");

/** "r g b" (sysfs multi_intensity) → "#rrggbb" for <input type=color>. */
export function toHex(c: string): string {
  return (
    "#" +
    c
      .split(" ")
      .map(Number)
      .map((v) => v.toString(16).padStart(2, "0"))
      .join("")
  );
}
