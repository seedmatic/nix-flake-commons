# shellcheck shell=bash
# relock — ONE implementation, shared by every head of the fabric. See rke2lab's
# docs/architecture/fabric/relock-bootstrap-spec.adoc; built by nix-flake-commons' `lib.mkRelockApp`.
#
# Build-time tokens (written WITHOUT at-sigils here so replaceVars does not substitute them in this
# comment): repoName (the head's id in fabric/heads), system, afterInputs, toolId, toolSlug, planJq,
# configurationsNix.
#
# ★ WHY the name is identical in every repo: propagation is a REQUEST, and the caller must know
# nothing about the callee beyond its name. The same reasoning applies one level down, to the
# implementation: if each repo wrote its own, "the same rule everywhere" would be a claim nobody could
# check. So the rule lives once, and each head supplies only what is ITS OWN: its id, and the apps it
# runs after its inputs.

downstream=0
nopush=0
planonly=0
targets=()

afterInputs=(@afterInputs@)

for a in "$@"; do
  case $a in
    --downstream) downstream=1 ;;
    --no-push) nopush=1 ;;
    --plan) planonly=1 ;;
    -h|--help)
      cat <<'USAGE'
relock [--downstream | --no-push | --plan] [target...]

Reconcile this head's lock. No target = ALL of it.

  inputs            every flake input          -> flake.lock
  <input-name>      one input, by its name in flake.lock
  after             the apps this head runs after its inputs (afterInputs)

An input bump that moves no exported derivation (packages, apps, configurations with their revision
neutralised) is DROPPED, not carried. After a push, the trace of the change is written on this repo's
`fabric/relock` branch, which nothing pins.

--plan prints the plan of a pass started here, as JSON, and changes nothing: the heads come from
nix-flake-commons' `fabric/heads`, the edges from each code head's lock, both read through the GitHub
API. A cycle, an id that is not a head, or an id that resolves elsewhere fails it.
--downstream plays that plan: each head of it runs its own relock once, on the pass's tool, in the
plan's order; a head that pins a failed head is not run. The pass ends non-zero naming every failure.
Exit 3: everything landed, but a trace could not be written (the heads that pin it still run).
A pass runs ONE relock everywhere: each head's is built with `--override-input flake-commons` on the
pass's tool, and a relock of any other code refuses.
--no-push commits in THIS checkout and stops before anything leaves it, so the commits can be
reviewed; it prints the exact command that resumes where it stopped.

GitHub token: read from `gh auth token` at each run and handed ONLY to relock's own nix and API calls,
as extra-access-tokens appended to NIX_CONFIG, and to curl on its stdin. Never written anywhere, never
exported, and never passed to the programs relock runs (afterInputs apps, another head's relock).
USAGE
      exit 0 ;;
    -*) echo "relock: unknown flag '$a' (try --help)" >&2; exit 2 ;;
    *) targets+=("$a") ;;
  esac
done
# A head only ever sees what is pushed, so playing a pass after a run that pushed nothing would
# relock the next heads against the revision this run did NOT carry — and report success.
if [ "$nopush" = 1 ] && [ "$downstream" = 1 ]; then
  echo "relock: --no-push and --downstream contradict each other — a head sees only what is pushed" >&2
  exit 2
fi

# A MEMBER of a pass is a relock its pass's starter runs, the starter's own included. It carries the
# plan, and the tool of the pass: a run of any other code refuses before anything, because each head
# would otherwise run the relock of its own flake-commons pin, and a fix to relock would reach a head
# only on the pass AFTER the one that bumped it there.
member=0
if [ -n "${RELOCK_PASS_PLAN:-}" ]; then
  member=1
  if [ ! -f "$RELOCK_PASS_PLAN" ]; then
    echo "relock(@repoName@): the plan of this pass ($RELOCK_PASS_PLAN) is gone — refusing to run outside it" >&2
    exit 1
  fi
  if [ "${RELOCK_PASS_TOOL_ID:-}" != "@toolId@" ]; then
    echo "REFUSING: relock(@repoName@) is tool @toolId@, but this pass runs tool ${RELOCK_PASS_TOOL_ID:-<none named>}:" >&2
    echo "          one pass runs one relock — its starter must build this one on the pass's tool" >&2
    exit 1
  fi
  if [ -n "${RELOCK_HEAD:-}" ] && [ "$RELOCK_HEAD" != "@repoName@" ]; then
    echo "REFUSING: the pass called head '$RELOCK_HEAD', but this relock is head '@repoName@'" >&2
    exit 1
  fi
  if [ "$downstream" = 1 ] || [ "$planonly" = 1 ]; then
    echo "relock(@repoName@): a member of a pass plays no pass of its own" >&2
    exit 2
  fi
fi

# The GitHub token, for the PRIVATE inputs (measured 2026-10-07: without one, nix fetched ndh's
# private claude-hub input as a 404 and fell back to a stale cache). Taken from `gh auth token` at
# each run rather than stored: the copy that used to live in nix.conf expired and nobody noticed.
#
# ⚠️ Scoped to relock's OWN nix and API calls, and that is the whole design. The variable is NOT
# exported, and `nix` below is a function that appends the token to NIX_CONFIG for that one process
# only — APPENDED, as extra-access-tokens, because NIX_CONFIG may already carry settings (the flox hook
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

