{
  inputs = {
    dream2nix.url = "github:nix-community/dream2nix";
    src.url = "github:BurntSushi/ripgrep/13.0.0";
    src.flake = false;
  };

  outputs = {
    self,
    dream2nix,
    src,
  } @ inp:
    (dream2nix.lib.makeFlakeOutputs {
      systems = ["x86_64-linux"];
      config.projectRoot = ./.;
      source = src;
      projects = ./projects.toml;
    })
    // {
      # checks.x86_64-linux.ripgrep = self.packages.x86_64-linux.ripgrep;
    };
}
