{ ... }:
{
  # fastfetch reads ~/.config/fastfetch/config.jsonc and falls back to its
  # stock logo-and-columns layout when that file is missing, which is what
  # "still the original skin" was. The package is installed from
  # ./packages.nix; this is the half that ships the config.
  #
  # Only config.jsonc is managed. The other variants in ./fastfetch are
  # alternates to pass by hand with `fastfetch -c`.
  xdg.configFile."fastfetch/config.jsonc".source = ./fastfetch/config.jsonc;
}
