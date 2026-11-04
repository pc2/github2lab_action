#!/bin/sh

# SPDX-FileCopyrightText: 2022 Jakob Fritz <j.fritz@fz-juelich.de>
# SPDX-FileCopyrightText: 2026 Gerrit Pape <gerrit.pape@uni-paderborn.de>
#
# SPDX-License-Identifier: MIT

set -u

# Set a default waiting-time in seconds between queries,
# if the pipeline finished
DEFAULT_POLL_TIMEOUT=10
POLL_TIMEOUT=${POLL_TIMEOUT:-$DEFAULT_POLL_TIMEOUT}
MAX_WAIT_MINUTES=${MAX_WAIT_MINUTES:-0}
LOG_TRACES=${LOG_TRACES:-true}
SET_STATUS=${SET_STATUS:-true}
STATUS_CONTEXT=${STATUS_CONTEXT:-gitlab-ci}
CHECK_RUNS=${CHECK_RUNS:-false}
CHECK_PREFIX=${CHECK_PREFIX:-gitlab/}
SUMMARY=${SUMMARY:-false}

API="https://${GITLAB_HOSTNAME}/api/v4/projects/${GITLAB_PROJECT_ID}"
GITHUB_API=${GITHUB_API_URL:-https://api.github.com}

output() {
  echo "$1=$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "$GITHUB_OUTPUT"
  fi
}

gitlab() {
  curl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" --silent "$API/$1"
}

# github <method> <path> [json body]
github() {
  if [ $# -ge 3 ]; then
    curl --silent --request "$1" --header "Authorization: token ${GITHUB_TOKEN}" \
      --header "Accept: application/vnd.github+json" --data "$3" "$GITHUB_API/$2"
  else
    curl --silent --request "$1" --header "Authorization: token ${GITHUB_TOKEN}" \
      --header "Accept: application/vnd.github+json" "$GITHUB_API/$2"
  fi
}

set_status() {
  if [ "$SET_STATUS" = "true" ]; then
    github POST "repos/${GITHUB_REPOSITORY}/statuses/${target_sha}" \
      '{"state":"'"$1"'", "target_url": "'"${ci_web_url}"'", "context": "'"${STATUS_CONTEXT}"'"}' > /dev/null
  fi
}

jobs_table() {
  printf '%s' "$1" | jq -r '"| Job | Stage | Status | Duration |", "|---|---|---|---|",
    (.[] | "| [\(.name)](\(.web_url)) | \(.stage) | \(.status) | \(
      if .duration then ((.duration / 60) | floor | tostring) + " min" else "" end) |")'
}

# GitLab state to check run fields
check_fields() {
  case $1 in
    success) echo '{"status": "completed", "conclusion": "success"}' ;;
    failed) echo '{"status": "completed", "conclusion": "failure"}' ;;
    canceled) echo '{"status": "completed", "conclusion": "cancelled"}' ;;
    skipped | manual) echo '{"status": "completed", "conclusion": "skipped"}' ;;
    running) echo '{"status": "in_progress"}' ;;
    *) echo '{"status": "queued"}' ;;
  esac
}

# check_update <name> <gitlab state> <url> <title> <text>
# Creates or updates a check run on the target commit. GitHub links check
# runs of a workflow to the workflow run, so the GitLab link is in the text.
check_update() {
  id=$(jq -r --arg name "$1" '.[$name].id // empty' "$check_state")
  body=$(jq -n --arg name "$1" --arg sha "$target_sha" --arg url "$3" --arg title "$4" --arg text "$5" \
    --argjson fields "$(check_fields "$2")" \
    '{name: $name, head_sha: $sha, details_url: $url, output: {title: $title, summary: $text}} + $fields')
  if [ -n "$id" ]; then
    github PATCH "repos/${GITHUB_REPOSITORY}/check-runs/$id" "$body" > /dev/null
  else
    id=$(github POST "repos/${GITHUB_REPOSITORY}/check-runs" "$body" | jq -r '.id // empty')
  fi
  jq --arg name "$1" --arg id "$id" --arg state "$2" '.[$name] = {id: $id, state: $state}' "$check_state" > "$check_state.new"
  mv "$check_state.new" "$check_state"
}

