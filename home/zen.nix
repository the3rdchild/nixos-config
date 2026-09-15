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
  '';
}
