#!/usr/bin/env bash
# Import the repository signing key from APT_SIGNING_KEY (an armored secret
# key) and confirm it is the key named by APT_SIGNING_KEY_FPR.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

: "${APT_SIGNING_KEY:?APT_SIGNING_KEY is required}"
require gpg
gpg --batch --quiet --import <<<"$APT_SIGNING_KEY"
gpg --batch --list-secret-keys --with-colons "$APT_SIGNING_KEY_FPR" 2>/dev/null | grep -q '^sec' ||
	die "APT_SIGNING_KEY does not hold the secret key $APT_SIGNING_KEY_FPR"
log "imported signing key $APT_SIGNING_KEY_FPR"
