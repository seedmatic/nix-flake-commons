# shellcheck shell=bash
# relock — ONE implementation, shared by every repo in the chain. See rke2lab's
# docs/architecture/patterns/flake-lock-propagation.adoc; built by nix-flake-commons' `lib.mkRelockApp`.
#
# Build-time tokens (written WITHOUT at-sigils here so replaceVars does not substitute them in this
# comment): repoName, repoSlug, repoUrl, ownBranch, system, consumers, ownedArtifacts,
# pushFirstBranch, catalogBranch, selfPinName, aliases.
#
# ★ WHY the name is identical in every repo: propagation is a REQUEST, and the caller must know
# nothing about the callee beyond its name — that uniformity is what makes `nix run <any repo>#relock`
# possible. The same reasoning applies one level down, to the implementation: if each repo wrote its
# own, "the same rule everywhere" would be a claim nobody could check. So the rule lives once and each
# repo supplies only what is ITS OWN — its url, its artifacts, its branches, its consumers.

downstream=0
nopush=0
targets=()

# A repo's own words for some of its regen apps (`plans` → `regen-dataplan`), declared where that
# repo builds its relock — never here. The root that every seedmatic flake consumes must not name
# one consumer's artifacts; it used to, as two hard-coded cases.
declare -A alias_of=()
aliases=(@aliases@)
for kv in "${aliases[@]}"; do alias_of[${kv%%=*}]=${kv#*=}; done

for a in "$@"; do
  case $a in
    --downstream) downstream=1 ;;
    --no-push) nopush=1 ;;
    -h|--help)
      cat <<'USAGE'
relock [--downstream | --no-push] [target...]

Reconcile this repo's derived, committed artifacts. No target = ALL of them.

  inputs            every flake input          -> flake.lock
  <input-name>      one input, by its name in flake.lock
  artifacts         every regen-* app this repo exposes (discovered)
  regen-<name>      one regen app by name
  envs              every flox env on the catalog branch, if this repo has one
  envs:<id>         one such env
  catalog           the catalog branch's pin of this repo, if it has one

An input bump that moves no exported derivation is DROPPED, not carried.
--downstream then REQUESTS each declared consumer's own relock.
--no-push commits in THIS checkout and stops before anything leaves it, so the commits can be
reviewed; it prints the exact command that resumes where it stopped.

GitHub token: read from `gh auth token` at each run and handed ONLY to relock's own nix calls,
as extra-access-tokens appended to NIX_CONFIG. Never written anywhere, never exported, and never
passed to the programs those calls build (regen apps, lock-envs, a consumer's relock).
USAGE
      if [ "${#aliases[@]}" -gt 0 ]; then
        printf '\nAliases this repo declares:\n'
        for kv in "${aliases[@]}"; do printf '  %-17s %s\n' "${kv%%=*}" "${kv#*=}"; done
      fi
      exit 0 ;;
    -*) echo "relock: unknown flag '$a' (try --help)" >&2; exit 2 ;;
    *) targets+=("$a") ;;
  esac
done
# A consumer only ever sees what is pushed, so requesting one after a run that pushed nothing would
# relock it against the revision this run did NOT carry — and report success.
if [ "$nopush" = 1 ] && [ "$downstream" = 1 ]; then
  echo "relock: --no-push and --downstream contradict each other — a consumer sees only what is pushed" >&2
  exit 2
fi

# The GitHub token, for the PRIVATE inputs (measured 2026-10-07: without one, nix fetched ndh's
# private claude-hub input as a 404 and fell back to a stale cache). Taken from `gh auth token` at
# each run rather than stored: the copy that used to live in nix.conf expired and nobody noticed.
#
# ⚠️ Scoped to relock's OWN nix calls, and that is the whole design. The variable is NOT exported,
# and `nix` below is a function that appends the token to NIX_CONFIG for that one process only —
# APPENDED, as extra-access-tokens, because NIX_CONFIG may already carry settings (the flox hook
# puts the flake registry there) and `access-tokens` would replace nix.conf's. A token in a
# process-wide variable is how GH_TOKEN once leaked into an editor; and `nix run` would hand its
# environment to the program it starts, which is why apps are built here and run without it.
gh_token=""
if command -v gh >/dev/null 2>&1 && gh_token=$(gh auth token 2>/dev/null) && [ -n "$gh_token" ]; then
  :
