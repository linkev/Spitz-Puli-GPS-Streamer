#!/bin/sh

# GL.iNet GPS Streamer Installation and Management Script
# Usage: curl -sSL https://raw.githubusercontent.com/linkev/Spitz-Puli-GPS-Streamer/main/install.sh | sh
# Or: wget -qO- https://raw.githubusercontent.com/linkev/Spitz-Puli-GPS-Streamer/main/install.sh | sh

VERSION="1.0.0"
SCRIPT_DIR="/root/gps-streamer"
STREAM_SCRIPT="$SCRIPT_DIR/stream_gps.sh"
CONFIG_FILE="$SCRIPT_DIR/config"
SERVICE_NAME="gps-streamer"
INIT_SCRIPT="/etc/init.d/$SERVICE_NAME"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if we're running on a supported system
check_system() {
    if [ ! -f /etc/openwrt_release ]; then
        log_warning "This script is designed for OpenWrt systems (GL.iNet routers)"
        echo "Continuing anyway, but some features may not work..."
    fi
    
    # Check for required tools
    for tool in curl cat grep; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_error "Required tool '$tool' not found. Please install it first."
            exit 1
        fi
    done
}

# Create directory structure
create_directories() {
    log_info "Creating directory structure..."
    mkdir -p "$SCRIPT_DIR"
    mkdir -p "$SCRIPT_DIR/logs"
}

# Download the GPS streaming script
download_stream_script() {
    log_info "Downloading GPS streaming script..."
    
    # URL to the raw script on GitHub
    SCRIPT_URL="https://raw.githubusercontent.com/linkev/Spitz-Puli-GPS-Streamer/main/stream_gps.sh"
    
    if curl -sSL "$SCRIPT_URL" -o "$STREAM_SCRIPT"; then
        chmod +x "$STREAM_SCRIPT"
        log_success "GPS streaming script downloaded successfully"
    else
        log_error "Failed to download GPS streaming script"
        exit 1
    fi
}

# Get server configuration from user
configure_server() {
    echo
    log_info "=== GPS Streamer Configuration ==="
    echo
    
    # Get server IP
    while true; do
        echo -n "Enter your server IP address (where GPS data will be sent): "
        read -r server_ip
        
        if [ -z "$server_ip" ]; then
            log_warning "Please enter a valid IP address"
            continue
        fi
        
        # Basic IP validation
        if echo "$server_ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            break
        elif echo "$server_ip" | grep -qE '^[a-zA-Z0-9.-]+$'; then
            # Allow hostnames/domains
            break
        else
            log_warning "Please enter a valid IP address or hostname"
        fi
    done
    
    # Get server port (with default)
    echo -n "Enter server port [9999]: "
    read -r server_port
    server_port=${server_port:-9999}
    
    # Get batch size (with default)
    echo -n "Enter batch size (number of GPS sentences per transmission) [10]: "
    read -r batch_size
    batch_size=${batch_size:-10}
    
    # Save configuration
    cat > "$CONFIG_FILE" << EOF
# GPS Streamer Configuration
SERVER_IP="$server_ip"
SERVER_PORT="$server_port"
BATCH_SIZE="$batch_size"
RETRY_DELAY="5"
EOF
    
    log_success "Configuration saved to $CONFIG_FILE"
    echo
    echo "Configuration summary:"
    echo "  Server: $server_ip:$server_port"
    echo "  Batch size: $batch_size sentences"
    echo
}

