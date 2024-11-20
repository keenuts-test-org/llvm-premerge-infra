import requests
import time

from github import Github
from github import Auth

URL = "https://influx-prod-13-prod-us-east-0.grafana.net/api/v1/push/influx/write"
# TODO(aidengrossman): Env variables
API_KEY = "<api key>"
METRICS_USERID = "<user id>"

# TODO(aidengrossman): Env variables
auth = Auth.Token("<token>")
github_object = Github(auth=auth)
repo = github_object.get_repo("llvm/llvm-project")
workflow_runs = repo.get_workflow_runs()

workflow_runs_it = iter(workflow_runs)

lines = []

for i in range(0, 400):
    workflow_run = next(workflow_runs_it)
    if workflow_run.status != 'completed':
        continue

    if workflow_run.name != "Check code formatting":
        continue

    workflow_jobs = workflow_run.jobs()
    if workflow_jobs.totalCount == 0:
      continue
    assert(workflow_jobs.totalCount == 1)


    created_at = workflow_jobs[0].created_at
    started_at = workflow_jobs[0].started_at
    completed_at = workflow_jobs[0].completed_at

    job_result = int(workflow_jobs[0].conclusion == "success")

    queue_time = started_at - created_at
    run_time = completed_at - started_at

    if run_time.seconds == 0:
      continue

    created_at_ns = int(created_at.timestamp()) * 10 ** 9

    to_append = f'docs_action queue_time={queue_time.seconds},run_time={run_time.seconds},status={job_result} {created_at_ns}'
    print(created_at)

    lines.append(to_append)


print(lines)

def batch(iterable, n=1):
    l = len(iterable)
    for ndx in range(0, l, n):
        yield iterable[ndx:min(ndx + n, l)]

for metric_batch in batch(lines, 8):
    request_data = '\n'.join(metric_batch)
    response = requests.post(URL,
                             headers = {'Content-Type': 'text/plain'},
                             data = request_data,
                             auth = (METRICS_USERID, API_KEY)
    )

    print(request_data)

    print(response.status_code)
    print(response.text)