else
  gh_token=""
  echo "relock: no GitHub token ('gh auth token' gave none) — private inputs will fail to fetch" >&2
fi
nix() {
  if [ -n "$gh_token" ]; then
    NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}extra-access-tokens = github.com=$gh_token" command nix "$@"
  else
    command nix "$@"
  fi
}

# An app's program, BUILT with the token, so that running it afterwards needs no fetch and gets no
# token. `nix build` refuses the program string itself, so its context's derivations are built.
app_program() { # $1 app installable (flake#apps.<system>.<name>) -> program path on stdout
  local prog d
  local -a drvs=()
  prog=$(nix eval --raw "$1.program") || return 1
  mapfile -t drvs < <(nix eval --json "$1.program" --apply 'p: builtins.attrNames (builtins.getContext p)' | jq -r '.[]') || return 1
  for d in "${drvs[@]}"; do nix build --no-link "$d^*" || return 1; done
  printf '%s\n' "$prog"
}

# WHOSE repo this reconciles — its OWN, always, and resolved rather than assumed.
#
# ⚠️ The contract is `nix run <repo>#relock` from ANY directory. When rke2lab's relock requests ours,
# the CWD is RKE2LAB's worktree, so a bare `git rev-parse --show-toplevel` would hand us the wrong
# repo and relock it with our rules — silently, and reporting success. So the CWD counts only if it is
# a checkout of THIS repo; otherwise we obtain one of our own.
#
# Matching is on the SLUG (`owner/name`), not the url: a local checkout may speak ssh where the input
# speaks https, and the same repo must not read as a different one because of the transport.
#
# ⚠️ And the slug is not enough when one repo carries SEVERAL flakes, one per branch — rke2lab's
# develop and its orphans seed-incluster and flox-catalog. Matched on the slug alone, the orphan's
# relock run from a develop checkout reconciled develop by the orphan's rules, and a requested run
# cloned the default branch instead of the orphan: both silently, both reporting success. So a flake
# that names its `branch` counts a checkout as its own only on that branch and clones that branch;
# and a flake that names none refuses to run on the branches it has itself declared as OTHER flakes
# of the repo (`pushFirstBranch`, `catalogBranch`).
ownBranch="@ownBranch@"
pushFirstBranch="@pushFirstBranch@"
catalogBranch="@catalogBranch@"
cur=""
REPO=""
if top=$(git rev-parse --show-toplevel 2>/dev/null); then
  origin=$(git -C "$top" remote get-url origin 2>/dev/null || true)
  origin=${origin%.git}
  case "$origin" in
    *"@repoSlug@") REPO=$top ;;
  esac
fi
if [ -n "$REPO" ]; then
  cur=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
  if [ -n "$ownBranch" ] && [ "$cur" != "$ownBranch" ]; then
    echo "REFUSING: this checkout of @repoSlug@ is on '$cur', but @repoName@ is the flake on '$ownBranch'." >&2
    echo "Run it from a worktree of '$ownBranch', or from outside any checkout of @repoSlug@ to have" >&2
    echo "'$ownBranch' cloned." >&2
    exit 1
  fi
  if [ -z "$ownBranch" ] && { [ "$cur" = "$pushFirstBranch" ] || [ "$cur" = "$catalogBranch" ]; }; then
    echo "REFUSING: this checkout of @repoSlug@ is on '$cur', which @repoName@ declares as ANOTHER" >&2
    echo "flake of this repo. Run that branch's own relock from here, or this one from another checkout." >&2
    exit 1
  fi
  echo "relock(@repoName@): reconciling the checkout at $REPO ($cur)"
else
  # A REQUESTED run, from somewhere that is not our checkout. We clone, reconcile and PUSH: the chain
  # is push-gated anyway (a `github:` input only ever sees what is pushed), so the remote is the only
  # place a request can usefully land. The operator's own checkout stays untouched and simply pulls.
  # Unpushed commits in a throwaway clone would vanish with it: --no-push needs the operator's checkout.
  if [ "$nopush" = 1 ]; then
    on=""
    if [ -n "$ownBranch" ]; then on=" on $ownBranch"; fi
    echo "relock: --no-push needs a checkout of @repoSlug@$on — run it from there;" >&2
    echo "        in a clone, the unpushed commits would be lost with it" >&2
    exit 2
  fi
  REPO=$(mktemp -d)/@repoName@
  clone_branch=()
  if [ -n "$ownBranch" ]; then clone_branch=(--branch "$ownBranch"); fi
  echo "relock(@repoName@): not inside this repo — cloning @repoUrl@ ${ownBranch:+($ownBranch) }to reconcile and push"
  git clone --quiet "${clone_branch[@]}" "@repoUrl@" "$REPO" || { echo "relock: cannot clone @repoUrl@ $ownBranch" >&2; exit 1; }
  cur=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
  echo "relock(@repoName@): cloned at $cur"
