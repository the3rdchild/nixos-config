import { useCallback, useEffect, useRef, useState } from "react";
import { api, getStatus, toHex, type Effect, type Status } from "./api";
import { COOL_C, HOT_C, MODE_LABELS, clamp, hueOf } from "./effects";
import { Backdrop, BACKDROP_ORDER, type BackdropKind } from "./components/Backdrop";
import { FanRotor } from "./components/FanRotor";
import { KeyboardPreview } from "./components/KeyboardPreview";
import { PaletteEditor } from "./components/PaletteEditor";
import { Segmented } from "./components/Segmented";
import { Sparkline } from "./components/Sparkline";

const PROFILES = [
  { value: 1, label: "Quiet", sub: "profile 1" },
  { value: 2, label: "Balanced", sub: "profile 2" },
  { value: 3, label: "Turbo", sub: "profile 3" },
  { value: 4, label: "Performance", sub: "profile 4" },
];

const MODE_OPTIONS = MODE_LABELS.map(({ mode, label }) => ({ value: mode, label }));

/** Poll cadence. These are sysfs reads; a second is cheap and keeps the
 *  rotors honest without the page feeling like a stale snapshot. */
const POLL_MS = 1000;
/** ~3 minutes of temperature at POLL_MS. */
const HISTORY = 180;

const DEFAULT_EFFECT: Effect = {
  mode: "static",
  speed: 1,
  smooth: true,
  palette: ["#ff2828", "#2878ff", "#b428ff"],
};

