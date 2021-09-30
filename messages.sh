#!/usr/bin/env bash

set -euo pipefail
SELECTOR="${SELECTOR:-app=demo-pipeline}"
AWS_REGION=${AWS_REGION?Please set the AWS_REGION environment variable.}
AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID?Please set the AWS_REGION environment variable.}
WORKSPACE=${WORKSPACE?Please set the WORKSPACE environment variable (should match the Terraform workspace in ./app).}
QUEUE_URL=https://sqs.${AWS_REGION}.amazonaws.com/${AWS_ACCOUNT_ID}/demo-${WORKSPACE}

add_messages() {
    local count target duration msg
    count=${1:-1}
    target=${TARGET:-goo.gl}
    duration=${DURATION:-30}
    echo "Adding ${count} message(s), using target '${target}' and duration '${duration}'. Set TARGET or DURATION environment variables to override these values."
    for i in $(seq 1 "${count}"); do
        duration=$((duration + i)) # use slightly different durations, for funsies
        msg='{ "target": "'"${target}"'", "duration": "'"${duration}"'" }'
        (
            set -x
            aws sqs send-message --queue-url "${QUEUE_URL}" --message-body "${msg}"
        )
    done
    sleep 3
    show_queue
}

show_queue() {
    (
        set -x
        aws sqs get-queue-attributes --queue-url "${QUEUE_URL}" --attribute-names QueueArn ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
    )
}

show_jobs() {
    echo
    (
        set -x
        kubectl get jobs --selector="${SELECTOR}"
    )
    echo
}

pull_from_deadletter() {
    local count=${1:-1} result
    if [ "${1}" = "--all" ]; then
        count=$(QUEUE_URL=${QUEUE_URL}-deadletter show_queue | jq -r '.Attributes.ApproximateNumberOfMessages')
    fi

    # QUEUE_URL=${QUEUE_URL}-deadletter show_queue
    echo "Pulling ${count} messages from deadletter queue..."
    for i in $(seq 0 "${count}"); do
        result=$(aws sqs receive-message --queue-url "${QUEUE_URL}-deadletter" | jq '.Messages[0]')
        if [ -z "${result}" ]; then
            log_error "Got no result when pulling from deadletter queue."
            exit 1
        fi
        aws sqs send-message --queue-url "${QUEUE_URL}" --message-body "$(echo "${result}" | jq -r '.Body')"
        aws sqs delete-message --queue-url "${QUEUE_URL}-deadletter" --receipt-handle "$(echo "${result}" | jq -r '.ReceiptHandle')"
    done
}

purge_queue() {
    echo "Purging queue ${QUEUE_URL}..."
    show_queue
    (
        set -x
        aws sqs purge-queue --queue-url "${QUEUE_URL}"
    )
    echo "Queue purged"
}

purge_jobs() {
    echo "Purging all jobs matching selector: ${SELECTOR} ..."
    show_jobs
    kubectl delete jobs --selector="${SELECTOR}"
    echo "Jobs purged."
}

usage() {
    echo "Usage:"
    echo -e "-h, --help\t\t show usage"
    echo -e "-a, --add <count>\t generate and enqueue <count> messages (\$QUEUE_URL, \$TARGET, \$DURATION)"
    echo -e "-p, --purge\t\t purge queue and jobs (\$QUEUE_URL, \$SELECTOR)"
    echo -e "-s, --show\t\t show queue attributes (\$QUEUE_URL)"
}

main() {
    case "${1:-}" in
    -a | --add)
        shift
        add_messages "$@"
        ;;
    -d | --deadletter)
        shift
        pull_from_deadletter "$@"
        ;;
    -p | --purge)
        purge_queue
        purge_jobs
        ;;
    -s | --show)
        show_queue
        show_jobs
        ;;
    *)
        usage
        ;;
    esac
}

main "$@"
