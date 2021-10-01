#!/bin/bash
set -eu

# shellcheck disable=SC1091
. "$(git rev-parse --show-toplevel)/bin/utils.sh"

validate_aws_account() {
    if ! aws sts get-caller-identity | grep -q "${AWS_ACCOUNT_ID}"; then
        log_error "Didn't find expected account ID '${AWS_ACCOUNT_ID}' in the output of 'aws sts get-caller-identity'. Please make sure that your AWS profile is set correctly."
        exit 1
    fi
}

we_are_at_repo_root() {
    [ "$(pwd)" = "$(git rev-parse --show-toplevel)" ]
}

create_bucket() {
    # Create bucket and configure remote state
    local bucket_config='{
  "Rules": [
    {
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }
  ]
}'
    # shellcheck disable=SC2154
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" --create-bucket-configuration "LocationConstraint=$AWS_REGION" --acl private \
        && aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" --region "$AWS_REGION" --versioning-configuration Status=Enabled \
        && aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" --region "$AWS_REGION" --server-side-encryption-configuration "$bucket_config" \
        && log_success "${bold}Created bucket '${BUCKET_NAME}' in region '${AWS_REGION}'."
}

bucket_exists() {
    local name="${1}"
    log_debug "Querying AWS for bucket '$name'..."
    exists="$(aws s3api list-buckets --query "Buckets[].Name" | jq '. | index("'"${name}"'") // empty')"
    [ -n "${exists}" ]
}

write_state_tf() {
    need_vars DEST BUCKET_NAME AWS_REGION || exit 1
    cat >"${DEST}" <<EOF
terraform {
  backend "s3" {
    bucket         = "${BUCKET_NAME}"
    region         = "${AWS_REGION}"
    key            = "tfstate"
    encrypt        = true
  }
}
EOF
    # shellcheck disable=SC2154
    log_success "${bold}Wrote config for bucket '${BUCKET_NAME}' to ${DEST}."
}

main() {
    if [ -n "${CI:-}" ]; then
        log_warning "We're in CI, skipping state bucket creation"
        exit
    fi

    validate_aws_account || exit 1

    BUCKET_PREFIX="ephemerasearch-tfstate"
    log_warning "Using hardcoded bucket prefix ${BUCKET_PREFIX}; you probably want to fix this"
    DIRNAME=${1:-}

    if ! we_are_at_repo_root && [ -n "${DIRNAME}" ]; then
        log_warning "Unexpected argument '${DIRNAME}'. Either run from the repo root, or don't provide an argument."
        exit 1
    elif we_are_at_repo_root && [ -z "${DIRNAME}" ]; then
        log_warning "You're at the repo root but did not provide a directory name as an argument."
        exit 1
    elif we_are_at_repo_root && [ -n "${DIRNAME}" ] && [ ! -d "${DIRNAME}" ]; then
        log_warning "You provided an argument ${DIRNAME}, but there is no directory by this name in your current path."
        exit 1
    elif [ -n "${DIRNAME}" ] && [ -d "${DIRNAME}" ]; then # Argument was provided and directory exists
        # Normalize dirname in case it's fully qualified or has a trailing slash
        DIRNAME="$(basename "${DIRNAME}")"
        PATH_PREFIX="${DIRNAME}"
    else
        PATH_PREFIX="."
        DIRNAME="$(basename "$(pwd)")"
    fi

    DEST="${PATH_PREFIX}/state.tf"
    if [ -e "${DEST}" ]; then
        log_warning "${DEST} already exists; please remove it before proceeding."
        exit 1
    fi

    BUCKET_NAME="${BUCKET_PREFIX}-${DIRNAME}"
    if bucket_exists "$BUCKET_NAME"; then
        log_warning "Bucket '${BUCKET_NAME}' already exists."
        if confirm "Do you want to write to file '$DEST' for bucket '${BUCKET_NAME}'?"; then
            write_state_tf
        fi
    else
        # shellcheck disable=SC2154
        log_notice "${bold}Creating bucket: ${underline}$BUCKET_NAME${underlineoff} in region $AWS_REGION"
        log_notice "Config will be written to: $(realpath "${DEST}")"
        confirm "Create bucket '${BUCKET_NAME}'?" && create_bucket && write_state_tf
    fi
}

main "$@"
