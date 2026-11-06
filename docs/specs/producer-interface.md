# Spec: Producer interface

<!--
Specs are precise, testable contracts. They change only alongside the code
that implements them. Use MUST/SHOULD/MAY deliberately.
-->

Index: [docs/README.md](../README.md).

This contract governs how a producer repository asks apt-publisher to publish
its release, and what apt-publisher accepts. It is implemented by
`.github/workflows/publish.yml` and `scripts/fetch-release.sh`,
`scripts/publish.sh` and `scripts/notify.sh`, and enforced by
`tests/check-config.sh` and `tests/run.sh`. Context:
[design/overview.md](../design/overview.md). Operations:
[runbooks/producers.md](../runbooks/producers.md).

## Interface

### The dispatch request

A producer sends a GitHub `repository_dispatch` to `frostyard/apt-publisher`:

```yaml
      - name: Request APT publication
        uses: peter-evans/repository-dispatch@28959ce8df70de7be546dd1250a005dd32156697 # v4
        with:
          token: ${{ secrets.APT_PUBLISH_TOKEN }}
          repository: frostyard/apt-publisher
          event-type: publish-deb
          client-payload: '{"repo": "${{ github.repository }}", "tag": "${{ github.ref_name }}"}'
```

The event type is `publish-deb`. Its `client_payload` holds:

| Field | Type | Required | Constraints |
| --- | --- | --- | --- |
| `repo` | string | yes | `OWNER/NAME` of an entry in `config/producers.tsv` |
| `tag` | string | yes | a release tag of that repository; its release assets hold the `.deb` files |
| `codenames` | array of strings | no | subset of the producer's `codenames` column; default is that whole column |

The same request can be made by hand with the **publish** workflow's
`workflow_dispatch` inputs `repo`, `tag` and `codenames` (space separated).
`publish.yml` passes them to the scripts through `env:`, never through
`${{ }}` inside `run:`.

### The token

`APT_PUBLISH_TOKEN` is an organization secret, visible to every producer. It
MUST need Contents read/write on `frostyard/apt-publisher` only, which is
what `repository_dispatch` requires. A producer holds no GPG key and no R2
credentials.

### `config/producers.tsv`

One tab-separated row per producer, 7 columns. The comment block in the file
is the source of this table.

| Column | Field | Constraints |
| --- | --- | --- |
| 1 | `repository` | GitHub `owner/name` allowed to request publication |
| 2 | `packages` | comma-separated shell globs; every `.deb` in the release MUST match one |
| 3 | `codenames` | comma-separated codenames the producer MAY publish to; also the default when a request names none |
| 4 | `attested` | `no`, or `WORKFLOW@refs/tags/PATTERN`, or `WORKFLOW@refs/heads/BRANCH` (ADR-0004); `yes` is not a valid value |
| 5 | `notify` | comma-separated repositories sent a `build` dispatch after a successful publish, or `-` for none |
| 6 | `component` | `main` or `image`; the one component this producer's packages go to (core ADR-0059) |
| 7 | `keep` | an integer N from 1 to 999, or `-` for no limit (core ADR-0067); a row without column 7 (a test fixture) reads as `-` |

### `config/codenames.tsv`

One tab-separated row per codename, 4 columns:

| Column | Field | Constraints |
| --- | --- | --- |
| 1 | `codename` | `trixie`, `forky` |
| 2 | `debian-major` | the Debian major version: `13`, `14`; unique |
| 3 | `architectures` | comma-separated: `amd64,arm64,all` |
| 4 | `components` | `main`, or `main,image` (core ADR-0059) |

### Version markers

| Version shape | Where it may publish |
| --- | --- |
| plain, for example `2.0.2-1` | any codename the producer lists |
| `NN` in `~debNN` or `+debNN`, for example `1.16.8-1~deb13` | only the codename whose `debian-major` is `NN` |
| anything else, for example `1:7.5.1-debian13-202610031200` | any codename the producer lists |

### The `build` dispatch

After the publication is read back, the cache is purged and the canary
passes, `scripts/notify.sh` sends a
`repository_dispatch` with event type `build` to every repository in the
producer's `notify` column (core
[ADR-0056](https://github.com/frostyard/core/blob/main/docs/adr/0056-rebuild-images-after-apt-publication.md)).
It runs only after a successful publish, so a downstream build always sees
the new packages. When the column is `-`, it sends nothing.

## Rules

- A request from a repository that no row of `config/producers.tsv` names
  MUST be refused, and no state changes.
- Every `.deb` in the release MUST match one of the producer's `packages`
  globs.
- A request MUST name only codenames the producer's row lists, and only
  architectures the codename publishes.
- The producer's `component` MUST be published by every codename it lists.
- With `attested` set, `fetch-release.sh` MUST verify every `.deb` with
  `gh attestation verify --signer-workflow` and `--source-ref`, so both the
  signing workflow and the ref are pinned.
- A version that carries a `~debNN` or `+debNN` marker MUST publish only to
  the codename whose Debian major is `NN`.
- A package name MUST live in one component per codename; a publication of a
  name that the codename already has in the other component MUST be refused.
- A name/version/arch already published with different bytes MUST be
  refused.
- With `keep=N`, the publication that adds newer versions MUST withdraw the
  older ones in the same run, and a publication whose own packages would be
  withdrawn at once MUST be refused before any state change.
- `notify.sh` MUST send `build` only after the publication passed its
  read-back and the canary, and MUST send it to exactly the listed repositories.

## Derived artifacts

| Artifact | Derivation |
| --- | --- |
| `config/producers.tsv`, `config/codenames.tsv` | The routing tables the scripts read; `scripts/lib.sh` (`producer_field`, `codename_field`) reads them. |
| [runbooks/producers.md](../runbooks/producers.md) | The procedure that changes these tables. |
| `tests/check-config.sh` | Checks the shape of both files (7 and 4 columns, value sets, cross rules). |

## References

- Rationale: [ADR-0004](../adr/0004-pin-the-signer-workflow-of-attested-producers.md),
  core [ADR-0055](https://github.com/frostyard/core/blob/main/docs/adr/0055-publish-debian-packages-through-the-apt-publisher.md),
  core [ADR-0059](https://github.com/frostyard/core/blob/main/docs/adr/0059-publish-image-only-packages-in-a-separate-apt-component.md),
  core [ADR-0067](https://github.com/frostyard/core/blob/main/docs/adr/0067-publish-omarchy-apps-on-change-and-keep-the-newest-two.md)
- Context: [design/overview.md](../design/overview.md)
- Operations: [runbooks/producers.md](../runbooks/producers.md)
