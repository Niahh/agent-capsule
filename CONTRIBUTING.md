# Contributing

## Before pushing

Run the behavior tests and linters. CI runs the same checks:

```sh
make test
shellcheck agent-capsule tests/agent-capsule_test.sh tests/worklog_test.sh entrypoint.sh \
  completions/agent-capsule.bash
hadolint Dockerfile
```

## Commits and branches

- [Conventional Commits](https://www.conventionalcommits.org): `type(scope): subject`,
  imperative mood, lower-case, no trailing period.
- One logical change per commit, one topic per pull request.
- Branch naming: `<type>/<short-description>`, e.g. `fix/userns-flag`.

## Documentation

Keep the short `--help` summary aligned with the option parser. Document detailed
behavior in the README and update it with every user-visible change.
