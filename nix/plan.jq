# The plan of a relock pass, from facts only: the heads of fabric/heads, and the lock of each code
# head. Input: { start, heads: { <id>: { repo, branch, kind } }, locks: { <code id>: <flake.lock> },
# tips?: { <id>: <rev> } }. Output: { start, heads, edges, order, levels, errors, pinned, gaps? }. Nothing is
# declared: an edge is a pin of a lock.
#
# An edge `from -> to` says `from` pins `to`, so `to` runs first. A root input that is a list is a
# `follows`, not an edge. An indirect id must be a head, and must resolve to that head's repository; a
# direct `github:` input of a head's repository must name a head's branch. Anything else is a third
# party. A data head has no lock: it is a leaf, never run.

def edges_of($H; $locks):
  [ $locks | to_entries[] | .key as $from | .value as $l
    | ($l.nodes[$l.root].inputs // {}) | to_entries[]
    | select(.value | type == "string")
    | { from: $from, input: .key, node: $l.nodes[.value] } ]
  | map(
      . as $e | ($e.node.original // {}) as $o | ($e.node.locked // {}) as $k
      | if $o.type == "indirect" then
          if $H[$o.id] == null then
            { error: "\($e.from): input `\($e.input)` pins the id `\($o.id)`, which is not a head of fabric/heads" }
          elif $k.type == "github" and ("\($k.owner)/\($k.repo)" != $H[$o.id].repo) then
            { error: "\($e.from): input `\($e.input)` resolves the id `\($o.id)` to \($k.owner)/\($k.repo), but fabric/heads has it on \($H[$o.id].repo)" }
          else { edge: { from: $e.from, to: $o.id, input: $e.input } } end
        elif $o.type == "github" and ([$H[] | .repo] | index("\($o.owner)/\($o.repo)")) != null then
          ($o.ref // "develop") as $ref
          | [ $H | to_entries[] | select(.value.repo == "\($o.owner)/\($o.repo)" and .value.branch == $ref) | .key ] as $m
          | if ($m | length) == 1 then { edge: { from: $e.from, to: $m[0], input: $e.input } }
            else { error: "\($e.from): input `\($e.input)` pins \($o.owner)/\($o.repo) at `\($ref)` directly, which is no head of fabric/heads" } end
        else empty end)
  | map(if .edge != null and .edge.from == .edge.to
        then { error: "\(.edge.from): input `\(.edge.input)` pins its own id — a cycle of one" } else . end);

# The head a lock node resolves to, by the edges' own mapping — at ANY depth of the lock, so that the
# copy of flake-commons ndh pins, inside rke2lab's lock, counts like rke2lab's own pin.
def head_of($H; $node):
  ($node.original // {}) as $o
  | if $o.type == "indirect" and $H[$o.id] != null then $o.id
    elif $o.type == "github" then
      [ $H | to_entries[] | select(.value.repo == "\($o.owner)/\($o.repo)" and .value.branch == ($o.ref // "develop")) | .key ]
      | if length == 1 then .[0] else null end
    else null end;

# Every locked node of every lock that resolves to a head: { from, node, head, rev }.
def head_pins($H; $locks):
  [ $locks | to_entries[] | .key as $from | .value as $l
    | $l.nodes | to_entries[]
    | select(.key != $l.root and .value.locked != null)
    | { from: $from, node: .key, head: head_of($H; .value), rev: .value.locked.rev }
    | select(.head != null) ];

# Kahn's order, deterministic: at each step every head whose pins have all run, sorted. The heads of
# one step pin none of each other: they are a LEVEL, which a pass may run at once.
def topo($nodes; $E):
  { done: [], steps: [], left: $nodes, stuck: false }
  | until((.left | length) == 0 or .stuck;
      . as $s
      | [ $s.left[] as $n
          | select([ $E[] | select(.from == $n) | .to ] | all(. as $d | $s.done | index($d) != null))
          | $n ] as $ready
      | if ($ready | length) == 0 then .stuck = true
        else .done += ($ready | sort) | .steps += [ $ready | sort ] | .left -= $ready end);

# What is left when Kahn's order sticks is the cycles plus the heads downstream of them. A head that no
# head left pins cannot be on a cycle: drop it, again and again, and only the cycles remain.
def cycles_in($left; $E):
  [ $left[] as $n | select([ $E[] | select(.to == $n and (.from as $f | $left | index($f)) != null) ] | length > 0) | $n ] as $kept
  | if ($kept | length) == ($left | length) then $left else cycles_in($kept; $E) end;

# The heads a pass started from `start` reaches: every head of the start's repository (its orphan
# projects and its fabric/ facets move with it), and whatever pins any of them, transitively.
def reach($E; $set):
  ($set + [ $E[] | select(.to as $t | $set | index($t) != null) | .from ] | unique) as $n
  | if ($n | length) == ($set | length) then $set else reach($E; $n) end;

. as $in
| $in.heads as $H
| edges_of($H; $in.locks) as $res
| ([ $res[] | .edge // empty ] | unique_by([.from, .to])) as $E
| [ $res[] | .error // empty ] as $idErrors
| topo($H | keys; $E) as $t
| (if $t.stuck then
     cycles_in($t.left; $E) as $c
     | [ "a cycle among " + ($c | sort | join(", ")) + ": "
       + ([ $E[] | select(.from as $f | .to as $to | ($c | index($f)) != null and ($c | index($to)) != null)
            | "\(.from) pins \(.to) (input `\(.input)`)" ] | join("; "))
       + " — move the datum one of them reads onto a fabric/ orphan" ]
   else [] end) as $cycleErrors
| (if $H[$in.start] == null then [ "the start `\($in.start)` is not a head of fabric/heads" ] else [] end) as $startErrors
| (if $H[$in.start] == null then [] else
     reach($E; [ $H | to_entries[] | select(.value.repo == $H[$in.start].repo) | .key ]) end) as $scope
| {
    start: $in.start,
    heads: $H,
    edges: $E,
    order: [ $t.done[] | select(. as $n | ($scope | index($n)) != null and $H[$n].kind == "code") ],
    levels: [ $t.steps[] | map(select(. as $n | ($scope | index($n)) != null and $H[$n].kind == "code")) | select(length > 0) ],
    errors: ($startErrors + $idErrors + $cycleErrors),
    pinned: ([ head_pins($H; $in.locks)[] | .head ] | unique)
  }
# ALIGNED means every node that resolves to a head, transitive ones included, is locked at that head's
# tip. Each gap is named; a head whose tip is not given cannot be judged, and is a gap too.
| if $in.tips == null then . else
    . + { gaps: [ head_pins($H; $in.locks)[] | select(.rev != $in.tips[.head])
      | if $in.tips[.head] == null then "\(.from): node `\(.node)` pins \(.head), whose tip is unknown"
        else "\(.from): node `\(.node)` pins \(.head) at \((.rev // "none")[0:9]), \(.head) is at \($in.tips[.head][0:9])" end ] }
  end
