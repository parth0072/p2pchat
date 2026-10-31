#!/bin/bash
# Stages, commits, and pushes all pending MeshChat changes.
#
# Usage:
#   chmod +x push.sh
#   ./push.sh "your commit message"
#
# If no message is given, a default one is used.

set -e

cd "$(dirname "$0")"

MESSAGE="${1:-Update MeshChat}"

git add -A
git status --short

git commit -m "$MESSAGE" || echo "Nothing to commit."
# -u origin HEAD works on main and on a brand-new branch with no upstream yet.
git push -u origin HEAD
