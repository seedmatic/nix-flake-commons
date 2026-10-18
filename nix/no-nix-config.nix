# A flake of ours declares no nixConfig: no machine takes it (ndh dropped accept-flake-config), so a substituter
# or a key written there is dead text that reads as trust. Each seedmatic flake runs this on its own flake.nix. The
# pattern must catch a sample of a declaration and leave a mention in a comment alone.
{ pkgs, flakeNix }:
let
  # Spelled in pieces, so this file does not match its own pattern.
  caught = pkgs.writeText "caught.nix" (
    "{\n  nix" + "Config.extra-substituters = [ ];\n  nix" + "Config = { };\n}\n"
  );
  spared = pkgs.writeText "spared.nix" "{\n  # no machine takes a flake's nix${"Config"}\n  x = 1;\n}\n";
in
pkgs.runCommand "no-nix-config" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  pattern='^\s*nixConfig\s*(\.|=)'
  [ "$(grep -cE "$pattern" ${caught})" = 2 ] || { echo "FAIL the pattern misses a nixConfig declaration"; exit 1; }
  ! grep -qE "$pattern" ${spared} || { echo "FAIL the pattern catches a comment"; exit 1; }
  if grep -nE "$pattern" ${flakeNix}; then
    echo "a nixConfig is declared in flake.nix: dead text, since no machine of ours takes it"
    exit 1
  fi
  touch $out
''
