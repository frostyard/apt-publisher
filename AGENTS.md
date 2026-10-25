# apt-publisher contributor context

This repository is the single writer of Frostyard's APT metadata at
`repository.frostyard.org/debian`. aptly does the publishing; bash scripts in
`scripts/` hold the policy; GitHub workflows call them. The README explains
the flow and [ADR-0001](docs/adr/0001-aptly-single-writer.md) the decision.

## Invariants

- Only workflows in the `apt-repository` concurrency group (with
  `queue: max`) write the bucket or the state bucket. Do not add another
  writer; `tests/check-config.sh` enforces the group settings.
- Validation runs before any state change. `publish.sh` refuses unknown
  producers, foreign package names, disallowed codenames or architectures,
  and mismatched `~debNN` markers.
- Nothing deletes pool files. Keep `-skip-cleanup` on every switch; deletion
  would be a separate, explicit decision.
- `reconcile_state` must run before any change in every path that can
  publish, and publications go through `commit_publications` (pending marker,
  save, publish, clear, save). Only `switch.sh --force` skips reconciliation.
- Rollback rebuilds the working repository from the snapshot (`rebuild_repo`);
  otherwise the next publication would restore what was rolled back.
- A codename publishes the components in `config/codenames.tsv` (`main`, or
  `main,image`; core ADR-0059). A package name lives in one component per
  codename: `publish.sh` refuses a name that the other component already has.
- `main` keeps its names: repository `frostyard-<codename>`, snapshot
  `<codename>-<time>-<label>`, marker `txn/pending-<codename>`, and the same
  aptly commands. Only `image` adds `-image` to them. Do not change the
  `main` path for a main-only codename.
- Check snapshot existence with `snapshot_exists`, not `aptly snapshot show`,
  which fails once a snapshot's source repository has been rebuilt.
- Secrets arrive only through the environment (`R2_*`, `APT_SIGNING_KEY`,
  `CLOUDFLARE_*`, `GH_TOKEN`). Never write them to `aptly.conf` or logs.
- Request values (`repo`, `tag`, `codenames`) reach scripts through `env:`,
  never through `${{ }}` inside `run:`.

## Gates

`make verify` runs shellcheck, actionlint, `tests/check-config.sh` and the
end-to-end `tests/run.sh`. Tools are pinned in `mise.toml`. Add a test to
`tests/run.sh` for every new refusal or routing rule.
