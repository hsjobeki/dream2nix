{
  dlib,
  externals,
  externalSources,
  inputs,
  lib,
  pkgs,
  utils,
  dream2nixConfig,
  dream2nixConfigFile,
  dream2nixWithExternals,
} @ args: let
  t = lib.types;
in {
  imports = [
    ./functions.discoverers
    ./functions.fetchers
    ./functions.default-fetcher
    ./functions.combined-fetcher
    ./functions.translators
    ./apps
    ./builders
    ./discoverers
    ./discoverers.default-discoverer
    ./fetchers
    ./translators
    ./indexers
  ];
  options = {
    lib = lib.mkOption {
      type = t.raw;
    };
    dlib = lib.mkOption {
      type = t.raw;
    };
    externals = lib.mkOption {
      type = t.raw;
    };
    externalSources = lib.mkOption {
      type = t.raw;
    };
    inputs = lib.mkOption {
      type = t.raw;
    };
    pkgs = lib.mkOption {
      type = t.raw;
    };
    utils = lib.mkOption {
      type = t.raw;
    };
    dream2nixConfig = lib.mkOption {
      type = t.raw;
    };
    dream2nixWithExternals = lib.mkOption {
      type = t.path;
    };
    dream2nixConfigFile = lib.mkOption {
      type = t.path;
    };
  };
  config =
    args
    // {
      lib = args.lib // builtins;
    };
}
