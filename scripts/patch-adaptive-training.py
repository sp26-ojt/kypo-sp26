#!/usr/bin/env python3
import json, sys, os

public_host = os.environ.get("PUBLIC_HOST", "")
cm = json.load(sys.stdin)
data = cm.get("data", {})

for key in data:
    if "elasticsearch.port=9200" in data[key]:
        lines = data[key].splitlines()
        keys_to_remove = [
            "server.base-url",
            "frontend.url",
            "spring.flyway.repair-on-migrate",
            "spring.main.allow-bean-definition-overriding",
        ]
        lines = [l for l in lines if not any(l.startswith(k + "=") for k in keys_to_remove)]

        insert_at = next(i + 1 for i, l in enumerate(lines) if "elasticsearch.port=9200" in l)
        extra = [
            f"server.base-url=https://{public_host}/adaptive-training/api/v1",
            f"frontend.url=https://{public_host}",
            "spring.flyway.repair-on-migrate=true",
            "spring.main.allow-bean-definition-overriding=true",
            "spring.autoconfigure.exclude=cz.cyberrange.platform.commons.security.config.ResourceServerSecurityConfig",
        ]
        for j, line in enumerate(extra):
            lines.insert(insert_at + j, line)

        data[key] = "\n".join(lines)

cm["data"] = data
print(json.dumps(cm))

