# Behaviour tests for the shared `relock` — what shellcheck CANNOT see.
#
# shellcheck already gates the script at every build, so nothing here re-checks syntax. What it
# cannot see is behaviour at run time, and above all the failure paths: every defect found in this
# script was a syntactically flawless script going SILENT at the wrong moment — a failure read as an
# absence, a failure swallowed in an `if`, a failure swallowed in an `||` list. Each case below is one
# such contract.
#
# It runs the script exactly as `mkRelockApp` BUILDS it, with only its `export PATH=` line removed, so
# a fake `nix` and a fake `curl` (the GitHub API) take over and produce each answer on demand. The real
# git and jq do the rest, against throwaway repositories and local bare remotes. The fabric's heads
# are a fixture: `t` and its orphan project `t-orphan` (one repository), `peer`, `peer2`, and `d`, a
# data head of peer's repository.

setup() {
  T=$BATS_TEST_TMPDIR
  export HOME=$T GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  # git's global and system configs are the test's own: a run outside the build sandbox must never
  # read the operator's hooks or write the operator's config.
  export GIT_CONFIG_GLOBAL=$T/.gitconfig GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME=$T/.config
  mkdir -p "$T/bin" "$T/remote/seedmatic" "$T/gh"
  for v in RELOCK RELOCK_AFTER RELOCK_ORPHAN RELOCK_PEER RELOCK_PEER2; do
    f=$(printf '%s' "$v" | tr 'A-Z_' 'a-z-')
    sed '/^export PATH=/d' "${!v}" > "$T/$f"
    chmod +x "$T/$f"
  done

  # The fake nix. It records every call, and answers each question relock asks. Its shebang is the
  # bash on PATH, not /usr/bin/env: the Linux build sandbox does not promise /usr/bin/env.
  printf '#!%s\n' "$(command -v bash)" > "$T/bin/nix"
  cat >> "$T/bin/nix" <<'FAKE'
echo "$*" >> "$T/calls"
printf '%s\n' "${NIX_CONFIG:-}" >> "$T/nix-config"
# What nix does with a git+file flake whose path crosses a symlink: fine while the tree is clean,
# refused once it is dirty — and a bumped lock makes it dirty.
for a in "$@"; do
  case $a in
    *git+file://*) p=${a#*git+file://}; p=${p%%\"*} ;;
    /*\#*) p=${a%%#*} ;;
    *) continue ;;
  esac
  if [ -d "$p" ] && [ "$(cd "$p" && pwd -P)" != "$p" ] && [ -n "$(git -C "$p" status --porcelain --untracked-files=no)" ]; then
    echo "error: path '$p' is a symlink" >&2; exit 1
  fi
done
case "$*" in
  *"#lib.relockToolId"*) printf '%s' "${STUB_TOOL_ID:-$RELOCK_TOOL_ID}" ;;
  # What the head exports: its systems, and whether it has configurations.
  *"relock:shape"*)
    [ "${STUB_HAS_PACKAGES:-true}" = fail ] && { echo "error: cannot evaluate packages" >&2; exit 1; }
    systems=$(printf '%s\n' ${STUB_SYSTEMS:-aarch64-darwin} | jq -R . | jq -sc .)
    pk=$systems; [ "${STUB_HAS_PACKAGES:-true}" = false ] && pk='[]'
    printf '{"packages":%s,"apps":%s,"configurations":%s}\n' "$pk" "$systems" "${STUB_HAS_CONFIGS:-false}" ;;
  # One system, tried before anything moves.
  *"relock:probe"*)
    if [ -n "${STUB_BROKEN_SYSTEM:-}" ] && [[ "$*" == *"\"$STUB_BROKEN_SYSTEM\""* ]]; then
      echo "error: attribute '$STUB_BROKEN_SYSTEM' missing" >&2; exit 1
    fi ;;
  # The measure: packages and apps of every measured system, and the configurations.
  *"relock:measure"*)
    n=$(( $(cat "$T/measures" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/measures"
    [ "${STUB_MEASURE:-ok}" = fail-after-first ] && [ "$n" -gt 1 ] && { echo "error: cannot evaluate packages" >&2; exit 1; }
    [ "${STUB_APPS:-ok}" = fail ] && { echo "error: cannot evaluate apps" >&2; exit 1; }
    [ "${STUB_CONFIGS:-ok}" = fail ] && [ "${STUB_HAS_CONFIGS:-false}" = true ] && { echo "error: cannot evaluate a configuration" >&2; exit 1; }
    drv=$(cat "$T/drv"); [ "${STUB_DRV_FROM_LOCK:-}" = 1 ] && drv=$(cksum < "$p/flake.lock" | cut -d' ' -f1)
    jq -n --arg d "$drv" --arg l "$(cat "$T/drv-linux")" --arg a "$(cat "$T/app-drv")" --arg c "$(cat "$T/cfg-drv")" \
      --arg expr "$*" --arg broken "${STUB_BROKEN_SYSTEM:-}" \
      --argjson haspk "$([ "${STUB_HAS_PACKAGES:-true}" = false ] && echo false || echo true)" \
      --argjson hascfg "${STUB_HAS_CONFIGS:-false}" '
      # Only what the expression asks for: its systems, and the configurations if it imports them.
      def asked($k): [ $expr | capture("\($k) = each \\(.*?\\) \\[(?<l>[^\\]]*)\\]").l | scan("\"([^\"]+)\"") | .[0] ];
      { packages: ([ asked("packages")[] | { (.): { p: ("/nix/store/" + (if . == "aarch64-linux" then $l else $d end) + ".drv") } } ] | add // {}),
        apps: ([ asked("apps")[] | { (.): { relock: [ "/nix/store/\($a).drv" ] } } ] | add // {}),
        configurations: (if ($expr | test("configurations = import ")) then
          { darwin: {}, nixos: (if $hascfg then { h: "/nix/store/\($c).drv" } else {} end) } else {} end) }' ;;
  # An app's program: its path, then its (empty) context — relock builds it, then runs it itself.
  *".program"*"getContext"*) echo '[]' ;;
  *"github:seedmatic/t/t-orphan/develop#apps."*"relock.program"*) printf '%s' "$T/relock-orphan" ;;
  *"github:seedmatic/t/develop#apps."*"relock.program"*) printf '%s' "$T/relock" ;;
  *"github:seedmatic/peer/develop#apps."*"relock.program"*)
    [ "${STUB_PEER:-ok}" = unbuildable ] && { echo "error: peer does not evaluate" >&2; exit 1; }
    [ "${STUB_PEER:-ok}" = cached ] && echo "warning: unable to download 'https://api.github.com/repos/seedmatic/peer/commits/develop'; using cached version" >&2
    printf '%s' "$T/relock-peer" ;;
  *"github:seedmatic/peer2/develop#apps."*"relock.program"*) printf '%s' "$T/relock-peer2" ;;
  *"after-x.program"*) printf '%s' "$T/bin/after-x" ;;
  *"flake update"*)
    case ${STUB_UPDATE:-none} in
      rev)    jq '.nodes.a.locked.rev = "r2"' flake.lock > l && mv l flake.lock; echo d2 > "$T/drv" ;;
      # A new revision at each run.
      revs)   n=$(( $(cat "$T/revn" 2>/dev/null || echo 1) + 1 )); echo "$n" > "$T/revn"
              jq --arg r "r$n" '.nodes.a.locked.rev = $r' flake.lock > l && mv l flake.lock; echo "d$n" > "$T/drv" ;;
      # Only another system's package moves: what a darwin seat must not drop.
      linux-only) jq '.nodes.a.locked.rev = "r2"' flake.lock > l && mv l flake.lock; echo lin2 > "$T/drv-linux" ;;
      # A real propagation: the upstream head t bumps `a`; a head that pins t takes t's pushed head.
      propagate)
        if jq -e '.nodes.t' flake.lock >/dev/null; then
          case "$*" in
            *"flake update t "*) r=$(git -C "$T/remote/seedmatic/t.git" rev-parse develop)
              jq --arg r "$r" '.nodes.t.locked.rev = $r' flake.lock > l && mv l flake.lock ;;
          esac
        else
          case "$*" in *"flake update a "*) jq '.nodes.a.locked.rev = "r2"' flake.lock > l && mv l flake.lock ;; esac
        fi ;;
      # Only a configuration moves: the bump of a contribution's pin, seen from its aggregator.
      config-only) jq '.nodes.a.locked.rev = "r2"' flake.lock > l && mv l flake.lock; echo cfg2 > "$T/cfg-drv" ;;
      one-fails)
        case "$*" in
          *"flake update a "*) jq '.nodes.a.locked.rev = "a2"' flake.lock > l && mv l flake.lock; echo d-a > "$T/drv" ;;
          *"flake update b "*) echo "error: cannot fetch b" >&2; exit 1 ;;
        esac ;;
      app-only) jq '.nodes.a.locked.rev = "r2"' flake.lock > l && mv l flake.lock; echo app2 > "$T/app-drv" ;;
      nested) jq '.nodes.x.locked.rev = "x2"' flake.lock > l && mv l flake.lock ;;
      path)   jq '.nodes.a.locked = {"type":"path","path":"/somewhere/local"}' flake.lock > l && mv l flake.lock ;;
      garbage) echo 'not json at all' > flake.lock ;;
      cached)  echo "warning: error: unable to download 'https://api.github.com/repos/o/r/commits/HEAD': HTTP error 404; using cached version" >&2 ;;
      cached-moved)
        jq '.nodes.a.locked.rev = "stale"' flake.lock > l && mv l flake.lock
        echo "warning: unable to download 'https://api.github.com/repos/o/r/commits/HEAD'" >&2 ;;
      failing) echo "error: cannot fetch" >&2; exit 1 ;;
      # The git fetcher's fallback: a warning, exit 0, the old revision.
      git-cached) echo "warning: could not update local clone of Git repository 'https://example/a.git'; continuing with the most recent version" >&2 ;;
      coupled|coupled-forever)
        case "$*" in
          *"flake update b "*)
            jq '.nodes.b.locked.rev = "b2"' flake.lock > l && mv l flake.lock; echo d-b > "$T/drv"; touch "$T/b-moved" ;;
          *"flake update a "*)
            if [ "$STUB_UPDATE" = coupled-forever ] || [ ! -f "$T/b-moved" ]; then
              echo "error: input 'a/x' follows a non-existent input 'b/x'" >&2; exit 1
            fi
            jq '.nodes.a.locked.rev = "a2"' flake.lock > l && mv l flake.lock; echo d-a > "$T/drv" ;;
        esac ;;
    esac ;;
  *) echo "fake nix: unexpected call: $*" >&2; exit 99 ;;
esac
FAKE

  # The fake GitHub API: a file of a head, served from $T/gh/<owner>/<repo>/<branch>/<path>, or curl's
  # own failure (22) when there is none. It records each URL, and what came on its stdin.
  printf '#!%s\n' "$(command -v bash)" > "$T/bin/curl"
  cat >> "$T/bin/curl" <<'FAKE'
cat >> "$T/curl-stdin"
url=""; for a in "$@"; do case $a in https://*) url=$a ;; esac; done
echo "$*" >> "$T/curl-calls"
[ "${STUB_API:-ok}" = fail ] && { echo "curl: (22) The requested URL returned error: 503" >&2; exit 22; }
r=${url#https://api.github.com/repos/}; repo=${r%%/contents/*}; rest=${r#*/contents/}
path=${rest%%\?ref=*}; ref=${rest#*\?ref=}; ref=${ref//%2F//}
[ -n "${STUB_API_FAIL:-}" ] && [ "$repo" = "$STUB_API_FAIL" ] && { echo "curl: (22) 404" >&2; exit 22; }
f="$T/gh/$repo/$ref/$path"
[ -f "$f" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cat "$f"
FAKE

  # `gh auth token`, simulated: a stand-in value, never a real token.
  printf '#!%s\n' "$(command -v bash)" > "$T/bin/gh"
  cat >> "$T/bin/gh" <<'FAKE'
[ "$1 $2" = "auth token" ] || exit 2
[ "${STUB_GH:-ok}" = fail ] && { echo "not logged in" >&2; exit 1; }
echo SIMULATED-GH-TOKEN
FAKE
  # The after-inputs app: it rewrites a tracked file, as lock-envs rewrites an env's lock.
  printf '#!%s\n' "$(command -v bash)" > "$T/bin/after-x"
  cat >> "$T/bin/after-x" <<'FAKE'
env > "$T/child-env.after"
case ${STUB_AFTER:-ok} in
  ok) echo relocked >> env.lock ;;
  none) : ;;
  fail) echo half >> env.lock; echo "after boom" >&2; exit 4 ;;
