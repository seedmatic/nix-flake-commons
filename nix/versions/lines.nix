# The nix world's version lines, in the contract of ./schema.json. Pure: it reads attributes only, builds nothing.
#
#   lib.versionLines { lib } [ carrier … ]
#
# A carrier is { name; source; pinned; latest ? null; upstream ? "none"; } where `pinned` and `latest` are version
# strings already read (a package's `.version`, a lock's rev). A `latest` that has to be read from the network (a
# GitHub release) is left null here, and the report app fills it at run time: an evaluation stays pure.
#
# level and status compare the numeric parts only: a leading `v` and a `+`/`-` suffix (rke2's `+rke2r1`, a build
# tag) are not part of the comparison, so `1.36.4+rke2r1` and `v1.36.4` are the same version. Non-numeric versions
# (a revision) compare by equality: current when equal, unknown otherwise.
{ lib }:
let
  # "v1.36.4+rke2r1" → [ 1 36 4 ]; null when it is not a dotted number.
  parts =
    v:
    let
      core = lib.head (lib.splitString "+" (lib.head (lib.splitString "-" (lib.removePrefix "v" v))));
      fields = lib.splitString "." core;
    in
    if v != null && fields != [ ] && lib.all (f: builtins.match "[0-9]+" f != null) fields then
      map lib.toInt fields
    else
      null;

  # The first index where two part lists differ, padded with zeros; null when equal.
  firstDiff =
    a: b:
    let
      n = lib.max (lib.length a) (lib.length b);
      at = l: i: if i < lib.length l then lib.elemAt l i else 0;
      go = i: if i >= n then null else if at a i != at b i then i else go (i + 1);
    in
    go 0;

  compare =
    pinned: latest:
    let
      p = parts pinned;
      l = parts latest;
      i = if p == null || l == null then null else firstDiff p l;
      at = xs: j: if j < lib.length xs then lib.elemAt xs j else 0;
    in
    if latest == null then
      {
        level = null;
        status = "unknown";
      }
    else if p == null || l == null then
      {
        level = null;
        status = if pinned == latest then "current" else "unknown";
      }
    else if i == null then
      {
        level = null;
        status = "current";
      }
    else
      {
        level = lib.elemAt [ "major" "minor" "micro" ] (lib.min i 2);
        status = if at p i < at l i then "behind" else "ahead";
      };
in
carriers:
map (
  c:
  let
    latest = c.latest or null;
  in
  {
    world = "nix";
    inherit (c) name source pinned;
    inherit latest;
    upstream = c.upstream or "none";
  }
  // compare c.pinned latest
) carriers
