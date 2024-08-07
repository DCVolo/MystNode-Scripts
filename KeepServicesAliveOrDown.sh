#!/bin/bash

#set -x
set -e

# The current version of the script
CURRENT_VERSION="0.9.7"

# The URL of the script on GitHub
SCRIPT_URL="https://raw.githubusercontent.com/DCVolo/MystNode-Scripts/main/KeepServicesAliveOrDown.sh"

# Available Update
updaterStatus="No" 

# DEFAULT PARAMETERS
# Timer (seconds)
p_timer=60
# Discord webhook URL
p_discord=""
# Define the name of your MystNode container
# if this is empty; docker_cmd will be empty, so it can run on most Linux
p_container=""
docker_cmd=""
# Default mode is file modification event (fast, need apt-get install inotify-tools), mode 1 is basic check every XX seconds.
p_check_mode=1
# Full path to config-mainnet.toml wich contain the active-services list
p_pathToconfigMainnet=""
# Define an array to represent the status of the services you want to run.
# Each index represents a service in the order: [scraping, data_transfer, dvpn, wireguard]
# If the value at an index is 1, the corresponding service should be running; if it's 0, the service should not be running.
service_status=(1 1 1 1)
service_names=("scraping" "data_transfer" "dvpn" "wireguard") # DO NOT MODIFY
# Your MystNode's identitiy, if not set it will find it anyway
p_node_ID="" # I strongly advise to let the script find your node's ID rather than you messing with MysteriumNetwork


# Function to get the node ID
get_node_id() {
    if [ -z "$p_node_ID" ]; then
        # Takes the account identity
        p_node_ID=$($docker_cmd myst account info | grep "Using identity:" | awk -F':' '{print $2}' | tr -d ' ')
        # from the list of identities (???) (array or not array, that is the question)
        #p_node_ID=$($docker_cmd myst cli identities list | grep "[+]" | awk -F' ' '{print $2}' | tr -d ' ')
    fi
}


# Function to start a service | $1 = node ID, $2 = service name
start_service() {
    $docker_cmd myst cli service start "$1" "$2"
    send_notif_discord "$2" "started"
}


# Function to stop a service | $1 = service ID, $2 = service name
stop_service() {
    $docker_cmd myst cli service stop "$1"
    send_notif_discord "$2" "stopped"
}


# Function to send a Discord notification | $1 = service_name, $2 = service_action (started/stopped)
send_notif_discord() {
    if [ -n "$p_discord" ]; then
        curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST \
            --data "{\"content\": \"Service : $1, Status : $2.\"}" "$p_discord"
    fi
}


# Detect the current active services and check wether they should be enabled or disabled
check_services() {
    # Get the current active services and store the result in an array
    services_currently_active_ID=()
    services_currently_active_TYPE=()
    while IFS= read -r line; do
        # Extract the ID, Type and Status from the line and add them to their respective array
        id=$(echo "$line" | awk '{print $3}')
        type=$(echo "$line" | awk '{print $NF}')
        services_currently_active_ID+=("$id")
        services_currently_active_TYPE+=("$type")
    done < <($docker_cmd myst cli service list | grep Running)

    # Loop through each service defined in the 'service_status' array.
    for i in "${!service_names[@]}"; do
        # Get the name of the service from the 'service_names' array.
        service=${service_names[$i]}
        # If the service is supposed to be running (value is 1)...
        if [[ ${service_status[$i]} -eq 1 ]]; then
            # If the service is not currently running, start it.
            if ! echo "${services_currently_active_TYPE[@]}" | grep -q "$service"; then
                start_service "$p_node_ID" "$service"
            fi
        else
            # If the service is not supposed to be running (value is 0) but it is, stop it.
            if echo "${services_currently_active_TYPE[@]}" | grep -q "$service"; then
                # Find the index of the service type in the array
                for index in "${!services_currently_active_TYPE[@]}"; do
                    if [ "${services_currently_active_TYPE[$index]}" = "$service" ]; then
                        # Get the corresponding ID
                        service_id="${services_currently_active_ID[$index]}"
                        break
                    fi
                done
                stop_service "$service_id" "$service"
            fi
        fi
    done
}


# Will kill any instance of this script that were launched
kill_this_script(){
    pkill -f $0
    exit 0
}


