import { Suspense, lazy } from "react";
import { LiquidFormBackground } from "@designcodeio/threeui/components/LiquidFormBackground";

// DotMatrixBackground is the only thing here that pulls in three.js — half
// a megabyte for a backdrop most sessions never switch to. Loading it on
// demand keeps the default page a single small chunk.
const DotMatrixBackground = lazy(() =>
  import("@designcodeio/threeui/components/DotMatrixBackground").then((m) => ({
    default: m.DotMatrixBackground,
  })),
);

// The one WebGL context on the page.
//
// Both of these are real canvases with live props (the ThreeUI shader
// components under shaders/neuform-* are iframes that only take
// hue/saturation/brightness, so nothing there can be driven by data).
// Here the tint follows the keyboard and the flow speed follows the fans,
// which is the whole reason for a shader instead of a gradient.
//
// "off" exists because this page controls the fans of the laptop whose GPU
// it is heating. A fullscreen raymarch is a real power draw; the choice is
// the user's and it is remembered.

export type BackdropKind = "liquid" | "dots" | "off";

export const BACKDROP_ORDER: BackdropKind[] = ["liquid", "dots", "off"];

export interface BackdropProps {
  kind: BackdropKind;
  /** Keyboard hue in degrees. */
  hue: number;
  /** 0–1, from how hard the fans are working. */
  energy: number;
}

export function Backdrop({ kind, hue, energy }: BackdropProps) {
  if (kind === "off") return <div className="bg bg--flat" />;
  if (kind === "dots") {
    return (
      <Suspense fallback={<div className="bg bg--flat" />}>
        <DotMatrixBackground
          className="bg"
          speed={0.4 + energy * 0.8}
          gridScale={48}
          pulseSpeed={0.3 + energy * 0.5}
          mouseAmount={0.05}
          opacity={0.32}
          // The shader's own dots are teal; rotate from there to the keyboard.
          hue={hue - 180}
        />
      </Suspense>
    );
  }
  return (
    <LiquidFormBackground
      className="bg"
      speed={0.25 + energy * 0.7}
      morph={0.9}
      noiseScale={1.15}
      mouseAmount={0.28}
      metal={0.85}
      camera={5.8}
      tintHue={hue}
      tintAmount={0.55}
    />
  );
}
