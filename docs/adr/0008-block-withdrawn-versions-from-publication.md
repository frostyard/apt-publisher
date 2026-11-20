# 0008 — Block withdrawn versions from publication

- **Status:** Accepted (2026-11-20)
- **Date:** 2026-11-16

## Context

A withdrawal removes a version from the index and leaves the pool file. It
does not stop a later publication of the same version: a re-run of the
producer's release workflow, or a repeated `repository_dispatch`, publishes
the release again, and the withdrawn version is back with no warning
([design/overview.md](../design/overview.md), known limitations; there is no
blocklist).

The batch files in `withdrawals/` already record withdrawals that went
through a reviewed pull request. Each row is `NAME VERSION [ARCH]`, and
`scripts/withdraw.sh` reads the files with fixed regular expressions for the
name, the version and the architecture.

## Decision

`scripts/publish.sh` reads every file in `withdrawals/` (`APT_WITHDRAWALS_DIR`),
hidden files too, and refuses a `.deb` that a row names.

- **Rows apply to every codename.** A batch file names no codename, so a row
  blocks the version in `trixie`, `forky` and any later codename.
- **A row matches by name, version and architecture.** The names are equal,
  and `dpkg --compare-versions` finds the versions equal (so `0:1.0` and `1.0`
  match). A row with an architecture blocks only that `Architecture:` value,
  exactly: a row for `amd64` does not block an `Architecture: all` package. A
  row with no architecture blocks every architecture.
- **The rows are those of the commit the run checks out.** The workflow reads
  the files of its own checkout.
- **A malformed row refuses the run.** The row must have 2 or 3 fields and
  match the shapes `withdraw.sh` applies. A directory entry that is not a
  readable regular file refuses the run too, a hidden entry included. An empty
  file holds no row. The message names
  `withdrawals/FILE line N`. A row that is skipped would let a withdrawn
  version come back.
- **The refusal comes before any state change.** The check runs after the
  producer's package globs and before `--dry-run` exits, `aptly_init` and
  reconciliation. Every blocked `.deb` is listed, one line each, and the whole
  release is refused: nothing of it is published.
- **The PR that removes the row is the only way back.**
- **A single withdraw by workflow input does not block.** It has no committed
  row. A permanent block needs a committed batch row.

## Consequences

- A withdrawn version stays withdrawn when its producer publishes the same
  release again. The refusal is visible in the publish run, with the row's
  file and line.
- The 2 batch files that exist now block those versions in new publish runs:
  `withdrawals/2026-11-02-omarchy-removed-apps.txt` (70 rows) and
  `withdrawals/2026-11-05-snow-first-setup.txt` (10 rows). A release that holds
  one of them is refused as a whole.
- A re-run of an old publish run checks out its own commit and reads only that
  commit's rows. A row added later does not apply to it.
- A rollback (`scripts/switch.sh`) does not judge rows. A rollback to a
  snapshot that lists a withdrawn version restores it.
- `import-stable` and the move add no new versions and do not read rows.
- A single withdraw by workflow input needs a committed batch row for a
  permanent block.
- A release that has one blocked package blocks its other packages too, until
  the row is removed or the producer builds a new version.
- A malformed row in any file stops every publish run until a PR fixes it.
  `tests/check-config.sh` checks the files in CI to catch this early.

## Alternatives considered

- **A blocklist in the state pool, written by the withdraw workflow:**
  rejected. It is not reviewed in a PR and not visible in git, it is another
  state object to reconcile with the bucket, and a single withdraw would block
  a version without review.
- **Keep the limitation:** rejected. A re-run of a producer's release workflow
  or a repeated `repository_dispatch` publishes the bad version again with no
  warning.
- **Block names only:** unregistration of a producer already does that. It
  does not cover one bad version of a live producer.

## References

- Shapes: [design/overview.md](../design/overview.md),
  [specs/producer-interface.md](../specs/producer-interface.md)
- Runbooks: [runbooks/operations.md](../runbooks/operations.md),
  [runbooks/producers.md](../runbooks/producers.md)
- Builds on: [ADR-0001](0001-aptly-single-writer.md),
  [ADR-0003](0003-keep-the-newest-versions-of-a-producer.md)
