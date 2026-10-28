# lib.versionLines against fixtures: the comparison, and every line against ./schema.json. Each case is a mutant of
# the comparison too: a level or a status read wrong fails here.
{ pkgs, versionLines }:
let
  inherit (pkgs) lib;
  c = name: pinned: latest: {
    inherit name pinned latest;
    source = "fixture:${name}";
    upstream = "nixpkgs:nixpkgs-unstable#${name}";
  };
  lines = versionLines [
    (c "same" "1.36.4" "1.36.4")
    (c "suffixes" "1.36.4+rke2r1" "v1.36.4")
    (c "micro" "2.9.5" "2.9.6")
    (c "minor" "1.36.3" "1.37.1")
    (c "major" "3.20.2" "4.3.0")
    (c "padded" "260" "260.0.1")
    (c "ahead" "1.37.0" "1.36.9")
    (c "unreachable" "1.0.0" null)
    (c "revision" "26f4107e47e3" "718f670e0000")
    (c "revision-same" "26f4107e47e3" "26f4107e47e3")
  ];
  expected = {
    same = { level = null; status = "current"; };
    suffixes = { level = null; status = "current"; };
    micro = { level = "micro"; status = "behind"; };
    minor = { level = "minor"; status = "behind"; };
    major = { level = "major"; status = "behind"; };
    padded = { level = "micro"; status = "behind"; };
    ahead = { level = "minor"; status = "ahead"; };
    unreachable = { level = null; status = "unknown"; };
    revision = { level = null; status = "unknown"; };
    revision-same = { level = null; status = "current"; };
  };
  wrong = builtins.filter (
    l: { inherit (l) level status; } != expected.${l.name}
  ) lines;
  jsonl = pkgs.writeText "lines.jsonl" (lib.concatMapStrings (l: builtins.toJSON l + "\n") lines);
in
pkgs.runCommand "version-lines"
  {
    nativeBuildInputs = [ pkgs.check-jsonschema pkgs.jq ];
  }
  (
    if wrong != [ ] then
      ''
        echo "FAIL the comparison: ${builtins.toJSON wrong}" >&2
        exit 1
      ''
    else
      ''
        # Every line against the contract.
        while IFS= read -r line; do
          printf '%s' "$line" >line.json
          check-jsonschema --schemafile ${./schema.json} line.json >/dev/null || { echo "FAIL schema: $line" >&2; exit 1; }
        done <${jsonl}
        # And the schema refuses a line it must refuse: a ninth field.
        jq -c '.extra = 1' <<<"$(head -1 ${jsonl})" >bad.json
        if check-jsonschema --schemafile ${./schema.json} bad.json >/dev/null 2>&1; then
          echo "FAIL the schema accepts an extra field" >&2; exit 1
        fi
        touch $out
      ''
  )
