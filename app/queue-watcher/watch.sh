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
MAX_PENDING=10 # TODO: parameterize

kickoff_job() {
    log_verbose "Kicking off job..."
    # shellcheck disable=SC2016
    envsubst '${QUEUE_URL},${WORKSPACE}' </src/job.yaml | kubectl create -f -
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

block_if_pending() {
    local pending_jobs

    # shellcheck disable=SC2086
    pending_jobs="$(get_pending_count)"
    while [ "${pending_jobs}" -gt "${MAX_PENDING}" ]; do
        # Block while there's at least ${MAX_PENDING} pods in Pending status.
        # Note: this may cause scale-up to be slower than it could be, depending on the value of MAX_PENDING and how many nodes can be added at once.
        log_warning "There are ${pending_jobs} pending jobs, which is more than the MAX_PENDING value (${MAX_PENDING}). Sleeping instead of polling the queue."
        sleep 10
        pending_jobs="$(get_pending_count)"
    done
}

main() {
    # Continuously poll the queue and create a Kubernetes job for each message
    log_verbose "starting watcher with QUEUE_URL '${QUEUE_URL}' and WORKSPACE '${WORKSPACE}'..."
    log_verbose "$(get_queue_attributes)" # informational; shows all queue attributes
    while true; do
        log_debug "Status at beginning of loop:"
        log_debug "$(get_queue_attributes ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible | jq .Attributes)" # informational
        mc="$(get_message_count)"
        pc="$(get_pending_count)"
        to_create=$((mc - pc))
        if [ "${to_create}" -lt 1 ]; then
            log_verbose "There at least as many pending jobs as messages in the queue (${pc} >= ${mc}). Taking a nap."
            sleep 10 && continue
        fi
        log_success "${mc} messages in the queue; ${pc} pending pods. Creating ${to_create} job(s), within the limits of MAX_PENDING (${MAX_PENDING})."
        while [ "${to_create}" -ge 1 ]; do
            block_if_pending
            if kickoff_job; then
                log_success "Kicked off job"
                sleep 5
            else
                log_error "Couldn't kickoff job"
                sleep 20
            fi
            to_create=$((to_create - 1))
            log_verbose "${to_create} left to create."
            sleep 1
        done
        log_success "No more to create."
        sleep 3
    done
}

main "$@"
