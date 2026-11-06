#!/usr/bin/env python

# SPDX-FileCopyrightText: 2023 Jakob Fritz <j.fritz@fz-juelich.de>
# SPDX-FileCopyrightText: 2026 Gerrit Pape <gerrit.pape@uni-paderborn.de>
#
# SPDX-License-Identifier: MIT

"""
Group of functions to find and download artifacts from Gitlab-CI-jobs
in a pipeline to a given commit.
It is designed to be called from within Github-Actions
and uses environment-variables as input.
"""

import os
import subprocess
import zipfile
from os import environ as env

import requests

ARTIFACT_DIR = os.getenv("ARTIFACT_DIR") or "artifacts"


def get_job_list():
    """
    This function gets a list of jobs in the pipeline of a Gitlab-CI
    for a given commit.
    It does not take any arguments, but uses environment-variables.

    The following environment-variables are needed:
    GITLAB_HOSTNAME: The hostname of the gitlab-instance (e.g gitlab.com)
    GITLAB_PROJECT_ID: ID of the project (e.g. 1234)
    GITLAB_TOKEN: A secret token to access gitlab with more rights
    GITHUB_SHA: The SHA of the last commit that was pushed
    PR_HEAD_SHA: The SHA of the latest commit in a Pull Request
    PIPELINE_ID: Optional, takes this pipeline instead of the commit's last one
    ARTIFACT_STAGES: Optional, space separated stages whose jobs are kept
    """
    headers = {"PRIVATE-TOKEN": env["GITLAB_TOKEN"]}
    pipeline_id = os.getenv("PIPELINE_ID")
    if pipeline_id:
        print(f"Pipeline-ID is {pipeline_id}")
        return filter_stages(get_jobs(pipeline_id, headers))
    if os.getenv("MIRROR_BRANCH") not in [None, ""]:
        print(f"Used branch is: {os.getenv('MIRROR_BRANCH')}")
        used_sha = subprocess.run(
            ["git", "rev-parse", f"{os.getenv('MIRROR_BRANCH')}"],
            capture_output=True,
            text=True,
            check=False,
        ).stdout
        # strip whitespaces (incl. newlines)
        used_sha = used_sha.strip()
    elif env["GITHUB_EVENT_NAME"] in ["pull_request", "pull_request_target"]:
        used_sha = env["PR_HEAD_SHA"]
    else:
        used_sha = env["GITHUB_SHA"]
    pipeline_url = (
        f"https://{env['GITLAB_HOSTNAME']}/api/v4/projects/"
        + f"{env['GITLAB_PROJECT_ID']}/repository/commits/{used_sha}"
    )
    # Get the pipeline for the commit
    response = requests.get(pipeline_url, headers=headers)
    # Raise an error if the request was not successfull
    response.raise_for_status()
    pipeline_id = response.json()["last_pipeline"]["id"]
    print(f"Pipeline-ID is {pipeline_id}")
    return filter_stages(get_jobs(pipeline_id, headers))


def get_list(path, headers):
    """
    Returns all pages of a GitLab list endpoint below the project.
    """
    url = f"https://{env['GITLAB_HOSTNAME']}/api/v4/projects/{env['GITLAB_PROJECT_ID']}/{path}"
    items = []
    page = 1
    while True:
        response = requests.get(
            url, headers=headers, params={"per_page": 100, "page": page}, timeout=60
        )
        response.raise_for_status()
        chunk = response.json()
        if not isinstance(chunk, list):
            raise TypeError(f"Unexpected response for {path}.")
        items += chunk
        if len(chunk) < 100:
            return items
        page += 1


def get_jobs(pipeline_id, headers):
    """
    Returns all jobs of a pipeline and of its child pipelines in the same project.
    Child jobs are named <trigger job>/<job>, so they cannot collide with jobs of the parent.
    """
    jobs = []
    queue = [(pipeline_id, "")]
    while queue:
        current, prefix = queue.pop(0)
        jobs += [
            job | {"name": prefix + job["name"]}
            for job in get_list(f"pipelines/{current}/jobs", headers)
        ]
        for bridge in get_list(f"pipelines/{current}/bridges", headers):
            downstream = bridge.get("downstream_pipeline") or {}
            if str(downstream.get("project_id")) == str(env["GITLAB_PROJECT_ID"]):
                queue.append((downstream["id"], prefix + bridge["name"] + "/"))
    return jobs


