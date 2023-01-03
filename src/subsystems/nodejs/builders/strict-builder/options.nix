{lib, ...}: let
  # l = lib;
  t = lib.types;
  optStr = lib.mkOption {
    type = t.str;
    default = null;
  };
  optInstallMethod = lib.mkOption {
    type = t.enum ["copy" "symlink"];
    default = null;
  };
  optBool = lib.mkOption {
    type = t.bool;
    default = null;
  };
  optPackage = lib.mkOption {
    type = t.oneOf [t.package t.str t.path];
    default = null;
  };
in {
  options = {
    # d2nPatchPhase = optStr;
    # d2nCheckPhase = optStr;
    nmTreeJSON = optStr;
    depsTreeJSON = optStr;
    installMethod = optInstallMethod;
    isMain = optBool;
    nodeSources = optPackage;
    packageName = optStr;
  };
}