esac
FAKE
  chmod +x "$T/bin/nix" "$T/bin/curl" "$T/bin/gh" "$T/bin/after-x"
  export PATH="$T/bin:$PATH" T
  echo d1 > "$T/drv"
  echo app1 > "$T/app-drv"
  echo cfg1 > "$T/cfg-drv"
  echo lin1 > "$T/drv-linux"

  # The fabric's heads, as nix-flake-commons' fabric/heads serves them.
  put "seedmatic/nix-flake-commons" "fabric/heads" heads.json <<'JSON'
{ "schema": "seedmatic.fabric-heads/v1",
  "heads": {
    "flake-commons": { "repo": "seedmatic/nix-flake-commons", "branch": "develop", "kind": "code" },
    "t":        { "repo": "seedmatic/t",     "branch": "develop",          "kind": "code" },
    "t-orphan": { "repo": "seedmatic/t",     "branch": "t-orphan/develop", "kind": "code" },
    "peer":     { "repo": "seedmatic/peer",  "branch": "develop",          "kind": "code" },
    "peer2":    { "repo": "seedmatic/peer2", "branch": "develop",          "kind": "code" },
    "d":        { "repo": "seedmatic/peer",  "branch": "fabric/d",         "kind": "data" } } }
JSON
  # The pushed locks the plan reads: every head pins flake-commons; peer pins t, peer2 pins peer.
  lock_of nix-flake-commons develop
  lock_of t develop
  lock_of t t-orphan/develop
  lock_of peer develop t
  lock_of peer2 develop peer

  # A repository whose origin is the head's, on develop, so relock recognises it as its own.
  git init -q --bare --initial-branch=develop "$T/remote/seedmatic/t.git"
  git clone -q "$T/remote/seedmatic/t.git" "$T/work" 2>/dev/null
  cd "$T/work"
  git checkout -q -b develop 2>/dev/null || true
  echo '{}' > flake.nix
  echo 'env v1' > env.lock
  # Root inputs: `a` is a real node; `f` is a `follows` — an input PATH with no lock of its own.
  cat > flake.lock <<'LOCK'
{"nodes":{"root":{"inputs":{"a":"a","f":["a","x"]}},
 "a":{"locked":{"type":"github","rev":"r1"},"inputs":{"x":"x"}},
 "x":{"locked":{"type":"github","rev":"x1"}}},"root":"root","version":7}
