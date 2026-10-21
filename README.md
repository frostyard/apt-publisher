# apt-publisher

The single writer for Frostyard's APT repository, built on
[aptly](https://www.aptly.info/). Producer repositories stop publishing
`.deb` files themselves. Instead they send a dispatch, and this repository's
workflow publishes the release to
`https://repository.frostyard.org/debian`, under explicit codenames
(`trixie`, `forky`).

> **Status: in production since 2026-10-02.** It publishes `trixie` and
> `forky` at `https://repository.frostyard.org/debian/`. The order of the
> remaining work is in core
> [Plan 0009](https://github.com/frostyard/core/blob/main/docs/plans/0009-debian-publication-through-apt-publisher.md).

It replaces repogen's `publish-to-r2` Debian path. That path is already
disabled ("Debian publication requires the reviewed target-scoped
production writer"), and many producer repositories used it to
read-modify-write one shared index with no lock.

## How a release is published

```
producer tag ─► goreleaser ─► GitHub release (.deb + build provenance)
        │
        └─ repository_dispatch "publish-deb" {repo, tag, codenames?}
                │
                ▼
   publish.yml   (concurrency group "apt-repository", queue: max: one writer,
                  up to 100 queued runs)
     fetch-release.sh   download the release's .deb assets, gh attestation verify
     publish.sh         validate ─► reconcile state with the bucket ─► aptly add
                        ─► snapshot ─► record pending + save ─► publish switch
                        ─► clear pending + save ─► read back from the bucket
     purge-cache.sh     purge InRelease/Release/Packages from the Cloudflare cache
     apt-canary.sh      apt-get update + download of each new package through
                        the public URL
     notify.sh          dispatch `build` to downstream repositories (snosi)
```

GitHub's default concurrency queue holds one pending run and cancels older
ones. Every writer workflow sets `queue: max` instead, so up to 100 runs wait
their turn. A failed or cancelled run keeps its payload and can be re-run
from the Actions page. The nightly **audit** workflow catches anything that
still slips through, such as a producer whose dispatch step failed: it
reports every latest-release `.deb` that no codename lists.

Bucket layout (`frostyardrepo`):

```
debian/dists/trixie/   signed InRelease, by-hash indexes, amd64 arm64 all
debian/dists/forky/
debian/pool/main/...   one pool shared by every codename
dists/stable/, pool/   repogen's legacy suite: read by the import, never written
```

aptly's state lives in a private bucket (`frostyard-apt-state/aptly/`).
Each run restores it, as on a fresh runner, and saves it back:

- `db/`: aptly's database. Replaced files are kept under `history/`.
- `pool/`: aptly's package pool, append-only.
- `txn/`: pending markers recording the snapshot a publication was about to
  make visible.

### Keeping state and bucket in step

Before changing a codename, every script compares the packages the bucket
lists with aptly's database. It compares package sets because `Release`
changes on every publication.

- **The bucket matches the published snapshot:** the state is current.
- **The bucket matches the pending snapshot:** an earlier run published but
  died before saving, and the publication is completed. A retry, or any
  other producer's run, converges.
- **Anything else is refused:** lost state, an older database, or another
  writer's change. Inspect it, then recover with `switch.sh --force`, which
  also re-uploads pool files whose bucket copy is corrupted.

### What the publisher refuses

Each of these is covered by `tests/run.sh`:

- requests from a repository not listed in `config/producers.tsv`;
- packages that don't match the producer's name globs, so updex cannot
  publish `bootc`;
- codenames the producer isn't allowed, and architectures the codename
  doesn't publish;
- a `~deb14` build targeted at trixie (see [Codenames](#codenames-and-versions));
- a name/version/arch that is already published with different bytes;
- publishing when the bucket doesn't match aptly's database: lost or older
  state, a tampered index, another writer;
- importing anything outside the reviewed, verified manifest;
- deleting pool files: every switch uses `-skip-cleanup`, so rollbacks and
  withdrawals leave files in place.

Every publish is read back from the bucket:

- the InRelease signature against `keys/frostyard.gpg`;
- each `Packages` hash against `Release`;
- each expected `name=version`, with its file downloaded and checked
  against its SHA256.

Rollbacks and imports also run the deep check: every file the codename lists
must be in the bucket with the index's MD5. Finally, the canary installs the
new packages with apt through the public URL.

## Producer integration

Taking updex as the example, replace the "Publish to frostyard repo" and
"Kickoff snosi" steps in `.github/workflows/release.yml` with:

```yaml
      - name: Request APT publication
        uses: peter-evans/repository-dispatch@28959ce8df70de7be546dd1250a005dd32156697 # v4
        with:
          token: ${{ secrets.APT_PUBLISH_TOKEN }}
          repository: frostyard/apt-publisher
          event-type: publish-deb
          client-payload: '{"repo": "${{ github.repository }}", "tag": "${{ github.ref_name }}"}'
```

- **Token:** `APT_PUBLISH_TOKEN` needs Contents read/write on
  `frostyard/apt-publisher` only, which is what `repository_dispatch` requires.
  Producers no longer hold the GPG key or R2 credentials.
- **Snosi trigger:** the snosi build is now dispatched by the publisher, after
  the packages are live.
- **Provenance:** updex already attests its `.deb` files.
- **Registration:** add the producer to `config/producers.tsv`. Producers
  that don't attest yet use `attested=no` until they add
  `actions/attest-build-provenance`.

## Codenames and versions

| Codename | Debian | Architectures |
| --- | --- | --- |
| trixie | 13 | amd64, arm64, all |
| forky | 14 | amd64, arm64, all |

- **Statically linked packages** (updex, `CGO_ENABLED=0`) use plain versions.
  The same file goes into every target codename and is stored once.
- **Packages linked against distribution libraries** (bootc, libostree,
  incus, ...) are built once per codename. Their versions carry a marker:
  `1.16.8-1~deb13` and `1.16.8-1~deb14`.
  - The publisher routes each build to the matching codename only.
  - `~deb13` sorts below `~deb14`, so upgrading from trixie to forky picks up
    the forky build.
  - GitHub lists release assets with `.` in place of `~`
    (`bootc_1.16.8-1.deb13_amd64.deb`). Routing reads the version from the
    package, and the audit compares `~` as `.`.
  - incus is the exception for now. Its versions
    (`1:7.5.1-debian13-202610031200`) carry `-debian13-`, which is not a
    marker, so it is registered for `trixie` only until they carry `~deb13`
    or `~deb14`.

Clients:

```
Types: deb
URIs: https://repository.frostyard.org/debian/
Suites: trixie
Components: main
Signed-By: /etc/apt/keyrings/frostyard.gpg
```

The signing key is the one that signs the legacy suite, so existing
keyrings keep working.

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
   - `DISPATCH_TOKEN` (repository_dispatch to the `notify` repositories).
4. Run **check-secrets**. It checks every secret without publishing:
   - the signing key's fingerprint, that it signs without a passphrase, and
     that `keys/frostyard.gpg` verifies the signature;
   - that R2 can list both buckets (read-only, so write access is first
     proven by a publication);
   - that Cloudflare purges one `dists/` URL from the zone;
   - that `DISPATCH_TOKEN` can dispatch to each `notify` repository. It sends
     event type `apt-publisher-token-check`, which starts nothing as long as
     those repositories' `repository_dispatch` triggers filter on `types`.

## Migrating from repogen

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
3. **Move producers** one at a time to the dispatch step above, adding each
   to `config/producers.tsv`. Until a producer moves, its new releases land
   only in `stable`. Repeating steps 1 and 2 picks them up: identical files
   are no-ops, and changed bytes under an existing version are refused.
4. **Move clients.** In snosi, change
   `mkosi.sandbox/etc/apt/sources.list.d/frostyard.sources` to the sources
   block above.
5. **Freeze `stable`.** Leave it in place for clients that haven't moved.
   Deleting it is a separate decision.

## Operations

- **Withdraw one version:** run **withdraw** with a codename, package and
  version, plus an architecture if needed.
  - It removes that version from the working repository and publishes a new
    snapshot; everything else stays published.
  - The file stays in the pool, and republishing the release brings the
    version back.
  - The audit reports a withdrawn latest release as missing. That's
    expected, and the audit never republishes.
- **Point-in-time rollback:** run **rollback** with a codename and an
  earlier snapshot.
  - It publishes that snapshot and rebuilds the working repository from it,
    so later releases build on the rolled-back contents.
  - Everything published to that codename after the snapshot is unpublished,
    including other producers' packages. Republish a release to roll it
    forward.
  - With the snapshot left empty, it lists snapshots, publications and
    pending markers instead.
- **Recovery:** when a run refuses because the bucket doesn't match aptly's
  database, inspect what changed first.
  - Then run **rollback** with `force` and the snapshot the bucket should
    serve.
  - This republishes it regardless of the mismatch and re-uploads any pool
    file whose bucket copy differs.
- **Health check** (needs R2 credentials):
  `scripts/verify.sh trixie --deep frostyard-updex=2.0.2`.
- **Install check** through the public URL:
  `scripts/apt-canary.sh trixie amd64 frostyard-updex=2.0.2`.
- **Missed releases:** `scripts/audit-producers.sh`, run nightly by
  **audit**.
- **Secrets:** run **check-secrets** after setting or rotating one.
- **Routing check** without credentials:
  `scripts/publish.sh --producer frostyard/updex --debs ./dist --dry-run`.

## Development

```sh
mise install   # aptly, rclone, shellcheck, actionlint, jq
make verify    # shellcheck, actionlint, config checks, end-to-end test
```

The end-to-end test also needs `gpg`, `gpgv`, `dpkg-deb`, `apt-get`,
`curl` and `python3`, which Debian and the Ubuntu runners already have.
`tests/run.sh` does the following:

- starts `rclone serve s3` on a free port and creates a throwaway signing
  key;
- builds a repogen-shaped legacy suite;
- runs every script as a fresh runner;
- checks the published result with `apt-get update` / `apt-cache policy` and
  the canary's `apt-get download` in a sandboxed apt root;
- simulates the failures it guards against: a stale database, an
  interrupted publication (an `rclone` shim that fails a save), leftover
  import files, corrupted pool files and tampered indexes;
- runs the audit against a stubbed `gh`, and the secrets check against
  stubbed `curl` and `gh`.

`KEEP_TMP=1` keeps its work directory for inspection.

## Production notes

- **R2:** done 2026-10-02. A trial against real R2 under a scratch prefix
  passed publish, deep verify, a CDN canary, withdraw, rollback and a cache
  purge (core Plan 0009, Phase 1).
- **CDN:** done 2026-10-03. The Cache Rule `apt immutable` caches
  `/debian/pool/` and `by-hash` paths at the edge; `InRelease`, `Release` and
  `Packages*` stay uncached (core Plan 0009, Phase 3).
- **actionlint:** actionlint (1.7.12 included) doesn't know the
  concurrency `queue` key yet, so `.github/actionlint.yaml` ignores that one
  error. `tests/check-config.sh` asserts every workflow using the
  `apt-repository` environment sets it.
- **Restore cost:** each run restores the whole state pool, about 3 GiB
  after the import. aptly reads a pool file only when a snapshot references
  a package the bucket lacks, so a database-only restore with on-demand pool
  fetches is a possible later optimisation.
- **ADR:** core
  [ADR-0055](https://github.com/frostyard/core/blob/main/docs/adr/0055-publish-debian-packages-through-the-apt-publisher.md)
  records the organization decision.
  [ADR-0001](docs/adr/0001-aptly-single-writer.md) records this repository's
  side.
