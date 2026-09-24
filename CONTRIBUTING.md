# Contributing

## Running the test matrix locally

```bash
nix flake check
```

This runs `nix fmt`/`statix`/`deadnix`/`shellcheck` (via
`checks.pre-commit-check`) plus the three checks under `tests/`:

- `happy-path` and `bad-manifest` are full `pkgs.testers.runNixOSTest`
  VM integration tests — expect the first run to take a few minutes
  while it builds a VM image.
- `podman-nesting` is a pure eval-level structural check (no VM — a
  real podman image pull needs network access NixOS VM tests don't
  have by default).

Run a single check directly for faster iteration:

```bash
nix build .#checks.x86_64-linux.happy-path -L
```

## Module option conventions

Every option lives under `my.*`, defaulting to `enable = false` where
applicable — the same "Switchboard" convention `lib.mkContainer` and
`nixosModules.host`/`.updater` already follow. Keep new options
consistent with that shape.

## Scope

This flake extracts a specific mechanism (build once in CI, host pulls
an already-cache-verified artifact and swaps it in). Changes that add
fleet-specific assumptions back in — hardcoded IPs, hardcoded release
URLs, a hardcoded catalogue of containers — belong in your own
consuming flake, not here. See `lib/factory.nix`'s and
`modules/host.nix`'s header comments for the option paths this flake
deliberately does *not* declare itself.

## PRs

- Keep the test matrix green (`nix flake check`).
- A behavior change to `lib.mkContainer`'s function signature or the
  `my.container-host`/`my.services.container-updater` option shapes is
  a breaking change — call it out in the PR description.
