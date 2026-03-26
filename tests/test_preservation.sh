#!/bin/sh

# Preservation Property Tests
# These tests verify baseline behavior on NON-BUGGY inputs (cases where all
# isBugCondition functions return false).
# EXPECTED OUTCOME: ALL tests PASS on unfixed code (confirms baseline to preserve).
#
# Preservation 1: retry() uses max_attempts=3 and delay=5 (lightweight ops unchanged)
# Preservation 2: deploy_head_services() calls tofu apply (core deploy logic preserved)
# Preservation 3: setup_head_services_variables() sets TF_VAR_head_host (core variable setup preserved)
# Preservation 4: utils.sh exports retry function (export behavior preserved)

# Resolve script directory in a POSIX-compatible way
SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
    /*) ;;
    *) SCRIPT_PATH="$(pwd)/$SCRIPT_PATH" ;;
esac
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
DEPLOY_SCRIPT="$SCRIPT_DIR/../scripts/03-infrastructure-deploy.sh"
UTILS_SCRIPT="$SCRIPT_DIR/../scripts/utils.sh"

PASS=0
FAIL=0

assert_pass() {
    local test_name="$1"
    local result="$2"  # 0 = condition met (preservation holds), 1 = condition NOT met (regression)
    if [ "$result" -eq 0 ]; then
        echo "PASS: $test_name -- Baseline behavior preserved"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $test_name -- Baseline behavior NOT preserved (regression detected)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=============================================="
echo " Preservation Property Tests (Unfixed Code)"
echo " Expected: ALL tests PASS (baseline confirmed)"
echo "=============================================="
echo ""

# ---------------------------------------------------------------------------
# Preservation 1: retry() uses max_attempts=3 and delay=5 (lightweight ops)
# ---------------------------------------------------------------------------
# isBugCondition_InsufficientRetry(op) = false for lightweight ops (git clone, kubectl)
# The retry() function must keep max_attempts=3 and delay=5 unchanged.
# This must hold on unfixed code AND after the fix (fix only adds retry_heavy, not changes retry).
echo "--- Preservation 1: retry() uses max_attempts=3 and delay=5 ---"

retry_body=$(awk '/^retry\(\)/{found=1} found{print} found && /^\}$/{exit}' "$UTILS_SCRIPT")

# Check max_attempts=3
if echo "$retry_body" | grep -q "max_attempts=3"; then
    max_attempts_ok=0
else
    max_attempts_ok=1
fi

# Check delay=5
if echo "$retry_body" | grep -q "delay=5"; then
    delay_ok=0
else
    delay_ok=1
fi

if [ "$max_attempts_ok" -eq 0 ] && [ "$delay_ok" -eq 0 ]; then
    assert_pass "Preservation1_Retry_LightweightParams" 0
else
    assert_pass "Preservation1_Retry_LightweightParams" 1
fi

echo ""

# ---------------------------------------------------------------------------
# Preservation 2: deploy_head_services() calls tofu apply (core deploy logic)
# ---------------------------------------------------------------------------
# The core deploy logic (tofu apply) must remain present in deploy_head_services().
# Fixes must not remove or skip the actual deployment step.
echo "--- Preservation 2: deploy_head_services() calls tofu apply ---"

deploy_head_services_body=$(awk '/^deploy_head_services\(\)/{found=1} found{print} found && /^\}$/{exit}' "$DEPLOY_SCRIPT")

if echo "$deploy_head_services_body" | grep -qE "tofu apply"; then
    assert_pass "Preservation2_DeployHead_TofuApply" 0
else
    assert_pass "Preservation2_DeployHead_TofuApply" 1
fi

echo ""

# ---------------------------------------------------------------------------
# Preservation 3: setup_head_services_variables() sets TF_VAR_head_host
# ---------------------------------------------------------------------------
# The core variable setup must remain: TF_VAR_head_host must be exported.
# Fixes to the iss URL must not remove other variable assignments.
echo "--- Preservation 3: setup_head_services_variables() sets TF_VAR_head_host ---"

setup_vars_body=$(awk '/^setup_head_services_variables\(\)/{found=1} found{print} found && /^\}$/{exit}' "$DEPLOY_SCRIPT")

if echo "$setup_vars_body" | grep -q 'TF_VAR_head_host'; then
    assert_pass "Preservation3_SetupVars_HeadHost" 0
else
    assert_pass "Preservation3_SetupVars_HeadHost" 1
fi

echo ""

# ---------------------------------------------------------------------------
# Preservation 4: utils.sh exports retry function
# ---------------------------------------------------------------------------
# The export -f for retry must remain in utils.sh so sourcing scripts can use it.
# Adding retry_heavy must not remove the existing retry export.
echo "--- Preservation 4: utils.sh exports retry function ---"

if grep -q "export -f.*retry" "$UTILS_SCRIPT"; then
    assert_pass "Preservation4_Utils_ExportRetry" 0
else
    assert_pass "Preservation4_Utils_ExportRetry" 1
fi

echo ""
echo "=============================================="
echo " Results: PASS=$PASS  FAIL=$FAIL"
echo " (On unfixed code: expected PASS=4, FAIL=0)"
echo "=============================================="

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "REGRESSION: $FAIL preservation test(s) failed."
    exit 1
fi

echo ""
echo "All preservation tests passed. Baseline behavior confirmed."
exit 0
