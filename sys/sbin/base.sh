#!/usr/bin/env bash
# This is the main bash ressource file.
#  - default variables values
#  - fonctions used by others

shopt -s extglob

RED=$'\e[31;01m'
BLUE=$'\e[36;01m'
YELLOW=$'\e[33;01m'
GREEN=$'\e[32;01m';
NORMAL=$'\e[0m'
CYAN="\\e[0;36m"

SDEBUG=${SDEBUG-}

# exit codes
END_SUCCESS=0
END_FAIL=1
END_RECVSIG=3
END_BADUSAGE=65

# activate shell debug if SDEBUG is set
if [[ -n $SDEBUG ]];then set -x;fi

NONINTERACTIVE="${NONINTERACTIVE:-}"

ROOTPATH="${ROOTPATH:-/code/app}"
BINPATH="${BINPATH:-"${ROOTPATH}/bin"}"
WWW_DIR="${WWW_DIR:-"${ROOTPATH}/www"}"
PUBLIC_DIR="${PUBLIC_DIR:-"${ROOTPATH}/var/public"}"
PRIVATE_DIR="${PUBLIC_DIR:-"${ROOTPATH}/var/private"}"
STOP_CRON_FLAG="${PRIVATE_DIR}/SUSPEND_CRONS"
MAINTENANCE_FLAG="${PRIVATE_DIR}/MAINTENANCE"

# System User
APP_USER="${APP_USER:-drupal}"
APP_GROUP="${APP_GROUP:-$APP_USER}"
PHP_GROUP="${PHP_GROUP:-apache}"
USER="${APP_USER}"
GROUP="${PHP_GROUP}"

# Locale to set
LOCALE="fr"

COMPOSER="${BINPATH}/composer"

reset_colors() {
    if [[ -n ${NO_COLOR} ]]; then
        BLUE=""
        YELLOW=""
        RED=""
        CYAN=""
    fi
}

log_() {
    reset_colors
    logger_color=${1:-${RED}}
    msg_color=${2:-${YELLOW}}
    shift;shift;
    logger_slug="${logger_color}[${LOGGER_NAME}]${NORMAL} "
    if [[ -n ${NO_LOGGER_SLUG} ]];then
        logger_slug=""
    fi
    printf "${logger_slug}${msg_color}$(echo "${@}")${NORMAL}\n" >&2;
    printf "" >&2;  # flush
}

log() {
    log_ "${RED}" "${CYAN}" "${@}"
}

warn() {
    log_ "${RED}" "${CYAN}" "${YELLOW}[WARN] ${@}${NORMAL}"
}

may_die() {
    reset_colors
    thetest=${1:-1}
    rc=${2:-1}
    shift
    shift
    if [ "x${thetest}" != "x0" ]; then
        if [[ -z "${NO_HEADER-}" ]]; then
            NO_LOGGER_SLUG=y log_ "" "${CYAN}" "Problem detected:"
        fi
        NO_LOGGER_SLUG=y log_ "${RED}" "${RED}" "$@"
        exit $rc
    fi
}

die() {
    may_die 1 1 "${@}"
}

die_in_error_() {
    ret=${1}
    shift
    msg="${@:-"$ERROR_MSG"}"
    may_die "${ret}" "${ret}" "${msg}"
}

die_in_error() {
    die_in_error_ "${?}" "${@}"
}

debug() {
    if [[ -n "${DEBUG// }" ]];then
        log_ "${YELLOW}" "${YELLOW}" "${@}"
    fi
}

vvv() {
    debug "${@}"
    "${@}"
}

vv() {
    log "${@}"
    "${@}"
}

settings_folder_write_fix() {
    cd "${ROOTPATH}"
    echo "${YELLOW}+ Check Write rights in ${SITES_DIR}/${SITES_SUBDIR}${NORMAL}"
    chmod u+w "${SITES_DIR}/${SITES_SUBDIR}"
    chown ${USER}:${GROUP} "${SITES_DIR}/${SITES_SUBDIR}"
}

bad_exit() {
        echo ;
        echo "${RED} ERROR: ${1}" >&2;
        echo "${NORMAL}" >&2;
        exit ${END_FAIL};
}

check_conf_arg() {
    CONFARG=${1}
    if [ "x${!CONFARG}" == "x" ]; then
        bad_exit "${CONFARG} is not defined"
    fi
}

ask() {
    local ask=${ASK:-}
    if [[ -n $NONINTERACTIVE ]];then
        ask=${ask:-yauto}
    fi
    UNDONE=1
    NO_AVOID=${2}
    echo "${NORMAL}"
    while :
    do
        if [ "x${ask}" = "xyauto" ]; then
          echo " * ${1} [o/n]: ${GREEN}y (auto)${NORMAL}"
          USER_CHOICE=ok
          break
        fi
        read -r -p " * ${1} [o/n]: " USER_CHOICE
        if [ "x${USER_CHOICE}" == "xn" ]; then
            if [ "x${NO_AVOID}" == "xNO_AVOID_MESSAGE" ]; then
                echo "${GREEN}  --> no${NORMAL}"
                USER_CHOICE=abort
            else
                echo "${BLUE}  --> ok, step avoided.${NORMAL}"
                USER_CHOICE=abort
            fi
            break
        else
            if [ "x${USER_CHOICE}" == "xo" ]; then
                USER_CHOICE=ok
                break
            else
                if [ "x${USER_CHOICE}" == "xy" ]; then
                    USER_CHOICE=ok
                    break
                fi
            fi
        fi
        echo "${RED}Please answer \"o\",\"y\" (yes|oui) or \"n\" (no|non).${NORMAL}"
    done
}

call_composer() {
    "${COMPOSER}" "${@}"
}

_flag() {
    echo "${YELLOW}+ touch ${$1}${NORMAL}"
    touch "${1}"
}

_unflag() {
    echo "${YELLOW}+ touch ${1}${NORMAL}"
    touch "${1}"
}

suspend_cron() {
    _flag "${STOP_CRON_FLAG}"
}

unsuspend_cron() {
    _unflag "${STOP_CRON_FLAG}"
}

maintenance_mode() {
    _flag "${MAINTENANCE_FLAG}"
}

undo_maintenance_mode() {
    _unflag "${MAINTENANCE_FLAG}"
}

activate_maintenance() {
    maintenance_mode
    suspend_cron
}

deactivate_maintenance() {
    undo_maintenance_mode
    unsuspend_cron
}
# vim:set et sts=4 ts=4 tw=80:
