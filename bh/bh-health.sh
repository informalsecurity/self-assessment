#!/bin/bash

# BloodHound Container Health Monitoring & Recovery Script
# This script monitors BloodHound containers and handles unhealthy states

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Configuration
BLOODHOUND_DIR="/opt/bloodhound"
LOG_FILE="/var/log/bloodhound-health.log"
COMPOSE_PROJECT_NAME="bloodhound"
HEALTH_CHECK_INTERVAL=60  # seconds
MAX_RESTART_ATTEMPTS=3
RESTART_DELAY=30  # seconds between restart attempts

# Logging functions
log() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${GREEN}${message}${NC}"
    echo "$message" >> "$LOG_FILE"
}

warn() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1"
    echo -e "${YELLOW}${message}${NC}"
    echo "$message" >> "$LOG_FILE"
}

error() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1"
    echo -e "${RED}${message}${NC}"
    echo "$message" >> "$LOG_FILE"
}

info() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1"
    echo -e "${BLUE}${message}${NC}"
    echo "$message" >> "$LOG_FILE"
}

# Check if BloodHound directory exists
check_bloodhound_dir() {
    if [ ! -d "$BLOODHOUND_DIR" ]; then
        error "BloodHound directory not found: $BLOODHOUND_DIR"
        exit 1
    fi
    cd "$BLOODHOUND_DIR"
}

# Get container health status
get_container_health() {
    local container_name="$1"
    local health_status
    
    # Get health status from docker inspect
    health_status=$(docker inspect --format='{{.State.Health.Status}}' "${COMPOSE_PROJECT_NAME}-${container_name}-1" 2>/dev/null || echo "not_found")
    
    # If health status is not available, check if container is running
    if [ "$health_status" = "<no value>" ] || [ "$health_status" = "not_found" ]; then
        local running_status=$(docker inspect --format='{{.State.Running}}' "${COMPOSE_PROJECT_NAME}-${container_name}-1" 2>/dev/null || echo "false")
        if [ "$running_status" = "true" ]; then
            health_status="running"
        else
            health_status="stopped"
        fi
    fi
    
    echo "$health_status"
}

# Check if container is responsive
check_container_responsiveness() {
    local service="$1"
    local port="$2"
    local timeout=5
    
    case "$service" in
        "bloodhound")
            # Check BloodHound web interface
            if curl -s --max-time $timeout "http://localhost:$port/api/version" >/dev/null 2>&1; then
                return 0
            fi
            ;;
        "graph-db")
            # Check Neo4j
            if curl -s --max-time $timeout "http://localhost:$port" >/dev/null 2>&1; then
                return 0
            fi
            ;;
        "app-db")
            # Check PostgreSQL
            if docker exec "${COMPOSE_PROJECT_NAME}-app-db-1" pg_isready -U bloodhound >/dev/null 2>&1; then
                return 0
            fi
            ;;
    esac
    
    return 1
}

# Get all BloodHound containers
get_bloodhound_containers() {
    docker-compose ps --services 2>/dev/null || echo "bloodhound graph-db app-db"
}

# Check health of all containers
check_all_containers() {
    local unhealthy_containers=()
    local all_containers
    
    all_containers=$(get_bloodhound_containers)
    
    info "Checking health of all BloodHound containers..."
    
    for container in $all_containers; do
        local health=$(get_container_health "$container")
        local responsive=true
        
        # Additional responsiveness checks
        case "$container" in
            "bloodhound")
                if ! check_container_responsiveness "bloodhound" "8080"; then
                    responsive=false
                fi
                ;;
            "graph-db")
                if ! check_container_responsiveness "graph-db" "7474"; then
                    responsive=false
                fi
                ;;
            "app-db")
                if ! check_container_responsiveness "app-db" "5432"; then
                    responsive=false
                fi
                ;;
        esac
        
        if [ "$health" = "unhealthy" ] || [ "$health" = "stopped" ] || [ "$responsive" = false ]; then
            unhealthy_containers+=("$container")
            warn "Container $container is unhealthy (status: $health, responsive: $responsive)"
        else
            log "Container $container is healthy (status: $health)"
        fi
    done
    
    echo "${unhealthy_containers[@]}"
}

