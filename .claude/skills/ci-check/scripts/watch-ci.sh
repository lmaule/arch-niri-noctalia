#!/usr/bin/env bash
# Wait for the GitHub "Install test" run for a commit, print each check's
# result and save the job log for ci-timings.py.
#
# Usage: watch-ci.sh [commit-sha | run-id] [log-file]
#   default commit: HEAD of this repo; default log: $TMPDIR/ci-<run-id>.log
# Needs: gh (authenticated), git.

set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
repo_dir=$(cd "$here/../../../.." && pwd)
slug=$(git -C "$repo_dir" remote get-url origin | sed -E 's#(\.git)?$##; s#.*github\.com[:/]##')
target=${1:-$(git -C "$repo_dir" rev-parse HEAD)}

if [[ $target =~ ^[0-9]+$ ]]; then
  run=$target
else
  run=""
  for _ in $(seq 1 20); do   # the run can take a few seconds to appear after a push
    run=$(gh api "repos/$slug/actions/runs?head_sha=$target" --jq '.workflow_runs[0].id // empty' 2>/dev/null)
    [[ -n $run ]] && break
    sleep 6
  done
  [[ -n $run ]] || { echo "No CI run found for $target in $slug" >&2; exit 2; }
fi
echo "run: https://github.com/$slug/actions/runs/$run"

while true; do
  status=$(gh api "repos/$slug/actions/runs/$run" --jq '.status + " " + (.conclusion // "")')
  [[ $status == completed* ]] && break
  sleep 60
done
echo "result: ${status#completed }"
gh api "repos/$slug/actions/runs/$run/jobs" --jq '.jobs[0].steps[] | "  \(.conclusion // .status)\t\(.name)"'

log=${2:-${TMPDIR:-/tmp}/ci-$run.log}
job=$(gh api "repos/$slug/actions/runs/$run/jobs" --jq '.jobs[0].id')
gh api "repos/$slug/actions/jobs/$job/logs" > "$log" 2>/dev/null && echo "log: $log"
[[ $status == "completed success" ]]