# Create OpenWrt init script for service management
create_init_script() {
    log_info "Creating service management script..."
    
    cat > "$INIT_SCRIPT" << 'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

PROG_NAME="gps-streamer"
PROG_PATH="/root/gps-streamer/stream_gps.sh"
CONFIG_FILE="/root/gps-streamer/config"
PID_FILE="/var/run/gps-streamer.pid"
LOG_FILE="/root/gps-streamer/logs/stream.log"

start_service() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration file not found: $CONFIG_FILE"
        return 1
    fi
    
    if [ ! -x "$PROG_PATH" ]; then
        echo "GPS streamer script not found or not executable: $PROG_PATH"
        return 1
    fi
    
    # Source configuration
    . "$CONFIG_FILE"
    
    procd_open_instance
    procd_set_param command "$PROG_PATH"
    procd_set_param env SERVER_IP="$SERVER_IP" SERVER_PORT="$SERVER_PORT" BATCH_SIZE="$BATCH_SIZE" RETRY_DELAY="$RETRY_DELAY"
    procd_set_param pidfile "$PID_FILE"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-5}
    procd_close_instance
}

stop_service() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            rm -f "$PID_FILE"
        fi
    fi
    
    # Kill any remaining processes
    killall -q stream_gps.sh 2>/dev/null || true
}

reload_service() {
    stop
    start
}
EOF
    
    chmod +x "$INIT_SCRIPT"
    log_success "Service script created"
}

# Test GPS functionality
test_gps() {
    log_info "Testing GPS functionality..."
    
    if [ ! -r /dev/mhi_LOOPBACK ]; then
        log_warning "GPS device /dev/mhi_LOOPBACK not accessible"
        log_warning "Make sure GPS is enabled on your router's 5G modem"
        return 1
    fi
    
    log_info "Checking for GPS data (10 second test)..."
    if timeout 10 cat /dev/mhi_LOOPBACK | head -5 > /tmp/gps_test 2>/dev/null; then
        if [ -s /tmp/gps_test ]; then
            log_success "GPS data detected!"
            echo "Sample GPS data:"
            head -3 /tmp/gps_test | sed 's/^/  /'
        else
            log_warning "No GPS data received in 10 seconds"
            log_warning "GPS may not have a fix yet, or GPS is not properly enabled"
        fi
    else
        log_warning "Could not read GPS data"
    fi
    
    rm -f /tmp/gps_test
}

# Interactive management menu
show_menu() {
    echo
    log_info "=== GPS Streamer Management ==="
    echo
    echo "1) Start GPS streaming service"
    echo "2) Stop GPS streaming service"
    echo "3) Restart GPS streaming service"
    echo "4) Check service status"
    echo "5) View live GPS stream"
    echo "6) View service logs"
    echo "7) Edit configuration"
    echo "8) Test GPS functionality"
    echo "9) Enable auto-start on boot"
    echo "10) Disable auto-start on boot"
    echo "11) Uninstall GPS streamer"
    echo "0) Exit"
    echo
    echo -n "Choose an option [0-11]: "
}

# Service management functions
start_service() {
    log_info "Starting GPS streaming service..."
    if "$INIT_SCRIPT" start; then
        log_success "GPS streaming service started"
    else
        log_error "Failed to start GPS streaming service"
    fi
}

stop_service() {
    log_info "Stopping GPS streaming service..."
    if "$INIT_SCRIPT" stop; then
        log_success "GPS streaming service stopped"
    else
        log_error "Failed to stop GPS streaming service"
    fi
}

restart_service() {
    log_info "Restarting GPS streaming service..."
    "$INIT_SCRIPT" stop
    sleep 2
    "$INIT_SCRIPT" start
}

check_status() {
    log_info "Checking GPS streaming service status..."
    
    if [ -f /var/run/gps-streamer.pid ]; then
        local pid=$(cat /var/run/gps-streamer.pid)
        if kill -0 "$pid" 2>/dev/null; then
            log_success "GPS streaming service is running (PID: $pid)"
        else
            log_warning "PID file exists but process is not running"
        fi
    else
        log_warning "GPS streaming service is not running"
    fi
    
    # Check if process is running even without PID file
    if pgrep -f "stream_gps.sh" >/dev/null; then
        local pids=$(pgrep -f "stream_gps.sh" | tr '\n' ' ')
        log_info "Found stream_gps.sh processes: $pids"
    fi
}

