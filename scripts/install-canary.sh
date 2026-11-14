#!/usr/bin/env bash
# Install check of the canary: install packages with apt-get install in a
# throwaway debian:CODENAME container, with the published keyring and
# APT_PUBLIC_URL as the only Frostyard source, so a package that downloads but
# does not install (a missing dependency, a failing maintainer script, a
# conflict) fails the run. apt-canary.sh calls it after its download check.
#
#   install-canary.sh CODENAME[/COMPONENT] NAME=VERSION...   (component: main)
#   install-canary.sh --report FILE  rows of "codename name version arch component"
#
# With --report, the amd64 and arch:all rows of one codename and component
# install in 1 container with 1 apt-get install. The container sees main for
# main, and main and image for image (image packages can depend on main).
# Rows of other architectures are not installed (the runner is amd64): they
# get the download check only, and a log line says so.
#
# The container gets only the CANARY_* values (keyring, URL, suite,
# components): no mount, no other environment value, no extra privilege.
# Podman copies the host's proxy variables (which can hold credentials) into
# a container by default, so a podman runtime (also behind a docker name: its
# --version starts with "podman") runs with --http-proxy=false.
# There is no setting that turns the install check off.
#
# Tunables, read from the environment:
#   APT_CANARY_RUNTIME         container runtime, a command name or a path
#                              (docker when on PATH, else podman)
#   APT_CANARY_IMAGE           image without its tag; the tag is the codename
#                              (docker.io/library/debian)
#   APT_CANARY_TRIES           tries per image pull, at least 1 (4)
#   APT_CANARY_DELAY           seconds; the pause before pull try n+1 is DELAY*n (30)
#   APT_CANARY_INSTALL_BUDGET  seconds for all pulls, pauses and container
#                              runs of 1 call, at least 1 (420). A hard
#                              limit: each command runs under it (plus a 10 s
#                              kill grace), and a container that it stops is
#                              removed by name.
#   APT_CANARY_CLEANUP         seconds for that removal, at least 1 (30),
#                              plus a 5 s kill grace. The worst case of 1
#                              call is BUDGET + 10 s + CLEANUP + 5 s.
# Only an image pull is retried. A failed install is not: it fails at once
# with the end of the container's log (inside the container, apt retries each
# fetch 3 times).

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require awk base64 timeout

tries=$(tunable APT_CANARY_TRIES 4 1)
delay=$(tunable APT_CANARY_DELAY 30 0)
budget=$(tunable APT_CANARY_INSTALL_BUDGET 420 1)
cleanup=$(tunable APT_CANARY_CLEANUP 30 1)
image_base=${APT_CANARY_IMAGE:-docker.io/library/debian}
[[ $image_base =~ ^[A-Za-z0-9][A-Za-z0-9./_:-]*$ ]] || die "invalid APT_CANARY_IMAGE $image_base"

