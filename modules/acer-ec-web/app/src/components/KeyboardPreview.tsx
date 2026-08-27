import { memo, useEffect, useMemo, useRef } from "react";
import { frameAt } from "../effects";
import type { Effect } from "../api";

// A stylised one-zone keyboard that runs the same curve the server is
// writing to sysfs. It never talks to the API: it integrates its own phase
// at 60 fps and asks effects.ts what the colour is, which is why a two-
// second status poll can still drive a preview that pulses smoothly.
//
// Per frame it writes two CSS custom properties on the wrapper and lets the
// stylesheet fan them out to every key — updating one element instead of
// re-rendering eighty <rect>s.

const ROWS: number[][] = [
  [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
  [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.9],
  [1.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.4],
  [1.8, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2.1],
  [2.3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2.6],
  [1.3, 1.3, 1.3, 6.4, 1.3, 1.3, 1.3, 1.3],
];

const W = 300;
const H = 116;
const PAD = 5;
const GAP = 2.5;

interface Key {
  x: number;
  y: number;
  w: number;
  h: number;
}

function layout(): Key[] {
  const rowH = (H - PAD * 2 - GAP * (ROWS.length - 1)) / ROWS.length;
  const keys: Key[] = [];
  ROWS.forEach((row, r) => {
    const units = row.reduce((a, b) => a + b, 0);
    const unit = (W - PAD * 2 - GAP * (row.length - 1)) / units;
    let x = PAD;
    row.forEach((u) => {
      const w = unit * u;
      keys.push({ x, y: PAD + r * (rowH + GAP), w, h: rowH });
      x += w + GAP;
    });
  });
  return keys;
}

export interface KeyboardPreviewProps {
  effect: Effect;
  /** Base colour, "#rrggbb" — what static and breathing show. */
  baseHex: string;
  /** Base brightness as a 0–1 fraction of max_brightness. */
  brightness: number;
  /** EC temperature, for reactive mode. */
  temp: number | null;
  /** Reported live so the parent can tint the background with it. */
  onFrame?: (hex: string) => void;
}

// memo, because the parent re-renders as the accent colour follows the
// effect and there is no reason to reconcile eighty <rect>s for that.
export const KeyboardPreview = memo(function KeyboardPreview({
  effect,
  baseHex,
  brightness,
  temp,
  onFrame,
}: KeyboardPreviewProps) {
  const keys = useMemo(layout, []);
  const hostRef = useRef<HTMLDivElement>(null);

  // The animation loop must not restart when a prop changes — restarting
  // would reset the phase and make every slider drag stutter the preview.
  const live = useRef({ effect, baseHex, brightness, temp, onFrame });
  live.current = { effect, baseHex, brightness, temp, onFrame };

  useEffect(() => {
    let frame = 0;
    let phase = 0;
    let last = performance.now();
    let reported = "";
    const tick = (now: number) => {
      const p = live.current;
      const dt = Math.min((now - last) / 1000, 0.1);
      last = now;
      phase += dt * p.effect.speed;
      const f = frameAt(p.effect, p.baseHex, phase, p.temp);
      const host = hostRef.current;
      if (host) {
        host.style.setProperty("--glow", f.hex);
        host.style.setProperty("--lvl", (f.level * p.brightness).toFixed(3));
      }
      if (f.hex !== reported) {
        reported = f.hex;
        p.onFrame?.(f.hex);
      }
      frame = document.hidden ? 0 : requestAnimationFrame(tick);
    };
    const resume = () => {
      if (!document.hidden && !frame) {
        last = performance.now();
        frame = requestAnimationFrame(tick);
      }
    };
    document.addEventListener("visibilitychange", resume);
    frame = requestAnimationFrame(tick);
    return () => {
      if (frame) cancelAnimationFrame(frame);
      document.removeEventListener("visibilitychange", resume);
    };
  }, []);

  return (
    <div className="kbd" ref={hostRef}>
      <div className="kbd__glow" />
      <svg viewBox={`0 0 ${W} ${H}`} className="kbd__svg" aria-hidden="true">
        {keys.map((k, i) => (
          <rect
            key={i}
            className="kbd__key"
            x={k.x}
            y={k.y}
            width={k.w}
            height={k.h}
            rx={2.6}
          />
        ))}
      </svg>
    </div>
  );
});
