{ ... }:
let
  # The profile installs.ini pins for the release channel. Hardcoded here
  # because home.file needs a static path; ./zen-wallpaper-accent.nix reads
  # the same value out of installs.ini at run time instead.
  profile = ".var/app/app.zen_browser.zen/.zen/f2drxuzd.Default (release)";
in
{
  # Zen (flatpak app.zen_browser.zen) prefs, applied on every Zen start via
  # user.js in the active profile — installs.ini pins f2drxuzd.Default (release).
  # user.js wins over prefs.js, so changing these in about:config won't stick.
  home.file."${profile}/user.js".text = ''
    // Managed by home/zen.nix.

    // Skip the "Paste" confirmation button Firefox shows when a page reads the
    // clipboard via navigator.clipboard (CTRL+SHIFT+V in web editors).
    // Only clipboard reads — camera/mic/location/notification prompts stay.
    user_pref("dom.events.testing.asyncClipboard", true);

    // Block notification permission prompts for every new site. Spam sites
    // (judol / "JACKPOT" / scratch-card pushes, Aug 2026) get push access by
    // tricking a click on "Allow". Sites already allowed in permissions.sqlite
    // (WhatsApp, YouTube, rumahweb) keep working; add more from the site's
    // padlock menu → Permissions.
    user_pref("permissions.default.desktop-notification", 2);

    // Load chrome/userChrome.css below. Zen ships the Firefox default, which
    // is false (greprefs.js:1444) — its own Zen Mods reach the same chrome/
    // directory through nsIZenModsBackend and never needed this pref, so
    // having mods installed is not evidence that userChrome.css is being read.
    user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
  '';

  # ── The wallpaper's accent colour.
  #
  # The palette itself is written next to this file by ii-zen-accent (see
  # ./zen-wallpaper-accent.nix for why CSS and not the zen.theme.accent-color
  # pref, and ./ii-session.nix for what runs it). This half is the mapping,
  # and it is static: which Zen variables the accent lands on does not depend
  # on the wallpaper, so it belongs in the store rather than in a file some
  # script rewrites.
  #
  # A store symlink is safe here where it would not be for most of this
  # profile: Zen rewrites prefs.js, extensions.json and chrome/zen-themes.css
  # on its own, but userChrome.css is a file it only ever reads.
  #
  # !important on all of them. --zen-primary-color in particular is set as an
  # inline style on documentElement by zenThemeModifier.js, and inline styles
  # are author-origin — a user-origin !important is the one thing that beats
  # them. The var() fallbacks are Zen's own defaults, so a missing or
  # half-written generated file degrades to stock rather than to nothing.
  home.file."${profile}/chrome/userChrome.css".text = ''
    /* Managed by home/zen.nix. */
    @import url("zen-wallpaper-accent.css");

    :root {
      /* Zen's accent. Drives tab strip, workspaces, folders, split view,
         media controls and the download animation — `grep -rl
         zen-primary-color chrome/browser/content/browser/zen-styles`. */
      --zen-primary-color: var(--ii-wp-primary, AccentColor) !important;
      --zen-colors-primary: var(--ii-wp-primary, AccentColor) !important;

      /* Firefox's own accent-coloured chrome bits, so the browser does not
         end up half matugen and half Adwaita blue. */
      --focus-outline-color: var(--ii-wp-primary, AccentColor) !important;
      --toolbarbutton-icon-fill-attention: var(--ii-wp-primary, AccentColor) !important;
      --tab-loading-fill: var(--ii-wp-primary, AccentColor) !important;
    }
  '';
}
