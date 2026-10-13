# Points micro's colorscheme at the session's light/dark mode, touching
# nothing else in settings.json.
#
# micro ships no light/dark pair of its own worth trusting sight-unseen, so
# this also writes the two colorschemes it switches between (ii-dark,
# ii-light — same palettes as ./kitty-theme-settings.nix, so a terminal
# running micro doesn't clash with itself). settings.json is plain JSON with
# no comments, unlike VS Code's settings.json (../vscode-theme-settings.nix),
# so a full json.load/json.dump round trip is safe here.
{ pkgs }:

pkgs.writers.writePython3Bin "micro-theme-settings" {
  flakeIgnore = [ "E501" ];
} ''
  """Point micro's colorscheme at the session's light/dark mode."""

  import json
  import os
  import subprocess

  DARK = "ii-dark"
  LIGHT = "ii-light"

  SCHEMES = {
      DARK: """
  color-link default "#a9b1d6,#1a1b26"
  color-link comment "#565f89,"
  color-link identifier "#7aa2f7,"
  color-link constant "#ff9e64,"
  color-link constant.string "#9ece6a,"
  color-link constant.string.char "#9ece6a,"
  color-link symbol "#bb9af7,"
  color-link type "#2ac3de,"
  color-link type.keyword "#bb9af7,"
  color-link special "#7dcfff,"
  color-link statement "#bb9af7,"
  color-link preproc "#bb9af7,"
  color-link underlined "#c0caf5,"
  color-link error "#f7768e,"
  color-link todo "#e0af68,bold"
  color-link diff-added "#9ece6a,"
  color-link diff-modified "#e0af68,"
  color-link diff-deleted "#f7768e,"
  color-link line-number "#3b4261,#1a1b26"
  color-link current-line-number "#737aa2,#1a1b26"
  color-link gutter-error "#f7768e,"
  color-link gutter-warning "#e0af68,"
  color-link cursor-line "#1f2335"
  color-link color-column "#1f2335"
  color-link statusline "#1a1b26,#3d59a1"
  color-link indent-char "#3b4261,"
  color-link select "#c0caf5,#28344a"
  """,
      LIGHT: """
  color-link default "#504e55,#fcfcfc"
  color-link comment "#9a9996,"
  color-link identifier "#62a0ea,"
  color-link constant "#ffa348,"
  color-link constant.string "#57e389,"
  color-link constant.string.char "#57e389,"
  color-link symbol "#9141ac,"
  color-link type "#5bc8af,"
  color-link type.keyword "#9141ac,"
  color-link special "#5bc8af,"
  color-link statement "#9141ac,"
  color-link preproc "#9141ac,"
  color-link underlined "#504e55,"
  color-link error "#ed333b,"
  color-link todo "#ff7800,bold"
  color-link diff-added "#57e389,"
  color-link diff-modified "#ff7800,"
  color-link diff-deleted "#ed333b,"
  color-link line-number "#9a9996,#fcfcfc"
  color-link current-line-number "#5e5c64,#fcfcfc"
  color-link gutter-error "#ed333b,"
  color-link gutter-warning "#ff7800,"
  color-link cursor-line "#f6f5f4"
  color-link color-column "#f6f5f4"
  color-link statusline "#fcfcfc,#b0afac"
  color-link indent-char "#deddda,"
  color-link select "#504e55,#deddda"
  """,
  }

  ROOT = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
  SETTINGS_PATH = os.path.join(ROOT, "micro", "settings.json")
  SCHEMES_DIR = os.path.join(ROOT, "micro", "colorschemes")


  def write_schemes():
      os.makedirs(SCHEMES_DIR, exist_ok=True)
      for name, text in SCHEMES.items():
          path = os.path.join(SCHEMES_DIR, name + ".micro")
          text = text.strip() + "\n"
          if os.path.exists(path) and open(path, encoding="utf-8").read() == text:
              continue
          with open(path, "w", encoding="utf-8") as handle:
              handle.write(text)


  def session_mode():
      """DARK, LIGHT, or None if dconf cannot be read."""
      # dconf opens $XDG_CONFIG_HOME/dconf/user, and XDG_CONFIG_HOME here is
      # the micro root being edited. Drop it so the read always hits the one
      # shared database in ~/.config (see sharedFromConfigHome in
      # ./ii-session/default.nix).
      env = {k: v for k, v in os.environ.items() if k != "XDG_CONFIG_HOME"}
      try:
          value = subprocess.run(
              ["${pkgs.dconf}/bin/dconf", "read", "/org/gnome/desktop/interface/color-scheme"],
              capture_output=True, text=True, check=True, env=env,
          ).stdout.strip().strip("'")
      except (OSError, subprocess.CalledProcessError):
          return None
      if value == "prefer-dark":
          return DARK
      if value in ("prefer-light", "default"):
          return LIGHT
      return None


  def main():
      write_schemes()

      mode = session_mode()
      if mode is None:
          return

      os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)
      settings = {}
      if os.path.exists(SETTINGS_PATH):
          with open(SETTINGS_PATH, encoding="utf-8") as handle:
              text = handle.read()
          try:
              settings = json.loads(text) if text.strip() else {}
          except ValueError:
              print("micro-theme-settings: settings.json does not parse, left untouched")
              return

      if settings.get("colorscheme") == mode:
          return

      settings["colorscheme"] = mode
      with open(SETTINGS_PATH, "w", encoding="utf-8") as handle:
          json.dump(settings, handle, indent=4)
          handle.write("\n")


  main()
''