# Restart a specific container
restart_container() {
    local container="$1"
    local attempt="$2"
    
    log "Restarting container: $container (attempt $attempt/$MAX_RESTART_ATTEMPTS)"
    
    # Stop the container gracefully
    docker-compose stop "$container" || warn "Failed to stop $container gracefully"
    
    sleep 5
    
    # Start the container
    if docker-compose up -d "$container"; then
        log "Container $container restarted successfully"
        sleep "$RESTART_DELAY"
        
        # Wait for container to be ready
        local wait_time=0
        local max_wait=120
        
        while [ $wait_time -lt $max_wait ]; do
            local health=$(get_container_health "$container")
            if [ "$health" = "healthy" ] || [ "$health" = "running" ]; then
                log "Container $container is now healthy"
                return 0
            fi
            sleep 5
            wait_time=$((wait_time + 5))
        done
        
        warn "Container $container took too long to become healthy"
        return 1
    else
        error "Failed to restart container $container"
        return 1
    fi
}

# Restart all containers in dependency order
restart_all_containers() {
    log "Restarting all BloodHound containers in dependency order..."
    
    # Stop all containers
    log "Stopping all containers..."
    docker-compose down
    
    sleep 10
    
    # Start containers in dependency order
    log "Starting containers in dependency order..."
    
    # Start databases first
    log "Starting databases..."
    docker-compose up -d app-db graph-db
    
    # Wait for databases to be ready
    log "Waiting for databases to be ready..."
    sleep 30
    
    # Check database health
    local max_wait=120
    local wait_time=0
    
    while [ $wait_time -lt $max_wait ]; do
        local app_db_health=$(get_container_health "app-db")
        local graph_db_health=$(get_container_health "graph-db")
        
        if [ "$app_db_health" = "healthy" ] || [ "$app_db_health" = "running" ]; then
            if [ "$graph_db_health" = "healthy" ] || [ "$graph_db_health" = "running" ]; then
                log "Databases are ready"
                break
            fi
        fi
        
        sleep 5
        wait_time=$((wait_time + 5))
    done
    
    # Start BloodHound application
    log "Starting BloodHound application..."
    docker-compose up -d bloodhound
    
    # Wait for BloodHound to be ready
    sleep 30
    
    log "All containers restarted"
}

