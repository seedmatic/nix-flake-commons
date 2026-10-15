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
  # relock signs every commit it pushes (-S): a throwaway ssh key is the test's signer.
  ssh-keygen -q -t ed25519 -N '' -C relock-test -f "$T/signing" >/dev/null
  git config --global gpg.format ssh
  git config --global user.signingkey "$T/signing.pub"
  mkdir -p "$T/bin" "$T/remote/seedmatic" "$T/gh"
  for v in RELOCK RELOCK_ORPHAN RELOCK_PEER RELOCK_PEER2 SWEEP; do
    f=$(printf '%s' "$v" | tr 'A-Z_' 'a-z-')
    sed '/^export PATH=/d' "${!v}" > "$T/$f"
    chmod +x "$T/$f"
  done

  # The fake nix. It records every call, and answers each question relock asks. Its shebang is the
  # bash on PATH, not /usr/bin/env: the Linux build sandbox does not promise /usr/bin/env.
  printf '#!%s\n' "$(command -v bash)" > "$T/bin/nix"
  cat >> "$T/bin/nix" <<'FAKE'
# The fake's own calls to itself (a whole measure answered from its projections) are not relock's.
if [ -n "${STUB_PREV:-}" ]; then echo "$*" >> "$T/calls-inner"; else echo "$*" >> "$T/calls"; fi
printf '%s\n' "${NIX_CONFIG:-}" >> "$T/nix-config"
# What nix reads of a git+file flake (measured on nix 2.34.8). Given `rev`, the git objects — and a
# shallow repository needs `shallow=1`. Without `rev`, the working tree's files FROM DISK, clean or
# dirty: such a call is recorded, for the teardown to refuse, and refused like nix refuses it once
# its path crosses a symlink and the tree is dirty. In whatever tree a call names, a smudged file is
# recorded.
rev=""
for a in "$@"; do
  case $a in
    *git+file://*) p=${a#*git+file://}; p=${p%%[\"#]*} ;;
    /*\#*|.\#*) p=${a%%#*} ;;
    *) continue ;;
  esac
  q=""; case $p in *\?*) q=${p#*\?}; p=${p%%\?*} ;; esac
  rev=$(sed -n 's/.*rev=\([0-9a-f]\{40\}\).*/\1/p' <<<"$q")
  if [ -z "$rev" ]; then
    echo "$a" >> "$T/worktree-refs"
    if [[ $p == /* ]] && [ -d "$p" ] && [ "$(cd "$p" && pwd -P)" != "$p" ] && [ -n "$(git -C "$p" status --porcelain --untracked-files=no)" ]; then
      echo "error: path '$p' is a symlink" >&2; exit 1
    fi
  elif [ "$(git -C "$p" rev-parse --is-shallow-repository)" = true ] && [[ $q != *shallow=1* ]]; then
    echo "error: '$p' is a shallow Git repository, but shallow repositories are only allowed when \`shallow = true;\` is specified" >&2; exit 1
  fi
  if [ -d "$p" ]; then grep -rlsF --exclude-dir=.git SMUDGED-PLAINTEXT "$p" >> "$T/smudged" || true; fi
done
case "$*" in
  *"#lib.relockToolId"*) printf '%s' "${STUB_TOOL_ID:-$RELOCK_TOOL_ID}" ;;
  # What the head exports: its systems, and whether it has configurations.
  *"relock:shape"*)
    if [ -n "${STUB_SLOW:-}" ]; then
      h=${RELOCK_HEAD:-?}; echo "start $h $(date +%s%N | cut -c1-13)" >> "$T/slow"; sleep "$STUB_SLOW"; echo "end $h $(date +%s%N | cut -c1-13)" >> "$T/slow"
    fi
    [ "${STUB_HAS_PACKAGES:-true}" = fail ] && { echo "error: cannot evaluate packages" >&2; exit 1; }
    systems=$(printf '%s\n' ${STUB_SYSTEMS:-aarch64-darwin} | jq -R . | jq -sc .)
    pk=$systems; [ "${STUB_HAS_PACKAGES:-true}" = false ] && pk='[]'
    printf '{"packages":%s,"apps":%s,"configurations":%s}\n' "$pk" "$systems" "${STUB_HAS_CONFIGS:-false}" ;;
  # A whole measure, in one evaluation: it counts the measures, and answers from its projections,
  # each asked of this same fake (so one projection failing fails the whole, as in nix).
  *"relock:measure all"*)
    all="$*"; prev=$(cat "$T/measures" 2>/dev/null || echo 0); n=$((prev + 1)); echo "$n" > "$T/measures"
    [ "${STUB_MEASURE:-ok}" = fail-after-first ] && [ "$n" -gt 1 ] && { echo "error: cannot evaluate packages" >&2; exit 1; }
    [ "${STUB_MEASURE:-ok}" = fail ] && { echo "error: cannot evaluate packages" >&2; exit 1; }
    ref=$(sed -n 's/.*getFlake "\([^"]*\)".*/\1/p' <<<"$all")
    # A measure that names no list of systems is no measure: say so, as nix would refuse to parse it.
    for k in packages apps; do
      [[ "$all" =~ $k\ =\ each\ \(.*\)\ \[[^]]*\] ]] || { echo "error: syntax error, unexpected ';' (no $k systems)" >&2; exit 1; }
    done
    res='{"packages":{},"apps":{}}'
    for k in packages apps; do
      for s in $(jq -rn --arg e "$all" --arg k "$k" '$e | capture("\($k) = each \\(.*?\\) \\[(?<l>[^\\]]*)\\]").l | scan("\"([^\"]+)\"") | .[0]'); do
        piece=$(STUB_PREV=$prev "$0" eval --impure --json --expr "/* relock:measure $k $s */ let o = (builtins.getFlake \"$ref\").outputs; in x") || exit 1
        res=$(jq -c --arg k "$k" --arg s "$s" --argjson p "$piece" '.[$k][$s] = $p' <<<"$res")
      done
    done
    cfg=$(STUB_PREV=$prev "$0" eval --impure --json --expr "/* relock:measure configurations */ let o = (builtins.getFlake \"$ref\").outputs; in x") || exit 1
    jq --argjson c "$cfg" '. + { configurations: $c }' <<<"$res" ;;
  # One projection of a measure: the packages or the apps of one system, or the configurations.
  *"relock:measure configurations"*)
    n=$(cat "$T/measures" 2>/dev/null || echo 0)
    [ "${STUB_MEASURE:-ok}" = fail-after-first ] && [ "$n" -gt 1 ] && { echo "error: cannot evaluate packages" >&2; exit 1; }
    [ "${STUB_MEASURE:-ok}" = fail ] && { echo "error: cannot evaluate packages" >&2; exit 1; }
    [ "${STUB_CONFIGS:-ok}" = fail ] && [ "${STUB_HAS_CONFIGS:-false}" = true ] && { echo "error: cannot evaluate a configuration" >&2; exit 1; }
    jq -n --arg c "$(cat "$T/cfg-drv")" --argjson hascfg "${STUB_HAS_CONFIGS:-false}" \
      '{ darwin: {}, nixos: (if $hascfg then { h: "/nix/store/\($c).drv" } else {} end) }' ;;
  *"relock:measure "*)
    all="$*"; m=${all#*relock:measure }; kind=${m%% *}; sys=${m#* }; sys=${sys%% *}
    if [ -n "${STUB_BROKEN_SYSTEM:-}" ] && [ "$sys" = "$STUB_BROKEN_SYSTEM" ]; then
      if [ "${STUB_ERROR_STYLE:-}" = nix ]; then
        printf "error:\n       … while evaluating the attribute 'packages'\n\n       error: attribute '%s' missing\n" "$sys" >&2
      else
        echo "error: attribute '$sys' missing" >&2
      fi
      exit 1
    fi
    [ -n "${STUB_EVAL_WARNING:-}" ] && echo "evaluation warning: $STUB_EVAL_WARNING" >&2
    # A system broken BY a bump: it evaluates at the pushed head, not at any other revision.
    if [ -n "${STUB_BREAKS_ON_BUMP:-}" ] && [ "$sys" = "$STUB_BREAKS_ON_BUMP" ] \
      && [ "$rev" != "$(git -C "$T/remote/seedmatic/t.git" rev-parse develop)" ]; then
      echo "error: attribute 'broken-by-the-bump' missing" >&2; exit 1
    fi
    # An apps projection that fails once a measure has run: broken by a bump, not before the run.
    before=${STUB_PREV:-$(cat "$T/measures" 2>/dev/null || echo 0)}
    [ "$kind" = apps ] && [ "${STUB_APPS:-ok}" = fail ] && [ "$before" -ge 1 ] && { echo "error: cannot evaluate apps" >&2; exit 1; }
    [ "$kind" = packages ] && [ "${STUB_MEASURE:-ok}" = fail-after-first ] && [ "$before" -ge 1 ] && { echo "error: cannot evaluate packages" >&2; exit 1; }
    drv=$(cat "$T/drv"); [ "${STUB_DRV_FROM_LOCK:-}" = 1 ] && drv=$(git -C "$p" show "$rev:flake.lock" | cksum | cut -d' ' -f1)
    if [ "$kind" = packages ]; then
      d=$drv; [ "$sys" = aarch64-linux ] && d=$(cat "$T/drv-linux")
      jq -n --arg d "$d" '{ p: ("/nix/store/" + $d + ".drv") }'
    else
      jq -n --arg a "$(cat "$T/app-drv")" '{ relock: [ "/nix/store/\($a).drv" ] }'
    fi ;;
  # An app's program: its path, then its (empty) context — relock builds it, then runs it itself.
  *"getContext"*) echo '[]' ;;
  # A member's relock, built from the pass's tool: the head is named in the function applied to it.
  *"#lib.relockOf --apply"*)
    case "$*" in
      *'"t-orphan"'*) printf '%s' "$T/relock-orphan" ;;
      *'"peer2"'*) printf '%s' "$T/relock-peer2" ;;
      *'"peer"'*)
        [ "${STUB_PEER:-ok}" = unbuildable ] && { echo "error: peer's relock does not build" >&2; exit 1; }
        [ "${STUB_PEER:-ok}" = cached ] && echo "warning: unable to download 'https://api.github.com/repos/seedmatic/nix-flake-commons/commits/fc1'; using cached version" >&2
        printf '%s' "$T/relock-peer" ;;
      *'"t"'*) printf '%s' "$T/relock" ;;
      *) echo "error: no such head" >&2; exit 1 ;;
    esac ;;
  *".after-x --apply"*) printf '%s' "$T/bin/after-x" ;;
  *"flake update"*)
    # A flake read by revision has its lock written only where it is told to.
    out=""; prev=""; for a in "$@"; do [ "$prev" = --output-lock-file ] && out=$a; prev=$a; done
    [[ "$*" == *"--flake git+file://"* ]] || echo "flake update in $PWD" >> "$T/worktree-refs"
    [ -n "$out" ] || { echo "error: cannot write modified lock file of flake (use '--output-lock-file')" >&2; exit 1; }
    cd "$(dirname "$out")"
    # Each input named that pins a head resolves to that head's tip, as the real nix resolves it.
    names=(); seen=0
    for a in "$@"; do
      if [ "$seen" = 1 ]; then case $a in --*) break ;; *) names+=("$a") ;; esac; fi
      [ "$a" = update ] && seen=1
    done
    for i in "${names[@]}"; do
      id=$(jq -r --arg i "$i" '.nodes.root.inputs[$i] as $n | if ($n | type) == "string" then (.nodes[$n].original | select(.type == "indirect") | .id) // empty else empty end' flake.lock)
      [ -n "$id" ] || continue
      h=$(jq -c --arg i "$id" '.heads[$i] // empty' "$T/gh/seedmatic/nix-flake-commons/fabric/heads/heads.json")
      [ -n "$h" ] || continue
      # Someone else pushes to the head while the pass runs: once, just before this resolution.
      if [ -n "${STUB_RACE:-}" ] && [ "$id" = "$STUB_RACE" ] && [ ! -f "$T/raced" ]; then
        bare="$T/remote/$(jq -r .repo <<<"$h").git"; touch "$T/raced"
        c=$(git -C "$bare" commit-tree "develop^{tree}" -p develop -m "someone else's push")
        git -C "$bare" update-ref refs/heads/develop "$c"
      fi
      if tip=$("$T/bin/fake-tip" "$(jq -r .repo <<<"$h")" "$(jq -r .branch <<<"$h")" 2>/dev/null) \
        && [ "$(jq -r --arg i "$i" '.nodes[.nodes.root.inputs[$i]].locked.rev' flake.lock)" != "$tip" ]; then
        jq --arg i "$i" --arg r "$tip" '.nodes[.nodes.root.inputs[$i]].locked.rev = $r' flake.lock > l && mv l flake.lock
      fi
    done
    # Only edges asked for: they resolved above, and the mode's scenario is about the other inputs.
    only_edges=1
    for i in "${names[@]}"; do
      jq -e --arg i "$i" '.nodes.root.inputs[$i] as $n | ($n | type) == "string" and .nodes[$n].original.type == "indirect"' flake.lock >/dev/null || only_edges=0
    done
    if [ "$only_edges" = 1 ] && [ "${#names[@]}" -gt 0 ] && [[ "${STUB_UPDATE:-none}" != edges && "${STUB_UPDATE:-none}" != propagate ]]; then exit 0; fi
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
      # `a` drops its input `x` upstream: x's node and the follows through it leave the lock, no
      # derivation moves — a lock-only cleanup (bird, claude-hub).
      pruned) jq 'del(.nodes.x) | del(.nodes.a.inputs.x) | del(.nodes.root.inputs.f)' flake.lock > l && mv l flake.lock ;;
      path)   jq '.nodes.a.locked = {"type":"path","path":"/somewhere/local"}' flake.lock > l && mv l flake.lock ;;
      garbage) echo 'not json at all' > flake.lock ;;
      cached)  echo "warning: error: unable to download 'https://api.github.com/repos/o/r/commits/HEAD': HTTP error 404; using cached version" >&2 ;;
      cached-moved)
        jq '.nodes.a.locked.rev = "stale"' flake.lock > l && mv l flake.lock
        echo "warning: unable to download 'https://api.github.com/repos/o/r/commits/HEAD'" >&2 ;;
      failing) echo "error: cannot fetch" >&2; exit 1 ;;
      # The git fetcher's fallback: a warning, exit 0, the old revision.
      git-cached) echo "warning: could not update local clone of Git repository 'https://example/a.git'; continuing with the most recent version" >&2 ;;
      # Two edges coupled like ndh and flake-commons: either one alone breaks a follows; together they
      # move, and no exported derivation moves with them.
      edges)
        if [[ " $* " == *" flake-commons "* && " $* " == *" peer "* ]]; then
          jq '.nodes.fc.locked.rev = "fc2" | .nodes.peer.locked.rev = "peer2"' flake.lock > l && mv l flake.lock
        elif [[ " $* " == *" flake-commons "* || " $* " == *" peer "* ]]; then
          echo "error: input 'peer/bird' follows a non-existent input 'peer/flake-commons/bird'" >&2; exit 1
        else
          jq '.nodes.a.locked.rev = "r2"' flake.lock > l && mv l flake.lock
        fi ;;
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
  # sweep-configurations' measure: a flake with no configurations.
  *"neutralise = "*) echo '{"nixos":{},"darwin":{}}' ;;
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
r=${url#https://api.github.com/repos/}
if [[ "$r" == */commits/* ]]; then
  [ "${STUB_TIPS:-ok}" = fail ] && { echo "curl: (22) The requested URL returned error: 403" >&2; exit 22; }
  ref=${r#*/commits/}; ref=${ref//%2F//}
  if [ -n "${STUB_RACE_AFTER:-}" ] && [ "${r%%/commits/*}" = "seedmatic/$STUB_RACE_AFTER" ] && [ ! -f "$T/raced-after" ]; then
    touch "$T/raced-after"; bare="$T/remote/seedmatic/$STUB_RACE_AFTER.git"
    c=$(git -C "$bare" commit-tree "$ref^{tree}" -p "$ref" -m "someone else's push, after the head ended")
    git -C "$bare" update-ref "refs/heads/$ref" "$c"
  fi
  exec "$T/bin/fake-tip" "${r%%/commits/*}" "$ref"
fi
repo=${r%%/contents/*}; rest=${r#*/contents/}
path=${rest%%\?ref=*}; ref=${rest#*\?ref=}; ref=${ref//%2F//}
[ -n "${STUB_API_FAIL:-}" ] && [ "$repo" = "$STUB_API_FAIL" ] && { echo "curl: (22) 404" >&2; exit 22; }
f="$T/gh/$repo/$ref/$path"
[ -f "$f" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cat "$f"
FAKE

  # A branch's tip as the API reports it: a pinned fixture value ($T/gh/<repo>/<branch>/.tip), else
  # the bare's branch, else 404.
  printf '#!%s\n' "$(command -v bash)" > "$T/bin/fake-tip"
  cat >> "$T/bin/fake-tip" <<'FAKE'
if [ -f "$T/gh/$1/$2/.tip" ]; then cat "$T/gh/$1/$2/.tip"; exit 0; fi
git -C "$T/remote/$1.git" rev-parse --verify -q "refs/heads/$2" 2>/dev/null && exit 0
echo "curl: (22) The requested URL returned error: 404" >&2; exit 22
FAKE
  # What a push lands, the API serves: a bare's post-receive copies a pushed flake.lock into $T/gh.
  printf '#!%s\n' "$(command -v bash)" > "$T/bin/api-sync"
  cat >> "$T/bin/api-sync" <<'FAKE'
repo=$(basename "$(dirname "$PWD")")/$(basename "$PWD" .git)
while read -r _ new ref; do
  b=${ref#refs/heads/}
  git cat-file -e "$new:flake.lock" 2>/dev/null || continue
  mkdir -p "$T/gh/$repo/$b" && git show "$new:flake.lock" > "$T/gh/$repo/$b/flake.lock"
done
FAKE
  chmod +x "$T/bin/fake-tip" "$T/bin/api-sync"

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
  # flake-commons has no bare: its tip is the one every fixture lock pins.
  echo fc1 > "$T/gh/seedmatic/nix-flake-commons/develop/.tip"

  # A repository whose origin is the head's, on develop, so relock recognises it as its own.
  git init -q --bare --initial-branch=develop "$T/remote/seedmatic/t.git"
  ln -s "$T/bin/api-sync" "$T/remote/seedmatic/t.git/hooks/post-receive"
  git clone -q "$T/remote/seedmatic/t.git" "$T/work" 2>/dev/null
  cd "$T/work"
  git checkout -q -b develop 2>/dev/null || true
  echo '{}' > flake.nix
  echo 'env v1' > env.lock
  # Root inputs: `a` is a real node; `f` is a `follows` — an input PATH with no lock of its own;
  # `flake-commons` is an edge, as in every head.
  cat > flake.lock <<'LOCK'
{"nodes":{"root":{"inputs":{"a":"a","f":["a","x"],"flake-commons":"fc"}},
 "fc":{"original":{"type":"indirect","id":"flake-commons"},"locked":{"type":"github","owner":"seedmatic","repo":"nix-flake-commons","rev":"fc1"}},
 "a":{"locked":{"type":"github","rev":"r1"},"inputs":{"x":"x"}},
 "x":{"locked":{"type":"github","rev":"x1"}}},"root":"root","version":7}
LOCK
  git add flake.nix flake.lock env.lock && git commit -qm init && git push -qu origin develop 2>/dev/null
  # A requested run clones https://github.com/<repo>.git: send it to the local bare instead. A file://
  # url, because git ignores --depth for a plain local path: the clone must REALLY be shallow.
  git config --global url."file://$T/remote/seedmatic/t.git".insteadOf "https://github.com/seedmatic/t.git"
}

# The invariant of every case: nix is never handed a working tree.
teardown() {
  if [ -s "$T/worktree-refs" ]; then
    echo "nix was handed a working tree:"
    cat "$T/worktree-refs"
    return 1
  fi
}

# The operator's git as it is: a sops-like filter configured GLOBALLY, whose smudge writes a committed
# secret decrypted into every checkout — here, a marker the fake nix looks for in each tree it is
# handed. The checkout under test is checked out through it again, so it holds the plaintext.
smudging_secret() {
  git config --global filter.fakesops.smudge 'sed s/ENCRYPTED/SMUDGED-PLAINTEXT/'
  git config --global filter.fakesops.clean 'sed s/SMUDGED-PLAINTEXT/ENCRYPTED/'
  git config --global filter.fakesops.required true
  echo 'secret filter=fakesops' > "$T/work/.gitattributes"
  echo ENCRYPTED > "$T/work/secret"
  git -C "$T/work" add .gitattributes secret && git -C "$T/work" commit -qm secret && git -C "$T/work" push -q 2>/dev/null
  rm "$T/work/secret" && git -C "$T/work" checkout -q -- secret
  grep -q SMUDGED-PLAINTEXT "$T/work/secret"
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
    ln -s "$T/bin/api-sync" "$T/remote/seedmatic/$r.git/hooks/post-receive"
    git config --global url."file://$T/remote/seedmatic/$r.git".insteadOf "https://github.com/seedmatic/$r.git"
    # The lock the API serves for this head is the one its branch holds.
    if [ -f "$T/gh/seedmatic/$r/develop/flake.lock" ]; then
      git clone -q "$T/remote/seedmatic/$r.git" "$T/src-$r" 2>/dev/null
      cp "$T/gh/seedmatic/$r/develop/flake.lock" "$T/src-$r/flake.lock"
      git -C "$T/src-$r" commit -qam "$r's lock" && git -C "$T/src-$r" push -q 2>/dev/null
      rm -rf "$T/src-$r"
    fi
  done
}
# The orphan project of t, pushed, with a worktree.
mk_orphan() {
  git -C "$T/work" checkout -q --orphan t-orphan/develop
  git -C "$T/work" commit -qm orphan
  git -C "$T/work" push -qu origin t-orphan/develop 2>/dev/null
}
# t's checkout gains two edges: flake-commons and peer, both heads of the fake fabric/heads.
with_edges() {
  jq '.nodes.root.inputs += { "flake-commons": "fc", peer: "peer" }
      | .nodes.fc = { original: { type: "indirect", id: "flake-commons" },
                      locked: { type: "github", owner: "seedmatic", repo: "nix-flake-commons", rev: "fc1" } }
      | .nodes.peer = { original: { type: "indirect", id: "peer" },
                        locked: { type: "github", owner: "seedmatic", repo: "peer", rev: "peer1" } }' \
    "$T/work/flake.lock" > "$T/x" && mv "$T/x" "$T/work/flake.lock"
  git -C "$T/work" commit -qam "t pins two heads" && git -C "$T/work" push -q 2>/dev/null
}
# A head's `after`, in the fake fabric/heads.
after_of() { # $1 head, then its apps
  local h=$1 f="$T/gh/seedmatic/nix-flake-commons/fabric/heads/heads.json"; shift
  jq --arg h "$h" --argjson a "$(printf '%s\n' "$@" | jq -R . | jq -sc .)" '.heads[$h].after = $a' "$f" > "$f.next" && mv "$f.next" "$f"
}
# `! cmd` asserts nothing in bats: bash exempts a negated command from errexit, so it never fails a test
# unless it is the last line. refute does — and only on a NO: the command must answer 1 (grep's "no
# match", git rev-parse's "no such ref"). 0 is a refutation that held; any other code (grep's 2 on a
# file that is not there) is no answer at all, and a property must not pass on one.
refute() {
  local rc=0
  "$@" || rc=$?
  case $rc in
    1) return 0 ;;
    0) echo "refuted, but it held: $*" >&2; return 1 ;;
    *) echo "refute got no answer (rc=$rc): $*" >&2; return 1 ;;
  esac
}
never_updated() { ! grep -q "flake update" "$T/calls" 2>/dev/null; }
relock_commits() { git -C "$T/work" log --format=%s | grep -c '^chore(' || true; }
tree_clean()     { [ -z "$(git -C "$T/work" status --porcelain --untracked-files=no)" ]; }
lock_unchanged() { git -C "$T/work" diff --quiet HEAD -- flake.lock; }
remote_rev() { git -C "$T/remote/seedmatic/t.git" rev-parse --verify -q "refs/heads/$1" || echo none; }
trace_of() { git -C "$T/remote/seedmatic/${2:-t}.git" show "fabric/relock:$1.json" 2>/dev/null; }
signed() { git -C "$T/remote/seedmatic/t.git" cat-file commit "$1" | grep -q '^gpgsig -----BEGIN SSH SIGNATURE'; }

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
  [[ "$output" == *"BUMPED — derivations moved"* ]]
  [[ "$output" != *"no derivation moved"* ]]
  [ "$(relock_commits)" -eq 1 ]
  [ "$(jq -c '.status.pruned' <<<"$(trace_of t)")" = '{}' ]
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

@test "an input dropped upstream: the bump moves nothing, the node goes, the bump is CARRIED" {
  before=$(remote_rev develop)
  STUB_HAS_CONFIGS=true STUB_UPDATE=pruned run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUMPED — no derivation moved, but the lock lost 1 locked node(s): x"* ]]
  git -C "$T/work" log -1 --format=%b | grep -q "the lock lost 1 locked node(s): x"
  [ "$(jq -r '.status.pruned.a | join(",")' <<<"$(trace_of t)")" = x ]
  [ "$(relock_commits)" -eq 1 ]
  [ "$(git -C "$T/work" show HEAD:flake.lock | jq -c '.nodes.x')" = null ]
  [ "$(remote_rev develop)" != "$before" ]
  [ "$(jq -r '.status.bumped | keys | join(",")' <<<"$(trace_of t)")" = a ]
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

# ── what nix reads ─────────────────────────────────────────────────────────────────────────────────

@test "a requested run checks its clone out with no filter: the operator's smudge never writes there" {
  smudging_secret
  mkdir -p "$T/outside" && cd "$T/outside"
  STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloned at develop"* ]]
  [[ "$output" == *"BUMPED"* ]]
  grep -q 'relock:measure.*git+file://[^?]*/t?rev=[0-9a-f]*&shallow=1' "$T/calls"
  [ ! -s "$T/smudged" ]
}

@test "a smudged checkout is read by revision only: nix never sees its working tree" {
  smudging_secret
  STUB_UPDATE=rev run "$T/relock" --no-push inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUMPED"* ]]
  grep -q 'relock:measure.*git+file://[^?]*/work?rev=' "$T/calls"
  grep -q 'flake update a --flake git+file://[^?]*/work?rev=' "$T/calls"
  [ ! -s "$T/worktree-refs" ]
}

@test "a bump is measured on a commit no ref names, which carries it — and that is what gets committed" {
  STUB_DRV_FROM_LOCK=1 STUB_UPDATE=rev run "$T/relock" --no-push inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUMPED"* ]]
  m=$(grep 'relock:measure' "$T/calls" | tail -1 | sed -n 's/.*?rev=\([0-9a-f]\{40\}\).*/\1/p')
  [ "$(git -C "$T/work" show "$m:flake.lock" | jq -r .nodes.a.locked.rev)" = r2 ]
  [ -z "$(git -C "$T/work" for-each-ref --contains "$m")" ]
  [ "$(git -C "$T/work" rev-parse 'HEAD^{tree}')" = "$(git -C "$T/work" rev-parse "$m^{tree}")" ]
}

@test "a head's evaluation warnings stay out of a pass; a measure's real error does not" {
  STUB_EVAL_WARNING="getExe: Package tailscale does not have meta.mainProgram" STUB_UPDATE=rev run "$T/relock" --no-push inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUMPED"* ]]
  [[ "$output" != *"evaluation warning"* ]]
  git -C "$T/work" reset -q --hard '@{u}'
  STUB_EVAL_WARNING=noise STUB_MEASURE=fail-after-first STUB_UPDATE=revs run "$T/relock" --no-push inputs
  [[ "$output" == *"error: cannot evaluate packages"* ]]
  [[ "$output" != *"evaluation warning"* ]]
}

@test "sweep says which of its four measures runs, and its measuring commit runs no hook" {
  mkdir -p "$T/hooks" && printf '#!%s\nexit 1\n' "$(command -v bash)" > "$T/hooks/pre-commit" && chmod +x "$T/hooks/pre-commit"
  git config --global core.hooksPath "$T/hooks"
  run "$T/sweep" "$T/work"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(1/4)"* ]] && [[ "$output" == *"(4/4)"* ]]
  [[ "$output" == *"0 configurations"* ]]
}

@test "sweep clones with no filter and measures revisions: the operator's smudge never reaches nix" {
  smudging_secret
  run "$T/sweep" "$T/work"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 configurations"* ]]
  grep -q 'neutralise = true.*' "$T/calls"
  grep -q 'git+file://[^?]*/flake?rev=' "$T/calls"
  [ ! -s "$T/smudged" ]
}

# ── what a run says of itself ────────────────────────────────────────────────────────────────────────

@test "a system left out is said with nix's own cause, not the bare first line of its trace" {
  STUB_ERROR_STYLE=nix STUB_SYSTEMS="aarch64-darwin x86_64-darwin" STUB_BROKEN_SYSTEM=x86_64-darwin STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"so none of x86_64-darwin is measured — error: attribute 'x86_64-darwin' missing"* ]]
}

@test "a run says how long it took, and --format=jsonl puts its event on stdout and every word on stderr" {
  STUB_UPDATE=rev "$T/relock" --format=jsonl inputs >"$T/out" 2>"$T/err"
  grep -q 'BUMPED' "$T/err"
  refute grep -q 'BUMPED' "$T/out"
  grep -qE 'DONE — [0-9]+m[0-9]{2}s' "$T/err"
  [ "$(wc -l < "$T/out")" -eq 1 ]
  jq -e --arg r "$(remote_rev develop)" '.event == "head" and .head == "t" and .outcome == "done"
      and .pushed == $r and (.seconds | type == "number") and (.bumped | has("a"))' "$T/out"
  jq -e '.status.seconds | type == "number"' <<<"$(trace_of t)"
}

@test "every evaluation a run makes is timed, in its event and in one line for a human" {
  STUB_UPDATE=rev "$T/relock" --format=jsonl inputs >"$T/out" 2>"$T/err"
  jq -e '.evals | map(.what) == ["shape", "baseline", "measure a"]' "$T/out"
  jq -e '.evals | all(.seconds | type == "number" and . >= 0)' "$T/out"
  grep -qE '^evaluations: shape [0-9.]+s, .*baseline [0-9.]+s, measure a [0-9.]+s$' "$T/err"
}

@test "a measure is ONE evaluation when every system evaluates; split only to find a broken one" {
  STUB_UPDATE=rev run "$T/relock" --no-push inputs
  [ "$status" -eq 0 ]
  [ "$(grep -c 'relock:measure all' "$T/calls")" -eq 2 ]
  refute grep -qE 'relock:measure (packages|apps|configurations)' "$T/calls"
}

@test "a requested head pays no baseline: its edges' measure is its starting point" {
  with_edges
  STUB_UPDATE=edges "$T/relock" --format=jsonl edges after >"$T/out" 2>"$T/err"
  jq -e '.evals | map(.what) == ["shape", "measure edges"]' "$T/out"
}

@test "a requested head whose edges are current pays no full evaluation at all" {
  STUB_UPDATE=none "$T/relock" --format=jsonl edges after >"$T/out" 2>"$T/err"
  grep -q 'already current (flake-commons)' "$T/err"
  jq -e '.evals | map(.what) | index("baseline") == null and index("measure edges") == null' "$T/out"
}

@test "a pass times the build of every member's relock" {
  mk_orphan
  git -C "$T/work" checkout -q develop
  peers peer peer2
  STUB_UPDATE=none "$T/relock" --format=jsonl --downstream >"$T/out" 2>"$T/err"
  jq -se '[.[] | select(.event == "pass")][0].evals | map(.what) == ["build t-orphan'"'"'s relock", "build peer'"'"'s relock", "build peer2'"'"'s relock", "alignment check"]' "$T/out"
}

@test "a run that pushes nothing says so in its event: pushed is empty, not HEAD" {
  STUB_UPDATE=none "$T/relock" --format=jsonl inputs >"$T/out" 2>"$T/err"
  grep -q 'nothing to push' "$T/err"
  jq -e '.event == "head" and .outcome == "done" and .pushed == ""' "$T/out"
}

@test "a pass is ONE jsonl stream on stdout — its start, every head's run, its end — and every word on stderr" {
  mk_orphan
  git -C "$T/work" checkout -q develop
  peers peer peer2
  STUB_UPDATE=none "$T/relock" --downstream --format=jsonl >"$T/out" 2>"$T/err"
  grep -qE '\^ peer done \([0-9]+m[0-9]{2}s\)' "$T/err"
  while read -r line; do jq -e . <<<"$line" >/dev/null; done < "$T/out"
  [ "$(jq -sr '[.[] | select(.event == "pass-start")] | length' "$T/out")" -eq 1 ]
  [ "$(jq -sr '[.[] | select(.event == "pass")][0].outcome' "$T/out")" = done ]
  [ "$(jq -sr '[.[] | select(.event == "head") | .head] | sort | join(" ")' "$T/out")" = "peer peer2 t t-orphan" ]
}

@test "--plan --format=jsonl puts the plan on stdout as one event" {
  "$T/relock" --plan --format=jsonl >"$T/out" 2>"$T/err"
  [ "$(wc -l < "$T/out")" -eq 1 ]
  jq -e '.event == "plan" and .errors == [] and (.order | index("t") != null)' "$T/out"
}

@test "an unknown --format is refused before anything" {
  run "$T/relock" --format=xml inputs
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown format 'xml'"* ]]
  never_updated
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
  refute grep -q "SIMULATED-GH-TOKEN" "$T/curl-calls"
}

@test "the token is never printed" {
  STUB_UPDATE=rev run "$T/relock" --no-push
  [[ "$output" != *"SIMULATED-GH-TOKEN"* ]]
}

@test "no token from gh: said, and the run goes on without one" {
  STUB_GH=fail STUB_UPDATE=none run "$T/relock" --no-push inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"no GitHub token"* ]]
  refute grep -q "extra-access-tokens" "$T/nix-config"
  refute grep -q "Authorization" "$T/curl-stdin"
}

