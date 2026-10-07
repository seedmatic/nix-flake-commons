# The `relock` app, as a FACTORY — because the rule must be ONE implementation, not a copy per repo.
#
# The app NAME is already decided to be identical in every repo
# (docs/architecture/patterns/flake-lock-propagation.adoc § naming): propagation is a REQUEST, so the
# caller must know nothing about the callee beyond its name. That argument does not stop at the name.
# If each repo wrote its own relock, "every repo applies the same rule" would be a claim nobody could
# check, and the two would drift exactly where it matters — the derivation-impact guard that
# TERMINATES the rke2lab <-> ndh cycle. So the rule lives once, here, and each repo supplies only what
# is its own.
#
# It lives in nix-flake-commons because that is the ROOT every seedmatic flake already consumes. It
# used to live in rke2lab, which was fine for ndh — ndh already read `inputs.rke2lab.lib.*` — but any
# other repo wanting `#relock` would have had to take a NEW edge to a leaf, just for a tool. A tool
# shared by the whole chain belongs where the whole chain already points.
#
# A separate file rather than a `let` binding, because the two uses sit in different scopes — a repo's
# own app is per-system (it needs `pkgs`), while `lib.mkRelockApp` is the system-independent export
# the consumers call. A file is visible to both without making either recursive.
{
  # The consumer's own nixpkgs — the app is system-specific even though this factory is not.
  pkgs,
  # Short repo name, for the log lines and the default input name.
  name,
  # `owner/name` — how a checkout is RECOGNISED as this repo. Matched on the slug and not the url
  # because a local checkout may speak ssh where the input speaks https, and the same repo must not
  # read as a different one because of the transport.
  slug,
  # Where to clone when the request arrives from outside our own checkout.
  url,
  # Who to REQUEST on `--downstream`. This is the one fact a repo cannot read off its own lock: a lock
  # says who I consume, never who consumes me.
  consumers ? [ ],
  # Extra pathspecs the dirty-guard must ignore, because relock rewrites them itself. `flake.lock` is
  # always ignored; these are the repo's generated artifacts (dataplan.json, …).
  ownedArtifacts ? [ ],
  # An orphan branch to push BEFORE inputs resolve — a `github:` input sees only what is pushed. "" for
  # a repo with none.
  pushFirstBranch ? "",
  # An orphan branch that PINS this repo and carries the flox envs. "" for a repo with none, and the
  # whole catalog hop is then skipped.
  catalogBranch ? "",
  # This repo's input name inside that catalog's lock.
  selfPinName ? name,
  # The branch THIS flake lives on, for a flake that is not its repo's default branch — an orphan
  # such as rke2lab's seed-incluster. The slug alone cannot tell two flakes of one repo apart, so a
  # checkout counts as ours only on this branch, and a requested run clones this branch. "" for a
  # flake on the default branch.
  branch ? "",
  # The repo's OWN words for some of its regen apps — `{ plans = "regen-dataplan"; }` — accepted as
  # targets and listed in `--help`. Declared by the repo, because a factory in the root that names
  # one consumer's artifacts is the wrong way round.
  aliases ? { },
}:
pkgs.writeShellApplication {
  name = "relock";
  runtimeInputs = [
    pkgs.coreutils
    # gitMinimal: on darwin, nixpkgs' full `git` drags a ~12.8 GB closure (apple-sdk, clang,
    # cctools) — measured on rke2lab's deploy. relock needs plain git and nothing else.
    pkgs.gitMinimal
    pkgs.jq
    pkgs.nix
  ];
  text = builtins.readFile (
    pkgs.replaceVars ./relock.sh {
      inherit
        selfPinName
        pushFirstBranch
        catalogBranch
        ;
      repoUrl = url;
      repoName = name;
      repoSlug = slug;
      ownBranch = branch;
      system = pkgs.stdenv.hostPlatform.system;
      consumers = pkgs.lib.concatStringsSep " " (map (c: ''"${c}"'') consumers);
      ownedArtifacts = pkgs.lib.concatStringsSep " " (map (a: "':!${a}'") ownedArtifacts);
      aliases = pkgs.lib.concatStringsSep " " (
        pkgs.lib.mapAttrsToList (k: v: ''"${k}=${v}"'') aliases
      );
    }
  );
}
