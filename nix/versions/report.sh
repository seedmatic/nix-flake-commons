#!/usr/bin/env bash
# versions-report: ONE report of every world's version lines, in the contract of schema.json.
#
#   versions-report [--format=table|jsonl] <lines.jsonl>…
#
# Each argument is a file of JSON Lines (or `-`): the nix world's lines of a flake (`nix eval .#versions.lines`) and
# the clusters world's (`manifests versions format=jsonl`). A line whose `latest` is null and whose upstream is a
# GitHub ref is completed here, at run time, from the GitHub API (the token from `gh auth token`, handed to curl on
# its stdin, never in argv nor on disk). Every line is validated against the schema; the report is sorted by
# status (behind, ahead, unknown, current) then world and name, majors first among the behind.
set -euo pipefail

format=table
files=()
for arg in "$@"; do
  case $arg in
    --format=table | --format=jsonl) format=${arg#--format=} ;;
    --format=*) echo "versions-report: unknown format ${arg#--format=}" >&2; exit 2 ;;
    *) files+=("$arg") ;;
  esac
done
((${#files[@]} > 0)) || { echo "usage: versions-report [--format=table|jsonl] <lines.jsonl>…" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat "${files[@]}" | grep -v '^[[:space:]]*$' >"$work/in.jsonl" || true

# A GitHub head or release for the lines that need the network: `github:<owner>/<repo>#<branch>` reads the branch's
# head commit; `github:<owner>/<repo>` reads the highest release whose tag IS a version (`v?X.Y(.Z)`, an optional
# `+…` build suffix), never a draft or a prerelease. Not `releases/latest`: a repo that publishes two releases per
# version (tektoncd/operator: `v0.81.2` and the chart's `tekton-operator-0.81.2`) points it at either.
# VERSIONS_GITHUB_API names another API root (a test's local fixture); the default is GitHub's.
api=${VERSIONS_GITHUB_API:-https://api.github.com}
token=$(gh auth token 2>/dev/null || true)
github() { # <api path>
  if [[ -n $token ]]; then
    printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -fsS --max-time 20 -K - "$api/$1"
  else
    curl -fsS --max-time 20 "$api/$1"
  fi
}
while IFS= read -r line; do
  latest=$(jq -r '.latest // empty' <<<"$line")
  upstream=$(jq -r '.upstream' <<<"$line")
  if [[ -z $latest && $upstream == github:* ]]; then
    ref=${upstream#github:}
    if [[ $ref == *#* ]]; then
      latest=$(github "repos/${ref%%#*}/commits/${ref#*#}" 2>/dev/null | jq -r '.sha // empty' || true)
    else
      # The first page (30 releases, newest first) holds the highest version: no query string, so the path is the
      # same against GitHub and a test's file:// fixture.
      latest=$(github "repos/$ref/releases" 2>/dev/null | jq -r -f @highestJq@ || true)
    fi
    if [[ -n $latest ]]; then
      line=$(jq -c --arg l "$latest" '.latest = $l' <<<"$line")
    fi
  fi
  printf '%s\n' "$line"
done <"$work/in.jsonl" >"$work/filled.jsonl"

# Recompute level and status for the lines completed here, with the same rule as lib.versionLines: numeric parts
# only, a leading v and a +/- suffix ignored; a non-numeric pin compares by equality.
jq -c -f @compareJq@ "$work/filled.jsonl" >"$work/lines.jsonl"

while IFS= read -r line; do
  printf '%s' "$line" >"$work/line.json"
  if ! check-jsonschema --schemafile @schema@ "$work/line.json" >/dev/null 2>&1; then
    echo "versions-report: a line breaks the contract: $line" >&2
    exit 1
  fi
done <"$work/lines.jsonl"

jq -s -c 'sort_by(
    ({"behind": 0, "ahead": 1, "unknown": 2, "current": 3}[.status]),
    ({"major": 0, "minor": 1, "micro": 2}[.level // "micro"]),
    .world, .name)[]' "$work/lines.jsonl" >"$work/sorted.jsonl"

if [[ $format == jsonl ]]; then
  cat "$work/sorted.jsonl"
  exit 0
fi
# Aligned in jq, not by `column`: util-linux's column escapes a non-ASCII byte (the ⚠) without a UTF-8 locale.
# The flag is padded as its own column of width 1 (jq's length counts the ⚠ as one character).
jq -r -s '
  def pad($w): . + (" " * ([$w - length, 0] | max));
  ([["", "WORLD", "NAME", "PINNED", "LATEST", "LEVEL", "STATUS", "SOURCE"]]
   + [.[] | [ (if .level == "major" and .status == "behind" then "⚠" else "" end),
              .world, .name, (.pinned | .[0:24]), ((.latest // "?") | .[0:24]), (.level // "-"), .status, .source ]])
  | . as $rows
  | [range(0; $rows[0] | length) as $c | [$rows[][$c] | length] | max] as $w
  | $rows[] | [range(0; length) as $c | .[$c] | pad($w[$c])] | join("  ") | sub(" +$"; "")
' "$work/sorted.jsonl"
behind=$(jq -s '[.[] | select(.status == "behind")] | length' "$work/sorted.jsonl")
majors=$(jq -s '[.[] | select(.status == "behind" and .level == "major")] | length' "$work/sorted.jsonl")
echo
echo "$(wc -l <"$work/sorted.jsonl" | tr -d ' ') lines · $behind behind, $majors of them a major (⚠)"
