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
    local - ret=0 name
    set +u # Don't allow set -u in caller script to cause us to exit
    for name in "$@"; do
        eval vval="\$$name"
        # shellcheck disable=SC2154
        if [ -z "${vval:-}" ]; then
            log_error "[need_vars] Variable $name not set!"
            ret=1
        fi
    done
    return $ret
}
