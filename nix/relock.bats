# Behaviour tests for the shared `relock` — what shellcheck CANNOT see.
#
# shellcheck already gates the script at every build (syntax, quoting, constant tests), so nothing
# here re-checks that. What it cannot see is behaviour at run time, and above all the failure
# paths: every defect found in this script was a syntactically flawless script going SILENT at the
# wrong moment — a failure read as an absence, a failure swallowed in an `if`, a failure swallowed in
# an `||` list. Each case below is one such contract, and most are a regression that really happened.
#
# It runs the script exactly as `mkRelockApp` BUILDS it (substitution and aliases included), with only
# its `export PATH=` line removed, so a fake `nix` takes over and can produce each failure on demand.
# The fake is driven by environment variables; the real git and jq do the rest, against a throwaway
# repository and a local bare remote.

setup() {
  T=$BATS_TEST_TMPDIR
  export HOME=$T GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

  mkdir -p "$T/bin" "$T/remote/seedmatic"
  sed '/^export PATH=/d' "$RELOCK" > "$T/relock"
  sed '/^export PATH=/d' "$RELOCK_ON_BRANCH" > "$T/relock-on-branch"
  chmod +x "$T/relock" "$T/relock-on-branch"

  # The fake nix. It records every call, and answers each question relock asks. Its shebang is the
  # bash on PATH, not /usr/bin/env: the Linux build sandbox does not promise /usr/bin/env.
  printf '#!%s\n' "$(command -v bash)" > "$T/bin/nix"
  cat >> "$T/bin/nix" <<'FAKE'
echo "$*" >> "$T/calls"
case "$*" in
  *"outputs ? packages"*)
    n=$(( $(cat "$T/probes" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/probes"
    mode=$STUB_HAS_PACKAGES
    [ "$mode" = true-then-fail ] && { [ "$n" -eq 1 ] && mode=true || mode=fail; }
    [ "$mode" = fail ] && { echo "error: cannot evaluate packages" >&2; exit 1; }
    echo "$mode" ;;
  *"? relock"*)
    [ "${STUB_CONSUMER:-absent}" = absent ] && { echo false; exit 0; }
    echo true ;;
  *"run fake:consumer#relock"*)
    [ "$STUB_CONSUMER" = fail ] && { echo "consumer boom" >&2; exit 3; }
    exit 0 ;;
  *"#apps."*)     [ -n "${STUB_REGEN:-}" ] && echo '["regen-x"]' || echo '[]' ;;
  *"run .#regen-x"*)
    if [ "$STUB_REGEN" = fail ]; then echo '{"half":1}' > artifact.json; echo "regen boom" >&2; exit 4; fi
    echo '{"fresh":1}' > artifact.json ;;
  *"#packages."*) printf '{"p":"/nix/store/%s.drv"}\n' "$(cat "$T/drv")" ;;
  *"flake update"*)
    case ${STUB_UPDATE:-none} in
      rev)    jq '.nodes.a.locked.rev = "r2"' flake.lock > l && mv l flake.lock; echo d2 > "$T/drv" ;;
      nested) jq '.nodes.x.locked.rev = "x2"' flake.lock > l && mv l flake.lock ;;
      path)   jq '.nodes.a.locked = {"type":"path","path":"/somewhere/local"}' flake.lock > l && mv l flake.lock ;;
      garbage) echo 'not json at all' > flake.lock ;;
    esac ;;
  *) echo "fake nix: unexpected call: $*" >&2; exit 99 ;;
esac
FAKE
  chmod +x "$T/bin/nix"
  export PATH="$T/bin:$PATH" T
  echo d1 > "$T/drv"

  # A repo whose origin ends with the slug relock was built for, so it recognises it as its own.
  git init -q --bare "$T/remote/seedmatic/t.git"
  git clone -q "$T/remote/seedmatic/t.git" "$T/work" 2>/dev/null
  cd "$T/work"
  echo '{}' > flake.nix
  echo '{"stale":1}' > artifact.json
  # Root inputs: `a` is a real node; `f` is a `follows` — an input PATH with no lock of its own.
  cat > flake.lock <<'LOCK'
{"nodes":{"root":{"inputs":{"a":"a","f":["a","x"]}},
 "a":{"locked":{"type":"github","rev":"r1"},"inputs":{"x":"x"}},
 "x":{"locked":{"type":"github","rev":"x1"}}},"root":"root","version":7}
