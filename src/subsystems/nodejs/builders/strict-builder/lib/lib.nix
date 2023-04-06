{
  lib,
  tree,
}: let
  b = builtins;
  l = lib // b;

  debug = msg: val: (l.trace "${msg}: ${(l.toJSON val)}" val);

  collectAll = {
    path ? [],
    set,
  }: let
    accumulate = acc: {
      name,
      value,
    }: let
      version = b.head (b.attrNames value);
      inherit (value.${version}) deps derivation;
      # pre-populate directDependencies
      # the resolve algorithm will check for conflicts with directDependencies and add "hoistedDependencies" if possible
      # hoisting is only possible without namespace collisions therefore we need to track those.
      directDependencies =
        lib.mapAttrsToList (depName: depValue: {
          name = depName;
          version = b.head (b.attrNames depValue);
        })
        deps;
      atom = {
        all = [{inherit name version path derivation directDependencies;}];
        versions =
          acc.versions
          or {}
          // {
            ${name} = l.unique ((acc.versions.${name} or []) ++ [version]);
          };
      };
      hasDependenciesThen = th: el:
        if b.attrNames value != [] && b.attrNames deps != []
        then th
        else el;

      attrsInSet =
        hasDependenciesThen (collectAll {
          path = path ++ [{inherit name version;}];
          set = deps;
        })
        atom;
    in {
      all = acc.all or [] ++ attrsInSet.all ++ (hasDependenciesThen atom.all []);
      versions =
        acc.versions
        or {}
        // attrsInSet.versions or {}
        // {
          ${name} = l.unique (acc.versions.${name} or [] ++ attrsInSet.versions.${name} or [] ++ (hasDependenciesThen [version] []));
        };
    };
  in
    b.foldl' accumulate {} (l.mapAttrsToList (name: value: l.nameValuePair name value) set);

  # mapAttrsToList = f: set: (b.map (name: f name set.${name}) (b.attrNames set));
  /*
  Example:

  The following dependency tree:

  User -> b@1.0.0 -> c@1.0.0

  should result in

  {
    "all": [
      {
        "derivation": "/nix/store/<hash>c-1.0.0-lib",
        "name": "c",
        "path": [
          { "name": "b", "version": "1.0.0" }
        ],
        "version": "1.0.0"
      },
      {
        "derivation": "/nix/store/<hash>b-1.0.0-lib",
        "name": "b",
        "version": "1.0.0"
        "path": [],
      }
    ],
    "versions": {
      "c": ["1.0.0"]
      "b": ["1.0.0"]
    }
  }

  Type:
    {
      all: [
        {
          derivation :: String;
          name :: String;
          version :: String;
          path :: [
            { name :: String; version :: String;}
          ];
        }
      ]
      versions: {
        ${pname} :: [ String ];
      }
    }
  */
  dependencyCollection =
    (collectAll {set = tree;})
    // {
      /*
      Type: {name::String, version::String} -> Int
      */
      countRef = {
        name,
        version,
      }:
        b.foldl' (
          count: v:
            if name == v.name && version == v.version
            then count + 1
            else count
        )
        0
        dependencyCollection.all;
      /*
        from that collection of dependencies we can now determine the optimal root packages.
        for every package that exists in more than one version we can count the references in the tree.
        1. choose the package with higher reference count.
        2. no version has higher reference count; choose highest semver.

      Type:
      {
        ${pname} :: {
          ${version} :: Int
        }
      }
      */
      conflictVersions = l.filterAttrs (name: vs: b.length vs > 1) dependencyCollection.versions or {};
      referenceCount =
        b.foldl' (
          acc: {
            name,
            value,
          }: let
            versions =
              b.foldl' (
                vs: version:
                  vs // {${version} = dependencyCollection.countRef {inherit name version;};}
              ) {}
              value;
          in
            acc
            // {
              ${name} = versions;
            }
        ) {} (b.map (name: {
          inherit name;
          value = dependencyCollection.conflictVersions.${name};
        }) (b.attrNames dependencyCollection.conflictVersions));

      /*
      returns all root versions of the current collection.
      count defaults to -1 if there where no conflicts
      otherwise count the references to resolve the optimal tree.

      Type:
        {
          ${pname} :: {
            version :: String;
            count :: -1 | Int;
          }
        }
      */
      rootVersions =
        b.mapAttrs (
          name: vs: {
            # we can safely asume this is only one version as we already checked that
            version = b.head vs;
            count = -1;
          }
        ) (l.filterAttrs (name: vs: b.length vs == 1) dependencyCollection.versions or {})
        # add resolved conflicts
        // b.foldl' (
          acc: {
            name,
            value,
          }: let
            /*
              Takes a set of versions with counted references
              Returns either the version with highest reference count
              or (in case of equal reference count)
              the highest semantic version.
            Example:
              chooseVersion { "2.0.0" = 2; "3.0.0" = 1; }
              -> { count = 2; version = "2.0.0"; }

              chooseVersion { "2.0.0" = 1; "3.0.0" = 1; }
              -> { count = 1; version = "3.0.0"; }
            Type:
              chooseVersion :: { ${version} :: Int } -> { version :: String, count :: Int}
            */
            chooseVersion = vs:
              b.foldl' (
                resolved: {
                  version,
                  count,
                }:
                  if (resolved.count or 0) < count
                  then # update
                    resolved // {inherit version count;}
                  else if (resolved.count or 0) == count && (b.compareVersions resolved.version version) < 0
                  then resolved // {inherit version count;} # update if semver is newer
                  else resolved
              ) {} (b.map (version: {
                inherit version;
                count = value.${version};
              }) (b.attrNames value));
          in
            acc
            // {
              ${name} = chooseVersion value;
            }
        ) {} (b.map (name: {
          inherit name;
          value = dependencyCollection.referenceCount.${name};
        }) (b.attrNames dependencyCollection.referenceCount));
    };

  # for every version find the right place
  # if version is root version -> trivial -> {prefix}/node_modules
  # else
  # check "private dependencies of the highest parent"
  # if there are no conflicts, add it to the "private dependencies" and call "resolveConflicts" with updated {prefix}
  # else take the next parent in chain. -> Remove the highest parent from the list for next recursion.
  # call resolveConlicts again with the updated highest parent.

  resolveAll = {
    all,
    rootVersions,
  }: let
    resolve = {
      rootVersions,
      parent,
    }: acc: pkg: let
      addNodePath = {
        all,
        name,
        version,
        parent,
      }:
        b.map (
          package:
            package
            // (
              if package.name == name && package.version == version
              then {
                nodePath = {inherit (parent) name version;};
              }
              else if package.name == parent.name && package.version == parent.version
              then {
                hoistedDependencies = package.hoistedDependencies or [] ++ [{inherit name version;}];
              }
              else {}
            )
        )
        all;

      topMostParent =
        if pkg.path == []
        then {}
        else let
          matchingPkgs =
            b.filter
            (
              a: let
                inherit (b.head pkg.path) name version;
              in
                a.name == name && a.version == version
            )
            all;
        in
          if matchingPkgs == []
          then {}
          else b.head matchingPkgs;

      parentRootVersions = b.foldl' (acc: e:
        acc
        // {
          ${e.name} = {
            count = -1;
            inherit (e) version;
          };
        }) {} (topMostParent.privateDependencies or [] ++ topMostParent.hoistedDependencies or []);

      resolvedConflict =
        resolve {
          rootVersions =
            parentRootVersions
            // {
              ${pkg.name} = {
                count = -1;
                version = pkg.version;
              };
            };
          parent = topMostParent;
        }
        acc (pkg
          // {
            path =
              if b.length pkg.path > 1
              then b.tail pkg.path
              else pkg.path;
          });

      resolveNext =
        resolve {
          rootVersions = parentRootVersions;
          parent = topMostParent;
        }
        acc (pkg
          // {
            path =
              if b.length pkg.path > 1
              then b.tail pkg.path
              else pkg.path;
          });

      res =
        if (rootVersions ? ${pkg.name} && pkg.version == rootVersions.${pkg.name}.version && parent ? name)
        then
          addNodePath {
            all = acc;
            parent = parent;
            inherit (pkg) name version;
          }
        else
          (
            if b.all (d: d.name != pkg.name) topMostParent.directDependencies
            then
              /*
              no direct dependency on the package -> we can hoist it here
              */
              resolvedConflict
            else if b.any (d: d.name == pkg.name && d.version == pkg.version) topMostParent.directDependencies
            then resolvedConflict
            else resolveNext
            /*
            direct dependency, we need to check the version too, if it is different we cannot hoist
            */
            # abrt resolve {rootVersions=newRootVersions; parent=topMostParent;} acc pkg
            # acc
          );
    in
      res;
  in
    b.foldl' (resolve (debug "arg0" {
      parent = {
        name = "";
        version = "";
      };
      inherit (dependencyCollection) rootVersions;
    }))
    (debug "all" all)
    all;

  /*
  Type:
    {
      name :: String;
      version :: String;
      path :: [
        {
          name :: String;
          version :: String;
        }
      ];
      rootVersions: {
        ${pname} :: {
          count :: Int
          version :: String
        }
      }
    }
    ->
    String
  */
  choosePath = {
    name,
    version,
    path,
    rootVersions,
  }:
    if rootVersions.${name}.version == version
    then "node_modules/"
    else "node_modules/" + l.concatStringsSep "/node_modules/" (l.catAttrs "name" path);

  mkFolderStructure = {
    path ? [],
    set,
  }: let
    accumulate = acc: {
      name,
      value,
    }: let
      version = b.head (b.attrNames value);
      inherit (value.${version}) deps derivation;
      atom = {
        ${name} = {
          inherit version derivation;
          path = choosePath {
            inherit name version path;
            inherit (dependencyCollection) rootVersions;
          };
        };
      };

      attrsInSet =
        if b.attrNames value != [] && b.attrNames deps != []
        then
          # recurse if there are more deps
          mkFolderStructure {
            path = path ++ [{inherit name version;}];
            set = deps;
          }
        # otherwise return the leaf
        else atom;
    in
      acc
      // attrsInSet
      // (
        if b.attrNames value != [] && b.attrNames deps != []
        then atom
        else {}
      );
  in
    b.foldl' accumulate {} (b.map (name: {
      inherit name;
      value = set.${name};
    }) (b.attrNames set));

  resolved =
    if dependencyCollection ? all
    then resolveAll {inherit (dependencyCollection) all rootVersions;}
    else [];

  testSet = {
    dependencyCollection = l.filterAttrs (n: v: n != "countRef") dependencyCollection;
    inherit resolved;
  };
  test = builtins.toFile "out" (builtins.toJSON testSet);

  folder = builtins.toFile "out" (builtins.toJSON (mkFolderStructure {set = tree;}));

  packageVersions = l.mapAttrs (n: v: [v.version]) dependencyCollection.rootVersions;
in {
  inherit collectAll test dependencyCollection folder packageVersions resolved;
}
