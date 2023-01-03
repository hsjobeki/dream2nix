{
  name,
  dlib,
  lib,
  ...
}: let
  l = lib // builtins;
in {
  type = "pure";

  generateUnitTestsForProjects = [
    (builtins.fetchTarball {
      url = "https://github.com/BurntSushi/ripgrep/tarball/30ee6f08ee8e22c42ab2ef837c764f52656d025b";
      sha256 = "1g73qfc6wm7d70pksmbzq714mwycdfx1n4vfrivjs7jpkj40q4vv";
    })
    (builtins.fetchTarball {
      url = "https://github.com/yusdacra/cargo-basic-git/tarball/ba781213ed1c0e653c3247ab339cc84bda9d0337";
      sha256 = "08fs64gm7r5l5pipn78lkkzdkalysk0c7hx5b1bcqdq99lbdhpbp";
    })
  ];

  translate = {
    project,
    tree,
    ...
  }: let
    # get the root source and project source
    rootTree = tree;
    projectTree = rootTree.getNodeFromPath project.relPath;
    rootSource = rootTree.fullPath;
    projectSource = dlib.sanitizePath "${rootSource}/${project.relPath}";
    subsystemInfo = project.subsystemInfo or {};
    # pull all crates from subsystemInfo, if not find all of them
    # this is mainly helpful when `projects` is defined manually in which case
    # crates won't be available, so we will reduce burden on the user here.
    allCrates =
      subsystemInfo.crates
      or (
        (import ../../findAllCrates.nix {inherit lib dlib;})
        {tree = rootTree;}
      );

    # Get the root toml
    rootToml = {
      relPath = project.relPath;
      value = projectTree.files."Cargo.toml".tomlContent;
    };

    # use workspace members from discover phase
    # or discover them again ourselves
    workspaceMembers =
      subsystemInfo.workspaceMembers
      or (
        l.flatten
        (
          l.map
          (
            memberName: let
              components = l.splitString "/" memberName;
            in
              # Resolve globs if there are any
              if l.last components == "*"
              then let
                parentDirRel = l.concatStringsSep "/" (l.init components);
                dirs = (rootTree.getNodeFromPath parentDirRel).directories;
              in
                l.mapAttrsToList
                (name: _: "${parentDirRel}/${name}")
                dirs
              else memberName
          )
          (rootToml.value.workspace.members or [])
        )
      );
    # Get cargo packages (for workspace members)
    workspaceCargoPackages =
      l.map
      (relPath: {
        inherit relPath;
        value = (projectTree.getNodeFromPath "${relPath}/Cargo.toml").tomlContent;
      })
      # Filter root referencing member, we already parsed this (rootToml)
      (l.filter (relPath: relPath != ".") workspaceMembers);

    # All cargo packages that we will output
    cargoPackages =
      if l.hasAttrByPath ["package" "name"] rootToml.value
      # Note: the ordering is important here, since packageToml assumes
      # the rootToml to be at 0 index (if it is a package)
      then [rootToml] ++ workspaceCargoPackages
      else workspaceCargoPackages;

    # Get a "main" package toml
    packageToml = l.elemAt cargoPackages 0;

    # Parse Cargo.lock and extract dependencies
    parsedLock = projectTree.files."Cargo.lock".tomlContent;
    parsedDeps = parsedLock.package;

    # Gets a checksum from the [metadata] table of the lockfile
    getChecksum = dep: let
      key = "checksum ${dep.name} ${dep.version} (${dep.source})";
    in
      parsedLock.metadata."${key}";

    # map of dependency names to versions
    depNamesToVersions =
      l.listToAttrs
      (l.map (dep: l.nameValuePair dep.name dep.version) parsedDeps);
    # This parses a "package-name version" entry in the "dependencies"
    # field of a dependency in Cargo.lock
    parseDepEntryImpl = entry: let
      parsed = l.splitString " " entry;
      name = l.head parsed;
      maybeVersion =
        if l.length parsed > 1
        then l.elemAt parsed 1
        else null;
    in {
      inherit name;
      version =
        # If there is no version, search through the lockfile to
        # find the dependency's version
        if maybeVersion != null
        then maybeVersion
        else
          depNamesToVersions.${name}
          or (throw "no dependency found with name ${name} in Cargo.lock");
    };
    depNameVersionAttrs = let
      makePair = entry: l.nameValuePair entry (parseDepEntryImpl entry);
      depEntries = l.flatten (l.map (dep: dep.dependencies or []) parsedDeps);
    in
      l.listToAttrs (l.map makePair (l.unique depEntries));
    parseDepEntry = entry: depNameVersionAttrs.${entry};

    # Parses a git source, taken straight from nixpkgs.
    parseGitSourceImpl = src: let
      parts = builtins.match ''git\+([^?]+)(\?(rev|tag|branch)=(.*))?#(.*)'' src;
      type = builtins.elemAt parts 2; # rev, tag or branch
      value = builtins.elemAt parts 3;
    in
      if parts == null
      then null
      else
        {
          url = builtins.elemAt parts 0;
          sha = builtins.elemAt parts 4;
        }
        // (lib.optionalAttrs (type != null) {inherit type value;});
    parsedGitSources = let
      makePair = dep:
        l.nameValuePair
        "${dep.name}-${dep.version}"
        (parseGitSourceImpl (dep.source or ""));
    in
      l.listToAttrs (l.map makePair parsedDeps);
    parseGitSource = dep: parsedGitSources."${dep.name}-${dep.version}";

    # Extracts a source type from a dependency.
    getSourceTypeFromImpl = dependencyObject: let
      checkType = type: l.hasPrefix "${type}+" dependencyObject.source;
    in
      if !(l.hasAttr "source" dependencyObject)
      then "path"
      else if checkType "git"
      then "git"
      else if checkType "registry"
      then
        if dependencyObject.source == "registry+https://github.com/rust-lang/crates.io-index"
        then "crates-io"
        else throw "registries other than crates.io are not supported yet"
      else throw "unknown or unsupported source type: ${dependencyObject.source}";
    depSourceTypes = let
      makePair = dep:
        l.nameValuePair
        "${dep.name}-${dep.version}"
        (getSourceTypeFromImpl dep);
    in
      l.listToAttrs (l.map makePair parsedDeps);
    getSourceTypeFrom = dep: depSourceTypes."${dep.name}-${dep.version}";

    package = rec {
      toml = packageToml.value;
      name = toml.package.name;
      version =
        toml.package.version
        or (l.warn "no version found in Cargo.toml for ${name}, defaulting to unknown" "unknown");
    };
  in
    dlib.simpleTranslate2.translate
    ({...}: {
      translatorName = name;
      # relative path of the project within the source tree.
      location = project.relPath;

      # the name of the subsystem
      subsystemName = "rust";

      # Extract subsystem specific attributes.
      # The structure of this should be defined in:
      #   ./src/specifications/{subsystem}
      subsystemAttrs = {
        relPathReplacements = let
          # function to find path replacements for one package
          findReplacements = package: let
            # Extract dependencies from the Cargo.toml of the package
            tomlDeps =
              l.flatten
              (
                l.map
                (
                  target:
                    (l.attrValues (target.dependencies or {}))
                    ++ (l.attrValues (target.buildDependencies or {}))
                )
                ([package.value] ++ (l.attrValues (package.value.target or {})))
              );
            # We only need to patch path dependencies
            pathDeps = l.filter (dep: dep ? path) tomlDeps;
            # filter out path dependencies whose path are same as in workspace members.
            # this is because otherwise workspace.members paths will also get replaced in the build.
            # and there is no reason to replace these anyways since they are in the source.
            outsideDeps =
              l.filter
              (
                dep:
                  !(l.any (memberPath: dep.path == memberPath) workspaceMembers)
              )
              pathDeps;
            makeReplacement = dep: {
              name = dep.path;
              value = dlib.sanitizeRelativePath "${package.relPath}/${dep.path}";
            };
            replacements = l.listToAttrs (l.map makeReplacement outsideDeps);
            # filter out replacements which won't replace anything
            # this means that the path doesn't need to be replaced because it's
            # already in the source that we are building
            filtered =
              l.filterAttrs
              (
                n: v: ! l.pathExists (dlib.sanitizePath "${projectSource}/${v}")
              )
              replacements;
          in
            filtered;
          # find replacements for all packages we export
          allPackageReplacements =
            l.map
            (
              package: let
                pkg = package.value.package;
                replacements = findReplacements package;
              in {${pkg.name}.${pkg.version} = replacements;}
            )
            cargoPackages;
        in
          l.foldl' l.recursiveUpdate {} allPackageReplacements;
        gitSources = let
          gitDeps = l.filter (dep: (getSourceTypeFrom dep) == "git") parsedDeps;
        in
          l.unique (l.map (dep: parseGitSource dep) gitDeps);
        meta = l.foldl' l.recursiveUpdate {} (
          l.map
          (
            package: let
              pkg = package.value.package;
            in {
              ${pkg.name}.${pkg.version} =
                {license = dlib.parseSpdxId (pkg.license or "");}
                // (
                  l.filterAttrs
                  (n: v: l.any (on: n == on) ["description" "homepage"])
                  pkg
                );
            }
          )
          cargoPackages
        );
      };

      defaultPackage = package.name;

      /*
      List the package candidates which should be exposed to the user.
      Only top-level packages should be listed here.
      Users will not be interested in all individual dependencies.
      */
      exportedPackages = let
        makePair = p: let
          pkg = p.value.package;
        in
          l.nameValuePair pkg.name pkg.version;
      in
        l.listToAttrs (l.map makePair cargoPackages);

      /*
      a list of raw package objects
      If the upstream format is a deep attrset, this list should contain
      a flattened representation of all entries.
      */
      serializedRawObjects = parsedDeps;

      /*
      Define extractor functions which each extract one property from
      a given raw object.
      (Each rawObj comes from serializedRawObjects).

      Extractors can access the fields extracted by other extractors
      by accessing finalObj.
      */
      extractors = {
        name = rawObj: finalObj: rawObj.name;

        version = rawObj: finalObj: rawObj.version;

        dependencies = rawObj: finalObj:
          l.map parseDepEntry (rawObj.dependencies or []);

        sourceSpec = rawObj: finalObj: let
          sourceType = getSourceTypeFrom rawObj;
          sourceConstructors = {
            path = dependencyObject: let
              findCrate =
                l.findFirst
                (
                  crate:
                    (crate.name == dependencyObject.name)
                    && (crate.version == dependencyObject.version)
                )
                null;
              workspaceCrates =
                l.map
                (
                  pkg: {
                    inherit (pkg.value.package) name version;
                    inherit (pkg) relPath;
                  }
                )
                cargoPackages;
              workspaceCrate = findCrate workspaceCrates;
              nonWorkspaceCrate = findCrate allCrates;
            in
              if
                (package.name == dependencyObject.name)
                && (package.version == dependencyObject.version)
              then
                dlib.construct.pathSource {
                  path = project.relPath;
                  rootName = null;
                  rootVersion = null;
                }
              else if workspaceCrate != null
              then
                dlib.construct.pathSource {
                  path = workspaceCrate.relPath;
                  rootName = package.name;
                  rootVersion = package.version;
                }
              else if nonWorkspaceCrate != null
              then
                dlib.construct.pathSource {
                  path = nonWorkspaceCrate.relPath;
                  rootName = null;
                  rootVersion = null;
                }
              else throw "could not find crate '${dependencyObject.name}-${dependencyObject.version}'";

            git = dependencyObject: let
              parsed = parseGitSource dependencyObject;
              maybeRef =
                if parsed.type or null == "branch"
                then {ref = "refs/heads/${parsed.value}";}
                else if parsed.type or null == "tag"
                then {ref = "refs/tags/${parsed.value}";}
                else {};
            in
              maybeRef
              // {
                type = "git";
                url = parsed.url;
                rev = parsed.sha;
              };

            crates-io = dependencyObject: {
              type = "crates-io";
              hash = dependencyObject.checksum or (getChecksum dependencyObject);
            };
          };
        in
          sourceConstructors."${sourceType}" rawObj;
      };
    });

  version = 2;

  # If the translator requires additional arguments, specify them here.
  # When users run the CLI, they will be asked to specify these arguments.
  # There are only two types of arguments:
  #   - string argument (type = "argument")
  #   - boolean flag (type = "flag")
  # String arguments contain a default value and examples. Flags do not.
  extraArgs = {};
}
