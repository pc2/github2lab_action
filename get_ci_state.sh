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
POLL_FAILURE_MINUTES=${POLL_FAILURE_MINUTES:-30}
STOP_ON_MANUAL=${STOP_ON_MANUAL:-false}
LOG_TRACES=${LOG_TRACES:-true}
SET_STATUS=${SET_STATUS:-true}
STATUS_CONTEXT=${STATUS_CONTEXT:-gitlab-ci}
CHECK_RUNS=${CHECK_RUNS:-false}
CHECK_PREFIX=${CHECK_PREFIX:-gitlab/}
PIPELINE_CHECK_NAME=${PIPELINE_CHECK_NAME:-${CHECK_PREFIX}pipeline}
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
  curl --fail --silent --show-error --retry 3 --max-time 60 \
    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$API/$1"
}

pipeline_status() {
  printf '%s' "$1" | jq -er '.status | select(IN(
    "created", "waiting_for_resource", "preparing", "waiting_for_callback",
    "pending", "running", "manual", "scheduled", "canceling",
    "success", "failed", "canceled", "skipped"))'
}

# A pipeline blocked by a manual job only continues after a person plays it.
# STOP_ON_MANUAL ends the monitoring there instead of waiting.
pipeline_finished() {
  case $1 in
    success | failed | canceled | skipped) return 0 ;;
    manual) [ "$STOP_ON_MANUAL" = "true" ] ;;
    *) return 1 ;;
  esac
}

# Reads the pipeline into ci_output and ci_status.
# Failed reads are retried, so a GitLab outage shorter than POLL_FAILURE_MINUTES does not end the monitoring.
# Returns 1 when the monitoring deadline passes during an outage, so the caller can hand over.
read_pipeline() {
  failing_since=$(date +%s)
  while :; do
    if ci_output=$(gitlab "pipelines/${pipeline_id}") && read_status=$(pipeline_status "$ci_output"); then
      ci_status=$read_status
      return 0
    fi
    now=$(date +%s)
    if [ "$deadline" -gt 0 ] && [ "$now" -ge "$deadline" ]; then
      return 1
    fi
    if [ $((now - failing_since)) -ge $((POLL_FAILURE_MINUTES * 60)) ]; then
      echo "Failed to read pipeline ${pipeline_id} for ${POLL_FAILURE_MINUTES} minutes: ${ci_output}"
      exit 1
    fi
    echo "Reading pipeline ${pipeline_id} failed, retrying: ${ci_output}"
    sleep "$POLL_TIMEOUT"
  done
}

# gitlab_list <path> <file>: writes all pages of a GitLab list endpoint to the file as one JSON array.
gitlab_list() {
  list_page=1
  : > "$2.pages"
  while :; do
    gitlab "$1?per_page=100&page=${list_page}" > "$2.page" &&
      jq -e 'type == "array"' "$2.page" > /dev/null 2>&1 || return 1
    cat "$2.page" >> "$2.pages"
    [ "$(jq length "$2.page")" -ge 100 ] || break
    list_page=$((list_page + 1))
  done
  jq -s 'add // []' "$2.pages" > "$2"
}

# pipeline_jobs <pipeline id>: prints the jobs of the pipeline and of its child pipelines in this project.
# Child jobs are named <trigger job>/<job>, so they cannot collide with jobs of the parent.
pipeline_jobs() {
  work=$(mktemp -d) || return 1
  printf '[{"id": %s, "prefix": ""}]' "$1" > "$work/queue"
  : > "$work/jobs"
  jobs_failed=0
  while [ "$(jq length "$work/queue")" -gt 0 ]; do
    child_id=$(jq -r '.[0].id' "$work/queue")
    prefix=$(jq -r '.[0].prefix' "$work/queue")
    if ! gitlab_list "pipelines/${child_id}/jobs" "$work/list"; then
      jobs_failed=1
      break
    fi
    jq --arg prefix "$prefix" 'map(.name = $prefix + .name)' "$work/list" >> "$work/jobs"
    if ! gitlab_list "pipelines/${child_id}/bridges" "$work/list"; then
      jobs_failed=1
      break
    fi
    jq --arg prefix "$prefix" --argjson project "$GITLAB_PROJECT_ID" --slurpfile queue "$work/queue" \
      '$queue[0][1:] + [.[] | select(.downstream_pipeline.project_id? == $project)
        | {id: .downstream_pipeline.id, prefix: ($prefix + .name + "/")}]' "$work/list" > "$work/queue.new"
    mv "$work/queue.new" "$work/queue"
  done
  if [ "$jobs_failed" = 0 ]; then
    jq -s 'add // []' "$work/jobs"
  fi
  rm -rf "$work"
  return "$jobs_failed"
}

