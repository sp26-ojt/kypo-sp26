#!/bin/bash

# Common utility functions for OpenStack deployment

# Logging function with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Error logging
log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

# Warning logging
log_warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" >&2
}

# Success logging
log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1"
}

# Retry function for unreliable operations
retry() {
    local max_attempts=3
    local delay=5
    local attempt=1
    local exit_code=0

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi
        exit_code=$?
        log_warning "Attempt $attempt/$max_attempts failed. Retrying in ${delay}s..."
        sleep $delay
        ((attempt++))
    done

    log_error "All $max_attempts attempts failed for command: $*"
    return $exit_code
}

# Retry function for heavy/slow operations
retry_heavy() {
    local max_attempts=5
    local delay=30
    local attempt=1
    local exit_code=0

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi
        exit_code=$?
        log_warning "Attempt $attempt/$max_attempts failed. Retrying in ${delay}s..."
        sleep $delay
        ((attempt++))
    done

    log_error "All $max_attempts attempts failed for command: $*"
    return $exit_code
}

# Wait for network connectivity
wait_for_network() {
    local target="${1:-8.8.8.8}"
    local timeout="${2:-300}"
    local elapsed=0

    log "Waiting for network connection to $target..."

    while ! ping -c 1 "$target" &> /dev/null; do
        if [ $elapsed -ge $timeout ]; then
            log_error "Network timeout after ${timeout}s"
            return 1
        fi

        if [ $((elapsed % 30)) -eq 0 ] && [ $elapsed -gt 0 ]; then
            log "Network still unavailable. Elapsed: ${elapsed}s"
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    log_success "Network connectivity established"
    return 0
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Wait for service to be ready
wait_for_service() {
    local service_name="$1"
    local check_command="$2"
    local max_attempts="${3:-60}"
    local delay="${4:-5}"
    local attempt=1

    log "Waiting for $service_name to be ready..."

    while [ $attempt -le $max_attempts ]; do
        if eval "$check_command" >/dev/null 2>&1; then
            log_success "$service_name is ready"
            return 0
        fi

        if [ $((attempt % 10)) -eq 0 ]; then
            log "$service_name not ready yet... ($attempt/$max_attempts)"
        fi

        sleep $delay
        ((attempt++))
    done

    log_error "$service_name failed to become ready within timeout"
    return 1
}

# Create directory with error handling
safe_mkdir() {
    local dir="$1"
    if ! mkdir -p "$dir"; then
        log_error "Failed to create directory: $dir"
        return 1
    fi
    log "Created directory: $dir"
}

# Copy file with error handling
safe_copy() {
    local source="$1"
    local destination="$2"

    if [ ! -f "$source" ]; then
        log_error "Source file does not exist: $source"
        return 1
    fi

    if ! cp "$source" "$destination"; then
        log_error "Failed to copy $source to $destination"
        return 1
    fi

    log "Copied $source to $destination"
}

# Set up error handling
setup_error_handling() {
    set -euo pipefail
    trap 'log_error "Script failed at line $LINENO"' ERR
}

# Export functions for use in other scripts
export -f log log_error log_warning log_success retry wait_for_network
export -f command_exists wait_for_service safe_mkdir safe_copy setup_error_handling
export -f retry_heavy
