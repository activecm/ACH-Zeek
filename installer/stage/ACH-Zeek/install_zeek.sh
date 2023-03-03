#!/usr/bin/env bash
#Copyright 2020 Active Countermeasures
#Performs installation of Zeek

#### Environment Set Up

# Set the working directory to the script directory
pushd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null

# Set exit on error
set -o errexit
set -o errtrace
set -o pipefail

# ERROR HANDLING
__err() {
    echo2 ""
    echo2 "Installation failed on line $1:$2."
    echo2 ""
    exit 1
}

__int() {
    echo2 ""
    echo2 "Installation cancelled."
    echo2 ""
    exit 1
}

trap '__err ${BASH_SOURCE##*/} $LINENO' ERR
trap '__int' INT

# Load the function library
. ./scripts/shell-lib/acmlib.sh
normalize_environment

#### Script Constants

#### Main Logic

print_usage_text () {
    cat >&2 <<EOHELP
This script will install Zeek. If the --sensor flag is passed to the script,
Zeek will be set up to monitor a network interface as a service. Otherwise,
Zeek will be set up to process packet captures with the "zeek readpcap" command.

On the command line, enter:
$0 [--sensor]
EOHELP
}

parse_parameters () {
    # Reads input parameters into the the Init State variables
    if [ "$1" = 'help' -o "$1" = '--help' ]; then
        print_usage_text
        exit 0
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|help|--help)
                # Display help and exit
                print_usage_text
                exit 0
                ;;
            --sensor)
                _SETUP_SENSOR=true
                ;;
            *)
                ;;
        esac
        shift
    done
}

test_system () {
    status "Checking minimum requirements"
    require_supported_os
    require_selinux_permissive
    require_free_space_MB "$HOME" "/" "/usr" 5120
}

disable_bro () {
    # Check for broctl on the system
    local broctl
    if [ -x /opt/bro/bin/broctl ]; then
        broctl="/opt/bro/bin/broctl"
    elif [ -x /usr/local/bro/bin/broctl ]; then
        broctl="/usr/local/bro/bin/broctl"
    elif command -v broctl > /dev/null; then
        local broctl=`command -v broctl`
    fi

    if [ -n "$broctl" ]; then
        status "Disabling existing Bro IDS installation"
        echo2 "Zeek IDS cannot run alongside Bro IDS. Stopping the Bro IDS service..."
        # Disable broctl
        $SUDO "$broctl" stop
        $SUDO "$broctl" cron disable
    fi

    local bro_logs
    if [ -d /opt/bro/logs ]; then
        bro_logs="/opt/bro/logs"
    elif [ -d /usr/local/bro/logs ]; then
        bro_logs="/usr/local/bro/logs"
    elif [ -n "$broctl" ]; then
        local broctl_dir=`dirname "$broctl"`
        local broctl_parent_dir=`realpath "$broctl_dir/.."`
        if [ -d "$broctl_parent_dir/logs" ]; then
            bro_logs="$broctl_parent_dir/logs"
        fi
    fi
    if [ -n "$bro_logs" -a ! -d /opt/zeek/logs ]; then
        status "Linking $bro_logs to /opt/zeek/logs"
        # Preserve historical Bro logs
        $SUDO mkdir -p /opt/zeek
        $SUDO ln -sf "$bro_logs" /opt/zeek/logs
    fi
}

check_for_unmanaged_zeek () {
    local zeek_path
    if [ -x /opt/bro/bin/zeekctl ]; then
        zeek_path="/opt/bro"
    elif [ -x /opt/zeek/bin/zeekctl ]; then
        zeek_path="/opt/zeek"
    elif [ -x /usr/local/zeek/bin/zeekctl ]; then
        zeek_path="/usr/local/zeek"
    elif command -v zeekctl > /dev/null; then
        local zeek_cmd=`command -v zeekctl`
        local zeek_cmd_dir=`dirname $zeek_cmd`
        zeek_path=`realpath "$zeek_cmd_dir/.."`
    fi
    if [ -n "$zeek_path" ]; then
        status "Zeek installation detected at $zeek_path. Stopping script"
        echo2 "Please refer to our FAQ for guidance on linking existing Zeek instalations to AC-Hunter:"
        echo2 "https://portal.activecountermeasures.com/ufaqs/can-i-send-bro-zeek-logs-from-an-existing-bro-zeek-sensor-to-rita-to-be-analyzed"
        exit 1
    fi
}

