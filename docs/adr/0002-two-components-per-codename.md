# 0002 — Publish two components per codename

- **Status:** Accepted
- **Date:** 2026-10-28

## Context

Core [ADR-0059](https://github.com/frostyard/core/blob/main/docs/adr/0059-publish-image-only-packages-in-a-separate-apt-component.md)
gives every codename under `debian/` two components: `main`, for packages
that any Debian host can install, and `image`, for builds that Frostyard
images need instead of Debian's packages of the same name. Core
[ADR-0061](https://github.com/frostyard/core/blob/main/docs/adr/0061-add-the-image-apt-component-on-the-first-publication-run.md)
amends its step 3: the first publication run adds `image` by itself. ADR-0059
step 2 asks this repository to record the mechanism in its own ADR.

[ADR-0001](0001-aptly-single-writer.md) designed the publisher for one
component. Its guarantees (one writer, reconcile before change, recoverable
transactions, read-back, no deletion) must hold for each component, and for
the change of a package's component.

aptly 1.6.3 publishes several components under one codename and one signed
`Release`, each with its own pool path `pool/<component>/`. `aptly publish
switch -component=main,image` switches both at once, but cannot add a
component to a published codename; `aptly publish source add` followed by
`aptly publish update` can. `aptly repo move` moves packages between local
repositories without changing them.

## Decision

**Configuration.**

- `config/codenames.tsv` column 4 lists the components a codename publishes:
  `main` or `main,image`.
- `config/producers.tsv` column 6 registers each producer for one component.
  A producer's packages go only there; producers send the same `publish-deb`
  payload as before. `tests/check-config.sh` refuses a producer registered for
  a codename that does not publish its component.

**One component per name.** A codename publishes a package name in one
component only. Publish, import and the move refuse a name that the other
component already holds, in its working repository or its published
snapshot.

**Per-component state.** Each component has its own working repository,
snapshots and pending marker. `main` keeps the names it had before
(`frostyard-<codename>`, `<codename>-<time>-<label>`,
`txn/pending-<codename>`), so a main-only codename runs the same aptly
commands as before. `image` adds `-image` to each name.

**Transactions.** Every normal publishing path (publish, withdraw,
rollback, import, move) reconciles first and goes through
`commit_publications`: pending markers for every component it changes, save,
one signed `Release` update per codename (one `publish switch`, or for an
added component `publish source add` and `publish update`), clear, save.
`reconcile_state` compares the package set of every component with aptly's
database. It completes an interrupted publication of any component itself,
from the saved pending markers. `switch.sh --force` is the operator's
recovery: it skips reconciliation and drops the markers.

**Adding and removing a component.** A configured component that a published
codename lacks is added empty by the next publication run, also by a publish
run that does not target that codename (ADR-0061). Removing a component from
a published codename is refused; it would be a separate migration.

**Rollback.** A rollback names one snapshot per component. It refuses a
snapshot that puts a registered package name in a component other than its
producer's registration, so a snapshot taken before a move is not a rollback
target. A move is reverted by a forward change: the registration goes back,
and the move runs again.

**The move.** `scripts/move.sh` and the manual `move` workflow, in the
`apt-repository` concurrency group, move every published version whose
component differs from its producer's registration:

- it reconciles first, and refuses a working repository that differs from
  its published snapshot, unless an operator gives `--rebuild` after
  inspecting the refusal;
- it moves all versions and architectures of a name with `aptly repo move`,
  so no package version changes;
- it publishes both components of a codename in one `Release`, as one
  recoverable transaction;
- it saves a move marker (the new snapshot names and the moved versions)
  before it changes any working repository. The next run that reconciles
  that codename (a publication, withdrawal, rollback, import or move that
  targets it) drops the marker when the move became visible, and otherwise
  rebuilds both working repositories from their published snapshots.
  `switch.sh --force` drops it. A later publication
  switches one component only, so it must never find a move half applied. A
  rerun of the move that finds its earlier move completed still reads it
  back, purges the CDN and runs the canary;
- it reads every moved version back in its new component, checks that the
  old component no longer lists it, checks every pool file's MD5, purges the
  CDN, and runs the apt canary on the newest version of each name and
  architecture;
- names without a registered producer stay where they are;
- a dry run prints the plan and changes nothing. The workflow defaults to a
  dry run.

The move uploads a copy of each file under `pool/<new component>/`. The
copies under the old component's pool path stay, because no switch deletes
pool files.

**Published key.** The publisher is the only writer of `debian/frostyard.gpg`,
the binary form of `keys/frostyard.gpg`. Every publishing path uploads it
when the bucket copy is missing or differs, and every read-back compares its
bytes. The nightly audit checks it through the public URL. `/public.key` is
outside `debian/` and stays as it is.

**Debian names.** The nightly audit also reports every `main` package whose
name Debian ships for that codename in the codename, `-updates`, `-security`
or `-backports`. It is report-only: moving a producer to `image` is a
reviewed registration change. It reads Debian's indexes over HTTPS and checks
them against their `Release` hashes; it does not verify Debian's signature.

## Consequences

- Scripts, tests and recovery procedures have a component dimension.
  Operators give one rollback snapshot per component.
- The live move of bootc-debian and incus (ADR-0059 step 5) is one manual
  workflow run after their registration change. Publication requests for
  them between the merge and the move fail closed, and are rerun after the
  move.
- The move roughly doubles the bucket's storage of the moved packages (about
  2.8 GB under `pool/image/` for bootc-debian and incus). The state pool does
  not grow.
- Snapshots taken before a move cannot be rolled back to. A point-in-time
  rollback across the move needs a forward change instead.
- The audit reports a Debian name in `main` only after the fact, at most one
  day later. It does not report a package that depends on a Frostyard
  replacement of a Debian package (ADR-0059's second criterion for `image`):
  that stays a review duty for registrations.
- The nightly audit needs Debian's mirrors. A fetch error other than a 404,
  a malformed `Release` or index, or a hash mismatch fails the audit; it
  never reads as "no Debian names". A suite whose `Release` returns 404 is
  taken as absent and skipped, because Debian adds and drops suites over a
  release's life. So a wrong mirror path that returns 404 reads as absent;
  the audit logs every skipped suite.

## Alternatives considered

- **A second aptly publication per codename for images:** rejected by core
  ADR-0059. It doubles the transactions to keep in step.
- **Move by withdrawing and republishing each producer's releases:** rejected.
  It needs every old release asset, changes nothing that the move does not,
  and publishes each codename once per release instead of once.
- **Let a rollback cross a move:** rejected. A pre-move snapshot puts a name
  back in `main` while the registration says `image`, and the next
  publication of that producer would fail on the one-component rule.
- **Refuse Debian names at publication time:** rejected by core ADR-0059. It
  makes every publication depend on a Debian mirror.

## References

- Builds on: [ADR-0001](0001-aptly-single-writer.md), core
  [ADR-0059](https://github.com/frostyard/core/blob/main/docs/adr/0059-publish-image-only-packages-in-a-separate-apt-component.md),
  core
  [ADR-0061](https://github.com/frostyard/core/blob/main/docs/adr/0061-add-the-image-apt-component-on-the-first-publication-run.md)
- Shapes: [README](../../README.md), [scripts/lib.sh](../../scripts/lib.sh),
  [scripts/move.sh](../../scripts/move.sh),
  [scripts/switch.sh](../../scripts/switch.sh),
  [scripts/audit-debian-names.sh](../../scripts/audit-debian-names.sh)
- Evidence: frostyard/apt-publisher#15 and #16 (the two-component mechanism
  and the addition)
