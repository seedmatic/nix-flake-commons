# nix/versions/ KNOWLEDGE BASE

**Parent:** ../AGENTS.md

## OVERVIEW
Version reporting subsystem: pure version-line comparison (lines.nix), JSON schema, report merger (report.sh/nix), tests.

## STRUCTURE
```
versions/
├── lines.nix          # lib.versionLines: produces version lines
├── check.nix          # tests for lines.nix against schema
├── schema.json        # JSON schema for a version line
├── compare.jq         # jq comparison (mirrors lines.nix)
├── highest-release.jq # picks highest stable release
├── report.nix         # versions-report app factory
├── report.sh          # report merger logic
└── report.bats        # report tests
```

## WHERE TO LOOK
| Task | Location |
|------|----------|
| version comparison logic | lines.nix, compare.jq |
| schema contract | schema.json |
| report app | report.nix, report.sh |
| tests | check.nix, report.bats |

## CONVENTIONS
- Eight fields per line: world, name, source, pinned, latest, level, status, upstream.
- latest completed at runtime from GitHub API for github: upstreams.
- Schema rejects extra fields (additionalProperties false).

## ANTI-PATTERNS
- Don't add fields without updating schema.
- Don't network in pure evaluation (latest stays null in lines.nix).

## NOTES
- Worlds: "nix" and "clusters".
