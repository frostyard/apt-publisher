# 0006 — State the reason for the incus signer ref

- **Status:** Accepted; amends [ADR-0004](0004-pin-the-signer-workflow-of-attested-producers.md) in part
- **Date:** 2026-11-13

## Context

ADR-0004 registers `frostyard/incus` as `builds-docker.yml@refs/heads/stable`.
Its **Registered** paragraph gives no reason for that ref: the parenthesis
after it records process, which core
[ADR-0051](https://github.com/frostyard/core/blob/main/docs/adr/0051-adrs-state-facts-not-process.md)
keeps out of an ADR.

## Decision

`frostyard/incus` stays registered as `builds-docker.yml@refs/heads/stable`.
Reason: `frostyard/incus` builds its packages and attests them in
`.github/workflows/builds-docker.yml`, whose `release` job runs only on
`refs/heads/stable`, the default branch. So every attestation of a published incus `.deb` names that workflow
and `refs/heads/stable`.

This replaces the parenthesis after the incus entry in ADR-0004's **Registered**
paragraph. Everything else in ADR-0004 stands.

## Consequences

- A release of incus that another branch or workflow attested is refused:
  `gh attestation verify` fails for its `.deb` files, before any state
  changes, as for every branch producer of ADR-0004.
- A move of incus's release build to another branch or workflow needs a
  `config/producers.tsv` change first.

## Alternatives considered

- **Edit ADR-0004.** Rejected: an Accepted ADR permits only link maintenance
  (core ADR-0033).
- **Leave ADR-0004 as written.** Rejected: the registration then has no
  recorded reason.

## References

- Amends in part: [ADR-0004](0004-pin-the-signer-workflow-of-attested-producers.md)
- Shapes: [config/producers.tsv](../../config/producers.tsv)
