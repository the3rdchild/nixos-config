import { Meter, CoreStrip } from "./Meter";
import { Sparkline } from "./Sparkline";
import { fmtBytes, fmtPct, fmtWatts, type Metrics } from "../metrics";

// CPU, both GPUs, memory and where the watts go.
//
// The rails at the bottom are a *breakdown*, not a list of readings: they
// are built server-side so they never overlap and never exceed the total
// (cores + iGPU + SoC rest come out of the package figure; whatever the
// platform draws beyond that and the discrete GPU lands in "rest"). Drawing
// them as shares of the total is therefore honest — the bars really do add
// up to the number above them.

export interface SystemCardProps {
  metrics: Metrics | null;
  /** CPU usage history, 0–100, oldest first. */
  cpuHistory: number[];
  accent: string;
}

export function SystemCard({ metrics, cpuHistory, accent }: SystemCardProps) {
  const cpu = metrics?.cpu;
  const mem = metrics?.mem;
  const igpu = metrics?.igpu;
  const dgpu = metrics?.dgpu;
  const power = metrics?.power;

  const cpuSub = [
    cpu?.freq_mhz != null ? `${(cpu.freq_mhz / 1000).toFixed(2)} GHz` : null,
    cpu?.temp != null ? `${cpu.temp.toFixed(0)} °C` : null,
    cpu?.watts != null ? fmtWatts(cpu.watts) : null,
  ]
    .filter(Boolean)
    .join(" · ");

  // The clock, not a load percentage: i915 exposes no busy counter and the
  // real one needs perf privileges this service does not have. Showing the
  // render clock against its own range is the honest version of the same
  // question — it sits at the floor idle and walks up under load.
  const igpuSpan =
    igpu && igpu.max_mhz ? (igpu.freq_mhz - (igpu.min_mhz ?? 0)) / (igpu.max_mhz - (igpu.min_mhz ?? 0)) : null;

  const asleep = dgpu?.present && dgpu.state !== "active";

  const rails = power?.rails ?? [];
  const railMax = rails.reduce((a, r) => Math.max(a, r.watts), 0);

  return (
    <section className="card">
      <h2>System</h2>

      <Meter
        label="CPU"
        value={cpu?.usage ?? null}
        readout={fmtPct(cpu?.usage)}
        sub={cpuSub || undefined}
        accent={accent}
      />
      <CoreStrip cores={cpu?.cores ?? []} accent={accent} />
      <Sparkline values={cpuHistory} min={0} max={100} accent={accent} />

      {igpu ? (
        <Meter
          label="iGPU clock"
          value={igpuSpan}
          readout={`${igpu.freq_mhz} MHz`}
          sub={
            [
              igpu.max_mhz ? `max ${igpu.max_mhz} MHz` : null,
              igpu.watts != null ? fmtWatts(igpu.watts) : null,
            ]
              .filter(Boolean)
              .join(" · ") || undefined
          }
          accent={accent}
        />
      ) : null}

      {dgpu?.present ? (
        asleep ? (
          <Meter
            label="dGPU"
            value={null}
            readout="asleep"
            muted
            sub="Left suspended on purpose — querying it would wake the card."
            accent={accent}
          />
        ) : (
          <Meter
            label={dgpu.name ? dgpu.name.replace(/^NVIDIA\s+/, "") : "dGPU"}
            value={dgpu.usage ?? null}
            readout={fmtPct(dgpu.usage)}
            sub={
              [
                dgpu.mem_total
                  ? `${fmtBytes(dgpu.mem_used)} / ${fmtBytes(dgpu.mem_total)}`
                  : null,
                dgpu.temp != null ? `${dgpu.temp.toFixed(0)} °C` : null,
                dgpu.watts != null ? fmtWatts(dgpu.watts) : null,
              ]
                .filter(Boolean)
                .join(" · ") || undefined
            }
            accent={accent}
          />
        )
      ) : null}

      {mem ? (
        <Meter
          label="Memory"
          value={mem.total ? mem.used / mem.total : null}
          readout={`${fmtBytes(mem.used)} / ${fmtBytes(mem.total)}`}
          sub={
            [
              `${fmtBytes(mem.cached)} cached`,
              mem.swap_total ? `swap ${fmtBytes(mem.swap_used)}` : null,
            ]
              .filter(Boolean)
              .join(" · ") || undefined
          }
          accent={accent}
        />
      ) : null}

      <div className="rails">
        <div className="rails__head">
          <span className="k">Power draw</span>
          <span className="v">{fmtWatts(power?.total)}</span>
        </div>
        {power?.total == null ? (
          <p className="hint">
            {power?.battery?.ac
              ? "On AC: whole-system draw needs the RAPL psys domain."
              : "No power source could be read."}
          </p>
        ) : null}
        {rails.length ? (
          <ul className="rails__list">
            {rails.map((r) => (
              <li key={r.key} className="rail" style={{ color: accent }}>
                <span className="rail__label">{r.label}</span>
                <span className="rail__track">
                  <i
                    className="rail__fill"
                    style={{ width: `${railMax ? (r.watts / railMax) * 100 : 0}%` }}
                  />
                </span>
                <span className="rail__val">{fmtWatts(r.watts)}</span>
              </li>
            ))}
          </ul>
        ) : (
          <p className="hint">
            No per-rail figures — the powercap counters are unreadable.
          </p>
        )}
        {power?.source ? (
          <p className="hint">
            {power.source === "battery"
              ? "Total from the battery gauge."
              : "Total from RAPL psys."}
          </p>
        ) : null}
      </div>
    </section>
  );
}
