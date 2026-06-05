#!/usr/bin/env bash
# Stand-in for gke-gcloud-auth-plugin. Mints a known token, but only when it
# can see KUBERNETES_EXEC_INFO — this lets a test assert that shiki actually
# passes the cluster info through (provideClusterInfo) by toggling that flag.
set -euo pipefail

if [ -z "${KUBERNETES_EXEC_INFO:-}" ]; then
  echo "fake-exec-plugin: KUBERNETES_EXEC_INFO was not set" >&2
  exit 3
fi

cat <<'EOF'
{"apiVersion":"client.authentication.k8s.io/v1beta1","kind":"ExecCredential","status":{"token":"ya29.test-token","expirationTimestamp":"2026-06-05T20:14:35Z"}}
EOF