# Handle unhealthy containers
handle_unhealthy_containers() {
    local unhealthy_containers=("$@")
    
    if [ ${#unhealthy_containers[@]} -eq 0 ]; then
        log "All containers are healthy"
        return 0
    fi
    
    warn "Found ${#unhealthy_containers[@]} unhealthy container(s): ${unhealthy_containers[*]}"
    
    # If more than one container is unhealthy, restart all
    if [ ${#unhealthy_containers[@]} -gt 1 ]; then
        warn "Multiple containers unhealthy, performing full restart"
        restart_all_containers
        return $?
    fi
    
    # Handle single unhealthy container
    local container="${unhealthy_containers[0]}"
    local attempt=1
    
    while [ $attempt -le $MAX_RESTART_ATTEMPTS ]; do
        if restart_container "$container" "$attempt"; then
            log "Successfully recovered container: $container"
            return 0
        fi
        
        attempt=$((attempt + 1))
        if [ $attempt -le $MAX_RESTART_ATTEMPTS ]; then
            warn "Restart attempt $((attempt-1)) failed, waiting before retry..."
            sleep "$RESTART_DELAY"
        fi
    done
    
    error "Failed to recover container $container after $MAX_RESTART_ATTEMPTS attempts"
    warn "Performing full restart as last resort..."
    restart_all_containers
}

# Generate detailed status report
generate_status_report() {
    echo ""
    echo "=============================================="
    echo "  BloodHound Container Health Report"
    echo "=============================================="
    echo "Time: $(date)"
    echo ""
    
    local all_containers
    all_containers=$(get_bloodhound_containers)
    
    for container in $all_containers; do
        local health=$(get_container_health "$container")
        local container_id=$(docker ps -q -f name="${COMPOSE_PROJECT_NAME}-${container}-1" 2>/dev/null || echo "N/A")
        local uptime=""
        
        if [ "$container_id" != "N/A" ]; then
            uptime=$(docker inspect --format='{{.State.StartedAt}}' "$container_id" 2>/dev/null | xargs -I {} date -d {} "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "Unknown")
        fi
        
        echo "Container: $container"
        echo "  Status: $health"
        echo "  Container ID: $container_id"
        echo "  Started: $uptime"
        
        # Additional service-specific checks
        case "$container" in
            "bloodhound")
                if check_container_responsiveness "bloodhound" "8080"; then
                    echo "  Web Interface: Responsive"
                else
                    echo "  Web Interface: Not Responsive"
                fi
                ;;
            "graph-db")
                if check_container_responsiveness "graph-db" "7474"; then
                    echo "  Neo4j Browser: Responsive"
                else
                    echo "  Neo4j Browser: Not Responsive"
                fi
                ;;
            "app-db")
                if check_container_responsiveness "app-db" "5432"; then
                    echo "  PostgreSQL: Responsive"
                else
                    echo "  PostgreSQL: Not Responsive"
                fi
                ;;
        esac
        echo ""
    done
    
    echo "=============================================="
}

# Main execution logic
main() {
    case "${1:-}" in
        "check")
            check_bloodhound_dir
            log "Performing health check..."
            
            local unhealthy_containers
            unhealthy_containers=($(check_all_containers))
            
            if [ ${#unhealthy_containers[@]} -eq 0 ]; then
                log "✅ All containers are healthy"
                exit 0
            else
                warn "❌ Found unhealthy containers: ${unhealthy_containers[*]}"
                exit 1
            fi
            ;;
            
        "fix")
            check_bloodhound_dir
            log "Checking and fixing unhealthy containers..."
            
            local unhealthy_containers
            unhealthy_containers=($(check_all_containers))
            
            handle_unhealthy_containers "${unhealthy_containers[@]}"
            ;;
            
        "restart-all")
            check_bloodhound_dir
            log "Performing full restart of all containers..."
            restart_all_containers
            ;;
            
        "restart")
            if [ -z "$2" ]; then
                error "Please specify container name: bloodhound, graph-db, or app-db"
                exit 1
            fi
            
            check_bloodhound_dir
            restart_container "$2" "1"
            ;;
            
        "status")
            check_bloodhound_dir
            generate_status_report
            ;;
            
        "monitor")
            check_bloodhound_dir
            log "Starting continuous monitoring (interval: ${HEALTH_CHECK_INTERVAL}s)"
            log "Press Ctrl+C to stop monitoring"
            
            while true; do
                local unhealthy_containers
                unhealthy_containers=($(check_all_containers))
                
                if [ ${#unhealthy_containers[@]} -gt 0 ]; then
                    warn "Auto-fixing unhealthy containers: ${unhealthy_containers[*]}"
                    handle_unhealthy_containers "${unhealthy_containers[@]}"
                fi
                
                sleep "$HEALTH_CHECK_INTERVAL"
            done
            ;;
            
        "setup-watchdog")
            log "Setting up container health watchdog service..."
            
            # Create systemd service for monitoring
            cat > /etc/systemd/system/bloodhound-watchdog.service << EOF
[Unit]
Description=BloodHound Container Health Watchdog
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=$0 monitor
Restart=always
RestartSec=60
User=root

[Install]
WantedBy=multi-user.target
EOF

            # Create timer for periodic checks
            cat > /etc/systemd/system/bloodhound-watchdog.timer << EOF
[Unit]
Description=BloodHound Container Health Check Timer
Requires=bloodhound-watchdog.service

[Timer]
OnCalendar=*:0/5  # Every 5 minutes
Persistent=true

[Install]
WantedBy=timers.target
EOF

            systemctl daemon-reload
            systemctl enable bloodhound-watchdog.timer
            systemctl start bloodhound-watchdog.timer
            
            log "✅ Watchdog service setup complete"
            log "Health checks will run every 5 minutes"
            log "View status: systemctl status bloodhound-watchdog.timer"
            ;;
            
        *)
            echo "BloodHound Container Health Management"
            echo ""
            echo "Usage: $0 {check|fix|restart-all|restart|status|monitor|setup-watchdog}"
            echo ""
            echo "Commands:"
            echo "  check           - Check health of all containers"
            echo "  fix             - Automatically fix any unhealthy containers"
            echo "  restart-all     - Restart all containers in proper order"
            echo "  restart <name>  - Restart specific container (bloodhound|graph-db|app-db)"
            echo "  status          - Show detailed status report"
            echo "  monitor         - Continuously monitor and auto-fix (Ctrl+C to stop)"
            echo "  setup-watchdog  - Setup automatic monitoring service"
            echo ""
            echo "Examples:"
            echo "  $0 check                    # Check container health"
            echo "  $0 fix                      # Fix any issues automatically"
            echo "  $0 restart bloodhound       # Restart just BloodHound"
            echo "  $0 restart-all              # Restart everything"
            echo "  $0 monitor                  # Start continuous monitoring"
            echo ""
            echo "Log file: $LOG_FILE"
            exit 1
            ;;
    esac
}

# Create log directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"

# Run main function with all arguments
main "$@"
