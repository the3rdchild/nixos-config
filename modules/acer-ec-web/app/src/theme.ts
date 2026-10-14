export type ThemeMode = "light" | "dark" | "auto";
export type ResolvedTheme = "light" | "dark";

const STORAGE_KEY = "acer-ec-theme";
const MODES: ThemeMode[] = ["dark", "light", "auto"];

const media = () => window.matchMedia("(prefers-color-scheme: light)");

export function getSystemTheme(): ResolvedTheme {
  return media().matches ? "light" : "dark";
}

export function resolveTheme(mode: ThemeMode): ResolvedTheme {
  return mode === "auto" ? getSystemTheme() : mode;
}

export function getStoredMode(): ThemeMode {
  const stored = localStorage.getItem(STORAGE_KEY);
  return stored === "light" || stored === "dark" || stored === "auto" ? stored : "auto";
}

export function setStoredMode(mode: ThemeMode): void {
  localStorage.setItem(STORAGE_KEY, mode);
}

export function applyResolvedTheme(resolved: ResolvedTheme): void {
  document.documentElement.dataset.theme = resolved;
}

export function nextMode(mode: ThemeMode): ThemeMode {
  return MODES[(MODES.indexOf(mode) + 1) % MODES.length];
}

/** Keeps the resolved theme in sync with the OS while `mode` is "auto". */
export function watchSystemTheme(onChange: (resolved: ResolvedTheme) => void): () => void {
  const m = media();
  const listener = () => onChange(getSystemTheme());
  m.addEventListener("change", listener);
  return () => m.removeEventListener("change", listener);
}
