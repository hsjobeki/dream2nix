{config, ...}: let
  inherit (config.dlib) mkFunction;
  l = config.lib;
  t = l.types;
in {
  options.utils = {
    generatePackagesFromLocksTree = mkFunction {
      type = t.attrsOf t.package;
    };
    makeOutputsForIndexes = mkFunction {
      type = t.attrs;
    };
  };
}
