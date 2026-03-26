#!/bin/sh

# Bug Condition Exploration Tests
# These tests check for all 4 bug conditions on UNFIXED code.
# EXPECTED OUTCOME: ALL tests FAIL on unfixed code (failure confirms bugs exist).
#
# Bug 1: deploy_head_services() has NO helm cleanup before tofu apply
# Bug 2: deploy_head_services() has NO wait_for_service for postgres
# Bug 3: setup_head_services_variables() uses https:// in TF_VAR_users iss field
# Bug 4: retry_heavy() does NOT exist in utils.sh

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

assert_fail() {
    local test_name="$1"
    local result="$2"  # 0 = condition found (bug present), 1 = condition NOT found (bug absent/fixed)
    if [ "$result" -eq 0 ]; then
        echo "FAIL: $test_name -- Bug condition confirmed (bug IS present on unfixed code)"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $test_name -- Bug condition NOT found (code may already be fixed)"
        PASS=$((PASS + 1))
    fi
}

echo "=============================================="
echo " Bug Condition Exploration Tests (Unfixed Code)"
echo " Expected: ALL tests FAIL (bugs confirmed)"
echo "=============================================="
echo ""

# ---------------------------------------------------------------------------
# Bug 1: deploy_head_services() does NOT have helm cleanup before tofu apply
# ---------------------------------------------------------------------------
# The fix would add a block that calls `helm uninstall` before `tofu apply`.
# On unfixed code, no such block exists inside deploy_head_services().
echo "--- Bug 1: Helm cleanup missing in deploy_head_services() ---"

deploy_head_services_body=$(awk '/^deploy_head_services\(\)/{found=1} found{print} found && /^\}$/{exit}' "$DEPLOY_SCRIPT")
if echo "$deploy_head_services_body" | grep -q "helm uninstall"; then
    # helm uninstall found -> bug is FIXED -> test passes (unexpected on unfixed code)
    assert_fail "Bug1_HelmCleanup_Missing" 1
else
    # helm uninstall NOT found -> bug IS present -> test fails (expected on unfixed code)
    assert_fail "Bug1_HelmCleanup_Missing" 0
fi

echo ""

# ---------------------------------------------------------------------------
# Bug 2: deploy_head_services() does NOT have wait_for_service for postgres
# ---------------------------------------------------------------------------
# The fix would add a wait_for_service call for postgres inside deploy_head_services().
# On unfixed code, no such call exists.
echo "--- Bug 2: Postgres readiness gate missing in deploy_head_services() ---"

if echo "$deploy_head_services_body" | grep -qE "wait_for_service.*(postgres|Postgres)|postgres.*wait_for_service"; then
    # wait_for_service for postgres found -> bug is FIXED -> test passes (unexpected on unfixed code)
    assert_fail "Bug2_PostgresWait_Missing" 1
else
    # wait_for_service for postgres NOT found -> bug IS present -> test fails (expected on unfixed code)
    assert_fail "Bug2_PostgresWait_Missing" 0
fi

echo ""

# ---------------------------------------------------------------------------
# Bug 3: setup_head_services_variables() uses https:// in TF_VAR_users iss field
# ---------------------------------------------------------------------------
# The fix would change iss="https://..." to iss="http://keycloak-service:8080/...".
# On unfixed code, https:// is present in the TF_VAR_users assignment.
echo "--- Bug 3: https:// used in TF_VAR_users iss field ---"

setup_vars_body=$(awk '/^setup_head_services_variables\(\)/{found=1} found{print} found && /^\}$/{exit}' "$DEPLOY_SCRIPT")
tf_var_users_line=$(echo "$setup_vars_body" | grep 'TF_VAR_users')
if echo "$tf_var_users_line" | grep -q 'https://'; then
    # https:// found in TF_VAR_users -> bug IS present -> test fails (expected on unfixed code)
    assert_fail "Bug3_HTTPS_In_TF_VAR_users" 0
else
    # https:// NOT found in TF_VAR_users -> bug is FIXED -> test passes (unexpected on unfixed code)
    assert_fail "Bug3_HTTPS_In_TF_VAR_users" 1
fi

echo ""

# ---------------------------------------------------------------------------
# Bug 4: retry_heavy() does NOT exist in utils.sh
# ---------------------------------------------------------------------------
# The fix would add a retry_heavy() function to utils.sh.
# On unfixed code, retry_heavy() does not exist.
echo "--- Bug 4: retry_heavy() missing in utils.sh ---"

if grep -q "^retry_heavy()" "$UTILS_SCRIPT"; then
    # retry_heavy found -> bug is FIXED -> test passes (unexpected on unfixed code)
    assert_fail "Bug4_RetryHeavy_Missing" 1
else
    # retry_heavy NOT found -> bug IS present -> test fails (expected on unfixed code)
    assert_fail "Bug4_RetryHeavy_Missing" 0
fi

echo ""
echo "=============================================="
echo " Results: PASS=$PASS  FAIL=$FAIL"
echo " (On unfixed code: expected PASS=0, FAIL=4)"
echo "=============================================="

# Exit with failure when bugs are present (FAIL > 0) to signal bugs confirmed
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "CONFIRMED: $FAIL bug(s) detected on unfixed code."
    exit 1
fi

echo ""
echo "All bug conditions resolved (code appears to be fixed)."
exit 0
