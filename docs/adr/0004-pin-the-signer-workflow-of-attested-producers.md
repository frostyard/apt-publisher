# 0004 — Pin the signer workflow of attested producers

- **Status:** Accepted
- **Date:** 2026-11-03

## Context

`fetch-release.sh` verified an attested producer's `.deb` files with
`gh attestation verify --source-ref refs/tags/<tag> --deny-self-hosted-runners`.
That argument names the ref the attesting workflow ran on. It does not name
the workflow: an attestation from any workflow in the producer's repository,
at that ref, satisfied the check.

updex, firn, intuneme and chairlift attest from `release.yml`, which runs on
any tag (`tags: ["*"]`). bootc-debian and omarchy-apps attest from
`build.yml` on `refs/heads/main`, a ref the old check could never accept, so
they were registered `attested=no` and their provenance was not checked at
all. Core Plan 0009, "Later / ideas", names the missing check: which workflow
signed.

## Decision

**Configuration.** `config/producers.tsv` column 4, `attested`, is `no`, or a
policy `WORKFLOW@REF`: WORKFLOW is a workflow file name in the producer's
`.github/workflows/`, and REF is `refs/tags/PATTERN` or `refs/heads/BRANCH`.
`yes` is no longer a value. The full expression, the same in bash and in awk:

```
^(no|[A-Za-z0-9_.-]+\.ya?ml@refs/(tags/[A-Za-z0-9_.*?-]+|heads/[A-Za-z0-9_./-]+))$
```

**The checks.** For a policy, `fetch-release.sh` passes, for every `.deb`,
`--signer-workflow PRODUCER/.github/workflows/WORKFLOW` and
`--source-ref REF`, and keeps `--deny-self-hosted-runners`.

- `refs/tags/PATTERN`: PATTERN is a shell glob, and the release tag must
  match it before the download. The source ref is `refs/tags/<the release
  tag>`. A tag outside the pattern, such as intuneme's unattested `dev`
  prerelease, is refused before the download.
- `refs/heads/BRANCH`: an exact branch name, no glob. The source ref is
  `refs/heads/BRANCH`, and the release tag can be any value: the attested
  commit is the branch head the build ran on.

**Fail closed.** A column-4 value that matches no form stops the run with an
error before the download, so a wrong value blocks that producer's
publications and changes no state.

**Registered.** updex, intuneme, firn, chairlift and first-setup are
`release.yml@refs/tags/v*`; bootc-debian and omarchy-apps are
`build.yml@refs/heads/main`; incus is
`builds-docker.yml@refs/heads/stable` (a follow-up decision, Brian, T733a).
No producer is `no` now.

## Consequences

- A producer that renames its release workflow or changes its tag scheme
  needs a `producers.tsv` change first; until then its publications are
  refused.
- A tag pattern is not a ruleset. It proves which tag the attested run built,
  not who may push that tag: tag protection stays on the producer's side.
- The release tag of a branch producer is not bound to the attested commit. A
  later step can add `--source-digest` for that.
- Every `.deb` of a policy producer costs one `gh attestation verify` call,
  as before.

## References

- Builds on: [ADR-0001](0001-aptly-single-writer.md)
- Shapes: [config/producers.tsv](../../config/producers.tsv),
  [scripts/fetch-release.sh](../../scripts/fetch-release.sh),
  [tests/check-config.sh](../../tests/check-config.sh)
- Evidence: `tests/run.sh`, section "build provenance (ADR-0004)"
- Amended in part by: [ADR-0006](0006-state-the-reason-for-the-incus-signer-ref.md)
