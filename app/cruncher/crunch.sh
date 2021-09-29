#!/usr/bin/env bash
# shellcheck disable=2002

set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

fetch_message() {
    # Fetch a message from the queue
    local n=0 max_tries=5 message msg_count
    while true; do
        # Note: if the message isn't deleted before its visibility timeout, it will reappear in the queue and another job will be created.
        message="$(aws sqs receive-message --max-number-of-messages 1 --attribute-names All --wait-time-seconds 10 --queue-url "${QUEUE_URL}")"
        if [ -n "${message}" ]; then
            log_success "Got a message after ${n} tries!"
            echo "${message}" | jq -r '.Messages[0]' | tee /state/message.json
            break
        fi
        log_error "Couldn't parse message (an empty result may mean there are none in the queue, or that there are only invisible messages):"
        log_warning "message: --> $message"
        msg_count="$(aws sqs get-queue-attributes --queue-url "${QUEUE_URL}" --attribute-names ApproximateNumberOfMessages | jq -r '.Attributes.ApproximateNumberOfMessages')"
        if [ "${msg_count}" -eq 0 ]; then
            log_warning "There do not appear to be any messages in the queue. Exiting."
            exit 1
        elif [ "${n}" -ge "${max_tries}" ]; then
            log_warning "There seem to be ${msg_count} in the queue, but could not get one after ${n} tries. Exiting."
            exit 1
        fi
        log_notice "There are ${msg_count} in the queue. Not sure why we didn't get one. Will try again shortly. (Attempt ${n}/${max_tries})"
        sleep 5
        n=$((n + 1))
    done

    # Save message metadata in our /state volume which is shared across containers.
    cat /state/message.json | jq -r '.MessageId' | tee /state/MESSAGE_ID
    cat /state/message.json | jq -r '.ReceiptHandle' | tee /state/RECEIPT_ID
    cat /state/message.json | jq -r '.Body' | jq . | tee /state/body.json
    cat /state/body.json | jq -r '.duration' | tee /state/DURATION
    cat /state/body.json | jq -r '.target' | tee /state/TARGET
}

main() {
    log_debug "QUEUE_URL is '${QUEUE_URL}' ok?"
    fetch_message
}

main "$@"
