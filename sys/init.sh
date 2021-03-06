#!/bin/bash
SDEBUG=${SDEBUG-}
SCRIPTSDIR="$(dirname $(readlink -f "$0"))"
cd "$SCRIPTSDIR/.."
TOPDIR=$(pwd)

# now be in stop-on-error mode
set -e

# export back the gateway ip as a host if ip is available in container
if ( ip -4 route list match 0/0 &>/dev/null );then
    ip -4 route list match 0/0 \
        | awk '{print $3" host.docker.internal"}' >> /etc/hosts
fi

# load locales & default env
# load this first as it resets $PATH
for i in /etc/environment /etc/default/locale;do
    if [ -e $i ];then . $i;fi
done

# load virtualenv if any
for VENV in ./venv ../venv;do
    if [ -e $VENV ];then . $VENV/bin/activate;break;fi
done

PROJECT_DIR=$TOPDIR
if [ -e app ];then
    PROJECT_DIR=$TOPDIR/app
fi
if [ -e /code/app ]; then
    PROJECT_DIR=/code/app
fi
export PROJECT_DIR
# activate shell debug if SDEBUG is set
if [[ -n $SDEBUG ]];then set -x;fi


DEFAULT_IMAGE_MODE=phpfpm

export IMAGE_MODE=${IMAGE_MODE:-${DEFAULT_IMAGE_MODE}}
IMAGE_MODES="(cron|nginx|fg|phpfpm|supervisor)"
NO_START=${NO_START-}
DEFAULT_NO_MIGRATE=
DEFAULT_NO_COMPOSER=
DEFAULT_NO_STARTUP_LOGS=${NO_STARTUP_LOGS-}
DEFAULT_NO_COLLECT_STATIC=
if [[ -n $@ ]];then
    DEFAULT_NO_STARTUP_LOGS=1
    DEFAULT_NO_MIGRATE=1
    DEFAULT_NO_COLLECT_STATIC=1
fi
NO_STARTUP_LOGS=${NO_STARTUP_LOGS-${NO_MIGRATE-$DEFAULT_NO_STARTUP_LOGS}}
NO_MIGRATE=${NO_MIGRATE-$DEFAULT_NO_MIGRATE}
NO_COMPOSER=${NO_COMPOSER-$DEFAULT_NO_COMPOSER}
NO_COLLECT_STATIC=${NO_COLLECT_STATIC-$DEFAULT_NO_COLLECT_STATIC}
NO_IMAGE_SETUP="${NO_IMAGE_SETUP:-"1"}"
FORCE_IMAGE_SETUP="${FORCE_IMAGE_SETUP:-"1"}"
SKIP_SERVICES_SETUP="${SKIP_SERVICES_SETUP-}"
IMAGE_SETUP_MODES="${IMAGE_SETUP_MODES:-"fg|phpfpm"}"

FINDPERMS_PERMS_DIRS_CANDIDATES="${FINDPERMS_PERMS_DIRS_CANDIDATES:-"public private"}"
FINDPERMS_OWNERSHIP_DIRS_CANDIDATES="${FINDPERMS_OWNERSHIP_DIRS_CANDIDATES:-"public private"}"
export APP_TYPE="${APP_TYPE:-symfony}"
export APP_USER="${APP_USER:-$APP_TYPE}"
export APP_GROUP="$APP_USER"
# directories created and set on user ownership at startup
export USER_DIRS=". public private"
SHELL_USER=${SHELL_USER:-${APP_USER}}

# Symfony variables
export SYMFONY_LISTEN=${SYMFONY_LISTEN:-"0.0.0.0:8000"}
export PHP_MAX_WORKERS=${PHP_MAX_WORKERS:-50}
export PHP_MAX_SPARE_WORKERS=${PHP_MAX_SPARE_WORKERS:-35}
export PHP_MIN_SPARE_WORKERS=${PHP_MIN_SPARE_WORKERS:-5}
export PHP_DISPLAY_ERROR=${PHP_DISPLAY_ERROR:-0}
export PHP_XDEBUG_REMOTE=${PHP_XDEBUG_REMOTE:-0}
export PHP_XDEBUG_PROFILER_ENABLE_TRIGGER=${PHP_XDEBUG_PROFILER_ENABLE_TRIGGER:-1}
export PHP_XDEBUG_REMOTE_AUTOSTART=${PHP_XDEBUG_REMOTE_AUTOSTART:-0}
export PHP_XDEBUG_PORT=${PHP_XDEBUG_PORT:-9000}
export PHP_XDEBUG_IP=${PHP_XDEBUG_IP:-172.17.0.1}
export COOKIE_DOMAIN=${COOKIE_DOMAIN:-".local"}
export APP_ENV=${APP_ENV:-"prod"}
export DATABASE_URL=${DATABASE_URL:-"no value"}
export APP_SECRET=${APP_SECRET:-42424242424242424242424242}

