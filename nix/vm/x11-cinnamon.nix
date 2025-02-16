{...}: {
  imports = [
    ./common-cinnamon.nix
  ];

  services.displayManager.defaultSession = "cinnamon";
}