old_version_cleanup () {
    require_zeek_container_running
    status "Cleaning up old files"

    if [ "$acm_no_interactive" != 'yes' ]; then
        if [ -d "$HOME/AIH-Bro-latest" ]; then
            echo2 "Zeek is now installed in /opt/zeek"
            echo2 "Previous versions of AC-Hunter used the directory $HOME/AIH-Bro-latest."
            echo2 "We recommend deleting this old installation directory"
            echo2 "as long as you have not saved any personal files there."
            echo2 "Would you like to remove the directory $HOME/AIH-Bro-latest"
            if askYN; then
                rm -rf "$HOME/AIH-Bro-latest"
            fi
        fi

        if [ -d "$HOME/remscript" ]; then
            echo2 "The directory $HOME/remscript was used by previous versions of AC-Hunter but is no longer needed."
            echo2 "Would you like to remove the directory $HOME/remscript"
            if askYN; then
                rm -rf "$HOME/remscript"
            fi
        fi

        if [ -f "$HOME/AIH-Bro-latest.tar" ]; then
            echo2
            echo2 "The file $HOME/AIH-Bro-latest.tar was used by previous versions of AC-Hunter but is no longer needed."
            echo2 "Would you like to remove the file $HOME/AIH-Bro-latest.tar"
            if askYN; then
                rm -f "$HOME/AIH-Bro-latest.tar"
            fi
        fi
    fi
}

install_docker () {
    status "Installing docker"
    $SUDO scripts/shell-lib/docker/install_docker.sh
    echo2 ''
    if $SUDO docker ps &>/dev/null ; then
        echo2 'Docker appears to be working, continuing.'
    else
        fail 'Docker does not appear to be working. Does the current user have sudo or docker privileges?'
    fi
}

require_zeek_container_running () {
    # TODO give a time so we don't have to wait and do a loop with sleep 1 and increment counter
    # Make sure the zeek container is running
    local container_status=`$SUDO docker ps -f "name=zeek" -f "status=running" --format "{{.ID}}"`
    if [ -z "$container_status" ]; then
        fail "An error occurred while starting Zeek"
    fi
}

install_zeek () {
    status "Installing Zeek"
    local zeek_release=`cat ./VERSION`
    if [ -z "$zeek_release" ]; then
        fail "Could not read target Zeek release from VERSION file"
    fi

    # Install the helper script to the path
    $SUDO mkdir -p /opt/zeek/bin
    $SUDO cp -f scripts/zeek /opt/zeek/bin/zeek
    $SUDO chmod 0755 /opt/zeek/bin/zeek
    $SUDO ln -sf /opt/zeek/bin/zeek /usr/local/bin/zeek

    # https://github.com/activecm/docker-zeek/blob/master/zeek
    # uses these variables for configuration. Set the AC-Hunter specific
    # values here to ensure we aren't dependent on defaults in an external
    # script which could change in future versions
    # Note: The HEREDOC block must be indented using tabs.
    cat <<- HEREDOC | $SUDO tee /etc/profile.d/docker-zeek.sh >/dev/null
		# This file is auto-generated. Any changes will be overwritten on next upgrade.
		export zeek_top_dir='/opt/zeek/'
		export zeek_release='${zeek_release}'
	HEREDOC
    $SUDO chmod 0644 /etc/profile.d/docker-zeek.sh
    source /etc/profile.d/docker-zeek.sh

    # Stop any currently running Zeek
    $SUDO /opt/zeek/bin/zeek stop 2>&1 || true

    # Load the target docker zeek image for the target platform
    local escaped_version=`echo ${zeek_release} | sed 's|[^a-zA-Z0-9]|_|g'`

    local target_arch
    case `uname -m` in 
    x86_64) 
        target_arch="amd64" 
        ;; 
    aarch64) 
        target_arch="arm64" 
        ;; 
    arm|armv7l) 
        target_arch="arm" 
        ;; 
    esac

    gzip -d -c ./images/activecm_zeek_${escaped_version}_${target_arch}.tar.gz | $SUDO docker load

    # Install the custom AC-Hunter Zeek config
    # NOTE: This must be done before running init_zeek_cfg
    # otherwise, 100-default.zeek will always exist when we go to make this check.
    # Therefore, we would always overwrite a customer's custom 100-default.zeek script.
    if [ ! -e /opt/zeek/share/zeek/site/autoload/100-default.zeek ]; then
        $SUDO mkdir -p /opt/zeek/share/zeek/site/autoload
        $SUDO cp zeek_scripts/100-default.zeek /opt/zeek/share/zeek/site/autoload/100-default.zeek
    fi

    # Copy over any missing Zeek scripts into the autoload directory
    # -n prevents copying if the target file exists
    $SUDO cp -rn zeek_scripts/site/* /opt/zeek/share/zeek/site/

    if [ "$_SETUP_SENSOR" = "true" ]; then
        status "Starting Zeek as a network monitor"
        /opt/zeek/bin/zeek start

        status "Waiting for initialization"
        sleep 15

        require_zeek_container_running
    fi

    echo2 "Congratulations, Zeek is installed."
}

main () {
    parse_parameters "$@"

    status "Checking for administrator privileges"
    require_sudo
    export acm_no_interactive

    test_system

    status "Installing supporting software"
    ensure_common_tools_installed

    disable_bro

    check_for_unmanaged_zeek

    install_docker

    install_zeek

    old_version_cleanup
}

main "$@"

#### Clean Up
# Change back to the initial working directory
popd > /dev/null
