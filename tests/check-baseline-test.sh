#!/usr/bin/env bash
# Negative tests for tests/check-baseline.sh: each case copies the working tree
# to a temporary directory, applies 1 mutation, and requires the check to fail
# with a known message. One case runs the check on an unmutated copy and
# requires exit 0. The repository is never touched; every temporary directory
# goes away on exit.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cases=0
failures=0

copy_tree() { # copy_tree DIR: a copy of the working tree without .git
	mkdir -p "$1"
	(cd "$ROOT" && tar --exclude=./.git -cf - .) | tar -xf - -C "$1"
}

changed() { # changed ORIG COPY REL: succeeds when the copy differs at REL
	local orig=$1 copy=$2 rel=$3
	if [[ -L $orig/$rel || -L $copy/$rel ]]; then
		if [[ $(readlink -- "$orig/$rel") != "$(readlink -- "$copy/$rel")" ]]; then
			return 0
		fi
		return 1
	fi
	if [[ ! -e $orig/$rel || ! -e $copy/$rel ]]; then
		return 0
	fi
	if cmp -s -- "$orig/$rel" "$copy/$rel"; then
		return 1
	fi
	return 0
}

run_case() { # run_case CASE [EXPECTED]: a case name and a needed stderr line
	local id=$1 want=${2-} dir=$work/case-$1 orig=$work/orig-$1 err status
	cases=$((cases + 1))
	copy_tree "$orig"
	mkdir -p "$dir"
	cp -a "$orig/." "$dir"
	if [[ -n $want ]]; then
		if ! "mut_$id" "$dir" "$orig"; then
			printf 'not ok %d - %s: the mutation did not change the tree\n' "$cases" "$id"
			failures=$((failures + 1))
			return 0
		fi
	fi
	if err=$("$dir/tests/check-baseline.sh" 2>&1 >/dev/null); then
		status=0
	else
		status=$?
	fi
	if [[ -z $want ]]; then
		if ((status != 0)); then
			printf 'not ok %d - %s: the check failed on an unmutated tree\n' "$cases" "$id"
			printf '  %s\n' "${err//$'\n'/$'\n'  }"
			failures=$((failures + 1))
			return 0
		fi
		printf 'ok %d - %s\n' "$cases" "$id"
		return 0
	fi
	if ((status == 0)); then
		printf 'not ok %d - %s: the check exited 0\n' "$cases" "$id"
		failures=$((failures + 1))
		return 0
	fi
	if [[ $err != *"$want"* ]]; then
		printf 'not ok %d - %s: stderr does not hold "%s"\n' "$cases" "$id" "$want"
		printf '  %s\n' "${err//$'\n'/$'\n'  }"
		failures=$((failures + 1))
		return 0
	fi
	printf 'ok %d - %s\n' "$cases" "$id"
}

# B1: the instruction-file symlinks.
mut_b1_remove_gemini() {
	rm -f "$1/GEMINI.md"
	changed "$2" "$1" GEMINI.md
}

mut_b1_absolute_cursorrules() {
	rm -f "$1/.cursorrules"
	ln -s "$1/AGENTS.md" "$1/.cursorrules"
	changed "$2" "$1" .cursorrules
}

mut_b1_regular_claude() {
	rm -f "$1/CLAUDE.md"
	printf 'not a symlink\n' >"$1/CLAUDE.md"
	changed "$2" "$1" CLAUDE.md
}

# B2: the corrections inbox.
mut_b2_blank_line() {
	printf '\n' >>"$1/.memory/corrections.jsonl"
	changed "$2" "$1" .memory/corrections.jsonl
}

mut_b2_final_invalid_no_newline() {
	printf '%s' '{"date": "2026-11-06", "scope": "s"' >>"$1/.memory/corrections.jsonl"
	changed "$2" "$1" .memory/corrections.jsonl
}

mut_b2_duplicate_key() {
	printf '%s\n' '{"date": "2026-11-06", "scope": "s", "correction": "c", "evidence": "e", "promoted_to": "", "scope": "s"}' \
		>>"$1/.memory/corrections.jsonl"
	changed "$2" "$1" .memory/corrections.jsonl
}

mut_b2_missing_key() {
	printf '%s\n' '{"date": "2026-11-06", "scope": "s", "correction": "c", "evidence": "e"}' \
		>>"$1/.memory/corrections.jsonl"
	changed "$2" "$1" .memory/corrections.jsonl
}

mut_b2_non_string_value() {
	printf '%s\n' '{"date": "2026-11-06", "scope": "s", "correction": "c", "evidence": "e", "promoted_to": 1}' \
		>>"$1/.memory/corrections.jsonl"
	changed "$2" "$1" .memory/corrections.jsonl
}

