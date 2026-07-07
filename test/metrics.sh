#!/usr/bin/env bash
# Cyclomatic-complexity report via ShellMetrics. Review-time, NOT a CI gate:
# surfaces per-function CCN so firewall logic stays auditable. Functions over
# the threshold are marked >> FLAG for a simplify-or-keep decision.
set -euo pipefail
THRESHOLD="${SHELLMETRICS_THRESHOLD:-10}"

SM="$(command -v shellmetrics 2>/dev/null || true)"
if [ -z "$SM" ] && [ -x /opt/shellmetrics/shellmetrics ]; then
    SM=/opt/shellmetrics/shellmetrics
fi
if [ -z "$SM" ] || [ ! -x "$SM" ]; then
    echo "shellmetrics not installed - skipping (install: git clone https://github.com/shellspec/shellmetrics /opt/shellmetrics)" >&2
    exit 0
fi

cd "$(dirname "$0")/.."
echo "# Complexity report (ShellMetrics) - flags CCN > $THRESHOLD"
git ls-files '*.sh' | while IFS= read -r f; do
    echo "## $f"
    "$SM" "$f" | awk -v t="$THRESHOLD" '
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
            loc = $3
            if ($4 != "") loc = loc " " $4
            printf "  %s CCN=%-3s %s\n", ($2 + 0 > t + 0 ? ">>FLAG" : "      "), $2, loc
        }
    '
done
