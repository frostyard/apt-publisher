# Operations

Runbook for the people who run apt-publisher: one-time setup, the publishing
operations, recovery, and the two pieces of infrastructure outside
GitHub. Index: [docs/README.md](../README.md). How it fits together:
[design/overview.md](../design/overview.md). The dispatch contract:
[specs/producer-interface.md](../specs/producer-interface.md). Adding or
retiring a producer: [producers.md](producers.md).

Every writer operation is a workflow in `.github/workflows/`. They run in the
`apt-repository` concurrency group, one at a time, with up to 100 queued.

## One-time setup

1. Create a private R2 bucket, `frostyard-apt-state`.
2. Create an R2 API token with object read/write on `frostyardrepo` and
   `frostyard-apt-state`.
3. Create a GitHub environment named `apt-repository`, limited to `main`,
   with these secrets:
   - `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`;
   - `APT_SIGNING_KEY`: the armored secret key for
     `432C452CD2B7F4FF1B5D23264DE6A2016E622F97`, the same material as
     repogen's `REPOGEN_GPG_KEY`. It must not have a passphrase;
   - `CLOUDFLARE_ZONE`, `CLOUDFLARE_API_TOKEN` (cache purge);
   - `DISPATCH_TOKEN` (`repository_dispatch` to the `notify` repositories).
4. Run **check-secrets**. It checks every secret without publishing:
   - the signing key's fingerprint, that it signs without a passphrase, and
     that `keys/frostyard.gpg` verifies the signature;
   - that R2 can list both buckets (read-only, so write access is first
     proven by a publication);
   - that Cloudflare purges one `dists/` URL from the zone;
   - that `DISPATCH_TOKEN` can dispatch to each `notify` repository. It sends
     event type `apt-publisher-token-check`, which starts nothing as long as
     those repositories' `repository_dispatch` triggers filter on `types`.

## Withdraw one version

Run **withdraw** with a codename, package and version, plus an architecture
if needed.

- It removes that version from the working repository of the component that
  holds it and publishes a new snapshot of that component; everything else
  stays published.
- The file stays in the pool, and republishing the release brings the
  version back.
- The audit reports a withdrawn latest release as missing. That is expected,
  and the audit never republishes.

## Retention: keep the newest N