mut_b2_invalid_date() {
	printf '%s\n' '{"date": "2026-02-30", "scope": "s", "correction": "c", "evidence": "e", "promoted_to": ""}' \
		>>"$1/.memory/corrections.jsonl"
	changed "$2" "$1" .memory/corrections.jsonl
}

mut_b2_empty_evidence() {
	printf '%s\n' '{"date": "2026-11-06", "scope": "s", "correction": "c", "evidence": "  ", "promoted_to": ""}' \
		>>"$1/.memory/corrections.jsonl"
	changed "$2" "$1" .memory/corrections.jsonl
}

# B3: the docs shape.
mut_b3_no_org_adrs() {
	rm -f "$1/docs/org-adrs.md"
	changed "$2" "$1" docs/org-adrs.md
}

mut_b3_no_plans_template() {
	rm -f "$1/docs/plans/TEMPLATE.md"
	changed "$2" "$1" docs/plans/TEMPLATE.md
}

# B4: the make gate and the tool pins.
mut_b4_ci_without_verify() {
	sed -i 's/^ci: verify/ci:/' "$1/Makefile"
	changed "$2" "$1" Makefile
}

mut_b4_no_mise_lock() {
	rm -f "$1/mise.lock"
	changed "$2" "$1" mise.lock
}

# B5: pinned, least-privilege workflows.
mut_b5_unpinned_uses() {
	sed -i 's|@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1|@v4|' "$1/.github/workflows/ci.yml"
	changed "$2" "$1" .github/workflows/ci.yml
}

mut_b5_no_persist_credentials() {
	sed -i '/persist-credentials: false/d' "$1/.github/workflows/ci.yml"
	changed "$2" "$1" .github/workflows/ci.yml
}

# A checkout that is not the first key of its list item: the step starts with
# `- name:` and the `uses:` line comes next.
mut_b5_name_first_checkout() {
	printf 'name: fixture\n\non:\n  workflow_dispatch:\n\npermissions: {}\n\ndefaults:\n  run:\n    shell: bash\n\njobs:\n  fixture:\n    runs-on: ubuntu-24.04\n    steps:\n      - name: Checkout\n        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2\n' \
		>"$1/.github/workflows/fixture.yml"
	changed "$2" "$1" .github/workflows/fixture.yml
}

