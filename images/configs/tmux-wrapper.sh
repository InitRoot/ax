#!/bin/bash
# Tmux isolation wrapper for axiom containerized instances
# Dynamically determines instance name from multiple sources

# Debug function (only if DEBUG_TMUX is set)
debug_log() {
    [ "$DEBUG_TMUX" = "1" ] && echo "[TMUX DEBUG] $1" >&2
}

# Try multiple methods to get instance name
if [ -n "$AXIOM_INSTANCE_NAME" ]; then
    INSTANCE_NAME="$AXIOM_INSTANCE_NAME"
    debug_log "Using AXIOM_INSTANCE_NAME: $INSTANCE_NAME"
elif [ -f /tmp/axiom_instance_name ] && [ -r /tmp/axiom_instance_name ]; then
    INSTANCE_NAME=$(cat /tmp/axiom_instance_name 2>/dev/null | tr -d '\n')
    debug_log "Using /tmp/axiom_instance_name: $INSTANCE_NAME"
else
    # Extract instance name from hostname (remove axiom- prefix)
    HOSTNAME=$(hostname 2>/dev/null || echo 'unknown')
    INSTANCE_NAME=${HOSTNAME#axiom-}
    debug_log "Using hostname extraction: $HOSTNAME -> $INSTANCE_NAME"
fi

# Fallback if instance name is empty
if [ -z "$INSTANCE_NAME" ] || [ "$INSTANCE_NAME" = "unknown" ]; then
    INSTANCE_NAME="fallback-$$"
    debug_log "Using fallback name: $INSTANCE_NAME"
fi

# Use shared tmp storage for microk8s compatibility
TMUX_SOCKET="/tmp/shared/tmux-$INSTANCE_NAME/default"
debug_log "Using socket: $TMUX_SOCKET"

# Create directory with proper permissions in shared storage
mkdir -p "/tmp/shared/tmux-$INSTANCE_NAME"
chown op:op "/tmp/shared/tmux-$INSTANCE_NAME" 2>/dev/null || true
chmod 755 "/tmp/shared/tmux-$INSTANCE_NAME" 2>/dev/null || true

# Fallback to local tmp if shared storage not available
if [ ! -d "/tmp/shared" ]; then
    TMUX_SOCKET="/tmp/tmux-$INSTANCE_NAME/default"
    mkdir -p "/tmp/tmux-$INSTANCE_NAME"
    chown op:op "/tmp/tmux-$INSTANCE_NAME" 2>/dev/null || true
    chmod 755 "/tmp/tmux-$INSTANCE_NAME" 2>/dev/null || true
    debug_log "Fallback to local socket: $TMUX_SOCKET"
fi

# Execute real tmux with isolated socket
exec /usr/bin/tmux -S "$TMUX_SOCKET" "$@"