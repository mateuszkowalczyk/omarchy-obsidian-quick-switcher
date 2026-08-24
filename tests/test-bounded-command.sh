#!/usr/bin/env bash

set -uo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_dir/bounded-command
failures=0

check_status() {
  local expected=$1
  local actual=$2
  local label=$3
  if (( actual != expected )); then
    echo "FAIL: $label (expected status $expected, got $actual)" >&2
    failures=$((failures + 1))
  fi
}

output=$($helper 5 5 test bash -c "printf 12345")
check_status 0 $? "accepts an exact stdout fit"
[[ $output == 12345 ]] || { echo "FAIL: preserves stdout" >&2; failures=$((failures + 1)); }

output=$(printf input | $helper 5 5 test bash -c "cat")
check_status 0 $? "passes stdin through to the command"
[[ $output == input ]] || { echo "FAIL: preserves stdin" >&2; failures=$((failures + 1)); }

$helper 5 5 test bash -c "printf 123456" >/dev/null 2>/dev/null
check_status 74 $? "rejects stdout overflow"

$helper 5 5 test bash -c "printf 123456 >&2" >/dev/null 2>/dev/null
check_status 74 $? "rejects stderr overflow"

$helper 5 5 test bash -c "printf err >&2; exit 7" >/dev/null 2>/dev/null
check_status 7 $? "preserves command failure status"

timeout 3 "$helper" 5 5 test bash -c "sleep 4 &" >/dev/null 2>/dev/null
check_status 0 $? "does not wait indefinitely for an inherited output pipe"

if (( failures > 0 )); then
  exit 1
fi
echo "bounded-command tests passed"
