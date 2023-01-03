{
  lib,
  pkgs,
  externals,
  ...
} @ topArgs: {
  type = "ifd";

  build = {
    subsystemAttrs,
    defaultPackageName,
    defaultPackageVersion,
    getCyclicDependencies,
    getDependencies,
    getSource,
    getSourceSpec,
    packages,
    produceDerivation,
    ...
  } @ args: let
    l = lib // builtins;

    utils = import ../utils.nix (args // topArgs);
    vendoring = import ../vendor.nix (args // topArgs);

    mkCrane = toolchain:
      if toolchain ? cargoHostTarget && toolchain ? cargoBuildBuild
      then externals.crane toolchain
      else if toolchain ? cargo
      then
        externals.crane {
          cargoHostTarget = toolchain.cargo;
          cargoBuildBuild = toolchain.cargo;
        }
      else throw "crane toolchain must include either a 'cargo' or both of 'cargoHostTarget' and 'cargoBuildBuild'";

    buildDepsWithToolchain =
      utils.mkBuildWithToolchain
      (toolchain: (mkCrane toolchain).buildDepsOnly);
    buildPackageWithToolchain =
      utils.mkBuildWithToolchain
      (toolchain: (mkCrane toolchain).buildPackage);
    defaultToolchain = {
      inherit (pkgs) cargo;
    };

    buildPackage = pname: version: let
      replacePaths =
        utils.replaceRelativePathsWithAbsolute
        subsystemAttrs.relPathReplacements.${pname}.${version};
      writeGitVendorEntries = vendoring.writeGitVendorEntries "nix-sources";

      # common args we use for both buildDepsOnly and buildPackage
      common = {
        inherit pname version;

        src = utils.getRootSource pname version;
        cargoVendorDir = "$TMPDIR/nix-vendor";
        installCargoArtifactsMode = "use-zstd";

        postUnpack = ''
          export CARGO_HOME=$(pwd)/.cargo_home
          export cargoVendorDir="$TMPDIR/nix-vendor"
        '';
        preConfigure = ''
          ${writeGitVendorEntries}
          ${replacePaths}
        '';

        cargoTestProfile = "release";
        cargoBuildProfile = "release";

        # Make sure cargo only builds & tests the package we want
        cargoBuildCommand = "cargo build \${cargoBuildFlags:-} --profile \${cargoBuildProfile} --package ${pname}";
        cargoTestCommand = "cargo test \${cargoTestFlags:-} --profile \${cargoTestProfile} --package ${pname}";
      };

      # The deps-only derivation will use this as a prefix to the `pname`
      depsNameSuffix = "-deps";
      depsArgs =
        common
        // {
          # we pass cargoLock path to buildDepsOnly
          # so that crane's mkDummySrc adds it to the dummy source
          inherit (utils) cargoLock;
          pnameSuffix = depsNameSuffix;
          # Make sure cargo only checks the package we want
          cargoCheckCommand = "cargo check \${cargoBuildFlags:-} --profile \${cargoBuildProfile} --package ${pname}";
          dream2nixVendorDir = vendoring.vendoredDependencies;
          preUnpack = ''
            ${vendoring.copyVendorDir "$dream2nixVendorDir" common.cargoVendorDir}
          '';
          # move the vendored dependencies folder to $out for main derivation to use
          postInstall = ''
            mv $TMPDIR/nix-vendor $out/nix-vendor
          '';
        };
      deps =
        produceDerivation
        "${pname}${depsNameSuffix}"
        (buildDepsWithToolchain {
          toolchain = defaultToolchain;
          args = depsArgs;
        });

      buildArgs =
        common
        // {
          meta = utils.getMeta pname version;
          cargoArtifacts = deps;
          # link the vendor dir we used earlier to the correct place
          preUnpack = ''
            ${vendoring.copyVendorDir "$cargoArtifacts/nix-vendor" common.cargoVendorDir}
          '';
          # write our cargo lock
          # note: we don't do this in buildDepsOnly since
          # that uses a cargoLock argument instead
          preConfigure = ''
            ${common.preConfigure}
            ${utils.writeCargoLock}
          '';
          passthru = {dependencies = deps;};
        };
      build =
        produceDerivation
        pname
        (buildPackageWithToolchain {
          toolchain = defaultToolchain;
          args = buildArgs;
        });
    in
      build;

    allPackages =
      l.mapAttrs
      (name: version: {"${version}" = buildPackage name version;})
      args.packages;

    mkShellForDrvs = drvs:
      pkgs.callPackage ../devshell.nix {
        name = "devshell";
        inherit drvs;
      };

    pkgShells =
      l.mapAttrs
      (
        name: version: let
          pkg = allPackages.${name}.${version};
        in
          mkShellForDrvs [pkg.passthru.dependencies pkg]
      )
      args.packages;

    allPackagesList = l.flatten (
      l.mapAttrsToList
      (
        name: version: let
          pkg = allPackages.${name}.${version};
        in [pkg.passthru.dependencies pkg]
      )
      args.packages
    );
  in {
    packages = allPackages;
    devShells =
      pkgShells
      // {
        default = mkShellForDrvs allPackagesList;
      };
  };
}