LOCK
  git add flake.nix flake.lock env.lock && git commit -qm init && git push -qu origin develop 2>/dev/null
  # A requested run clones https://github.com/<repo>.git: send it to the local bare instead. A file://
  # url, because git ignores --depth for a plain local path: the clone must REALLY be shallow.
  git config --global url."file://$T/remote/seedmatic/t.git".insteadOf "https://github.com/seedmatic/t.git"
}

# A file of a head on the fake GitHub, from stdin.
put() { mkdir -p "$T/gh/$1/$2/$(dirname "$3")"; cat > "$T/gh/$1/$2/$3"; }
# A pushed lock for a head: it pins flake-commons at fc1, and each head named after its branch, by id.
lock_of() { # $1 repo  $2 branch  $3… ids it pins
  local repo=$1 branch=$2; shift 2
  jq -n --arg self "$repo" --args '{ version: 7, root: "root",
      nodes: ({ root: { inputs: ((if $self == "nix-flake-commons" then {} else { "flake-commons": "fc" } end) + ([ $ARGS.positional[] | { (.): . } ] | add // {})) },
                fc: { original: { type: "indirect", id: "flake-commons" },
                      locked: { type: "github", owner: "seedmatic", repo: "nix-flake-commons", rev: "fc1" } } }
              + ([ $ARGS.positional[] | { (.): { original: { type: "indirect", id: . },
                    locked: { type: "github", owner: "seedmatic", repo: ({ "t-orphan": "t", d: "peer" }[.] // .), rev: "\(.)1" } } } ] | add // {})) }' \
    "$@" | put "seedmatic/$repo" "$branch" flake.lock
}
# Bare remotes for the peers: a requested relock CLONES its repo, here through an insteadOf.
peers() {
  for r in "$@"; do
    git clone -q --bare "$T/remote/seedmatic/t.git" "$T/remote/seedmatic/$r.git"
    git config --global url."file://$T/remote/seedmatic/$r.git".insteadOf "https://github.com/seedmatic/$r.git"
  done
}
# The orphan project of t, pushed, with a worktree.
mk_orphan() {
  git -C "$T/work" checkout -q --orphan t-orphan/develop
  git -C "$T/work" commit -qm orphan
  git -C "$T/work" push -qu origin t-orphan/develop 2>/dev/null
}
never_updated() { ! grep -q "flake update" "$T/calls" 2>/dev/null; }
relock_commits() { git -C "$T/work" log --format=%s | grep -c '^chore(' || true; }
tree_clean()     { [ -z "$(git -C "$T/work" status --porcelain --untracked-files=no)" ]; }
lock_unchanged() { git -C "$T/work" diff --quiet HEAD -- flake.lock; }
remote_rev() { git -C "$T/remote/seedmatic/t.git" rev-parse --verify -q "refs/heads/$1" || echo none; }
trace_of() { git -C "$T/remote/seedmatic/${2:-t}.git" show "fabric/relock:$1.json" 2>/dev/null; }

# ── who this relock is ─────────────────────────────────────────────────────────────────────────────

@test "a relock whose name is not a code head of fabric/heads refuses before anything" {
  jq '.heads.t.kind = "data"' "$T/gh/seedmatic/nix-flake-commons/fabric/heads/heads.json" > x && mv x "$T/gh/seedmatic/nix-flake-commons/fabric/heads/heads.json"
  run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"'t' is not a code head of fabric/heads"* ]]
  never_updated
}

@test "fabric/heads that cannot be read refuses — the relock does not guess who it is" {
  STUB_API=fail run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read fabric/heads"* ]]
  never_updated
}

@test "fabric/heads of another schema refuses" {
  echo '{"heads":{}}' | put seedmatic/nix-flake-commons fabric/heads heads.json
  run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"no seedmatic.fabric-heads/v1"* ]]
}

@test "a head REFUSES a checkout of its repository on another head's branch" {
  mk_orphan
  run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"*"'t-orphan/develop'"*"another head"* ]]
  never_updated
  tree_clean
}

@test "an orphan project's head reconciles its own branch, and a session of it" {
  mk_orphan
  STUB_UPDATE=none run "$T/relock-orphan" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"reconciling the checkout at $T/work (t-orphan/develop)"* ]]
  git -C "$T/work" checkout -q -b t-orphan/feature/x
  STUB_UPDATE=none run "$T/relock-orphan" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"(t-orphan/feature/x)"* ]]
}

@test "a develop head accepts a session branch outside every head's namespace" {
  git -C "$T/work" checkout -q -b feature/x
  STUB_UPDATE=none run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"reconciling the checkout at $T/work (feature/x)"* ]]
}

