# PROJECT KNOWLEDGE BASE

**Generated:** 2026-11-08
**Commit:** b760352
**Branch:** develop

## OVERVIEW
Shared Nix flake ("nix-flake-commons") consumed by every seedmatic flake. Exports the relock propagation tool, version reporting, and guard checks (no nixConfig, no installer channel, no IFD readFile). Also hosts a registry of Flox environments (.flox-envs.d).

## STRUCTURE
```
./
├── flake.nix            # flake entry: inputs + outputs (lib, checks, apps, nixosModules)
├── flake.lock
├── nix/                 # all Nix logic (relock, versions, checks, helpers)
├── .githooks/           # pre-commit secret/token/sops guards
├── .flox/               # this repo's own Flox env
└── .flox-envs.d/        # registry of Flox env definitions (one per tool)
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| relock tool | nix/relock.sh, nix/relock.nix | factory in relock.nix; logic in relock.sh (1393 LOC) |
| version reporting | nix/versions/ | lines.nix, report.sh/nix, schema.json |
| guard checks | nix/no-*.nix | no-ifd-readfile, no-nix-config, no-installer-channel |
| LXC container module | nix/lxc-container.nix | disables installer channel/cloneConfig |
| upstream caches | nix/upstream-caches.nix | cache data |
| configurations measure | nix/configurations.nix | neutralises configurationRevision |
| tests | nix/relock.bats, nix/versions/report.bats | bats |
| pre-commit | .githooks/pre-commit | secret material, token shape, sops filter |

## CODE MAP
| Symbol | Type | Location | Refs | Role |
|--------|------|----------|------|------|
| mkRelockApp | factory | nix/relock.nix | many | builds relock app per head |
| relockToolId | string | flake.nix | - | hash of relock code files |
| upstreamCaches | attrset | nix/upstream-caches.nix | - | shared binary caches |
| noNixConfig | function | nix/no-nix-config.nix | - | check: no nixConfig in flake.nix |
| noInstallerChannel | function | nix/no-installer-channel.nix | - | check: no installer channel |
| versionLines | function | nix/versions/lines.nix | - | produces version lines |
| versionSchema | path | nix/versions/schema.json | - | JSON schema for a version line |
| lxc-container | module | nix/lxc-container.nix | - | LXC container profile |
| configurations | function | nix/configurations.nix | - | measures configs |

## CONVENTIONS
- Formatting: nixfmt (treefmt-nix input). Shellcheck gates every .sh build. jq for JSON.
- Heavy doc comments: every nix file has a leading comment explaining purpose; "★" markers for key points.
- Build-time tokens: replaceVars-style @token@ substitution via replace-vars-text.nix (never readFile of derivations — that's IFD).
- Branch: develop. Commits: conventional-ish (feat:, chore:, etc.).
- Pre-commit: secret material guard, token shape guard, sops filter attribute guard.

## ANTI-PATTERNS (THIS PROJECT)
- No `nixConfig` in any flake.nix (no machine takes it).
- No `builtins.readFile` of a derivation (import-from-derivation) — use replace-vars-text.nix.
- No installer channel in NixOS configs (copies 324 MiB nixpkgs).
- No private key / bearer token in clear in staged blobs.
- No sops filter attribute in flake repos.

## UNIQUE STYLES
- Single implementation shared by all heads (relock lives once here).
- configurations measure neutralises `system.configurationRevision` to avoid moving on every commit.
- relock impact guard drops bumps that move no exported derivation.

## COMMANDS
```bash
nix flake check                    # all checks
nix run .#versions-report -- <lines.jsonl>...
nix run .#sweep-configurations -- <checkout>
nix run .#relock                   # relock this head
```

## NOTES
- .flox-envs.d/ holds one Flox env per tool; not core logic.
- relock.sh is 1393 lines, relock.bats 1631 lines — hotspots.
- No README.md; knowledge lives in code comments.