Give a producer `keep=N` in `config/producers.tsv` (core
[ADR-0067](https://github.com/frostyard/core/blob/main/docs/adr/0067-publish-omarchy-apps-on-change-and-keep-the-newest-two.md),
[ADR-0003](../adr/0003-keep-the-newest-versions-of-a-producer.md)).

- The publication that adds newer versions withdraws every older version of
  the producer's packages, per name and architecture, in the same run: the
  versions leave the working repository before the snapshot, and one signed
  `Release` carries both changes.
- Versions are ordered with `dpkg --compare-versions`, so epochs and `~`
  order as apt orders them.
- It withdraws from the index only. Pool files stay, so a pruned version
  comes back through a rollback to a snapshot that lists it, or through a
  republication of its release while it is within the newest N (for example
  after a withdrawal of a newer version).
- It removes each version by its exact package key (`NAME_VERSION_ARCH`),
  never by a dependency query, and refuses the run when the working
  repository then differs from the plan.
- `--pruned FILE` lists the withdrawn versions as
  `codename name version arch component` rows; the run summary names them.
- A publication whose own packages would be withdrawn at once, because they
  are older than the newest N, is refused before any state change.
- `-` keeps every version.

## Withdraw a batch

Commit a file in `withdrawals/` with one `NAME VERSION [ARCH]` request row per
line (a `#` line is a comment), then run **withdraw** with that codename and
the file name as `batch`.

- It resolves every row against the published codename first: a row that
  matches nothing, or a name that two components hold, refuses the whole
  batch, so either every row is withdrawn or nothing is.
- A batch withdraws from 1 component: its rows leave that component's
  working repository with one aptly call, and that component is published in
  one signed `Release`. A batch that resolves to two components is refused,
  so split it per component. The single mode is the same with one row.
- Set `dry_run` to print the plan from the published index alone; it needs
  no credentials and changes nothing. Use it first.
- The files stay in the pool, as for one version.

## Point-in-time rollback

Run **rollback** with a codename and earlier snapshots, one for each
component the codename publishes, separated by spaces. A codename that
publishes only `main` takes one. Snapshots that put a name in a component
other than its producer's registered one, such as snapshots from before a
move, are refused.

- It publishes those snapshots and rebuilds the working repositories from
  them, so later releases build on the rolled-back contents.
- Everything published to that codename after the snapshots is unpublished,
  including other producers' packages. Republish a release to roll it
  forward.
- With the snapshot left empty, it lists snapshots, publications and pending
  markers instead.

## Move packages between components

Run **move** (`dry_run` is the default) after changing a producer's
`component`. The mechanism, the move marker and the recovery rules are in
[design/overview.md](../design/overview.md#moving-packages-between-components).
Run it with `recheck=true` (and `dry_run=false`) when a step after Move
failed, or when a retry was green with nothing to move.

## Recover from a state mismatch

When a run refuses because the bucket does not match aptly's database,
inspect what changed first.

- Then run **rollback** with `force` and the snapshots the bucket should
  serve.
- This republishes it regardless of the mismatch and re-uploads any pool
  file whose bucket copy differs.

## Checks

- **Health check** (needs R2 credentials):
  `scripts/verify.sh trixie --deep frostyard-updex=2.0.2`. A spec can name a
  component, `image/NAME=VERSION`, and `!` asks for absence.
- **Download check** through the public URL (apt checks the signature, the
  indexes and the package hashes; it installs nothing):
  `scripts/apt-canary.sh trixie amd64 frostyard-updex=2.0.2`; use
  `trixie/image` for the image component.
- **Missed releases:** `scripts/audit-producers.sh`, run nightly by
  **audit**. Debian names in `main`: `scripts/audit-debian-names.sh`, also
  run by **audit**. The nightly schedule runs only while the repository
  variable `APT_AUDIT_ENABLED` is `true` (it is set); a manual run always
  runs.
- **Secrets:** run **check-secrets** after setting or rotating one.
- **Routing check** without credentials:
  `scripts/publish.sh --producer frostyard/updex --debs ./dist --dry-run`.

## Import from the legacy stable suite

repogen's `stable` suite is still in the bucket, unchanged, and
**import-stable** reads it.

1. **Review.** Run **import-stable** with `publish` unchecked.
   - It verifies the signed legacy `stable` suite and every `.deb` against
     it, and changes nothing.
   - Review the package list and note the manifest SHA256 from the run
     summary.
2. **Import.** Run **import-stable** again with `publish` checked and that
   SHA256.
   - It verifies everything again, refuses if the manifest changed since the
     review, and adds exactly the manifest's files.
   - It then publishes trixie and deep-verifies the result.
   - Check `https://repository.frostyard.org/debian/dists/trixie/InRelease`.
3. **Move producers** one at a time to the dispatch step in
   [producers.md](producers.md). Until a producer moves, its new releases
   land only in `stable`. Repeating steps 1 and 2 picks them up: identical
   files are no-ops, and changed bytes under an existing version are refused.
4. **Move clients.** In snosi, change
   `mkosi.sandbox/etc/apt/sources.list.d/frostyard.sources` to the sources
   block in [design/overview.md](../design/overview.md#clients).
5. **Freeze `stable`.** Leave it in place for clients that have not moved.
   Deleting it is a separate decision.

## The Cloudflare cache rules

The `frostyard.org` zone has one Cache Rule, `apt immutable`:

- Custom filter expression:
  `http.host eq "repository.frostyard.org" and (starts_with(http.request.uri.path, "/debian/pool/") or (starts_with(http.request.uri.path, "/debian/dists/") and http.request.uri.path contains "/by-hash/"))`.
- Cache eligibility: Eligible for cache.
- Edge TTL: ignore cache-control header, 1 year, plus a Status code TTL of
  `no-store` for status codes 400 and up, so errors are never cached.
- Browser TTL: Respect origin. apt gains nothing from browser caching, and
  overriding would give proxies such as apt-cacher-ng long lifetimes for
  error responses.

Why that is safe: pool files never change under the same name (the publisher
refuses different bytes for an existing version), and `by-hash` paths are
content-addressed.

- The mutable indexes (`InRelease`, `Release`, `Release.gpg`, `Packages*`)
  stay uncached. `scripts/purge-cache.sh` still purges them after each
  publish, as a safety net.
- Checked: a `by-hash` index and `frostyard-updex_2.0.2_amd64.deb` returned
  `MISS`, then `HIT`. A missing file returned `BYPASS` twice. `InRelease`
  returned `DYNAMIC`.
- Keep any later rule in the zone from matching these paths with "Bypass
  cache": a later matching rule overrides this one.

## Re-run the R2 trial

For example after upgrading aptly or rclone.

- Run it from a workstation, against real R2 under `APT_PREFIX=debian-test`
  and `APT_STATE_PATH=aptly-test`.
- Set `APT_PUBLIC_URL=https://repository.frostyard.org/debian-test` too, or
  the canary and the purge check `/debian`.
- Steps:
  1. Fetch a release and verify its attestations.
  2. Dry run, then publish to trixie and forky.
  3. `scripts/verify.sh --deep` both codenames, purge, then run the canary.
  4. Withdraw one build from forky.
  5. `scripts/switch.sh` back to the first forky snapshot.
  6. Remove both test prefixes.
- Import the key into a throwaway `GNUPGHOME`, and give each script a fresh
  `APTLY_ROOT`.
- There is no committed trial script: `tests/run.sh` runs the same
  operations against a local S3 server.