@test "a requested run of an orphan project's head clones ITS branch" {
  mk_orphan
  git -C "$T/work" checkout -q develop
  mkdir -p "$T/outside" && cd "$T/outside"
  STUB_UPDATE=none run "$T/relock-orphan" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloned at t-orphan/develop"* ]]
}

@test "a committed registry that disagrees with fabric/heads refuses" {
  echo '{"version":2,"flakes":[{"from":{"type":"indirect","id":"peer"},"to":{"type":"github","owner":"seedmatic","repo":"elsewhere"}}]}' > "$T/work/flake-registry.json"
  git -C "$T/work" add flake-registry.json && git -C "$T/work" commit -qm reg && git -C "$T/work" push -q 2>/dev/null
  run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"disagrees with fabric/heads"*"peer: seedmatic/elsewhere at develop, but fabric/heads has seedmatic/peer at develop"* ]]
  never_updated
}

@test "a committed registry that names an orphan by its branch agrees with fabric/heads" {
  echo '{"version":2,"flakes":[{"from":{"type":"indirect","id":"t-orphan"},"to":{"type":"github","owner":"seedmatic","repo":"t","ref":"t-orphan/develop"}}]}' > "$T/work/flake-registry.json"
  git -C "$T/work" add flake-registry.json && git -C "$T/work" commit -qm reg && git -C "$T/work" push -q 2>/dev/null
  STUB_UPDATE=none run "$T/relock" inputs
  [ "$status" -eq 0 ]
}

# ── the local rule ─────────────────────────────────────────────────────────────────────────────────

@test "an untracked file does not block a run — nix never sees it" {
  touch "$T/work/scratch-from-another-session"
  STUB_UPDATE=none run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUSING"* ]]
}

@test "a tracked modification refuses — it would be credited to the bump" {
  echo '{ }' > "$T/work/flake.nix"
  run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING"* ]]
}

@test "a FAILING shape probe is fatal — it must not read as 'an aggregator'" {
  STUB_HAS_PACKAGES=fail STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -ne 0 ]
  [[ "$output" != *"DONE"* ]]
  [ "$(relock_commits)" -eq 0 ]
  tree_clean
  lock_unchanged
}

@test "a measured system that stops evaluating after a bump is fatal: not committed, the lock restored" {
  STUB_MEASURE=fail-after-first STUB_UPDATE=rev run "$T/relock" inputs
  [[ "$output" == *"FAILED to measure impact"* ]]
  [ "$(relock_commits)" -eq 0 ]
  tree_clean
  lock_unchanged
}

@test "a bump that moves a package is carried" {
  STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUMPED"* ]]
  [ "$(relock_commits)" -eq 1 ]
}

@test "a bump that moves ONLY an app's program is carried — relock ships itself that way" {
  STUB_UPDATE=app-only run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUMPED"* ]]
  [ "$(relock_commits)" -eq 1 ]
}

@test "a bump that moves ONLY a configuration is carried — a contribution travels that way" {
  STUB_HAS_CONFIGS=true STUB_UPDATE=config-only run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUMPED"* ]]
  [ "$(relock_commits)" -eq 1 ]
  grep -q "configurations.nix" "$T/calls"
}

@test "a flake with configurations and no packages is measured, not taken for an aggregator" {
  STUB_HAS_PACKAGES=false STUB_HAS_CONFIGS=true STUB_UPDATE=nested run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO derivation impact -> dropped"* ]]
  grep -q "relock:measure" "$T/calls"
  grep -q "configurations.nix" "$T/calls"
}

@test "a FAILING configurations measure is fatal — the bump is not carried, the lock restored" {
  STUB_HAS_CONFIGS=true STUB_CONFIGS=fail STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -ne 0 ]
  [ "$(relock_commits)" -eq 0 ]
  lock_unchanged
}

@test "a bump that moves neither a package, an app nor a configuration is dropped" {
  STUB_HAS_CONFIGS=true STUB_UPDATE=nested run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO derivation impact -> dropped"* ]]
  [ "$(relock_commits)" -eq 0 ]
  lock_unchanged
}

@test "a FAILING apps projection is fatal — the bump is not carried, the lock restored" {
  STUB_APPS=fail STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -ne 0 ]
  [ "$(relock_commits)" -eq 0 ]
  lock_unchanged
  tree_clean
}

@test "aggregator: a bump of a root input is carried — its inputs ARE what it exports" {
  STUB_HAS_PACKAGES=false STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUMPED"* ]]
  [ "$(relock_commits)" -eq 1 ]
}

@test "aggregator: a follows root input is left out of the impact projection" {
  STUB_HAS_PACKAGES=false STUB_UPDATE=nested run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO derivation impact"* ]]
  [ "$(relock_commits)" -eq 0 ]
}

@test "a re-aim at a local checkout is refused, and the lock is restored" {
  STUB_UPDATE=path run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED: 1 target(s)"* ]]
  [[ "$output" == *"LOCAL lock REFUSED"* ]]
  [ "$(relock_commits)" -eq 0 ]
  tree_clean
  lock_unchanged
}

@test "an unreadable lock after an update is NOT waved through the local-lock guard" {
  STUB_UPDATE=garbage run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED to read the updated lock"* ]]
  [ "$(relock_commits)" -eq 0 ]
  tree_clean
  lock_unchanged
}

@test "the local registry wins over the committed one — that is what the indirection is for" {
  echo '{"version":2,"flakes":[]}' > "$T/work/flake-registry.json"
  echo '{"version":2,"flakes":[]}' > "$T/work/flake-registry.local.json"
  git -C "$T/work" add flake-registry.json && git -C "$T/work" commit -qm reg && git -C "$T/work" push -q 2>/dev/null
  STUB_UPDATE=none run "$T/relock" inputs
  [ "$status" -eq 0 ]
  grep -q -- "--flake-registry $T/work/flake-registry.local.json flake update" "$T/calls"
}

@test "with no local override, the committed registry is used" {
  echo '{"version":2,"flakes":[]}' > "$T/work/flake-registry.json"
  git -C "$T/work" add flake-registry.json && git -C "$T/work" commit -qm reg && git -C "$T/work" push -q 2>/dev/null
  STUB_UPDATE=none run "$T/relock" inputs
  [ "$status" -eq 0 ]
  grep -q -- "--flake-registry $T/work/flake-registry.json flake update" "$T/calls"
}

@test "a fetch that fell back to a CACHE is a failure, never 'already current'" {
  STUB_UPDATE=cached run "$T/relock" --no-push inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED to fetch"*"cached copy"* ]]
  [[ "$output" == *"using cached version"* ]]
  [[ "$output" != *"already current"* ]]
  [ "$(relock_commits)" -eq 0 ]
  lock_unchanged
}

