# The `relock` app, as a FACTORY — because the rule must be ONE implementation, not a copy per head.
#
# The app NAME is identical in every repo: propagation is a REQUEST, so the caller must know nothing
# about the callee beyond its name. That argument does not stop at the name. If each repo wrote its own
# relock, "every head applies the same rule" would be a claim nobody could check, and the copies would
# drift exactly where it matters — the derivation-impact guard. So the rule lives once, here, and each
# head supplies only what is its own.
#
# It lives in nix-flake-commons because that is the ROOT every seedmatic flake already consumes.
#
# A separate file rather than a `let` binding, because the two uses sit in different scopes — a head's
# own app is per-system (it needs `pkgs`), while `lib.mkRelockApp` is the system-independent export
# the heads call.
{
  # The head's own nixpkgs — the app is system-specific even though this factory is not.
  pkgs,
  # The head's id in nix-flake-commons' `fabric/heads` — the id the locks name in `original.id`. Its
  # repository and branch come from there, never from here: a second copy is how ids drift apart.
  name,
  # Apps run AFTER the inputs' bump, before the impact guard measures, because what they produce
  # resolves through the bumped inputs (flox-catalog's `lock-envs`).
  afterInputs ? [ ],
  # Injected by `lib.mkRelockApp`, never passed by a head: the tool's identity (a hash of its code)
  # and the repo it is fetched from, so that a pass can build every relock it plays from ONE tool.
  toolId,
  toolSlug,
}:
pkgs.writeShellApplication {
  name = "relock";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.curl
    # gitMinimal: on darwin, nixpkgs' full `git` drags a ~12.8 GB closure (apple-sdk, clang,
    # cctools) — measured on rke2lab's deploy. relock needs plain git and nothing else.
    pkgs.gitMinimal
    pkgs.jq
    pkgs.nix
  ];
  text = builtins.readFile (
    pkgs.replaceVars ./relock.sh {
      inherit toolId toolSlug;
      repoName = name;
      system = pkgs.stdenv.hostPlatform.system;
      afterInputs = pkgs.lib.concatStringsSep " " (map (a: ''"${a}"'') afterInputs);
      planJq = "${./plan.jq}";
      configurationsNix = "${./configurations.nix}";
    }
  );
}