# One file of a head, through the GitHub API: a few hundred milliseconds, where `nix flake metadata`
# downloads the head's whole tree to read one file (measured 2026-10-09: 0.45 s against 2.3 s and
# 3.9 MB on rke2lab). Any HTTP error fails: an answer that did not come is never read as an empty one.
# The token travels on curl's stdin, never in its arguments, which every process can read.
api_raw() { # $1 owner/repo  $2 branch  $3 path -> the file on stdout
  local ref
  ref=$(jq -rn --arg b "$2" '$b | @uri')
  {
    if [ -n "$gh_token" ]; then printf 'header = "Authorization: Bearer %s"\n' "$gh_token"; fi
    printf 'header = "Accept: application/vnd.github.raw"\n'
  } | curl --config - -fsSL "https://api.github.com/repos/$1/contents/$3?ref=$ref"
}

# An app's program, BUILT with the token, so that running it afterwards needs no fetch and gets no
# token. `nix build` refuses the program string itself, so its context's derivations are built.
# Empty but for another head's relock, which is built on the pass's tool. An override never writes a
# lock: nothing here passes --commit-lock-file.
tool_override=()
# Read with --refresh, and a fallback to nix's cache is refused: a program served from a stale copy
# would run another head's OLD relock while the pass believes it runs its tool.
cache_refused() { # $1 nix's stderr -> 0 when nix fell back to a cache, said
  if grep -qE 'using cached version|unable to download' "$1"; then
    sed 's/^/    /' "$1" >&2
    echo "relock: nix answered from its cache — refusing that answer" >&2
    return 0
  fi
  return 1
}
app_program() { # $1 app installable (flake#apps.<system>.<name>) -> program path on stdout
  local prog d ctx err
  local -a drvs=()
  err=$(mktemp)
  if ! prog=$(nix eval --raw --refresh "${tool_override[@]}" "$1.program" 2>"$err") || cache_refused "$err"; then
    grep -v '^evaluation warning' "$err" >&2 || true; rm -f "$err"; return 1
  fi
  if ! ctx=$(nix eval --json --refresh "${tool_override[@]}" "$1.program" --apply 'p: builtins.attrNames (builtins.getContext p)' 2>"$err") || cache_refused "$err"; then
    grep -v '^evaluation warning' "$err" >&2 || true; rm -f "$err"; return 1
  fi
  rm -f "$err"
  mapfile -t drvs < <(jq -r '.[]' <<<"$ctx")
  for d in "${drvs[@]}"; do nix build --no-link "$d^*" || return 1; done
  printf '%s\n' "$prog"
}

# Every target that FAILED in this run, named. A failure does not stop the others, and what did
# succeed is still pushed — but the run then ends non-zero with the list, so a starter reads a
# failure, not "done", and counts it in its own list in turn.
#
# A trace that could not be written is a failure of its own, exit 3: the change it traces HAS landed,
# so a pass still runs the heads that pin this one, and only names the missing trace.
failed=()
trace_failed=()
finish() { # $1 the word for success
  if [ "${#failed[@]}" -eq 0 ] && [ "${#trace_failed[@]}" -eq 0 ]; then echo "$1"; exit 0; fi
  echo "FAILED: $(( ${#failed[@]} + ${#trace_failed[@]} )) target(s)"
  if [ "${#failed[@]}" -gt 0 ]; then printf '  %s\n' "${failed[@]}"; fi
  if [ "${#trace_failed[@]}" -gt 0 ]; then printf '  %s\n' "${trace_failed[@]}"; fi
  if [ "${#failed[@]}" -eq 0 ]; then exit 3; fi
  exit 1
}

# THE HEADS. Who this relock is — its repository, its branch — is no argument of the factory: it is
# its entry in fabric/heads, the one list of the fabric's heads, read once per pass (a member reads it
# from the plan, so a whole pass sees one list).
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
heads="$work/heads.json"
if [ "$member" = 1 ]; then
  jq '.heads' "$RELOCK_PASS_PLAN" > "$heads"
elif ! api_raw "@toolSlug@" "fabric/heads" "heads.json" > "$work/fabric-heads.json"; then
  echo "relock(@repoName@): cannot read fabric/heads from @toolSlug@ — refusing to guess who this is" >&2
  exit 1
elif ! jq -e '.schema == "seedmatic.fabric-heads/v1" and (.heads | type == "object")' "$work/fabric-heads.json" >/dev/null 2>&1; then
  echo "relock(@repoName@): fabric/heads holds no seedmatic.fabric-heads/v1 — refusing to read it" >&2
  exit 1
else
  jq '.heads' "$work/fabric-heads.json" > "$heads"
fi
selfRepo=$(jq -r '.["@repoName@"].repo // empty' "$heads")
selfBranch=$(jq -r '.["@repoName@"].branch // empty' "$heads")
selfKind=$(jq -r '.["@repoName@"].kind // empty' "$heads")
if [ -z "$selfRepo" ] || [ "$selfKind" != code ]; then
  echo "REFUSING: '@repoName@' is not a code head of fabric/heads — a relock's name is its head's id" >&2
  exit 1
