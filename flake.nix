{
  description = "nix system configurations";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      #      "https://kclejeune.cachix.org"
      "https://cache.flox.dev"
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      #      "kclejeuneachix.org-1:fOCrECygdFZKbMxHClhiTS6oowOkJ/I/dh9q9b1I4ko="
      "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs="
    ];
  };

  inputs = {
    flake-compat.url = "github:edolstra/flake-compat";
    flake-utils.url = "github:numtide/flake-utils";

    nix.url = "github:NixOS/nix/2.32.4";
    nixos-hardware.url = "github:nixos/nixos-hardware";
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0";
    nixpkgs-unstable.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";

    impermanence.url = "github:nix-community/impermanence";
      
    disko = {
      url = "github:nix-community/disko/v1.12.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  
    nix-snapshotter = {
      url = "github:pdtpartners/nix-snapshotter";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    chromium-bin = {
      url = "github:lrworth/chromium-bin-flake";
    };

    lix-module = {
      url = "https://git.lix.systems/lix-project/nixos-module/archive/2.93.0.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/0";

    darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flox = {
      url = "github:flox/flox?branch=main";
#     inputs.nixpkgs.follows = "nixpkgs";
    };

    nvfetcher.url = "github:berberman/nvfetcher";

    treefmt-nix.url = "github:numtide/treefmt-nix/main";

    extra-container = {
      flake = true;
      url = "github:erikarvstedt/extra-container";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    # nxmatic 

    bird = {
      flake = true;
      url = "github:nxmatic/bird?ref=hotfix/v2.15.1-nix-darwin";
    };

    maven-mvnd = {
      flake = true;
      url = "github:nxmatic/nix-maven-mvnd/develop";
    };

  };

  # The aggregator's first outputs: the shared `relock` tool, and this repo's own use of it.
  #
  # `lib.mkRelockApp` is here because this is the ROOT every seedmatic flake already consumes — a
  # tool the whole chain shares belongs where the whole chain already points. And this repo is a USER
  # of it, not only its host: it has third-party inputs of its own to bump, and relock measures an
  # aggregator's impact on the revisions it locks, since its inputs are what it exports.
  #
  # Who the heads are is not written here: it is nix-flake-commons' `fabric/heads`, an orphan that
  # holds only that list, read by every pass. A pass started here covers every head, since every head
  # pins this one.
  #
  # A pass runs ONE tool everywhere, and that tool is known by its CODE, not by this repo's revision:
  # a commit here that touches none of its files must not make every head read as running another
  # relock.
  outputs = { self, nixpkgs, flake-utils, home-manager, ... }:
    let
      relockToolId = builtins.hashString "sha256" (
        builtins.concatStringsSep "" (map builtins.readFile [
          ./nix/relock.sh
          ./nix/relock.nix
          ./nix/plan.jq
          ./nix/configurations.nix
        ])
      );
    in
    {
      lib.mkRelockApp = args: import ./nix/relock.nix (args // {
        toolId = relockToolId;
        toolSlug = "seedmatic/nix-flake-commons";
      });
      lib.relockToolId = relockToolId;
    }
    // flake-utils.lib.eachDefaultSystem (system: let pkgs = nixpkgs.legacyPackages.${system}; in {
      # Behaviour tests for relock, run by `nix flake check`. They cover what shellcheck — already a
      # gate of every build — cannot see: the failure paths, where every defect this script had was
      # a silence. The instances under test are built by the SAME factory; the heads they name live in
      # the test's fake fabric/heads.
      checks.relock =
        let
          relockOf = name: afterInputs: self.lib.mkRelockApp { inherit pkgs name afterInputs; };
        in
        pkgs.runCommand "relock-bats" {
          nativeBuildInputs = [ pkgs.bats pkgs.bash pkgs.coreutils pkgs.gnused pkgs.git pkgs.jq ];
          RELOCK = "${relockOf "t" [ ]}/bin/relock";
          RELOCK_AFTER = "${relockOf "t" [ "after-x" ]}/bin/relock";
          RELOCK_ORPHAN = "${relockOf "t-orphan" [ ]}/bin/relock";
          RELOCK_PEER = "${relockOf "peer" [ ]}/bin/relock";
          RELOCK_PEER2 = "${relockOf "peer2" [ ]}/bin/relock";
          RELOCK_TOOL_ID = self.lib.relockToolId;
          PLAN_JQ = ./nix/plan.jq;
        } ''
          export HOME=$TMPDIR
          bats --print-output-on-failure ${./nix/relock.bats}
          touch $out
        '';

      # Proves on a real flake that the guard's measure of the configurations does not move with the
      # revision alone: `nix run .#sweep-configurations -- <checkout>`.
      apps.sweep-configurations = {
        type = "app";
        program = "${
          pkgs.writeShellApplication {
            name = "sweep-configurations";
            runtimeInputs = [ pkgs.coreutils pkgs.gitMinimal pkgs.jq pkgs.nix ];
            text = builtins.readFile (
              pkgs.replaceVars ./nix/sweep-configurations.sh {
                configurationsNix = "${./nix/configurations.nix}";
              }
            );
          }
        }/bin/sweep-configurations";
        meta.description = "Prove that relock's neutralised measure of a flake's configurations does not move with the revision alone";
      };

      apps.relock = {
        type = "app";
        program = "${self.lib.mkRelockApp { inherit pkgs; name = "flake-commons"; }}/bin/relock";
        meta.description = "Reconcile THIS head's locks: bump each input, DROP any bump that moves nothing it exports, push. --plan shows a pass, --downstream plays it over every head of fabric/heads";
      };
    });

}
