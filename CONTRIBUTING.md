# Contributing

## Before pushing

Lint both files; CI runs the same checks:

```sh
shellcheck agent-capsule
hadolint Dockerfile
```

## Commits and branches

- [Conventional Commits](https://www.conventionalcommits.org): `type(scope): subject`,
  imperative mood, lower-case, no trailing period.
- One logical change per commit, one topic per pull request.
- Branch naming: `<type>/<short-description>`, e.g. `fix/userns-flag`.

## Documentation

The script header is the single source of truth: `--help` prints it. Update it
together with any behavior change; keep the README short and in sync.
