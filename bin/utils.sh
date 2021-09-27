#!/usr/bin/env bash
# shellcheck disable=SC2209,SC2162
shopt -s extglob

###
### Logging helpers
###

red='\033[0;31m'
yellow='\033[0;33m'
lightyellow='\033[0;93m'
green='\033[0;32m'
blue='\033[0;34m'
cyan='\033[0;36m'
purple='\033[0;35m'
white='\033[0;37m'

bold='\033[1m'
boldoff='\033[21m' # interpreted as double underline :/
dim='\e[2m'
inverted='\e[7m'
underline='\e[4m'
underlineoff='\033[24m'
reset='\033[0m'

export red yellow lightyellow green blue cyan purple white dim inverted bold boldoff underline underlineoff reset

if [ -n "${INFRA_DEBUG:-}" ]; then
  export FILENAME=" [$0]"
fi

maybe_log() {
  NEWLINE='\n'
  [ -n "${NL+1}" ] && NEWLINE="$NL"
  printf >&2 "%b${NEWLINE}" "$*"
  unset NL NEWLINE
}

function log() {
  maybe_log "${*}"
}

log_debug() {
  if [ -n "${DEBUG:-}" ]; then
    maybe_log "${blue}🐞${FILENAME:-} ${*}${reset}"
  fi
}

log_verbose() {
  maybe_log "${purple}ℹ️${FILENAME:-} ${*}${reset}"
}

log_success() {
  maybe_log "${green}✓${FILENAME:-} ${*}${reset}"
}

log_announce() {
  maybe_log "${cyan}💬${inverted}${FILENAME:-} ${*}${reset}"
}

log_notice() {
  maybe_log "${cyan}💬${FILENAME:-} ${*}${reset}"
}

log_warning() {
  (
    set +x
    maybe_log "${yellow}⚠️ ${FILENAME:-} ${*}${reset}"
  )
}

log_error() {
  maybe_log "${red}✘ ${*}${reset}"
}

log_critical() {
  maybe_log "${red}${inverted}✘ ${*}${reset}"
}

line() {
  # Print a horizontal line if we're in an interactive shell.
  # shellcheck disable=SC2015
  [[ $- == *i* ]] && stty size | perl -ale 'print "─"x$F[1]' || true
}

confirm() {
  [ "${CI:-}" = true ] && return 1

  prompt="${1:-Are you sure? }"
  while true; do
    read -p "${prompt} [y/n/x] " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      log
      log "Proceeding..."
      break
    elif [[ $REPLY =~ ^[Nn]$ ]]; then
      log
      log_warning "You said 'no'."
      return 1
    elif [[ $REPLY =~ ^[Xx]$ ]]; then
      log
      log_warning "Exiting."
      exit 1
    else
      log "\nChoose 'y', 'n', or 'x' to exit."
    fi
  done
}

need_vars() {
  local ret=0 name oldopt
  oldopt=$- # Preserve current value of 'set -u'
  set +u    # Don't allow set -u in caller script to cause us to exit
  for name in "$@"; do
    eval vval="\$$name"
    # shellcheck disable=SC2154
    if [ -z "${vval:-}" ]; then
      log_error "[need_vars] Variable $name not set!"
      ret=1
    fi
  done
  set -$oldopt # Restore previous set
  return $ret
}

describe_instances() {
  local - name_filter running_filter result
  while [ -n "${*}" ]; do
    log_verbose "handling ${1}"
    case "${1}" in
    --name)
      shift
      # name=${1}
      name_filter="Name=tag:Name,Values=${1}"
      shift
      ;;
    --running)
      running_filter="Name=instance-state-name,Values=running"
      shift
      ;;
    *)
      log_error "Unknown argument: ${1}"
      ;;
    esac
    sleep 1
  done
  # shellcheck disable=SC2086
  result="$(aws ec2 describe-instances --filters ${running_filter:-} ${name_filter:-})"
  if ! wat="$(echo "${result}" | jq '.Reservations')"; then
    log_error "Couldn't get .Reservations"
    log_warning "${result}" 2> >(head)
    return 1
  fi
  echo "${wat}"
}

