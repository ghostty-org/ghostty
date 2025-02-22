{...}: {
  imports = [
    ./common-gnome.nix
  ];

  services.displayManager = {
    defaultSession = "gnome";
  };
}
