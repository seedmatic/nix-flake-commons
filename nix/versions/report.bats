#!/usr/bin/env bats
# versions-report merges every world's lines into one report: validated against the schema, sorted (behind first,
# majors first among them), and the same comparison as lib.versionLines for a line it completes. No network: the
# GitHub API is a local directory the app's curl reads through file://.

setup() {
	# The GitHub API as local files: the app's own curl reads them through file://, no network, no stub on PATH
	# (the app's PATH comes first). No token: there is no `gh` login in the sandbox.
	api="$BATS_TEST_TMPDIR/api"
	mkdir -p "$api/repos/rancher/rke2/releases"
	printf '%s' '{"tag_name":"v1.36.5+rke2r1"}' >"$api/repos/rancher/rke2/releases/latest"
	export VERSIONS_GITHUB_API="file://$api"
	nix="$BATS_TEST_TMPDIR/nix.jsonl"
	clusters="$BATS_TEST_TMPDIR/clusters.jsonl"
	cat >"$nix" <<'EOF'
{"world":"nix","name":"kubectl","source":"rke2lab:flake.lock#nixpkgs","pinned":"1.36.3","latest":"1.37.1","level":"minor","status":"behind","upstream":"nixpkgs:nixpkgs-unstable#kubectl"}
{"world":"nix","name":"rke2","source":"rke2lab:nixos/rke2-1-36.nix","pinned":"1.36.4+rke2r1","latest":null,"level":null,"status":"unknown","upstream":"github:rancher/rke2"}
{"world":"nix","name":"go","source":"rke2lab:flake.lock#nixpkgs","pinned":"1.26.8","latest":"1.26.8","level":null,"status":"current","upstream":"nixpkgs:nixpkgs-unstable#go"}
EOF
	cat >"$clusters" <<'EOF'
{"world":"clusters","name":"capiCore","source":"rke2lab:Component.java","pinned":"v1.14.0","latest":"v2.0.1","level":"major","status":"behind","upstream":"github:kubernetes-sigs/cluster-api"}
{"world":"clusters","name":"vclusterChart","source":"rke2lab:Component.java","pinned":"0.37.4","latest":null,"level":null,"status":"unknown","upstream":"none"}
EOF
}

@test "one report: every world, sorted behind first and majors first" {
	run versions-report --format=jsonl "$nix" "$clusters"
	[ "$status" -eq 0 ]
	names=$(jq -r .name <<<"$output" | tr '\n' ' ')
	[ "$names" = "capiCore kubectl rke2 vclusterChart go " ]
}

@test "a GitHub upstream's latest is completed at run time, and compared" {
	run versions-report --format=jsonl "$nix"
	[ "$status" -eq 0 ]
	rke2=$(jq -c 'select(.name == "rke2")' <<<"$output")
	[ "$(jq -r .latest <<<"$rke2")" = "v1.36.5+rke2r1" ]
	[ "$(jq -r .level <<<"$rke2")" = "micro" ]
	[ "$(jq -r .status <<<"$rke2")" = "behind" ]
}

@test "the table flags a major behind" {
	run versions-report "$nix" "$clusters"
	[ "$status" -eq 0 ]
	[[ "$output" == *"⚠"*"capiCore"* ]]
	[[ "$output" == *"of them a major (⚠)"* ]]
	# The flag is the character, never an escaped byte sequence (util-linux's column did that on Linux).
	[[ "$output" != *'\x'* ]]
}

@test "the table's columns are aligned" {
	run versions-report "$nix" "$clusters"
	[ "$status" -eq 0 ]
	# Every unflagged row's NAME starts at the header's NAME column. Unflagged rows only: they are ASCII, and bash
	# counts a ⚠ as three bytes when the sandbox has no UTF-8 locale. The flagged row is checked by its width in jq.
	header=$(head -1 <<<"$output")
	col=${header%%NAME*}
	rows=0
	while IFS= read -r row; do
		[ -n "$row" ] || break
		[[ $row == "⚠"* ]] && continue
		[ "${row:${#col}:1}" != " " ]
		[ "${row:$((${#col} - 1)):1}" = " " ]
		rows=$((rows + 1))
	done < <(sed -n '2,6p' <<<"$output")
	[ "$rows" -eq 4 ]
}

@test "a line that breaks the contract is refused" {
	printf '%s\n' '{"world":"nix","name":"x","source":"bad","pinned":"1","latest":"1","level":null,"status":"current","upstream":"none"}' >"$BATS_TEST_TMPDIR/bad.jsonl"
	run versions-report --format=jsonl "$BATS_TEST_TMPDIR/bad.jsonl"
	[ "$status" -ne 0 ]
	[[ "$output" == *"breaks the contract"* ]]
}
