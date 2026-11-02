# 0003 — Keep the newest versions of a producer

- **Status:** Accepted
- **Date:** 2026-11-02

## Context

[ADR-0001](0001-aptly-single-writer.md) gives the publisher two removal
modes: withdrawal of one version, and a point-in-time rollback. Neither is
automatic, so a codename accumulates every version a producer ever
published. Core
[ADR-0067](https://github.com/frostyard/core/blob/main/docs/adr/0067-publish-omarchy-apps-on-change-and-keep-the-newest-two.md)
publishes omarchy-apps on change and keeps the newest two versions.

Clients need a small, predictable set of versions in the index. The pool is
append-only, so old files stay available for a rollback.

## Decision

**Configuration.** `config/producers.tsv` column 7, `keep`, holds a positive
integer N, or `-` for no limit. An empty column, as in a six-column row,
reads as `-`.

**The rule.** A publication of a producer with `keep=N` withdraws every
version older than the newest N of each of its packages, counted per package
name and architecture, for the names that match the producer's column-2
globs. A codename's working repository holds every producer of its component,
so a name that matches no glob is never pruned. `2` keeps two versions of a
package per architecture; it does not keep two versions of the producer.

**Version order.** Versions are compared with `dpkg --compare-versions`.
`sort -V` reads an epoch and a `~` wrongly: `1:1.0` is newer than `2.0`, and
`2.0~rc1` is older than `2.0`.

**One publication.** The rule runs in the publication that adds the versions
that make older ones too many: the run adds the packages, removes the older
versions from the working repository, takes the snapshot, publishes and reads
the result back, all in one transaction. A publication whose own packages are
among the versions to withdraw is refused before any state change: retention
would withdraw them at once.

**A third removal mode.** Retention amends ADR-0001's two removal modes with
a third, and it shares the no-deletion rule: aptly switches keep
`-skip-cleanup`, so no pool file is deleted. Retention removes a version from
the index only. A pruned version comes back only through a rollback to a
snapshot that lists it, or through a later publication that re-adds it while
it is within the limit.

**Report.** `publish.sh --pruned FILE` writes one
`codename name version arch component` row per withdrawn version, and an
empty file when it withdrew none. The publish workflow adds those rows to the
run summary.

**Read-back.** Each pruned `name=version` that no architecture keeps anymore
is verified absent from the publication, as `!COMPONENT/NAME=VERSION`.
`tests/check-config.sh` refuses a `keep` value that is not a positive integer
or `-`.

## Consequences

- A producer with `keep=N` lists at most N versions of each of its packages
  per architecture in each codename. The pool and the state bucket keep every
  file.
- Re-dispatching an old release after newer versions were published is
  refused while it is older than the newest N, so it stays unpublished until
  a rollback makes room for it. The audit reports its assets as missing, as
  it reports a withdrawn version.
- The snapshot a publication creates lists the versions that stayed, so a
  rollback to that snapshot does not bring a pruned version back. A rollback
  to an earlier snapshot does.

## Alternatives considered

- **Delete pool files.** Refused: ADR-0001 keeps the pool immutable, so a
  rollback can restore a version and clients keep a stable URL.
- **Withdraw each old version by hand.** Withdrawal stays the narrow tool for
  one version, but a producer that releases on every change needs the rule in
  every publication.
- **`sort -V` for the version order.** Rejected: it mishandles epochs and
  `~`, and Frostyard ships both.
- **Keep the newest N versions of the whole producer.** Rejected: a producer
  ships several packages, and each needs its own versions.

## References

- Builds on: [ADR-0001](0001-aptly-single-writer.md), core
  [ADR-0067](https://github.com/frostyard/core/blob/main/docs/adr/0067-publish-omarchy-apps-on-change-and-keep-the-newest-two.md)
- Shapes: [config/producers.tsv](../../config/producers.tsv),
  [scripts/publish.sh](../../scripts/publish.sh),
  [scripts/lib.sh](../../scripts/lib.sh),
  [.github/workflows/publish.yml](../../.github/workflows/publish.yml)
- Evidence: `tests/run.sh`, section "retention (core ADR-0067)"