# ── after the inputs ───────────────────────────────────────────────────────────────────────────────

@test "an after-inputs app runs AFTER the inputs, and what it changes is committed" {
  after_of t after-x
  STUB_UPDATE=rev STUB_AFTER=ok run "$T/relock"
  [ "$status" -eq 0 ]
  [ "$(git -C "$T/work" log --format=%s -2 | tr '\n' '|')" = "chore(relock): after-x after inputs|chore(flake): relock a|" ]
  tree_clean
}

@test "an after-inputs app that changes nothing commits nothing" {
  after_of t after-x
  STUB_UPDATE=none STUB_AFTER=none run "$T/relock"
  [ "$status" -eq 0 ]
  [[ "$output" == *"after-x"*"already current"* ]]
  [ "$(relock_commits)" -eq 0 ]
}

@test "a failing after-inputs app restores the tree, commits nothing of its own, and says why" {
  after_of t after-x
  STUB_UPDATE=none STUB_AFTER=fail run "$T/relock"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED (after-inputs app after-x)"* ]]
  [[ "$output" == *"after boom"* ]]
  [ "$(relock_commits)" -eq 0 ]
  tree_clean
}

@test "an after-inputs app is run WITHOUT the token" {
  after_of t after-x
  STUB_UPDATE=none STUB_AFTER=ok run "$T/relock"
  [ -f "$T/child-env.after" ]
  refute grep -q "SIMULATED-GH-TOKEN" "$T/child-env.after"
}

