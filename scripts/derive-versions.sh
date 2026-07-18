#!/usr/bin/env bash
# Derive the coupled build versions from TALOS_VERSION — the single source of truth.
#
# TALOS_VERSION -> PKGS_COMMIT:
#   Read the pkgs ref that the Talos release pins in
#   pkg/machinery/gendata/data/pkgs, e.g. "v1.13.0-28-g54ec9fc" -> "54ec9fc".
#   This is what build-extensions.sh downloads siderolabs/pkgs at, so it *must*
#   match the chosen Talos release or the kernel/module are built wrong.
#
# Usage:
#   scripts/derive-versions.sh            # print the derived values
#   scripts/derive-versions.sh --verify   # exit 1 if scripts/common.sh has drifted
#
# The --verify mode is meant to run in CI so a Talos bump that forgets to update
# PKGS_COMMIT fails the PR instead of silently building against the wrong kernel.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

derive_pkgs_commit() {
	local talos="$1" ref
	ref=$(curl -fsSL \
		"https://raw.githubusercontent.com/siderolabs/talos/${talos}/pkg/machinery/gendata/data/pkgs") \
		|| {
			echo "ERROR: could not fetch pkgs ref for Talos ${talos}" >&2
			return 1
		}
	ref="${ref//[[:space:]]/}"
	# git-describe form "vX.Y.Z-N-g<sha>" -> "<sha>"; a plain tag/SHA is used as-is.
	if [[ "${ref}" == *-g* ]]; then
		printf '%s\n' "${ref##*-g}"
	else
		printf '%s\n' "${ref}"
	fi
}

EXPECTED_PKGS_COMMIT="$(derive_pkgs_commit "${TALOS_VERSION}")"

if [[ "${1:-}" == "--verify" ]]; then
	rc=0
	if [[ "${EXPECTED_PKGS_COMMIT}" != "${PKGS_COMMIT}" ]]; then
		echo "FAIL: PKGS_COMMIT drift for ${TALOS_VERSION}" >&2
		echo "  scripts/common.sh: ${PKGS_COMMIT}" >&2
		echo "  expected:          ${EXPECTED_PKGS_COMMIT} (from siderolabs/talos gendata)" >&2
		echo "  Fix: set PKGS_COMMIT to the expected value in scripts/common.sh." >&2
		rc=1
	else
		echo "OK: PKGS_COMMIT=${PKGS_COMMIT} matches Talos ${TALOS_VERSION}"
	fi
	# KERNEL_VERSION is a label for image tags; the real vermagic comes from the
	# kernel that pkgs@PKGS_COMMIT builds. It is asserted at build time, not here.
	echo "NOTE: KERNEL_VERSION=${KERNEL_VERSION} must match the kernel pkgs@${PKGS_COMMIT} builds."
	exit "${rc}"
fi

echo "TALOS_VERSION=${TALOS_VERSION}"
echo "PKGS_COMMIT=${EXPECTED_PKGS_COMMIT}"
echo "KERNEL_VERSION=${KERNEL_VERSION}"
