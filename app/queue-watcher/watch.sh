#!/usr/bin/env bash
#
# Watches an SQS queue and creates Kubernetes jobs to process samples for the demo pipeline.
#
# shellcheck disable=2002
set -euo pipefail
shopt -s inherit_errexit

# Never create more than MAX_PENDING jobs.
MAX_PENDING=${MAX_PENDING:-}
: "${QUEUE_URL?Please set the QUEUE_URL environment variable.}"
JOB_YAML_PATH=${JOB_YAML_PATH:-/src/job.yaml}

kickoff_job() {
    local job task=${1}
    echo "Kicking off job with task: ${1}"
    # shellcheck disable=SC2016
    job=$(TASK=${task} envsubst '${TASK}' <"${JOB_YAML_PATH}")
    echo "${job}" | kubectl create -f -
}

pop_message() {
    local body messages msg receipt_handle
    messages=$(aws sqs receive-message --max-number-of-messages 1 --attribute-names All --wait-time-seconds 10 --queue-url "${QUEUE_URL}")
    [ -z "${messages}" ] && echo "No messages received" && return
    echo "Message(s) received:"
    echo "${messages}"
    msg=$(echo "$messages" | jq '.Messages[0]')
    body=$(echo "${msg}" | jq -r .Body)
    receipt_handle=$(echo "${msg}" | jq -r '.ReceiptHandle')
    kickoff_job "${body}" || return 1
    echo -n "Deleting message... "
    aws sqs delete-message --queue-url "${QUEUE_URL}" --receipt-handle "${receipt_handle}"
    echo "Done."
}

main() {
    # Continuously poll the queue and create a Kubernetes job for each message
    echo "starting watcher with QUEUE_URL '${QUEUE_URL}'..."
    while sleep 1; do

        # Hold off if there are already too many pending pods.
        if [ -n "${MAX_PENDING}" ] \
            && pending_pod_count=$(kubectl get --no-headers pods --selector=app=demo-pipeline --field-selector=status.phase=Pending | wc -l) \
            && [ "${pending_pod_count}" -ge "${MAX_PENDING}" ]; then

            echo "Too many pending pods (${pending_pod_count}) in relation to MAX_PENDING (${MAX_PENDING}). Chilling a bit."
            sleep 10 && continue
        fi

        # Otherwise, pop from the queue.
        pop_message
    done
}

main "$@"