@test "a member runs the \`after\` of its head in fabric/heads, read from the pass's plan" {
  mk_orphan
  git -C "$T/work" checkout -q develop
  peers peer peer2
  after_of peer after-x
  STUB_UPDATE=none STUB_AFTER=ok run "$T/relock" --downstream
  [ "$status" -eq 0 ]
  [[ "$output" == *"== peer =="*"== after the inputs =="*"after-x"*"== peer2 =="* ]]
  [ "$(grep -c '== after the inputs ==' <<<"$output")" -eq 1 ]
}

@test "an \`after\` that is not a list of app names is refused before anything" {
  jq '.heads.t.after = "after-x"' "$T/gh/seedmatic/nix-flake-commons/fabric/heads/heads.json" > x && mv x "$T/gh/seedmatic/nix-flake-commons/fabric/heads/heads.json"
  STUB_UPDATE=rev run "$T/relock" --no-push
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING: the \`after\` of 't' in fabric/heads is not a list of app names"* ]]
  never_updated
  after_of t 'after-x; true'
  STUB_UPDATE=rev run "$T/relock" --no-push
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a list of app names"* ]]
  never_updated
}

# ── the edges ─────────────────────────────────────────────────────────────────────────────────────

@test "the edges move in ONE bump, carried though no derivation moves; the other inputs stay guarded" {
  with_edges
  before=$(remote_rev develop)
  STUB_UPDATE=edges run "$T/relock"
  [ "$status" -eq 0 ]
  [[ "$output" == *"targets: edges inputs after"* ]]
  [[ "$output" == *"edges              BUMPED — edges carried, no impact guard: flake-commons, peer"* ]]
  [[ "$output" == *"a                  moved, NO derivation impact -> dropped"* ]]
  [ "$(git -C "$T/remote/seedmatic/t.git" log --format=%s "$before..develop")" = "chore(flake): relock edges (flake-commons, peer)" ]
  git -C "$T/remote/seedmatic/t.git" log -1 --format=%b develop | grep -qx 'flake-commons: fc1 -> fc2'
  git -C "$T/remote/seedmatic/t.git" log -1 --format=%b develop | grep -qx 'peer: peer1 -> peer2'
  [ "$(git -C "$T/remote/seedmatic/t.git" show develop:flake.lock | jq -r '[.nodes.fc.locked.rev, .nodes.peer.locked.rev, .nodes.a.locked.rev] | join(" ")')" = "fc2 peer2 r1" ]
  [ "$(jq -c '.status.bumped | keys' <<<"$(trace_of t)")" = '["flake-commons","peer"]' ]
  [ "$(jq -c '.status.dropped' <<<"$(trace_of t)")" = '["a","f"]' ]
}

@test "an edge bump after which the head no longer evaluates is not carried" {
  with_edges
  STUB_UPDATE=edges STUB_MEASURE=fail run "$T/relock" --no-push edges
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED — this head does not evaluate with its edges bumped; nothing carried"* ]]
  [ "$(relock_commits)" -eq 0 ]
  lock_unchanged
}

@test "with no baseline, a system broken BEFORE the run is left out, one broken BY the edges is fatal" {
  with_edges
  STUB_SYSTEMS="aarch64-darwin x86_64-darwin" STUB_BROKEN_SYSTEM=x86_64-darwin STUB_UPDATE=edges run "$T/relock" --no-push edges
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUMPED — edges carried"* ]]
  [[ "$output" == *"packages of x86_64-darwin: one of them does not evaluate before any bump"* ]]
  git -C "$T/work" reset -q --hard '@{u}'
  STUB_SYSTEMS="aarch64-darwin aarch64-linux" STUB_BREAKS_ON_BUMP=aarch64-linux STUB_UPDATE=edges run "$T/relock" --no-push edges
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED — this head does not evaluate with its edges bumped; nothing carried"* ]]
  [[ "$output" == *"broken-by-the-bump"* ]]
  [ "$(relock_commits)" -eq 0 ]
}

@test "a named edge that cannot move alone is retried with every edge, and carried" {
  with_edges
  STUB_UPDATE=edges run "$T/relock" --no-push peer
  [ "$status" -eq 0 ]
  [[ "$output" == *"== input peer =="*"deferred — it is coupled"*"== deferred inputs: retried once, after the others =="*"edges              BUMPED — edges carried, no impact guard: flake-commons, peer"* ]]
  [ "$(relock_commits)" -eq 1 ]
}

@test "a head without edges says so, and its inputs are guarded as before" {
  jq 'del(.nodes.root.inputs["flake-commons"]) | del(.nodes.fc)' "$T/work/flake.lock" > "$T/x" && mv "$T/x" "$T/work/flake.lock"
  git -C "$T/work" commit -qam "t pins no head" && git -C "$T/work" push -q 2>/dev/null
  STUB_UPDATE=none run "$T/relock" --no-push
  [ "$status" -eq 0 ]
  [[ "$output" == *"== edges =="*"  none"*"== inputs =="* ]]
}

@test "in a pass, a requested head moves only its edges and its after; the start moves everything" {
  mk_orphan
  git -C "$T/work" checkout -q develop
  peers peer peer2
  STUB_UPDATE=rev run "$T/relock" --downstream
  [ "$status" -eq 0 ]
  [ "$(grep -c '^targets: edges after$' <<<"$output")" -eq 3 ]
  [ "$(grep -c '^targets: edges inputs after$' <<<"$output")" -eq 1 ]
  [ "$(git -C "$T/remote/seedmatic/t.git" show develop:flake.lock | jq -r .nodes.a.locked.rev)" = r2 ]
  [ "$(git -C "$T/remote/seedmatic/peer.git" log -1 --format=%s develop)" = "chore(flake): relock edges (t)" ]
  [ "$(git -C "$T/remote/seedmatic/peer2.git" log -1 --format=%s develop)" = "chore(flake): relock edges (peer)" ]
  [[ "$output" == *"== alignment =="*"aligned: every pin of the 4 head(s) is at its head's tip"* ]]
}

# ── alignment ─────────────────────────────────────────────────────────────────────────────────────

@test "--plan says whether the fabric is aligned now: every pin at its head's tip, or the gap named" {
  peers peer
  run "$T/relock" --plan
  [ "$status" -eq 0 ]
  t_tip=$(remote_rev develop)
  jq -e --arg g "peer: node \`t\` pins t at t1, t is at ${t_tip:0:9}" '.gaps | index($g) != null' <<<"$output"
  jq -e '.gaps | index("peer2: node `peer` pins peer at peer1, peer is at " + ("'"$(git -C "$T/remote/seedmatic/peer.git" rev-parse develop | cut -c1-9)"'")) != null' <<<"$output"
  jq -e '[.gaps[] | select(test("flake-commons"))] | length == 0' <<<"$output"
  never_updated
}

@test "a pass names a TRANSITIVE pin it cannot move, and fails on it" {
  # peer's lock holds, below its root, a copy of t at an old revision — as rke2lab holds the
  # flake-commons ndh pins.
  jq '.nodes.t_2 = { original: { type: "indirect", id: "t" }, locked: { type: "github", owner: "seedmatic", repo: "t", rev: "t0" } }' \
    "$T/gh/seedmatic/peer/develop/flake.lock" > "$T/x" && mv "$T/x" "$T/gh/seedmatic/peer/develop/flake.lock"
  mk_orphan
  git -C "$T/work" checkout -q develop
  peers peer peer2
  STUB_UPDATE=none run "$T/relock" --downstream
  [ "$status" -eq 1 ]
  [[ "$output" == *"edges              BUMPED — edges carried, no impact guard: t"* ]]
  [[ "$output" == *"NOT ALIGNED — peer: node \`t_2\` pins t at t0, t is at "* ]]
  [ "$(grep -c 'NOT ALIGNED' <<<"$output")" -eq 1 ]
  [[ "$output" == *"not aligned: peer: node \`t_2\`"* ]]
}

@test "an edge that resolves past what its head landed in this pass is refused, before any push" {
  mk_orphan
  git -C "$T/work" checkout -q develop
  peers peer peer2
  STUB_UPDATE=rev STUB_RACE=t run "$T/relock" --downstream
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED — edge t resolved "*", but t landed "*" in this pass: it moved during the pass"* ]]
  [[ "$output" == *"peer2: NOT RUN — it pins peer"* ]]
  [ "$(git -C "$T/remote/seedmatic/peer.git" log -1 --format=%s develop)" = "peer's lock" ]
  [[ "$output" == *"NOT ALIGNED — peer: node \`t\` pins t at t1"* ]]
}

@test "a pass runs each level of its plan at once, and shows each head whole, in the plan's order" {
  mk_orphan
  git -C "$T/work" checkout -q develop
  peers peer peer2
  run "$T/relock" --plan
  [ "$(jq -c .levels <<<"$output")" = '[["t","t-orphan"],["peer"],["peer2"]]' ]
  STUB_UPDATE=none STUB_SLOW=2 run "$T/relock" --downstream
  [ "$status" -eq 0 ]
  [[ "$output" == *"== level: t t-orphan — at once, at most 4 at a time =="*"  ended: t"*"  ended: t-orphan"*"== t =="*"== t-orphan =="*"== peer =="*"== peer2 =="* ]]
  # t and t-orphan overlapped: each started before the other ended.
  started_t=$(grep -m1 "^start t " "$T/slow" | cut -d' ' -f3); ended_o=$(grep -m1 "^end t-orphan " "$T/slow" | cut -d' ' -f3)
  started_o=$(grep -m1 "^start t-orphan " "$T/slow" | cut -d' ' -f3); ended_t=$(grep -m1 "^end t " "$T/slow" | cut -d' ' -f3)
  [ "$started_o" -lt "$ended_t" ] && [ "$started_t" -lt "$ended_o" ]
}

@test "--jobs=1 runs a level one head at a time; a count that is not one is refused" {
  mk_orphan
  git -C "$T/work" checkout -q develop
  peers peer peer2
  STUB_UPDATE=none STUB_SLOW=1 run "$T/relock" --downstream --jobs=1
  [ "$status" -eq 0 ]
  ended_t=$(grep -m1 "^end t " "$T/slow" | cut -d' ' -f3); started_o=$(grep -m1 "^start t-orphan " "$T/slow" | cut -d' ' -f3)
  [ "$started_o" -ge "$ended_t" ]
  run "$T/relock" --downstream --jobs=0
  [ "$status" -eq 2 ]
  [[ "$output" == *"--jobs wants a count of heads, not '0'"* ]]
}

@test "--plan --script plays the plan's edges with no relock, and the fabric ends aligned" {
  mk_orphan
  git -C "$T/work" checkout -q develop
  peers peer peer2
  run "$T/relock" --plan --script
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$T/fallback.sh"
  bash -n "$T/fallback.sh"
  grep -qx "edges 'peer' 'seedmatic/peer' 'develop' 'flake-commons' 't'" "$T/fallback.sh"
  grep -qx "edges 'peer2' 'seedmatic/peer2' 'develop' 'flake-commons' 'peer'" "$T/fallback.sh"
  [ "$(grep -n "^edges 'peer' " "$T/fallback.sh" | cut -d: -f1)" -lt "$(grep -n "^edges 'peer2' " "$T/fallback.sh" | cut -d: -f1)" ]
  never_updated
  run bash "$T/fallback.sh"
  [ "$status" -eq 0 ]
  [ "$(git -C "$T/remote/seedmatic/peer.git" log -1 --format=%s develop)" = "chore(flake): relock edges (flake-commons, t)" ]
  git -C "$T/remote/seedmatic/peer2.git" cat-file commit develop | grep -q '^gpgsig -----BEGIN SSH SIGNATURE'
  run "$T/relock" --plan
  [ "$(jq -c '[.gaps[] | select(test("^peer"))]' <<<"$output")" = '[]' ]
}

@test "--script goes with --plan only, and a plan that fails prints no script" {
  run "$T/relock" --script
  [ "$status" -eq 2 ]
  lock_of t develop peer
  run "$T/relock" --plan --script
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO SCRIPT — the plan fails"* ]]
  [[ "$output" != *"#!/usr/bin/env bash"* ]]
}

@test "a head pushed by someone else after it ended is not taken as landed; what pins it is not run" {
  mk_orphan
  git -C "$T/work" checkout -q develop
  peers peer peer2
  STUB_UPDATE=rev STUB_RACE_AFTER=t run "$T/relock" --downstream
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED — t landed "*", but its branch is at "*": someone pushed after it"* ]]
  [[ "$output" == *"== peer: NOT RUN — it pins t, which did not land in this pass =="* ]]
  [[ "$output" == *"head t (landed unconfirmed)"* ]]
}

@test "a fabric/heads id, repository or branch that is not a plain name is refused before anything" {
  jq '.heads["evil\necho pwned"] = { repo: "seedmatic/t", branch: "develop", kind: "code" }' \
    "$T/gh/seedmatic/nix-flake-commons/fabric/heads/heads.json" > "$T/x" && mv "$T/x" "$T/gh/seedmatic/nix-flake-commons/fabric/heads/heads.json"
  run "$T/relock" --plan --script
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING: fabric/heads holds a head whose id, repository, branch or kind is not a plain name"* ]]
  [[ "$output" != *"#!/usr/bin/env bash"* ]]
  jq 'del(.heads["evil\necho pwned"]) | .heads.peer.branch = "develop; rm -rf ~"' \
    "$T/gh/seedmatic/nix-flake-commons/fabric/heads/heads.json" > "$T/x" && mv "$T/x" "$T/gh/seedmatic/nix-flake-commons/fabric/heads/heads.json"
  run "$T/relock" --plan
  [ "$status" -eq 1 ]
  [[ "$output" == *"\"peer\""* ]]
  never_updated
}

@test "a tip that cannot be read fails the alignment, never passes it" {
  mk_orphan
  git -C "$T/work" checkout -q develop
  peers peer peer2
  STUB_UPDATE=none STUB_TIPS=fail run "$T/relock" --downstream
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED — the tip of t cannot be read, so what it landed cannot be confirmed"* ]]
  [[ "$output" == *"== peer: NOT RUN — it pins t"* ]]
  [[ "$output" == *"NOT ALIGNED — "*"whose tip is unknown"* ]]
  [[ "$output" != *"aligned: every pin"* ]]
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

@test "every commit relock pushes is signed: the bump and the trace" {
  before=$(remote_rev develop)
  STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 0 ]
  pushed=$(git -C "$T/remote/seedmatic/t.git" rev-list "$before..develop")
  [ -n "$pushed" ]
  for c in $pushed "$(remote_rev fabric/relock)"; do signed "$c"; done
}

@test "an after-inputs commit is signed too" {
  before=$(remote_rev develop)
  after_of t after-x
  STUB_UPDATE=rev STUB_AFTER=ok run "$T/relock"
  [ "$status" -eq 0 ]
  [ "$(git -C "$T/remote/seedmatic/t.git" rev-list --count "$before..develop")" -eq 2 ]
  for c in $(git -C "$T/remote/seedmatic/t.git" rev-list "$before..develop"); do signed "$c"; done
}

@test "a signature that cannot be made commits and pushes NOTHING — no unsigned fallback" {
  git config --global user.signingkey "$T/no-such-key.pub"
  before=$(remote_rev develop)
  STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED to commit the bump — lock restored"* ]]
  [ "$(remote_rev develop)" = "$before" ]
  [ "$(remote_rev fabric/relock)" = none ]
  lock_unchanged
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

@test "a data head is a leaf: its lock never read, never run, what pins it ordered after it, its tip judged" {
  lock_of peer develop t d
  run "$T/relock" --plan
  [ "$status" -eq 0 ]
  [ "$(jq -c .order <<<"$output")" = '["t","t-orphan","peer","peer2"]' ]
  jq -e '.edges | index({from: "peer", to: "d", input: "d"}) != null' <<<"$output"
  refute grep -q "contents/.*ref=fabric%2Fd" "$T/curl-calls"
  grep -q "commits/fabric%2Fd" "$T/curl-calls"
  jq -e '.gaps | index("peer: node `d` pins d, whose tip is unknown") != null' <<<"$output"
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
  grep -q -- 'eval --raw --refresh github:seedmatic/nix-flake-commons/fc1#lib\.relockOf --apply .*"peer"' "$T/calls"
  # Never through a member's own flake: its lock may hold pins the new tool no longer satisfies.
  refute grep -q -- 'github:seedmatic/peer/develop#' "$T/calls"
  refute grep -q -- 'github:seedmatic/peer2/develop#' "$T/calls"
  refute grep -q -- '--commit-lock-file' "$T/calls"
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
  [[ "$output" == *"FAILED: 4 target(s)"*"head peer"*"head peer2 (pins peer)"*"not aligned: peer: node \`t\` pins t at t1"*"not aligned: peer2: node \`peer\` pins peer at peer1"* ]]
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
  refute grep -q "SIMULATED-GH-TOKEN" "$T/child-env.peer"
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
  # Measured at the run's first HEAD only: once told broken, never measured again.
  head0=$(git -C "$T/work" rev-parse HEAD~1)
  [ "$(grep -E 'relock:measure (all|packages x86_64-darwin)' "$T/calls" | grep 'x86_64-darwin' | grep -vc "rev=$head0")" -eq 0 ]
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
  reject_trace_pushes 5
  STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 75 ]
  [[ "$output" == *"FAILED to write the trace on fabric/relock — the change itself is pushed, and has landed"* ]]
  [[ "$output" == *"trace t (its change landed)"* ]]
  [ "$(git -C "$T/remote/seedmatic/t.git" show develop:flake.lock | jq -r .nodes.a.locked.rev)" = r2 ]
}

@test "a rejected trace push is retried on a fresh fetch, up to four times" {
  reject_trace_pushes 4
  STUB_UPDATE=rev run "$T/relock" inputs
  [ "$status" -eq 0 ]
  [[ "$output" == *"the trace's push was rejected — fetching fabric/relock again (1 of 4 retries)"* ]]
  [[ "$output" == *"(4 of 4 retries)"* ]]
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
  refute git -C "$T/remote/seedmatic/t.git.gone" rev-parse -q --verify refs/heads/fabric/relock
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
  grep -q -- 'eval --raw --refresh github:seedmatic/nix-flake-commons/fc1#lib\.relockOf' "$T/calls"
}

# ── review of 1a: a REAL propagation ───────────────────────────────────────────────────────────────

@test "a pass PROPAGATES: t pushes its bump, peer pins t's pushed head, both traced" {
  peers peer peer2
  # peer's own lock pins t at the current head.
  git clone -q "$T/remote/seedmatic/peer.git" "$T/peer-src"
  jq --arg r "$(remote_rev develop)" '.nodes.root.inputs.t = "t" | .nodes.t = {"original":{"type":"indirect","id":"t"},"locked":{"type":"github","owner":"seedmatic","repo":"t","rev":$r}}' \
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
