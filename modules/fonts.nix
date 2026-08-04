{ pkgs, ... }:
{
  # System-level fonts, so SDDM and anything outside the user session sees
  # them too (home.packages only covers the logged-in user's profile).
  fonts = {
    packages = with pkgs; [
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      noto-fonts-color-emoji
      nerd-fonts.fira-code
      nerd-fonts.jetbrains-mono
      nerd-fonts.iosevka
    ];

    # Noto Sans CJK ships every region in one collection and each face claims
    # lang=ja, so without an explicit order fontconfig may resolve Japanese to
    # the KR or SC face and draw shared Han with the wrong regional glyphs.
    # Naming the JP faces here pins the Japanese variants.
    fontconfig.defaultFonts = {
      sansSerif = [ "Noto Sans" "Noto Sans CJK JP" ];
      serif = [ "Noto Serif" "Noto Serif CJK JP" ];
      monospace = [ "JetBrainsMono Nerd Font" "Noto Sans Mono CJK JP" ];
      emoji = [ "Noto Color Emoji" ];
    };
  };
}
