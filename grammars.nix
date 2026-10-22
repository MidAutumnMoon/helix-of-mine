{
  stdenv,
  lib,
  fetchurl,
  includeGrammarIf ? _: true,
  grammarOverlays ? [],
  ...
}: let
  languagesConfig =
    builtins.fromTOML (builtins.readFile ./languages.toml);
  grammarPins =
    builtins.fromJSON (builtins.readFile ./grammar-sources.json);
  isGitGrammar = grammar:
    builtins.hasAttr "source" grammar
    && builtins.hasAttr "git" grammar.source
    && builtins.hasAttr "rev" grammar.source;
  # Throw rather than fetch at eval time: an unpinned or stale grammar must
  # fail loudly instead of blocking evaluation on the network.
  pinFor = grammar:
    if grammarPins ? ${grammar.name}
    && grammarPins.${grammar.name}.rev == grammar.source.rev
    && grammarPins.${grammar.name}.git == grammar.source.git
    then grammarPins.${grammar.name}
    else throw ''
      helix: grammar '${grammar.name}' (${grammar.source.git}) has no pin at
      rev ${grammar.source.rev} in grammar-sources.json.
      Run contrib/update-grammar-sources.sh to regenerate the pins.
    '';
  # If `use-grammars.only` is set, use only those grammars.
  # If `use-grammars.except` is set, use all other grammars.
  # Otherwise use all grammars.
  useGrammar = grammar:
    if languagesConfig ? use-grammars.only
    then builtins.elem grammar.name languagesConfig.use-grammars.only
    else if languagesConfig ? use-grammars.except
    then !(builtins.elem grammar.name languagesConfig.use-grammars.except)
    else true;
  grammarsToUse = builtins.filter useGrammar languagesConfig.grammar;
  gitGrammars = builtins.filter isGitGrammar grammarsToUse;
  grammarsToBuild = builtins.filter includeGrammarIf gitGrammars;

  # A grammar spec is the build recipe input: where the unpacked source tree
  # lives (a fetchurl FOD, referenced lazily so stale pins of excluded
  # grammars never throw) and where in it the parser sits. Overlays extend
  # and replace specs, not derivations; a value without a `source` attr
  # (null) drops the grammar from the build.
  specFor = grammar: {
    source = fetchurl {
      inherit (pinFor grammar) url hash;
    };
    subpath = grammar.source.subpath or "";
  };
  extensibleSpecs =
    lib.makeExtensible (self:
      builtins.listToAttrs
      (builtins.map (grammar: {
        inherit (grammar) name;
        value = specFor grammar;
      })
      grammarsToBuild));
  overlaidSpecs =
    lib.pipe extensibleSpecs
    (builtins.map (overlay: specs: specs.extend overlay) grammarOverlays);
  specLines =
    builtins.map
    (name: let spec = overlaidSpecs.${name}; in
      "${name}\t${spec.source}\t${spec.subpath}")
    (builtins.attrNames (lib.filterAttrs (_: spec: spec ? source) overlaidSpecs));
in
  # One derivation compiles every grammar, so the helix runtime closure
  # carries a single grammar path; the per-grammar source tarballs are
  # build-time inputs here and never enter the closure.
  # see https://github.com/NixOS/nixpkgs/blob/fbdd1a7c0bc29af5325e0d7dd70e804a972eb465/pkgs/development/tools/parsing/tree-sitter/grammar.nix
  stdenv.mkDerivation {
    pname = "helix-tree-sitter-grammars";
    version = "0";

    passAsFile = ["grammarSpecs"];
    grammarSpecs = builtins.concatStringsSep "\n" specLines;

    dontUnpack = true;
    dontConfigure = true;

    FLAGS = [
      "-Isrc"
      "-g"
      "-O3"
      "-fPIC"
      "-fno-exceptions"
      "-Wl,-z,relro,-z,now"
    ];

    buildPhase = ''
      runHook preBuild

      mkdir -p "$out"
      build_one() {
          local name=$1 src=$2 subpath=$3
          local work
          work=$(mktemp -d)
          tar -xf "$src" -C "$work"
          cd "$work"/*/
          if [[ -n "$subpath" ]]; then
              cd "$subpath"
          fi
          if [[ -e src/scanner.cc ]]; then
              $CXX -c src/scanner.cc -o scanner.o $FLAGS
          elif [[ -e src/scanner.c ]]; then
              $CC -c src/scanner.c -o scanner.o $FLAGS
          fi
          $CC -c src/parser.c -o parser.o $FLAGS
          $CXX -shared -o "$out/$name${stdenv.hostPlatform.extensions.sharedLibrary}" *.o
          rm -rf "$work"
      }
      build_line() {
          local name src subpath
          IFS=$'\t' read -r name src subpath <<< "$1"
          build_one "$name" "$src" "$subpath"
      }
      export -f build_one build_line
      # -r: an empty spec set (devShell builds no grammars) must not run the
      # child once with no arguments; -e: a failed step in the per-grammar
      # child must fail its build instead of silently shipping a degraded
      # grammar.
      xargs -P "$(nproc)" -r -d '\n' -n1 bash -ec 'build_line "$1"' bash < "$grammarSpecsPath"

      runHook postBuild
    '';

    # Strip failed on darwin: strip: error: symbols referenced by indirect symbol table entries that can't be stripped
    fixupPhase = lib.optionalString stdenv.hostPlatform.isLinux ''
      runHook preFixup
      shopt -s nullglob
      for so in "$out"/*.so; do
          $STRIP "$so"
      done
      runHook postFixup
    '';
  }
