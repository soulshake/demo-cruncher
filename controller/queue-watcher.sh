#!/bin/sh

set -euo pipefail
shopt -s inherit_errexit
. ./utils.sh

: "${QUEUE_URL?Please set the QUEUE_URL environment variable.}"

kickoff_job() {
    local job task=${1}
    log_verbose "Kicking off job with task: ${1}"
    env task="$task" $(
      echo "$task" | jq -r 'to_entries[] | "\(.key)=\"\(.value)\""'
    ) envsubst < job.yaml | kubectl create -f-
}

pop_message() {
    local body messages msg receipt_handle
    messages=$(aws sqs receive-message --queue-url "${QUEUE_URL}")
    [ -z "${messages}" ] && {
      log_verbose "No messages received. Waiting 10 seconds and trying again."
      sleep 10
      return
    }
    log_verbose "Message(s) received:"
    echo "${messages}"
    msg=$(echo "$messages" | jq '.Messages[0]')
    body=$(echo "${msg}" | jq -r .Body)
    receipt_handle=$(echo "${msg}" | jq -r '.ReceiptHandle')
    kickoff_job "${body}" || return 1
    echo -n "Deleting message... "
    aws sqs delete-message --queue-url "${QUEUE_URL}" --receipt-handle "${receipt_handle}"
    log_success "Message deleted."
}

# Continuously poll the queue and create a Kubernetes job for each message
log_verbose "starting watcher with QUEUE_URL '${QUEUE_URL}'..."
while sleep 1; do
    pop_message
done
