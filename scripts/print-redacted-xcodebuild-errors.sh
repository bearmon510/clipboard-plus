#!/usr/bin/env bash
# Prints the error lines of an xcodebuild log for a public workflow log.
# Signing identities, certificate and profile names, and quoted team names can
# carry the developer's name, so they are replaced before anything is printed.
# Secrets such as the team ID and bundle ID are masked by GitHub separately.
set -euo pipefail

log="${1:?usage: print-redacted-xcodebuild-errors.sh <xcodebuild log>}"

redact() {
  sed -E \
    -e 's/((Apple|iPhone|iOS|Mac) (Development|Distribution|Developer)): [^"]*/\1: <redacted>/g' \
    -e 's/(Signing Identity|Provisioning Profile|[Tt]eam)(:)? *"[^"]*"/\1\2 "<redacted>"/g' \
    -e "s/(Signing Identity|Provisioning Profile|[Tt]eam)(:)? *'[^']*'/\\1\\2 '<redacted>'/g" \
    -e 's/(Team|team) [A-Z0-9]{10}\b/\1 <redacted>/g'
}

echo "xcodebuild failed. Redacted error lines follow; the full log is not published."
grep -E 'error:|\*\* [A-Z ]+ FAILED \*\*|requires a provisioning profile|[Nn]o (profiles|signing certificate|[Aa]ccount)' "$log" \
  | redact \
  | tail -n 80 \
  || echo "No error lines were found in the log."