view_live_stream() {
    log_info "Viewing live GPS stream (press Ctrl+C to stop)..."
    echo "Raw NMEA data from GPS:"
    echo "----------------------------------------"
    timeout 30 cat /dev/mhi_LOOPBACK || log_warning "No GPS data or timeout reached"
}

view_logs() {
    log_info "Recent GPS streamer logs:"
    echo "----------------------------------------"
    if [ -f "$SCRIPT_DIR/logs/stream.log" ]; then
        tail -50 "$SCRIPT_DIR/logs/stream.log"
    else
        log_warning "No log file found"
    fi
}

edit_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log_info "Current configuration:"
        cat "$CONFIG_FILE"
        echo
    fi
    configure_server
    log_info "Configuration updated. Restart the service to apply changes."
}

enable_autostart() {
    log_info "Enabling auto-start on boot..."
    "$INIT_SCRIPT" enable
    log_success "GPS streamer will now start automatically on boot"
}

disable_autostart() {
    log_info "Disabling auto-start on boot..."
    "$INIT_SCRIPT" disable
    log_success "GPS streamer auto-start disabled"
}

uninstall() {
    echo
    log_warning "This will completely remove the GPS streamer installation."
    echo -n "Are you sure? (y/N): "
    read -r confirm
    
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        log_info "Uninstalling GPS streamer..."
        
        # Stop and disable service
        "$INIT_SCRIPT" stop 2>/dev/null || true
        "$INIT_SCRIPT" disable 2>/dev/null || true
        
        # Remove files
        rm -rf "$SCRIPT_DIR"
        rm -f "$INIT_SCRIPT"
        
        log_success "GPS streamer uninstalled successfully"
        exit 0
    else
        log_info "Uninstall cancelled"
    fi
}

# Main installation function
install() {
    echo
    log_info "=== GL.iNet GPS Streamer Installer v$VERSION ==="
    echo
    
    check_system
    create_directories
    download_stream_script
    configure_server
    create_init_script
    test_gps
    
    echo
    log_success "Installation completed successfully!"
    echo
    log_info "You can now manage the GPS streamer using:"
    echo "  $0 menu"
    echo
    log_info "Or use individual commands:"
    echo "  $0 start    - Start the GPS streaming service"
    echo "  $0 stop     - Stop the GPS streaming service"
    echo "  $0 status   - Check service status"
    echo
}

# Main script logic
case "$1" in
    install|"")
        install
        ;;
    menu)
        while true; do
            show_menu
            read -r choice
            case $choice in
                1) start_service ;;
                2) stop_service ;;
                3) restart_service ;;
                4) check_status ;;
                5) view_live_stream ;;
                6) view_logs ;;
                7) edit_config ;;
                8) test_gps ;;
                9) enable_autostart ;;
                10) disable_autostart ;;
                11) uninstall ;;
                0) log_info "Goodbye!"; exit 0 ;;
                *) log_warning "Invalid option. Please choose 0-11." ;;
            esac
            echo
            echo -n "Press Enter to continue..."
            read -r
        done
        ;;
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        restart_service
        ;;
    status)
        check_status
        ;;
    config)
        edit_config
        ;;
    test)
        test_gps
        ;;
    uninstall)
        uninstall
        ;;
    *)
        echo "Usage: $0 [install|menu|start|stop|restart|status|config|test|uninstall]"
        echo
        echo "Commands:"
        echo "  install   - Install GPS streamer (default if no command given)"
        echo "  menu      - Interactive management menu"
        echo "  start     - Start GPS streaming service"
        echo "  stop      - Stop GPS streaming service"
        echo "  restart   - Restart GPS streaming service"
        echo "  status    - Check service status"
        echo "  config    - Edit configuration"
        echo "  test      - Test GPS functionality"
        echo "  uninstall - Remove GPS streamer completely"
        exit 1
        ;;
esac