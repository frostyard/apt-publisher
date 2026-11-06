# Security policy

apt-publisher is a private repository. It is the single writer of the
Frostyard APT repository at `https://repository.frostyard.org/debian/`, which
every Frostyard host installs packages from.

## Reporting a vulnerability

GitHub private vulnerability reporting is not available for a private
repository. Please do not open a public issue, and do not post credentials,
keys or logs that contain them.

- Email the maintainer: bketelsen@gmail.com.
- The repository's Security tab, https://github.com/frostyard/apt-publisher/security,
  shows this policy to collaborators. It has no private report form for a
  private repository, so use email.

Tell us what you can: the component, the version or commit, what an attacker
can do, and the smallest way to reproduce it. We will answer with what we
found and when a fix lands.

If a credential may be exposed, say so in the first line, and rotate it before
you send the details.

## Supported versions

The repository makes no releases. `main` is what runs, and fixes land on
`main`; only the current `main` gets fixes. A published package comes from a
producer's release and is supported by that producer.

## Scope

In scope:

- the signing key, its material in the `apt-repository` environment, and the
  published keyring `keys/frostyard.gpg`;
- producer verification: `scripts/fetch-release.sh`, the attestation policy
  in `config/producers.tsv` column 4, and the routing rules in
  `scripts/publish.sh`;
- the R2 and Cloudflare credentials held in the `apt-repository`
  environment, and the `DISPATCH_TOKEN` that notifies downstream
  repositories;
- the published repository itself: its indexes, its keyring and the paths
  under `https://repository.frostyard.org/debian/`.

Out of scope: a package's own bugs (report those to its producer), and the
legacy repogen `stable` suite, which this repository reads but never writes.
