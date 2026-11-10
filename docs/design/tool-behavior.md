# Tool behavior the publisher relies on

Index: [docs/README.md](../README.md).
Living document. Rationale: [ADR-0001](../adr/0001-aptly-single-writer.md),
[ADR-0003](../adr/0003-keep-the-newest-versions-of-a-producer.md),
[ADR-0004](../adr/0004-pin-the-signer-workflow-of-attested-producers.md).
Contracts: [specs/producer-interface.md](../specs/producer-interface.md).
Context: [overview.md](overview.md).

## Overview

The publisher drives aptly, rclone, apt, `gh`, Cloudflare and R2 through the
scripts in `scripts/`. Each fact below was verified against the pinned tool
and is the reason a script is written the way it is. Re-check these if a
pinned version changes (`mise.toml`, `mise.lock`).

## Design

### aptly 1.6.3

- It reads a local pool file only when a snapshot references a package the
  bucket lacks, so an object with the same MD5 is skipped.
- `publish switch`, `publish update` and `publish snapshot` call `Publish`
  before they update or add the publication in the database. A failed
  `Publish` leaves that database entry unchanged. For `publish update`, the
  staged source revision stays in the database.
- A failed `Publish` prints `ERROR: unable to publish:` on stderr and exits
  1. Retry only transient R2 errors on that line. Errors before `Publish`
  (`unable to switch:`, `unable to update:`, signer initialization) and
  after it (`unable to save to DB:`) must not retry.
- aptly writes indexes with a `.tmp` suffix, then renames them at the end.
  Pool uploads skip objects with the same MD5. Repeating the same publish
  command with the same snapshots converges, as pending-marker recovery
  does. `publish source add/update` change the database before publication;
  repeating the whole staging path is not safe.
- S3 uploads are a single `PutObject` with `Md5` metadata. That is why
  `verify --deep` can trust the R2 ETag as the MD5.
- A database-only state (no pool) broke the import-then-publish flow and
  failure recovery, which is why the state bucket also holds the pool.
- `aptly snapshot show` exits 1 once the snapshot's source repository has
  been dropped. Use `snapshot_exists`, which is `snapshot list -raw`.
- aptly writes `snapshot list` one line per `write` call. Piped into
  `grep -q` under `pipefail`, aptly could die of SIGPIPE, so an existing
  snapshot was reported missing: 107 of 300 calls with both processes on one
  CPU. It surfaced as an intermittent CI failure, "no snapshot named
  forky-...". `snapshot_exists` now reads the whole list first. Do the same
  with any reader of aptly output that stops early.
- `aptly repo drop -force` keeps snapshots.
- `repo create NAME from snapshot S` rebuilds a repo from a snapshot.
- aptly's `Packages` stanzas do not put `Architecture` after `Version`, so
  parse whole stanzas (paragraph mode, as `stanzas_tsv` does).
- `publish switch -skip-cleanup` never deletes pool files. Without it, aptly
  deletes unreferenced files under `pool/main` at the prefix.

### rclone 1.71.1

- rclone already retries: defaults are `--retries 3` and
  `--low-level-retries 10`. The aptly retry helper does not wrap rclone.

- `rclone serve s3` quirks (tests only): it livelocks intermittently with
  `--dir-cache-time 0s`, so keep the default; auth keys `AK,SK` were
  rejected, while `testaccesskey,testsecretkey123` works.

### apt

- `apt-get download` over `file://` verifies hashes, which is why the canary
  corruption test is meaningful.

### gh

- `gh attestation verify` prints nothing when stdout is not a terminal; only
  the exit status matters. On updex v2.0.1, the genuine `.deb` gives 0, while
  a tampered copy or the wrong `--source-ref` tag gives 1.

### actionlint

- Versions 1.7.7 through 1.7.12 reject the concurrency `queue` key, hence
  the ignore in `.github/actionlint.yaml`.

### Cloudflare

- An active token without Cache Purge on the zone gets "Authentication
  error", not a permission error. `check-secrets.sh` reports the token's
  status alongside it to tell the cases apart.
- The zone accepts a purge of 30 URLs in one request.
- `repository.frostyard.org` serves any bucket prefix: `/debian-test/`
  worked with no setup.
- Without a rule, every response was `cf-cache-status: DYNAMIC`, the
  immutable `by-hash` indexes included (checked 2026-10-02).
- Cloudflare's "Ignore cache-control header and use this TTL" applies to
  every status code. A 404 is cached for the full TTL unless a Status code
  TTL exempts it. Status code TTLs accept `no-store` and work on every plan.

### R2

- aptly's S3 publishing works with `region: auto` and `acl: none`, and
  rclone's `Cloudflare` provider restores and saves the state.
- `verify --deep` passed against real R2, so R2 ETags are MD5s for aptly's
  uploads.

### Review history

A Codex review raised five findings plus one gap. All six were reproduced
against the local S3 setup before fixing, and each fix has a test in
`tests/run.sh`:

| Finding | Fix | Test (search tests/run.sh) |
| --- | --- | --- |
| Default concurrency queue cancels pending runs | `queue: max` on all writer workflows, enforced by `tests/check-config.sh`; nightly report-only audit | `check-config.sh`; "the audit reports an unpublished release" |
| Older DB silently drops newer packages | `reconcile_state`: bucket package set must equal the DB's published or pending snapshot | "an older database is refused" |
| Rollback undone by the next unrelated release | `rebuild_repo` from the snapshot during rollback | "the rollback survives an unrelated publication" |
| Import publishes leftovers in `--work` | Add exact manifest paths; two-run import pinned by manifest SHA256 | "import ignores files outside the manifest" |
| Interrupted first publication cannot be retried | Pending marker in `txn/` before publish; reconcile completes it | "retrying converges", "another producer's run completes it" |
| Verify checks metadata only | Per-package SHA256 on publish, `--deep` MD5 of the whole pool, apt canary through the public URL | "verify checks a named package's bytes", "deep verify finds...", "the canary refuses..." |

The check names above are in `tests/run.sh`, which `make verify` runs.

## Operational notes

- A pinned tool upgrade is a change to the publishing path: it touches
  `mise.toml` and `mise.lock`, which are on the risk path list. Run
  `make verify` and, for aptly or rclone, the R2 trial in
  [runbooks/operations.md](../runbooks/operations.md).

## References

- Rationale: [ADR-0001](../adr/0001-aptly-single-writer.md),
  [ADR-0003](../adr/0003-keep-the-newest-versions-of-a-producer.md),
  [ADR-0004](../adr/0004-pin-the-signer-workflow-of-attested-producers.md)
- Context: [overview.md](overview.md)
- Contracts: [specs/producer-interface.md](../specs/producer-interface.md)
