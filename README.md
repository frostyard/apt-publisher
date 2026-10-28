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
debian/pool/image/...  the image component's files, once a codename publishes it
dists/stable/, pool/   repogen's legacy suite: read by the import, never written
```

aptly's state lives in a private bucket (`frostyard-apt-state/aptly/`).
Each run restores it, as on a fresh runner, and saves it back:

- `db/`: aptly's database. Replaced files are kept under `history/`.
- `pool/`: aptly's package pool, append-only.
- `txn/`: pending markers recording the snapshot a publication was about to
  make visible, one per component (`pending-trixie`, `pending-trixie-image`),
  and a move marker while a move runs (`move-trixie`; see
  [Moving packages between components](#moving-packages-between-components)).

### Keeping state and bucket in step

Before changing a codename, every script compares the packages the bucket
lists with aptly's database, for every component the codename publishes. It
compares package sets because `Release` changes on every publication. The
bucket's `Release` must also list exactly the configured components, or,
while a configured component is being added, exactly the components aptly's
database publishes.

- **Every component matches its published snapshot:** the state is current.
- **Every component matches its published or its pending snapshot:** an
  earlier run published but died before saving, and the publication is
  completed. A retry, or any other producer's run, converges.
- **Anything else is refused:** lost state, an older database, another
  writer's change, or a bucket that serves other components than the
  configuration. Inspect it, then recover with `switch.sh --force`, which
  also re-uploads pool files whose bucket copy is corrupted.

### What the publisher refuses

Each of these is covered by `tests/run.sh`:

- requests from a repository not listed in `config/producers.tsv`;
- packages that don't match the producer's name globs, so updex cannot
  publish `bootc`;
- codenames the producer isn't allowed, and architectures the codename
  doesn't publish;
- a producer registered for a component (`image`) that the codename doesn't
  publish (see [Components](#components));
- a package name that the codename already publishes in the other component;
- a `~deb14` build targeted at trixie (see [Codenames](#codenames-and-versions));
- a name/version/arch that is already published with different bytes;
- publishing when the bucket doesn't match aptly's database: lost or older
  state, a tampered index, another writer, or a different set of components;
- importing anything outside the reviewed, verified manifest;
- deleting pool files: every switch uses `-skip-cleanup`, so rollbacks and
  withdrawals leave files in place.

Every publish is read back from the bucket:

- the InRelease signature against `keys/frostyard.gpg`, and its
  `Components:` against the configuration;
- each component's `Packages` hash against `Release`;
- each expected `component/name=version`, with its file downloaded and
  checked against its SHA256.

Rollbacks and imports also run the deep check: every file the codename lists,
in every component, must be in the bucket with the index's MD5. Finally, the canary installs the
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

| Codename | Debian | Architectures | Components |
| --- | --- | --- | --- |
| trixie | 13 | amd64, arm64, all | main, image |
| forky | 14 | amd64, arm64, all | main, image |

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

## Components

A codename can publish two components, under one signed `Release`
([ADR-0059](https://github.com/frostyard/core/blob/main/docs/adr/0059-publish-image-only-packages-in-a-separate-apt-component.md)):

- `main`: packages for any Debian host.
- `image`: builds that Frostyard images need instead of Debian's packages of
  the same name.

How it works:

- `config/codenames.tsv` column 4, `components`, lists what a codename
  publishes: `main` or `main,image`.
- `config/producers.tsv` column 6, `component`, says where a producer's
  packages go: `main` or `image`. The producer must be registered only for
  codenames that publish that component.
- **One component per name:** a codename publishes a package name in one
  component only. A publication of a name that the codename already has in
  the other component is refused.
- Each component has its own working repository (`frostyard-trixie`,
  `frostyard-trixie-image`), snapshots (`trixie-TIME-LABEL`,
  `trixie-image-TIME-LABEL`), pending marker and pool path.
- A first publication of a codename publishes every configured component;
  the ones without packages start empty.
- A publication switches only its producer's component, in one `Release`.
- A rollback takes one snapshot per component; a component the codename does
  not publish yet is added empty. It refuses a snapshot that puts a package
  name in a component other than its producer's registered one (see
  [Moving packages between components](#moving-packages-between-components)).

`trixie` and `forky` publish `main,image`. frostyard/bootc-debian (`bootc`,
`libostree-1-1`) and frostyard/incus (`incus`, `incus-base`, `incus-client`,
`incus-extra`, `incus-ui-canonical`) are registered for `image` (ADR-0059
step 5): their builds replace Debian packages of the same name. Every other
producer is `main`. The versions they published to `main` before the
registration move with the move workflow below.

The live codenames published `main` only. The first publication run after
this change adds each missing configured component to them, empty: it writes
it with `publish source add` and `publish update`, in one signed `Release`.
That run can be a publication, a withdrawal, a rollback or an import, and a
publication also adds the component to the codenames it does not target.
Later runs switch as before. `publish switch` cannot add a component, and a
configuration that removes a component from a published codename is refused.

### Moving packages between components

When a producer's registration changes component, the **move** workflow
(`scripts/move.sh`) moves its published packages to the new component:

- It moves every published version of every architecture whose component
  differs from its producer's registration. Names without a registered
  producer stay where they are. No package version changes.
- Each codename gets one publication: the names leave one component and
  appear in the other in one signed `Release`, as one recoverable
  transaction like any publication.
- It runs in the `apt-repository` concurrency group. **Run it with
  `dry_run` first**: it prints the plan, one
  `move CODENAME NAME VERSION ARCH FROM -> TO` line per package, and changes
  nothing. The live run reads the result back (deep check), purges the CDN
  cache and runs the canary on the newest moved version of each package.
- **A move that dies is settled by the next run.** A move changes two
  components and saves its repositories before it publishes, so it writes a
  move marker first (`txn/move-CODENAME`, one `component snapshot` line per
  changed component) and removes it after it. The next run of any script
  reconciles first. If the move became visible, it completes it and drops
  the marker. If it never became visible, it undoes it: it rebuilds the
  changed working repositories from the published snapshots, drops the
  marker, and logs that an interrupted move was undone. Run the move again.
  Without this, a publication that waited in the queue would switch one
  component only and strand the move in the other: the names would leave
  `main` and never reach `image`. `switch.sh --list` prints a marker as
  `move pending: CODENAME component=snapshot ...`, and `switch.sh --force`
  drops it.
- It starts from what the bucket serves: a working repository that differs
  from its published snapshot is refused. `--rebuild` rebuilds it from the
  published snapshot after a run that died between saving and publishing.
- **No pool file is deleted.** The files under `pool/main` stay; aptly
  uploads copies under `pool/image`.
- A publication between a registration change and the move fails on the
  one-component rule; run it again after the move.
- **Revert by a forward change.** Register the producer for its old
  component and run the move again: it moves the names back. A snapshot
  taken before a move is not a rollback target: `switch.sh` refuses it, also
  with `--force`, because it would put a name back in the component its
  producer left.

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
  - It removes that version from the working repository of the component
    that holds it and publishes a new snapshot of that component; everything
    else stays published.
  - The file stays in the pool, and republishing the release brings the
    version back.
  - The audit reports a withdrawn latest release as missing. That's
    expected, and the audit never republishes.
- **Point-in-time rollback:** run **rollback** with a codename and earlier
  snapshots, one for each component the codename publishes, separated by
  spaces. A codename that publishes only `main` takes one. Snapshots that
  put a name in a component other than its producer's registered one, such
  as snapshots from before a move, are refused.
  - It publishes those snapshots and rebuilds the working repositories from
    them, so later releases build on the rolled-back contents.
  - Everything published to that codename after the snapshots is
    unpublished, including other producers' packages. Republish a release to
    roll it forward.
  - With the snapshot left empty, it lists snapshots, publications and
    pending markers instead.
- **Move packages between components:** run **move** (`dry_run` is the
  default) after changing a producer's `component`; see
  [Moving packages between components](#moving-packages-between-components).
- **Recovery:** when a run refuses because the bucket doesn't match aptly's
  database, inspect what changed first.
  - Then run **rollback** with `force` and the snapshots the bucket should
    serve.
  - This republishes it regardless of the mismatch and re-uploads any pool
    file whose bucket copy differs.
- **Health check** (needs R2 credentials):
  `scripts/verify.sh trixie --deep frostyard-updex=2.0.2`. A spec can name a
  component, `image/NAME=VERSION`, and `!` asks for absence.
- **Install check** through the public URL:
  `scripts/apt-canary.sh trixie amd64 frostyard-updex=2.0.2`; use
  `trixie/image` for the image component.
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