log() {
    echo "$@" >&2;
}

vv() {
    log "$@";"$@";
}

die() {
    log "$@";exit 1;
}

#  shell: Run interactive shell inside container
_shell() {
    local pre=""
    local user="$APP_USER"
    if [[ -n $1 ]];then user=$1;shift;fi
    local bargs="$@"
    local NO_VIRTUALENV=${NO_VIRTUALENV-}
    local NO_NVM=${NO_VIRTUALENV-}
    local NVMRC=${NVMRC:-.nvmrc}
    local NVM_PATH=${NVM_PATH:-..}
    local NVM_PATHS=${NVMS_PATH:-${NVM_PATH}}
    local VENV_NAME=${VENV_NAME:-venv}
    local VENV_PATHS=${VENV_PATHS:-./$VENV_NAME ../$VENV_NAME}
    local DOCKER_SHELL=${DOCKER_SHELL-}
    local pre="DOCKER_SHELL=\"$DOCKER_SHELL\";touch \$HOME/.control_bash_rc;
    if [ \"x\$DOCKER_SHELL\" = \"x\" ];then
        if ( bash --version >/dev/null 2>&1 );then \
            DOCKER_SHELL=\"bash\"; else DOCKER_SHELL=\"sh\";fi;
    fi"
    if [[ -z "$NO_NVM" ]];then
        if [[ -n "$pre" ]];then pre=" && $pre";fi
        pre="for i in $NVM_PATHS;do \
        if [ -e \$i/$NVMRC ] && ( nvm --help > /dev/null );then \
            printf \"\ncd \$i && nvm install \
            && nvm use && cd - && break\n\">>\$HOME/.control_bash_rc; \
        fi;done $pre"
    fi
    if [[ -z "$NO_VIRTUALENV" ]];then
        if [[ -n "$pre" ]];then pre=" && $pre";fi
        pre="for i in $VENV_PATHS;do \
        if [ -e \$i/bin/activate ];then \
            printf \"\n. \$i/bin/activate\n\">>\$HOME/.control_bash_rc && break;\
        fi;done $pre"
    fi
    if [[ -z "$bargs" ]];then
        bargs="$pre && if ( echo \"\$DOCKER_SHELL\" | grep -q bash );then \
            exec bash --init-file \$HOME/.control_bash_rc -i;\
            else . \$HOME/.control_bash_rc && exec sh -i;fi"
    else
        bargs="$pre && . \$HOME/.control_bash_rc && \$DOCKER_SHELL -c \"$bargs\""
    fi
    export TERM="$TERM"; export COLUMNS="$COLUMNS"; export LINES="$LINES"
    exec gosu $user sh $( if [[ -z "$bargs" ]];then echo "-i";fi ) -c "$bargs"
}

#  configure: generate configs from template at runtime
configure() {
    if [[ -n $NO_CONFIGURE ]];then return 0;fi
    for i in $USER_DIRS;do
        if [ ! -e "$i" ];then mkdir -p "$i" >&2;fi
        chown $APP_USER:$APP_GROUP "$i"
    done
    if (find /etc/sudoers* -type f >/dev/null 2>&1);then chown -Rf root:root /etc/sudoers*;fi

    # copy only if not existing template configs from common deploy project
    # and only if we have that common deploy project inside the image
    if [ ! -e etc ];then mkdir etc;fi
    for i in sys/etc local/*deploy-common/etc local/*deploy-common/sys/etc;do
        if [ -d $i ];then cp -rfnv $i/* etc >&2;fi
    done
    # install with frep any template file to / (eg: logrotate & cron file)
    for i in $(find etc -name "*.frep" -type f 2>/dev/null);do
        log $i
        d="$(dirname "$i")/$(basename "$i" .frep)" \
            && di="/$(dirname $d)" \
            && if [ ! -e "$di" ];then mkdir -pv "$di" >&2;fi \
            && echo "Generating with frep $i:/$d" >&2 \
            && frep "$i:/$d" --overwrite
    done

    # regenerate symfony app/.env file
    log "regenerate /code/app/.env"
    frep "/code/app/.env.dist.frep:/code/app/.env" --overwrite
    chown symfony:symfony "/code/app/.env"

    # regenerate potential linked front project index.html file in public directory
    if [ -f /code/app/.front_index.frep ]; then
        FRONT_INDEX_FILE="${FRONT_INDEX_FILE:-"/code/app/public/front/dist/index.html"}"
        log "regenerate ${FRONT_INDEX_FILE}"
        frep "/code/app/.front_index.frep:${FRONT_INDEX_FILE}" --overwrite
        chown symfony:symfony "${FRONT_INDEX_FILE}"
    fi

    if [ -e /code/app/var/nginxwebroot ] && [[ -z ${NO_COLLECT_STATIC} ]]; then
        echo "Sync webroot for Nginx"
        # Sync the webroot to a shared volume with Nginx
        # but do not sync files which is already a shared Nginx volume
        # containing public long term contributions
        rsync -a --delete --exclude files/ /code/app/public/ /code/app/var/nginxwebroot/ \
            || "sync webroot failed"
    fi

    # add shortcuts to composer binaries on the project if they do not exists
    if [[ ! -L "$PROJECT_DIR/bin/composerinstall" ]];then
        if [[ -f "$PROJECT_DIR/bin/composerinstall" ]]; then
          rm -f "$PROJECT_DIR/bin/composerinstall"
        fi
        ( cd $PROJECT_DIR/bin \
            && gosu $APP_USER ln -s ../../init/sbin/composerinstall.sh composerinstall ) \
                || die "composerinstall link failed"
    fi
    if [[ ! -L "$PROJECT_DIR/bin/composer" ]];then
        if [[ -f "$PROJECT_DIR/bin/composer" ]]; then
          rm -f "$PROJECT_DIR/bin/composer"
        fi
        ( cd $PROJECT_DIR/bin \
            && gosu $APP_USER ln -s ../../init/sbin/composer.sh composer ) \
                || die "composerinstall link2 failed"
    fi
}

#  services_setup: when image run in daemon mode: pre start setup
#               like database migrations, etc
services_setup() {
    if [[ -z $NO_IMAGE_SETUP ]];then
        if [[ -n $FORCE_IMAGE_SETUP ]] || ( echo $IMAGE_MODE | egrep -q "$IMAGE_SETUP_MODES" ) ;then
            : "continue services_setup"
        else
            log "No image setup"
            return 0
        fi
    else
        if [[ -n $SKIP_SERVICES_SETUP ]];then
            log "Skip image setup"
            return 0
        fi
    fi
    # alpine linux has /etc/crontabs/ and ubuntu based vixie has /etc/cron.d/
    if [ -e /etc/cron.d ] && [ -e /etc/crontabs ];then cp -fv /etc/crontabs/* /etc/cron.d >&2;fi

    # composer install
    if [[ -z ${NO_COMPOSER} ]];then
        if [ -e /code/init/sbin/composerinstall.sh ]; then
            /code/init/sbin/composerinstall.sh || die "composerinstall failed"
        fi
    fi

    # FIXME: symfony migrations?
    # Run any migration
    if [[ -z ${NO_MIGRATE} ]];then
        ( cd $PROJECT_DIR \
            && ( gosu $APP_USER php bin/console --no-interaction doctrine:migrations:status || die "doctrine status failed" ) \
            && ( gosu $APP_USER php bin/console --no-interaction --allow-no-migration doctrine:migrations:migrate || die "doctrine migrate failed" ); )
    fi

    # FIXME Collect statics
    if [[ -z ${NO_COLLECT_STATIC} ]];then
        ( cd $PROJECT_DIR \
           && gosu $APP_USER php bin/console --no-interaction assets:install || die "assets install failed")
    fi

    # cd $PROJECT_DIR && gosu $APP_USER php bin/console --no-interaction about
}

fixperms() {
    if [[ -n $NO_FIXPERMS ]];then return 0;fi
    for i in /etc/{crontabs,cron.d} /etc/logrotate.d /etc/supervisor.d;do
        if [ -e $i ];then
            while read f;do
                chown -R root:root "$f"
                chmod 0640 "$f"
            done < <(find "$i" -type f)
        fi
    done
    while read f;do chmod 0755 "$f";done < \
        <(find $FINDPERMS_PERMS_DIRS_CANDIDATES -type d \
          -not \( -perm 0755 2>/dev/null\) |sort)
    while read f;do chmod 0644 "$f";done < \
        <(find $FINDPERMS_PERMS_DIRS_CANDIDATES -type f \
          -not \( -perm 0644 2>/dev/null\) |sort)
    while read f;do chown $APP_USER:$APP_USER "$f";done < \
        <(find $FINDPERMS_OWNERSHIP_DIRS_CANDIDATES \
          \( -type d -or -type f \) \
             -and -not \( -user $APP_USER -and -group $APP_GROUP \)  2>/dev/null|sort)
}

#  usage: print this help
usage() {
    drun="docker run --rm -it <img>"
    echo "EX:
$drun [-e NO_COLLECT_STATIC=1] [-e NO_MIGRATE=1] [-e NO_COMPOSER=1] [ -e FORCE_IMAGE_SETUP] [-e IMAGE_MODE=\$mode]
    docker run <img>
        run either fg, nginx, cron, supervisor or phpfpm daemon
        (IMAGE_MODE: $IMAGE_MODES)

$drun \$args: run commands with the context ignited inside the container
$drun [ -e FORCE_IMAGE_SETUP=1] [ -e NO_IMAGE_SETUP=1] [-e SHELL_USER=\$ANOTHERUSER] [-e IMAGE_MODE=\$mode] [\$command[ \args]]
    docker run <img> \$COMMAND \$ARGS -> run command
    docker run <img> shell -> interactive shell
(default user: $SHELL_USER)
(default mode: $IMAGE_MODE)

If FORCE_IMAGE_SETUP is set: run migration/static collection
If NO_IMAGE_SETUP is set: migration/static collection is skipped, no matter what
If NO_START is set: start an infinite loop doing nothing (for dummy containers in dev)
"
  exit 0
}

do_fg() {
    ( cd $PROJECT_DIR \
        && exec gosu $APP_USER php bin/console --no-interaction server:run $SYMFONY_LISTEN )
}

do_phpfpm() {
    (
        if [ ! -d /run/php-fpm ]; then mkdir /run/php-fpm; fi \
        && php-fpm -F -R
    )
}

if ( echo $1 | egrep -q -- "--help|-h|help" );then
    usage
fi

if [[ -n ${NO_START-} ]];then
    while true;do echo "start skipped" >&2;sleep 65535;done
    exit $?
fi

# Run app
pre() {
    configure
    services_setup
    fixperms
}

# only display startup logs when we start in daemon mode
# and try to hide most when starting an (eventually interactive) shell.
if ! ( echo "$NO_STARTUP_LOGS" | egrep -iq "^(no?)?$" );then pre 2>/dev/null;else pre;fi

if [[ -z "$@" ]]; then
    if ! ( echo $IMAGE_MODE | egrep -q "$IMAGE_MODES" );then
        log "Unknown image mode ($IMAGE_MODES): $IMAGE_MODE"
        exit 1
    fi
    log "Running in $IMAGE_MODE mode"
    if [[ "$IMAGE_MODE" = "fg" ]]; then
        do_fg
    else
        if [[ "$IMAGE_MODE" = "phpfpm" ]]; then
            do_phpfpm
        else

            if [[ "$IMAGE_MODE" = "cron" ]]; then
                if [[ -f /code/sys/crontab ]]; then
                    log "Ensure user crontab is registered"
                    gosu $APP_USER crontab /code/sys/crontab
                    gosu $APP_USER crontab -l
                fi
            fi
            cfg="/etc/supervisor.d/$IMAGE_MODE"
            if [ ! -e $cfg ];then
                log "Missing: $cfg"
                exit 1
            fi
            SUPERVISORD_CONFIGS="/etc/supervisor.d/rsyslog $cfg" exec /bin/supervisord.sh
        fi
    fi
else
    if [[ "${1-}" = "shell" ]];then shift;fi
    ( cd $PROJECT_DIR && _shell $SHELL_USER "$@" )
fi
