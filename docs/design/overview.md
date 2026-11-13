# Publishing pipeline

Index: [docs/README.md](../README.md).
Living document. Rationale: [ADR-0001](../adr/0001-aptly-single-writer.md),
[ADR-0002](../adr/0002-two-components-per-codename.md),
[ADR-0003](../adr/0003-keep-the-newest-versions-of-a-producer.md),
[ADR-0004](../adr/0004-pin-the-signer-workflow-of-attested-producers.md),
core [ADR-0055](https://github.com/frostyard/core/blob/main/docs/adr/0055-publish-debian-packages-through-the-apt-publisher.md),
core [ADR-0056](https://github.com/frostyard/core/blob/main/docs/adr/0056-rebuild-images-after-apt-publication.md),
core [ADR-0059](https://github.com/frostyard/core/blob/main/docs/adr/0059-publish-image-only-packages-in-a-separate-apt-component.md),
core [ADR-0067](https://github.com/frostyard/core/blob/main/docs/adr/0067-publish-omarchy-apps-on-change-and-keep-the-newest-two.md).
Contracts: [specs/producer-interface.md](../specs/producer-interface.md).
Runbooks: [runbooks/operations.md](../runbooks/operations.md),
[runbooks/producers.md](../runbooks/producers.md).

## Overview

This repository is the single writer of the Frostyard APT repository at
`https://repository.frostyard.org/debian`. Producer repositories stop
publishing `.deb` files themselves. Instead they send a `publish-deb`
dispatch, and this repository's workflow publishes their release under
explicit codenames (`trixie`, `forky`). aptly does the publishing; the bash
scripts in `scripts/` hold the policy; the GitHub workflows call them.

It replaces repogen's `publish-to-r2` Debian path, which many producer
repositories used to read-modify-write one shared index with no lock.

```
producer tag -> goreleaser -> GitHub release (.deb + build provenance)
        |
        +- repository_dispatch "publish-deb" {repo, tag, codenames?}
                |
                v
   publish.yml   (concurrency group "apt-repository", queue: max: one writer,
                  up to 100 queued runs)
     fetch-release.sh   download the release's .deb assets, gh attestation verify
                        with the producer's signing workflow and ref (ADR-0004)
     publish.sh         validate -> reconcile state with the bucket -> aptly add
                        -> snapshot -> record pending + save -> publish switch
                        -> clear pending + save -> read back from the bucket
     purge-cache.sh     purge InRelease/Release/Packages from the Cloudflare cache
     apt-canary.sh      apt-get update + download of each new package through
                        the public URL; retries a stale index and a transient
                        fetch, fails at once on a 404 or a bad hash
     notify.sh          dispatch `build` to downstream repositories (snosi)
```

## Design

### The writer and its queue

GitHub's default concurrency queue holds one pending run and cancels older
ones. Every writer workflow (`publish`, `withdraw`, `rollback`, `move`,
`import-stable`) sets `queue: max` instead, so up to 100 runs wait their
turn. A failed or cancelled run keeps its payload and can be re-run from the
Actions page. `check-secrets.yml` holds the same credentials, so it queues in
the same group.

The nightly **audit** workflow catches anything that still slips through,
such as a producer whose dispatch step failed: it reports every latest-release
`.deb` that no codename lists. It also runs the Debian-name audit
(`scripts/audit-debian-names.sh`, core ADR-0059): it prints
`DEBIAN-NAME codename package suites` for each package in `main` whose name
Debian ships in the codename's suite, `-updates`, `-security` or `-backports`.
Such a package belongs in `image`. The audit is report-only; moving a producer
is a reviewed registration change. It trusts HTTPS and the hashes in Debian's
`Release` file, not Debian's signature, and a failed fetch or hash mismatch
fails it rather than reading as "no names".

### Bucket layout

The public bucket is `frostyardrepo`:

```
debian/dists/trixie/   signed InRelease, by-hash indexes, amd64 arm64 all
debian/dists/forky/
debian/pool/main/...   one pool shared by every codename
debian/pool/image/...  the image component's files, once a codename publishes it
dists/stable/, pool/   repogen's legacy suite: read by the import, never written
```

### State bucket

aptly's state lives in a private bucket (`frostyard-apt-state/aptly/`). Each
run restores it, as on a fresh runner, and saves it back:

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

### Transient R2 publication errors

`aptly_publish_retry` wraps only `publish switch`, `publish update` and
`publish snapshot`. It repeats the same command, not source staging or
state saves. `APT_PUBLISH_RETRY_DELAYS` sets the delays in seconds. Its
default, `10 30`, allows 3 tries. An empty value disables retries. Every
word must be a non-negative integer. Initialization checks the value before
it restores or changes state.

A retry needs a line that starts with `ERROR: unable to publish:` and has
an R2 transient marker on that same line: `StatusCode: 5xx`, exhausted
attempts, `i/o timeout`, `context deadline exceeded`, `TLS handshake timeout`
or `connection reset by peer`. A `StatusCode: 4xx` on that line prevents a
retry, including 429. Signing, validation and database errors do not retry.
Each retry logs its try number and delay. The helper captures only stderr;
stdout passes through. aptly's stderr appears in the log only after each try
ends, so cancellation during a long publish loses that try's stderr.

A final failure returns aptly's last exit code unchanged. Pending markers,
move markers and state saves stay unchanged, so recovery is the same: a
rerun completes the publication. See [tool-behavior.md](tool-behavior.md)
for the aptly guarantees that make the retry safe and rclone's own retries.

### What the publisher refuses

Each of these is covered by `tests/run.sh`:

- requests from a repository not listed in `config/producers.tsv`;
- packages that do not match the producer's name globs, so updex cannot
  publish `bootc`;
- codenames the producer is not allowed, and architectures the codename does
  not publish;
- a producer registered for a component (`image`) that the codename does not
  publish (see [Components](#components));
- a package name that the codename already publishes in the other component;
- a `~deb14` build targeted at trixie (see
  [Codenames and versions](#codenames-and-versions));
- a name/version/arch that is already published with different bytes;
- a release whose own packages are older than the newest N the producer keeps
  ([runbooks/operations.md](../runbooks/operations.md)): the rule would
  withdraw them at once;
- publishing when the bucket does not match aptly's database: lost or older
  state, a tampered index, another writer, or a different set of components;
- importing anything outside the reviewed, verified manifest;
- deleting pool files: every switch uses `-skip-cleanup`, so rollbacks and
  withdrawals leave files in place.

### Read-back

Every publish is read back from the bucket:

- the InRelease signature against `keys/frostyard.gpg`, and its
  `Components:` against the configuration;
- each component's `Packages` hash against `Release`;
- each expected `component/name=version`, with its file downloaded and
  checked against its SHA256.

Rollbacks and imports also run the deep check: every file the codename lists,
in every component, must be in the bucket with the index's MD5. Finally, the
canary installs the new packages with apt through the public URL.

### Codenames and versions

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
  - incus is the exception on trixie. Its Debian 13 versions
    (`1:7.6-debian13-202611131200`) carry `-debian13-`, which is not a
    marker, so they would go to every target; its Debian 14 versions carry
    `~deb14` (`1:7.6-debian14-202611131200~deb14`). incus releases each
    codename's build on its own, and each request names its codename.

### Components

A codename can publish two components, under one signed `Release` (core
[ADR-0059](https://github.com/frostyard/core/blob/main/docs/adr/0059-publish-image-only-packages-in-a-separate-apt-component.md)):

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
- A first publication of a codename publishes every configured component; the
  ones without packages start empty.
- A publication switches only its producer's component, in one `Release`.
- A rollback takes one snapshot per component; a component the codename does
  not publish yet is added empty. It refuses a snapshot that puts a package
  name in a component other than its producer's registered one (see
  [Moving packages between components](#moving-packages-between-components)).

`trixie` and `forky` publish `main,image`. frostyard/bootc-debian (`bootc`,
`libostree-1-1`) and frostyard/incus (`incus`, `incus-base`, `incus-client`,
`incus-extra`, `incus-ui-canonical`) are registered for `image` (core
ADR-0059 step 5): their builds replace Debian packages of the same name, or
depend on those replacements (`bootc`, `incus-ui-canonical`). Every other
producer is `main`. The versions they published to `main` before the
registration move with the move workflow below.

`publish switch` cannot add a component; a configured component that a
published codename lacks is added, empty, by the next publication run
(`publish source add` + `publish update`, in one signed `Release`). A
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
  move marker first (`txn/move-CODENAME`) and saves it **before it moves any
  repository**. The marker holds one `component snapshot` line per changed
  component, with the names the new snapshots will get, and one
  `row NAME VERSION ARCH FROM TO` line per moved package. It is removed only
  after the deep read-back passes. The next run of any script reconciles
  first:
  - If the move became visible, it completes it and drops the marker.
  - If the marker's snapshots are not published (they may not even exist),
    it undoes the move: it rebuilds the changed working repositories from the
    published snapshots, drops the marker, and logs that an interrupted move
    was undone. Run the move again.
  Without this, a publication that waited in the queue would switch one
  component only and strand the move in the other: the names would leave
  `main` and never reach `image`. `switch.sh --list` prints a marker as
  `move pending: CODENAME component=snapshot ...`, and `switch.sh --force`
  drops it.
- **A retry of a recovered move is not silent.** When the reconciliation of a
  `move.sh` run completes an earlier move, that run reads it back with the
  deep check, prints its codename and writes its report rows, so the
  workflow purges the CDN cache and runs the canary.
- **If a step after Move fails, or a retry is green with nothing to move, run
  the workflow with `recheck=true`** (and `dry_run=false`). `move.sh
  --recheck` changes nothing and needs no signing key: it runs the deep
  read-back, prints each published codename with its snapshots, and reports
  the newest version of each package in `image`. The workflow then purges the
  cache and runs the canary. A dry run and a recheck cannot be combined.
- A missing or unreadable `config/producers.tsv` is an error: the move and the
  rollback guard fail closed instead of reading it as "no registered
  producer".
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

### Published key

The binary keyring `keys/frostyard.gpg` is served at
`https://repository.frostyard.org/debian/frostyard.gpg`, and hosts install
it directly as `/etc/apt/keyrings/frostyard.gpg` (core ADR-0059). This
repository is its only writer. Every publication (publish, withdraw,
rollback, import) uploads it first when the bucket copy is missing or
differs, so a failed upload changes no state. Every publication and
`scripts/verify.sh` read it back and compare the bytes. The cache purge lists
its URL, and the producer audit reports `MISSING key` or `MISMATCH key`. The
legacy `/public.key` stays unchanged and is not touched.

The key is the one that signs the legacy `stable` suite, so existing keyrings
keep working.

### Clients

A Debian host adds the repository with these fields:

```
Types: deb
URIs: https://repository.frostyard.org/debian/
Suites: trixie
Components: main
Signed-By: /etc/apt/keyrings/frostyard.gpg
```

A host that needs the image component replaces `Components: main` with
`Components: main image`.

## Operational notes

- **R2 and the trial.** A trial against real R2 under a scratch prefix passed
  publish, deep verify, a CDN canary, withdraw, rollback and a cache purge
  (core Plan 0009, Phase 1). See
  [runbooks/operations.md](../runbooks/operations.md) to run it again.
- **CDN rule.** The Cache Rule `apt immutable` caches `/debian/pool/` and
  `by-hash` paths at the edge; `InRelease`, `Release`, `Release.gpg` and
  `Packages*` stay uncached, and `scripts/purge-cache.sh` purges them after
  every publication as a safety net. The rule's configuration is in
  [runbooks/operations.md](../runbooks/operations.md).
- **actionlint** does not know the concurrency `queue` key yet, so
  `.github/actionlint.yaml` ignores that one error. `tests/check-config.sh`
  asserts every workflow that uses the `apt-repository` environment sets it.

### Known limitations, accepted for now

- **Restore cost.** Every run restores the whole state pool, about 3 GiB
  after the import. Restoring the database only, and fetching pool files on
  demand, is a possible optimisation.
- **Audit heuristics.** It parses `name_version_arch.deb` asset names and
  checks only each producer's latest release. It counts an asset as
  published if any of the producer's codenames lists it. It reports withdrawn
  latest releases as missing, by design.
- **Point-in-time rollback** also unpublishes other producers' later
  packages until they are republished. Use withdraw for a single bad
  version.
- **Withdrawn versions come back** if the same release is republished. There
  is no blocklist.
- **`switch.sh --force`** overwrites the bucket with aptly's view and
  re-uploads differing pool files. Run it only after inspecting the refusal.

### Security model

- **`main` is protected.** The "Protect main" ruleset requires a pull request
  (0 approvals) and blocks force-pushes and deletion on `main`, with no
  bypass. It exists because `APT_PUBLISH_TOKEN` needs Contents: write here,
  which would otherwise let a leaked token push a workflow to `main`, where
  the secrets live.
- **An organization ruleset also requires a review.** "default branch: humans
  merge" requires 1 approving review on every repository's default branch,
  including approval of the last push. Org admins can bypass it. Agents open
  pull requests and humans merge them. Pull requests authored under the
  owner's account cannot be self-approved, so they merge only through the
  admin bypass.
- **The `apt-repository` environment is limited to `main`.** It holds the
  signing key, the R2 credentials, the Cloudflare token and the dispatch
  token, so a workflow run from another ref cannot read them.
- **`APT_PUBLISH_TOKEN` is an org secret visible to every producer.** It
  needs Contents read/write on this repository only, which is what
  `repository_dispatch` requires. Producers hold no GPG key and no R2
  credentials.

## References

- Rationale: [ADR-0001](../adr/0001-aptly-single-writer.md),
  [ADR-0002](../adr/0002-two-components-per-codename.md),
  [ADR-0003](../adr/0003-keep-the-newest-versions-of-a-producer.md),
  [ADR-0004](../adr/0004-pin-the-signer-workflow-of-attested-producers.md),
  [docs/org-adrs.md](../org-adrs.md)
- Contracts: [specs/producer-interface.md](../specs/producer-interface.md)
- Operations: [runbooks/operations.md](../runbooks/operations.md),
  [runbooks/producers.md](../runbooks/producers.md)
- Built in: core [Plan 0009](https://github.com/frostyard/core/blob/main/docs/plans/0009-debian-publication-through-apt-publisher.md)
