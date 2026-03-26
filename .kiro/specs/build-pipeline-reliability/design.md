# Build Pipeline Reliability Bugfix Design

## Overview

Build pipeline (`scripts/03-infrastructure-deploy.sh`) không đạt 100% success rate khi chạy trên VM cũ hoặc khi re-deploy. Bốn lỗi độc lập được xác định và cần fix:

1. **Helm Release Conflict**: `deploy_head_services()` fail với "cannot re-use a name that is still in use" khi có Helm releases cũ
2. **Postgres Timing Race Condition**: `head-hook-preinstall` pod fail vì postgres cluster chưa healthy
3. **SSL/TLS PKIX Failure**: Java backend services từ chối self-signed certificate khi fetch Keycloak OIDC config qua HTTPS external URL
4. **Insufficient Retry**: `retry()` trong `utils.sh` chỉ retry 3 lần với 5s delay, không đủ cho heavy operations

Chiến lược fix: minimal, targeted changes vào `scripts/03-infrastructure-deploy.sh` và `scripts/utils.sh`, không thay đổi logic deploy cốt lõi.

## Glossary

- **Bug_Condition (C)**: Điều kiện kích hoạt bug - trạng thái môi trường hoặc config gây pipeline fail
- **Property (P)**: Behavior mong muốn khi bug condition xảy ra - pipeline phải tự recover và thành công
- **Preservation**: Behavior hiện tại trên VM sạch và các operations không liên quan phải không bị ảnh hưởng
- **deploy_head_services()**: Hàm trong `scripts/03-infrastructure-deploy.sh` deploy Helm charts và Terraform head services
- **retry()**: Hàm trong `scripts/utils.sh` wrap commands với retry logic
- **isBugCondition_HelmConflict**: Kiểm tra có Helm releases cũ đang tồn tại không
- **isBugCondition_PostgresNotReady**: Kiểm tra postgres pods có đang ở trạng thái Running/Ready không
- **isBugCondition_SSLFailure**: Kiểm tra issuerUrl config có dùng https:// không
- **isBugCondition_InsufficientRetry**: Kiểm tra heavy operation có đang dùng retry parameters không đủ không

## Bug Details

### Bug 1: Helm Release Conflict

Khi `deploy_head_services()` chạy trên VM đã có Helm releases từ lần deploy trước, `tofu apply` gọi Helm install sẽ fail vì Helm không cho phép install một release đã tồn tại mà không dùng `upgrade`.

**Formal Specification:**
```
FUNCTION isBugCondition_HelmConflict(env)
  INPUT: env = deployment environment state
  OUTPUT: boolean

  existing_releases ← helm list --all-namespaces --short
  RETURN length(existing_releases) > 0
         AND any release in existing_releases matches head chart release names
END FUNCTION
```

**Examples:**
- VM đã deploy lần trước: `helm list -n default` trả về `crczp-head` → deploy fail với "cannot re-use a name that is still in use"
- VM sạch: `helm list -n default` trả về empty → deploy thành công (không phải bug condition)
- VM có releases không liên quan: chỉ releases của head chart mới gây conflict

### Bug 2: Postgres Timing Race Condition

Khi `deploy_head_services()` chạy ngay sau khi postgres cluster được tạo, `head-hook-preinstall` pod cố kết nối postgres nhưng cluster chưa healthy, gây Helm install abort.

**Formal Specification:**
```
FUNCTION isBugCondition_PostgresNotReady(env)
  INPUT: env = cluster state at time of head chart deploy
  OUTPUT: boolean

  postgres_pods ← kubectl get pods -n default -l app=postgres
  all_ready ← all pods in postgres_pods have status Running AND ready=true
  RETURN NOT all_ready
END FUNCTION
```

**Examples:**
- Postgres pods ở trạng thái `Pending` hoặc `Init:0/1` → `head-hook-preinstall` fail
- Postgres pods ở trạng thái `Running` nhưng readiness probe chưa pass → fail
- Postgres pods tất cả `Running/Ready` → deploy thành công (không phải bug condition)

### Bug 3: SSL/TLS PKIX Failure

Khi `setup_head_services_variables()` set `TF_VAR_users` với `iss="https://$head_host/keycloak/realms/CRCZP"`, các Java backend services dùng URL này để fetch OIDC configuration. Self-signed certificate của deployment bị Java truststore từ chối.