# Will check if a newer version on github exists
check_for_update(){
    if ! command -v wget &> /dev/null; then
        updaterStatus="wget not installed, can't update."
    else
        # Download the script from GitHub
        wget -q -O KeepServicesAliveOrDown-temp.sh "$SCRIPT_URL"

        # Extract the version number from the downloaded script
        NEW_VERSION=$(sed -n 's/^CURRENT_VERSION="\([^"]*\)".*/\1/p' KeepServicesAliveOrDown-temp.sh)

        # Compare the version numbers
        if [ "$CURRENT_VERSION" != "$NEW_VERSION" ]; then
			# Keep the new file, renames it, and gives it right for execution
            updaterStatus="Yes,attemp self-update."
            mv KeepServicesAliveOrDown-temp.sh "$(basename "$0")"
			chmod +x "$0"
        else
            rm KeepServicesAliveOrDown-temp.sh
        fi
    fi
}


# Main structure of the code
main(){
    # If a container's name is not used then proceed to use a standard Linux command
    if [ -n "$p_container" ]; then
        docker_cmd="docker exec ${p_container}"
    fi

    get_node_id

    if [ "$p_check_mode" -eq 1 ]; then
        # Start an infinite loop. This script will keep running until it's manually stopped.
        while true; do
            check_services
            # Wait for XX seconds before the next iteration of the loop.
            sleep "$p_timer"
        done
    else
        # Use the filesystem event notifier
        check_services # otherwise it would need a file modification before being set as desired
        while inotifywait -e modify "$p_pathToconfigMainnet"; do
            check_services
        done
    fi
} > /dev/null 2>&1


# Display the help message in the console
function print_help {
	check_for_update
	echo "         "
    echo "UPDATE AVAILABLE: $updaterStatus"
	echo "SOURCE: $SCRIPT_URL"
	echo "VERSION: $CURRENT_VERSION"
    echo "         "
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -c, --container    MystNode container's name (Do not fill for standard Linux use)"
    echo "  -d, --discord      Discord webhook URL (HTTPS format, optional)"
    echo "  -h, --help         Display this help message but will also check for an update and install it if found"
    echo "  -m, --mode         (0/1) 0 uses inotifywait wich need to be installed 'sudo apt install inotify-tools', 1 (default) is a basic check every <duration> in seconds set with -t"
    echo "  -n, --nodeID       The MystNode's identity (Optional, the script will find it)"
    echo "  -p, --path-config  The full path to config mainnet (config-mainnet.toml)"
    echo "  -s, --services     Services to maintain either enabled or disabled [scraping data_transfer dvpn wireguard]."
    echo "  -t, --timer        Checking frequency (in seconds, works only with mode 1)"
    echo "  -q, --quit         Will kill any instance of this script that were launched"
    echo "  "
	echo "                     Ex: *no need for parameters if you edit the variables in the code and then run the script* "
    echo "                     Ex: -m 1 -s \"1 1 1 1\" -t 60"
    echo "                     Ex: -c \"myst\" -m 0 -p \"/var/lib/docker/volumes/myst-data/_data/config-mainnet.toml\" -s \"1 1 0 0\" "
    echo "                     Ex: -c \"myst\" -d \"https://url_of_your_Discord_Webhook\" -m 1 -n \"your node's ID\" -s \"1 1 1 0\" -t 60"
    echo "  "
    echo "                     Note:    You can (and I advise you to) edit the script (DEFAULT PARAMETERS) with 'nano ./KeepServicesAliveOrDown.sh' or use the full command given above."
    echo "                              Not using all parameters OR not using quotes OR filling incorrect data; Could result in bug/crash. "
    echo "                              By using this script you acknowledge that what happens next is your entire responsibility,"
    echo "                                      always check twice. It is commented but you can also take use of AI to explain the code."
    echo "                              The code was written for Linux Ubuntu but I guess it should work for most Linux distrib (?)"
    echo "                              If you do improve or fix some bad behavior please let me know on GITHUB. "
    echo "  "
    echo "                     Appreciate this ? I wouldn't mind an extra-mini-small donation : "
    echo "                              @PAYPAL         -> paypal.me/DCVolo"
    echo "                              CRYPTO (MYST)   -> 0x11178f4D20D1C2b16d31f3332ccb817244D1E4f8"
    echo "                              CRYPTO          -> 0xC3D781E81aF9B99A8226A69676447EE621E7150E"
}


# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -c|--container) p_container="$2"; shift ;;
        -d|--discord) p_discord="$2"; shift ;;
        -h|--help) print_help; exit 0 ;;
        -m|--mode) p_check_mode="$2"; shift ;;
        -n|--nodeID) p_node_ID="$2"; shift ;;
        -p|--path-config) p_pathToconfigMainnet="$2"; shift ;;
        -s|--services) IFS=' ' read -r -a service_status <<< "$2"; shift ;;
        -t|--timer) p_timer="$2"; shift ;;
        -q|--quit) kill_this_script; exit 0 ;;
        *) echo "Unknown parameter passed: $1"; print_help; exit 1 ;;
    esac
    shift
done

# execute the main code only if everything went well after the command-line args phase
main &