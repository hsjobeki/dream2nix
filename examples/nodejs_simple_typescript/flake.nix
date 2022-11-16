{
  inputs = {
    dream2nix.url = "github:nix-community/dream2nix";
    src.url = "github:hsjobeki/mui-theme?ref=main";
    src.flake = false;
  };

  outputs = {
    self,
    dream2nix,
    src,
  } @ inp:
    dream2nix.lib.makeFlakeOutputs {
      systems = ["x86_64-linux"];
      config.projectRoot = ./.;
      source = src;
    };
}
