#!/usr/bin/env bash
set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Helper functions
print_header() {
    echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${CYAN}ℹ${NC} $1"
}

# Check Docker is running
check_docker() {
    print_header "Docker Status"
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker command not found"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        print_error "Docker daemon is not running"
        exit 1
    fi
    
    print_success "Docker daemon is running"
    
    local docker_version
    docker_version=$(docker version --format '{{.Server.Version}}')
    print_info "Docker version: ${docker_version}"
}

# Check Swarm status
check_swarm() {
    print_header "Swarm Status"
    
    local swarm_active
    swarm_active=$(docker info --format '{{.Swarm.LocalNodeState}}')
    
    if [[ "${swarm_active}" != "active" ]]; then
        print_error "Swarm is not active on this node"
        exit 1
    fi
    
    print_success "Swarm is active"
    
    local node_role
    node_role=$(docker info --format '{{.Swarm.ControlAvailable}}')
    
    if [[ "${node_role}" != "true" ]]; then
        print_error "This node is not a Swarm Manager"
        exit 1
    fi
    
    print_success "This node is a Swarm Manager"
}

# List cluster nodes
list_nodes() {
    print_header "Cluster Nodes"
    
    echo -e "${BOLD}$(printf '%-15s %-25s %-12s %-15s %-10s' 'ID' 'NAME' 'STATUS' 'AVAILABILITY' 'ROLE')${NC}"
    echo -e "$(printf '%-15s %-25s %-12s %-15s %-10s' '─────────────' '─────────────────────' '──────────' '─────────────' '────────')"
    
    while IFS='|' read -r node_id hostname status availability role; do
        local status_color="${GREEN}"
        local avail_color="${GREEN}"
        
        [[ "${status}" != "Ready" ]] && status_color="${RED}"
        [[ "${availability}" != "Active" ]] && avail_color="${YELLOW}"
        
        local role_display="${role}"
        [[ "${role}" == "Leader" ]] && role_display="${BOLD}${GREEN}${role}${NC}"
        
        printf "%-15s %-25s ${status_color}%-12s${NC} ${avail_color}%-15s${NC} %b\n" \
            "${node_id:0:12}" \
            "${hostname}" \
            "${status}" \
            "${availability}" \
            "${role_display}"
    done < <(docker node ls --format '{{.ID}}|{{.Hostname}}|{{.Status}}|{{.Availability}}|{{.ManagerStatus}}')
}

# List services for Synapse stacks
list_services() {
    print_header "Synapse Services"
    
    # Check both synapse-infra and synapse-dev stacks
    local stacks=("synapse-infra" "synapse-dev")
    
    for stack in "${stacks[@]}"; do
        local service_count
        service_count=$(docker service ls --filter "label=com.docker.stack.namespace=${stack}" --format '{{.Name}}' 2>/dev/null | wc -l)
        
        if [[ ${service_count} -eq 0 ]]; then
            print_warning "No services found for stack: ${stack}"
            continue
        fi
        
        echo -e "\n${BOLD}Stack: ${stack}${NC}\n"
        
        echo -e "${BOLD}$(printf '%-30s %-10s %-50s %-20s' 'SERVICE' 'REPLICAS' 'IMAGE' 'PORTS')${NC}"
        echo -e "$(printf '%-30s %-10s %-50s %-20s' '────────────────────────────' '────────' '────────────────────────────────────────────────' '──────────────────')"
        
        while IFS='|' read -r name replicas image ports; do
            local replica_color="${GREEN}"
            
            # Parse replicas (format: "actual/desired")
            if [[ "${replicas}" =~ ^([0-9]+)/([0-9]+) ]]; then
                local actual="${BASH_REMATCH[1]}"
                local desired="${BASH_REMATCH[2]}"
                
                if [[ ${actual} -lt ${desired} ]]; then
                    replica_color="${RED}"
                elif [[ ${actual} -eq 0 ]]; then
                    replica_color="${RED}"
                fi
            fi
            
            # Truncate image if too long
            local image_short="${image}"
            if [[ ${#image} -gt 48 ]]; then
                image_short="${image:0:45}..."
            fi
            
            printf "%-30s ${replica_color}%-10s${NC} %-50s %-20s\n" \
                "${name}" \
                "${replicas}" \
                "${image_short}" \
                "${ports:-<none>}"
        done < <(docker service ls \
            --filter "label=com.docker.stack.namespace=${stack}" \
            --format '{{.Name}}|{{.Replicas}}|{{.Image}}|{{.Ports}}')
    done
}

# List failed or recent tasks
list_failed_tasks() {
    print_header "Recent Failed Tasks (Last 5 Minutes)"
    
    # Get tasks from last 5 minutes with non-zero exit codes or failed states
    local found_failures=false
    
    while IFS='|' read -r task_id name node desired_state current_state error; do
        found_failures=true
        
        local state_color="${RED}"
        
        echo -e "${RED}✗${NC} ${BOLD}Task:${NC} ${task_id:0:12}"
        echo -e "  ${CYAN}Service:${NC}      ${name}"
        echo -e "  ${CYAN}Node:${NC}         ${node}"
        echo -e "  ${CYAN}Desired:${NC}      ${desired_state}"
        echo -e "  ${state_color}Current:${NC}      ${current_state}"
        
        if [[ -n "${error}" ]]; then
            echo -e "  ${RED}Error:${NC}        ${error}"
        fi
        
        echo ""
    done < <(docker service ps \
        --filter "desired-state=running" \
        --filter "desired-state=shutdown" \
        --format '{{.ID}}|{{.Name}}|{{.Node}}|{{.DesiredState}}|{{.CurrentState}}|{{.Error}}' \
        $(docker service ls -q 2>/dev/null) 2>/dev/null | \
        grep -E "(Failed|Rejected|Orphaned|Remove)" || true)
    
    if [[ "${found_failures}" == "false" ]]; then
        print_success "No failed tasks found in recent history"
    fi
}

# Main execution
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║         Synapse Docker Swarm Health Check                    ║"
    echo "║         $(date '+%Y-%m-%d %H:%M:%S %Z')                          ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_docker
    check_swarm
    list_nodes
    list_services
    list_failed_tasks
    
    echo -e "\n${GREEN}${BOLD}Health check completed${NC}\n"
}

main "$@"
