{
  pkgs,
  lib,
  dependenciesJson,
  electronHeaders,
  nodeDeps,
  nodeSources,
  version,
  name,
  pname,
  subsystemAttrs,
  getSource,
  passthruDeps,
  ...
} @ args: let
  inherit (pkgs) stdenv makeWrapper mkShell;
  b = builtins;
  l = lib // builtins;
in
  stdenv.mkDerivation rec {
    inherit
      dependenciesJson
      electronHeaders
      nodeDeps
      nodeSources
      version
      ;

    packageName = name;

    inherit pname;

    meta = let
      meta = subsystemAttrs.meta;
    in
      meta
      // {
        license = l.map (name: l.licenses.${name}) meta.license;
      };

    passthru.dependencies = passthruDeps;

    passthru.devShell = import ./devShell.nix {
      inherit
        mkShell
        nodejs
        packageName
        pkg
        ;
    };

    /*
    For top-level packages install dependencies as full copies, as this
    reduces errors with build tooling that doesn't cope well with
    symlinking.
    */
    installMethod =
      if isMainPackage name version
      then "copy"
      else "symlink";

    electronAppDir = ".";

    # only run build on the main package
    runBuild = isMainPackage name version;

    src = getSource name version;

    nativeBuildInputs = [makeWrapper];

    buildInputs = [jq nodejs python3];

    # prevents running into ulimits
    passAsFile = ["dependenciesJson" "nodeDeps"];

    preConfigurePhases = ["d2nLoadFuncsPhase" "d2nPatchPhase"];

    # can be overridden to define alternative install command
    # (defaults to 'npm run postinstall')
    buildScript = null;

    # python script to modify some metadata to support installation
    # (see comments below on d2nPatchPhase)
    fixPackage = "${./fix-package.py}";

    # script to install (symlink or copy) dependencies.
    installDeps = "${./install-deps.py}";

    # python script to link bin entries from package.json
    linkBins = "${./link-bins.py}";

    # costs performance and doesn't seem beneficial in most scenarios
    dontStrip = true;

    # declare some useful shell functions
    d2nLoadFuncsPhase = ''
      # function to resolve symlinks to copies
      symlinksToCopies() {
        local dir="$1"

        echo "transforming symlinks to copies..."
        for f in $(find -L "$dir" -xtype l); do
          if [ -f $f ]; then
            continue
          fi
          echo "copying $f"
          chmod +wx $(dirname "$f")
          mv "$f" "$f.bak"
          mkdir "$f"
          if [ -n "$(ls -A "$f.bak/")" ]; then
            cp -r "$f.bak"/* "$f/"
            chmod -R +w $f
          fi
          rm "$f.bak"
        done
      }
    '';

    # TODO: upstream fix to nixpkgs
    # example which requires this:
    #   https://registry.npmjs.org/react-window-infinite-loader/-/react-window-infinite-loader-1.0.7.tgz
    unpackCmd =
      if lib.hasSuffix ".tgz" src
      then "tar --delay-directory-restore -xf $src"
      else null;

    unpackPhase = ''
      runHook preUnpack

      nodeModules=$(realpath ./package)

      export sourceRoot="$nodeModules/$packageName"

      # sometimes tarballs do not end with .tar.??
      unpackFallback(){
        local fn="$1"
        tar xf "$fn"
      }

      unpackCmdHooks+=(unpackFallback)

      unpackFile $src

      # Make the base dir in which the target dependency resides in first
      mkdir -p "$(dirname "$sourceRoot")"

      # install source
      if [ -f "$src" ]
      then
          # Figure out what directory has been unpacked
          packageDir="$(find . -maxdepth 1 -type d | tail -1)"

          # Restore write permissions
          find "$packageDir" -type d -exec chmod u+x {} \;
          chmod -R u+w -- "$packageDir"

          # Move the extracted tarball into the output folder
          mv -- "$packageDir" "$sourceRoot"
      elif [ -d "$src" ]
      then
          strippedName="$(stripHash $src)"

          # Restore write permissions
          chmod -R u+w -- "$strippedName"

          # Move the extracted directory into the output folder
          mv -- "$strippedName" "$sourceRoot"
      fi

      runHook postUnpack
    '';

    # The python script wich is executed in this phase:
    #   - ensures that the package is compatible to the current system
    #   - ensures the main version in package.json matches the expected
    #   - pins dependency versions in package.json
    #     (some npm commands might otherwise trigger networking)
    #   - creates symlinks for executables declared in package.json
    # Apart from that:
    #   - Any usage of 'link:' in package.json is replaced with 'file:'
    #   - If package-lock.json exists, it is deleted, as it might conflict
    #     with the parent package-lock.json.
    d2nPatchPhase = ''
      # delete package-lock.json as it can lead to conflicts
      rm -f package-lock.json

      # repair 'link:' -> 'file:'
      mv $nodeModules/$packageName/package.json $nodeModules/$packageName/package.json.old
      cat $nodeModules/$packageName/package.json.old | sed 's!link:!file\:!g' > $nodeModules/$packageName/package.json
      rm $nodeModules/$packageName/package.json.old

      # run python script (see comment above):
      cp package.json package.json.bak
      python $fixPackage \
      || \
      # exit code 3 -> the package is incompatible to the current platform
      #  -> Let the build succeed, but don't create lib/node_modules
      if [ "$?" == "3" ]; then
        mkdir -p $out
        echo "Not compatible with system $system" > $out/error
        exit 0
      else
        exit 1
      fi

      # configure typescript
      if [ -f ./tsconfig.json ] \
          && node -e 'require("typescript")' &>/dev/null; then
        node ${./tsconfig-to-json.js}
        ${pkgs.jq}/bin/jq ".compilerOptions.preserveSymlinks = true" tsconfig.json \
            | ${pkgs.moreutils}/bin/sponge tsconfig.json
      fi
    '';

    # - installs dependencies into the node_modules directory
    # - adds executables of direct node module dependencies to PATH
    # - adds the current node module to NODE_PATH
    # - sets HOME=$TMPDIR, as this is required by some npm scripts
    # TODO: don't install dev dependencies. Load into NODE_PATH instead
    nodeDepsStr = l.toString nodeDeps;

    configurePhase = ''
      runHook preConfigure
      # symlink sub dependencies as well as this imitates npm better
      python ${installDeps}
      echo "Symlinking transitive executables to $nodeModules/.bin"
      for dep in ${nodeDepsStr}; do
        binDir=$dep/lib/node_modules/.bin
        if [ -e $binDir ]; then
          for bin in $(ls $binDir/); do\
            if [ ! -e $nodeModules/.bin ]; then
              mkdir -p $nodeModules/.bin
            fi
            # symlink might have been already created by install-deps.py
            # if installMethod=copy was selected
            if [ ! -L $nodeModules/.bin/$bin ]; then
              ln -s $binDir/$bin $nodeModules/.bin/$bin
            else
              echo "won't overwrite existing symlink $nodeModules/.bin/$bin. current target: $(readlink $nodeModules/.bin/$bin)"
            fi
          done
        fi
      done
      # add bin path entries collected by python script
      export PATH="$PATH:$nodeModules/.bin"
      # add dependencies to NODE_PATH
      export NODE_PATH="$NODE_PATH:$nodeModules/$packageName/node_modules"
      export HOME=$TMPDIR
      runHook postConfigure
    '';

    # configurePhase = builtins.readFile (pkgs.writeShellApplication {
    #   name = "linker";
    #   text = builtins.readFile ./new-configure-phase.sh;
    # })/bin/linker;

    # Runs the install command which defaults to 'npm run postinstall'.
    # Allows using custom install command by overriding 'buildScript'.
    buildPhase = ''
      runHook preBuild

      # execute electron-rebuild
      if [ -n "$electronHeaders" ]; then
        echo "executing electron-rebuild"
        ${electron-rebuild}
      fi

      # execute install command
      if [ -n "$buildScript" ]; then
        if [ -f "$buildScript" ]; then
          $buildScript
        else
          eval "$buildScript"
        fi
      # by default, only for top level packages, `npm run build` is executed
      elif [ -n "$runBuild" ] && [ "$(jq '.scripts.build' ./package.json)" != "null" ]; then
        npm run build
      else
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

      runHook postBuild
    '';

    # Symlinks executables and manual pages to correct directories
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib
      cp -r $nodeModules $out/lib/node_modules
      nodeModules=$out/lib/node_modules
      cd "$nodeModules/$packageName"

      echo "Symlinking bin entries from package.json"
      python $linkBins

      echo "Symlinking manual pages"
      if [ -d "$nodeModules/$packageName/man" ]
      then
        mkdir -p $out/share
        for dir in "$nodeModules/$packageName/man/"*
        do
          mkdir -p $out/share/man/$(basename "$dir")
          for page in "$dir"/*
          do
              ln -s $page $out/share/man/$(basename "$dir")
          done
        done
      fi

      # wrap electron app
      if [ -n "$electronHeaders" ]; then
        echo "Wrapping electron app"
        ${electron-wrap}
      fi

      runHook postInstall
    '';
  }
