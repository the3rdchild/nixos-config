import { Meter } from "./Meter";
import { Sparkline } from "./Sparkline";
import { fmtDuration, fmtWatts, type Battery } from "../metrics";

// Charge, where it is heading and how fast, and what the pack is worth now.
//
// The time estimates come from the server, not from this page: it keeps a
// ~1-minute running average of the gauge's rate, because current_now is an
// instantaneous reading that triples between an idle desktop and a page
// load. Dividing by that directly gives a forecast that jumps by hours every
// poll. While the average is still being seeded (just after the panel was
// opened, or the charger plugged in) the card says so instead of passing one
// second of current off as a prediction.
//
// "Until power-off" is the number that matters on this machine: upower
// powers it off at the action level from power.nix, well before 0%.

export interface BatteryCardProps {
  battery: Battery | null | undefined;
  /** |rate| in watts, oldest first — 0 while idle on AC. */
  rateHistory: number[];
  accent: string;
}

const OK = "#6ee7a8";
const WARN = "#f0b35a";
const CRIT = "#e06c75";

function stateText(b: Battery): string {
  switch (b.status) {
    case "Discharging":
      return "On battery";
    case "Charging":
      return "Charging";
    case "Full":
      return "Full";
    case "Not charging":
      // What the gauge reports when the adapter is in but the EC is holding
      // the pack — at the top of a charge, or at a charge limit.
      return b.ac ? "Plugged in · not charging" : "Not charging";
    default:
      return b.status ? b.status.toLowerCase() : "—";
  }
}

export function BatteryCard({ battery: b, rateHistory, accent }: BatteryCardProps) {
  if (!b) {
    // undefined: no snapshot yet. null: the server looked and found none.
    return (
      <section className="card">
        <h2>Battery</h2>
        <p className="hint">
          {b === undefined ? "Sampling…" : "No battery found under /sys/class/power_supply."}
        </p>
      </section>
    );
  }

  const cap = b.capacity;
  const low = b.thresholds.low ?? 20;
  const crit = b.thresholds.critical ?? 10;
  const action = b.thresholds.action;
  const discharging = b.status === "Discharging";
  const charging = b.status === "Charging";

  // Semantic colour only where it carries meaning — charging, or running
  // low on battery. Otherwise the cell wears the keyboard accent like the
  // rest of the panel.
  const tint =
    cap != null && discharging && cap <= crit
      ? CRIT
      : cap != null && discharging && cap <= low
        ? WARN
        : charging
          ? OK
          : accent;

  const about = b.settling ? "Estimating…" : null;
  let eta: string;
  let etaSub: string | null = null;
  if (discharging) {
    eta = about ?? `${fmtDuration(b.to_action ?? b.to_empty)} left`;
    if (!about && action != null && b.to_action != null) {
      etaSub = `until power-off at ${action}% · ${fmtDuration(b.to_empty)} to empty`;
    }
  } else if (charging) {
    eta = about ?? (b.to_full != null ? `Full in about ${fmtDuration(b.to_full)}` : "Charging");
    if (!about) etaSub = "Runs optimistic near the top, where the charger tapers off.";
  } else {
    eta = b.ac ? "On AC power" : "Idle";
  }

  const hasRate = rateHistory.some((v) => v > 0);
  const rateMax = Math.max(10, ...rateHistory) * 1.15;

  const stats: [string, string][] = [
    [charging ? "Charging at" : "Draw", fmtWatts(b.rate_w)],
    [
      "Energy",
      b.energy_wh != null && b.full_wh != null ? `${b.energy_wh} / ${b.full_wh} Wh` : "—",
    ],
    ["Voltage", b.voltage != null ? `${b.voltage.toFixed(2)} V` : "—"],
    ["Cycles", b.cycles != null ? String(b.cycles) : "—"],
    ["Chemistry", b.technology ?? "—"],
    ["Gauge level", b.level ?? "—"],
  ];

  return (
    <section className="card">
      <h2>Battery</h2>

      <div className="batt">
        <div className="batt__cell" style={{ color: tint }}>
          <i className="batt__fill" style={{ width: `${cap ?? 0}%` }} />
          {action != null ? (
            <i className="batt__mark" style={{ left: `calc(4px + (100% - 8px) * ${action / 100})` }} title={`power-off at ${action}%`} />
          ) : null}
          {charging || b.ac ? (
            <svg className="batt__bolt" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M13 2 4 14h7l-1 8 9-12h-7z" />
            </svg>
          ) : null}
        </div>
        <div className="batt__readout">
          <span className="batt__pct">
            {cap ?? "—"}
            <small>%</small>
          </span>
          <span className="batt__state">{stateText(b)}</span>
        </div>
      </div>

      <div className="batt__eta">
        <span className="batt__eta-main">{eta}</span>
        {etaSub ? <span className="batt__eta-sub">{etaSub}</span> : null}
      </div>

      <dl className="stats">
        {stats.map(([k, v]) => (
          <div key={k} className="stats__item">
            <dt>{k}</dt>
            <dd>{v}</dd>
          </div>
        ))}
      </dl>

      <Meter
        label="Health"
        value={b.health}
        readout={b.health != null ? `${Math.round(b.health * 100)}%` : "—"}
        sub={
          b.full_wh != null && b.design_wh != null
            ? `holds ${b.full_wh} Wh of ${b.design_wh} Wh design`
            : undefined
        }
        accent={b.health != null && b.health < 0.7 ? WARN : accent}
      />

      {hasRate ? (
        <div className="tempbox">
          <div className="tempbox__head">
            <span className="k">{charging ? "Charge rate" : "Battery draw"}</span>
            <span className="v">{fmtWatts(b.rate_w)}</span>
          </div>
          <Sparkline values={rateHistory} min={0} max={rateMax} accent={tint} />
        </div>
      ) : null}

      <p className="hint">
        Estimates divide the remaining charge by a one-minute average of the
        gauge's rate, so they settle a little after a load change.
      </p>
    </section>
  );
}
