#!/usr/bin/env bash
set -euo pipefail

readonly CHECKER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check_architecture.sh"

run_fixture() {
	local expected="$1"
	local label="$2"
	shift 2
	local fixture_root
	fixture_root="$(mktemp -d)"
	mkdir -p "${fixture_root}/scripts"
	for fixture in "$@"; do
		cp "tests/architecture/${fixture}.gd.txt" "${fixture_root}/scripts/${fixture}.gd"
	done
	if "${CHECKER}" "${fixture_root}" >/dev/null 2>&1; then
		status=0
	else
		status=$?
	fi
	rm -rf "${fixture_root}"
	if (( status != expected )); then
		printf 'architecture checker fixture %s: expected exit %d, got %d\n' \
			"${label}" "${expected}" "${status}" >&2
		exit 1
	fi
}

run_fixture 0 clean clean
run_fixture 1 private-owner private_owner_access
run_fixture 1 facade-sibling facade_sibling_access
run_fixture 1 bare-class-comment-preload foo_thing bare_class_comment_preload
run_fixture 1 direct-autoload direct_autoload
