{ pkgs }:
#
# Extracted from ./vscode.nix so ./ii-session can run the same script
# against the second session's config root. One implementation, two callers —
# the script picks its target from XDG_CONFIG_HOME at run time, so pointing it
# at ~/.config-ii is all session B needs.

pkgs.writers.writePython3Bin "vscode-theme-settings" {
  flakeIgnore = [ "E501" ];
} ''
  """Point VS Code's theme at the session's light/dark mode, touching nothing else."""

  import json
  import os
  import re
  import subprocess

  PATH = os.path.join(
      os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
      "Code", "User", "settings.json",
  )

  # Not "Light+": VS Code 1.129 lists it, yet silently keeps the current
  # theme when workbench.colorTheme or preferredLightColorTheme names it
  # (tested live; "Light Modern" in the same spot applies at once). That
  # dead light theme was half of why light/dark never switched live.
  LIGHT = "Light Modern"
  DARK = "Dark+"

  # autoDetectColorScheme is off on purpose. It follows Electron's
  # nativeTheme, which here only ever flips one way: dark -> applied live,
  # light -> VS Code stays dark until restarted, even with a valid light
  # theme and the portal emitting SettingChanged (checked with dbus-monitor).
  # VS Code does reload settings.json live, so the mode is written there
  # instead, by the dconf watcher in ./vscode.nix.
  WANTED = {
      "window.autoDetectColorScheme": False,
      "workbench.preferredLightColorTheme": LIGHT,
      "workbench.preferredDarkColorTheme": DARK,
  }


  def session_theme():
      """The theme for dconf's color-scheme, or None if it cannot be read."""
      # dconf opens $XDG_CONFIG_HOME/dconf/user, and XDG_CONFIG_HOME here is
      # the VS Code root being edited. Drop it so the read always hits the
      # one shared database in ~/.config (see sharedFromConfigHome in
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


  theme = session_theme()
  if theme:
      WANTED["workbench.colorTheme"] = theme

  # Only scalars — these three keys never hold an object or array, and not
  # matching containers keeps the replacement from swallowing a brace.
  SCALAR = r'(?:true|false|null|"(?:[^"\\]|\\.)*"|-?[0-9][0-9.eE+-]*)'


  def blank_comments(text):
      """Overwrite // and /* */ comments with spaces, same length as the input.

      Same length is the point: offsets found in the blanked copy address the
      original text exactly, so a match can never land inside a comment and
      the edit still knows where to go. String literals are skipped so a '//'
      inside a path value survives.
      """
      out = list(text)
      i = 0
      end = len(text)
      while i < end:
          char = text[i]
          if char == '"':
              i += 1
              while i < end:
                  if text[i] == "\\":
                      i += 2
                      continue
                  if text[i] == '"':
                      i += 1
                      break
                  i += 1
              continue
          if char == "/" and i + 1 < end and text[i + 1] == "/":
              while i < end and text[i] != "\n":
                  out[i] = " "
                  i += 1
              continue
          if char == "/" and i + 1 < end and text[i + 1] == "*":
              while i < end and not (text[i] == "*" and i + 1 < end and text[i + 1] == "/"):
                  out[i] = " "
                  i += 1
              if i < end:
                  out[i] = " "
              if i + 1 < end:
                  out[i + 1] = " "
              i += 2
              continue
          i += 1
      return "".join(out)


  def parse(text):
      """Read JSONC as JSON. Used only to check the edit, never to rewrite."""
      bare = re.sub(r",(\s*[}\]])", r"\1", blank_comments(text))
      return json.loads(bare)


  def main():
      os.makedirs(os.path.dirname(PATH), exist_ok=True)

      if not os.path.exists(PATH):
          with open(PATH, "w", encoding="utf-8") as handle:
              json.dump(WANTED, handle, indent=4)
              handle.write("\n")
          return

      with open(PATH, encoding="utf-8") as handle:
          text = handle.read()

      try:
          before = parse(text)
      except ValueError:
          print("vscode-theme-settings: settings.json does not parse, left untouched")
          return

      if all(before.get(key) == value for key, value in WANTED.items()):
          return

      blanked = blank_comments(text)
      edits = []
      missing = {}
      for key, value in WANTED.items():
          pattern = re.compile(re.escape(json.dumps(key)) + r"(\s*:\s*)" + SCALAR)
          match = pattern.search(blanked)
          if match:
              edits.append((match.start(), match.end(), json.dumps(key) + match.group(1) + json.dumps(value)))
          else:
              missing[key] = value

      # Back to front, so an earlier edit cannot shift a later offset.
      new = text
      for start, stop, replacement in sorted(edits, reverse=True):
          new = new[:start] + replacement + new[stop:]

      if missing:
          brace = blank_comments(new).index("{")
          block = "".join(
              "\n    " + json.dumps(key) + ": " + json.dumps(value) + ","
              for key, value in missing.items()
          )
          new = new[:brace + 1] + block + new[brace + 1:]

      # The edit is regex-driven, so prove it landed where it was meant to:
      # the result must parse, and differ from the original in exactly these
      # keys. A match inside a nested object, or a mangled file, fails here
      # and nothing is written.
      expected = dict(before)
      expected.update(WANTED)
      try:
          after = parse(new)
      except ValueError:
          after = None
      if after != expected:
          print("vscode-theme-settings: edit did not verify, settings.json left untouched")
          return

      # In place, not a rename over it: VS Code watches this inode, and its
      # log showed "Watcher shutdown because watched path got deleted" after a
      # replace — a dead watcher means the live theme switch never lands. An
      # in-place write was verified to reload while VS Code was running.
      with open(PATH, "r+", encoding="utf-8") as handle:
          handle.write(new)
          handle.truncate()


  main()
''
