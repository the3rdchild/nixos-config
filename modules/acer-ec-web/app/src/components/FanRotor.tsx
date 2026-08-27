import { useEffect, useRef } from "react";

// A fan that actually turns at the speed the EC reports.
//
// Real rpm is unusable as a rotation rate — 2000 rpm is 33 turns a second,
// which at 60 fps strobes into a smear or, worse, appears to run backwards.
// SPIN_SCALE slows it to something the eye can follow while keeping the
// mapping linear, so "faster fan" still reads as "faster fan".
const SPIN_SCALE = 0.05;
const BLADES = 7;

// One blade, drawn pointing up from the hub in a 100×100 box; the group is
// rotated BLADES times around (50,50) to make the rotor.
const BLADE = "M50 50 C 60 40 63 24 54 12 C 40 19 35 36 43 49 Z";

export interface FanRotorProps {
  label: string;
  rpm: number | null;
  /** Raw 0–255 duty, as the EC reports it. */
  duty: number | null;
  /** Ring + blade tint. */
  accent: string;
}

export function FanRotor({ label, rpm, duty, accent }: FanRotorProps) {
  const rotorRef = useRef<SVGGElement>(null);
  // Read inside the animation frame so a new rpm changes the speed without
  // restarting the loop and snapping the blades back to zero.
  const rpmRef = useRef(0);
  rpmRef.current = rpm ?? 0;

  useEffect(() => {
    let frame = 0;
    let angle = 0;
    let last = performance.now();
    const tick = (now: number) => {
      const dt = Math.min((now - last) / 1000, 0.1);
      last = now;
      angle = (angle + (rpmRef.current / 60) * SPIN_SCALE * 360 * dt) % 360;
      rotorRef.current?.setAttribute("transform", `rotate(${angle.toFixed(2)} 50 50)`);
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

  const pct = duty == null ? 0 : Math.round((duty / 255) * 100);

  return (
    <div className="rotor" style={{ color: accent }}>
      <div className="rotor__dial">
        <svg viewBox="0 0 100 100" role="img" aria-label={`${label}: ${rpm ?? 0} rpm`}>
          {/* Duty ring. pathLength=100 turns the dash array into a percentage. */}
          <circle className="rotor__track" cx="50" cy="50" r="45" pathLength={100} />
          <circle
            className="rotor__duty"
            cx="50"
            cy="50"
            r="45"
            pathLength={100}
            strokeDasharray={`${pct} 100`}
            transform="rotate(-90 50 50)"
          />
          <g ref={rotorRef}>
            {Array.from({ length: BLADES }, (_, i) => (
              <path
                key={i}
                className="rotor__blade"
                d={BLADE}
                transform={`rotate(${(360 / BLADES) * i} 50 50)`}
              />
            ))}
          </g>
          <circle className="rotor__hub" cx="50" cy="50" r="13" />
        </svg>
        <div className="rotor__readout">
          <span className="rotor__rpm">{rpm ?? "—"}</span>
          <span className="rotor__unit">rpm</span>
        </div>
      </div>
      <div className="rotor__label">
        {label}
        <span className="rotor__duty-text">{duty == null ? "—" : `${pct}%`}</span>
      </div>
    </div>
  );
}
