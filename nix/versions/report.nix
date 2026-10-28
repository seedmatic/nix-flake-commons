# The versions-report app: the merger of every world's version lines, in the contract of ./schema.json.
{ pkgs }:
pkgs.writeShellApplication {
  name = "versions-report";
  runtimeInputs = with pkgs; [
    check-jsonschema
    coreutils
    curl
    gh
    gnugrep
    jq
  ];
  text = builtins.replaceStrings [ "@schema@" "@compareJq@" ] [ "${./schema.json}" "${./compare.jq}" ] (
    builtins.readFile ./report.sh
  );
}