**Formal Specification:**
```
FUNCTION isBugCondition_SSLFailure(config)
  INPUT: config = TF_VAR_users hoặc issuer URL config
  OUTPUT: boolean

  issuer_url ← extract iss field from config
  RETURN issuer_url STARTS_WITH "https://"
         AND certificate at issuer_url is self-signed
         AND NOT in Java default truststore
END FUNCTION
```

**Examples:**
- `iss="https://10.0.0.5/keycloak/realms/CRCZP"` → PKIX path building failed
- `iss="http://keycloak-service:8080/keycloak/realms/CRCZP"` → thành công (internal URL)
- Services không dùng issuer URL → không bị ảnh hưởng

### Bug 4: Insufficient Retry

`retry()` trong `utils.sh` dùng `max_attempts=3` và `delay=5s`. Với heavy operations như `tofu apply` (15-30 phút) hoặc Helm install, transient failures cần nhiều thời gian hơn để recover.

**Formal Specification:**
```
FUNCTION isBugCondition_InsufficientRetry(op)
  INPUT: op = operation being retried
  OUTPUT: boolean

  RETURN op.type IN {helm_install, tofu_apply, tofu_init}
         AND current_retry_config.max_attempts <= 3
         AND current_retry_config.delay <= 5
END FUNCTION
```

**Examples:**
- `retry tofu apply -auto-approve` fail lần 1 sau 2 phút → retry sau 5s → fail lại → abort sau 3 lần
- `retry tofu apply` với 5 attempts và 30s delay → đủ thời gian cho transient failures
- `retry git clone` → lightweight op, 3 attempts/5s là đủ

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- Deploy lần đầu trên VM sạch (không có Helm releases cũ) phải tiếp tục thành công như hiện tại
- Khi postgres đã healthy trước khi deploy, head chart phải deploy ngay lập tức không có delay không cần thiết
- Các services không dùng Keycloak OIDC issuer URL phải hoạt động bình thường
- `retry()` cho lightweight operations (git clone, kubectl commands) phải giữ behavior hiện tại
- `deploy_base_infrastructure()` và các Terraform operations khác phải hoạt động đúng như hiện tại

**Scope:**
Tất cả inputs KHÔNG thuộc bug conditions (VM sạch, postgres đã ready, config dùng internal URL, lightweight ops) phải hoàn toàn không bị ảnh hưởng bởi các fixes này.

## Hypothesized Root Cause

### Bug 1: Helm Release Conflict
1. **Thiếu idempotency check**: `deploy_head_services()` không kiểm tra Helm releases đã tồn tại trước khi chạy `tofu apply`
2. **Terraform state mismatch**: Terraform state có thể không sync với actual Helm state sau failed deploy
3. **Không có cleanup step**: Pipeline không có bước cleanup Helm releases trước khi re-deploy

### Bug 2: Postgres Timing Race Condition
1. **Thiếu readiness gate**: Không có bước wait cho postgres cluster healthy trước khi deploy head chart
2. **Helm hook ordering**: `head-hook-preinstall` chạy ngay khi Helm install bắt đầu, không đợi dependencies
3. **Kubernetes pod scheduling delay**: Postgres pods cần thời gian để schedule và start sau khi Terraform tạo resources

### Bug 3: SSL/TLS PKIX Failure
1. **External URL thay vì internal**: `TF_VAR_users` dùng `https://$head_host/keycloak/...` (external URL với self-signed cert) thay vì internal Kubernetes service URL
2. **Java truststore không có self-signed cert**: Deployment không import self-signed cert vào Java truststore
3. **`TF_VAR_openid_configuration_insecure=true`** đã được set nhưng có thể không đủ cho tất cả Java services

### Bug 4: Insufficient Retry
1. **Hardcoded conservative parameters**: `retry()` dùng `max_attempts=3` và `delay=5` phù hợp cho lightweight ops nhưng không đủ cho heavy ops
2. **Không có retry variant**: Không có hàm `retry_heavy()` hoặc parameterized retry cho different operation types
3. **Transient failures của Terraform/Helm**: OpenStack API rate limiting, network blips, resource contention cần nhiều thời gian hơn để resolve

## Correctness Properties

Property 1: Bug Condition - Helm Release Conflict Auto-Cleanup

_For any_ deployment environment where `isBugCondition_HelmConflict(env)` returns true (existing Helm releases present), the fixed `deploy_head_services()` function SHALL automatically uninstall conflicting Helm releases before proceeding with deployment, resulting in a successful deploy without "cannot re-use a name" errors.

**Validates: Requirements 2.1**

Property 2: Bug Condition - Postgres Readiness Gate

