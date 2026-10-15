{
  description =
    "Run Claude Code, Codex, or OpenCode in rootless Podman with one shared project directory";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      # macOS runs the containers in a Podman machine VM; the launcher itself is portable shell.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Read from VERSION= in the script, so there is one place to bump.
      version =
        builtins.head (builtins.match ''.*VERSION="([^"]+)".*'' (builtins.readFile ./agent-capsule));

      # What make and the test suites need, for the checks and for `nix develop`.
      testInputs =
        pkgs: with pkgs; [
          bash
          coreutils
          git
          gnumake
          nodejs
          perl
        ];
    in
    {
      packages = forAllSystems (pkgs: rec {
        agent-capsule = pkgs.stdenvNoCC.mkDerivation {
          pname = "agent-capsule";
          inherit version;
          src = self;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          dontBuild = true;

          # The script looks for its Dockerfile at ../share/agent-capsule/
          # relative to its own (symlink-resolved) location, so the standard
          # prefix layout works unchanged.
          installPhase = ''
            runHook preInstall
            install -Dm755 agent-capsule $out/bin/agent-capsule
            install -Dm644 Dockerfile $out/share/agent-capsule/Dockerfile
            install -Dm755 entrypoint.sh $out/share/agent-capsule/entrypoint.sh
            mkdir -p $out/share/agent-capsule/plugins
            cp -r plugins/worklog $out/share/agent-capsule/plugins/
            install -Dm644 completions/agent-capsule.bash \
              $out/share/bash-completion/completions/agent-capsule
            install -Dm644 completions/_agent-capsule \
              $out/share/zsh/site-functions/_agent-capsule
            runHook postInstall
          '';

          # podman is intentionally not pinned here: rootless Podman needs
          # host-level configuration (subuid/subgid, storage), so the host's
          # podman must be on PATH. Everything else is provided as a fallback.
          postFixup = ''
            wrapProgram $out/bin/agent-capsule \
              --suffix PATH : ${
                nixpkgs.lib.makeBinPath (
                  with pkgs;
                  [
                    coreutils
                    findutils
                    gawk
                    git
                    gnugrep
                  ]
                )
              }
          '';

          meta = {
            description = "Run a coding agent in a rootless Podman container sharing one project directory";
            homepage = "https://github.com/Niahh/agent-capsule";
            license = nixpkgs.lib.licenses.mit;
            platforms = systems;
            mainProgram = "agent-capsule";
          };
        };
        default = agent-capsule;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages =
            testInputs pkgs
            ++ (with pkgs; [
              shellcheck
              hadolint
            ]);
        };
      });

      # The lint and test targets, plus the package: `nix flake check` builds only what is listed here.
      checks = forAllSystems (pkgs: {
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.agent-capsule;
        shellcheck =
          pkgs.runCommand "shellcheck" { nativeBuildInputs = with pkgs; [ gnumake shellcheck ]; } ''
            make -C ${self} shellcheck
            touch $out
          '';
        hadolint = pkgs.runCommand "hadolint" { nativeBuildInputs = with pkgs; [ gnumake hadolint ]; } ''
          make -C ${self} hadolint
          touch $out
        '';
        launcher-tests = pkgs.runCommand "launcher-tests" { nativeBuildInputs = testInputs pkgs; } ''
          make -C ${self} test
          touch $out
        '';
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