fi

# The registry that resolves a repo's INDIRECT inputs, pinned by a CLI flag rather than left to
# NIX_CONFIG. Measured 2026-10-06: `--flake-registry` beats a NIX_CONFIG aimed elsewhere, and
# leaving NIX_CONFIG alone matters because that is where access-tokens for the private inputs
# live. What it points AT is the repo's EFFECTIVE registry — the operator's gitignored
# flake-registry.local.json when one exists, the committed flake-registry.json otherwise.
#
# ★ That precedence is the whole point of the indirection, and an earlier version of this
# function defeated it: it pinned the committed file unconditionally, so re-locking through a
# local re-aim was impossible — which is the one thing the registry exists to make possible.
# Re-aiming an input at the branch you are working on, and having a relock FOLLOW you there, is
# the use case; naming that branch in flake.nix is what we removed.
#
# What made the over-caution look reasonable was imagining the local file as somebody ELSE's.
# It cannot be: relock reconciles either the operator's own checkout or a FRESH CLONE, and a
# fresh clone has no gitignored file at all, so it falls back to the committed one by
# construction. The only flake-registry.local.json relock can ever read is the one belonging to
# whoever ran it.
#
# Safety is the GUARD's job, not this pin's, and the guard already draws the right line —
# between a re-aim at another BRANCH, whose locked rev is pushed and therefore fetchable by
# everyone, and a re-aim at a local CHECKOUT, whose rev exists on one machine. It refuses the
# second and lets the first through. Pinning the committed file as well bought nothing and cost
# the feature.
#
# A repo that carries neither file gets no flag: nothing to point at, and the guard covers it
# regardless. Uniform across the chain whether a given repo has migrated its inputs or not.
registry_flag=()
set_registry_flag() { # $1 checkout dir
  registry_flag=()
  if [ -f "$1/flake-registry.local.json" ]; then
    registry_flag=(--flake-registry "$1/flake-registry.local.json")
  elif [ -f "$1/flake-registry.json" ]; then
    registry_flag=(--flake-registry "$1/flake-registry.json")
  fi
}
set_registry_flag "$REPO"

# The per-input comparison attributes a derivation change to the input just bumped, so
# any OTHER uncommitted edit would be credited to it. Refuse rather than mislead.
#
# TRACKED changes only. Measured 2026-10-07: nix's git fetcher EXCLUDES untracked files from a
# flake's source — the untracked `.claude/` scratch paths in this checkout are absent from the
# store path `nix flake metadata` reports, while tracked `flake.nix` is present. So an untracked
# file cannot move any derivation, and refusing on one refuses on a condition this guard cannot
# be protecting against. It did exactly that: scratch notes left by another session blocked a
# reconciliation outright, and the only ways out were to commit files that were not ours or to
# delete them.
dirty=$(git -C "$REPO" status --porcelain --untracked-files=no -- . ':!flake.lock' @ownedArtifacts@)
if [ -n "$dirty" ]; then
  echo "REFUSING: the worktree carries changes beyond the artifacts relock owns, so a" >&2
  echo "derivation change could not be attributed. Commit or set them aside:" >&2
  printf '%s\n' "$dirty" >&2
  exit 1
fi

wt_for_branch() {
  local want=$1 path="" br=""
  while IFS= read -r line; do
    case $line in
      "worktree "*) path=${line#worktree } ;;
      "branch refs/heads/"*)
        br=${line#branch refs/heads/}
        [ "$br" = "$want" ] && { printf '%s\n' "$path"; return 0; } ;;
    esac
  done < <(git -C "$REPO" worktree list --porcelain)
  return 1
}

