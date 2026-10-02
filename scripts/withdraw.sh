#!/usr/bin/env bash
# Withdraw one package version from a codename: remove it from the working
# repository, snapshot, and publish, leaving every other package as it is.
# The file stays in the pool. Republishing the same release adds it back.

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

usage() {
	cat >&2 <<'EOF'
usage: withdraw.sh --codename CODENAME --package NAME --version VERSION [--arch ARCH]

  --arch  withdraw only this architecture; default: every architecture
EOF
	exit 2
}

codename='' name='' version='' arch=''
while (($#)); do
	case $1 in
	--codename) codename=${2:?} && shift ;;
	--package) name=${2:?} && shift ;;
	--version) version=${2:?} && shift ;;
	--arch) arch=${2:?} && shift ;;
	*) usage ;;
	esac
	shift
done
[[ -n $codename && -n $name && -n $version ]] || usage
codename_field "$codename" 1 >/dev/null || die "unknown codename $codename"
# Keep the aptly query to a plain package reference.
[[ $name =~ ^[a-z0-9][a-z0-9.+-]*$ ]] || die "invalid package name $name"
[[ $version =~ ^[A-Za-z0-9.+~:-]+$ ]] || die "invalid version $version"
[[ -z $arch || $arch =~ ^[a-z0-9]+$ ]] || die "invalid architecture $arch"

aptly_init
reconcile_state "$codename"
repo=$(ensure_repo "$codename")
query="$name (= $version)"
[[ -z $arch ]] || query+=" {$arch}"
aptly_ repo search "$repo" "$query" >/dev/null 2>&1 || die "$repo has no $query"
aptly_ repo remove "$repo" "$query" >&2
snapshot=$(new_snapshot_name "$codename" "withdraw-$name-$version${arch:+-$arch}")
aptly_ snapshot create "$snapshot" from repo "$repo" >/dev/null
commit_publications "$codename=$snapshot"
if [[ -z $arch ]]; then
	verify_published "$codename" "!$name=$version"
else
	verify_published "$codename"
fi
printf '%s %s\n' "$codename" "$snapshot"
