# level and status of a version line, the same rule as lines.nix: numeric parts only (a leading v and a +/- suffix
# ignored); a non-numeric pin compares by equality; null latest is unknown.
def parts: if . == null then null
  else (ltrimstr("v") | split("-")[0] | split("+")[0] | split(".")) as $f
    | if ($f | length) > 0 and all($f[]; test("^[0-9]+$")) then $f | map(tonumber) else null end end;
def at($i): if $i < length then .[$i] else 0 end;
(.pinned | parts) as $p | (.latest | parts) as $l
| if .latest == null then .level = null | .status = "unknown"
  elif $p == null or $l == null then .level = null | .status = (if .pinned == .latest then "current" else "unknown" end)
  else
    ([($p | length), ($l | length)] | max) as $n
    | ([range(0; $n) as $j | select(($p | at($j)) != ($l | at($j))) | $j] | first) as $i
    | if $i == null then .level = null | .status = "current"
      else .level = (["major", "minor", "micro"][[$i, 2] | min])
        | .status = (if ($p | at($i)) < ($l | at($i)) then "behind" else "ahead" end)
      end
  end
