# 0001 — Publish Debian packages through one aptly writer

- **Status:** Accepted
- **Date:** 2026-10-02

## Context

Many Frostyard repositories publish `.deb` files to
`repository.frostyard.org` through repogen's `publish-to-r2` action. Each run
syncs the published `dists/stable` indexes, merges in its own packages
(repogen ADR-0011), and uploads the result. There is no lock, so two releases
landing together can drop each other's packages. The repository has one
moving suite, `stable`, and only `all` and `amd64`.

repogen has disabled that Debian path pending a production writer. core
ADR-0048 asks that writer for explicit codenames, one protected writer,
mandatory signing, an immutable pool, by-hash indexes and verified
publication. aptly 1.6 already provides snapshots, atomic publish switches,
by-hash indexes, signing and S3-compatible publishing.

## Decision

- **One writer.** `frostyard/apt-publisher` is the only writer of Debian
  metadata. Its writer workflows share one GitHub concurrency group with
  `queue: max`, because the default queue keeps one pending run and cancels
  the rest. Only its `apt-repository` environment holds the signing key and
  R2 write credentials.
- **Missed requests.** A nightly, report-only audit lists every
  latest-release `.deb` of a registered producer that no codename publishes.
- **Dispatch, not direct publishing.** Producers send a `publish-deb`
  repository_dispatch naming a release.
- **Fetch-time checks.** The publisher downloads the release's `.deb` assets
  and verifies their build provenance for attested producers.
- **Pre-publish checks.** Before changing any state, it checks each package
  against the producer's allowed names, codenames and architectures.
- **Codenames.** aptly publishes `trixie` and `forky` under the `debian/`
  prefix of the existing bucket, sharing one pool. A `~debNN` or `+debNN`
  version marker routes a build to its codename only.
- **Atomic publication.** Every publication creates a snapshot and switches
  the codename to it.
- **Recoverable transactions.** The snapshot is recorded as pending and
  saved before it becomes visible.
- **Reconcile before change.** Before changing a codename, a run compares
  the bucket's package set with aptly's database. It continues when they
  match, and completes an interrupted publication when the bucket matches
  the pending snapshot. Anything else is refused: lost or older state, or
  another writer. An operator recovers with an explicit `--force`.
- **Two removal modes.** Withdrawing removes one version and republishes.
  Point-in-time rollback publishes an earlier snapshot and rebuilds the
  working repository from it, so later publications don't restore what was
  rolled back.
- **No deletion.** Pool files are never deleted: switches use
  `-skip-cleanup`.
- **Read-back.** Every publication is read back from the bucket: the
  signature, the index hashes and the new packages' bytes. Rollbacks and
  imports also check every listed pool file's MD5. An apt canary then
  installs the new packages through the public URL.
- **State.** aptly's database, pool and pending markers persist in a
  private bucket.
- **Legacy suite.** The `stable` suite is imported into `trixie` and then
  frozen.
  - A review run verifies the signatures and hashes and prints a manifest
    hash.
  - The import run adds exactly that manifest's files, and only if the hash
    still matches.

## Consequences

- Concurrent releases queue instead of racing. Producers lose their R2 and
  signing credentials.
- Rollback is point-in-time: it also unpublishes other producers' later
  packages until they are republished. Withdrawal is the narrow tool.
  Nothing is ever deleted from the pool.
- Clients move from `/ stable` to `/debian trixie` (or `forky`), keeping the
  same signing key.
- A package version is immutable: a rebuild with different bytes needs a
  new version.
- The pool is stored twice: published under `debian/pool` and in the state
  bucket. Each run restores the state pool (about 3 GiB after the import).
- The publisher depends on aptly's database format. Lost, stale or foreign
  state blocks publication instead of overwriting it, and recovery is an
  operator decision (`--force`).
- Interrupted publications converge on the next run, without an operator.
- Packages linked against distribution libraries need one build per
  codename, with versioned markers.

## Alternatives considered

- **Finish repogen's production writer:** it would reimplement aptly's
  snapshot, switch and signing behaviour, and keep the custom metadata parser
  as a correctness obligation.
- **reprepro:** mature and packaged in Debian, but it publishes only to a
  filesystem and has weaker snapshots, so an extra sync step would be needed.
- **deb-s3:** keeps the many-writers model behind an advisory S3 lock, and
  the original is unmaintained.
- **Hosted (Cloudsmith, packagecloud):** custom domains are paid-only and
  would split the single `repository.frostyard.org` origin (core ADR-0009).

## References

- Builds on: core ADR-0009 (single artifact origin), core ADR-0010
  (publish packages via repogen to R2), core ADR-0048 (explicit codenames),
  repogen ADR-0011 and ADR-0013
- Shapes: [README](../../README.md), [scripts/publish.sh](../../scripts/publish.sh),
  [scripts/import-stable.sh](../../scripts/import-stable.sh)
- Accepted for the organization as: core
  [ADR-0055](https://github.com/frostyard/core/blob/main/docs/adr/0055-publish-debian-packages-through-the-apt-publisher.md)
