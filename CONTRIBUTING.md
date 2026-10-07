# Contributing

## Before pushing

Run the behavior tests and linters. CI runs the same checks, plus image builds:

```sh
make test
shellcheck agent-capsule entrypoint.sh scripts/check-shell-completion \
  tests/agent-capsule_test.sh tests/worklog_test.sh tests/install_test.sh \
  completions/agent-capsule.bash
hadolint Dockerfile
```

The tests need bash 4.4 or later, git, node and perl. `nix develop` provides them
with shellcheck and hadolint, and `nix flake check` runs every check above.

## Commits and branches

- [Conventional Commits](https://www.conventionalcommits.org): `type(scope): subject`,
  imperative mood, lower-case, no trailing period.
- One logical change per commit, one topic per pull request.
- Branch naming: `<type>/<short-description>`, e.g. `fix/userns-flag`.

## Documentation

Keep the short `--help` summary aligned with the option parser. Document detailed
behavior in the README and update it with every user-visible change.
