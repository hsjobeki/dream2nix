{
  pkgs,
  lib,
  ...
}: {
  type = "pure";

  build = let
    inherit
      (pkgs)
      jq
      makeWrapper
      mkShell
      python3
      runCommandLocal
      stdenv
      bash
      ;
  in
    {
      # Funcs
      # AttrSet -> Bool) -> AttrSet -> [x]
      # getCyclicDependencies, # name: version: -> [ {name=; version=; } ]
      getDependencies, # name: version: -> [ {name=; version=; } ]
      getSource, # name: version: -> store-path
      # Attributes
      subsystemAttrs, # attrset
      defaultPackageName, # string
      # defaultPackageVersion, # string
      packages, # list
      # attrset of pname -> versions,
      # where versions is a list of version strings
      packageVersions,
      # function which applies overrides to a package
      # It must be applied by the builder to each individual derivation
      # Example:
      #   produceDerivation name (mkDerivation {...})
      produceDerivation,
      nodejs ? null,
      ...
    } @ args: let
      b = builtins;
      l = lib // builtins;

      # get nodejsversion from subsystemAttrs (user may have given custom value)
      nodejsVersion = subsystemAttrs.nodejsVersion;

      # function that checks if the building package is the root package, that the user wanted to build in the first place.
      isMainPackage = name: version:
        (args.packages."${name}" or null) == version;

      # get the nodejs runtime from pkgs
      nodejs =
        if args ? nodejs
        then b.toString args.nodejs
        else
          pkgs."nodejs-${nodejsVersion}_x"
          or (throw "Could not find nodejs version '${nodejsVersion}' in pkgs");

      # extract nodejs archive and move all node binarys to $out
      nodeSources = runCommandLocal "node-sources" {} ''
        tar --no-same-owner --no-same-permissions -xf ${nodejs.src}
        mv node-* $out
      '';

      # {
      #
      # }
      #
      #
      allPackages =
        # key: value: -> newValue
        lib.mapAttrs
        (name: versions:
          lib.genAttrs
          versions
          (version:
            makePackage name version))
        packageVersions;

      outputs = rec {
        # select only the packages listed in dreamLock as main packages
        packages =
          b.foldl'
          (ps: p: ps // p)
          {}
          (lib.mapAttrsToList
            (name: version: {
              "${name}"."${version}" = allPackages."${name}"."${version}";
            })
            args.packages);

        devShells =
          {default = devShells.${defaultPackageName};}
          // (
            l.mapAttrs
            (name: version: allPackages.${name}.${version}.devShell)
            args.packages
          );
      };

      # This is only executed for electron based packages.
      # Electron ships its own version of node, requiring a rebuild of native
      # extensions.
      # Theoretically this requires headers for the exact electron version in use,
      # but we use the headers from nixpkgs' electron instead which might have a
      # different minor version.
      # Alternatively the headers can be specified via `electronHeaders`.
      # Also a custom electron version can be specified via `electronPackage`
      electron-rebuild = ''
        # prepare node headers for electron
        if [ -n "$electronPackage" ]; then
          export electronDist="$electronPackage/lib/electron"
        else
          export electronDist="$nodeModules/$packageName/node_modules/electron/dist"
        fi
        local ver
        ver="v$(cat $electronDist/version | tr -d '\n')"
        mkdir $TMP/$ver
        cp $electronHeaders $TMP/$ver/node-$ver-headers.tar.gz

        # calc checksums
        cd $TMP/$ver
        sha256sum ./* > SHASUMS256.txt
        cd -

        # serve headers via http
        python -m http.server 45034 --directory $TMP &

        # copy electron distribution
        cp -r $electronDist $TMP/electron
        chmod -R +w $TMP/electron

        # configure electron toolchain
        ${pkgs.jq}/bin/jq ".build.electronDist = \"$TMP/electron\"" package.json \
            | ${pkgs.moreutils}/bin/sponge package.json

        ${pkgs.jq}/bin/jq ".build.linux.target = \"dir\"" package.json \
            | ${pkgs.moreutils}/bin/sponge package.json

        ${pkgs.jq}/bin/jq ".build.npmRebuild = false" package.json \
            | ${pkgs.moreutils}/bin/sponge package.json

        # execute electron-rebuild if available
        export headers=http://localhost:45034/
        if command -v electron-rebuild &> /dev/null; then
          pushd $electronAppDir

          electron-rebuild -d $headers
          popd
        fi
      '';

      # Generates a derivation for a specific package name + version
      makePackage = name: version: let
        pname = lib.replaceStrings ["@" "/"] ["__at__" "__slash__"] name;

        deps = getDependencies name version;

        nodeDeps =
          lib.forEach
          deps
          (dep: allPackages."${dep.name}"."${dep.version}");

        passthruDeps =
          l.listToAttrs
          (l.forEach deps
            (dep:
              l.nameValuePair
              dep.name
              allPackages."${dep.name}"."${dep.version}"));

        dependenciesJson =
          b.toJSON
          (lib.listToAttrs
            (b.map
              (dep: lib.nameValuePair dep.name dep.version)
              deps));

        electronDep =
          if ! isMainPackage name version
          then null
          else
            lib.findFirst
            (dep: dep.name == "electron")
            null
            deps;

        electronVersionMajor =
          lib.versions.major electronDep.version;

        electronHeaders =
          if
            (electronDep == null)
            # hashes seem unavailable for electron < 4
            || ((l.toInt electronVersionMajor) <= 2)
          then null
          else pkgs."electron_${electronVersionMajor}".headers;

        pkg = produceDerivation name (stdenv.mkDerivation rec {
          inherit
            dependenciesJson
            electronHeaders
            nodeDeps
            nodeSources
            version
            ;

          packageName = name;

          # sanitized name
          inherit pname;

          installPhase = import ./installPhase.nix {
            inherit lib pkgs;
          };

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
          runBuild = isMainPackage name version;
          src = getSource name version;
          nativeBuildInputs = [makeWrapper];
          buildInputs = [jq nodejs python3];

          # set env variables
          passAsFile = ["dependenciesJson" "nodeDeps"];

          buildScript = null;

          fixPackage = "${./fix-package.py}";

          installDeps = "${./install-deps.py}";

          linkBins = "${./link-bins.py}";

          dontStrip = true;

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

          nodeDepsStr = l.toString nodeDeps;
          configurePhase = ''
            runHook preConfigure

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

            # not needed anymore
            # # configure typescript
            # if [ -f ./tsconfig.json ] \
            #     && node -e 'require("typescript")' &>/dev/null; then
            #   node ./tsconfig-to-json.js
            #   ${pkgs.jq}/bin/jq ".compilerOptions.preserveSymlinks = true" tsconfig.json \
            #       | ${pkgs.moreutils}/bin/sponge tsconfig.json
            # fi


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
        });
      in
        pkg;
    in
      outputs;
}