LOCK
  git add flake.nix flake.lock artifact.json && git commit -qm init && git push -qu origin HEAD 2>/dev/null
  DEFAULT=$(git rev-parse --abbrev-ref HEAD)
  # A requested run clones the factory's url; send it to the local bare instead.
  git config --global url."$T/remote/seedmatic/t.git".insteadOf "file:///nonexistent/seedmatic/t.git"
}

# The repo's OTHER flake: an orphan branch, pushed, so a clone can take it.
mk_orphan() {
  git -C "$T/work" checkout -q --orphan orphan
  git -C "$T/work" commit -qm orphan
  git -C "$T/work" push -qu origin orphan 2>/dev/null
}
never_updated() { ! grep -q "flake update" "$T/calls" 2>/dev/null; }

relock_commits() { git -C "$T/work" log --format=%s | grep -c '^chore(' || true; }
# The tree AFTER the fact, not just the exit code: a failure path must leave nothing behind.
tree_clean()     { [ -z "$(git -C "$T/work" status --porcelain --untracked-files=no)" ]; }
lock_unchanged() { git -C "$T/work" diff --quiet HEAD -- flake.lock; }

@test "--help lists the aliases the repo declares, and nothing about any other repo" {
  run "$T/relock" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Aliases this repo declares"* ]]
  [[ "$output" == *"plans"*"regen-dataplan"* ]]
  [[ "$output" != *"rke2lab"* ]]
  [[ "$output" != *"flox-catalog"* ]]
}

@test "an untracked file does not block a run — nix never sees it" {
  touch "$T/work/scratch-from-another-session"
  STUB_HAS_PACKAGES=true STUB_UPDATE=none run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUSING"* ]]
}

@test "a tracked modification refuses — it would be credited to the bump" {
  echo '{ }' > "$T/work/flake.nix"
  STUB_HAS_PACKAGES=true run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]]
}

@test "a FAILING packages probe is fatal — it must not read as 'no packages'" {
  STUB_HAS_PACKAGES=fail STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -ne 0 ]
  [[ "$output" != *"DONE"* ]]
  [ "$(relock_commits)" -eq 0 ]
  tree_clean
  lock_unchanged
}

@test "a failed measurement mid-run is NOT committed, and the lock is restored" {
  STUB_HAS_PACKAGES=true-then-fail STUB_UPDATE=rev run "$T/relock" inputs
  [[ "$output" == *"FAILED to measure impact"* ]]
  [ "$(relock_commits)" -eq 0 ]
  tree_clean
  lock_unchanged
}

@test "packages repo: a bump that moves a derivation is carried" {
  STUB_HAS_PACKAGES=true STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUMPED"* ]]
  [ "$(relock_commits)" -eq 1 ]
}

@test "aggregator: a bump of a root input is carried — its inputs ARE what it exports" {
  STUB_HAS_PACKAGES=false STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUMPED"* ]]
  [ "$(relock_commits)" -eq 1 ]
}

@test "aggregator: a follows root input is left out of the impact projection" {
  # Only the node behind the `follows` moves. Resolving the follows by its last path segment
  # would have counted that as impact; it is already counted where it is defined.
  STUB_HAS_PACKAGES=false STUB_UPDATE=nested run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO derivation impact"* ]]
  [ "$(relock_commits)" -eq 0 ]
}

@test "a re-aim at a local checkout is refused, and the lock is restored" {
  STUB_HAS_PACKAGES=true STUB_UPDATE=path run "$T/relock" inputs
  [[ "$output" == *"LOCAL lock REFUSED"* ]]
  [ "$(relock_commits)" -eq 0 ]
  tree_clean
  lock_unchanged
}

@test "an unreadable lock after an update is NOT waved through the local-lock guard" {
  # An empty answer from the guard's own read is what "not local" looks like.
  STUB_HAS_PACKAGES=true STUB_UPDATE=garbage run "$T/relock" inputs
  [[ "$output" == *"FAILED to read the updated lock"* ]]
  [ "$(relock_commits)" -eq 0 ]
  tree_clean
  lock_unchanged
}

