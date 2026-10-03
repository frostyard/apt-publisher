# Handoff: apt-publisher

Written 2026-10-02 at the end of a Claude Code session, to resume on another
machine, and updated by a second session the same day.

**The order and status of the remaining work now live in core:**
[Plan 0009](https://github.com/frostyard/core/blob/main/docs/plans/0009-debian-publication-through-apt-publisher.md).
It is governed by core
[ADR-0055](https://github.com/frostyard/core/blob/main/docs/adr/0055-publish-debian-packages-through-the-apt-publisher.md)
(apt-publisher is the single Debian writer) and
[ADR-0056](https://github.com/frostyard/core/blob/main/docs/adr/0056-rebuild-images-after-apt-publication.md)
(apt-publisher triggers image rebuilds).

The [README](README.md) explains how the publisher works, and
[ADR-0001](docs/adr/0001-aptly-single-writer.md) records this repository's
side of the decision. This file holds what none of those do: apt-publisher
specifics, what was verified and how, and what was learned along the way.
Delete it once it's stale.

## Where things stand

- **Governance.** Core ADR-0055 and ADR-0056 were Accepted on 2026-10-02
  (frostyard/core#149, frostyard/core#150).
  - They supersede core ADR-0048, ADR-0054 and ADR-0013, and ADR-0009's
    Debian namespace.
  - Plan 0009 is Active and replaces Plans 0006 and 0007.
  - frostyard/core#151 updates the shared `frostyard-go-repo` skill's
    release step to match.
- **Repo:** `github.com/frostyard/apt-publisher`, **private**.
  - The "Protect main" ruleset requires a pull request (0 approvals) and
    blocks force-pushes and deletion on `main`, with no bypass.
  - It exists because `APT_PUBLISH_TOKEN` needs Contents: write here, which
    would otherwise let a leaked token push a workflow to `main`, where the
    secrets live.
- **CI:** [run 37151352797](https://github.com/frostyard/apt-publisher/actions/runs/37151352797)
  passed on `main`: config checks, then all 132 end-to-end checks.
- **Infrastructure is in place.**
  - The `frostyard-apt-state` bucket and an R2 token exist.
  - The `apt-repository` environment is limited to `main` and holds all
    seven secrets.
  - [check-secrets run 37048085445](https://github.com/frostyard/apt-publisher/actions/runs/37048085445)
    confirmed every value.
  - The R2 trial passed under `debian-test/`, which was then removed.
- **`trixie` is live** at `https://repository.frostyard.org/debian/`.
  - It was seeded from the full signed `stable` suite on 2026-10-02:
    [run 37051548490](https://github.com/frostyard/apt-publisher/actions/runs/37051548490),
    snapshot `trixie-20261002T190620Z-import-stable`, 234 files of 32
    packages.
  - Checked independently afterwards: the signature verifies with
    `keys/frostyard.gpg`, the index contents match, and apt downloads
    packages through the public URL.
  - Legacy `stable` is unchanged.
- **updex is the first migrated producer.**
  - Its release requests publication with `publish-deb`
    (frostyard/updex#432).
  - **v2.0.2 went through the whole path on 2026-10-02.**
    - The release ran
      [goreleaser run 37058579495](https://github.com/frostyard/updex/actions/runs/37058579495),
      which dispatched `publish-deb`.
    - [Publish run 37058743496](https://github.com/frostyard/apt-publisher/actions/runs/37058743496)
      took 4m40s. It verified the attestations, switched `trixie` to
      `trixie-20261002T201001Z-updex-v2.0.2`, and published `forky` for
      the first time from `forky-20261002T201002Z-updex-v2.0.2`.
    - It then read both suites back, purged 30 URLs, and ran the canary
      on trixie and forky for amd64 and arm64.
    - Finally it dispatched `build` to snosi, whose Build Image Variants
      and Build Installer ISO started at 20:13:57.
- **incus is migrated** (Plan 0009 Phase 4; frostyard/incus#6,
  frostyard/incus#7, frostyard/apt-publisher#7).
  - Each push to incus's `stable` branch builds Debian 13 amd64 and
    publishes a GitHub release of exactly five `.deb` files.
  - The build then requests `trixie` only. incus is registered
    `attested=no`, because its attestations name `refs/heads/stable`.
  - Incus 7.5.1 was published on 2026-10-03 by
    [publish run 37153494023](https://github.com/frostyard/apt-publisher/actions/runs/37153494023)
    as `1:7.5.1-debian13-202610032056`, into snapshot
    `trixie-20261003T210024Z-incus-7.5.1-debian13-202610032056`. forky
    gets none.
  - `stable` on incus is protected by a "Protect stable" ruleset, the same
    as apt-publisher's `main`.
  - incus's release workflow is *generated* by `sync-docker-build.py`;
    change the generator, not `builds-docker.yml`.
- **snosi reads `/debian/` `trixie`** (Plan 0009 Phase 5, done 2026-10-03;
  frostyard/snosi#1042).
  - Its images pick up each producer's publication, starting with updex
    2.0.2 and incus 7.5.1.
  - Its sysext publication, still through repogen, leaves both Debian trees
    untouched.
- **Legacy `stable` is protected again.**
  - Producers pinned to pre-refusal `publish-to-r2` commits wrote it after
    the freeze: incus 7.4 on 2026-09-16 at `v0.4.1`, and firn 0.6.0 on
    2026-10-01 at `6648671`.
  - On 2026-10-03 the org's `R2_*` and `REPOGEN_GPG_KEY` secrets were
    limited to snosi.
  - Core's drift alarm was re-baselined on the explained state
    (frostyard/core#153). It passes:
    [run 37151554483](https://github.com/frostyard/core/actions/runs/37151554483).
- **`APT_PUBLISH_TOKEN`** (org secret) is visible to updex, incus, firn and
  chairlift. This was checked per repo on 2026-10-03; the full list needs
  `admin:org`.
- **CDN cache rules are in place** (Plan 0009 Phase 3, done 2026-10-03):
  `/debian/pool/` and `by-hash` are cached at the edge; the indexes and
  errors are not. See "The CDN" below.
- **Not yet moved** (Plan 0009 Phase 4): bootc-debian, chairlift,
  intuneme, first-setup, firn, pilothouse, snowcat-cockpit and gchlog. Their
  old repogen steps now fail for lack of credentials instead of writing
  `stable`. After that comes forky (Phase 6).

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
  - aptly writes `snapshot list` one line per `write` call.
    - Piped into `grep -q` under `pipefail`, aptly could die of SIGPIPE, so
      an existing snapshot was reported missing: 107 of 300 calls with
      both processes on one CPU.
    - It surfaced as an intermittent CI failure, "no snapshot named
      forky-…".
    - `snapshot_exists` now reads the whole list first
      (frostyard/apt-publisher#2). Do the same with any reader of aptly
      output that stops early.
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
- **`gh attestation verify`** prints nothing when stdout isn't a terminal;
  only the exit status matters.
  - On updex v2.0.1, the genuine `.deb` gives 0, while a tampered copy or
    the wrong `--source-ref` tag gives 1.
- **Cloudflare purge errors.** An active token without Cache Purge on the
  zone gets "Authentication error", not a permission error. check-secrets
  reports the token's status alongside it to tell the cases apart.
- **Against real R2** (aptly 1.6.3, the R2 trial):
  - aptly's S3 publishing works with `region: auto` and `acl: none`, and
    rclone's `Cloudflare` provider restores and saves the state;
  - `verify --deep` passed, so R2 ETags are MD5s for aptly's uploads;
  - the zone accepts a purge of 30 URLs in one request.
- **The CDN.**
  - `repository.frostyard.org` serves any bucket prefix: `/debian-test/`
    worked with no setup.
  - Without a rule, every response was `cf-cache-status: DYNAMIC`, the
    immutable `by-hash` indexes included (checked 2026-10-02).
  - Cloudflare's "Ignore cache-control header and use this TTL" applies to
    every status code. A 404 is cached for the full TTL unless a Status
    code TTL exempts it. Status code TTLs accept `no-store` and work on
    every plan.

## Next steps: Plan 0009

Plan 0009 has the phases, the producer checklist (ordered by what snosi
installs) and the done-when conditions. Below are the apt-publisher details
it doesn't carry.

- **Phase 3, cache rules. Done 2026-10-03.** The `frostyard.org` zone has
  one Cache Rule, `apt immutable`:
  - Custom filter expression:
    `http.host eq "repository.frostyard.org" and (starts_with(http.request.uri.path, "/debian/pool/") or (starts_with(http.request.uri.path, "/debian/dists/") and http.request.uri.path contains "/by-hash/"))`.
  - Cache eligibility: Eligible for cache.
  - Edge TTL: ignore cache-control header, 1 year, plus a Status code TTL of
    `no-store` for status codes 400 and up, so errors are never cached.
  - Browser TTL: Respect origin. apt gains nothing from browser caching,
    and overriding would give proxies such as apt-cacher-ng long lifetimes
    for error responses.
  - Why that's safe: pool files never change under the same name (the
    publisher refuses different bytes for an existing version), and
    `by-hash` paths are content-addressed.
  - The mutable indexes (`InRelease`, `Release`, `Release.gpg`,
    `Packages*`) stay uncached. `purge-cache.sh` still purges them after
    each publish, as a safety net.
  - Checked on 2026-10-03: a `by-hash` index and
    `frostyard-updex_2.0.2_amd64.deb` returned `MISS`, then `HIT`. A
    missing file returned `BYPASS` twice. `InRelease` returned `DYNAMIC`.
  - Keep any later rule in the zone from matching these paths with
    "Bypass cache"; a later matching rule overrides this one.
- **Phase 4, moving a producer.** The apt-publisher side has three steps:
  1. **Register it.** Add a line to `config/producers.tsv` by PR, since
     `main` is protected. `tests/check-config.sh` validates the file.
     Confirm the package names first.
  2. **Share the token.** Add the repo to the org secret
     `APT_PUBLISH_TOKEN` without disturbing the existing list:
     `gh api -X PUT orgs/frostyard/actions/secrets/APT_PUBLISH_TOKEN/repositories/$(gh api repos/frostyard/<repo> --jq .id)`.
     Avoid `gh secret set --org --repos`, which *replaces* the list.
  3. **Change the producer's release workflow.**
     - frostyard/updex#432 is the template for tag-released Go producers,
       including its contract test and Tier 4 PR description.
     - frostyard/incus#6 is the template for producers that release from
       branch pushes.
     - `R2_*` and `REPOGEN_GPG_KEY` are already limited to snosi, so no
       producer needs them removed.

  Producer-specific notes:
  - **incus (done).** Its versions carry `-debian13-`, which is not a
    `~debNN` marker, so it is registered for `trixie` only. A forky build
    would append `~deb14`; `-debianNN-` already orders a Debian 13 build
    below a Debian 14 build.
  - **bootc-debian was made public on 2026-10-03,** so `fetch-release.sh`
    and the audit read its releases with `github.token`. Private producers
    still need a token with Contents read, or to go public.
    - It is registered `trixie` only and `attested=no`: it releases from
      manual runs on `main`, so its provenance names `refs/heads/main`.
    - Its versions carry `~deb13`. GitHub lists release assets with `.` in
      place of `~`, and aptly keeps those names for the pool files.
  - Producers without build attestations use `attested=no` until they add
    `actions/attest-build-provenance`.
  - Package names in `stable`: `frostyard-*`, `incus*`, `bootc`,
    `libostree-1-1`, `voxtype`, `ttfx`, `tensaku`, `omawrite`, `omacut`,
    `omacalc`, `moonlight-qt`, `kapsule*`, `hyprland-preview-share-picker`,
    `herdr`, `gpu-screen-recorder`, `cliamp`, `aether`, `igloo` and
    `snow-first-setup` (arch `all`).
    - Both `frostyard-igloo` and `igloo` exist, from a rename.
    - `kapsule*` has no producer: `github.com/frostyard/kapsule` doesn't
      exist.
- **Phase 5, snosi.** Done 2026-10-03 (frostyard/snosi#1042).
- **Phase 7, audit.** Set the repository variable `APT_AUDIT_ENABLED=true`
  once producers publish through apt-publisher.
- **Visibility (optional).** The org is on the Team plan, so the
  `apt-repository` environment's branch rule works on a private repo.
  Going public is a preference:
  `gh repo edit frostyard/apt-publisher --visibility public --accept-visibility-change-consequences`.
- **Re-running the R2 trial,** for example after upgrading aptly or rclone:
  - Run it from a workstation, against real R2 under
    `APT_PREFIX=debian-test` and `APT_STATE_PATH=aptly-test`.
  - Set `APT_PUBLIC_URL=https://repository.frostyard.org/debian-test` too,
    or the canary and purge check `/debian`.
  - Steps:
    1. Fetch a release and verify its attestations.
    2. Dry run, then publish to trixie and forky.
    3. `verify.sh --deep` both codenames, purge, then run the canary.
    4. Withdraw one build from forky.
    5. `switch.sh` back to the first forky snapshot.
    6. Remove both test prefixes.
  - Import the key into a throwaway `GNUPGHOME`, and give each script a
    fresh `APTLY_ROOT`.
  - The second session's `r2-trial.sh` lived in a `/tmp` scratchpad and
    isn't committed.
- **Decisions.**
  - Where the decision record lives is resolved: core ADR-0055 is the org
    record, and this repo's ADR-0001 is the local one.
  - What repogen becomes, and what happens to `stable` after 2027-09-30,
    are open questions in Plan 0009. repogen's v0.5.0
    digest-reconciliation failure is why snosi pins
    `repogen-version: v0.4.1`.

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
make verify     # 120 end-to-end checks, about 25 s
```

The test also needs `gpg`, `gpgv`, `dpkg-deb`, `apt-get`, `curl` and
`python3` from the system. `KEEP_TMP=1 tests/run.sh` keeps the fake bucket
and runner directories for inspection.
