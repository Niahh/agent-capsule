# macOS

Podman on macOS runs containers inside a Linux VM, so every host path
agent-capsule bind-mounts has to actually be visible inside that VM. A plain
init covers the common case, since `podman machine init` already mounts
`$HOME:$HOME` by default, which is where agent-capsule keeps everything
(project checkouts, `~/.agent-capsule/`, credentials):

```sh
podman machine init
podman machine start
```

`--with github`, `--with gitlab` and `--ca` also mount a directory under `$TMPDIR`,
which macOS keeps in `/var/folders`, outside `$HOME`.

If `agent-capsule` was installed via Nix (nix-darwin, `nix profile install`,
`nix build`, etc.), also mount `/nix/store`. The closures of any Nix-built
tools bind-mounted into the container with `--mount` need to be visible to the
VM. Passing any `--volume` at all replaces Podman's implicit
default instead of adding to it, so `$HOME:$HOME` and `/var/folders` must be listed
explicitly too. `--volume` also can't be added to an already-created machine, so get
them all in from the start:

```sh
podman machine init --volume $HOME:$HOME --volume /var/folders:/var/folders \
  --volume /nix/store:/nix/store:ro
podman machine start
```

Leaving out `$HOME:$HOME` breaks the launch, since agent-capsule bind-mounts
`PROJECT_DIR` itself (plus `~/.agent-capsule/` and the auth home) under
`$HOME`: `Error: statfs /Users/.../your-project: no such file or directory`.

