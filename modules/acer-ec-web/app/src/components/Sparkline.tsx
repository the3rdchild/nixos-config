export interface SparklineProps {
  /** Oldest sample first. Fewer than two points renders nothing. */
  values: number[];
  /** Floor/ceiling of the y axis; the series is clamped into them. */
  min: number;
  max: number;
  accent: string;
}

const W = 200;
const H = 44;

/** EC temperature over the last few minutes of polling, kept in the page. */
export function Sparkline({ values, min, max, accent }: SparklineProps) {
  if (values.length < 2) return <div className="spark spark--empty" />;

  const span = Math.max(1, max - min);
  const step = W / (values.length - 1);
  const pts = values.map((v, i) => {
    const y = H - ((Math.min(max, Math.max(min, v)) - min) / span) * (H - 4) - 2;
    return `${(i * step).toFixed(1)},${y.toFixed(1)}`;
  });

  return (
    <svg className="spark" viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" style={{ color: accent }}>
      <path className="spark__area" d={`M0,${H} L${pts.join(" L")} L${W},${H} Z`} />
      <polyline className="spark__line" points={pts.join(" ")} />
    </svg>
  );
}
