red='\033[0;31m'
yellow='\033[0;33m'
green='\033[0;32m'
blue='\033[0;34m'
purple='\033[0;35m'
inverted='\e[7m'
reset='\033[0m'
log() { printf >&2 "%b\n" "$*"; }
log_debug() { if [ -n "${DEBUG:-}" ]; then log "${blue}🐞${FILENAME:-} ${*}${reset}"; fi; }
log_verbose() { log "${purple}ℹ️${FILENAME:-} ${*}${reset}"; }
log_success() { log "${green}✓${FILENAME:-} ${*}${reset}"; }
log_warning() { log "${yellow}⚠️ ${FILENAME:-} ${*}${reset}"; }
log_error() { log "${red}✘ ${*}${reset}"; }
log_critical() { log "${red}${inverted}✘ ${*}${reset}"; }
