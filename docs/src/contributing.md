# dream2nix contributers guide

## Initialize a new Subsystem

To add a new subsystem follow the steps below:

1. [initialize a new translator](#Initialize-a-new-translator)
2. [Initialize a new builder](#Initialize-a-new-builder)

Then you need to add you newly created subsystem here:

[src/modules/builders/implementation.nix](https://github.com/nix-community/dream2nix/blob/main/src/modules/builders/implementation.nix)

```nix
{config, ...}: let
  lib = config.lib;
  defaults = {
    rust = "build-rust-package";
    nodejs = "granular-nodejs";
    python = "simple-python";
    php = "granular-php";
    haskell = "simple-haskell";
    debian = "simple-debian";
    racket = "simple-racket";
    # add your newly created subsystem here.
    # e.g. src/subsystems/{SUBSYSTEM_NAME}/builders/{BUILDER_NAME}/default.nix
    SUBSYSTEM_NAME  = "BUILDER_NAME"; 

  };
   #   ...

```

## Adding a new Translator

In general there are 3 different types of translators

1. pure translator

   - translation logic is implemented in nix lang only
   - does not invoke build or read from any build output

2. pure translator utilizing IFD (import from derivation)

   - part of the logic is integrated as a nix build
   - nix code is used to invoke a nix build and parse its results
   - same interface as pure translator

3. impure

   - translator can be any executable program running outside of a nix build
   - not constrained in any way (can do arbitrary network access etc.)

### Initialize the translator

Clone dream2nix repo and execute:
```shell
nix run .#contribute
```
... then select `translator` and answer all questions. This will generate a template.

This will create the following file

`src/subsystems/{SUBSYSTEM_NAME}/translators/{TRANSLATOR_NAME}/default.nix`

Further instructions are contained in the template in form of code comments.

A dead simple translator returns at least the generic dream-lock-schema which can be found here [`src/specificiations/dream-lock-schema.json`](https://github.com/nix-community/dream2nix/blob/main/src/specifications/dream-lock-schema.json)

```nix

{
  dlib,
  lib,
  ...
}: let
  l = lib // builtins;
in {
  type = "pure";

  generateUnitTestsForProjects = [
    (builtins.fetchTarball {
      url = "github:your example repo";
      sha256 = "sha256";
    })
  ];

  discoverProject = tree:
    l.any
    (filename: l.hasSuffix "lock.json" filename)
    (l.attrNames tree.files);

  # translate from a given source and a project specification to a dream-lock.
  translate = {
    project,
    source,
    tree,
    ...
  } @ args: let
    # get the root source and project source
    rootSource = tree.fullPath;
    projectSource = "${tree.fullPath}/${project.relPath}";
    projectTree = tree.getNodeFromPath project.relPath;

    # parse the json / toml etc.
    lockJson = (projectTree.getNodeFromPath "lock.json").jsonContent;

  # Your `translate` should return at least those two sets
  # `_generic` and `sources` 
  # for a full translator look refer to the full template 
  in {
    _generic = {
      defaultPackage = "default-package";
      # at least the default packge name should be returned with an arbitrary name
      packages = {
        "default-package" = "some-attr-from-project-metadata-file";
      };
      subsystem = "my-subsystem";
    }; 

    sources = {
      "package-A" = {
         url = "http://example.com";
         hash = "sha256:123";
         type = "http";
      }
    }
  };
}

```

### First run of the new translator

Before you can run the translator it is currently neccessary to add a `simple builder` too. Otherwise it is not possible to build or discover attributes.

1. Create an example project and upload it to github
2. Create an example flake in the `examples/` (copy one of the existing flakes and point to your github project)
3. in `examples/your-example` run `nix flake show --override-input dream2nix ../../.` to discover the possible outputs and if your translator is valid
4. in `examples/your-example` run `nix build .# --override-input dream2nix ../../.` to build your package. A folder with the generic lockfile inside it will be created.

### Unit tests (pure translators only)

Unit tests will automatically be generated as soon as your translator specifies `generateUnitTestsForProjects`.
Unit tests can be executed via `nix run .#tests-unit`

### Repl debugging

- temporarily expose internal functions of your translator
- use nix repl `nix repl ./.`
- invoke a function via
   `subsystems.{subsystem}.translators.{translator-name}.some_function`

### Tested example flake

Add an example flake under `./examples/name-of-example`.
The flake can be tested via:
```shell
nix run .#tests-examples name-of-example --show-trace
```
The flake will be tested in the CI-pipeline as well.

---

## Initialize a new builder

Clone dream2nix repo and execute:
```shell
nix run .#contribute
```
... then select `builder` and answer all questions. This will generate a template.

#### ! Important: the builder should output a valid package / module of your subsystem to allow for other projects to consume your ouput. e.g. a nodejs subsystem ouputs a valid node module.


Further instructions are contained in the template in form of code comments.

## Debug or test a builder

### Tested example flake

Add an example flake under `./examples/name-of-example`.
The flake can be tested via:
```shell
nix run .#tests-examples name-of-example --show-trace
```
The flake will be tested in the CI-pipeline as well.
