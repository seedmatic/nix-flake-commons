# shellcheck shell=bash
# sweep-configurations — proves, on a real flake, that relock's measure of the configurations does
# not move with the revision alone. It takes a clone of the flake, measures every nixos/darwin
# configuration (raw, and with `system.configurationRevision` neutralised, nix/configurations.nix),
# adds an EMPTY commit — same tree, new revision — and measures again. The raw measure may move (that
# is the noise the neutralisation exists for); the neutralised one must not, or relock's guard would
# carry every bump of that flake.
#
# Build-time token (written WITHOUT at-sigils): configurationsNix.

if [ "$#" -ne 1 ] || ! git -C "$1" rev-parse --git-dir >/dev/null 2>&1; then
  echo "usage: sweep-configurations <checkout of a flake>" >&2
  exit 2
fi
src=$(cd "$1" && pwd -P)
work=$(realpath "$(mktemp -d)")
trap 'rm -rf "$work"' EXIT
git clone --quiet --no-local "$src" "$work/flake"
measure() { # $1 neutralise (true|false) -> JSON
  nix eval --json --impure --expr \
    "import @configurationsNix@ { outputs = (builtins.getFlake \"git+file://$work/flake\").outputs; neutralise = $1; }"
}
before_raw=$(measure false) || exit 1
before=$(measure true) || exit 1
git -C "$work/flake" -c user.name=sweep -c user.email=sweep@localhost commit --quiet --allow-empty -m "sweep: same tree, new revision"
after_raw=$(measure false) || exit 1
after=$(measure true) || exit 1

jq -rn --argjson br "$before_raw" --argjson ar "$after_raw" --argjson bn "$before" --argjson an "$after" '
  [ ("nixos", "darwin") as $k | ($bn[$k] | keys[]) as $c
    | { kind: $k, name: $c,
        raw: (if $br[$k][$c] == $ar[$k][$c] then "same" else "MOVES" end),
        neutralised: (if $bn[$k][$c] == $an[$k][$c] then "same" else "MOVES" end) } ]
  | (["kind", "configuration", "raw", "neutralised"] | @tsv),
    (.[] | [.kind, .name, .raw, .neutralised] | @tsv),
    ("\(length) configurations: raw moves on \(map(select(.raw == "MOVES")) | length), neutralised moves on \(map(select(.neutralised == "MOVES")) | length)")'
moved=$(jq -n --argjson bn "$before" --argjson an "$after" '[ ("nixos", "darwin") as $k | ($bn[$k] | keys[]) as $c | select($bn[$k][$c] != $an[$k][$c]) ] | length')
if [ "$moved" != 0 ]; then
  echo "FAILED: $moved neutralised configuration(s) move with the revision alone — relock's guard would carry every bump" >&2
  exit 1
fi