lockrev() { # $1 flake.lock  $2 root-input name -> resolved node rev
  # shellcheck disable=SC2016  # $i/$n/$nn are jq vars, not shell
  jq -r --arg i "$2" '
    .nodes.root.inputs[$i] as $n
    | (if ($n|type)=="array" then $n[-1] else $n end) as $nn
    | .nodes[$nn].locked.rev // empty' "$1"
}

# The MEANINGFUL projection of a flake edge: every exported package's derivation path.
# NOT a projection of the lock's fields — in a flake.lock `locked.rev` IS the content
# identity, so deleting it would make every bump compare equal and look impact-free.
#
# A flake with no `packages` is an AGGREGATOR: what it exports is its inputs, which its consumers
# follow — so its impact is the revision each root input is locked at. Without this, relock died on
# nix-flake-commons (the eval of a missing attribute aborts under `set -e`), and caught, it would
# have dropped every bump as impact-free.
#
# ⚠️ Presence is tested WITHOUT evaluating `packages`, and an error must stay fatal. A first version
# probed `.#packages` under `2>/dev/null` inside an `if`: a repo whose packages FAIL to evaluate then
# read as an aggregator, every bump showed "impact", and all of them were carried — with no error
# anywhere. Absent and broken must not look alike. Hence the capture into a variable: under `set -e`
# a failing command substitution aborts, while the same failure inside an `if` condition is
# swallowed and simply reads as false (measured).
#
# ⚠️ And `set -e` alone does NOT carry it: evalmap only ever runs inside `$(…)`, and the
# writeShellApplication wrapper sets errexit/nounset/pipefail but NOT `inherit_errexit`, so inside
# the substitution a failing capture just continues (measured). Every failure is therefore returned
# EXPLICITLY, and each caller decides what it means.
evalmap() {
  local has_packages
  has_packages=$(nix eval --impure --json --expr "(builtins.getFlake \"git+file://$REPO\").outputs ? packages") || return 1
  if [ "$has_packages" = true ]; then
    nix eval --json "$REPO#packages.@system@" \
      --apply 'ps: builtins.mapAttrs (_: p: if p ? drvPath then p.drvPath else null) ps' \
      | jq -S .
  else
    # A `follows` root input has no lock of its own — it is an input PATH whose target is already
    # counted where it is defined — so it is left out rather than resolved. Taking its last path
    # segment as a node key would have measured the wrong node, or null.
    # shellcheck disable=SC2016  # $l is a jq var, not shell
    jq -S '. as $l | .nodes.root.inputs
      | with_entries(select(.value | type == "string"))
      | map_values($l.nodes[.].locked.rev // $l.nodes[.].locked.narHash)' "$REPO/flake.lock"
  fi
}

all_inputs() { jq -r '.nodes.root.inputs | keys[]' "$REPO/flake.lock"; }

# Every `regen-*` app this flake exposes — DISCOVERED, not listed. A repo's generated
# artifacts are whatever its regen apps write, and it already declares those as apps; making
# a caller re-list them (app AND filename) is the same "enumerate what you could derive" the
# cluster set was cured of. It also means a new regen app is covered the day it lands.
regen_apps() {
  nix eval --json "$REPO#apps.@system@" --apply 'as: builtins.attrNames as' 2>/dev/null \
    | jq -r '.[] | select(startswith("regen-"))'
}

# Re-derive and commit only what MOVED. No eval needed and no filename needed: the regen
# writes whatever it writes, and git reports it.
#
# ⚠️ Like relock_input, this runs as `regen_artifact … || true`, so bash switches errexit off for its
# whole body: every failure is returned EXPLICITLY. A failed regen restores whatever it had already
# rewritten — it must leave nothing dirty, and certainly nothing committed — and says WHY, since its
# own stderr is the only account of the failure.
regen_artifact() { # $1 app
  printf '  %-18s ' "$1"
  local err
  err=$(mktemp)
  local -a moved=()
  local prog
  if ! prog=$(cd "$REPO" && app_program ".#apps.@system@.$1" 2>"$err") || ! ( cd "$REPO" && "$prog" ) >/dev/null 2>>"$err"; then
    mapfile -t moved < <(git -C "$REPO" diff --name-only)
    if [ "${#moved[@]}" -gt 0 ]; then git -C "$REPO" checkout -q -- "${moved[@]}"; fi
    echo "FAILED (regen app $1) — restored ${moved[*]:-nothing}"
    sed 's/^/    /' "$err" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  mapfile -t moved < <(git -C "$REPO" diff --name-only)
  if [ "${#moved[@]}" -eq 0 ]; then
    echo "already current"
  elif git -C "$REPO" commit -q -m "chore(relock): regen via $1" -- "${moved[@]}"; then
    committed=1
    echo "REGENERATED — ${moved[*]} was stale"
  else
    git -C "$REPO" checkout -q -- "${moved[@]}"
    echo "FAILED to commit the regenerated ${moved[*]} — restored"
    return 1
  fi
}

# `nix flake update` in $1 for the inputs that follow; its stderr lands in `update_err`.
# Returns 1 when nix fails, and 2 when it SUCCEEDS on a stale copy.
#
# ⚠️ The second case is the dangerous one. Measured 2026-10-07 on ndh's private `claude-hub` input:
# the GitHub API answered 404 Not Found, nix printed "using cached version" and exited 0, the lock
# came out unchanged, and relock reported "already current" — on an input three commits behind its
# branch. A fetch that did not happen must never read as one that found nothing new.
update_err=""
nix_update() {
  local dir=$1 err rc=0
  shift
  err=$(mktemp)
  ( cd "$dir" && nix "${registry_flag[@]}" flake update "$@" --refresh ) >/dev/null 2>"$err" || rc=1
  if [ "$rc" = 0 ] && grep -qE 'using cached version|unable to download' "$err"; then rc=2; fi
  update_err=$(grep -vE '^evaluation warning' "$err" || true)
  rm -f "$err"
  return "$rc"
}

relock_input() { # $1 input name
  printf '  %-18s ' "$1"
  local rc=0
  nix_update "$REPO" "$1" || rc=$?
  if [ "$rc" = 1 ]; then
    git -C "$REPO" checkout -q -- flake.lock
    echo "FAILED to resolve"
    printf '%s\n' "$update_err" | sed 's/^/    /' >&2
    return 1
  fi
  if [ "$rc" = 2 ]; then
    git -C "$REPO" checkout -q -- flake.lock
    echo "FAILED to fetch — nix fell back to a cached copy, so the bump is NOT carried"
    printf '%s\n' "$update_err" | grep -E 'using cached version|unable to download|error|status' | sed 's/^/    /' >&2
    return 1
  fi
  if git -C "$REPO" diff --quiet -- flake.lock; then
    echo "already current"
    return 0
  fi
  # A lock has to be fetchable by everyone, not only by whoever ran this. The ONLY way a local
  # revision can enter one is a path- or file-typed ref: a `github:` fetch physically cannot see an
  # unpushed commit, which is what makes the chain push-gated to begin with. Measured 2026-10-06 —
  # re-locking ndh's `rke2lab` input resolved the PUSHED head while the local checkout sat two
  # commits ahead of it. So this single check IS the invariant; probing "is the rev on the remote"
  # as well would be vacuous.
  local locked_at
  # Checked: an unreadable lock left `locked_at` empty, and an empty answer is what "not local" looks
  # like — the guard against machine-local locks would have waved it through in silence.
  if ! locked_at=$(jq -r --arg i "$1" '
    (.nodes.root.inputs[$i]) as $n
    | if ($n | type) != "string" then ""
      else
        .nodes[$n].locked
        | if .type == "path" then "path:" + (.path // "")
          elif ((.url // "") | test("^(file|git\\+file)://")) then .url
          else "" end
      end' "$REPO/flake.lock"); then
    git -C "$REPO" checkout -q -- flake.lock
    echo "FAILED to read the updated lock — bump NOT carried"
    return 1
  fi
  if [ -n "$locked_at" ]; then
    git -C "$REPO" checkout -q -- flake.lock
    echo "LOCAL lock REFUSED -> $locked_at"
    echo "relock: that revision resolves only on this machine, so the lock would be unfetchable" >&2
    echo "        for every other consumer. Aim this id at a PUSHED ref and run again — another" >&2
    echo "        branch is fine (its revisions are on the remote), a local checkout is not." >&2
    return 1
  fi
  local after
  # Checked by hand: relock_input runs as `relock_input … || true`, and bash switches errexit off
  # for the whole body of a function called in an `||` list. Unchecked, a failed measurement left
  # `after` empty, unequal to the baseline, and the bump was COMMITTED as "derivations moved".
  if ! after=$(evalmap); then
    git -C "$REPO" checkout -q -- flake.lock
    echo "FAILED to measure impact — bump NOT carried"
    return 1
  fi
  if [ "$after" = "$baseline" ]; then
    # A lock is a statement about outputs: carrying this adds nothing and would keep the
    # rke2lab <-> ndh cycle turning.
    git -C "$REPO" checkout -q -- flake.lock
    echo "moved, NO derivation impact -> dropped"
  else
    if ! git -C "$REPO" commit -q -m "chore(flake): relock $1" -- flake.lock; then
      git -C "$REPO" checkout -q -- flake.lock
      echo "FAILED to commit the bump — lock restored"
      return 1
    fi
    baseline=$after
    committed=1
    echo "BUMPED — derivations moved"
  fi
}

# Orphan-branch hops are OPTIONAL — a repo with none simply skips them. NOT a parameter: a
# repo either carries such a branch or it does not, and `git worktree list` already answers
# that. This is what lets the same implementation serve a repo like ndh, which has neither a
# seed-incluster nor a flox-catalog branch.
# The branch names come in as variables, set at the checkout guard above, not as tokens inline:
# after substitution a token IS a literal, and shellcheck rejects `[ -n "literal" ]` (SC2157) —
# correctly, since the test would be constant.
FIRST=""
if [ -n "$pushFirstBranch" ]; then FIRST=$(wt_for_branch "$pushFirstBranch") || FIRST=""; fi
CATALOG=""
if [ -n "$catalogBranch" ]; then CATALOG=$(wt_for_branch "$catalogBranch") || CATALOG=""; fi

# There WAS a pre-flight check here: read `original.ref` out of the catalog's lock and refuse
# if it differed from the branch we stand on. It is gone, and not because it was inconvenient.
#
# It PREDICTED by name what the catalog hop already MEASURES by revision: the post-condition at
# the end of that hop compares the rev the catalog ended up pinning against the rev this run
# pushed, and exits 1 when they differ. That assertion covers the same failure — and covers it
# for every shape of target, whether the catalog names a ref, names none, or points at a local
# checkout. The name-based prediction only ever worked for one of those three.
#
# And it was actively in the way: the catalog's pin is now an INDIRECT id, so there is no
# `original.ref` to read. The check would have silently skipped itself (`[ -n "$cat_ref" ]`)
# while looking like it still guarded something — the worst of the two outcomes. Any repair of
# that pin removes the ref, so this check could not survive the chantier in any form.
#
# One guard that measures beats two where one guesses.

# No target = everything, in dependency order: artifacts first (they can move the
# derivations the input guard compares against), then inputs, then the catalog.
if [ "${#targets[@]}" -eq 0 ]; then
  targets=(artifacts inputs envs catalog)
fi

echo "worktrees:"
echo "  @repoName@ ($cur) : $REPO"
if [ -n "$pushFirstBranch" ]; then echo "  $pushFirstBranch : ${FIRST:-<no worktree>}"; fi
if [ -n "$catalogBranch" ]; then echo "  $catalogBranch : ${CATALOG:-<no worktree>}"; fi
echo "targets: ${targets[*]}"
echo

# Our own branches first: an orphan-branch INPUT resolves github:, which sees only what is
# pushed.
if [ -n "$FIRST" ] && [ "$nopush" = 1 ]; then
  # Honest, not silent: the inputs below still resolve github:, so they see the REMOTE head, which
  # may be behind this worktree.
  echo "== own branches: NOT pushed (--no-push) =="
  first_remote=$(git -C "$FIRST" ls-remote origin "refs/heads/$pushFirstBranch" | cut -c1-9)
  echo "  $pushFirstBranch NOT pushed: its input resolves the remote head ${first_remote:-<none>}," \
    "not this worktree's $(git -C "$FIRST" rev-parse --short=9 HEAD)"
  echo
elif [ -n "$FIRST" ]; then
  echo "== own branches: push before resolving =="
  git -C "$FIRST" push origin "$pushFirstBranch"
  echo "  $pushFirstBranch @ $(git -C "$FIRST" rev-parse --short=9 HEAD) pushed"
  echo
fi

baseline=$(evalmap)
do_catalog=0
env_targets=()
committed=0
for t in "${targets[@]}"; do
  t=${alias_of[$t]:-$t}
  case $t in
    # Every generated artifact this repo knows how to re-derive.
    artifacts)
      echo "== artifacts (every regen-* app) =="
      while read -r app; do regen_artifact "$app" || true; done < <(regen_apps)
      echo ;;
    regen-*)  echo "== $t ==" ; regen_artifact "$t" || true ; echo ;;
    inputs)
      echo "== inputs =="
      while read -r i; do relock_input "$i" || true; done < <(all_inputs)
      echo ;;
    # ⚠️ The env locks are NOT taken here. They resolve `path:../../..#<attr>` against the
    # CATALOG's flake, so locking before its rke2lab pin moves records the OLD derivation
    # and then reports "unchanged (churn dropped)" — a sincere answer to a question asked too
    # early. Measured 2026-09-30: cluster-api/seed-incluster reported unchanged, the pin then
    # advanced, and the env kept pinning the previous controller binary, so the node would
    # never have realised it. Re-locking the SAME env after the bump reported BUMPED and the
    # drv changed. So the targets only RECORD what to lock; the catalog hop does it, after.
    # Naming an env is for a SURGICAL act only. Normally you do not: any change committed to
    # rke2lab implies the catalog must be re-pinned and the envs re-locked, because the
    # envs resolve `path:../../..#<attr>` THROUGH the catalog's flake. Requiring the
    # operator to pair `relock seed-incluster envs:cluster-api/seed-incluster` made them
    # supply a dependency relation they should not have to know — and let them name the
    # wrong env, or forget it. The derivation guard drops the envs that did not move, so
    # re-locking all of them is both cheap and correct.
    envs) env_targets+=("") ; do_catalog=1 ;;
    envs:*) env_targets+=("${t#envs:}") ; do_catalog=1 ;;
    catalog) do_catalog=1 ;;
    *)
      if all_inputs | grep -qx -- "$t"; then
        echo "== input $t =="
        relock_input "$t" || true
        echo
      else
        echo "relock: unknown target '$t' (try --help)" >&2
        exit 2
      fi ;;
  esac
