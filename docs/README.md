# Documentation

Docs are split by the question they answer:

| Directory | Question | Contents |
| --- | --- | --- |
| [adr/](adr/) | **Why** did we choose this? | Architecture Decision Records: immutable once accepted; superseded, never edited |
| [design/](design/) | **How** does it fit together? | Living documents describing the current architecture |
| [specs/](specs/) | **What exactly** is the contract? | Precise, testable interface definitions |
| [plans/](plans/) | **When/in what order** do we build? | Roadmaps and phase plans; updated as work lands |
| [runbooks/](runbooks/) | **What do I type now?** | Operations, producer onboarding and development procedures |

## Index

### Org-wide decisions

- [org-adrs.md](org-adrs.md): the frostyard/core ADRs that bind this repository, and what each one binds here.

### Decisions (ADRs)

- [0001 — Publish Debian packages through one aptly writer](adr/0001-aptly-single-writer.md)
- [0002 — Publish two components per codename](adr/0002-two-components-per-codename.md)
- [0003 — Keep the newest versions of a producer](adr/0003-keep-the-newest-versions-of-a-producer.md)
- [0004 — Pin the signer workflow of attested producers](adr/0004-pin-the-signer-workflow-of-attested-producers.md)

### Design

- [overview.md](design/overview.md): the publishing flow, the buckets, the components, the security model.
- [tool-behavior.md](design/tool-behavior.md): what aptly, rclone, apt, Cloudflare and R2 do that the scripts rely on.

### Specs

- [producer-interface.md](specs/producer-interface.md): the `publish-deb` dispatch, the registration files, version markers and the `build` dispatch.

### Plans

No local plan yet. The order of the remaining work is core
[Plan 0009](https://github.com/frostyard/core/blob/main/docs/plans/0009-debian-publication-through-apt-publisher.md).

### Runbooks

- [operations.md](runbooks/operations.md): one-time setup, publication, withdrawal, retention, rollback, move, recovery, the cache rules.
- [producers.md](runbooks/producers.md): add, change or retire a producer.
- [development.md](runbooks/development.md): the tools, `make verify`, and what the end-to-end test does.

## Conventions

- **New docs start from their category's `TEMPLATE.md`** (in each directory).
- New decision → new ADR with the next number; if it reverses an old one, mark
  the old one `Superseded by NNNN` rather than editing it.
- Design docs are updated in place to always reflect reality.
- Specs change only alongside the code that implements them.
- Cross-links between categories are mandatory in both directions: see the
  documentation rules in [AGENTS.md](../AGENTS.md) (CLAUDE.md, GEMINI.md,
  `.cursorrules` and `.github/copilot-instructions.md` are symlinks to it,
  core ADR-0018).
- Adding a doc means adding it to the index above.
- The root [README.md](../README.md) is the front page. It follows core's
  [README spec](https://github.com/frostyard/core/blob/main/docs/specs/readme.md)
  (kind `packaging`, at most 1000 words); the details live here.