# Reads the jobs of the pipeline into ci_jobs_json, returns 1 after repeated failures.
read_jobs() {
  for attempt in 1 2 3 4 5; do
    if ci_jobs_json=$(pipeline_jobs "$pipeline_id"); then
      return 0
    fi
    echo "Reading the jobs of pipeline ${pipeline_id} failed, attempt ${attempt}."
    sleep "$POLL_TIMEOUT"
  done
  return 1
}

# github <method> <path> [json body]
github() {
  if [ $# -ge 3 ]; then
    curl --silent --retry 3 --max-time 60 --request "$1" --header "Authorization: token ${GITHUB_TOKEN}" \
      --header "Accept: application/vnd.github+json" --data "$3" "$GITHUB_API/$2"
  else
    curl --silent --retry 3 --max-time 60 --request "$1" --header "Authorization: token ${GITHUB_TOKEN}" \
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
    skipped) echo '{"status": "completed", "conclusion": "skipped"}' ;;
    manual)
      if [ "$STOP_ON_MANUAL" = "true" ]; then
        echo '{"status": "completed", "conclusion": "action_required"}'
      else
        echo '{"status": "queued"}'
      fi
      ;;
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
  : > "$check_state.pages"
  check_page=1
  while :; do
    github GET "repos/${GITHUB_REPOSITORY}/commits/${target_sha}/check-runs?per_page=100&page=${check_page}" > "$check_state.page"
    jq '[.check_runs[]?]' "$check_state.page" >> "$check_state.pages" 2> /dev/null || break
    [ "$(jq '.check_runs | length' "$check_state.page" 2> /dev/null || echo 0)" -ge 100 ] || break
    check_page=$((check_page + 1))
  done
  jq -s --arg prefix "$CHECK_PREFIX" --arg pipeline "$PIPELINE_CHECK_NAME" \
    '[add // [] | .[] | select((.name | startswith($prefix)) or .name == $pipeline)
    | {key: .name, value: {id: (.id | tostring), state: ""}}] | from_entries' "$check_state.pages" > "$check_state"
  rm -f "$check_state.page" "$check_state.pages"
}

checks_sync() {
  changed=false
  while IFS= read -r job; do
    [ -n "$job" ] || continue
    name="${CHECK_PREFIX}$(printf '%s' "$job" | jq -r .name)"
    state=$(printf '%s' "$job" | jq -r .status)
    if [ "$state" = "manual" ] &&
      [ "$(printf '%s' "$job" | jq -r .allow_failure)" = "true" ]; then
      state=skipped
    fi
    if [ "$(jq -r --arg name "$name" '.[$name].state // empty' "$check_state")" = "$state" ]; then
      continue
    fi
    url=$(printf '%s' "$job" | jq -r .web_url)
    check_update "$name" "$state" "$url" "$state" "[$(printf '%s' "$job" | jq -r .name)]($url): $state"
    changed=true
  done <<EOJOBS
$(printf '%s' "$ci_jobs_json" | jq -c '.[]')
EOJOBS
  name=$PIPELINE_CHECK_NAME
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

deadline=0
if [ "$MAX_WAIT_MINUTES" -gt 0 ]; then
  deadline=$(( $(date +%s) + MAX_WAIT_MINUTES * 60 ))
fi
if ! read_pipeline; then
  echo "GitLab was unreachable until the deadline, stopping to wait."
  output finished false
  output status unknown
  exit 0
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

ci_status="pending"

# Only terminal pipeline states permit result collection.
until pipeline_finished "$ci_status"
do
  # Wait some seconds
   sleep "$POLL_TIMEOUT"
   # Get the current state of the pipeline, an outage reaching the deadline hands over below
   if read_pipeline; then
     echo "Current pipeline status: ${ci_status}"
     if [ "$CHECK_RUNS" = "true" ] && read_jobs; then
       checks_sync
     fi
     # If the pipeline is running, print the current state (to end loop)
     if [ "$ci_status" = "running" ]
     then
       echo "Checking pipeline status..."
       set_status pending
     fi
   fi
   if [ "$deadline" -gt 0 ] && [ "$(date +%s)" -ge "$deadline" ] &&
     ! pipeline_finished "$ci_status"; then
     echo "Pipeline still ${ci_status} after ${MAX_WAIT_MINUTES} minutes, stopping to wait."
     output finished false
     output status "$ci_status"
     exit 0
   fi
done
# Pipeline is done
output finished true
output status "$ci_status"

# Show status of the pipeline
echo "Pipeline finished with status ${ci_status}"
echo "Fetching all GitLab pipeline jobs involved"
if ! read_jobs; then
  echo "::warning title=GitLab jobs unavailable::The job list of pipeline ${pipeline_id} could not be read, job checks and summary are incomplete."
  ci_jobs_json='[]'
fi
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