fi
toolSlug="@toolSlug@"

# A checkout BELONGS to this head when it is a checkout of the head's repository on the head's
# branch, or on a session of it. The sessions of a head on `develop` are the branches of no other
# head's namespace; the sessions of `seed-incluster/develop` are `seed-incluster/*`. Matching on the
# repository alone reconciled one flake of a repo by another's rules, silently.
namespace_of() { case $1 in */*) printf '%s\n' "${1%%/*}" ;; *) printf '\n' ;; esac; }
belongs() { # $1 branch -> 0 when it is this head's branch or a session of it
  local b=$1 ns
  [ "$b" = "$selfBranch" ] && return 0
  ns=$(namespace_of "$selfBranch")
  if [ -n "$ns" ]; then
    case $b in "$ns"/*) return 0 ;; *) return 1 ;; esac
  fi
  jq -e --arg r "$selfRepo" --arg b "$b" '[ .[] | select(.repo == $r) | .branch | select(contains("/")) | split("/")[0] ]
    | index($b | split("/")[0]) == null' "$heads" >/dev/null
}

# The checkout this run reconciles, if the CWD is one of ours: matched on the origin's slug, because a
# local checkout may speak ssh where the remote speaks https.
REPO=""
cur=""
if top=$(git rev-parse --show-toplevel 2>/dev/null); then
  origin=$(git -C "$top" remote get-url origin 2>/dev/null || true)
  origin=${origin%.git}
  case "$origin" in
    *"$selfRepo") REPO=$top ;;
  esac
fi

# THE PASS. Planned from facts only, then played: each head of the plan runs its own relock once, in
# the plan's order. Nothing ends a cycle here, because a cycle never gets this far.
if [ "$member" = 0 ] && { [ "$downstream" = 1 ] || [ "$planonly" = 1 ]; }; then
  if [ -n "$REPO" ]; then
    cur=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
    if [ "$downstream" = 1 ] && [ "$cur" != "$selfBranch" ]; then
      echo "REFUSING --downstream from '$cur': a pass starts from the head's own branch, '$selfBranch' —" >&2
      echo "          the heads after it pin what is pushed there, not a session" >&2
      exit 1
    fi
  fi

  # The tool of the pass, as a FETCHABLE reference, proven before anything moves: every head's relock
  # is built from it. From the tool's own head it is that head's pushed revision; from any other, the
  # start's pushed flake-commons pin. Unpushed code cannot pass for either.
  mapfile -t code_heads < <(jq -r 'to_entries[] | select(.value.kind == "code") | .key' "$heads" | sort)
  plan_errors=()
  locks="$work/locks.json"
  echo '{}' > "$locks"
  for id in "${code_heads[@]}"; do
    repo=$(jq -r --arg i "$id" '.[$i].repo' "$heads")
    branch=$(jq -r --arg i "$id" '.[$i].branch' "$heads")
    if ! api_raw "$repo" "$branch" flake.lock > "$work/lock-$id.json" || ! jq -e '.nodes' "$work/lock-$id.json" >/dev/null 2>&1; then
      plan_errors+=("cannot read the lock of $id ($repo:$branch) through the GitHub API")
      continue
    fi
    jq --arg i "$id" --slurpfile l "$work/lock-$id.json" '. + { ($i): $l[0] }' "$locks" > "$work/locks.next" && mv "$work/locks.next" "$locks"
  done
  if [ "${#plan_errors[@]}" -gt 0 ]; then
    echo "relock(@repoName@): NO PLAN — the facts could not all be read:" >&2
    printf '  %s\n' "${plan_errors[@]}" >&2
    exit 1
  fi
  plan="$work/plan.json"
  jq -n --arg start "@repoName@" --slurpfile h "$heads" --slurpfile l "$locks" \
    '{ start: $start, heads: $h[0], locks: $l[0] }' | jq -f "@planJq@" > "$plan"

  if [ "$selfRepo" = "$toolSlug" ]; then
    tool_rev=$(git ls-remote "https://github.com/$selfRepo.git" "refs/heads/$selfBranch" | cut -f1)
    tool_ref="github:$selfRepo/${tool_rev:-<none>}"
  else
    tool_ref=$(jq -r --arg s "@repoName@" '.locks[$s] as $l | $l.nodes[$l.root].inputs["flake-commons"] as $n
      | if ($n | type) == "string" and $l.nodes[$n].locked.type == "github"
        then "github:\($l.nodes[$n].locked.owner)/\($l.nodes[$n].locked.repo)/\($l.nodes[$n].locked.rev)" else "" end' \
      <(jq -n --slurpfile l "$locks" '{ locks: $l[0] }'))
  fi
  jq --arg id "@toolId@" --arg ref "$tool_ref" '. + { tool: { id: $id, ref: $ref } }' "$plan" > "$work/plan.next" && mv "$work/plan.next" "$plan"

  if [ "$planonly" = 1 ]; then
    jq 'del(.heads)' "$plan"
    if jq -e '.errors | length > 0' "$plan" >/dev/null; then exit 1; fi
    exit 0
  fi
  if jq -e '.errors | length > 0' "$plan" >/dev/null; then
    echo "relock(@repoName@): NO PASS — the plan fails before anything moves:" >&2
    jq -r '.errors[] | "  " + .' "$plan" >&2
    exit 1
  fi
  if [ -z "$tool_ref" ] || [ "${tool_ref##*/}" = "<none>" ]; then
    echo "REFUSING --downstream: @repoName@ names no pushed tool (no github: flake-commons pin, or the tool's head is not on the remote)" >&2
    exit 1
  fi
  tool_err=$(mktemp)
  if ! pass_tool=$(nix eval --raw --refresh "$tool_ref#lib.relockToolId" 2>"$tool_err") || cache_refused "$tool_err"; then
    rm -f "$tool_err"
    echo "REFUSING --downstream: the pass's tool $tool_ref cannot be fetched" >&2
    exit 1
  fi
  rm -f "$tool_err"
  if [ "$pass_tool" != "@toolId@" ]; then
    echo "REFUSING --downstream: $tool_ref is tool $pass_tool, not the one running here (@toolId@)" >&2
    echo "          — commit and push the relock you mean to run, or run the one that is pushed" >&2
    exit 1
  fi

  RELOCK_PASS_TOOL_ID="@toolId@"
  RELOCK_PASS_TOOL_REF="$tool_ref"
  RELOCK_PASS_WAVE="@repoName@@$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  pass_plan=$(mktemp)
  jq --arg w "$RELOCK_PASS_WAVE" '. + { wave: $w }' "$plan" > "$pass_plan"
  RELOCK_PASS_PLAN="$pass_plan"
  export RELOCK_PASS_TOOL_ID RELOCK_PASS_TOOL_REF RELOCK_PASS_WAVE RELOCK_PASS_PLAN
  trap 'rm -rf "$work" "$pass_plan"' EXIT
  tool_override=(--override-input flake-commons "$RELOCK_PASS_TOOL_REF")

  mapfile -t order < <(jq -r '.order[]' "$plan")
  echo "== pass $RELOCK_PASS_WAVE, on the tool $RELOCK_PASS_TOOL_REF =="
  echo "order: ${order[*]}"
  echo
  declare -A down=()
  here=$(pwd)
  for id in "${order[@]}"; do
    # A head that pins a head which failed, or was not run, would relock against what that head did
    # NOT carry: it is not run, and the failure is said with the head it waits on.
    blocked=$(jq -r --arg i "$id" '.edges[] | select(.from == $i) | .to' "$plan" | while read -r d; do
      if [ -n "${down[$d]:-}" ]; then printf '%s\n' "$d"; fi; done | head -n1)
    if [ -n "$blocked" ]; then
      echo "== $id: NOT RUN — it pins $blocked, which did not land in this pass =="
      failed+=("head $id (pins $blocked)")
      down[$id]=1
      continue
    fi
    echo "== $id =="
    rc=0
    if [ "$id" = "@repoName@" ]; then
      # The start's own relock, by the very program running here, in the operator's checkout.
      ( cd "$here" && RELOCK_HEAD="$id" "$0" "${targets[@]}" ) || rc=$?
    else
      repo=$(jq -r --arg i "$id" '.[$i].repo' "$heads")
      branch=$(jq -r --arg i "$id" '.[$i].branch' "$heads")
      if ! prog=$(app_program "github:$repo/$branch#apps.@system@.relock"); then
        echo "  FAILED — cannot build $id's relock on the pass's tool (its error is above)"
        rc=1
      else
        # Run from outside any checkout, so the head clones its own branch.
        elsewhere=$(mktemp -d)
        ( cd "$elsewhere" && RELOCK_HEAD="$id" "$prog" ) || rc=$?
        rm -rf "$elsewhere"
      fi
    fi
    if [ "$rc" = 3 ]; then
      echo "  ^ $id landed, but its trace was not written (its output is above)"
      trace_failed+=("trace $id (its change landed)")
    elif [ "$rc" != 0 ]; then
      echo "  ^ FAILED — $id's relock exited $rc (its output is above)"
      failed+=("head $id")
      down[$id]=1
    else
      echo "  ^ $id done"
    fi
    echo
  done
  finish "DONE (pass $RELOCK_PASS_WAVE)"