done

# Anything committed here must TRAVEL: the catalog pins rke2lab and the envs resolve
# through it, so a change that stops at this repo is a change the nodes never see. The
# operator therefore never has to pair a target with its env — see the note at the env
# targets.
if [ "$committed" = 1 ] && [ "$do_catalog" = 0 ] && [ -n "$CATALOG" ]; then
  do_catalog=1
  env_targets=("")
  if [ "$nopush" = 0 ]; then
    echo "  (committed here ⇒ re-pinning the catalog and re-locking every env)"
    echo
  fi
fi

# Push whatever the artifacts did. The catalog hop resolves
# github:seedmatic/rke2lab/<branch> and therefore pins what the REMOTE answers, not this
# worktree — so pushing only on a change was the hole: any other commit left HEAD
# unpushed and the catalog silently pinned an older rev while reporting a clean bump
# (measured 2026-09-30: catalog at 9ccd89923 while HEAD was fec07de85).
if [ "$nopush" = 1 ]; then
  ahead=$(git -C "$REPO" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")
  echo "== NOT pushed (--no-push) =="
  echo "  @repoName@ ($cur): $ahead commit(s) ahead of its upstream — review them with:"
  echo "    git -C '$REPO' log --stat '@{u}..HEAD'"
  resume=()
  if [ -n "$FIRST" ]; then resume+=("git -C '$FIRST' push origin '$pushFirstBranch'"); fi
  resume+=("git -C '$REPO' push")
  # The catalog hop measures the revision a push landed, so it can only follow a push. `envs`, not
  # `catalog`: the catalog target alone re-pins without re-locking a single env.
  if [ -n "$CATALOG" ] && { [ "$do_catalog" = 1 ] || [ "$committed" = 1 ]; }; then
    echo "  catalog hop SKIPPED: it measures the revision a push landed"
    resume+=("(cd '$REPO' && nix run .#relock -- envs)")
  fi
  echo
  echo "To resume where this stopped:"
  printf '  %s' "${resume[0]}"
  for r in "${resume[@]:1}"; do printf ' && %s' "$r"; done
  echo
  echo "DONE (not pushed)"
  exit 0
fi
git -C "$REPO" push
pushed_head=$(git -C "$REPO" rev-parse HEAD)
echo "  @repoName@ @ ${pushed_head:0:9} pushed"
echo

# ⚠️ `-n "$CATALOG"` is load-bearing, and its absence was a latent defect: the header claims this
# implementation serves a repo with no such branch, yet an unguarded hop would `lockrev "/flake.lock"`
# and die on exactly that repo. A repo without a catalog branch simply has nothing to re-pin.
if [ "$do_catalog" = 1 ] && [ -n "$CATALOG" ]; then
  echo "== own branch @catalogBranch@: pin @selfPinName@ =="
  pin_before=$(lockrev "$CATALOG/flake.lock" @selfPinName@)
  # The catalog branch is a different checkout with its own committed registry, so the pin is
  # re-resolved for it rather than inherited from the main one.
  set_registry_flag "$CATALOG"
  if ! nix_update "$CATALOG" @selfPinName@; then
    git -C "$CATALOG" checkout -q -- flake.lock
    echo "FAILED: the catalog could not re-resolve @selfPinName@ (nix failed, or fell back to a cache):" >&2
    printf '%s\n' "$update_err" | sed 's/^/    /' >&2
    exit 1
  fi
  pin_after=$(lockrev "$CATALOG/flake.lock" @selfPinName@)
  if [ "$pin_before" != "$pin_after" ]; then
    git -C "$CATALOG" commit -q -m "chore(flake): relock @selfPinName@ -> ${pin_after:0:9}" -- flake.lock
    echo "  pinned @selfPinName@ ${pin_before:0:9} -> ${pin_after:0:9}"
  else
    echo "  already pinning @selfPinName@ ${pin_after:0:9}"
  fi
  # NOW the envs, with the pin already moved — see the note at the env targets above.
  # lock-envs applies the same guard one level down: it re-locks and commits only real
  # derivation bumps, dropping locked-url churn.
  for e in "${env_targets[@]}"; do
    lock_envs=$(cd "$CATALOG" && app_program ".#apps.@system@.lock-envs")
    if [ -z "$e" ]; then
      ( cd "$CATALOG" && "$lock_envs" )
    else
      ( cd "$CATALOG" && "$lock_envs" "$e" )
    fi
  done
  # ASSERT the landing rather than trust the bump report: a lagging push, a stale
  # --refresh cache or a catalog tracking another branch all end here quietly on a rev
  # that is not what this run built. The point is to make ONE revision travel — prove it.
  if [ "$pin_after" != "$pushed_head" ]; then
    echo "MISMATCH: the catalog pinned @selfPinName@ ${pin_after:0:9} but this run pushed ${pushed_head:0:9} —" >&2
    echo "the propagation did NOT carry this revision. Check that '$cur' is the branch the" >&2
    echo "catalog tracks and that the push above reached the remote." >&2
    exit 1
  fi
  echo "  verified: catalog pins @selfPinName@ ${pushed_head:0:9} — the revision this run pushed"
  ahead=$(git -C "$CATALOG" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
  if [ "${ahead:-0}" -gt 0 ] 2>/dev/null; then
    git -C "$CATALOG" push
    echo "  @catalogBranch@ pushed $ahead commit(s)"
  else
    echo "  @catalogBranch@ already up to date"
  fi
  echo
fi

# Crossing a repo boundary is a REQUEST, never a reach-in: we do not edit a consumer's
# lock, we run the consumer's OWN relock. Off by default — it mutates another repo.
consumers=(@consumers@)
if [ "$downstream" = 1 ]; then
  echo "== downstream: request each consumer's own relock =="
  # A request, so a failure here is not fatal — but it is SAID, with the consumer's name and its own
  # stderr. The first version ran `nix run "$c#relock" 2>/dev/null` and answered every failure with
  # "exposes no #relock yet": a consumer whose relock CRASHED read exactly like one that has none.
  for c in "${consumers[@]}"; do
    printf '  %-28s ' "$c"
    if ! has_relock=$(nix eval --json "$c#apps.@system@" --apply 'as: as ? relock'); then
      echo "FAILED — cannot evaluate $c (its error is above)"
    elif [ "$has_relock" != true ]; then
      echo "exposes no #relock yet — skipped (that app is THAT repo's to add)"
    elif prog=$(app_program "$c#apps.@system@.relock") && "$prog"; then
      echo "  ^ $c done"
    else
      echo "  ^ FAILED — $c's relock exited non-zero (its output is above)"
    fi
  done
else
  echo "consumers NOT notified (pass --downstream): ${consumers[*]}"
fi
echo "DONE"