# Picks up check runs of earlier runs on the same commit, so that a workflow
# that attaches to a running pipeline updates them instead of adding new ones.
checks_init() {
  check_state="${RUNNER_TEMP:-/tmp}/github2lab_checks_${pipeline_id}.json"
  github GET "repos/${GITHUB_REPOSITORY}/commits/${target_sha}/check-runs?per_page=100" |
    jq --arg prefix "$CHECK_PREFIX" '[.check_runs[]? | select(.name | startswith($prefix))
      | {key: .name, value: {id: (.id | tostring), state: ""}}] | from_entries' > "$check_state"
}

checks_sync() {
  changed=false
  while IFS= read -r job; do
    [ -n "$job" ] || continue
    name="${CHECK_PREFIX}$(printf '%s' "$job" | jq -r .name)"
    state=$(printf '%s' "$job" | jq -r .status)
    if [ "$(jq -r --arg name "$name" '.[$name].state // empty' "$check_state")" = "$state" ]; then
      continue
    fi
    url=$(printf '%s' "$job" | jq -r .web_url)
    check_update "$name" "$state" "$url" "$state" "[$(printf '%s' "$job" | jq -r .name)]($url): $state"
    changed=true
  done <<EOJOBS
$(printf '%s' "$ci_jobs_json" | jq -c '.[]')
EOJOBS
  name="${CHECK_PREFIX}pipeline"
  if [ "$changed" = true ] || [ "$(jq -r --arg name "$name" '.[$name].state // empty' "$check_state")" != "$ci_status" ]; then
    check_update "$name" "$ci_status" "$ci_web_url" "pipeline ${pipeline_id} ${ci_status}" \
      "$(printf '### GitLab pipeline [%s](%s): %s\n\n' "$pipeline_id" "$ci_web_url" "$ci_status"; jobs_table "$ci_jobs_json")"
  fi
}

