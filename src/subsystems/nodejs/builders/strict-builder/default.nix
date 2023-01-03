{
  pkgs,
  lib,
  externals,
  ...
}: {
  type = "pure";

  build = {
    ### FUNCTIONS
    # AttrSet -> Bool -> AttrSet -> [x]
    getCyclicDependencies, # name: version: -> [ {name=; version=; } ]
    getDependencies, # name: version: -> [ {name=; version=; } ]
    # function that returns a nix-store-path, where a single dependency from the lockfile has been fetched to.
    getSource, # name: version: -> store-path
    # to get information about the original source spec
    getSourceSpec, # name: version: -> {type="git"; url=""; hash="";}
    ### ATTRIBUTES
    subsystemAttrs, # attrset
    defaultPackageName, # string
    defaultPackageVersion, # string
    # all exported (top-level) package names and versions
    # attrset of pname -> version,
    packages,
    # all existing package names and versions
    # attrset of pname -> versions,
    # where versions is a list of version strings
    packageVersions,
    # function which applies overrides to a package
    # It must be applied by the builder to each individual derivation
    # Example:
    # produceDerivation name (mkDerivation {...})
    produceDerivation,
    ...
  }: let
    l = lib // builtins;
    b = builtins;

    nodejsVersion = subsystemAttrs.nodejsVersion;

    defaultNodejsVersion = l.versions.major pkgs.nodejs.version;

    isMainPackage = name: version:
      (packages."${name}" or null) == version;

    nodejs =
      if !(l.isString nodejsVersion)
      then pkgs."nodejs-${defaultNodejsVersion}_x"
      else
        pkgs."nodejs-${nodejsVersion}_x"
        or (throw "Could not find nodejs version '${nodejsVersion}' in pkgs");

    nodeSources = pkgs.runCommandLocal "node-sources" {} ''
      tar --no-same-owner --no-same-permissions -xf ${nodejs.src}
      mv node-* $out
    '';

    # e.g.
    # {
    #   "@babel/core": ["1.0.0","2.0.0"]
    #   ...
    # }
    # is mapped to
    # allPackages = {
    #   "@babel/core": {"1.0.0": pkg-derivation, "2.0.0": pkg-derivation }
    #   ...
    # }
    allPackages =
      lib.mapAttrs
      (
        name: versions:
        # genAttrs takes ["1.0.0, 2.0.0"] returns -> {"1.0.0": makePackage name version}
        # makePackage: produceDerivation: name name (stdenv.mkDerivation {...})
        # returns {"1.0.0": pkg-derivation, "2.0.0": pkg-derivation }
          lib.genAttrs
          versions
          (version: (mkNodeModule name version))
      )
      packageVersions;

    # our builder, written in python. Better handles the complexity with how npm builds node_modules
    nodejsBuilder = pkgs.python310Packages.buildPythonApplication {
      name = "builder";
      src = ./nodejs_builder;
      format = "pyproject";
      nativeBuildInputs = with pkgs.python310Packages; [poetry mypy flake8 black];
      doCheck = false;
    };

    # type: resolveChildren :: { name :: String, version :: String, rootVersions :: { ${String} :: {String} }} -> { ${String} :: { version :: String, dependencies :: Self } }
    # function that resolves local vs global dependencies.
    # we copy dependencies into the global node_modules scope, if they dont have conflicts there.
    # otherwise we need to declare the package as 'private'
    # returns the recursive structure:
    # {
    #   "pname": {
    #      "version": "1.0.0",
    #      "dependencies": {...},
    #   }
    # }
    resolveChildren = {
      name, #a
      version, #1.1.2
      rootVersions,
      # {
      #   "packageNameA": "1.0.0",
      #   "packageNameB": "2.0.0"
      # }
    }: let
      directDeps = getDependencies name version;

      installLocally = name: version: !(rootVersions ? ${name}) || (rootVersions.${name} != version);

      locallyRequiredDeps = b.filter (d: installLocally d.name d.version) directDeps;

      localDepsAttrs = b.listToAttrs (l.map (dep: l.nameValuePair dep.name dep.version) locallyRequiredDeps);
      newRootVersions = rootVersions // localDepsAttrs;

      localDeps =
        l.mapAttrs
        (
          name: version: {
            inherit version;
            dependencies = resolveChildren {
              inherit name version;
              rootVersions = newRootVersions;
            };
          }
        )
        localDepsAttrs;
    in
      localDeps;

    # function that 'builds' a package.
    # executes
    # type: mkNodeModule :: String -> String -> Derivation
    mkNodeModule = name: version: let
      pname = lib.replaceStrings ["@" "/"] ["__at__" "__slash__"] name;

      # all direct dependencies of current package
      deps = getDependencies name version;

      # in case of a conflict pick the highest semantic version as root. All other version must then be private if used.
      # TODO: pick the version that minimizes the tree
      pickVersion = name: versions: directDepsAttrs.${name} or (l.head (l.sort (a: b: l.compareVersions a b == 1) versions));
      rootPackages = l.mapAttrs (name: versions: pickVersion name versions) packageVersions;

      # direct dependencies are all direct dependencies parsed from the lockfile at root level.
      directDeps = getDependencies name version;

      # type: { ${String} :: String } # e.g  { "prettier" = "1.2.3"; }
      directDepsAttrs = l.listToAttrs (b.map (dep: l.nameValuePair dep.name dep.version) directDeps);

      # build the node_modules tree from all known rootPackages
      # type: { ${String} :: { version :: String, dependencies :: Self } }
      nodeModulesTree =
        l.mapAttrs (
          name: version: let
            dependencies = resolveChildren {
              inherit name version;
              rootVersions = rootPackages;
            };
          in {
            inherit version dependencies;
          }
        )
        (l.filterAttrs (n: v: n != name) rootPackages);

      nmTreeJSON = b.toJSON nodeModulesTree;

      # type:
      #   makeDepAttrs :: {
      #     deps :: DependencyTree,
      #     dep :: { name :: String, version :: String }
      #     attributes :: {
      #       derivation :: Derivation,
      #       deps :: DependencyTree,
      #     }
      #   }
      #   -> DependencyTree
      #
      #   DependencyTree :: {
      #     ${name} :: {
      #       ${version} :: {
      #         deps :: DependencyTree,
      #         derivation :: Derivation,
      #       }
      #     }
      #   }
      makeDepAttrs = {
        deps,
        dep,
        attributes,
      }:
        deps
        // {
          ${dep.name} =
            (deps.${dep.name} or {})
            // {
              ${dep.version} =
                (deps.${dep.name}.${dep.version} or {})
                // attributes;
            };
        };

      depsTree = let
        getDeps = deps: (b.foldl'
          (
            deps: dep:
              makeDepAttrs {
                inherit deps dep;
                attributes = {
                  deps = getDeps (getDependencies dep.name dep.version);
                  derivation = allPackages.${dep.name}.${dep.version}.lib;
                };
              }
          )
          {}
          deps);
      in (getDeps deps);

      depsTreeJSON = b.toJSON depsTree;

      # Type: src :: Derivation
      src = getSource name version;

      pkg =
        externals.drv-parts.lib.derivationFromModules {}
        ({config, ...}: {
          imports = [
            externals.drv-parts.modules.mkDerivation
            (import ./options.nix {inherit lib;})
          ];
          inherit (pkgs) stdenv;
          inherit pname version src nodeSources;

          inherit nmTreeJSON depsTreeJSON;
          passAsFile = ["nmTreeJSON" "depsTreeJSON"];

          # needed for some current overrides
          nativeBuildInputs = [pkgs.makeWrapper];

          buildInputs = with pkgs; [jq nodejs python3];
          outputs = ["out" "lib" "deps"];

          installMethod =
            if isMainPackage name version
            then "copy"
            else "symlink";

          # only build the main package
          # deps only get unpacked, installed, patched, etc
          isMain = isMainPackage name version;

          env = {
            packageName = name;
            inherit (config) installMethod isMain;
          };

          passthru.devShell = import ./devShell.nix {
            inherit nodejs pkg pkgs;
          };

          unpackCmd =
            if lib.hasSuffix ".tgz" src
            then "tar --delay-directory-restore -xf $src"
            else null;

          preConfigurePhases = ["d2nPatchPhase" "d2nCheckPhase"];

          unpackPhase = import ./unpackPhase.nix {};

          # nodejs expects HOME to be set
          env.d2nPatchPhase = ''
            export HOME=$TMPDIR
          '';

          # pre-checks:
          # - platform compatibility (os + arch must match)
          env.d2nCheckPhase = ''
            # exit code 3 -> the package is incompatible to the current platform
            #  -> Let the build succeed, but don't create node_modules
            ${nodejsBuilder}/bin/d2nCheck  \
            || \
            if [ "$?" == "3" ]; then
              mkdir -p $out
              mkdir -p $lib
              mkdir -p $deps
              echo "Not compatible with system $system" > $lib/error
              exit 0
            else
              exit 1
            fi
          '';

          # create the node_modules folder
          # - uses symlinks as default
          # - symlink the .bin
          # - add PATH to .bin
          configurePhase = ''
            runHook preConfigure

            ${nodejsBuilder}/bin/d2nNodeModules

            export PATH="$PATH:node_modules/.bin"

            runHook postConfigure
          '';

          dontBuild = !(isMainPackage name version);
          # Build:
          # npm run build
          # custom build commands for:
          # - electron apps
          # fallback to npm lifecycle hooks, if no build script is present
          buildPhase = ''
            runHook preBuild

            if [ "$(jq '.scripts.build' ./package.json)" != "null" ];
            then
              echo "running npm run build...."
              npm run build
            fi

            runHook postBuild
          '';

          # copy node_modules
          # - symlink .bin
          # - symlink manual pages
          # - dream2nix copies node_modules folder if it is the top-level package
          installPhase = ''
            runHook preInstall

            if [ ! -n "$isMain" ];
            then
              if [ "$(jq '.scripts.preinstall' ./package.json)" != "null" ]; then
                npm --production --offline --nodedir=$nodeSources run preinstall
              fi
              if [ "$(jq '.scripts.install' ./package.json)" != "null" ]; then
                npm --production --offline --nodedir=$nodeSources run install
              fi
              if [ "$(jq '.scripts.postinstall' ./package.json)" != "null" ]; then
                npm --production --offline --nodedir=$nodeSources run postinstall
              fi
            fi

            # $out
            # - $out/lib/... -> $lib ...(extracted tgz)
            # - $out/lib/node_modules -> $deps
            # - $out/bin

            # $deps
            # - $deps/node_modules

            # $lib
            # - ... (extracted + install scripts runned)
            ${nodejsBuilder}/bin/d2nMakeOutputs


            runHook postInstall
          '';
        });
    in
      pkg;

    mainPackages =
      b.foldl'
      (ps: p: ps // p)
      {}
      (lib.mapAttrsToList
        (name: version: {
          "${name}"."${version}" = allPackages."${name}"."${version}";
        })
        packages);
    devShells =
      {default = devShells.${defaultPackageName};}
      // (
        l.mapAttrs
        (name: version: allPackages.${name}.${version}.devShell)
        packages
      );
  in {
    packages = mainPackages;
    inherit devShells;
  };
}
