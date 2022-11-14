{config, ...}: let
  l = config.lib;
  t = l.types;
in {
  options = {
    indexers = l.mkOption {
      type = t.lazyAttrsOf (
        t.submoduleWith {
          modules = [../interfaces.indexer];
          specialArgs = {framework = config;};
        }
      );
      default = {};
      description = ''
        The indexers.
      '';
    };
  };
}
