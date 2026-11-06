#!/bin/sh

# SPDX-FileCopyrightText: 2022 Jakob Fritz <j.fritz@fz-juelich.de>
# SPDX-FileCopyrightText: 2026 Gerrit Pape <gerrit.pape@uni-paderborn.de>
#
# SPDX-License-Identifier: MIT

set -u

echo "Getting the URL of the repo"
if ! project_json=$(curl --fail --silent --show-error --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://${GITLAB_HOSTNAME}/api/v4/projects/${GITLAB_PROJECT_ID}") ||
  ! GITLAB_REPO_URL=$(printf '%s' "$project_json" | jq -er '.http_url_to_repo | select(type == "string" and length > 0)') ||
  [ -z "$GITLAB_REPO_URL" ]; then
  echo "::error::Cannot read the repository URL for GitLab project ${GITLAB_PROJECT_ID} on ${GITLAB_HOSTNAME}."
  echo "Check GITLAB_HOSTNAME and GITLAB_PROJECT_ID, and ensure GITLAB_TOKEN has API access to this project."
  exit 1
fi
GITLAB_REPO_URL=${GITLAB_REPO_URL#https://}
GITLAB_REPO_URL=${GITLAB_REPO_URL#http://}
echo "URL is https://${GITLAB_REPO_URL}"

# Add the remote Gitlab-Repo to the local git
echo "adding gitlab-repo as remote"
git remote add gitlab "https://TOKENUSER:${GITLAB_TOKEN}@${GITLAB_REPO_URL}" || exit 1
trap 'git remote remove gitlab > /dev/null 2>&1 || :' 0
if [ -n "${MIRROR_SHA:-}" ]; then
  git rev-parse --verify --end-of-options "${MIRROR_SHA}^{commit}" > /dev/null || exit 1
  BRANCHNAME=${MIRROR_BRANCH:-$GITHUB_REF_NAME}
  push_ref="${MIRROR_SHA}:refs/heads/${BRANCHNAME}"
else
  # Get current state of local git
  echo "Running git fetch, git checkout, git pull"
  # Get the current state of the single branch from the GitHub-Repo
  # In case this is a pull-request, add this to fetch

  # First unshallow the git repository
  if "$(git rev-parse --is-shallow-repository)"; then
    git fetch --unshallow
  else
    git fetch
  fi

  if [ -n "${MIRROR_BRANCH:+1}" ]
  then
    sh -c "git fetch --prune --no-tags --force origin"
    sh -c "git checkout ${MIRROR_BRANCH}"
    BRANCHNAME="${MIRROR_BRANCH}"
  elif [ "${GITHUB_EVENT_NAME}" = 'pull_request' ] || [ "${GITHUB_EVENT_NAME}" = 'pull_request_target' ]
  then
    sh -c "git fetch --prune --no-tags --force origin +${PR_HEAD_SHA}"
    sh -c "git checkout ${PR_HEAD_SHA}"
    BRANCHNAME="PullRequest_${PR_NUMBER}"
    sh -c "git branch $BRANCHNAME"
    sh -c "git checkout $BRANCHNAME"
  else
    sh -c "git fetch --prune --no-tags --force origin"
    sh -c "git checkout ${GITHUB_REF_NAME}"
    sh -c "git pull --no-tags --force origin ${GITHUB_REF_NAME}"
    BRANCHNAME="${GITHUB_REF_NAME}"
  fi

  push_ref=$BRANCHNAME
fi

echo "git status is:"
git status
echo "Pushing to new gitlab remote"
# Push the current state of the repo to GitLab
set --
if [ "${FORCE_PUSH:-}" = "true" ]; then
  set -- "$@" --force
fi
# Concurrent mirrors of one branch make the remote reject a push while the ref is locked, retry it.
attempt=0
while :; do
  git push "$@" gitlab "$push_ref" >push_out 2>&1
  ret_code=$?
  attempt=$((attempt + 1))
  if [ "$ret_code" = 0 ] || [ "$attempt" -ge 5 ] || ! grep -q "cannot lock ref" push_out; then
    break
  fi
  echo "The remote branch is locked by another push, retrying."
  sleep 5
done
push_out_var=$(cat push_out)
echo "$push_out_var"

if [ "${MIRROR_ONLY:-false}" != "true" ] && grep "Everything up-to-date" < push_out ; then
  echo "No changes occured, so no need to push again; triggering Pipeline instead."
  post_reply=$(curl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" --silent --request POST -d "ref=$BRANCHNAME" "https://${GITLAB_HOSTNAME}/api/v4/projects/${GITLAB_PROJECT_ID}/pipeline")
  web_url=$(echo "$post_reply" | jq '.web_url')
  echo "Triggered pipeline can be found here: $web_url"
  exit "$ret_code"
fi 

if [ "$ret_code" = 0 ]; then
  # Report, that pushing is done and add newline afterwards for formatting
  echo "Done pushing git-repo to https://${GITLAB_REPO_URL}"
else
  # Report, that pushing resulted in an error
  echo "Seems as if an error occured while pushing to https://${GITLAB_REPO_URL}. See above for details"
fi
echo ""
exit "$ret_code"