@test "a cache fallback that DID rewrite the lock is restored, not carried" {
  STUB_UPDATE=cached-moved run "$T/relock" --no-push inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED to fetch"* ]]
  [[ "$output" != *"BUMPED"* ]]
  lock_unchanged
}

@test "a failing update says why, with nix's own error" {
  STUB_UPDATE=failing run "$T/relock" --no-push inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED to resolve"* ]]
  [[ "$output" == *"cannot fetch"* ]]
  tree_clean
}

two_inputs() {
  cat > "$T/work/flake.lock" <<'LOCK'
{"nodes":{"root":{"inputs":{"a":"a","b":"b"}},
 "a":{"locked":{"type":"github","rev":"a1"}},
 "b":{"locked":{"type":"github","rev":"b1"}}},"root":"root","version":7}
LOCK
  git -C "$T/work" commit -qam two-inputs && git -C "$T/work" push -q 2>/dev/null
}

@test "a bump coupled to another input's waits for it, then is carried — whatever the order" {
  two_inputs
  STUB_UPDATE=coupled run "$T/relock" --no-push inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"deferred"* ]]
  [ "$(git -C "$T/work" log --format=%s -2 | tr '\n' '|')" = "chore(flake): relock a|chore(flake): relock b|" ]
}

@test "a coupling that persists is a clear failure, and leaves nothing behind" {
  two_inputs
  STUB_UPDATE=coupled-forever run "$T/relock" --no-push inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED — still coupled"* ]]
  [ "$(jq -r '.nodes.a.locked.rev' "$T/work/flake.lock")" = "a1" ]
  tree_clean
}

@test "one input that fails among others: the others are carried and pushed, the run ends non-zero naming it" {
  two_inputs
  STUB_UPDATE=one-fails run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED: 1 target(s)"*"input b"* ]]
  [ "$(git -C "$T/remote/seedmatic/t.git" show develop:flake.lock | jq -r .nodes.a.locked.rev)" = a2 ]
}

@test "--no-push commits in the checkout, pushes NOTHING, writes no trace, and prints how to resume" {
  before=$(remote_rev develop)
  STUB_UPDATE=rev run "$T/relock" --no-push inputs
  [ "$status" -eq 0 ]
  [ "$(relock_commits)" -eq 1 ]
  [ "$(remote_rev develop)" = "$before" ]
  [[ "$output" == *"To resume where this stopped:"*"git -C '$T/work' push"* ]]
  [ "$(remote_rev fabric/relock)" = none ]
}

@test "--no-push refuses a requested run: unpushed commits in a clone would be lost" {
  mkdir -p "$T/outside" && cd "$T/outside"
  run "$T/relock" --no-push inputs
  [ "$status" -eq 2 ]
  [[ "$output" == *"--no-push needs a checkout"* ]]
}

@test "--no-push with --downstream is refused: a head sees only what is pushed" {
  run "$T/relock" --no-push --downstream inputs
  [ "$status" -eq 2 ]
  [[ "$output" == *"contradict"* ]]
  never_updated
}

@test "a requested run clones shallow under a TMPDIR that crosses a symlink, and pushes fast-forward" {
  before=$(remote_rev develop)
  mkdir -p "$T/realtmp" && ln -s "$T/realtmp" "$T/linktmp"
  mkdir -p "$T/outside" && cd "$T/outside"
  TMPDIR="$T/linktmp" STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloned at develop"* ]]
  [[ "$output" == *"BUMPED"* ]]
  [[ "$output" != *"is a symlink"* ]]
  [ "$(git -C "$T/remote/seedmatic/t.git" show develop:flake.lock | jq -r .nodes.a.locked.rev)" = r2 ]
  [ "$(git -C "$T/remote/seedmatic/t.git" rev-parse "develop^")" = "$before" ]
}

# ── the token ──────────────────────────────────────────────────────────────────────────────────────

@test "the gh token reaches relock's own nix calls, appended — an inherited NIX_CONFIG survives" {
  NIX_CONFIG="flake-registry = /somewhere/registry.json" STUB_UPDATE=none run "$T/relock" --no-push inputs
  [ "$status" -eq 0 ]
  grep -q "extra-access-tokens = github.com=SIMULATED-GH-TOKEN" "$T/nix-config"
  grep -q "flake-registry = /somewhere/registry.json" "$T/nix-config"
}

@test "the token reaches the API on curl's stdin, never in its arguments" {
  STUB_UPDATE=none run "$T/relock" --no-push inputs
  [ "$status" -eq 0 ]
  grep -q "Authorization: Bearer SIMULATED-GH-TOKEN" "$T/curl-stdin"
  ! grep -q "SIMULATED-GH-TOKEN" "$T/curl-calls"
}

@test "the token is never printed" {
  STUB_UPDATE=rev run "$T/relock" --no-push
  [[ "$output" != *"SIMULATED-GH-TOKEN"* ]]
}

@test "no token from gh: said, and the run goes on without one" {
  STUB_GH=fail STUB_UPDATE=none run "$T/relock" --no-push inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"no GitHub token"* ]]
  ! grep -q "extra-access-tokens" "$T/nix-config"
  ! grep -q "Authorization" "$T/curl-stdin"
}

# ── after the inputs ───────────────────────────────────────────────────────────────────────────────

@test "an after-inputs app runs AFTER the inputs, and what it changes is committed" {
  STUB_UPDATE=rev STUB_AFTER=ok run "$T/relock-after"
  [ "$status" -eq 0 ]
  [ "$(git -C "$T/work" log --format=%s -2 | tr '\n' '|')" = "chore(relock): after-x after inputs|chore(flake): relock a|" ]
  tree_clean
}

@test "an after-inputs app that changes nothing commits nothing" {
  STUB_UPDATE=none STUB_AFTER=none run "$T/relock-after"
  [ "$status" -eq 0 ]
  [[ "$output" == *"after-x"*"already current"* ]]
  [ "$(relock_commits)" -eq 0 ]
}

@test "a failing after-inputs app restores the tree, commits nothing of its own, and says why" {
  STUB_UPDATE=none STUB_AFTER=fail run "$T/relock-after"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED (after-inputs app after-x)"* ]]
  [[ "$output" == *"after boom"* ]]
  [ "$(relock_commits)" -eq 0 ]
  tree_clean
}

@test "an after-inputs app is run WITHOUT the token" {
  STUB_UPDATE=none STUB_AFTER=ok run "$T/relock-after"
  [ -f "$T/child-env.after" ]
  ! grep -q "SIMULATED-GH-TOKEN" "$T/child-env.after"
}

