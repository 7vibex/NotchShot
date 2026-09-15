#!/bin/bash
#
# Fast repository hygiene gates for CI. No dependencies beyond bash + grep + wc.
# Fails closed: any violation exits non-zero with the offending path.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "hygiene: $1" >&2; exit 1; }

# 1. No leftover task markers in shipped Swift.
if grep -rn --include="*.swift" -E "TODO|FIXME|HACK|XXX" Sources/ Tests/; then
    fail "task markers found in Sources/ or Tests/"
fi

# 2. README architecture section must name every module directory.
for dir in Sources/NotchShotKit/*/; do
    name="$(basename "$dir")"
    grep -q "^  $name/" README.md || fail "README.md missing module $name/"
done

# 3. File-size guardrail: the AppCoordinator god-object must keep shrinking.
#    Cap is 4000 lines; current ~3880 after ShelfItem/VideoThumbnail extraction.
while IFS= read -r line; do
    count="${line%% *}"
    path="${line#* }"
    if [ "$count" -gt 4000 ]; then
        fail "$path is $count lines (>4000). Extract a pipeline controller first."
    fi
done < <(find Sources -name "*.swift" -exec wc -l {} \; | awk '{print $1" "$2}')

# 4. Sparkle must stay exactly pinned — the updater is a privileged path.
grep -q 'Sparkle.*exact: "2\.9\.[0-9]*"' Package.swift \
    || fail "Package.swift must pin Sparkle with exact:"

# 5. Updater must stay fail-closed (HTTPS + EdDSA required, nil otherwise).
grep -q 'url.scheme?.lowercased() == "https"' Sources/NotchShotKit/Updates/SecureUpdateController.swift \
    || fail "SecureUpdateController lost its HTTPS-only check"
grep -q 'updaterController = nil' Sources/NotchShotKit/Updates/SecureUpdateController.swift \
    || fail "SecureUpdateController lost its fail-closed nil path"

echo "hygiene: ok"
