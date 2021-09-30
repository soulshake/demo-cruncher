#!/usr/bin/env bash
#
# This script creates a new queue message for each failed job.
#
set -euo pipefail
shopt -s inherit_errexit

QUEUE_URL=https://sqs.${AWS_REGION}.amazonaws.com/${AWS_ACCOUNT_ID}/demo-${WORKSPACE}

retry_failed_jobs() {
    local all_failed failed_count job task name

    all_failed=$(kubectl get job -o=jsonpath='{.items[?(@.status.conditions[].type=="Failed")]}' | jq --slurp)
    failed_count=$(jq '. | length' <<<"${all_failed}")

    echo -e "${failed_count} job(s) to requeue. Note: once requeued, failed jobs will be immediately deleted.\n"

    for i in $(seq 0 "$((failed_count - 1))"); do
        job=$(echo "${all_failed}" | jq -r '.['"${i}"']')
        task=$(echo "${job}" | jq -r '.spec.template.metadata.annotations.task // empty')
        name=$(echo "${job}" | jq -r '.metadata.name')

        echo "Requeing job ${name}..."
        if [ -n "${task}" ] && aws sqs send-message --queue-url "${QUEUE_URL}" --message-body "${task}"; then
            echo "✓ Requeued task: ${task}"
            kubectl delete job "${name}"
            echo "✓ Deleted job: ${name}"
        else
            if [ -z "${task}" ]; then
                echo "$(tput setaf 1)✘ ERROR: Couldn't extract task from job '${name}'.$(tput sgr0)"
            else
                echo "✘ ERROR: Could not requeue job '${name}' with task: ${task}"
            fi
            echo "To delete this job, run: kubectl delete job ${name}"
        fi
        echo
    done
}

main() {
    retry_failed_jobs
}

main "$@"
