# 0007 — Install new packages in a throwaway container

- **Status:** Accepted; amends [ADR-0005](0005-check-publications-with-an-apt-download-canary.md) in part
- **Date:** 2026-11-13

## Context

[ADR-0005](0005-check-publications-with-an-apt-download-canary.md) makes the
canary after a publication a download check: a sandboxed apt runs
`apt-get update` and `apt-get download` for each new package through the
public URL. It does not check dependency resolution, conflicts or maintainer
scripts. A package can pass the canary and still fail on every host that
installs it, and `scripts/notify.sh` then starts downstream image builds
that install it.

The publish job runs on an `ubuntu-24.04` runner (amd64) with a 30-minute
limit. The publish and move workflows both run
`scripts/apt-canary.sh --report FILE` after the CDN purge; the publish
workflow runs `scripts/notify.sh` only after it passes. Rollback, withdraw
and import-stable do not run the canary.

On 2026-11-13, each newest amd64 package that the repository published in
`trixie` and `forky` was installed with `apt-get install
--no-install-recommends`, one package in each fresh `debian:<codename>`
container, with `keys/frostyard.gpg` and the public URL as the only Frostyard
source (`main` for a `main` package, `main` and `image` for an `image`
package). All 33 packages of registered producers installed, the `image`
packages included (`bootc`, `libostree-1-1`, the 5 `incus` packages). The
longest took 48 s, `apt-get update` included. 2 imported packages that no
producer registers, `kapsule` 0.1.1 and `kapsule-gnome` 0.1.3 in `trixie`,
failed: their `postinst` runs `systemctl daemon-reload`, which fails when
systemd is not PID 1. No arm64 package was installed: the runner has no arm64
emulation.

## Decision

After the download check passes for every row of the report, the canary
installs the new packages. `scripts/apt-canary.sh` calls
[scripts/install-canary.sh](../../scripts/install-canary.sh), and a failed
install fails `apt-canary.sh`, so the publish run stops before
`scripts/notify.sh`.

- **Scope.** Each `amd64` and `all` row is installed. For each codename and
  component, one container installs all of that target's rows in one
  `apt-get install --no-install-recommends NAME=VERSION...`. Rows of another
  architecture (`arm64`) get the download check only, and the canary logs
  that it did not install them.
- **Environment.** The container is `debian:<codename>` from Docker Hub,
  with its own Debian sources, `keys/frostyard.gpg` (mode 0644), and
  `APT_PUBLIC_URL` as the only Frostyard source. A `main` target enables
  `main`; an `image` target enables `main` and `image`. `apt-get update`
  runs with `--error-on=any`. A `policy-rc.d` that exits 101 stops every
  service start, and systemd is not PID 1.
- **Pass.** `apt-get install` succeeds, and `dpkg-query` shows each package
  installed (`ii`) at the reported version. There is no exception list:
  every package of a report must install. A `postinst` that needs a running
  systemd or service fails the check.
- **Isolation.** The container gets 4 environment values: the keyring
  (base64), the public URL, the codename and the components. It gets no
  mount, no other environment value and no extra privilege, so no secret of
  the job reaches it. podman forwards the host's proxy variables by default,
  so the canary passes `--http-proxy=false` to podman. Docker adds proxy
  values only from the client's own `config.json`, which the runner does not
  set.
- **Time.** The install check has its own hard limit,
  `APT_CANARY_INSTALL_BUDGET` (420 s), for the image pulls and the container
  runs together, apart from the download budget. A container that outlasts
  it is removed by name, under its own limit (`APT_CANARY_CLEANUP`, 30 s,
  plus a 5 s kill grace), and the canary fails with its log and the result
  of the removal. A failed image pull is
  retried with the canary's tries and delay, inside that limit.
- **Runtime.** `APT_CANARY_RUNTIME` names the container runtime; the default
  is `docker`, else `podman`. Without one, the canary fails. No setting turns
  the install check off.
- **Move.** The move workflow runs the same script, so a move and a recheck
  install the reported packages too: an `image` row installs with `main` and
  `image`. Rollback, withdraw and import-stable stay without a canary.

This amends these statements of ADR-0005:

- "The canary after a publication is a download check." The canary is a
  download check, then an install check for `amd64` and `all` packages.
- "It does not prove that the package installs: dependency resolution,
  conflicts and maintainer scripts are not checked." For `amd64` and `all`
  packages, the canary now checks them.
- "The canary needs no root and no container." The install check needs a
  container runtime and runs as root inside the container.

The download check of ADR-0005 and its retry policy stay as they are.

## Consequences

- A passed publication proves that each new `amd64` and `all` package
  installs, with its dependencies and maintainer scripts, in a minimal
  `debian:<codename>` system with the Frostyard component that it needs.
- It does not prove that services start (no systemd, no service start),
  that a package works, or that an `arm64` package installs.
- The publish job also depends on Docker Hub and on the Debian mirrors. An
  outage there now fails a publish run after the switch: the publication
  stays live, and `scripts/notify.sh` does not run, as after a failed
  download check.
- The canary takes more time: about 10 to 50 s for each codename and
  component on 2026-11-13, at most 420 s. The download check's worst case
  (600 s budget, 120 s warm-up, 10 s kill grace) and the install check's
  (30 s for `RUNTIME --version` plus a 5 s kill grace, 420 s budget, 10 s
  kill grace, 30 s cleanup, 5 s kill grace) come to 1230 s; they leave the
  other steps about 9 minutes of the 30-minute job.
- A package whose `postinst` fails without systemd, as `kapsule` does today,
  cannot pass a publish run until its producer fixes it.
- A recheck of a move installs every newest `image` package of a codename in
  one container, which is slower than a publication.

## Alternatives considered

- **Install each package in its own container.** It names the failing
  package, but it multiplies the pulls and `apt-get update` runs. One
  container per target installs the release as a host would.
- **Simulate only (`apt-get -s install`).** It needs no container, but it
  does not run maintainer scripts.
- **Boot systemd in the container.** It would check service starts, but it
  needs a privileged container and makes the check slower and less stable.
- **Install arm64 packages under QEMU.** It needs a workflow step for
  binfmt, and the workflows stay unchanged in this decision.

## References

- Amends in part: [ADR-0005](0005-check-publications-with-an-apt-download-canary.md)
- Builds on: [ADR-0002](0002-two-components-per-codename.md) (the `image`
  component, core ADR-0059)
- Shapes: [scripts/install-canary.sh](../../scripts/install-canary.sh),
  [scripts/apt-canary.sh](../../scripts/apt-canary.sh),
  [design/overview.md](../design/overview.md),
  [runbooks/operations.md](../runbooks/operations.md)
- Issue: [#48](https://github.com/frostyard/apt-publisher/issues/48)
