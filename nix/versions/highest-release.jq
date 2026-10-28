# The highest release of a GitHub /releases list whose tag IS a version: `v?X.Y(.Z)` with an optional `+…` build
# suffix (rke2's `+rke2r1`), not a draft, not a prerelease. Prints the tag verbatim, or nothing.
def key: ltrimstr("v") | split("+")[0] | split(".") | map(tonumber);
[ .[]
  | select((.draft | not) and (.prerelease | not))
  | .tag_name
  | select(test("^v?[0-9]+\\.[0-9]+(\\.[0-9]+)?(\\+[0-9A-Za-z.]+)?$")) ]
| if length == 0 then empty else (max_by(key)) end