def filter_stages(job_list):
    """
    Keeps the jobs of the stages in ARTIFACT_STAGES, or all jobs if it is unset.
    """
    stages = (os.getenv("ARTIFACT_STAGES") or "").split()
    if not stages:
        return job_list
    return [job for job in job_list if job["stage"] in stages]


def download_artifacts(job_list):
    """
    Download all artifacts from a list of jobs
    (ususally the ones in a single pipeline).
    It takes only the list of jobs and returns nothing
    """
    # Create directory to store artifacts in
    os.makedirs(ARTIFACT_DIR, exist_ok=True)
    for job in job_list:
        # If a job has an artifact (apart from the log), download it
        if any(e["file_type"] == "archive" for e in job["artifacts"]):
            download_single_artifact(job)
        else:
            print(
                "The following job does not exhibit "
                + f"an artifact for download: {job['name']}"
            )


def get_artifact_info(job):
    """
    Extracts the artifact for a job from a list of artifacts
    The other (ignored) artifacts are the trace and logs

    Takes the job as input.
    returns a dict with info of the artifact to be downloaded.
    """
    for artifact in job["artifacts"]:
        # Return the correct artifact (i.e. not the log)
        if artifact["file_type"] == "archive":
            return artifact
    raise KeyError(f"No artifact found for job: {job['name']}")


def download_single_artifact(job):
    """
    Downloads a single artifact for a given job.
    Retrieves the url of the artifact and writes the content to a file
    with the name of the job.

    Takes the job as input and returns nothing.
    """
    artifact = get_artifact_info(job)
    job_id = job["id"]
    job_name = sanitize(job["name"])
    artifact_root = os.path.realpath(ARTIFACT_DIR)
    artifact_path = os.path.join(artifact_root, f"{job_name}.{artifact['file_format']}")
    if os.path.dirname(os.path.realpath(artifact_path)) != artifact_root:
        raise ValueError("Artifact destination must stay inside ARTIFACT_DIR.")
    headers = {"PRIVATE-TOKEN": env["GITLAB_TOKEN"]}
    file_url = (
        f"https://{env['GITLAB_HOSTNAME']}/api/v4/projects/"
        + f"{env['GITLAB_PROJECT_ID']}/jobs/{job_id}/artifacts"
    )
    if os.path.exists(artifact_path):
        raise ValueError(f"Two jobs share the artifact name {job_name}.")
    # Stream the archive to disk, artifacts may exceed the runner memory
    with requests.get(
        file_url, headers=headers, stream=True, timeout=(60, 600)
    ) as response:
        response.raise_for_status()
        try:
            with open(artifact_path, "wb") as file:
                file.writelines(response.iter_content(chunk_size=1 << 20))
        except BaseException:
            os.remove(artifact_path)
            raise
    if os.getenv("EXTRACT_ARTIFACTS") == "true":
        with zipfile.ZipFile(artifact_path) as archive:
            archive.extractall(ARTIFACT_DIR)
        os.remove(artifact_path)
        print(f"Extracted artifacts of job: {job['name']} into {ARTIFACT_DIR}.")
        return
    print(f"Downloaded file from job: {job['name']} as {job_name}.")


def sanitize(job_name):
    # From the output of Github:
    # Invalid characters include:  Double quote ", Colon :, Less than <, Greater than >, Vertical bar |, Asterisk *, Question mark ?, Carriage return \r, Line feed \n
    sanitized_name = job_name.strip()
    sanitized_name = sanitized_name.replace('"', "")
    sanitized_name = sanitized_name.replace(":", "")
    sanitized_name = sanitized_name.replace("<", "")
    sanitized_name = sanitized_name.replace(">", "")
    sanitized_name = sanitized_name.replace("|", "")
    sanitized_name = sanitized_name.replace("*", "")
    sanitized_name = sanitized_name.replace("?", "")
    sanitized_name = sanitized_name.replace("\r", "")
    sanitized_name = sanitized_name.replace("\n", "")
    # Officially not needed, but probably helpfull to exclude spaces
    sanitized_name = sanitized_name.replace(" ", "_")
    sanitized_name = sanitized_name.replace("/", "_")
    sanitized_name = sanitized_name.replace("\\", "_")
    return sanitized_name


if __name__ == "__main__":
    jobs = get_job_list()
    download_artifacts(jobs)