write_summary() {
  if [ "$SUMMARY" = "true" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '### GitLab pipeline [%s](%s): %s\n\n' "$pipeline_id" "$ci_web_url" "$ci_status"
      jobs_table "$ci_jobs_json"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

if [ -n "${MIRROR_BRANCH:+1}" ]
  then
    used_sha=$(git rev-parse "$MIRROR_BRANCH")
    branch_name=${MIRROR_BRANCH}
elif [ "${GITHUB_EVENT_NAME}" = 'pull_request' ] || [ "${GITHUB_EVENT_NAME}" = 'pull_request_target' ]
  then
    used_sha=${PR_HEAD_SHA}
    branch_name=PullRequest_${PR_NUMBER}
else
    used_sha=${GITHUB_SHA}
    branch_name=${GITHUB_REF}
fi

if [ -n "${PIPELINE_ID:-}" ]; then
  pipeline_id=$PIPELINE_ID
  echo "Attaching to pipeline ${pipeline_id}"
else
  echo "Triggered CI for branch ${branch_name}"
  # Get the id of the last pipeline that run for a given commit (GITHUB_SHA)
  pipeline_id=$(gitlab "repository/commits/${used_sha}" | jq '.last_pipeline.id')

  pipeline_id_attempt=1
  until [ "$pipeline_id" != "null" ]
  do
    sleep "$POLL_TIMEOUT"
    pipeline_id=$(gitlab "repository/commits/${used_sha}" | jq '.last_pipeline.id')
    pipeline_id_attempt=$((pipeline_id_attempt + 1))
    if [ "$pipeline_id_attempt" -gt "5" ]
    then
      echo "Failed to fetch pipeline id for ${used_sha}"
      exit 1
    fi
  done
fi

ci_output=$(gitlab "pipelines/${pipeline_id}")
ci_status=$(printf '%s' "$ci_output" | jq -r '.status // empty')
if [ -z "$ci_status" ]; then
  echo "Failed to read pipeline ${pipeline_id}: ${ci_output}"
  exit 1
fi
ci_web_url=$(printf '%s' "$ci_output" | jq -r .web_url)
if [ -n "${TARGET_SHA:-}" ]; then
  target_sha=$TARGET_SHA
elif [ -n "${PIPELINE_ID:-}" ]; then
  target_sha=$(printf '%s' "$ci_output" | jq -r .sha)
else
  target_sha=$used_sha
fi

echo "Working with pipeline id #${pipeline_id}"
echo "::notice title=GitLab pipeline ${pipeline_id}::${ci_web_url}"
echo "Poll timeout set to ${POLL_TIMEOUT} s"
output pipeline_id "$pipeline_id"
output web_url "$ci_web_url"
output sha "$target_sha"

if [ "$CHECK_RUNS" = "true" ]; then
  checks_init
fi
deadline=0
if [ "$MAX_WAIT_MINUTES" -gt 0 ]; then
  deadline=$(( $(date +%s) + MAX_WAIT_MINUTES * 60 ))
fi

ci_status="pending"

# Repeat until the pipeline is neither pending nor running
until [ "$ci_status" != "created" ] && [ "$ci_status" != "preparing" ] && [ "$ci_status" != "pending" ] && [ "$ci_status" != "running" ]
do
  # Wait some seconds
   sleep "$POLL_TIMEOUT"
   # Get the current state of the pipeline and the url of the website
   ci_output=$(gitlab "pipelines/${pipeline_id}")
   ci_status=$(printf '%s' "$ci_output" | jq -r .status)

   echo "Current pipeline status: ${ci_status}"
   if [ "$CHECK_RUNS" = "true" ]; then
     ci_jobs_json=$(gitlab "pipelines/${pipeline_id}/jobs?per_page=100")
     checks_sync
   fi
   # If the pipeline is running, print the current state (to end loop)
   if [ "$ci_status" = "running" ]
   then
     echo "Checking pipeline status..."
     set_status pending
   fi
   if [ "$deadline" -gt 0 ] && [ "$(date +%s)" -ge "$deadline" ]; then
     case $ci_status in
       created | preparing | pending | running)
         echo "Pipeline still ${ci_status} after ${MAX_WAIT_MINUTES} minutes, stopping to wait."
         output finished false
         output status "$ci_status"
         exit 0
         ;;
     esac
   fi
done
# Pipeline is done
output finished true
output status "$ci_status"

# Show status of the pipeline
echo "Pipeline finished with status ${ci_status}"
echo "Fetching all GitLab pipeline jobs involved"
ci_jobs_json=$(gitlab "pipelines/${pipeline_id}/jobs?per_page=100")
if [ "$CHECK_RUNS" = "true" ]; then
  checks_sync
fi
write_summary
if [ "$LOG_TRACES" = "true" ]; then
  # And get jobs that ran in this pipeline
  ci_jobs=$(printf '%s' "$ci_jobs_json" | jq -r '.[] | { id, name, stage }')
  # Give information on each job, but collapse this to not clutter the report
  echo "Posting output from all GitLab pipeline jobs"
  for JOB_ID in $(echo "$ci_jobs" | jq -r .id); do
    echo "##[group]Stage $( echo "$ci_jobs" | jq -r "select(.id==$JOB_ID) | .stage" ) / Job $( echo "$ci_jobs" | jq -r "select(.id==$JOB_ID) | .name" )"
    gitlab "jobs/${JOB_ID}/trace"
    echo "##[endgroup]"
  done
  echo "Debug problems by unfolding stages/jobs above"
fi
# Give the URL of the pipeline to make it easier to find and remove errors
echo "For more details on the Jobs see: ${ci_web_url}"

# Set result of the pipeline (success or failure) to own job (via curl)
# and return that as a return-code (0 for success; 1 for failure)
if [ "$ci_status" = "success" ]
then
  set_status success
  exit 0
elif [ "$ci_status" = "failed" ]
then
  set_status failure
  exit 1
else
  exit 1
fi
