#!@python@
"""Stand-in for plasma-apply-colorscheme, for the illogical-impulse session.

kde-material-you-colors is the Qt half of these dots' colour pipeline:
matugen/templates/kde/kde-material-you-colors-wrapper.sh runs it on every
wallpaper change, it writes eight .colors files into
~/.local/share/color-schemes, and then shells out to this command to apply one.
Without it the generation half succeeds and the apply half dies with exit 127,
so the shell and GTK follow the wallpaper while every Qt and KDE app keeps the
kdeglobals it already had — which reads exactly like "the theme is still light".

Upstream ships the command only in kdePackages.plasma-workspace, whose closure
measures 4307 MB, in a configuration that deliberately dropped plasma6 for being
~35 packages too many. So this covers the part that matters here: merge the
scheme's sections into kdeglobals, then tell running Qt apps to re-read it.

It is NOT a reimplementation. No Plasma desktop theme, no wallpaper plugin, no
KColorSchemeManager bookkeeping. If any of that is ever needed, install the real
package and delete this.

The parser settings are ../home/qt.nix's, for the reasons documented there: KDE
keys are CamelCase and must not be lowercased, ':' is part of group names like
[Colors:View] rather than a delimiter, and colour and font values contain '%'
and '$' so interpolation has to be off. [Colors:Header][Inactive] survives the
round trip too — strict=False parses that header greedily and writes it back
verbatim.
"""

import configparser
import os
import subprocess
import sys

DBUS_SEND = "@dbusSend@"

# KHintsSettings::ChangeType, plasma-integration qt6/src/platformtheme.
PALETTE_CHANGED = 0

CONFIG = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
    "kdeglobals",
)


def ini():
    parser = configparser.RawConfigParser(
        strict=False,
        allow_no_value=True,
        delimiters=("=",),
        comment_prefixes=("#",),
        inline_comment_prefixes=None,
    )
    parser.optionxform = str
    return parser


def resolve(arg):
    """Accept either a path to a .colors file or a bare scheme name."""
    if os.path.isfile(arg):
        return arg
    data = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    roots = [data] + (os.environ.get("XDG_DATA_DIRS") or "").split(":")
    for root in roots:
        if not root:
            continue
        candidate = os.path.join(root, "color-schemes", arg + ".colors")
        if os.path.isfile(candidate):
            return candidate
    return None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not args:
        sys.stderr.write("usage: plasma-apply-colorscheme <name or .colors path>\n")
        return 2

    path = resolve(args[0])
    if path is None:
        sys.stderr.write("colour scheme not found: " + args[0] + "\n")
        return 1

    scheme = ini()
    scheme.read(path, encoding="utf-8")
    current = ini()
    current.read(CONFIG, encoding="utf-8")

    # Replace the colour sections rather than merging into them: a key the new
    # scheme does not define must not survive from the old one.
    for section in list(current.sections()):
        if section.startswith("Colors:") or section.startswith("ColorEffects:"):
            current.remove_section(section)

    # Everything but [General], which describes the scheme file itself rather
    # than kdeglobals — only its ColorScheme name carries over.
    for section in scheme.sections():
        if section == "General":
            continue
        if not current.has_section(section):
            current.add_section(section)
        for key, value in scheme.items(section):
            current.set(section, key, value)

    name = scheme.get(
        "General",
        "ColorScheme",
        fallback=os.path.basename(path).removesuffix(".colors"),
    )
    if not current.has_section("General"):
        current.add_section("General")
    current.set("General", "ColorScheme", name)

    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    staging = CONFIG + ".ii-new"
    with open(staging, "w", encoding="utf-8") as handle:
        current.write(handle, space_around_delimiters=False)
    os.replace(staging, CONFIG)

    subprocess.run(
        [
            DBUS_SEND, "--session", "--type=signal", "/KGlobalSettings",
            "org.kde.KGlobalSettings.notifyChange",
            "int32:" + str(PALETTE_CHANGED), "int32:0",
        ],
        check=False,
    )
    sys.stdout.write("Applied color scheme " + name + "\n")
    return 0


sys.exit(main())
