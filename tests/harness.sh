# shellcheck shell=bash
# harness.sh — the shared core of the test harnesses in this directory:
# pass/fail counters, the result printers, and the summary trailer. Sourced,
# never executed. Each test file keeps everything domain-specific (stubs,
# runners, its own expect_* wrappers) and ends with `finish <name>`, whose
# exit status is the harness verdict.
#
# One copy on purpose: the three harnesses drifted into three output formats,
# and a counter forgotten inside a hand-rolled FAIL block is the kind of bug a
# test file must not be able to have.

PASS=0
FAIL=0

ok() { PASS=$((PASS+1)); echo "  ok  - $1"; }

# fail <name> [detail…] — one FAIL line, plus an indented line per detail.
fail() {
    FAIL=$((FAIL+1))
    echo "  FAIL- $1"
    shift
    for _detail in "$@"; do echo "        $_detail"; done
}

finish() {  # $1 = harness name
    echo
    echo "$1: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
}