fi

# THE LOCAL RULE, the same for every head and in every pass: bump, drop what moves nothing exported,
# commit, push, trace.
if [ -n "$REPO" ]; then
  cur=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
  if ! belongs "$cur"; then
    echo "REFUSING: this checkout of $selfRepo is on '$cur', which is not '$selfBranch' nor a session of it:" >&2
    echo "          it belongs to another head of the repository. Run that head's relock from here, or" >&2
    echo "          this one from its own checkout." >&2
    exit 1
  fi
  echo "relock(@repoName@): reconciling the checkout at $REPO ($cur)"
else
  # A REQUESTED run, from somewhere that is not our checkout. We clone, reconcile and PUSH: the chain
  # is push-gated anyway (a `github:` input only ever sees what is pushed), so the remote is the only
  # place a request can usefully land. Unpushed commits in a throwaway clone would vanish with it:
  # --no-push needs the operator's checkout.
  if [ "$nopush" = 1 ]; then
    echo "relock: --no-push needs a checkout of $selfRepo on $selfBranch — run it from there;" >&2
    echo "        in a clone, the unpushed commits would be lost with it" >&2
    exit 2
  fi
  # Canonical, because nix refuses a git+file flake whose path crosses a symlink once its tree is
  # dirty — and a bumped lock makes it dirty. TMPDIR may well cross one (macOS: /tmp -> private/tmp).
  REPO=$(realpath "$(mktemp -d)")/@repoName@
  echo "relock(@repoName@): not inside this head — cloning $selfRepo ($selfBranch) to reconcile and push"
  # Shallow: a requested run reads no history, it bumps the tip and pushes it.
  git clone --quiet --depth=1 --branch "$selfBranch" "https://github.com/$selfRepo.git" "$REPO" \
    || { echo "relock: cannot clone $selfRepo $selfBranch" >&2; exit 1; }
  cur=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
  echo "relock(@repoName@): cloned at $cur"
