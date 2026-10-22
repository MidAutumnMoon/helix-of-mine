{
  stdenv,
  lib,
  runCommand,
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
  buildGrammar = grammar: let
    pin = pinFor grammar;
  in
    stdenv.mkDerivation {
      # see https://github.com/NixOS/nixpkgs/blob/fbdd1a7c0bc29af5325e0d7dd70e804a972eb465/pkgs/development/tools/parsing/tree-sitter/grammar.nix

      pname = "helix-tree-sitter-${grammar.name}";
      version = grammar.source.rev;

      src = fetchurl {
        inherit (pin) url hash;
      };
      # The archive tarball unpacks to a single directory that unpackPhase
      # enters; grammars nested in a monorepo then descend into their subpath.
      preBuild =
        lib.optionalString (builtins.hasAttr "subpath" grammar.source)
        ''cd ${grammar.source.subpath}'';

      dontConfigure = true;

      FLAGS = [
        "-Isrc"
        "-g"
        "-O3"
        "-fPIC"
        "-fno-exceptions"
        "-Wl,-z,relro,-z,now"
      ];

      SHARED_LIB = grammar.name + stdenv.hostPlatform.extensions.sharedLibrary;

      buildPhase = ''
        runHook preBuild

        if [[ -e src/scanner.cc ]]; then
          $CXX -c src/scanner.cc -o scanner.o $FLAGS
        elif [[ -e src/scanner.c ]]; then
          $CC -c src/scanner.c -o scanner.o $FLAGS
        fi

        $CC -c src/parser.c -o parser.o $FLAGS
        $CXX -shared -o $SHARED_LIB *.o

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir $out
        mv $SHARED_LIB $out/
        runHook postInstall
      '';

      # Strip failed on darwin: strip: error: symbols referenced by indirect symbol table entries that can't be stripped
      fixupPhase = lib.optionalString stdenv.hostPlatform.isLinux ''
        runHook preFixup
        $STRIP $out/$SHARED_LIB
        runHook postFixup
      '';
    };
  grammarsToBuild = builtins.filter includeGrammarIf gitGrammars;
  builtGrammars =
    builtins.map (grammar: {
      inherit (grammar) name;
      value = buildGrammar grammar;
    })
    grammarsToBuild;
  extensibleGrammars =
    lib.makeExtensible (self: builtins.listToAttrs builtGrammars);
  overlaidGrammars =
    lib.pipe extensibleGrammars
    (builtins.map (overlay: grammar: grammar.extend overlay) grammarOverlays);
  sharedLibExtension = stdenv.hostPlatform.extensions.sharedLibrary;
  grammarLinks =
    lib.mapAttrsToList
    (name: artifact: "ln -s ${artifact}/${name}${sharedLibExtension} $out/${name}${sharedLibExtension}")
    (lib.filterAttrs (n: v: lib.isDerivation v) overlaidGrammars);
in
  runCommand "consolidated-helix-grammars" {} ''
    mkdir -p $out
    ${builtins.concatStringsSep "\n" grammarLinks}
  ''
