# Bugfix Requirements Document

## Introduction

Build pipeline (`scripts/03-infrastructure-deploy.sh`) không đạt 100% success rate khi chạy trên VM cũ hoặc khi re-deploy. Bốn lỗi độc lập được xác định: Helm release conflict, timing race condition với postgres, SSL/TLS trust failure trong Java services, và retry logic không đủ cho các heavy operations. Các lỗi này gây pipeline fail ở phase 3 (infrastructure deployment), yêu cầu can thiệp thủ công để recover.

## Bug Analysis

### Current Behavior (Defect)

1.1 WHEN `deploy_head_services()` chạy trên VM đã có Helm releases từ lần deploy trước THEN hệ thống báo lỗi "cannot re-use a name that is still in use" và dừng deployment

1.2 WHEN `deploy_head_services()` chạy mà postgres cluster chưa healthy THEN pod `head-hook-preinstall` fail và Helm install của head chart bị abort

1.3 WHEN các backend services (training-service, adaptive-training-service, uag-service, v.v.) khởi động và fetch Keycloak OIDC configuration qua HTTPS external URL (`https://<head_host>/keycloak/...`) THEN Java truststore từ chối self-signed certificate với lỗi "PKIX path building failed"

1.4 WHEN `retry()` trong `utils.sh` được gọi cho các heavy operations như Helm install hoặc `tofu apply` THEN hệ thống chỉ retry 3 lần với 5 giây delay, không đủ thời gian cho các operations có thể mất vài phút để recover

### Expected Behavior (Correct)

2.1 WHEN `deploy_head_services()` chạy trên VM đã có Helm releases cũ THEN hệ thống SHALL tự động cleanup (uninstall) các Helm releases xung đột trước khi deploy, đảm bảo deploy thành công mà không cần can thiệp thủ công

2.2 WHEN `deploy_head_services()` chuẩn bị deploy head chart THEN hệ thống SHALL wait cho postgres cluster ở trạng thái healthy (tất cả pods running/ready) trước khi tiến hành, với timeout hợp lý

2.3 WHEN các backend services fetch Keycloak OIDC configuration THEN hệ thống SHALL sử dụng internal HTTP URL (`http://keycloak-service:8080/keycloak/...`) thay vì HTTPS external URL, tránh SSL certificate validation hoàn toàn

2.4 WHEN `retry()` được gọi cho heavy operations THEN hệ thống SHALL sử dụng số lần retry và delay phù hợp (ví dụ: 5 lần retry với 30 giây delay) để cover các transient failures của Helm và Terraform

### Unchanged Behavior (Regression Prevention)

3.1 WHEN deploy chạy lần đầu trên VM sạch (không có Helm releases cũ) THEN hệ thống SHALL CONTINUE TO deploy thành công như hiện tại, không bị ảnh hưởng bởi cleanup logic

3.2 WHEN postgres cluster đã healthy trước khi `deploy_head_services()` chạy THEN hệ thống SHALL CONTINUE TO deploy head chart ngay lập tức mà không có delay không cần thiết

3.3 WHEN các services không liên quan đến Keycloak OIDC (không dùng issuer URL) hoạt động THEN hệ thống SHALL CONTINUE TO hoạt động bình thường, không bị ảnh hưởng bởi thay đổi URL config

3.4 WHEN `retry()` được gọi cho các lightweight operations (git clone, kubectl commands) THEN hệ thống SHALL CONTINUE TO hoạt động với behavior hiện tại, không bị delay không cần thiết

3.5 WHEN `deploy_base_infrastructure()` và các Terraform operations khác chạy THEN hệ thống SHALL CONTINUE TO hoạt động đúng như hiện tại

---

## Bug Condition Pseudocode

### Bug 1: Helm Release Conflict

```pascal
FUNCTION isBugCondition_HelmConflict(env)
  INPUT: env = deployment environment state
  OUTPUT: boolean

  RETURN helm list --all-namespaces | contains existing releases
END FUNCTION

// Fix Checking
FOR ALL env WHERE isBugCondition_HelmConflict(env) DO
  result ← deploy_head_services'(env)
  ASSERT result = SUCCESS AND no "cannot re-use a name" error
END FOR

// Preservation Checking
FOR ALL env WHERE NOT isBugCondition_HelmConflict(env) DO
  ASSERT deploy_head_services(env) = deploy_head_services'(env)
END FOR
```

### Bug 2: Postgres Timing Race Condition

```pascal
FUNCTION isBugCondition_PostgresNotReady(env)
  INPUT: env = cluster state at time of head chart deploy
  OUTPUT: boolean

  RETURN postgres pods NOT all in Running/Ready state
END FUNCTION

// Fix Checking
FOR ALL env WHERE isBugCondition_PostgresNotReady(env) DO
  result ← deploy_head_services'(env)
  ASSERT result = SUCCESS AND head-hook-preinstall pod does NOT fail
END FOR
```

### Bug 3: SSL/TLS PKIX Failure

```pascal
FUNCTION isBugCondition_SSLFailure(config)
  INPUT: config = backend service ConfigMap
  OUTPUT: boolean

  RETURN config.issuerUrl STARTS_WITH "https://"
END FUNCTION

// Fix Checking
FOR ALL config WHERE isBugCondition_SSLFailure(config) DO
  result ← service_startup'(config)
  ASSERT result = SUCCESS AND no "PKIX path building failed" error
END FOR
```

### Bug 4: Insufficient Retry

```pascal
FUNCTION isBugCondition_InsufficientRetry(op)
  INPUT: op = heavy operation (Helm install, tofu apply)
  OUTPUT: boolean

  RETURN op.type IN {helm_install, tofu_apply} AND retry.max_attempts <= 3
END FUNCTION

// Fix Checking
FOR ALL op WHERE isBugCondition_InsufficientRetry(op) DO
  result ← retry'(op)
  ASSERT result = SUCCESS within extended retry window
END FOR
```
