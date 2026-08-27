// API client for the acer-ec-web backend. The contract here must stay
// byte-for-byte compatible with the Python server in ../../acer-ec-web.nix.

export interface FanSide {
  duty: string | null;
  rpm: string | null;
}

export interface Status {
  available: boolean;
  kbd: {
    brightness: number;
    max_brightness: number;
    /** "r g b" — the raw multi_intensity string. */
    color: string;
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
