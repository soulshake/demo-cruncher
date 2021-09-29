#!/usr/bin/env bash
# shellcheck disable=SC1091
. "$(git rev-parse --show-toplevel)/bin/utils.sh"

set -euo pipefail
SELECTOR="${SELECTOR:-app=demo-pipeline}"

need_queue_url() {
    if [ -z "${QUEUE_URL:-}" ]; then
        echo "Please set the QUEUE_URL environment variable. Try running:"
        echo "terraform -chdir=app output -json | jq -r .queue_url.value"
        return 1
    fi
}

add_messages() {
    local count target duration msg
    need_queue_url || return 1
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
    need_queue_url || return 1
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
    need_queue_url || return 1
    log_warning "Purging queue ${QUEUE_URL}..."
    show_queue | grep QueueArn -A3
    # shellcheck disable=SC2119
    if confirm; then
        (
            set -x
            aws sqs purge-queue --queue-url "${QUEUE_URL}"
        )
        log_success "Queue purged"
    fi
}

purge_jobs() {
    log_warning "Purging all jobs matching selector: ${SELECTOR} ..."
    show_jobs
    # shellcheck disable=SC2119
    if confirm; then
        kubectl delete jobs --selector="${SELECTOR}"
        log_success "Jobs purged."
    fi
}

usage() {
    echo "Usage:"
    echo -e "-h, --help\t\t show usage"
    echo -e "-a, --add <count>\t generate and enqueue <count> messages (\$QUEUE_URL, \$TARGET, \$DURATION)"
    echo -e "-p, --purge\t\t purge jobs and queue (\$QUEUE_URL, \$SELECTOR)"
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