# ── the trace ──────────────────────────────────────────────────────────────────────────────────────

@test "after a pushed change, the trace is written on fabric/relock, naming the pushed revision" {
  STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"trace written on fabric/relock (t.json)"* ]]
  tr=$(trace_of t)
  [ "$(jq -r .schema <<<"$tr")" = seedmatic.relock/v1 ]
  [ "$(jq -r .rev <<<"$tr")" = "$(remote_rev develop)" ]
  [ "$(jq -r '.status.bumped.a | join(">")' <<<"$tr")" = "r1>r2" ]
  [ "$(jq -r .status.tool <<<"$tr")" = "$RELOCK_TOOL_ID" ]
  # the head's own branch did not move for it
  [ "$(git -C "$T/remote/seedmatic/t.git" log --format=%s -1 develop)" = "chore(flake): relock a" ]
}

@test "two heads of one repository keep their own trace files on its fabric/relock" {
  STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 0 ]
  mk_orphan
  echo d3 > "$T/drv"
  jq '.nodes.a.locked.rev = "r5"' "$T/work/flake.lock" > "$T/x" && mv "$T/x" "$T/work/flake.lock"
  git -C "$T/work" commit -qam orphan-lock && git -C "$T/work" push -q 2>/dev/null
  STUB_UPDATE=rev run "$T/relock-orphan" inputs
  [ "$status" -eq 0 ]
  [ "$(jq -r .head <<<"$(trace_of t)")" = t ]
  [ "$(jq -r .head <<<"$(trace_of t-orphan)")" = t-orphan ]
  [ "$(jq -r .rev <<<"$(trace_of t-orphan)")" = "$(remote_rev t-orphan/develop)" ]
}

@test "a run that commits nothing writes no trace" {
  STUB_UPDATE=none run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [ "$(remote_rev fabric/relock)" = none ]
}

# ── the plan ───────────────────────────────────────────────────────────────────────────────────────

@test "--plan orders each head after what it pins, and covers what pins the start" {
  run "$T/relock" --plan
  [ "$status" -eq 0 ]
  [ "$(jq -c .order <<<"$output")" = '["t","t-orphan","peer","peer2"]' ]
  [ "$(jq -r '.tool.ref' <<<"$output")" = "github:seedmatic/nix-flake-commons/fc1" ]
  never_updated
}

@test "--plan from a head covers only what pins it, transitively" {
  mkdir -p "$T/outside" && cd "$T/outside"
  run "$T/relock-peer" --plan
  [ "$status" -eq 0 ]
  [ "$(jq -c .order <<<"$output")" = '["peer","peer2"]' ]
}

@test "a data head is a leaf: never read, never run, and what pins it is ordered after it" {
  lock_of peer develop t d
  run "$T/relock" --plan
  [ "$status" -eq 0 ]
  [ "$(jq -c .order <<<"$output")" = '["t","t-orphan","peer","peer2"]' ]
  jq -e '.edges | index({from: "peer", to: "d", input: "d"}) != null' <<<"$output"
  ! grep -q "fabric%2Fd\|fabric/d" "$T/curl-calls"
}

@test "a pin cycle fails the plan, naming each edge of the cycle and nothing downstream of it" {
  lock_of t develop peer
  run "$T/relock" --plan
  [ "$status" -eq 1 ]
  [[ "$(jq -r '.errors[0]' <<<"$output")" == "a cycle among peer, t: peer pins t (input \`t\`); t pins peer (input \`peer\`)"* ]]
  [[ "$(jq -r '.errors[0]' <<<"$output")" != *peer2* ]]
}

@test "an id that is not a head fails the plan, naming the head and the id" {
  lock_of peer2 develop peer ghost
  run "$T/relock" --plan
  [ "$status" -eq 1 ]
  [[ "$(jq -r '.errors[]' <<<"$output")" == *"peer2: input \`ghost\` pins the id \`ghost\`, which is not a head of fabric/heads"* ]]
}

@test "an id that resolves to another repository than its head's fails the plan" {
  lock_of peer2 develop peer
  jq '.nodes.peer.locked.repo = "elsewhere"' "$T/gh/seedmatic/peer2/develop/flake.lock" | put seedmatic/peer2 develop flake.lock
  run "$T/relock" --plan
  [ "$status" -eq 1 ]
  [[ "$(jq -r '.errors[]' <<<"$output")" == *"resolves the id \`peer\` to seedmatic/elsewhere, but fabric/heads has it on seedmatic/peer"* ]]
}

@test "a lock the API cannot serve fails the plan — no fallback, no partial plan" {
  STUB_API_FAIL=seedmatic/peer2 run "$T/relock" --plan
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO PLAN"*"cannot read the lock of peer2"* ]]
  never_updated
}

# ── the pass ───────────────────────────────────────────────────────────────────────────────────────

@test "--downstream plays the plan: each head once, in order, on the pass's tool, the start in its checkout" {
  mk_orphan
  git -C "$T/work" checkout -q develop
  peers peer peer2
  STUB_UPDATE=none run "$T/relock" --downstream
  [ "$status" -eq 0 ]
  [ "$(grep -E '^== (t|t-orphan|peer|peer2) ==$' <<<"$output" | tr '\n' ' ')" = "== t == == t-orphan == == peer == == peer2 == " ]
  [[ "$output" == *"reconciling the checkout at $T/work (develop)"* ]]
  [[ "$output" == *"relock(peer): not inside this head — cloning seedmatic/peer (develop)"* ]]
  grep -q -- '--override-input flake-commons github:seedmatic/nix-flake-commons/fc1 github:seedmatic/peer/develop#apps\..*\.relock\.program' "$T/calls"
  ! grep -q -- '--commit-lock-file' "$T/calls"
  [[ "$output" == *"DONE (pass t@"* ]]
}

@test "a head that fails is named, what pins it is not run, and the rest of the pass still runs" {
  mk_orphan
  git -C "$T/work" checkout -q develop
  peers peer peer2
  STUB_PEER=unbuildable STUB_UPDATE=none run "$T/relock" --downstream
  [ "$status" -eq 1 ]
  [[ "$output" == *"== peer2: NOT RUN — it pins peer, which did not land in this pass =="* ]]
  [[ "$output" == *"reconciling the checkout at $T/work (develop)"* ]]
  [[ "$output" == *"== t-orphan =="* ]]
  [[ "$output" == *"FAILED: 2 target(s)"*"head peer"*"head peer2 (pins peer)"* ]]
}

