#!/usr/bin/env bash
#
# Watches an SQS queue and creates Kubernetes jobs to process samples for the demo pipeline.
#
# shellcheck disable=2002
set -euo pipefail
shopt -s inherit_errexit

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# Never create more than MAX_PENDING jobs.
MAX_PENDING=${MAX_PENDING:-5}
: "${AWS_REGION?Please set the AWS_REGION environment variable.}"
JOB_YAML_PATH=${JOB_YAML_PATH:-/src/job.yaml}

kickoff_job() {
    local job task=${1}
    log_verbose "Kicking off job with task: ${1}"
    # shellcheck disable=SC2016
    job=$(TASK=${task} envsubst '${TASK}' <"${JOB_YAML_PATH}")
    log_warning "${job}"
    echo "${job}" | kubectl create -f -
}

get_pending_count() {
    # Note: Selector must be correct or you'll accidentally generate a lot of pods
    kubectl get --no-headers pods --selector=app=demo-pipeline --field-selector=status.phase=Pending | wc -l
}

get_queue_attributes() {
    local attrs="${*:-All}"
    # shellcheck disable=SC2086
    aws sqs get-queue-attributes --queue-url "${QUEUE_URL}" --attribute-names ${attrs} | jq .
}

get_message_count() {
    get_queue_attributes ApproximateNumberOfMessages | jq -r .Attributes.ApproximateNumberOfMessages
}

block_while_too_many_pending() {
    local pending_jobs

    # shellcheck disable=SC2086
    pending_jobs="$(get_pending_count)"
    while [ "${pending_jobs}" -ge "${MAX_PENDING}" ]; do
        # Block while there's at least ${MAX_PENDING} pods in Pending status.
        # Note: this may cause scale-up to be slower than it could be, depending on the value of MAX_PENDING and how many nodes can be added at once.
        log_warning "There are ${pending_jobs} pending jobs, which is at least as many as the MAX_PENDING value (${MAX_PENDING}). Sleeping instead of polling the queue."
        sleep 5
        pending_jobs="$(get_pending_count)"
    done
}

pop_message() {
    local body messages msg receipt_handle
    messages=$(aws sqs receive-message --max-number-of-messages 1 --attribute-names All --wait-time-seconds 10 --queue-url "${QUEUE_URL}")
    [ -z "${messages}" ] && log_verbose "No messages received" && return
    log_verbose "Message(s) received:"
    log "${messages}"
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
    log_verbose "starting watcher with QUEUE_URL '${QUEUE_URL}'..."
    while sleep 1; do
        block_while_too_many_pending
        pop_message
    done
}

main "$@"