get_instance_by_name() {
  # Retrieve a pet instance by name or INSTANCE_ID if defined
  # If there's more than one matching instance, try filtering by `--running` (since terminated instances continue to show up for a while).
  if [ -n "${INSTANCE_ID:-}" ]; then
    log_warning "Using INSTANCE_ID envvar: ${INSTANCE_ID}"
    instance_id="${INSTANCE_ID}"
    # instance IDs must not be quoted. Expected syntax: --instance-ids "one" "two"
    # shellcheck disable=SC2086
    if instance="$(aws ec2 describe-instances --instance-ids ${instance_id} | jq .Reservations[].Instances[])"; then
      echo "${instance}"
      return
    else
      log_error "Couldn't get instance with INSTANCE_ID '${instance_id}'"
      return 1
    fi
  fi

  local name="${1/-pet-instance/}" # Remove -pet-instance suffix if present
  if [[ "$*" == *"--running"* ]]; then
    running_filter="--running"
  fi
  if ! instances="$(describe_instances ${running_filter:-} --name "${name}-pet-instance")"; then
    log_error "Couldn't get instance with tag Name=${name}-pet-instance"
    return 1
  fi
  count="$(echo "${instances}" | jq '. | length')"
  if [ -z "${instances}" ] || [ "${count}" = 0 ]; then
    log_error "No instance(s) found with tag: Name=tag:Name,Values=${name}"
    return 1
  fi
  log_success "yay '${count}' instances"
  if [ "${count}" -gt 1 ]; then
    log_warning "Got ${count} instances, will filter by status"
    filtered="$(describe_instances --running --name "${name}-pet-instance")"
    if [ "$(echo "${filtered}" | jq '. | length')" -gt 1 ]; then
      log_error "Got more than one instance after filtering! Bailing."
      log "${filtered}"
    else
      log_warning "Filtered by state=running and got 1 instance"
    fi
    instances="${filtered}"
  fi
  instance="$(echo "${instances}" | jq '.[0].Instances[0]')"
  if [ -z "${instance}" ] || [ "${instance}" = null ]; then
    log_error "Fix your jq, couldn't get instance from this:"
    log_debug "${instances}"
    return 1
  fi
  instance_id="$(echo "${instance}" | jq -r '.InstanceId // empty')"
  if [ -z "${instance_id}" ]; then
    log_error "Got instances, but couldn't extract instance id?"
    log_debug "${instance}"
    return 1
  fi
  log_success "Got instance with id: ${instance_id}"
  echo "${instance}" | jq .
}

list_instances() {
  # Pretty-print a table with instance name, public IP, AMI, instance ID, state and the value of an arbitrary tag `$TAG`.
  # Set TAG to show the value of some arbitrary tag in the last column
  local filters result
  if [[ "${*}" == *"--pets"* ]]; then
    filters=("--filters" "Name=tag:animal,Values=pet")
  fi
  TAG="${TAG:-bootstrap-status}"

  headers="PublicIpAddress,PrivateIpAddress,Placement.AvailabilityZone,InstanceType,InstanceId,ImageId,State.Name,IamInstanceProfile.Arn"
  # shellcheck disable=SC2016,SC2068
  result="$(aws ec2 describe-instances ${filters[@]} --output text \
    --query 'Reservations[*].Instances[*].['"${headers}"',Tags[?Key == `Name`],Tags[?Key == `"'"${TAG}"'"`]]')"
  # This is sedistic. It puts the value of the 'Name' tag in the first column and the value of the 'bootstrap' tag in the last column:
  # - reverse line order
  # - remove the 'Name' tag key and combine it with the following line
  # - re-reverse
  # - remove the '${TAG}' key and combine that line with the preceding one
  headers="$(echo "Name,${headers}" |
    sed 's/Placement.AvailabilityZone/AZ/' |
    sed 's/PublicIpAddress/PublicIp/' |
    sed 's/PrivateIpAddress/PrivateIp/' |
    sed 's/State.Name/State/' |
    sed 's/IamInstanceProfile.Arn/Role/' |
    tr ',' ' ')"
  table="$(echo "$result" |
    tac |
    sed "/^Name/N;s/\n/\t/" |
    tac |
    sed ':r;$!{N;br};s/\n'"${TAG}"'/ '"${TAG}"'/g' |
    sed "s/${TAG}//" |
    sed "s/Name//" |
    sort |
    sed "s|arn:aws:iam::${AWS_ACCOUNT_ID}:instance-profile/||")"
  column -t <<<"$headers ${TAG}
    $table"
}