if [[ -n ${APT_CANARY_RUNTIME:-} ]]; then
	runtime=$APT_CANARY_RUNTIME
	if [[ $runtime == */* ]]; then
		[[ -f $runtime && -x $runtime ]] || die "APT_CANARY_RUNTIME $runtime is not an executable file"
	else
		command -v "$runtime" >/dev/null || die "APT_CANARY_RUNTIME $runtime is not on PATH"
	fi
elif command -v docker >/dev/null; then
	runtime=docker
elif command -v podman >/dev/null; then
	runtime=podman
else
	die "the install canary needs docker or podman (or APT_CANARY_RUNTIME)"
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

# The first stdout line of --version names the runtime; stderr can hold a
# notice (podman-docker prints one), so it is not read. A podman runtime gets
# --http-proxy=false on each run; an unknown runtime is refused.
version=$(timeout -k 5 30 "$runtime" --version </dev/null 2>"$work/version.err") ||
	die "$runtime --version failed: $(cat "$work/version.err")"
version=${version%%$'\n'*}
case $version in
"podman version "*) run_opts=(--http-proxy=false) ;;
"Docker version "*) run_opts=() ;;
*) die "unknown container runtime: $runtime --version printed: $version" ;;
esac

[[ -r $APT_KEYRING ]] || die "cannot read the keyring $APT_KEYRING"
keyring=$(base64 -w0 "$APT_KEYRING") || die "cannot encode the keyring $APT_KEYRING"

# left prints the seconds left in the budget. SECONDS counts from the start.
left() { echo $((budget - SECONDS)); }

# tail_log LOG prints the last 100 lines of LOG.
tail_log() { tail -n 100 "$1"; }

# bounded LOG WHAT CMD... runs CMD with its output in LOG and the rest of the
# budget as a hard limit, and returns CMD's status. It dies when the budget is
# spent, before or during CMD; WHAT names CMD in the message.
bounded() {
	local out=$1 what=$2 rest rc=0
	shift 2
	rest=$(left)
	((rest > 0)) || die "the install canary budget of ${budget}s is spent before $what"
	timeout -k 10 "$rest" "$@" </dev/null >"$out" 2>&1 || rc=$?
	# A container can also end with 137 (SIGKILL) by itself, for example
	# out of memory: only a spent budget makes 137 the budget's.
	if ((rc == 124 || (rc == 137 && $(left) <= 0))); then
		return 124
	fi
	return "$rc"
}

declare -A pulled=()

# pull IMAGE pulls IMAGE once per call, retried TRIES times inside the budget.
pull() {
	local image=$1 try=1 rc pause first
	[[ -z ${pulled[$image]:-} ]] || return 0
	while :; do
		rc=0
		bounded "$work/pull.log" "$runtime pull $image" "$runtime" pull -q "$image" || rc=$?
		((rc != 124)) || die "the install canary budget of ${budget}s is spent; stopped $runtime pull $image: $(tail_log "$work/pull.log")"
		((rc != 0)) || break
		((try < tries)) || die "$runtime pull $image failed (try $try of $tries): $(tail_log "$work/pull.log")"
		pause=$((delay * try))
		((pause < $(left))) ||
			die "$runtime pull $image failed (try $try of $tries): $(tail_log "$work/pull.log") (the install canary budget of ${budget}s is spent)"
		first=$(grep -m1 . "$work/pull.log" || true)
		log "install canary: $runtime pull $image failed (try $try of $tries): $first; retrying in ${pause}s"
		sleep "$pause"
		try=$((try + 1))
	done
	pulled[$image]=1
}

# guest NAME=VERSION... runs as root in the container. It installs the
# packages from the Frostyard source in CANARY_* and checks that dpkg lists
# each one as installed at its version.
guest() {
	set -euo pipefail
	export DEBIAN_FRONTEND=noninteractive
	# No service starts in the throwaway container.
	printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
	chmod 0755 /usr/sbin/policy-rc.d
	local apt=(apt-get -q -y -o Acquire::Retries=3) spec name version got
	"${apt[@]}" update
	"${apt[@]}" install --no-install-recommends ca-certificates
	mkdir -p /etc/apt/keyrings
	printf '%s' "$CANARY_KEYRING" | base64 -d >/etc/apt/keyrings/frostyard.gpg
	# apt reads the keyring as its _apt user.
	chmod 0644 /etc/apt/keyrings/frostyard.gpg
	printf 'Types: deb\nURIs: %s/\nSuites: %s\nComponents: %s\nSigned-By: /etc/apt/keyrings/frostyard.gpg\n' \
		"$CANARY_URL" "$CANARY_SUITE" "$CANARY_COMPONENTS" >/etc/apt/sources.list.d/frostyard.sources
	# A bad signature or a missing index is an error, not a warning.
	"${apt[@]}" update --error-on=any
	"${apt[@]}" install --no-install-recommends "$@"
	for spec; do
		name=${spec%%=*}
		version=${spec#*=}
		# shellcheck disable=SC2016 # dpkg-query fields, not shell variables
		got=$(dpkg-query -W -f='${db:Status-Abbrev} ${Version}' "$name" 2>&1) || true
		# db:Status-Abbrev is 3 characters: "ii " for an installed package.
		if [[ $got != "ii  $version" ]]; then
			echo "error: $name is not installed at $version (dpkg-query: $got)" >&2
			exit 1
		fi
		echo "installed $spec"
	done
}

# install_check CODENAME[/COMPONENT] NAME=VERSION...
install_check() {
	local codename component=main target components image name rc=0 t0 spec
	codename=${1%%/*}
	[[ $1 != */* ]] || component=${1#*/}
	[[ $codename =~ ^[a-z0-9]+$ ]] || die "invalid codename $codename"
	[[ $component =~ ^[a-z0-9]+$ ]] || die "invalid component $component"
	shift
	(($# > 0)) || die "no package to install for $codename/$component"
	for spec; do
		[[ $spec =~ ^[a-z0-9][a-z0-9+.-]*=[A-Za-z0-9][A-Za-z0-9.+~:-]*$ ]] || die "invalid package spec $spec"
	done
	# main is the default and stays out of the messages.
	target=$codename
	components=main
	if [[ $component != main ]]; then
		target+=/$component
		components="main $component"
	fi
	image=$image_base:$codename
	t0=$SECONDS
	pull "$image"
	name=apt-canary-$$-$RANDOM
	bounded "$work/run.log" "the install of $target/amd64" "$runtime" run --rm --pull=never "${run_opts[@]}" --name "$name" \
		-e "CANARY_KEYRING=$keyring" -e "CANARY_URL=$APT_PUBLIC_URL" -e "CANARY_SUITE=$codename" \
		-e "CANARY_COMPONENTS=$components" "$image" \
		bash -c "$(declare -f guest); guest \"\$@\"" install-canary "$@" || rc=$?
	if ((rc == 124)); then
		local removed rm_rc=0
		timeout -k 5 "$cleanup" "$runtime" rm -f "$name" </dev/null >"$work/rm.log" 2>&1 || rm_rc=$?
		if ((rm_rc == 0)); then
			removed="removed container $name"
		else
			removed="could not remove container $name (status $rm_rc): $(tail -n 5 "$work/rm.log")"
		fi
		die "the install canary budget of ${budget}s is spent; stopped the install of $target/amd64; $removed: $(tail_log "$work/run.log")"
	fi
	((rc == 0)) || die "install canary of $target/amd64 failed: $(tail_log "$work/run.log")"
	log "install canary $target/amd64: $* ($((SECONDS - t0))s)"
}

if [[ ${1:-} == --report ]]; then
	[[ -f ${2:-} ]] || die "usage: install-canary.sh --report FILE"
	# Rows without a fifth column are main.
	while read -r codename component arch; do
		target=$codename
		[[ $component == main ]] || target+=/$component
		log "install canary $target/$arch: not installed, the runner is amd64 (download check only)"
	done < <(awk -F'\t' 'NF && $4 != "amd64" && $4 != "all" { print $1, ($5 == "" ? "main" : $5), $4 }' "$2" | sort -u)
	sets=0
	while read -r codename component; do
		mapfile -t specs < <(awk -F'\t' -v c="$codename" -v k="$component" \
			'$1 == c && ($5 == "" ? "main" : $5) == k && ($4 == "amd64" || $4 == "all") { print $2 "=" $3 }' "$2" | sort -u)
		install_check "$codename/$component" "${specs[@]}"
		sets=$((sets + 1))
	done < <(awk -F'\t' 'NF && ($4 == "amd64" || $4 == "all") { print $1, ($5 == "" ? "main" : $5) }' "$2" | sort -u)
	((sets > 0)) || log "install canary: the report has no amd64 or all row; nothing to install"
	exit 0
fi

(($# >= 2)) || die "usage: install-canary.sh CODENAME[/COMPONENT] NAME=VERSION... | --report FILE"
install_check "$@"
