#!/usr/bin/env bash
# Derive the release tag and name from the triggering event.
#
# For tag pushes: use the pushed tag ref.
# For workflow_dispatch: use INPUT_TAG, or auto-generate from UTC timestamp.
#   Also create and push the tag so action-gh-release has something to attach.
#
# Inputs (env vars, set by the workflow):
#   EVENT_NAME        "push" or "workflow_dispatch"
#   GITHUB_REF_NAME   set for push tag events
#   INPUT_TAG         optional manual tag (workflow_dispatch)
#   INPUT_NAME        optional release name (workflow_dispatch)
#   HEAD_SHA          commit to tag (workflow_dispatch)
#
# Outputs (written to $GITHUB_OUTPUT):
#   tag, name

set -euo pipefail

if [ "${EVENT_NAME:-}" = "push" ]; then
    tag="$GITHUB_REF_NAME"
    name="$GITHUB_REF_NAME"
else
    tag="${INPUT_TAG:-}"
    if [ -z "$tag" ]; then
        tag="v$(date -u +%Y.%m.%d-%H%M)"
    fi
    name="${INPUT_NAME:-$tag}"

    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git tag "$tag" "$HEAD_SHA" || true
    git push origin "$tag" || true
fi

echo "tag=$tag"   >> "$GITHUB_OUTPUT"
echo "name=$name" >> "$GITHUB_OUTPUT"
echo "Resolved tag=$tag name=$name"
