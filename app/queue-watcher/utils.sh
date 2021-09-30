#!/usr/bin/env bash
# shellcheck disable=SC2209,SC2162,SC2034
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

LOG_LEVEL=${LOG_LEVEL:-60}

maybe_log() {
    local lvl=${1}
    shift
    [ "${lvl}" -gt "${LOG_LEVEL}" ] || printf >&2 "%b\n" "$*"
}

function log() {
    maybe_log 0 "${*}"
}

log_trace() {
    maybe_log 80 "${blue}🐞${FILENAME:-} ${*}${reset}"
}

log_debug() {
    maybe_log 70 "${blue}🐞${FILENAME:-} ${*}${reset}"
}

log_verbose() {
    maybe_log 60 "${purple}ℹ️${FILENAME:-} ${*}${reset}"
}

log_success() {
    maybe_log 50 "${green}✓${FILENAME:-} ${*}${reset}"
}

log_announce() {
    maybe_log 30 "${cyan}💬${inverted}${FILENAME:-} ${*}${reset}"
}

log_notice() {
    maybe_log 40 "${cyan}💬${FILENAME:-} ${*}${reset}"
}

log_warning() {
    maybe_log 20 "${yellow}⚠️ ${FILENAME:-} ${*}${reset}"
}

log_error() {
    maybe_log 10 "${red}✘ ${*}${reset}"
}

log_critical() {
    maybe_log 0 "${red}${inverted}✘ ${*}${reset}"
}
