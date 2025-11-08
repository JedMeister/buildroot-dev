#!/bin/bash -e

# initalize env vars before setting -u in case they don't exist
RELEASE=${RELEASE:-}
FAB_ARCH=${FAB_ARCH:-}
FAB_PATH=${FAB_PATH:-}
[[ -z "$DEBUG" ]] || set -x

# fail on unset vars from here
set -u

fatal() { echo "FATAL: $*" >&2; exit 1; }
warning() { echo "WARNING: $*" >&2; }
info() { echo "INFO: $*"; }

usage() {
    cat <<EOF
$(basename "$0") [-h] [-b BUILDROOT]

Generate a "developer friendly" buildroot

This script leverages 'deck' & 'fab' to install some additional packages and
apply some additional config. Packages/config come from these files:

- plan
- overlay
- conf

Options:

    -h|--help       show this help and exit
    -b|--buildroot DIRECTORY
                     buildroot to use; default:
                    \$FAB_PATH/buildroots/\$(basename \$RELEASE-\$FAB_ARCH
    -o|--output DIRECTORY
                    path to output new buildroot to; default:
                    \$FAB_PATH/buildroots/dev-\$(basename \$RELEASE)-\$FAB_ARCH
                    - must not exists; unless -f|--force
    -f|--force      delete build &/or output directories if they exist
                    (overrides -u|--use-existing)
    -k|--keep       keep build/ directory after successful build
    -u|--use-existing
                    use existing build and output dirs (ignore if doesn't
                    exist) - useful for testing/development of this tool

Env vars:

    FAB_PATH        if not set, falls back to '/turnkey/fab'
    RELEASE         if not set, falls back to host
    FAB_ARCH        if not set, falls back to host

EOF
    exit 1
}

if [[ -z "$FAB_PATH" ]]; then
    FAB_PATH=/turnkey/fab
    if [[ -d "/turnkey/fab" ]]; then
        warning "FAB_PATH not set, falling back to $FAB_PATH"
    else
        fatal "FAB_PATH not set and default /turnkey/fab does not exist"
    fi
fi
if ! which fab >/dev/null 2>&1; then
    fatal "please install fab package"
fi
if [[ -z "$RELEASE" ]]; then
    RELEASE="debian/$(lsb_release -sc)"
    warning "RELEASE not set, falling back to system: $RELEASE"
fi
if [[ -z "$FAB_ARCH" ]]; then
    FAB_ARCH=$(dpkg --print-architecture)
    warning "FAB_ARCH not set, falling back to system: $FAB_ARCH"
fi

BUILDROOT="$FAB_PATH/buildroots/$(basename "$RELEASE")-$FAB_ARCH"
OUTPUT="$FAB_PATH/buildroots/dev-$(basename "$RELEASE")-$FAB_ARCH"
FORCE=
KEEP=
USE_EXISTING=

while [[ $# -ne 0 ]]; do
    case $1 in
        -h|--help)
            usage;;
        -b|--buildroot)
            shift
            BUILDROOT="$1";;
        -o|--output)
            shift
            OUTPUT="$1";;
        -f|--force)
            FORCE=y;;
        -k|--keep)
            KEEP=y;;
        -u|--use-existing)
            USE_EXISTING=y;;
        *)
            fatal "unknown argument: $1";;
    esac
    shift
done

if [[ ! -d "$BUILDROOT" ]]; then
    fatal "buildroot does not exist: $BUILDROOT"
fi
if [[ -f "$OUTPUT/bin/bash" ]] || [[ -f "build/bin/bash" ]]; then
    if [[ -z "$FORCE" ]] && [[ -z "$USE_EXISTING" ]]; then
        warning "build &/or $OUTPUT dir/s already contain files"
        fatal "clear dir/s or rerun with '--force' or '-use-existing'"
    elif [[ -n "$FORCE" ]]; then
        if deck --isdeck build; then
            deck -D build
        fi
        rm -rf build "$OUTPUT"
    fi
fi

mkdir -p build "$OUTPUT"

readarray -t overlays < overlay
readarray -t confs < conf
if ! deck --isdeck build; then
    info "decking $BUILDROOT to build/"
    deck "$BUILDROOT" build/
fi

info "installing plan"
fab-install build plan
for overlay in "${overlays[@]}"; do
    overlay="$FAB_PATH/$overlay"
    info "applying overlay: $overlay"
    fab-apply-overlay build/ "$overlay"
done
for conf in "${confs[@]}"; do
    conf="$FAB_PATH/$conf"
    info "applying conf: $conf"
    fab-chroot build/ --script "$conf"
done

info "rsyncing buildroot to $OUTPUT"
rsync --delete -Hac build/ "$OUTPUT"/

if [[ -z "$KEEP" ]]; then
    deck -D build/
    rm -rf build/
else
    warning "-k|--keep switch detected; not cleaning build/ dir"
fi

cat <<EOF
Building dev buildroot completed - output: $OUTPUT/

A common usage scenario is to use it via a "dev pool"; i.e.:

mkdir -p $FAB_PATH/pools/dev-$(basename "$RELEASE")-$FAB_ARCH
cd $FAB_PATH/pools/dev-$(basename "$RELEASE")-$FAB_ARCH
pool-init $OUTPUT
EOF