function num(v: string | null): number | null {
  if (v == null) return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function readBackdrop(): BackdropKind {
  try {
    const v = localStorage.getItem("acer-ec.backdrop");
    if (v && (BACKDROP_ORDER as string[]).includes(v)) return v as BackdropKind;
  } catch {
    // Private windows and blocked site data both land here; the default is fine.
  }
  return "liquid";
}

export default function App() {
  const [status, setStatus] = useState<Status | null>(null);
  const [error, setError] = useState("");
  const [history, setHistory] = useState<number[]>([]);
  const [backdrop, setBackdrop] = useState<BackdropKind>(readBackdrop);

  // Local copies of the controls. Polling refreshes them from the server,
  // except while a control is being held (focused) or was touched in the
  // last moment — see `settled` below.
  const [color, setColor] = useState("#0000ff");
  const [brightness, setBrightness] = useState(0);
  const [fan2Duty, setFan2Duty] = useState(0);
  const [effect, setEffect] = useState<Effect>(DEFAULT_EFFECT);

  // The colour the keys are showing this instant, sampled from the preview
  // and throttled to a few times a second. It tints the backdrop, the
  // rotors and the selected pills, so the whole panel wears the keyboard's
  // colour rather than just the little swatch.
  const [accent, setAccent] = useState("#5b8cff");
  const accentAt = useRef(0);

  const brightHeld = useRef(false);
  const fan2Held = useRef(false);
  const touched = useRef(0);

  const timers = useRef<Record<string, ReturnType<typeof setTimeout>>>({});
  const debounce = (key: string, ms: number, fn: () => void) => {
    clearTimeout(timers.current[key]);
    timers.current[key] = setTimeout(fn, ms);
  };

  const fail = useCallback((e: unknown) => {
    setError(e instanceof Error ? e.message : String(e));
  }, []);

  const render = useCallback((s: Status) => {
    setStatus(s);
    setError("");
    if (s.fan.temp != null) {
      setHistory((h) => [...h, s.fan.temp as number].slice(-HISTORY));
    }
    // A local change is authoritative for a moment: without this the reply
    // to one POST and the next poll fight the slider the user is dragging.
    const settled = Date.now() - touched.current > 1500;
    if (settled) {
      if (s.kbd.color) setColor(toHex(s.kbd.color));
      if (!brightHeld.current) setBrightness(s.kbd.brightness);
      setEffect(s.kbd.effect);
      if (!fan2Held.current && s.fan.fan2.duty != null) {
        setFan2Duty(Number(s.fan.fan2.duty));
      }
    }
  }, []);

  useEffect(() => {
    const poll = () => {
      if (document.hidden) return;
      getStatus().then(render).catch(fail);
    };
    poll();
    const id = setInterval(poll, POLL_MS);
    document.addEventListener("visibilitychange", poll);
    return () => {
      clearInterval(id);
      document.removeEventListener("visibilitychange", poll);
    };
  }, [render, fail]);

  const onFrame = useCallback((hex: string) => {
    const now = performance.now();
    if (now - accentAt.current < 250) return;
    accentAt.current = now;
    setAccent(hex);
  }, []);

  const postColor = (hex: string) => {
    touched.current = Date.now();
    setColor(hex);
    debounce("color", 120, () => {
      api<Status>("/api/kbd", { color: hex }).catch(fail);
    });
  };

  const postBrightness = (value: number) => {
    touched.current = Date.now();
    setBrightness(value);
    debounce("bright", 120, () => {
      api<Status>("/api/kbd", { brightness: value }).catch(fail);
    });
  };

  const postEffect = (patch: Partial<Effect>, ms = 0) => {
    touched.current = Date.now();
    setEffect({ ...effect, ...patch });
    // Keyed by which field changed, so dragging the speed slider cannot
    // cancel a still-pending mode switch.
    debounce(`effect:${Object.keys(patch).join()}`, ms, () => {
      api<Status>("/api/kbd/effect", patch).then(render).catch(fail);
    });
  };

  const postFan2 = (value: number) => {
    touched.current = Date.now();
    setFan2Duty(value);
    debounce("fan2", 200, () => {
      api<Status>("/api/fan", { fan2_duty: value }).catch(fail);
    });
  };

  const postProfile = (p: number) => {
    touched.current = Date.now();
    api<Status>("/api/fan", { profile: p }).then(render).catch(fail);
  };

  const postAuto = () => {
    api<Status>("/api/fan", { auto: true }).then(render).catch(fail);
  };

  const cycleBackdrop = () => {
    const next =
      BACKDROP_ORDER[(BACKDROP_ORDER.indexOf(backdrop) + 1) % BACKDROP_ORDER.length];
    setBackdrop(next);
    try {
      localStorage.setItem("acer-ec.backdrop", next);
    } catch {
      // Not being able to remember the choice is not worth an error.
    }
  };

  const maxBrightness = status?.kbd.max_brightness ?? 255;
  const fan = status?.fan;
  const rpm1 = num(fan?.fan1.rpm ?? null);
  const rpm2 = num(fan?.fan2.rpm ?? null);
  const temp = fan?.temp ?? null;
  const energy = clamp(Math.max(rpm1 ?? 0, rpm2 ?? 0) / 5000, 0, 1);

  const hint = MODE_LABELS.find((m) => m.mode === effect.mode)?.hint ?? "";
  const showColor = effect.mode === "static" || effect.mode === "breathing";
  const showSpeed = effect.mode !== "static" && effect.mode !== "reactive";

  return (
    <>
      <Backdrop kind={backdrop} hue={hueOf(accent)} energy={energy} />
      <div className="veil" />
      <div className="page">
        <header className="head">
          <div className="brand">
            <span className="brand__dot" style={{ background: accent }} />
            <h1>acer-ec</h1>
            <span className={`pill${status?.available ? " is-ok" : ""}`}>
              {status ? (status.available ? "online" : "no EC") : "…"}
            </span>
          </div>
          <div className="head__side">
            {temp != null ? <span className="head__temp">{temp.toFixed(0)}°C</span> : null}
            <button type="button" className="ghost" onClick={cycleBackdrop}>
              bg · {backdrop}
            </button>
          </div>
        </header>

        <div className="grid">
          <section className="card">
            <h2>Keyboard backlight</h2>
            <KeyboardPreview
              effect={effect}
              baseHex={color}
              brightness={maxBrightness ? brightness / maxBrightness : 0}
              temp={temp}
              onFrame={onFrame}
            />
            <Segmented
              label="Lighting mode"
              options={MODE_OPTIONS}
              value={effect.mode}
              accent={accent}
              onChange={(mode) => postEffect({ mode })}
            />
            <p className="hint">{hint}</p>

            {showColor ? (
              <div className="row">
                <label htmlFor="color">Colour</label>
                <input
                  type="color"
                  id="color"
                  value={color}
                  onChange={(e) => postColor(e.target.value)}
                />
                <span className="val">{status?.kbd.color || "—"}</span>
              </div>
            ) : null}

            {effect.mode === "palette" ? (
              <>
                <div className="row">
                  <label>Swatches</label>
                  <PaletteEditor
                    colors={effect.palette}
                    onChange={(palette) => postEffect({ palette }, 250)}
                  />
                </div>
                <div className="row">
                  <label>Transition</label>
                  <Segmented
                    label="Transition"
                    options={[
                      { value: "smooth", label: "Cross-fade" },
                      { value: "cut", label: "Hard cut" },
                    ]}
                    value={effect.smooth ? "smooth" : "cut"}
                    accent={accent}
                    onChange={(v) => postEffect({ smooth: v === "smooth" })}
                  />
                </div>
              </>
            ) : null}

            {effect.mode === "reactive" ? (
              <div className="row">
                <label>Range</label>
                <div className="ramp">
                  <span>{COOL_C}°C</span>
                  <i />
                  <span>{HOT_C}°C</span>
                </div>
              </div>
            ) : null}

            {showSpeed ? (
              <div className="row">
                <label htmlFor="speed">Speed</label>
                <input
                  type="range"
                  id="speed"
                  min={0.1}
                  max={5}
                  step={0.1}
                  value={effect.speed}
                  onChange={(e) => postEffect({ speed: Number(e.target.value) }, 150)}
                />
                <span className="val">{effect.speed.toFixed(1)}×</span>
              </div>
            ) : null}

            <div className="row">
              <label htmlFor="bright">
                {effect.mode === "breathing" ? "Peak" : "Brightness"}
              </label>
              <input
                type="range"
                id="bright"
                min={0}
                max={maxBrightness}
                value={brightness}
                onPointerDown={() => (brightHeld.current = true)}
                onPointerUp={() => (brightHeld.current = false)}
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
            <div className="rotors">
              <FanRotor
                label="CPU"
                rpm={rpm1}
                duty={num(fan?.fan1.duty ?? null)}
                accent={accent}
              />
              <FanRotor
                label="GPU"
                rpm={rpm2}
                duty={num(fan?.fan2.duty ?? null)}
                accent={accent}
              />
            </div>

            <Segmented
              label="Fan profile"
              options={PROFILES}
              value={fan?.profile}
              accent={accent}
              onChange={postProfile}
            />
            <p className="hint">
              CPU duty is driven by the profile — only the GPU fan takes a
              manual duty here.
            </p>

            <div className="row">
              <label htmlFor="fan2">GPU duty</label>
              <input
                type="range"
                id="fan2"
                min={0}
                max={255}
                value={fan2Duty}
                onPointerDown={() => (fan2Held.current = true)}
                onPointerUp={() => (fan2Held.current = false)}
                onFocus={() => (fan2Held.current = true)}
                onBlur={() => (fan2Held.current = false)}
                onChange={(e) => postFan2(Number(e.target.value))}
              />
              <span className="val">{Math.round((fan2Duty / 255) * 100)}%</span>
              <button type="button" className="ghost" onClick={postAuto}>
                auto
              </button>
            </div>

            <div className="tempbox">
              <div className="tempbox__head">
                <span className="k">EC temperature</span>
                <span className="v">{temp != null ? `${temp.toFixed(0)} °C` : "—"}</span>
              </div>
              <Sparkline values={history} min={35} max={95} accent={accent} />
            </div>
          </section>
        </div>

        {error ? <div className="err">{error}</div> : null}
      </div>
    </>
  );
}
