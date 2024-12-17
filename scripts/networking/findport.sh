#!/bin/sh
# Cross-platform script to find processes or containers using a specific port.
# Supports macOS and Linux. Options: -pid, -container, -nocolor, --help.

PORT=""
NOCOLOR=0
PID_MODE=0
FOUND_PID=0
CONTAINER_MODE=0
FOUND_CONTAINER=0

setup_colors() {
    if [ "$NOCOLOR" -eq 0 ] && [ "$TERM" != "dumb" ] && [ "$PID_MODE" -eq 0 ] && [ "$CONTAINER_MODE" -eq 0 ]; then
        RED="\033[31m"
        GREEN="\033[32m"
        YELLOW="\033[33m"
        CYAN="\033[36m"
        RESET="\033[0m"
    else
        RED=""; GREEN=""; YELLOW=""; CYAN=""; RESET=""
    fi
}

usage() {
    echo "Usage: $0 [options] <port>"
    echo "Options:"
    echo "  -pid           Output only the process PID using the port or exit(1) if not found."
    echo "  -container     Output only the container ID using the port or exit(1) if not found."
    echo "  -nocolor       Disable colorized output."
    echo "  --help         Show this help message."
    exit 0
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -pid) PID_MODE=1 ;;
            -container) CONTAINER_MODE=1 ;;
            -nocolor) NOCOLOR=1 ;;
            --help) usage ;;
            -*) echo "Unknown option: $1"; usage ;;
            *) PORT="$1" ;;
        esac
        shift
    done

    if [ -z "$PORT" ]; then
        echo "${RED}Error: Port is required.${RESET}"
        usage
    fi
}

# Prints the message only if not in pid or container mode
safe_echo() {
    if [ "$PID_MODE" -eq 1 ] || [ "$CONTAINER_MODE" -eq 1 ]; then
        return
    fi
    echo "$@"
}

# Function to print PIDs. Takes a list of PIDs as argument.
print_pids() {
    PIDS="$1"
    for PID in $PIDS; do
        if echo "$PID" | grep -qE '^[0-9]+$' && [ "$PID" -ne 0 ]; then
            COMM=$(ps -p "$PID" -o comm= 2>/dev/null)
            FOUND_PID=1
            if [ "$PID_MODE" -eq 1 ]; then
                # In PID mode: just print the PID and exit
                echo "$PID"
                exit 0
            else
                # Normal mode: Print a descriptive message via safe_echo
                safe_echo "${GREEN}Found process PID: $PID, Command: $COMM${RESET}"
            fi
        fi
    done
}

# Function to print container ID
print_container() {
    CONTAINER_ID="$1"
    FOUND_CONTAINER=1

    if [ "$CONTAINER_MODE" -eq 1 ]; then
        # In container mode: just print the container ID and exit
        echo "$CONTAINER_ID"
        exit 0
    fi

    # Normal mode: Print a descriptive message
    safe_echo "${CYAN}Found container ID: $CONTAINER_ID${RESET}"

    # Print docker ps output for the found container
    # This matches the style shown in the user's example
    if command -v docker >/dev/null 2>&1; then
        safe_echo ""
        safe_echo "Container details from 'docker ps --filter \"publish=$PORT\"':"
        safe_echo "$(docker ps --filter "publish=$PORT")"
    fi

    # Print helpful Docker commands
    safe_echo ""
    safe_echo "===== Additional Docker Management Commands ====="
    safe_echo "View container details:"
    safe_echo "  docker ps -f \"id=$CONTAINER_ID\""
    safe_echo "  docker inspect $CONTAINER_ID"
    safe_echo ""
    safe_echo "Manage the container:"
    safe_echo "  docker start $CONTAINER_ID"
    safe_echo "  docker stop $CONTAINER_ID"
    safe_echo "  docker logs $CONTAINER_ID"
    safe_echo "  docker rm $CONTAINER_ID"
    safe_echo ""
    safe_echo "Inspect networking details:"
    safe_echo "  docker inspect $CONTAINER_ID | grep -A20 NetworkSettings"
    safe_echo ""
    safe_echo "Get a shell in the running container:"
    safe_echo "  docker exec -it $CONTAINER_ID /bin/sh"
    safe_echo ""
    safe_echo "If the container is not running, start a temporary shell:"
    safe_echo "  docker run --rm -it $CONTAINER_ID /bin/sh"
    safe_echo "================================================="
    safe_echo ""
}

