import { useCallback, useEffect, useRef, useState } from "react";
import { DotMatrixBackground } from "@designcodeio/threeui/components/DotMatrixBackground";
import { LumenCta } from "@designcodeio/threeui/components/LumenCta";
import { api, getStatus, toHex, type Status } from "./api";

const PROFILES: { p: number; label: string }[] = [
  { p: 1, label: "1 · quiet" },
  { p: 2, label: "2 · balanced" },
  { p: 3, label: "3" },
  { p: 4, label: "4 · performance" },
];

export default function App() {
  const [status, setStatus] = useState<Status | null>(null);
  const [error, setError] = useState("");

  // Local copies of the controls. Polling refreshes them from sysfs, but a
  // control the user is currently holding (focused) is left alone — the same
  // rule the old page implemented with document.activeElement.
  const [color, setColor] = useState("#0000ff");
  const [brightness, setBrightness] = useState(0);
  const [fan2Duty, setFan2Duty] = useState(0);
  const brightHeld = useRef(false);
  const fan2Held = useRef(false);

  const brightTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const fan2Timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const colorTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const fail = useCallback((e: unknown) => {
    setError(e instanceof Error ? e.message : String(e));
  }, []);

  const render = useCallback((s: Status) => {
    setStatus(s);
    if (s.kbd.color) setColor(toHex(s.kbd.color));
    if (!brightHeld.current) setBrightness(s.kbd.brightness);
    if (!fan2Held.current && s.fan.fan2.duty != null) {
      setFan2Duty(Number(s.fan.fan2.duty));
    }
  }, []);

  useEffect(() => {
    const poll = () => getStatus().then(render).catch(fail);
    poll();
    const id = setInterval(poll, 2000);
    return () => clearInterval(id);
  }, [render, fail]);

  const postColor = (hex: string) => {
    setColor(hex);
    if (colorTimer.current) clearTimeout(colorTimer.current);
    colorTimer.current = setTimeout(() => {
      api<Status>("/api/kbd", { color: hex }).then(render).catch(fail);
    }, 300);
  };

  const postBrightness = (value: number) => {
    setBrightness(value);
    if (brightTimer.current) clearTimeout(brightTimer.current);
    brightTimer.current = setTimeout(() => {
      api<Status>("/api/kbd", { brightness: value }).catch(fail);
    }, 150);
  };

  const postFan2 = (value: number) => {
    setFan2Duty(value);
    if (fan2Timer.current) clearTimeout(fan2Timer.current);
    fan2Timer.current = setTimeout(() => {
      api<Status>("/api/fan", { fan2_duty: value }).catch(fail);
    }, 250);
  };

  const postProfile = (p: number) => {
    api<Status>("/api/fan", { profile: p }).then(render).catch(fail);
  };

  const postAuto = () => {
    api<Status>("/api/fan", { auto: true }).then(render).catch(fail);
  };

  const maxBrightness = status?.kbd.max_brightness ?? 255;
  const fan = status?.fan;

  return (
    <>
      <DotMatrixBackground
        className="bg"
        speed={0.5}
        gridScale={48}
        pulseSpeed={0.3}
        mouseAmount={0.03}
        opacity={0.3}
      />
      <div className="page">
        <header className="head">
          <h1>
            acer-ec
            <span className={`dot${status?.available ? " ok" : ""}`} />
          </h1>
        </header>
        <div className="grid">
          <section className="card">
            <h2>Keyboard backlight</h2>
            <div className="row">
              <label htmlFor="color">Colour</label>
              <input
                type="color"
                id="color"
                value={color}
                onChange={(e) => postColor(e.target.value)}
              />
              <span className="val">{status?.kbd.color || "-"}</span>
            </div>
            <div className="row">
              <label htmlFor="bright">Brightness</label>
              <input
                type="range"
                id="bright"
                min={0}
                max={maxBrightness}
                value={brightness}
                onFocus={() => (brightHeld.current = true)}
                onBlur={() => (brightHeld.current = false)}
                onChange={(e) => postBrightness(Number(e.target.value))}
              />
              <span className="val">
                {brightness} / {maxBrightness}
              </span>
            </div>
          </section>
          <section className="card">
            <h2>Fans</h2>
            <div className="row">
              <label>Profile</label>
              <div className="seg">
                {PROFILES.map(({ p, label }) => (
                  <LumenCta
                    key={p}
                    label={label}
                    ring={false}
                    variant={fan?.profile === p ? "primary" : "ghost"}
                    onClick={() => postProfile(p)}
                  />
                ))}
              </div>
            </div>
            <div className="row">
              <label htmlFor="fan2">GPU fan</label>
              <input
                type="range"
                id="fan2"
                min={0}
                max={255}
                value={fan2Duty}
                onFocus={() => (fan2Held.current = true)}
                onBlur={() => (fan2Held.current = false)}
                onChange={(e) => postFan2(Number(e.target.value))}
              />
              <span className="val">
                {fan?.fan2.duty != null ? fan.fan2.duty : "-"}
              </span>
              <LumenCta
                label="auto"
                ring={false}
                variant="ghost"
                onClick={postAuto}
              />
            </div>
            <div className="stats">
              <span className="k">CPU fan</span>
              <span className="v">{fan?.fan1.rpm ?? "-"} rpm</span>
              <span className="k">GPU fan</span>
              <span className="v">{fan?.fan2.rpm ?? "-"} rpm</span>
              <span className="k">CPU duty</span>
              <span className="v">{fan?.fan1.duty ?? "-"}</span>
              <span className="k">GPU duty</span>
              <span className="v">{fan?.fan2.duty ?? "-"}</span>
              <span className="k">EC temp</span>
              <span className="v">
                {fan?.temp != null ? `${fan.temp.toFixed(0)} °C` : "-"}
              </span>
            </div>
          </section>
        </div>
        <div className="err">{error}</div>
      </div>
    </>
  );
}
