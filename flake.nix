{
  description = "Run Claude Code, Codex, or opencode inside a rootless Podman container that shares one project directory with the host";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      # On macOS, Podman only runs containers through a Linux VM ("podman
      # machine"), which is where the rootless namespace/subuid handling
      # actually happens -- the script and its host-side dependencies here
      # are portable bash/coreutils, so it works there too.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Keep the package version in sync with VERSION= in the script.
      version =
        builtins.head (builtins.match ''.*VERSION="([^"]+)".*'' (builtins.readFile ./agent-capsule));
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
                    gawk
                    git
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
          packages = with pkgs; [
            shellcheck
            hadolint
          ];
        };
      });

      # Mirrors .github/workflows/lint.yml, plus a build of the package
      # itself (`nix flake check` only evaluates `packages`, it does not
      # build them unless they are also listed here).
      checks = forAllSystems (pkgs: {
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.agent-capsule;
        shellcheck =
          pkgs.runCommand "shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
            shellcheck ${self}/agent-capsule ${self}/tests/agent-capsule_test.sh \
              ${self}/entrypoint.sh ${self}/completions/agent-capsule.bash
            touch $out
          '';
        hadolint = pkgs.runCommand "hadolint" { nativeBuildInputs = [ pkgs.hadolint ]; } ''
          hadolint --config ${self}/.hadolint.yaml ${self}/Dockerfile
          touch $out
        '';
        launcher-tests =
          pkgs.runCommand "launcher-tests"
            { nativeBuildInputs = with pkgs; [ bash coreutils git perl ]; }
            ''
              bash ${self}/tests/agent-capsule_test.sh
              touch $out
            '';
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
