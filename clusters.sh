#!/bin/bash
# This script is used to create a lab cluster board, the board looks like below with a fixed width:
# Tilte: <Hub Cluster Name> <Hub Cluster Version> <Hub Cluster Nodes> <Spoke Clusters>
# Under <Hub Cluster Nodes>, there should be multiple lines and each line should show node name and state (Running, Not Running, etc.)
# Under <Spoke Clusters>, there should be multiple lines and each line should show spoke cluster name and state (Running, Not Running, etc.), version and reference configuration version
# The reference configuration version can be fetched from the spoke cluster's managedcluster object, the key is "configuration-version"

# The script will take a pre-defined hub clusters within a config file with yaml format, the config file is like below:
    # - api: https://api.hub1.domain.com:6443
    #   username: admin
    #   password: admin
    # - api: https://api.hub2.domain.com:6443
    #   username: admin
    #   password: admin
    # - api: https://api.hub3.domain.com:6443
    #   username: admin
    #   password: admin
    # - api: https://api.hub4.domain.com:6443
    #   username: admin
    #   password: admin
    # - kubeconfig: /path/to/kubeconfig-hub5.yaml
    # - kubeconfig: /path/to/kubeconfig-hub6.yaml

# The script will use the kubeconfig or username/password to login to the hub cluster and get the hub cluster information, including the hub cluster name, version, nodes and spoke clusters.

set -euo pipefail

basedir="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
# Default values
CONFIG_FILE="$basedir/.clusters.yaml"
BOARD_WIDTH=120
BOX_WIDTH=90
MODE="short"
FILTER_HUBS=()
# API timeout in seconds (can be overridden with LAB_TIMEOUT env var)
API_TIMEOUT="${LAB_TIMEOUT:-3}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check dependencies
check_dependencies() {
    local deps=("oc" "yq" "jq")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo "Error: $dep is required but not installed."
            exit 1
        fi
    done
}

# Print a horizontal line
print_line() {
    printf '=%.0s' $(seq 1 $BOARD_WIDTH)
    echo
}

