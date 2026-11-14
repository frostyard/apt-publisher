# 0005 — Check publications with an apt download canary

- **Status:** Accepted; amends [ADR-0001](0001-aptly-single-writer.md) in part
- **Date:** 2026-11-13

## Context

ADR-0001's "Read-back" item says "An apt canary then installs the new packages
through the public URL." [scripts/apt-canary.sh](../../scripts/apt-canary.sh)
has never installed a package: since the first commit it runs `apt-get update`
and `apt-get download` for each new package, in a sandboxed apt with no root
and no system state. The publish workflow runs
[scripts/notify.sh](../../scripts/notify.sh) only after the canary passes.

## Decision

The canary after a publication is a download check. For each new package, a
sandboxed apt pointed at the public URL runs `apt-get update` and
`apt-get download`. apt checks the `InRelease` signature, the index hashes, and
the package's size and hash, through the CDN.

This amends the statement of ADR-0001 "An apt canary then installs the new
packages through the public URL". Everything else in ADR-0001 stands.

## Consequences

- A passed publication proves that apt on a host can fetch and verify each new
  package through the public URL.
- It does not prove that the package installs: dependency resolution,
  conflicts and maintainer scripts are not checked.
- The canary needs no root and no container.

## Alternatives considered

- **Install the packages in a throwaway container.** Not part of this decision.
  It would also check dependency resolution and maintainer scripts, and it
  needs a root container in each publish run. A later ADR can add it
  ([#48](https://github.com/frostyard/apt-publisher/issues/48)).

## References

- Amends in part: [ADR-0001](0001-aptly-single-writer.md)
- Amended in part by: [ADR-0007](0007-install-new-packages-in-a-throwaway-container.md)
- Shapes: [scripts/apt-canary.sh](../../scripts/apt-canary.sh),
  [design/overview.md](../design/overview.md),
  [runbooks/operations.md](../runbooks/operations.md)