mut_b5_permissions_write_all() {
	sed -i 's/^permissions: {}$/permissions: write-all/' "$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

mut_b5_permissions_write_scope() {
	sed -i 's/^  contents: read$/  contents: write/' "$1/.github/workflows/ci.yml"
	changed "$2" "$1" .github/workflows/ci.yml
}

# B6: the risk paths and their caller.
mut_b6_no_risk_json() {
	rm -f "$1/.github/risk-paths.json"
	changed "$2" "$1" .github/risk-paths.json
}

mut_b6_no_scripts_glob() {
	jq '.paths |= map(select(.glob != "scripts/**"))' "$1/.github/risk-paths.json" \
		>"$1/.github/risk-paths.json.new"
	mv "$1/.github/risk-paths.json.new" "$1/.github/risk-paths.json"
	changed "$2" "$1" .github/risk-paths.json
}

# The unpinned caller ref: the B5 pin scan reports it before B6 reads it.
mut_b6_caller_main() {
	sed -i 's|@1b02a129026329cef2b46d1fbd0465a863c1cd81|@main|' "$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

# A pinned SHA of the wrong workflow: only B6 can catch this one.
mut_b6_caller_wrong_workflow() {
	sed -i 's|risk-paths\.yml@1b02a129026329cef2b46d1fbd0465a863c1cd81|other.yml@1b02a129026329cef2b46d1fbd0465a863c1cd81|' \
		"$1/.github/workflows/risk-paths.yml"
	changed "$2" "$1" .github/workflows/risk-paths.yml
}

# B7: the pull request template.
mut_b7_rename_risk_heading() {
	sed -i 's/^## Risk tier$/## Tiers/' "$1/.github/pull_request_template.md"
	changed "$2" "$1" .github/pull_request_template.md
}

# B12: the CI entry.
mut_b12_no_make_ci() {
	sed -i '/^      - run: make ci$/d' "$1/.github/workflows/ci.yml"
	changed "$2" "$1" .github/workflows/ci.yml
}

# B13: Dependabot.
mut_b13_no_github_actions() {
	sed -i 's/^  - package-ecosystem: "github-actions"$/  - package-ecosystem: "npm"/' \
		"$1/.github/dependabot.yml"
	changed "$2" "$1" .github/dependabot.yml
}

# B14: the security policy.
mut_b14_no_security_url() {
	sed -i 's|https://github.com/frostyard/apt-publisher/security|https://example.org/security|' \
		"$1/SECURITY.md"
	changed "$2" "$1" SECURITY.md
}

# B15: no CODEOWNERS.
mut_b15_codeowners() {
	printf '* @frostyard/owners\n' >"$1/.github/CODEOWNERS"
	changed "$2" "$1" .github/CODEOWNERS
}

# B16: no leftover agent-framework trees.
mut_b16_planning_tree() {
	mkdir -p "$1/.planning"
	printf 'x\n' >"$1/.planning/x"
	changed "$2" "$1" .planning
}

mut_b16_claude_other_file() {
	mkdir -p "$1/.claude"
	printf '# other\n' >"$1/.claude/other.md"
	changed "$2" "$1" .claude
}

# B17: the README.
mut_b17_duplicate_marker() {
	printf '<!-- readme-kind: packaging -->\n' >>"$1/README.md"
	changed "$2" "$1" README.md
}

mut_b17_long_readme() {
	printf 'word %.0s' {1..1000} >>"$1/README.md"
	printf '\n' >>"$1/README.md"
	changed "$2" "$1" README.md
}

order=(
	unmutated
	b1_remove_gemini
	b1_absolute_cursorrules
	b1_regular_claude
	b2_blank_line
	b2_final_invalid_no_newline
	b2_duplicate_key
	b2_missing_key
	b2_non_string_value
	b2_invalid_date
	b2_empty_evidence
	b3_no_org_adrs
	b3_no_plans_template
	b4_ci_without_verify
	b4_no_mise_lock
	b5_unpinned_uses
	b5_no_persist_credentials
	b5_name_first_checkout
	b5_permissions_write_all
	b5_permissions_write_scope
	b6_no_risk_json
	b6_no_scripts_glob
	b6_caller_main
	b6_caller_wrong_workflow
	b7_rename_risk_heading
	b12_no_make_ci
	b13_no_github_actions
	b14_no_security_url
	b15_codeowners
	b16_planning_tree
	b16_claude_other_file
	b17_duplicate_marker
	b17_long_readme
)

declare -A expected=(
	[b1_remove_gemini]='GEMINI.md must be a symlink to AGENTS.md'
	[b1_absolute_cursorrules]='.cursorrules must be a relative symlink'
	[b1_regular_claude]='CLAUDE.md must be a symlink to AGENTS.md'
	[b2_blank_line]='blank line'
	[b2_final_invalid_no_newline]='invalid JSON'
	[b2_duplicate_key]='duplicate key(s): scope'
	[b2_missing_key]='missing key(s): promoted_to'
	[b2_non_string_value]='value for promoted_to is not a string'
	[b2_invalid_date]='invalid date: 2026-02-30'
	[b2_empty_evidence]='evidence is empty'
	[b3_no_org_adrs]='docs/org-adrs.md is missing'
	[b3_no_plans_template]='docs/plans/TEMPLATE.md is missing'
	[b4_ci_without_verify]='the Makefile ci: rule must list verify'
	[b4_no_mise_lock]='mise.lock is missing'
	[b5_unpinned_uses]='uses is not pinned to a 40-character commit SHA'
	[b5_no_persist_credentials]='the checkout step does not set persist-credentials: false'
	[b5_name_first_checkout]='the checkout step does not set persist-credentials: false'
	[b5_permissions_write_all]='the permissions line must be permissions: {} or a block of read scopes'
	[b5_permissions_write_scope]='the permissions block holds a scope that is not read'
	[b6_no_risk_json]='.github/risk-paths.json is missing'
	[b6_no_scripts_glob]='does not list the glob scripts/**'
	[b6_caller_main]='uses is not pinned to a 40-character commit SHA'
	[b6_caller_wrong_workflow]="no workflow calls frostyard/core's risk-paths.yml"
	[b7_rename_risk_heading]='has no heading that names the risk tier'
	[b12_no_make_ci]='has no run: make ci step'
	[b13_no_github_actions]='has no github-actions entry'
	[b14_no_security_url]='does not link https://github.com/frostyard/apt-publisher/security'
	[b15_codeowners]='.github/CODEOWNERS must not exist'
	[b16_planning_tree]='.planning must not exist'
	[b16_claude_other_file]='.claude/ holds other.md'
	[b17_duplicate_marker]='must have exactly 1 line'
	[b17_long_readme]='the limit is 1000'
)

for id in "${order[@]}"; do
	run_case "$id" "${expected[$id]-}"
done

printf '1..%d\n' "$cases"
if ((failures > 0)); then
	printf '%d case(s) failed\n' "$failures" >&2
	exit 1
fi
