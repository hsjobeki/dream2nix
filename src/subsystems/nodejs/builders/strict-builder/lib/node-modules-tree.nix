{
  lib,
  getDependencies,
  name,
  version,
  pkgs,
  nodeModulesBuilder,
}: let
  l = lib // builtins;
  b = builtins;

  debug = msg: val: (l.trace "${msg}: ${(l.toJSON val)}" val);
  /*
  Function that resolves local vs global dependencies.
  We copy dependencies into the global node_modules scope, if they don't have
  conflicts there.
  Otherwise we need to declare the package as 'private'.

  type:
    resolveChildren :: {
      name :: String,
      version :: String,
      ancestorCandidates :: {
        ${pname} :: String
      }
    }
    -> Dependencies

    Dependencies :: {
      ${pname} :: {
        version :: String,
        dependencies :: Dependencies,
      }
    }
  */
  resolveChildren = {
    name,
    version,
    ancestorCandidates,
  }: let
    directDeps =
      getDependencies name version;

    /*
    Determine if a dependency needs to be installed as a local dep.
    Node modules automatically inherits all ancestors and their siblings as
      dependencies.
    Therefore, installation of a local dep can be omitted, if the same dep
      is already present as an ancestor or ancestor sibling.
    */
    installLocally = name: version:
      !(ancestorCandidates ? ${name})
      || (ancestorCandidates.${name} != version);

    locallyRequiredDeps =
      b.filter (d: installLocally d.name d.version) directDeps;

    localDepsAttrs = b.listToAttrs (
      l.map (dep: l.nameValuePair dep.name dep.version) locallyRequiredDeps
    );

    newAncestorCandidates = ancestorCandidates // localDepsAttrs;

    # creates entry for single dependency.
    mkDependency = name: version: {
      inherit version;
      dependencies = resolveChildren {
        inherit name version;
        ancestorCandidates = newAncestorCandidates;
      };
    };

    # attrset of locally installed dependencies
    dependencies = l.mapAttrs mkDependency localDepsAttrs;
  in
    dependencies;

  # build the node_modules tree from all known rootPackages
  # type: NodeModulesTree :: { ${pname} :: version@String } -> { ${name} :: { version :: String, dependencies :: NodeModulesTree } }
  nodeModulesTree = packageVersions: let
    # in case of a conflict pick the highest semantic version as root. All other version must then be private if used.
    # TODO: pick the version that minimizes the tree
    pickVersion = name: versions: directDepsAttrs.${name} or (l.head (l.sort (a: b: l.compareVersions a b == 1) versions));
    rootPackages = l.mapAttrs (name: versions: pickVersion name versions) packageVersions;

    # direct dependencies are all direct dependencies parsed from the lockfile at root level.
    directDeps = getDependencies name version;

    # type: { ${name} :: String } # e.g  { "prettier" = "1.2.3"; }
    # set with all direct dependencies contains every 'root' package with only one version
    directDepsAttrs = l.listToAttrs (b.map (dep: l.nameValuePair dep.name dep.version) directDeps);
  in
    l.mapAttrs (
      name: version: let
        dependencies = resolveChildren {
          inherit name version;
          ancestorCandidates = rootPackages;
        };
      in {
        inherit version dependencies;
      }
    )
    # filter out the 'self' package (e.g. "my-app")
    (l.filterAttrs (n: v: n != name) rootPackages);

  /*
  Type:
    mkNodeModules :: {
      pname :: String,
      version :: String,
      isMain :: Bool,
      installMethod :: "copy" | "symlink"
      # optional constraints for building node_modules
      # e.g. when npm-lockfile has already resolved all packages of the main package,
      # otherwise this should be empty to create independent thus reusable leaf derivations
      fixedRootPackages :: { ${pname} :: String },
      depsTree :: DependencyTree,
      nodeModulesTree :: NodeModulesTree,
      packageJSON :: Path
    }
  */
  mkNodeModules = {
    isMain,
    installMethod,
    pname,
    version,
    depsTree,
    packageJSON,
    fixedRootPackages ? {},
  }: let
    depsTreeJSON = b.toJSON depsTree;
    rootPackagesJson = b.toJSON fixedRootPackages;
    dependencies = import ./lib.nix {
      inherit lib;
      tree = depsTree;
    };
    inherit (dependencies) packageVersions resolved;
    packageVersionsJson = b.toJSON packageVersions;
    resolvedJson = b.toJSON resolved;
    nmTreeJSON = b.toJSON (nodeModulesTree packageVersions);
  in
    pkgs.runCommandLocal "node-modules-${pname}" {
      pname = "node_modules-${pname}";
      inherit version;

      inherit rootPackagesJson packageVersionsJson resolvedJson;
      buildInputs = with pkgs; [python3];

      inherit nmTreeJSON depsTreeJSON;
      passAsFile = ["nmTreeJSON" "depsTreeJSON" "hoistedJson" "rootPackagesJson" "packageVersionsJson" "resolvedJson"];
    } ''

      export isMain=${b.toString isMain}
      export installMethod=${installMethod}
      export packageJSON=${packageJSON}

      ${nodeModulesBuilder}

      # make sure $out gets created every time, even if it is empty
      if [ ! -d "$out" ]; then
        mkdir -p $out
      fi
      echo "Build node_modules for $pname-$version > $out"

      cp $resolvedJsonPath $out/resolved.json
      cp $rootPackagesJsonPath $out/rootPackages.json
      cp $packageVersionsJsonPath $out/packageVersions.json
      cp $depsTreeJSONPath $out/depsTree.json
      cp $nmTreeJSONPath $out/nmTree.json
    '';
in {
  inherit mkNodeModules;
}