check_proc_net_tcp() {
    if [ -f /proc/net/tcp ]; then
        HEX_PORT=$(printf '%04X\n' "$PORT")
        INODE=$(grep ":$HEX_PORT" /proc/net/tcp | awk '{print $10}')
        if [ -n "$INODE" ]; then
            PID_LIST=$(find /proc/*/fd -lname "socket:[$INODE]" 2>/dev/null | awk -F'/' '{print $3}' | sort -u)
            [ -n "$PID_LIST" ] && print_pids "$PID_LIST"
        fi
    fi
}

check_lsof() {
    if command -v lsof >/dev/null 2>&1; then
        PID_LIST=$(lsof -i :"$PORT" -t 2>/dev/null)
        [ -n "$PID_LIST" ] && print_pids "$PID_LIST"
    fi
}

check_netstat() {
    if command -v netstat >/dev/null 2>&1; then
        netstat -anp 2>/dev/null | grep -E "LISTEN.*:$PORT\b" | while read -r line; do
            PID=$(echo "$line" | awk '{print $NF}' | cut -d'/' -f1)
            if echo "$PID" | grep -qE '^[0-9]+$'; then
                print_pids "$PID"
            fi
        done
    fi
}

check_containers() {
    RUNTIME="$1"
    if command -v "$RUNTIME" >/dev/null 2>&1; then
        CONTAINER_IDS=$("$RUNTIME" ps --filter "publish=$PORT" --format "{{.ID}}" 2>/dev/null)
        if [ -n "$CONTAINER_IDS" ]; then
            for CID in $CONTAINER_IDS; do
                print_container "$CID"
            done
        fi
    fi
}

search_processes() {
    safe_echo "${YELLOW}--- Searching for Processes ---${RESET}"

    if [ "$FOUND_PID" -eq 0 ]; then check_proc_net_tcp; fi
    if [ "$FOUND_PID" -eq 0 ]; then check_lsof; fi
    if [ "$FOUND_PID" -eq 0 ]; then check_netstat; fi

    if [ "$FOUND_PID" -eq 0 ]; then
        safe_echo "${RED}No matching processes found using port $PORT.${RESET}"
    fi
}

search_containers() {
    safe_echo "${YELLOW}--- Searching for Containers ---${RESET}"

    if [ "$FOUND_CONTAINER" -eq 0 ]; then check_containers "podman"; fi
    if [ "$FOUND_CONTAINER" -eq 0 ]; then check_containers "docker"; fi

    if [ "$FOUND_CONTAINER" -eq 0 ]; then
        safe_echo "${RED}No matching containers found using port $PORT.${RESET}"
    fi
}

summary() {
    if [ "$PID_MODE" -eq 0 ] && [ "$CONTAINER_MODE" -eq 0 ]; then
        safe_echo "${YELLOW}Search completed for port $PORT.${RESET}"

        if [ "$FOUND_PID" -eq 0 ] && [ "$FOUND_CONTAINER" -eq 0 ]; then
            safe_echo "${RED}No matching processes or containers found using port $PORT.${RESET}"
        fi
    fi
}

main() {
    parse_args "$@"
    setup_colors
    search_processes
    search_containers
    summary

    if [ "$FOUND_PID" -eq 0 ] && [ "$FOUND_CONTAINER" -eq 0 ]; then
        if [ "$PID_MODE" -eq 1 ] || [ "$CONTAINER_MODE" -eq 1 ]; then
            exit 1
        fi
    fi
}

main "$@"