@test "a failed regen leaves nothing dirty, commits nothing, and says why" {
  STUB_HAS_PACKAGES=true STUB_REGEN=fail run "$T/relock" artifacts
  [[ "$output" == *"FAILED (nix run .#regen-x)"* ]]
  [[ "$output" == *"regen boom"* ]]
  [ "$(relock_commits)" -eq 0 ]
  tree_clean
}

@test "a regen that rewrites an artifact is committed" {
  STUB_HAS_PACKAGES=true STUB_REGEN=ok run "$T/relock" artifacts
  [ "$status" -eq 0 ]
  [[ "$output" == *"REGENERATED"* ]]
  [ "$(relock_commits)" -eq 1 ]
  tree_clean
}

@test "--downstream: a consumer whose relock FAILS is said so, with its stderr" {
  STUB_HAS_PACKAGES=true STUB_CONSUMER=fail run "$T/relock" --downstream inputs
  [[ "$output" == *"FAILED — fake:consumer's relock exited non-zero"* ]]
  [[ "$output" == *"consumer boom"* ]]
  [[ "$output" != *"exposes no #relock"* ]]
}

@test "--downstream: a consumer with no relock is skipped as such" {
  STUB_HAS_PACKAGES=true STUB_CONSUMER=absent run "$T/relock" --downstream inputs
  [[ "$output" == *"exposes no #relock yet"* ]]
}

@test "the local registry wins over the committed one — that is what the indirection is for" {
  echo '{"version":2,"flakes":[]}' > "$T/work/flake-registry.json"
  echo '{"version":2,"flakes":[]}' > "$T/work/flake-registry.local.json"
  git -C "$T/work" add flake-registry.json && git -C "$T/work" commit -qm reg
  STUB_HAS_PACKAGES=true STUB_UPDATE=none run "$T/relock" inputs
  [ "$status" -eq 0 ]
  grep -q -- "--flake-registry $T/work/flake-registry.local.json flake update" "$T/calls"
}

@test "with no local override, the committed registry is used" {
  echo '{"version":2,"flakes":[]}' > "$T/work/flake-registry.json"
  git -C "$T/work" add flake-registry.json && git -C "$T/work" commit -qm reg
  STUB_HAS_PACKAGES=true STUB_UPDATE=none run "$T/relock" inputs
  [ "$status" -eq 0 ]
  grep -q -- "--flake-registry $T/work/flake-registry.json flake update" "$T/calls"
}

@test "a branch-scoped flake REFUSES a checkout of its repo on another branch" {
  # The slug matches, so without the branch check this reconciled the default branch by the
  # orphan's rules, and said nothing.
  mk_orphan
  git -C "$T/work" checkout -q "$DEFAULT"
  STUB_HAS_PACKAGES=true run "$T/relock-on-branch" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"*"'$DEFAULT'"*"'orphan'"* ]]
  never_updated
  tree_clean
}

@test "a branch-scoped flake reconciles a checkout on its own branch" {
  mk_orphan
  STUB_HAS_PACKAGES=true STUB_UPDATE=none run "$T/relock-on-branch" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"reconciling the checkout at $T/work (orphan)"* ]]
  [[ "$output" == *"DONE"* ]]
}

@test "a requested run of a branch-scoped flake clones ITS branch, not the default one" {
  mk_orphan
  git -C "$T/work" checkout -q "$DEFAULT"
  mkdir -p "$T/outside" && cd "$T/outside"
  STUB_HAS_PACKAGES=true STUB_UPDATE=none run "$T/relock-on-branch" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloned at orphan"* ]]
  [[ "$output" == *"DONE"* ]]
}

@test "a requested run of a flake with no branch still clones the default branch" {
  mk_orphan
  git -C "$T/work" checkout -q "$DEFAULT"
  mkdir -p "$T/outside" && cd "$T/outside"
  STUB_HAS_PACKAGES=true STUB_UPDATE=none run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloned at $DEFAULT"* ]]
}

@test "a flake with no branch REFUSES a checkout on a branch it declares as another flake" {
  # The reverse confusion: the default flake's relock, run from the orphan's worktree.
  git -C "$T/work" checkout -q -b first
  STUB_HAS_PACKAGES=true run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"*"'first'"*"ANOTHER"* ]]
  never_updated
  tree_clean
}
