{ ... }:
{
  # Zen (flatpak app.zen_browser.zen) prefs, applied on every Zen start via
  # user.js in the active profile — installs.ini pins f2drxuzd.Default (release).
  # user.js wins over prefs.js, so changing these in about:config won't stick.
  home.file.".var/app/app.zen_browser.zen/.zen/f2drxuzd.Default (release)/user.js".text = ''
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
  '';
}
