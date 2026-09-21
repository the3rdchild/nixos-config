import { fmtBytes, fmtWatts, type AppRow } from "../metrics";

// What is actually spending the machine's power, grouped by program.
//
// The watt column is an estimate and says so. Nothing in this laptop
// measures the power of a single process: RAPL meters the package, the
// battery gauge meters the whole board. What the server can do honestly is
// divide the measured package power by each program's share of the CPU time
// actually executed in the sampling window, and add its share of the GPU's
// measured draw when nvidia-smi can see it running there. That is a good
// ranking and a rough magnitude — it is not accounting, which is why the
// heading says "est." and the note below says why.
//
// Grouped by command name rather than pid: "chromium" is one thing the user
// can close, forty renderer processes are not.

export interface AppsCardProps {
  apps: AppRow[] | undefined;
  /** True once the server has had two samples to difference. */
  ready: boolean;
  accent: string;
}

export function AppsCard({ apps, ready, accent }: AppsCardProps) {
  const rows = apps ?? [];
  const max = rows.reduce((a, r) => Math.max(a, r.watts ?? 0), 0);

  return (
    <section className="card">
      <h2>Top consumers</h2>
      {rows.length === 0 ? (
        <p className="hint">{ready ? "Nothing busy enough to rank." : "Sampling…"}</p>
      ) : (
        <table className="apps">
          <thead>
            <tr>
              <th>Program</th>
              <th className="apps__num">CPU</th>
              <th className="apps__num">Memory</th>
              <th className="apps__num">est. W</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.name}>
                <td className="apps__name">
                  <span className="apps__bar" style={{ color: accent }}>
                    <i style={{ width: `${max ? ((r.watts ?? 0) / max) * 100 : 0}%` }} />
                  </span>
                  <span className="apps__text" title={r.name}>
                    {r.name}
                    {r.procs > 1 ? <em> ×{r.procs}</em> : null}
                    {r.gpu ? <b title="GPU SM share">gpu {Math.round(r.gpu)}%</b> : null}
                  </span>
                </td>
                <td className="apps__num">{r.cpu.toFixed(1)}%</td>
                <td className="apps__num">{fmtBytes(r.rss)}</td>
                <td className="apps__num apps__watts">{fmtWatts(r.watts)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <p className="hint">
        Watts are estimated: measured package (and GPU) power split by each
        program's share of the CPU time in the sample window. No hardware
        here meters a single process. Memory is summed RSS, so forks of one
        program double-count their shared pages.
      </p>
    </section>
  );
}
