import type { CSSProperties } from "react";

// A labelled bar with its reading on the right. Everything numeric in the
// system card is one of these, so a glance down the column compares like
// with like — usage, memory and power all read the same way.

export interface MeterProps {
  label: string;
  /** 0–1, or null when there is no reading yet. A null bar draws empty. */
  value: number | null;
  /** Right-hand readout, already formatted and unit-bearing. */
  readout: string;
  accent: string;
  /** Optional detail line under the bar. */
  sub?: string;
  /** Dims the whole row — used for hardware that is present but asleep. */
  muted?: boolean;
}

export function Meter({ label, value, readout, accent, sub, muted }: MeterProps) {
  const pct = value == null ? 0 : Math.max(0, Math.min(1, value)) * 100;
  return (
    <div className={`meter${muted ? " is-muted" : ""}`} style={{ color: accent }}>
      <div className="meter__head">
        <span className="meter__label">{label}</span>
        <span className="meter__val">{readout}</span>
      </div>
      <div className="meter__track">
        <i className="meter__fill" style={{ width: `${pct.toFixed(1)}%` }} />
      </div>
      {sub ? <div className="meter__sub">{sub}</div> : null}
    </div>
  );
}

// Per-core load as a row of columns. Deliberately unlabelled: with twelve
// threads the useful signal is the shape — one pinned core versus all of
// them warm — not which index is which. The height is a CSS custom property
// so a poll updates twelve inline styles and no layout.
export function CoreStrip({ cores, accent }: { cores: number[]; accent: string }) {
  if (!cores.length) return null;
  return (
    <div className="cores" style={{ color: accent }}>
      {cores.map((c, i) => (
        <i
          key={i}
          className="cores__bar"
          style={{ "--v": c.toFixed(3) } as CSSProperties}
          title={`core ${i}: ${Math.round(c * 100)}%`}
        />
      ))}
    </div>
  );
}