fi

# The registry that resolves a head's INDIRECT inputs, pinned by a CLI flag rather than left to
# NIX_CONFIG (measured 2026-10-06: `--flake-registry` beats a NIX_CONFIG aimed elsewhere, and leaving
# NIX_CONFIG alone matters because that is where access-tokens for the private inputs live). It
# points at the head's EFFECTIVE registry: the operator's gitignored flake-registry.local.json when
# one exists — re-aiming an input at the branch you work on, and having relock follow you there, is
# what the indirection is for — the committed flake-registry.json otherwise. A fresh clone has no
# gitignored file, so the only local file relock can read is the operator's own.
#
# The COMMITTED registry must agree with fabric/heads, id by id: three lists that map an id to a
# repository drift apart exactly where nobody looks. The local one may disagree — that is its purpose.
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
if [ -f "$REPO/flake-registry.json" ]; then
  if ! drift=$(jq -r --slurpfile h "$heads" '.flakes[] | . as $f | $h[0][$f.from.id] as $e
      | if $e == null then "\($f.from.id): not a head of fabric/heads"
        elif "\($f.to.owner)/\($f.to.repo)" != $e.repo or ($f.to.ref // "develop") != $e.branch
        then "\($f.from.id): \($f.to.owner)/\($f.to.repo) at \($f.to.ref // "develop"), but fabric/heads has \($e.repo) at \($e.branch)"
        else empty end' "$REPO/flake-registry.json"); then
    echo "REFUSING: cannot read $REPO/flake-registry.json" >&2
    exit 1
  fi
  if [ -n "$drift" ]; then
    echo "REFUSING: the committed flake-registry.json disagrees with fabric/heads:" >&2
    printf '  %s\n' "$drift" >&2
    exit 1
  fi
fi

# The per-input comparison attributes a derivation change to the input just bumped, so any OTHER
# uncommitted edit would be credited to it. Refuse rather than mislead — flake.lock INCLUDED: an edited
# lock would ride along with the next bump (a `path:` pin on another input, committed and pushed), and a
# dropped bump restores the lock, which would wipe the edit. TRACKED changes only: nix's git fetcher
# excludes untracked files from a flake's source (measured 2026-10-07), so an untracked file cannot
# move any derivation.
dirty=$(git -C "$REPO" status --porcelain --untracked-files=no)
if [ -n "$dirty" ]; then
  echo "REFUSING: the worktree carries uncommitted changes, so a derivation change could not be" >&2
  echo "attributed, and a restored lock would lose them. Commit or set them aside:" >&2
  printf '%s\n' "$dirty" >&2
  exit 1
fi
# A head AHEAD of its upstream carries commits this run did not make — in a shared worktree, another
# session's, not yet reviewed and never checked for a machine-local lock. Pushing them with this run's
# would publish them. Refuse: push them, or set them aside, first.
ahead=$(git -C "$REPO" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "")
if [ -n "$ahead" ] && [ "$ahead" != 0 ]; then
  echo "REFUSING: $cur is $ahead commit(s) ahead of its upstream — commits this run did not make." >&2
  echo "          Push them (after review), or set them aside, then run again:" >&2
  git -C "$REPO" log --oneline '@{u}..HEAD' >&2
  exit 1
fi

lockrev() { # $1 flake.lock  $2 root-input name -> resolved node rev
  jq -r --arg i "$2" '
    .nodes.root.inputs[$i] as $n
    | (if ($n|type)=="array" then $n[-1] else $n end) as $nn
    | .nodes[$nn].locked.rev // empty' "$1"
}

# The MEANINGFUL projection of a flake edge: every exported derivation — each package's and the ones
# behind each app's program, for EVERY system the flake exposes (from darwin, a bump that moves only
# aarch64-linux packages was dropped: nnh's squashfs, flox-nri-plugin), and each nixos/darwin
# configuration's top level with its revision neutralised (nix/configurations.nix, the measure the
# sweep proves stable). Evaluation only: nothing is built, so a foreign system costs no builder.
# NOT a projection of the lock's fields — in a flake.lock `locked.rev` IS the content identity, so
# deleting it would make every bump compare equal and look impact-free.
#
# A flake with neither `packages` nor configurations is an AGGREGATOR: what it exports is its inputs,
# which the heads that pin it follow — so its impact is the revision each root input is locked at.
#
# The SHAPE is read once, before anything moves: which systems the flake exposes, and which of them
# evaluate. A system that does not evaluate at the start is said, with its error, and left out — it was
# broken before this run (measured 2026-10-09: rke2lab's x86_64 systems). A measured system that stops
# evaluating after a bump is fatal: absent and broken must not look alike.
#
# ⚠️ Every failure is returned EXPLICITLY — evalmap runs inside `$(…)`, where errexit does not carry
# (no `inherit_errexit`).
flake_expr="(builtins.getFlake \"git+file://$REPO\").outputs"
# shellcheck disable=SC2016  # nix's own interpolation, not the shell's
pk_expr='sys: builtins.mapAttrs (_: p: if p ? drvPath then p.drvPath else null) o.packages.${sys}'
# shellcheck disable=SC2016  # nix's own interpolation, not the shell's
ap_expr='sys: builtins.mapAttrs (_: a: builtins.attrNames (builtins.getContext a.program)) o.apps.${sys}'
aggregator=0
pk_systems=()
ap_systems=()
read_shape() {
  local shape sys err
  shape=$(nix eval --impure --json --expr "/* relock:shape */ let o = $flake_expr; in {
      packages = builtins.attrNames (o.packages or { }); apps = builtins.attrNames (o.apps or { });
      configurations = (o ? nixosConfigurations) || (o ? darwinConfigurations); }") || return 1
  if jq -e '(.packages | length) == 0 and (.configurations | not)' <<<"$shape" >/dev/null; then
    aggregator=1
    return 0
  fi
  err=$(mktemp)
  while read -r sys; do
    if nix eval --impure --json --expr "/* relock:probe */ let o = $flake_expr; in ($pk_expr) \"$sys\"" >/dev/null 2>"$err"; then
      pk_systems+=("$sys")
    else
      echo "  packages.$sys NOT MEASURED — it does not evaluate before any bump: $(grep -m1 'error:' "$err" | sed 's/^ *//')"
    fi
  done < <(jq -r '.packages[]' <<<"$shape")
  while read -r sys; do
    if nix eval --impure --json --expr "/* relock:probe */ let o = $flake_expr; in ($ap_expr) \"$sys\"" >/dev/null 2>"$err"; then
      ap_systems+=("$sys")
    else
      echo "  apps.$sys NOT MEASURED — it does not evaluate before any bump: $(grep -m1 'error:' "$err" | sed 's/^ *//')"
    fi
  done < <(jq -r '.apps[]' <<<"$shape")
  rm -f "$err"
}
nix_list() { local x out="["; for x in "$@"; do out+=" \"$x\""; done; printf '%s ]' "$out"; }
evalmap() {
  if [ "$aggregator" = 1 ]; then
    # A `follows` root input has no lock of its own — it is an input PATH whose target is already
    # counted where it is defined — so it is left out rather than resolved.
    jq -S '. as $l | .nodes.root.inputs
      | with_entries(select(.value | type == "string"))
      | map_values($l.nodes[.].locked.rev // $l.nodes[.].locked.narHash)' "$REPO/flake.lock"
    return
  fi
  nix eval --impure --json --expr "/* relock:measure */ let o = $flake_expr;
      each = f: systems: builtins.listToAttrs (map (s: { name = s; value = f s; }) systems); in {
      packages = each ($pk_expr) $(nix_list "${pk_systems[@]}");
      apps = each ($ap_expr) $(nix_list "${ap_systems[@]}");
      configurations = import @configurationsNix@ { outputs = o; }; }" | jq -S . || return 1
}

all_inputs() { jq -r '.nodes.root.inputs | keys[]' "$REPO/flake.lock"; }

# `nix flake update` in $1 for the inputs that follow; its stderr lands in `update_err`.
# Returns 1 when nix fails, 2 when it SUCCEEDS on a stale copy, and 3 when it fails because the
# lock would make one input follow an input of another that does not exist (see `deferred`).
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
  if [ "$rc" = 1 ] && grep -q 'follows a non-existent input' "$err"; then rc=3; fi
  update_err=$(grep -vE '^evaluation warning' "$err" || true)
  rm -f "$err"
  return "$rc"
}

# Inputs whose bump had to wait for another one. Measured 2026-10-07 on rke2lab: ndh, as locked,
# followed an input of flake-commons that the newer flake-commons had dropped; bumping flake-commons
# FIRST removed that input, and nix refused the whole lock. No FIXED order is right, so the order is
# discovered: such a bump is set aside with its lock restored, retried ONCE after every other target,
# and only then reported as failed.
deferred=()
retrying=0

# What this run carried and dropped, for its trace.
bumped='{}'
dropped=()
after_done=()

relock_input() { # $1 input name
  printf '  %-18s ' "$1"
  local rc=0 before
  before=$(lockrev "$REPO/flake.lock" "$1")
  nix_update "$REPO" "$1" || rc=$?
  if [ "$rc" = 3 ]; then
    git -C "$REPO" checkout -q -- flake.lock
    if [ "$retrying" = 0 ]; then
      deferred+=("$1")
      echo "deferred — it is coupled to another input's bump; retried after the others"
      return 0
    fi
    echo "FAILED — still coupled after the other bumps; nothing carried"
    printf '%s\n' "$update_err" | grep 'follows a non-existent input' | sed 's/^/    /' >&2
    echo "    the inputs named above can only move together: nix flake update <both>, then relock" >&2
    return 1
  fi
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
  # unpushed commit, which is what makes the chain push-gated to begin with. So this single check IS
  # the invariant.
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
    echo "        for every other head. Aim this id at a PUSHED ref and run again — another" >&2
    echo "        branch is fine (its revisions are on the remote), a local checkout is not." >&2
    return 1
  fi
  local after
  # Checked by hand: relock_input runs as `relock_input … || failed+=…`, and bash switches errexit
  # off for the whole body of a function called in an `||` list. Unchecked, a failed measurement left
  # `after` empty, unequal to the baseline, and the bump was COMMITTED as "derivations moved".
  if ! after=$(evalmap); then
    git -C "$REPO" checkout -q -- flake.lock
    echo "FAILED to measure impact — bump NOT carried"
    return 1
  fi
  if [ "$after" = "$baseline" ]; then
    git -C "$REPO" checkout -q -- flake.lock
    dropped+=("$1")
    echo "moved, NO derivation impact -> dropped"
  else
    if ! git -C "$REPO" commit -q -m "chore(flake): relock $1" -- flake.lock; then
      git -C "$REPO" checkout -q -- flake.lock
      echo "FAILED to commit the bump — lock restored"
      return 1
    fi
    baseline=$after
    committed=1
    bumped=$(jq -c --arg i "$1" --arg b "$before" --arg a "$(lockrev "$REPO/flake.lock" "$1")" '. + { ($i): [ $b, $a ] }' <<<"$bumped")
    echo "BUMPED — derivations moved"
  fi
}

# An app this head runs AFTER its inputs, because what it produces resolves through them:
# flox-catalog's envs lock `path:../../..#<attr>` against the catalog's own flake, so locking them
# before its rke2lab pin moves records the OLD derivation and reports "unchanged" (measured
# 2026-09-30). Run without the token; whatever it leaves changed is committed, whatever it commits
# itself stays; a failure restores the tree and says why.
after_input() { # $1 app name
  printf '  %-18s ' "$1"
  local err prog head_before
  local -a moved=()
  err=$(mktemp)
  head_before=$(git -C "$REPO" rev-parse HEAD)
  if ! prog=$(cd "$REPO" && app_program ".#apps.@system@.$1" 2>"$err") || ! ( cd "$REPO" && "$prog" ) >/dev/null 2>>"$err"; then
    mapfile -t moved < <(git -C "$REPO" diff --name-only)
    if [ "${#moved[@]}" -gt 0 ]; then git -C "$REPO" checkout -q -- "${moved[@]}"; fi
    echo "FAILED (after-inputs app $1) — restored ${moved[*]:-nothing}"
    sed 's/^/    /' "$err" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  mapfile -t moved < <(git -C "$REPO" diff --name-only)
  if [ "${#moved[@]}" -gt 0 ] && ! git -C "$REPO" commit -q -m "chore(relock): $1 after inputs" -- "${moved[@]}"; then
    git -C "$REPO" checkout -q -- "${moved[@]}"
    echo "FAILED to commit what $1 changed — restored"
    return 1
  fi
  if [ "$(git -C "$REPO" rev-parse HEAD)" = "$head_before" ]; then
    echo "already current"
  else
    committed=1
    after_done+=("$1")
    echo "COMMITTED — $1 moved something"
  fi
}

json_list() { if [ "$#" -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -R . | jq -sc .; fi; }

# The trace of a change, after it is pushed: one file per head (`<id>.json`) on this repository's
# `fabric/relock`, an orphan nothing pins — so writing it carries nothing anywhere, which is what
# separates it from the hop this tool used to make. Written by plumbing, so neither the checkout nor
# its branch moves.
write_trace() { # $1 the pushed revision
  local url tmp base attempt rc json blob tree commit
  url=$(git -C "$REPO" remote get-url origin) || return 1
  json=$(jq -n --arg h "@repoName@" --arg r "$1" --arg w "${RELOCK_PASS_WAVE:-@repoName@@$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
    --arg t "@toolId@" --argjson b "$bumped" --argjson d "$(json_list "${dropped[@]}")" --argjson a "$(json_list "${after_done[@]}")" \
    '{ schema: "seedmatic.relock/v1", head: $h, rev: $r,
       status: { wave: $w, tool: $t, bumped: $b, dropped: $d, after: $a } }')
  # A repository of its own: a shallow fetch into the operator's would make it SHALLOW, and in the
  # bare store that is the common dir of every worktree of the repo.
  tmp=$(mktemp -d)
  git init -q --bare "$tmp/trace.git" || { rm -rf "$tmp"; return 1; }
  for attempt in 1 2; do
    base=""
    # "Absent" is ls-remote's exit 2 (no such ref); anything else it cannot answer is an error, never
    # read as absent — a root commit pushed over an unseen branch is a rejected push at best.
    rc=0
    git ls-remote --exit-code "$url" refs/heads/fabric/relock >/dev/null 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then
      git -C "$tmp/trace.git" fetch -q --depth=1 "$url" "+refs/heads/fabric/relock:refs/base" || { rm -rf "$tmp"; return 1; }
      base=$(git -C "$tmp/trace.git" rev-parse refs/base) || { rm -rf "$tmp"; return 1; }
    elif [ "$rc" != 2 ]; then
      echo "  cannot tell whether fabric/relock exists on $url (ls-remote exited $rc)" >&2
      rm -rf "$tmp"
      return 1
    fi
    rm -f "$tmp/index"
    if [ -n "$base" ]; then GIT_INDEX_FILE="$tmp/index" git -C "$tmp/trace.git" read-tree "$base" || break; fi
    blob=$(printf '%s\n' "$json" | git -C "$tmp/trace.git" hash-object -w --stdin) || break
    GIT_INDEX_FILE="$tmp/index" git -C "$tmp/trace.git" update-index --add --cacheinfo "100644,$blob,@repoName@.json" || break
    tree=$(GIT_INDEX_FILE="$tmp/index" git -C "$tmp/trace.git" write-tree) || break
    if [ -n "$base" ]; then
      commit=$(git -C "$tmp/trace.git" commit-tree "$tree" -p "$base" -m "relock(@repoName@): trace of ${1:0:9}") || break
    else
      commit=$(git -C "$tmp/trace.git" commit-tree "$tree" -m "relock(@repoName@): trace of ${1:0:9}") || break
    fi
    # One retry: another head of this repository may have written its trace in between.
    if git -C "$tmp/trace.git" push -q "$url" "$commit:refs/heads/fabric/relock"; then
      rm -rf "$tmp"
      return 0
    fi
    [ "$attempt" = 1 ] && echo "  the trace's push was rejected — fetching fabric/relock again, once"
  done
  rm -rf "$tmp"
  return 1
}

if [ "${#targets[@]}" -eq 0 ]; then
  targets=(inputs after)
fi

echo "head: @repoName@ ($selfRepo:$selfBranch) at $REPO ($cur)"
echo "targets: ${targets[*]}"
echo

if ! read_shape; then
  echo "FAILED to read what this head exports — nothing reconciled" >&2
  exit 1
fi
if ! baseline=$(evalmap); then
  echo "FAILED to measure the starting point — nothing reconciled" >&2
  exit 1
fi
committed=0
for t in "${targets[@]}"; do
  case $t in
    inputs)
      echo "== inputs =="
      while read -r i; do relock_input "$i" || failed+=("input $i"); done < <(all_inputs)
      echo ;;
    after)
      if [ "${#afterInputs[@]}" -gt 0 ]; then
        # The deferred inputs first: what runs after the inputs runs after ALL of them.
        if [ "${#deferred[@]}" -gt 0 ]; then
          echo "== deferred inputs: retried once, after the others =="
          retrying=1
          for i in "${deferred[@]}"; do relock_input "$i" || failed+=("input $i"); done
          deferred=()
          echo
        fi
        echo "== after the inputs =="
        for app in "${afterInputs[@]}"; do after_input "$app" || failed+=("after $app"); done
        echo
      fi ;;
    *)
      if all_inputs | grep -qx -- "$t"; then
        echo "== input $t =="
        relock_input "$t" || failed+=("input $t")
        echo
      else
        echo "relock: unknown target '$t' (try --help)" >&2
        exit 2
      fi ;;
  esac