# Print a centered title
print_title() {
    local text="$1"
    local padding=$(( (BOARD_WIDTH - ${#text}) / 2 ))
    printf '%*s%s%*s\n' $padding '' "$text" $padding ''
}

# Print a section header
print_header() {
    local text="$1"
    echo -e "${BLUE}${text}${NC}"
}

# Parse YAML config file and extract hub cluster configurations
parse_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        echo "Error: Config file '$config_file' not found."
        exit 1
    fi
    
    # Get the number of hub clusters
    yq eval '.clusters | length' "$config_file"
}

# Get hub cluster config by index
get_hub_config() {
    local config_file="$1"
    local index="$2"
    local field="$3"
    
    yq eval ".clusters[$index].$field" "$config_file"
}

# Login to cluster using username/password
login_with_credentials() {
    local api="$1"
    local username="$2"
    local password="$3"
    
    oc login "$api" -u "$username" -p "$password" --insecure-skip-tls-verify=true --request-timeout="${API_TIMEOUT}s" &> /dev/null
}

# Set kubeconfig context
set_kubeconfig() {
    local kubeconfig="$1"
    export KUBECONFIG="$kubeconfig"
}

# Fast connectivity check - return 0 if reachable, 1 if not
check_cluster_connectivity() {
    # Try a simple, fast API call with minimal timeout
    # Use version endpoint which is lightweight
    if ! oc version --request-timeout=2s &>/dev/null; then
        return 1
    fi
    return 0
}

# Get hub cluster name
get_hub_name() {
    local full_name=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' --request-timeout="${API_TIMEOUT}s" 2>/dev/null || echo "Unknown")
    # Remove the random suffix (e.g., acm1-d7bnf -> acm1)
    echo "$full_name" | sed 's/-[a-z0-9]\{5\}$//'
}

# Get hub cluster version
get_hub_version() {
    oc get clusterversion version -o jsonpath='{.status.desired.version}' --request-timeout="${API_TIMEOUT}s" 2>/dev/null || \
    oc version --request-timeout="${API_TIMEOUT}s" 2>/dev/null | grep "Server Version" | awk '{print $3}' || \
    echo "Unknown"
}

# Get hub cluster nodes summary
get_hub_nodes_summary() {
    # Get nodes data in one call and process with awk for better performance
    local node_counts=$(oc get nodes --no-headers --request-timeout="${API_TIMEOUT}s" 2>/dev/null | awk '
        BEGIN { total=0; ready=0 }
        { total++ }
        /Ready/ { ready++ }
        END { print total, ready }
    ')
    
    if [[ -z "$node_counts" ]]; then
        echo -e "${YELLOW}●${NC} Nodes: 0 Ready (Total: 0)"
        return
    fi
    
    local total=$(echo "$node_counts" | awk '{print $1}')
    local ready=$(echo "$node_counts" | awk '{print $2}')
    local notready=$((total - ready))
    
    if [[ $notready -gt 0 ]]; then
        echo -e "${RED}●${NC} Nodes: $ready Ready, ${RED}$notready Not Ready${NC} (Total: $total)"
    else
        echo -e "${GREEN}●${NC} Nodes: $ready Ready (Total: $total)"
    fi
}

# Get hub cluster API URL
get_hub_api() {
    oc whoami --show-server --request-timeout="${API_TIMEOUT}s" 2>/dev/null | sed 's|^https://||' || echo "N/A"
}

# Get hub cluster console URL
get_hub_console() {
    oc get route console -n openshift-console -o jsonpath='{.spec.host}' --request-timeout="${API_TIMEOUT}s" 2>/dev/null | \
    sed 's|^|https://|' || echo "N/A"
}

# Get hub cluster GitOps URL
get_hub_gitops() {
    oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' --request-timeout="${API_TIMEOUT}s" 2>/dev/null | \
    sed 's|^|https://|' || echo "N/A"
}

# Global variable to store policy data
declare -A POLICY_CACHE

# Fetch all policies once and cache them
fetch_all_policies() {
    # Use jsonpath to fetch ONLY the fields we need (much faster than full JSON)
    # This avoids downloading huge annotations and spec fields
    local policy_data=$(oc get policies.policy.open-cluster-management.io -A \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .status.status[*]}{.clustername}{":"}{.compliant}{","}{end}{"@"}{end}' \
        --request-timeout="${API_TIMEOUT}s" 2>/dev/null)
    
    # Parse the compact format: policy|cluster:status,cluster:status,@policy|cluster:status,...
    if [[ -n "$policy_data" ]]; then
        # Split by @ to get each policy
        local IFS='@'
        for policy_entry in $policy_data; do
            if [[ -z "$policy_entry" ]]; then
                continue
            fi
            
            # Split policy name from cluster statuses
            local policy_name="${policy_entry%%|*}"
            local cluster_statuses="${policy_entry#*|}"
            
            # Parse each cluster:status pair
            IFS=',' read -ra status_pairs <<< "$cluster_statuses"
            for pair in "${status_pairs[@]}"; do
                if [[ -n "$pair" && "$pair" == *":"* ]]; then
                    local cluster="${pair%%:*}"
                    local status="${pair#*:}"
                    [[ -z "$status" ]] && status="Unknown"
                    POLICY_CACHE["$cluster:$policy_name"]="$status"
                fi
            done
        done
    fi
}

# Get overall compliance status for a cluster
get_cluster_compliance_summary() {
    local cluster_name="$1"
    
    local total=0
    local compliant=0
    local noncompliant=0
    
    for key in "${!POLICY_CACHE[@]}"; do
        if [[ "$key" == "$cluster_name:"* ]]; then
            ((total++))
            local status="${POLICY_CACHE[$key]}"
            if [[ "$status" == "Compliant" ]]; then
                ((compliant++))
            elif [[ "$status" == "NonCompliant" ]]; then
                ((noncompliant++))
            fi
        fi
    done
    
    if [[ $total -eq 0 ]]; then
        echo "N/A"
        return
    fi
    
    local color=$GREEN
    local summary="$compliant/$total"
    
    if [[ $noncompliant -gt 0 ]]; then
        color=$RED
    fi
    
    echo -e "${color}${summary}${NC}"
}

# Get policies for a spoke cluster from cache
get_cluster_policies() {
    local cluster_name="$1"
    
    # Skip if in short mode
    if [[ "$MODE" == "short" ]]; then
        return
    fi
    
    # Find all policies for this cluster
    local found=false
    for key in "${!POLICY_CACHE[@]}"; do
        if [[ "$key" == "$cluster_name:"* ]]; then
            found=true
            local policy="${key#*:}"
            local status="${POLICY_CACHE[$key]}"
            
            local color=$YELLOW
            if [[ "$status" == "Compliant" ]]; then
                color=$GREEN
            elif [[ "$status" == "NonCompliant" ]]; then
                color=$RED
            fi
            
            printf "      ${color}▪${NC} %-40s %s\n" "$policy" "$status"
        fi
    done | sort
}

# Print a box line
print_box_line() {
    local width=${1:-$BOX_WIDTH}
    printf '  +'
    printf -- '-%.0s' $(seq 1 $((width - 4)))
    printf '+\n'
}

# Print box content
print_box_content() {
    local content="$1"
    local width=${2:-$BOX_WIDTH}
    # Remove ANSI color codes for length calculation
    local clean_content=$(printf "%b" "$content" | sed -r 's/\x1b\[[0-9;]*m//g')
    local clean_length=${#clean_content}
    local padding=$((width - clean_length - 6))
    if [ $padding -lt 0 ]; then
        padding=0
    fi
    printf "  | %b%*s |\n" "$content" $((padding + 1)) ""
}

# Get spoke clusters
get_spoke_clusters() {
    # Fetch all policies once for this hub (both modes need it now)
    fetch_all_policies
    
    # Fetch all managed clusters data in ONE API call for better performance
    local clusters_json=$(oc get managedclusters -o json --request-timeout="${API_TIMEOUT}s" 2>/dev/null)
    
    if [[ -z "$clusters_json" || "$clusters_json" == "null" ]]; then
        echo "  No spoke clusters found"
        unset POLICY_CACHE
        declare -gA POLICY_CACHE
        return
    fi
    
    local has_clusters=false
    
    # Parse all cluster data at once using jq
    local cluster_data=$(echo "$clusters_json" | jq -r '.items[] | 
        select(.metadata.name != "local-cluster") | 
        [
            .metadata.name,
            (.status.conditions[]? | select(.type=="ManagedClusterConditionAvailable") | .status // "Unknown"),
            (.metadata.labels.openshiftVersion // "Unknown"),
            (.metadata.labels."configuration-version" // "N/A"),
            (.spec.managedClusterClientConfigs[0].url // "N/A")
        ] | @tsv' 2>/dev/null)
    
    if [[ -z "$cluster_data" ]]; then
        echo "  No spoke clusters found"
        unset POLICY_CACHE
        declare -gA POLICY_CACHE
        return
    fi
    
    # Process each cluster from the pre-fetched data
    while IFS=$'\t' read -r name available version config_version api_url; do
        has_clusters=true
        
        # Determine status and color
        local status="Unknown"
        local color=$YELLOW
        
        if [[ "$available" == "True" ]]; then
            status="Available"
            color=$GREEN
        elif [[ "$available" == "False" ]]; then
            status="NotAvailable"
            color=$RED
        fi
        
        # Get compliance summary for short mode
        local compliance_info=""
        if [[ "$MODE" == "short" ]]; then
            local compliance=$(get_cluster_compliance_summary "$name")
            compliance_info=" | Policies: $compliance"
        fi
        
        # Print cluster info
        printf "  ${color}●${NC} ${BLUE}%-14s${NC} | Status: ${color}%-10s${NC} | Ver: %-13s | Cfg: %-15s | API: %-70s%s\n" "$name" "$status" "$version" "$config_version" "$api_url" "$compliance_info"
        
        # Get and display policies only in full mode
        if [[ "$MODE" == "full" ]]; then
            local policies=$(get_cluster_policies "$name")
            if [[ -n "$policies" ]]; then
                echo -e "    ${BLUE}Policies:${NC}"
                echo -e "$policies"
            else
                echo -e "    ${BLUE}Policies:${NC} None"
            fi
        fi
    done <<< "$cluster_data"
    
    if [[ "$has_clusters" == "false" ]]; then
        echo "  No spoke clusters found"
    fi
    
    # Clear policy cache for next hub
    unset POLICY_CACHE
    declare -gA POLICY_CACHE
}

# Process a single hub cluster
process_hub() {
    local config_file="$1"
    local index="$2"
    
    # Get hub configuration
    local hub_name=$(get_hub_config "$config_file" "$index" "name")
    local api=$(get_hub_config "$config_file" "$index" "api")
    local username=$(get_hub_config "$config_file" "$index" "username")
    local password=$(get_hub_config "$config_file" "$index" "password")
    local kubeconfig=$(get_hub_config "$config_file" "$index" "kubeconfig")
    
    # Filter by hub name if specified
    if [[ ${#FILTER_HUBS[@]} -gt 0 ]]; then
        local match=false
        for filter in "${FILTER_HUBS[@]}"; do
            if [[ "$hub_name" == "$filter" ]]; then
                match=true
                break
            fi
        done
        if [[ "$match" == "false" ]]; then
            return 0
        fi
    fi
    
    # Connect to the hub cluster
    if [[ "$kubeconfig" != "null" ]]; then
        set_kubeconfig "$kubeconfig"
    elif [[ "$api" != "null" ]]; then
        if ! login_with_credentials "$api" "$username" "$password"; then
            echo "Failed to login to $api"
            return 1
        fi
    else
        echo "Error: Invalid hub configuration at index $index"
        return 1
    fi
    
    # Fast connectivity check to skip unreachable hubs early
    if ! check_cluster_connectivity; then
        local display_name="${hub_name:-Unknown}"
        echo
        printf "${RED}Hub: %-19s [UNREACHABLE - Skipping]${NC}\n" "$display_name"
        return 0
    fi
    
    # Get hub cluster information
    local cluster_name=$(get_hub_name)
    local hub_version=$(get_hub_version)
    local nodes_info=$(get_hub_nodes_summary)
    local hub_api=$(get_hub_api)
    local hub_console=$(get_hub_console)
    local hub_gitops=$(get_hub_gitops)
    
    # Print hub cluster board (use config name if available, otherwise cluster name)
    local display_name="${hub_name:-$cluster_name}"
    echo
    # Align second line with "| Nodes:" from first line
    # Padding: "Hub: " (5) + name (19) + " (v" (3) + version (10) + ")  " (3) = 40
    
    printf "${BLUE}Hub: %-19s (v%-10s)${NC}  |  %s  | API: %s\n" "$display_name" "$hub_version" "$nodes_info" "$hub_api"
    printf "%40s|  Console: %s  | GitOps: %s\n" "" "$hub_console" "$hub_gitops"
    # Get and display spoke clusters
    print_header "Spoke Clusters"
    get_spoke_clusters
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -m|--mode)
                MODE="$2"
                if [[ "$MODE" != "full" && "$MODE" != "short" ]]; then
                    echo "Error: Mode must be 'full' or 'short'"
                    exit 1
                fi
                shift 2
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                # Treat remaining arguments as hub names
                FILTER_HUBS+=("$1")
                shift
                ;;
        esac
    done
}

# Show usage information
show_usage() {
    cat <<EOF
Usage: clusters.sh[OPTIONS] [HUB_NAMES...]

Options:
  -c, --config FILE    Config file path (default: .lab-hubs.yaml)
  -m, --mode MODE      Display mode: full or short (default: short)
                       full:  Show spoke clusters with detailed policies
                       short: Show spoke clusters with policy summary
  -h, --help           Show this help message

Arguments:
  HUB_NAMES            Filter by specific hub names (space-separated)

Environment Variables:
  LAB_TIMEOUT          API timeout in seconds (default: 3)

Examples:
  clusters.sh                          # Show all hubs in short mode
  clusters.sh-m full                   # Show all hubs with detailed policies
  clusters.shacm1 acm2                 # Show only acm1 and acm2 hubs
  clusters.sh-m full acm1              # Show acm1 with detailed policies
  clusters.sh-c custom.yaml            # Use custom config file
  LAB_TIMEOUT=5 clusters.sh            # Use 5 second API timeout

Config file format:
clusters:
  - name: acm1
    kubeconfig: /path/to/kubeconfig-acm1.yaml
  - name: acm2
    api: https://api.hub2.domain.com:6443
    username: admin
    password: admin
EOF
}

# Main function
main() {
    parse_args "$@"
    
    check_dependencies
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Config file '$CONFIG_FILE' not found."
        echo
        show_usage
        exit 1
    fi
    
    local num_hubs=$(parse_config "$CONFIG_FILE")
    
    if [[ "$num_hubs" -eq 0 ]]; then
        echo "Error: No hub clusters defined in config file."
        exit 1
    fi
    
    # Process each hub cluster
    for ((i=0; i<num_hubs; i++)); do
        process_hub "$CONFIG_FILE" "$i" || echo "Warning: Failed to process hub at index $i"
    done
}

# Run main function
main "$@"