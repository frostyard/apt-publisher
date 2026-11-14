# apt-publisher contributor context

This repository is the single writer of Frostyard's APT metadata at
`repository.frostyard.org/debian`. aptly does the publishing; bash scripts in
`scripts/` hold the policy; GitHub workflows call them. The README is the
front page; [docs/design/overview.md](docs/design/overview.md) explains the
flow and [ADR-0001](docs/adr/0001-aptly-single-writer.md) the decision;
[ADR-0002](docs/adr/0002-two-components-per-codename.md) records the two
components per codename, the move, the published key and the Debian-name
audit (core ADR-0059), and
[ADR-0004](docs/adr/0004-pin-the-signer-workflow-of-attested-producers.md)
the signing workflow and ref that an attested producer names.

## Invariants

- Only workflows in the `apt-repository` concurrency group (with
  `queue: max`) write the bucket or the state bucket. Do not add another
  writer; `tests/check-config.sh` enforces the group settings.
- Validation runs before any state change. `publish.sh` refuses unknown
  producers, foreign package names, disallowed codenames or architectures,
  and mismatched `~debNN` markers.
- An attested producer's column 4 names its signing workflow and ref;
  `fetch-release.sh` passes `--signer-workflow` and `--source-ref` for every
  `.deb`. `yes` is not a valid value (ADR-0004).
- aptly publish calls that reach R2 go through `aptly_publish_retry`. Retry
  only the transient class on the `ERROR: unable to publish:` line; never
  wrap `publish source add/update`.
- Nothing deletes pool files. Keep `-skip-cleanup` on every switch; deletion
  would be a separate, explicit decision.
- `reconcile_state` must run before any change in every path that can
  publish, and publications go through `commit_publications` (pending marker,
  save, publish, clear, save). Only `switch.sh --force` skips reconciliation.
- The move (`scripts/move.sh`) goes through `reconcile_state` and
  `commit_publications` like every publishing path, and `switch.sh` refuses
  snapshots that contradict a registration (core ADR-0059): a move is
  reverted by a forward change, never by a rollback. It writes a move
  marker (`txn/move-<codename>`, with the snapshot names and the plan) and
  saves it before it moves any repository, and removes it only after the
  deep read-back; `reconcile_state` settles it (drops it when the move is
  visible, undoes it when not), so a later single-component publication
  never strands a move. `registered_component` dies when the producers file
  is unreadable.
- Rollback rebuilds the working repository from the snapshot (`rebuild_repo`);
  otherwise the next publication would restore what was rolled back.
- Removing a producer row stops only new publish runs. A re-run of an old
  publish run checks out its own commit, which still registers the producer,
  and `switch.sh` does not judge names without a producer, so a rollback
  restores them. When a producer retires, its withdrawal batch and the
  retirement record in `docs/runbooks/producers.md` must say that neither path
  may run after the withdrawal; never claim that unregistration alone keeps a
  name out.
- A codename publishes the components in `config/codenames.tsv` (`main`, or
  `main,image`; core ADR-0059). A package name lives in one component per
  codename: `publish.sh` refuses a name that the other component already has.
- A published codename that lacks a configured component gets it, empty,
  from the next publication run (`publish source add` + `publish update`, one
  signed `Release`), also from a publish run that does not target it.
  `publish switch` cannot add a component; removing one is refused.
- `main` keeps its names: repository `frostyard-<codename>`, snapshot
  `<codename>-<time>-<label>`, marker `txn/pending-<codename>`, and the same
  aptly commands. Only `image` adds `-image` to them. Do not change the
  `main` path for a main-only codename.
- Check snapshot existence with `snapshot_exists`, not `aptly snapshot show`,
  which fails once a snapshot's source repository has been rebuilt.
- The canary installs the new `amd64` and `all` packages in a throwaway
  container after the download check passes (`scripts/install-canary.sh`,
  ADR-0007). The container gets only the `CANARY_*` environment values
  (keyring, URL, suite, components): no mount, no secret, no extra privilege,
  and with podman `--http-proxy=false` (podman forwards proxy variables by
  default).
  No setting turns the install check off; tests use a fake runtime.
- Secrets arrive only through the environment (`R2_*`, `APT_SIGNING_KEY`,
  `CLOUDFLARE_*`, `GH_TOKEN`). Never write them to `aptly.conf` or logs.
- Request values (`repo`, `tag`, `codenames`) reach scripts through `env:`,
  never through `${{ }}` inside `run:`.

## Documentation

`docs/README.md` is the index. A decision about this repository gets an ADR in
`docs/adr/`; an org-wide one goes to frostyard/core and is listed in
`docs/org-adrs.md`. The root `README.md` follows core's README spec (kind
`packaging`, at most 1000 words); the flow, the contracts and the runbooks go
in `docs/`.

## Gates

`make verify` runs `make lint` and the end-to-end `tests/run.sh`. `make lint`
runs shellcheck, actionlint, `tests/check-config.sh`, `tests/check-baseline.sh`
and `tests/check-baseline-test.sh`, the baseline check's negative tests. Tools
are pinned in `mise.toml`. Add a test to `tests/run.sh` for every new refusal
or routing rule, and a case to `tests/check-baseline-test.sh` for every new
rule in `tests/check-baseline.sh`: a guard needs a committed test that fails
when the guard is reverted. A PR that touches a path in
`.github/risk-paths.json` gets the label of its strictest matched level
(`level:L1` read every line, `level:L2` read the diff, `level:L3` skim,
`level:L4` title and CI), and `risk:high` at L1 and L2; the workflow also
removes `ready-for-human` when the head moves after the label (core ADR-0077,
ADR-0078). A core org floor can raise the computed level above the entry's
level, and a stricter level label that the PR already has stays (the ratchet);
only the author lowers it, with the reason in the PR. Its body names each
matched path and why the change is safe.