done

if [ "${#deferred[@]}" -gt 0 ]; then
  echo "== deferred inputs: retried once, after the others =="
  retrying=1
  for i in "${deferred[@]}"; do relock_input "$i" || failed+=("input $i"); done
  echo
fi

if [ "$nopush" = 1 ]; then
  ahead=$(git -C "$REPO" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")
  echo "== NOT pushed (--no-push) =="
  echo "  @repoName@ ($cur): $ahead commit(s) ahead of its upstream — review them with:"
  echo "    git -C '$REPO' log --stat '@{u}..HEAD'"
  echo
  echo "To resume where this stopped:"
  echo "  git -C '$REPO' push"
  echo "  (no trace is written for an unpushed change)"
  finish "DONE (not pushed)"
fi

# Pushed when this run committed — and only then: the start refused a head already ahead of its
# upstream, so what is pushed is exactly what this run made.
if [ "$committed" = 1 ]; then
  if ! git -C "$REPO" push; then
    echo "FAILED to push @repoName@ ($cur) — nothing it carried has landed" >&2
    failed+=("push @repoName@")
    finish "DONE"
  fi
  pushed_head=$(git -C "$REPO" rev-parse HEAD)
  echo "  @repoName@ @ ${pushed_head:0:9} pushed"
else
  pushed_head=$(git -C "$REPO" rev-parse HEAD)
  echo "  @repoName@ @ ${pushed_head:0:9}: nothing to push"
fi
if [ "$committed" = 1 ]; then
  if write_trace "$pushed_head"; then
    echo "  trace written on fabric/relock (@repoName@.json)"
  else
    echo "  FAILED to write the trace on fabric/relock — the change itself is pushed, and has landed"
    trace_failed+=("trace @repoName@ (its change landed)")
  fi
fi
echo
finish "DONE"
