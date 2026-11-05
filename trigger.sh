#!/bin/sh

# SPDX-FileCopyrightText: 2026 Gerrit Pape <gerrit.pape@uni-paderborn.de>
#
# SPDX-License-Identifier: MIT

# Starts a pipeline through a pipeline trigger token, optionally after
# waiting for a pull mirror to fetch the commit. Pipeline variables are given
# one per line as KEY=VALUE in PIPELINE_VARIABLES.

set -u

API="https://${GITLAB_HOSTNAME}/api/v4/projects/${GITLAB_PROJECT_ID}"

output() {
  echo "$1=$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "$GITHUB_OUTPUT"
  fi
}

if [ -z "${GITLAB_TRIGGER_TOKEN:-}" ]; then
  echo "GITLAB_TRIGGER_TOKEN is not set. Create a pipeline trigger token in GitLab under Settings -> CI/CD -> Pipeline trigger tokens."
  exit 1
fi

if [ -n "${PIPELINE_REF:-}" ]; then
  ref=$PIPELINE_REF
elif [ -n "${MIRROR_BRANCH:-}" ]; then
  ref=$MIRROR_BRANCH
elif [ "${GITHUB_EVENT_NAME}" = 'pull_request' ] || [ "${GITHUB_EVENT_NAME}" = 'pull_request_target' ]; then
  ref="PullRequest_${PR_NUMBER}"
else
  ref=$GITHUB_REF_NAME
fi

# Wait until the pull mirror has fetched the commit
wait_minutes=${MIRROR_WAIT_MINUTES:-0}
if [ "$wait_minutes" -gt 0 ]; then
  wait_sha=${MIRROR_WAIT_SHA:-$GITHUB_SHA}
  deadline=$(( $(date +%s) + wait_minutes * 60 ))
  until curl --fail --silent --output /dev/null --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$API/repository/commits/$wait_sha"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "Commit $wait_sha did not appear on GitLab within $wait_minutes minutes."
      exit 1
    fi
    echo "Waiting for GitLab to fetch commit $wait_sha"
    sleep 60
  done
  echo "Commit $wait_sha is on GitLab"
fi

# Pipeline variables as form fields
set -- --form-string "token=$GITLAB_TRIGGER_TOKEN" --form-string "ref=$ref"
while IFS= read -r line; do
  case $line in
    '') continue ;;
  esac
  key=${line%%=*}
  value=${line#*=}
  if [ "$key" = "$line" ] || ! printf '%s' "$key" | grep -Eqx '[A-Za-z_][A-Za-z0-9_]*'; then
    echo "Pipeline variable '$line' is not of the form KEY=VALUE."
    exit 1
  fi
  set -- "$@" --form-string "variables[$key]=$value"
done <<EOVARIABLES
${PIPELINE_VARIABLES:-}
EOVARIABLES

echo "Starting a pipeline on ref $ref"
# GitLab refreshes its branch list shortly after a push, retry while the ref is still unknown.
deadline=$(( $(date +%s) + 120 ))
while :; do
  response=$(curl --silent --show-error --request POST "$@" "$API/trigger/pipeline")
  pipeline_id=$(printf '%s' "$response" | jq -r '.id // empty' 2>/dev/null)
  if [ -n "$pipeline_id" ]; then
    break
  fi
  if ! printf '%s' "$response" | jq -e '.message.base == ["Reference not found"]' >/dev/null 2>&1 \
    || [ "$(date +%s)" -ge "$deadline" ]; then
    echo "Starting the pipeline failed: $response"
    exit 1
  fi
  echo "GitLab does not know ref $ref yet, retrying."
  sleep 5
done

web_url=$(printf '%s' "$response" | jq -r .web_url)
output pipeline_id "$pipeline_id"
output web_url "$web_url"
output sha "$(printf '%s' "$response" | jq -r .sha)"
echo "::notice title=GitLab pipeline ${pipeline_id}::${web_url}"
