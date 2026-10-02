# Handoff: apt-publisher

Written 2026-10-02 at the end of a Claude Code session, to resume on another
machine. The [README](README.md) explains how the publisher works, and
[ADR-0001](docs/adr/0001-aptly-single-writer.md) records why. This file holds
what those don't: where things stand, what was verified and how, what was
learned along the way, and what's next. Delete it once it's stale.

## Where things stand

- **Repo:** `github.com/frostyard/apt-publisher`, **private**. One code
  commit (`38ee348`) plus this file.
- **CI:** [run 37040199794](https://github.com/frostyard/apt-publisher/actions/runs/37040199794)
  passed on GitHub: config checks, then all 113 end-to-end checks.
- **Not run against R2 yet.** The `apt-repository` environment exists
  (limited to `main`) with all seven secrets, set 2026-10-02. Run
  **check-secrets** to confirm their values before the R2 trial.
- **Nothing outside this repo has changed:**
  - updex and the other producers still call repogen's `publish-to-r2`
    action. The deb path of that action refuses to run, so their deb
    publishing is effectively blocked today.
  - snosi still reads the legacy `stable` suite.

## Why this exists

The question was "what's a more proper alternative to frostyard/repogen for
the Debian repository?" Findings from the snosi workspace:

- **Many writers, no lock.** About 20 repos called `publish-to-r2`:
  bootc-debian, chairlift, firn, igloo, gchlog, first-setup, intuneme,
  incus, nbc, omarchy-apps, pilothouse, snowcat-cockpit, updex and others.
  Each run read-modify-wrote the shared `dists/stable` index, rebuilt from
  published metadata (repogen ADR-0011), with no lock.
- **The deb path is already off.** repogen's action now refuses
  `package-type: deb` (action.yml, "requires the reviewed target-scoped
  production writer"). core ADR-0048 lists that writer's requirements, which
  are essentially aptly's feature set.
- **The live repository** (`https://repository.frostyard.org/dists/stable`):
  - suite `stable`, codename `stable`, Origin "Repogen Repository";
  - architectures `all amd64`;
  - 9 + 225 index entries, 234 files, about 3 GiB;
  - signed by `432C452CD2B7F4FF1B5D23264DE6A2016E622F97`, the same key as
    `keys/frostyard.gpg` and snosi's
    `mkosi.sandbox/etc/apt/keyrings/frostyard.gpg`;
  - no `~debNN` versions yet.
- **snosi itself** uses repogen only for sysexts (`build.yml`,
  `package-type: sysext`). It consumes debs through
  `mkosi.sandbox/etc/apt/sources.list.d/frostyard.sources`
  (`Suites: stable`).
- **Alternatives considered:**
  - aptly: chosen.
  - reprepro: filesystem only.
  - deb-s3: unmaintained, keeps many writers.
  - Cloudsmith: custom domains are paid-only and would break the single
    origin (core ADR-0009).
  - Pulp, Artifactory, OBS: they need servers.

## Review history

A Codex review raised five findings plus one gap. All six were reproduced
against the local S3 setup before fixing, and each fix has a test in
`tests/run.sh`:

| Finding | Fix | Test (search tests/run.sh) |
| --- | --- | --- |
| Default concurrency queue cancels pending runs | `queue: max` on all writer workflows, enforced by `tests/check-config.sh`; nightly report-only audit | `check-config.sh`; "the audit reports an unpublished release" |
| Older DB silently drops newer packages | `reconcile_state`: bucket package set must equal the DB's published or pending snapshot | "an older database is refused" |
| Rollback undone by the next unrelated release | `rebuild_repo` from the snapshot during rollback | "the rollback survives an unrelated publication" |
| Import publishes leftovers in `--work` | Add exact manifest paths; two-run import pinned by manifest SHA256 | "import ignores files outside the manifest" |
| Interrupted first publication can't be retried | Pending marker in `txn/` before publish; reconcile completes it | "retrying converges", "another producer's run completes it" |
| Verify checks metadata only | Per-package SHA256 on publish, `--deep` MD5 of the whole pool, apt canary through the public URL | "verify checks a named package's bytes", "deep verify finds…", "the canary refuses…" |

## Facts verified the hard way

Re-check these if versions change:

- **What aptly 1.6.3 needs locally.**
  - It reads a local pool file only when a snapshot references a package
    the bucket lacks, so an object with the same MD5 is skipped.
  - S3 uploads are a single `PutObject` with `Md5` metadata. That's why
    `verify --deep` can trust the R2 ETag as the MD5.
  - A database-only state (no pool) broke the import-then-publish flow and
    failure recovery, which is why the state bucket also holds the pool.
- **aptly snapshot behaviour.**
  - `aptly snapshot show` exits 1 once the snapshot's source repo has been
    dropped. Use `snapshot_exists`, which is `snapshot list -raw`.
  - `aptly repo drop -force` keeps snapshots.
  - `repo create NAME from snapshot S` rebuilds a repo from a snapshot.
- **Index field order.** aptly's `Packages` stanzas don't put `Architecture`
  after `Version`, so parse whole stanzas (paragraph mode, as
  `stanzas_tsv` does).
- **`publish switch -skip-cleanup`** never deletes pool files. Without it,
  aptly deletes unreferenced files under `pool/main` at the prefix.
- **`rclone serve s3` quirks** (tests only):
  - it livelocks intermittently with `--dir-cache-time 0s`; keep the
    default;
  - auth keys `AK,SK` were rejected, while `testaccesskey,testsecretkey123`
    works.
- **actionlint** 1.7.7 through 1.7.12 rejects the concurrency `queue` key,
  hence the ignore in `.github/actionlint.yaml`.
- **`apt-get download` over `file://`** verifies hashes, which is why the
  canary corruption test is meaningful.

## Next steps, in order

1. **Visibility.** The org's repos are mostly public (58 of 64, repogen
   included). Environment branch protection may need a public repo on a
   free plan:
   `gh repo edit frostyard/apt-publisher --visibility public --accept-visibility-change-consequences`.
2. **Infrastructure.**
   - Create a private R2 bucket, `frostyard-apt-state`.
   - Create an R2 token with read/write on it and on `frostyardrepo`.
   - Create a GitHub environment, `apt-repository`, limited to `main`,
     with secrets `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`,
     `R2_SECRET_ACCESS_KEY`, `APT_SIGNING_KEY`, `CLOUDFLARE_ZONE`,
     `CLOUDFLARE_API_TOKEN` and `DISPATCH_TOKEN`.
   - Confirm `REPOGEN_GPG_KEY` has no passphrase; the scripts assume none.
3. **R2 trial.**
   - Run publish, rollback, withdraw and verify from a workstation against
     R2, with `APT_PREFIX=debian-test` and `APT_STATE_PATH=aptly-test`.
   - Set the `R2_*` and `APT_SIGNING_KEY` env vars, and import the key with
     `scripts/import-signing-key.sh`.
   - This confirms aptly with `region: auto` and `acl: none`, rclone's
     Cloudflare provider, and that R2 ETags are MD5s for aptly's uploads.
4. **Cloudflare.**
   - Confirm `https://repository.frostyard.org/debian/` serves from the
     bucket, and decide cache rules for `dists/`.
   - The purge sends 30 URLs per request; check the zone's limits.
5. **Import.** Run **import-stable** without `publish` and review the
   manifest. Then run it with `publish` and that `manifest_sha256`.
6. **Producers.**
   - Move updex first, using the snippet in the README. Producers need an
     `APT_PUBLISH_TOKEN` with Contents read/write on apt-publisher only.
   - Then register each other producer in `config/producers.tsv`. Confirm
     each one's package names first; only updex is registered.
   - Package names seen in `stable` include `frostyard-*`, `incus*`,
     `bootc`, `libostree-1-1`, `voxtype`, `ttfx`, `tensaku`, `omawrite`,
     `omacut`, `omacalc`, `moonlight-qt`, `kapsule*`,
     `hyprland-preview-share-picker`, `herdr`, `gpu-screen-recorder`,
     `cliamp`, `aether` and `igloo`.
   - Producers that link distribution libraries need one build per codename
     with `~deb13` / `~deb14` versions; bootc-debian is the first of these.
   - Producers without build attestations use `attested=no` until they add
     `actions/attest-build-provenance`.
7. **snosi.** Change `frostyard.sources` to
   `URIs: https://repository.frostyard.org/debian/` and `Suites: trixie`,
   keeping the same keyring.
8. **Audit.** Set the repository variable `APT_AUDIT_ENABLED=true` once
   `/debian` is live.
9. **Decisions still open:**
   - whether ADR-0001 lives here or in `frostyard/core` next to ADR-0048;
   - what repogen becomes: sysexts only, or replaced by a small
     sign-and-upload script. Its v0.5.0 digest-reconciliation failure is
     why snosi pins `repogen-version: v0.4.1`;
   - when, or whether, to delete the frozen legacy `stable` suite.

## Known limitations, accepted for now

- **Restore cost.** Every run restores the whole state pool, about 3 GiB
  after the import. Restoring the database only, and fetching pool files on
  demand, is a possible optimisation.
- **Audit heuristics.**
  - It parses `name_version_arch.deb` asset names and checks only each
    producer's latest release.
  - It counts an asset as published if any of the producer's codenames
    lists it.
  - It reports withdrawn latest releases as missing, by design.
- **Point-in-time rollback** also unpublishes other producers' later
  packages until they are republished. Use withdraw for a single bad
  version.
- **Withdrawn versions come back** if the same release is republished. There
  is no blocklist.
- **`switch.sh --force`** overwrites the bucket with aptly's view and
  re-uploads differing pool files. Run it only after inspecting the refusal.

## Resuming

```sh
git clone git@github.com:frostyard/apt-publisher.git && cd apt-publisher
mise install    # aptly 1.6.3, rclone, shellcheck, actionlint, jq (mise.lock)
make verify     # 118 end-to-end checks, about 25 s
```

The test also needs `gpg`, `gpgv`, `dpkg-deb`, `apt-get`, `curl` and
`python3` from the system. `KEEP_TMP=1 tests/run.sh` keeps the fake bucket
and runner directories for inspection.
