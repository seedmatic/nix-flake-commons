# nix/ KNOWLEDGE BASE

**Parent:** ../AGENTS.md

## OVERVIEW
All Nix logic: relock factory/tool, version reporting, guard checks, container module, caches, config measure.

## STRUCTURE
```
nix/
├── configurations.nix, upstream-caches.nix, lxc-container.nix, replace-vars-text.nix
├── relock.nix (factory), relock.sh (logic), relock.bats (tests), plan.jq
├── versions/          # version lines, report, schema (see nix/versions/AGENTS.md)
├── no-ifd-readfile.nix, no-nix-config.nix, no-installer-channel.nix
└── sweep-configurations.sh
```

## WHERE TO LOOK
| Task | Location |
|------|----------|
| relock app factory | relock.nix |
| relock logic | relock.sh |
| relock tests | relock.bats |
| pass plan (Kahn) | plan.jq |
| version lines | versions/lines.nix |
| version report | versions/report.sh, report.nix |
| version tests | versions/report.bats |
| IFD guard | no-ifd-readfile.nix |
| nixConfig guard | no-nix-config.nix |
| installer channel guard | no-installer-channel.nix |
| config measure | configurations.nix |

## CONVENTIONS
- Files are heavily commented; read header before editing.
- replaceVars tokens written without @ in comments to avoid substitution.
- Tests use bats with fake nix/curl.

## ANTI-PATTERNS
- Don't readFile derivation output (IFD).
- Don't add nixConfig.
- Don't carry installer channel.

## NOTES
- relock.sh 1393 LOC, relock.bats 1631 LOC: hotspots, edit carefully.
