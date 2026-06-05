#!/usr/bin/env bash
# Stand-in for a plugin that returns client-certificate credentials (mTLS),
# which shiki does not yet support — the runner must reject this explicitly.
set -euo pipefail

cat <<'EOF'
{"apiVersion":"client.authentication.k8s.io/v1beta1","kind":"ExecCredential","status":{"clientCertificateData":"-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----","clientKeyData":"-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----"}}
EOF
