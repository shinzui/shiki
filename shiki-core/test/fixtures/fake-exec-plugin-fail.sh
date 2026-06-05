#!/usr/bin/env bash
# Stand-in for a plugin that cannot authenticate (e.g. gcloud not logged in).
echo "fake-exec-plugin: boom — could not obtain credentials" >&2
exit 1