@test "the plan's errors stop the pass before anything moves" {
  lock_of t develop peer
  before=$(remote_rev develop)
  STUB_UPDATE=rev run "$T/relock" --downstream
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO PASS"*"a cycle among peer, t"* ]]
  never_updated
  [ "$(remote_rev develop)" = "$before" ]
}

@test "a pass whose tool reference holds other code refuses before anything moves" {
  before=$(remote_rev develop)
  STUB_TOOL_ID=other STUB_UPDATE=rev run "$T/relock" --downstream
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING --downstream: github:seedmatic/nix-flake-commons/fc1 is tool other"* ]]
  never_updated
  [ "$(remote_rev develop)" = "$before" ]
}

@test "--downstream from a session branch refuses: the heads after it pin what is pushed on the head's branch" {
  git -C "$T/work" checkout -q -b feature/x
  run "$T/relock" --downstream
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING --downstream from 'feature/x'"* ]]
  never_updated
}

@test "a member of a pass runs another tool's code? it refuses before anything" {
  echo '{"heads":{}}' > "$T/plan"
  RELOCK_PASS_PLAN="$T/plan" RELOCK_PASS_TOOL_ID=another STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING: relock(t) is tool $RELOCK_TOOL_ID, but this pass runs tool another"* ]]
  never_updated
}

@test "a member whose plan is gone refuses — it does not run outside its pass" {
  RELOCK_PASS_PLAN="$T/gone" RELOCK_PASS_TOOL_ID="$RELOCK_TOOL_ID" run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"the plan of this pass ($T/gone) is gone"* ]]
  never_updated
}

@test "a member called as another head refuses" {
  jq -n --slurpfile h "$T/gh/seedmatic/nix-flake-commons/fabric/heads/heads.json" '{heads: $h[0].heads}' > "$T/plan"
  RELOCK_PASS_PLAN="$T/plan" RELOCK_PASS_TOOL_ID="$RELOCK_TOOL_ID" RELOCK_HEAD=peer run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"the pass called head 'peer', but this relock is head 't'"* ]]
}

@test "a member reads the heads from its plan, not from the API" {
  jq -n --slurpfile h "$T/gh/seedmatic/nix-flake-commons/fabric/heads/heads.json" '{heads: $h[0].heads}' > "$T/plan"
  STUB_API=fail RELOCK_PASS_PLAN="$T/plan" RELOCK_PASS_TOOL_ID="$RELOCK_TOOL_ID" STUB_UPDATE=none run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [ ! -s "$T/curl-calls" ]
}

@test "another head's relock in a pass is run WITHOUT the token" {
  peers peer peer2
  mk_orphan
  git -C "$T/work" checkout -q develop
  printf '#!%s\nenv > "$T/child-env.peer"\n' "$(command -v bash)" > "$T/relock-peer"
  STUB_UPDATE=none run "$T/relock" --downstream
  [ -f "$T/child-env.peer" ]
  ! grep -q "SIMULATED-GH-TOKEN" "$T/child-env.peer"
  grep -q '^RELOCK_PASS_PLAN=' "$T/child-env.peer"
  grep -q '^RELOCK_HEAD=peer$' "$T/child-env.peer"
}

# ── review of 1a: the start refuses what this run did not make ─────────────────────────────────────

@test "a head AHEAD of its upstream refuses at the start — those commits are not this run's" {
  echo other > "$T/work/other" && git -C "$T/work" add other && git -C "$T/work" commit -qm "another session's"
  before=$(remote_rev develop)
  STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING: develop is 1 commit(s) ahead of its upstream"*"another session's"* ]]
  never_updated
  [ "$(remote_rev develop)" = "$before" ]
}

@test "an uncommitted flake.lock refuses at the start — and the edit survives" {
  jq '.nodes.x.locked = {"type":"path","path":"/somewhere/local"}' "$T/work/flake.lock" > "$T/x" && mv "$T/x" "$T/work/flake.lock"
  STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING: the worktree carries uncommitted changes"*"flake.lock"* ]]
  never_updated
  [ "$(jq -r .nodes.x.locked.path "$T/work/flake.lock")" = /somewhere/local ]
}

# ── review of 1a: every system is measured ─────────────────────────────────────────────────────────

@test "a bump that moves ONLY another system's package is carried — a darwin seat must not drop it" {
  STUB_SYSTEMS="aarch64-darwin aarch64-linux" STUB_UPDATE=linux-only run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUMPED"* ]]
  [ "$(relock_commits)" -eq 1 ]
}

@test "a system that does not evaluate before any bump is said and left out; the run goes on" {
  STUB_SYSTEMS="aarch64-darwin x86_64-darwin" STUB_BROKEN_SYSTEM=x86_64-darwin STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"packages of x86_64-darwin: one of them does not evaluate before any bump, so none of x86_64-darwin is measured — error: attribute 'x86_64-darwin' missing"* ]]
  [[ "$output" == *"BUMPED"* ]]
  ! grep 'relock:measure' "$T/calls" | grep -q '"x86_64-darwin"'
}

# ── review of 1a: the trace, absent, rejected, or unreachable ───────────────────────────────────────

reject_trace_pushes() { # $1 how many pushes to fabric/relock the remote rejects
  echo "$1" > "$T/rejects"
  cat > "$T/remote/seedmatic/t.git/hooks/pre-receive" <<HOOK
#!$(command -v bash)
while read -r _ _ ref; do
  if [ "\$ref" = refs/heads/fabric/relock ]; then
    n=\$(cat "$T/rejects"); [ "\$n" -gt 0 ] && { echo \$((n - 1)) > "$T/rejects"; echo "rejected by the test" >&2; exit 1; }
  fi
done
exit 0
HOOK
  chmod +x "$T/remote/seedmatic/t.git/hooks/pre-receive"
}

@test "a trace that cannot be written is its own failure, exit 75 — the change itself has landed" {
  reject_trace_pushes 2
  STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 75 ]
  [[ "$output" == *"FAILED to write the trace on fabric/relock — the change itself is pushed, and has landed"* ]]
  [[ "$output" == *"trace t (its change landed)"* ]]
  [ "$(git -C "$T/remote/seedmatic/t.git" show develop:flake.lock | jq -r .nodes.a.locked.rev)" = r2 ]
}

@test "a rejected trace push is retried ONCE, on a fresh fetch" {
  reject_trace_pushes 1
  STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"the trace's push was rejected — fetching fabric/relock again, once"* ]]
  [ "$(jq -r .head <<<"$(trace_of t)")" = t ]
}

