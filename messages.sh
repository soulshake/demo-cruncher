#!/usr/bin/env bash

set -euo pipefail
SELECTOR="${SELECTOR:-app=demo-pipeline}"
WORKSPACE=${WORKSPACE:-production}
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
    kubectl get jobs --selector="${SELECTOR}"
    echo
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