_For any_ cluster state where `isBugCondition_PostgresNotReady(env)` returns true (postgres pods not all Running/Ready), the fixed `deploy_head_services()` function SHALL wait until postgres cluster is healthy before deploying the head chart, preventing `head-hook-preinstall` pod failures.

**Validates: Requirements 2.2**

Property 3: Bug Condition - Internal Keycloak URL

_For any_ configuration where `isBugCondition_SSLFailure(config)` returns true (issuerUrl uses https:// external URL), the fixed `setup_head_services_variables()` function SHALL use internal HTTP URL (`http://keycloak-service:8080/keycloak/...`) for the `iss` field, avoiding SSL certificate validation entirely.

**Validates: Requirements 2.3**

Property 4: Bug Condition - Extended Retry for Heavy Operations

_For any_ heavy operation where `isBugCondition_InsufficientRetry(op)` returns true (helm_install or tofu_apply with insufficient retry config), the fixed pipeline SHALL use extended retry parameters (>= 5 attempts, >= 30s delay) sufficient to cover transient failures.

**Validates: Requirements 2.4**

Property 5: Preservation - Clean VM Deploy Unchanged

_For any_ deployment environment where `isBugCondition_HelmConflict(env)` returns false (no existing Helm releases), the fixed `deploy_head_services()` function SHALL produce exactly the same behavior as the original function, with no unnecessary cleanup steps or delays.

**Validates: Requirements 3.1, 3.2**

Property 6: Preservation - Lightweight Operation Retry Unchanged

_For any_ lightweight operation where `isBugCondition_InsufficientRetry(op)` returns false (git clone, kubectl commands), the fixed `retry()` function SHALL produce exactly the same behavior as the original function, preserving existing retry parameters.

**Validates: Requirements 3.4, 3.5**

## Fix Implementation

### Changes Required

Assuming root cause analysis là đúng:

**File 1**: `scripts/utils.sh`

**Function**: `retry()`

**Specific Changes**:
1. **Add `retry_heavy()` function**: Tạo variant của `retry()` với `max_attempts=5` và `delay=30` cho heavy operations
   - Giữ nguyên `retry()` hiện tại để không break lightweight operations
   - `retry_heavy()` dùng cùng logic nhưng với parameters khác

---

**File 2**: `scripts/03-infrastructure-deploy.sh`

**Function**: `deploy_head_services()`

**Specific Changes**:
1. **Add Helm cleanup step**: Trước khi chạy `tofu apply`, kiểm tra và uninstall existing Helm releases
   ```bash
   # Cleanup existing Helm releases to ensure idempotent deploy
   existing_releases=$(helm list --all-namespaces --short 2>/dev/null || true)
   if [ -n "$existing_releases" ]; then
       log "Cleaning up existing Helm releases..."
       helm list --all-namespaces -q | xargs -I{} helm uninstall {} --wait 2>/dev/null || true
   fi
   ```

2. **Add postgres readiness wait**: Trước khi `tofu apply`, wait cho postgres pods healthy
   ```bash
   wait_for_service "postgres cluster" \
     "kubectl get pods -n default -l app=postgres --field-selector=status.phase=Running | grep -c Running | grep -q '^[1-9]'" \
     60 10
   ```

3. **Replace `retry` with `retry_heavy` for heavy ops**: Thay `retry tofu apply` bằng `retry_heavy tofu apply`

**Function**: `setup_head_services_variables()`

**Specific Changes**:
4. **Fix issuer URL**: Thay `iss=\"https://$head_host/keycloak/realms/CRCZP\"` bằng `iss=\"http://keycloak-service:8080/keycloak/realms/CRCZP\"` trong `TF_VAR_users`

**Function**: `deploy_base_infrastructure()`

**Specific Changes**:
5. **Replace `retry` with `retry_heavy` for tofu apply**: Thay `retry tofu apply` bằng `retry_heavy tofu apply`

## Testing Strategy

### Validation Approach

Testing theo hai phase: trước tiên surface counterexamples trên unfixed code để confirm root cause, sau đó verify fix hoạt động đúng và không gây regressions.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples chứng minh bug TRƯỚC khi implement fix. Confirm hoặc refute root cause analysis.

**Test Plan**: Viết tests simulate các bug conditions và assert expected behavior. Chạy trên UNFIXED code để observe failures.

**Test Cases**:
1. **Helm Conflict Test**: Mock `helm list` trả về existing releases, chạy `deploy_head_services()` → expect fail với "cannot re-use a name" (sẽ fail trên unfixed code)
2. **Postgres Not Ready Test**: Mock `kubectl get pods` trả về postgres pods ở `Pending` state, chạy deploy → expect `head-hook-preinstall` fail (sẽ fail trên unfixed code)
3. **SSL PKIX Test**: Set `TF_VAR_users` với `iss="https://..."`, start mock Java service → expect "PKIX path building failed" (sẽ fail trên unfixed code)
4. **Retry Exhaustion Test**: Mock `tofu apply` fail 4 lần liên tiếp với 1s delay → expect retry() abort sau 3 lần (sẽ fail trên unfixed code)

**Expected Counterexamples**:
- `deploy_head_services()` không cleanup Helm releases trước khi install
- Không có wait logic cho postgres readiness
- `TF_VAR_users` chứa `https://` issuer URL
- `retry()` abort sau 3 attempts cho heavy operations

### Fix Checking

**Goal**: Verify với mọi input thuộc bug condition, fixed function produce expected behavior.

**Pseudocode:**
```
// Bug 1
FOR ALL env WHERE isBugCondition_HelmConflict(env) DO
  result ← deploy_head_services_fixed(env)
  ASSERT result = SUCCESS
  ASSERT no "cannot re-use a name" error in logs
END FOR

// Bug 2
FOR ALL env WHERE isBugCondition_PostgresNotReady(env) DO
  result ← deploy_head_services_fixed(env)
  ASSERT postgres_wait_called = true
  ASSERT result = SUCCESS after postgres becomes ready
END FOR

// Bug 3
FOR ALL config WHERE isBugCondition_SSLFailure(config) DO
  generated_vars ← setup_head_services_variables_fixed(config)
  ASSERT generated_vars.TF_VAR_users NOT CONTAINS "https://"
  ASSERT generated_vars.TF_VAR_users CONTAINS "http://keycloak-service:8080"
END FOR

// Bug 4
FOR ALL op WHERE isBugCondition_InsufficientRetry(op) DO
  retry_config ← get_retry_config_for(op)
  ASSERT retry_config.max_attempts >= 5
  ASSERT retry_config.delay >= 30
END FOR
```

### Preservation Checking

**Goal**: Verify với mọi input KHÔNG thuộc bug condition, fixed function produce kết quả giống original.

**Pseudocode:**
```
// Preservation 1: Clean VM
FOR ALL env WHERE NOT isBugCondition_HelmConflict(env) DO
  ASSERT deploy_head_services_original(env) = deploy_head_services_fixed(env)
END FOR

// Preservation 2: Lightweight ops
FOR ALL op WHERE NOT isBugCondition_InsufficientRetry(op) DO
  ASSERT retry_original(op) = retry_fixed(op)
END FOR
```

**Testing Approach**: Property-based testing được khuyến nghị cho preservation checking vì:
- Tự động generate nhiều test cases trên input domain
- Catch edge cases mà manual tests có thể bỏ sót
- Đảm bảo behavior không thay đổi cho tất cả non-buggy inputs

**Test Cases**:
1. **Clean VM Preservation**: Verify deploy trên VM sạch (helm list empty) vẫn thành công như trước
2. **Postgres Ready Preservation**: Verify khi postgres đã ready, không có unnecessary wait delay
3. **Lightweight Retry Preservation**: Verify `retry git clone` vẫn dùng 3 attempts/5s delay
4. **Non-OIDC Service Preservation**: Verify services không dùng issuer URL không bị ảnh hưởng

### Unit Tests

- Test `retry_heavy()` dùng đúng `max_attempts=5` và `delay=30`
- Test Helm cleanup logic chỉ chạy khi có existing releases
- Test postgres wait logic block deploy cho đến khi pods ready
- Test `setup_head_services_variables()` generate internal HTTP URL cho issuer
- Test edge cases: helm list empty, postgres timeout, tofu apply fail sau 5 lần

### Property-Based Tests

- Generate random deployment states (có/không có Helm releases) và verify cleanup logic hoạt động đúng
- Generate random postgres pod states và verify wait logic block/pass đúng
- Generate random operation types và verify đúng retry variant được dùng
- Test preservation: với mọi clean VM state, deploy behavior giống original

### Integration Tests

- Full pipeline test trên VM sạch: verify không có regressions
- Full pipeline test trên VM đã deploy: verify cleanup + re-deploy thành công
- Test postgres timing: deploy khi postgres đang start, verify wait logic hoạt động
- Test retry exhaustion: mock heavy op fail nhiều lần, verify extended retry cover được
