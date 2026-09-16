# VS Code: follow the session's dark/light mode.
#
# HOW IT WORKS WITHOUT ANY DAEMON
#   VS Code does this itself. `window.autoDetectColorScheme` makes it read
#   Electron's nativeTheme, which on Wayland comes from the XDG settings
#   portal key org.freedesktop.appearance/color-scheme — and that is already
#   wired up here: xdg-desktop-portal-gtk is the Settings backend (the
#   hyprland portal doesn't implement that interface, so it falls through to
#   gtk per hyprland-portals.conf), and it maps the same
#   org.gnome.desktop.interface color-scheme key that `caelestia scheme`
#   writes. Verified by watching SettingChanged: flipping the mode emits
#   org.freedesktop.appearance/color-scheme = 1 for dark, 2 for light.
#
#   So unlike the Qt side (./qt.nix) there is nothing to watch and nothing to
#   translate — only three settings to put in place.
#
# WHY NOT programs.vscode
#   home-manager writes settings.json as a symlink into the store. VS Code
#   then cannot save ANY setting from its own UI, and this file is almost
#   entirely settings that were set that way. Same reasoning as the
#   copy-once mutableConfigs in ./caelestia.nix: the app owns the file.
#
#   Which rules out a jq-style rewrite too — settings.json here is JSONC and
#   carries comments (the ntfs-3g/FUSE watcher exclusions), and every
#   whole-file JSON round trip silently eats them. Hence the surgical edit
#   below.
{ config, pkgs, lib, ... }:
let
  themeSettings = pkgs.writers.writePython3Bin "vscode-theme-settings" {
    flakeIgnore = [ "E501" ];
  } ''
    """Assert VS Code's three auto-theme keys without disturbing the rest."""

    import json
    import os
    import re

    PATH = os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
        "Code", "User", "settings.json",
    )

    WANTED = {
        "window.autoDetectColorScheme": True,
        "workbench.preferredLightColorTheme": "Light+",
        "workbench.preferredDarkColorTheme": "Dark+",
    }

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

        staging = PATH + ".vscode-theme-settings"
        with open(staging, "w", encoding="utf-8") as handle:
            handle.write(new)
        os.replace(staging, PATH)


    main()
  '';
in
{
  # Also on PATH so the assertion can be re-run by hand after VS Code has
  # rewritten settings.json, without waiting for a rebuild.
  home.packages = [ themeSettings ];

  home.activation.vscodeTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${themeSettings}/bin/vscode-theme-settings
  '';
}