@test "a remote that cannot be read is never taken for an absent trace branch" {
  # The remote vanishes once the change is pushed: ls-remote can no longer answer.
  cat > "$T/remote/seedmatic/t.git/hooks/post-receive" <<HOOK
#!$(command -v bash)
mv "$T/remote/seedmatic/t.git" "$T/remote/seedmatic/t.git.gone"
HOOK
  chmod +x "$T/remote/seedmatic/t.git/hooks/post-receive"
  STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 75 ]
  [[ "$output" == *"cannot tell whether fabric/relock exists"* ]]
  ! git -C "$T/remote/seedmatic/t.git.gone" rev-parse -q --verify refs/heads/fabric/relock
}

@test "the trace never makes the operator's repository shallow" {
  # Three changes: fabric/relock has history to cut by the third.
  for i in 1 2 3; do
    STUB_UPDATE=revs run "$T/relock" inputs
    [ "$status" -eq 0 ]
    [[ "$output" == *"trace written"* ]]
  done
  [ "$(git -C "$T/remote/seedmatic/t.git" rev-list --count fabric/relock)" -eq 3 ]
  [ ! -f "$(git -C "$T/work" rev-parse --git-common-dir)/shallow" ]
}

@test "in a pass, a head whose trace failed still lets what pins it run; the pass ends 75" {
  mk_orphan
  git -C "$T/work" checkout -q develop
  peers peer peer2
  reject_trace_pushes 9
  STUB_UPDATE=rev run "$T/relock" --downstream
  [ "$status" -eq 75 ]
  [[ "$output" == *"t landed, but its trace was not written"* ]]
  [[ "$output" == *"^ peer done"* ]]
  [[ "$output" != *"NOT RUN"* ]]
}

# ── review of 1a: the plan ─────────────────────────────────────────────────────────────────────────

@test "a head that pins its own id fails the plan — a cycle of one" {
  lock_of peer2 develop peer peer2
  run "$T/relock" --plan
  [ "$status" -eq 1 ]
  [[ "$(jq -r '.errors[]' <<<"$output")" == *"peer2: input \`peer2\` pins its own id — a cycle of one"* ]]
}

@test "another head's relock served from nix's cache is refused, and what pins it is not run" {
  mk_orphan
  git -C "$T/work" checkout -q develop
  peers peer peer2
  STUB_PEER=cached STUB_UPDATE=none run "$T/relock" --downstream
  [ "$status" -eq 1 ]
  [[ "$output" == *"nix answered from its cache — refusing that answer"* ]]
  [[ "$output" == *"FAILED — cannot build peer's relock"* ]]
  [[ "$output" == *"peer2: NOT RUN — it pins peer"* ]]
  grep -q -- 'eval --raw --refresh --override-input flake-commons' "$T/calls"
}

# ── review of 1a: a REAL propagation ───────────────────────────────────────────────────────────────

@test "a pass PROPAGATES: t pushes its bump, peer pins t's pushed head, both traced" {
  peers peer peer2
  # peer's own lock pins t at the current head.
  git clone -q "$T/remote/seedmatic/peer.git" "$T/peer-src"
  jq --arg r "$(remote_rev develop)" '.nodes.root.inputs.t = "t" | .nodes.t = {"locked":{"type":"github","owner":"seedmatic","repo":"t","rev":$r}}' \
    "$T/peer-src/flake.lock" > "$T/x" && mv "$T/x" "$T/peer-src/flake.lock"
  git -C "$T/peer-src" commit -qam "peer pins t" && git -C "$T/peer-src" push -q 2>/dev/null
  git clone -q --bare "$T/remote/seedmatic/t.git" "$T/remote/seedmatic/t-orphan-src.git"
  mk_orphan
  git -C "$T/work" checkout -q develop
  STUB_DRV_FROM_LOCK=1 STUB_UPDATE=propagate run "$T/relock" --downstream
  [ "$status" -eq 0 ]
  t_head=$(remote_rev develop)
  [ "$(git -C "$T/remote/seedmatic/t.git" show develop:flake.lock | jq -r .nodes.a.locked.rev)" = r2 ]
  [ "$(git -C "$T/remote/seedmatic/peer.git" show develop:flake.lock | jq -r .nodes.t.locked.rev)" = "$t_head" ]
  [ "$(jq -r .rev <<<"$(trace_of t)")" = "$t_head" ]
  [ "$(jq -r '.status.bumped.t[1]' <<<"$(git -C "$T/remote/seedmatic/peer.git" show fabric/relock:peer.json)")" = "$t_head" ]
}

# ── review of f6ac9fd ──────────────────────────────────────────────────────────────────────────────

@test "a starter AHEAD of its upstream refuses before the first head runs, even when it is not first" {
  lock_of t develop t-orphan
  mk_orphan
  git -C "$T/work" checkout -q develop
  echo other > "$T/work/other" && git -C "$T/work" add other && git -C "$T/work" commit -qm "another session's"
  before=$(git -C "$T/remote/seedmatic/t.git" rev-parse t-orphan/develop)
  STUB_UPDATE=rev run "$T/relock" --downstream
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING: develop is 1 commit(s) ahead of its upstream"* ]]
  [[ "$output" != *"== t-orphan =="* ]]
  never_updated
  [ "$(git -C "$T/remote/seedmatic/t.git" rev-parse t-orphan/develop)" = "$before" ]
}

@test "a starter with an uncommitted flake.lock refuses before the first head runs" {
  lock_of t develop t-orphan
  mk_orphan
  git -C "$T/work" checkout -q develop
  jq '.nodes.x.locked.rev = "edited"' "$T/work/flake.lock" > "$T/x" && mv "$T/x" "$T/work/flake.lock"
  STUB_UPDATE=rev run "$T/relock" --downstream
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING: the worktree carries uncommitted changes"* ]]
  [[ "$output" != *"== t-orphan =="* ]]
  never_updated
}

@test "what the guard does not measure is in the final summary and in the trace" {
  STUB_SYSTEMS="aarch64-darwin x86_64-darwin" STUB_BROKEN_SYSTEM=x86_64-darwin STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$(tail -n 4 <<<"$output")" == *"NOT MEASURED by the impact guard"*"packages of x86_64-darwin"*"DONE"* ]]
  [[ "$(jq -r '.status.unmeasured[0]' <<<"$(trace_of t)")" == "packages of x86_64-darwin: one of them does not evaluate"* ]]
}

@test "the git fetcher's fallback to its old clone is a failure, never 'already current'" {
  STUB_UPDATE=git-cached run "$T/relock" --no-push inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED to fetch"* ]]
  [[ "$output" == *"could not update local clone of Git repository"* ]]
  [[ "$output" != *"already current"* ]]
}
