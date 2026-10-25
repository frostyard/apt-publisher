#!/usr/bin/env bash
# Withdraw one package version from a codename: remove it from the working
# repository of the component that holds it, snapshot, and publish only that
# component, leaving every other package and component as it is.
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
query="$name (= $version)"
[[ -z $arch ]] || query+=" {$arch}"
# The component is the one whose working repository holds the query.
found=()
for c in $(codename_components "$codename" | tr , ' '); do
	repo=$(ensure_repo "$codename" "$c")
	if aptly_ repo search "$repo" "$query" >/dev/null 2>&1; then
		found+=("$c")
	fi
done
if ((${#found[@]} > 1)); then
	die "$codename lists $query in more than one component (${found[*]}); one package name belongs in one component, so repair that first"
fi
if ((${#found[@]} == 0)); then
	if [[ $(codename_components "$codename") == main ]]; then
		die "$(repo_name "$codename" main) has no $query"
	fi
	die "$codename has no $query in any component"
fi
component=${found[0]}
repo=$(repo_name "$codename" "$component")
aptly_ repo remove "$repo" "$query" >&2
snapshot=$(new_snapshot_name "$codename" "$component" "withdraw-$name-$version${arch:+-$arch}")
aptly_ snapshot create "$snapshot" from repo "$repo" >/dev/null
commit_publications "$codename/$component=$snapshot"
if [[ -z $arch ]]; then
	verify_published "$codename" "!$component/$name=$version"
else
	verify_published "$codename"
fi
printf '%s %s\n' "$codename" "$snapshot"
