#!/bin/sh
# Check extracted release scripts on a POSIX host without changing networking.
set -eu
bundle=${1:?Pass the bundle archive path}
work=$(mktemp -d /tmp/routecraft-bundle-test.XXXXXX)
case "$work" in /tmp/routecraft-bundle-test.*) ;; *) echo 'Unexpected temporary path' >&2; exit 1;; esac
trap 'rm -rf "$work"' EXIT HUP INT TERM
tar -xzf "$bundle" -C "$work"
cr=$(printf '\r')
for name in configure.sh install.sh start.sh direct-gateway.sh tproxy-gateway.sh routecraft-poc.init; do
    if grep -q "$cr" "$work/$name"; then echo "CRLF in $name" >&2; exit 1; fi
    sh -n "$work/$name"
done
if env -i PATH="$PATH" ROUTECRAFT_POC_DIR="$work/empty" sh "$work/start.sh" >"$work/out" 2>&1; then
    echo 'start.sh unexpectedly succeeded without an exit node' >&2; exit 1
fi
grep -q 'ERROR: set ROUTECRAFT_EXIT_NODE' "$work/out"
echo 'Extracted bundle shell checks passed'
