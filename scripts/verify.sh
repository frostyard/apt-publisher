#!/usr/bin/env bash
# Read a published codename back from the bucket: InRelease signature,
# index hashes, NAME=VERSION listed with intact files, !NAME=VERSION not
# listed, and with --deep every listed pool file present with its MD5.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

(($#)) || {
	echo "usage: verify.sh CODENAME [--deep] [NAME=VERSION | !NAME=VERSION]..." >&2
	exit 2
}
codename_field "$1" 1 >/dev/null || die "unknown codename $1"
require rclone gpgv jq
r2_env
verify_published "$@"
