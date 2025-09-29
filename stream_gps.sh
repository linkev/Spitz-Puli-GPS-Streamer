#!/bin/sh

# GL.iNet Spitz/Puli GPS Streamer - Router Script
# Streams GPS data from GL-X3000/GL-XE3000 to remote server

# Configuration
SERVER_IP="${SERVER_IP:-192.168.8.1}"  # Replace with your server's IP address or domain name
SERVER_PORT="${SERVER_PORT:-9999}"
ENDPOINT="http://${SERVER_IP}:${SERVER_PORT}/gps"
BATCH_SIZE=10  # Number of NMEA sentences to batch before sending
RETRY_DELAY=5  # Seconds to wait before retry on failure

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [GL.iNet-GPS] $1" >&2
}

# Function to send GPS data batch
send_batch() {
    local batch="$1"
    if [ -z "$batch" ]; then
        return 0
    fi
    
    # Send data with timeout and retry logic
    if curl -s -m 10 -X POST \
        -H "Content-Type: text/plain" \
        -d "$batch" \
        "$ENDPOINT" >/dev/null 2>&1; then
        return 0
    else
        log "Failed to send batch, will retry..."
        return 1
    fi
}

# Function to analyze batch content for better logging
analyze_batch() {
    local batch="$1"
    local gga_count=0
    local rmc_count=0
    local gsv_count=0
    local vtg_count=0
    local gsa_count=0
    local other_count=0
    
    # Use a here-document to avoid subshell issues
    while IFS= read -r line; do
        case "$line" in
            \$GPGGA*) gga_count=$((gga_count + 1)) ;;
            \$GPRMC*) rmc_count=$((rmc_count + 1)) ;;
            \$GPGSV*) gsv_count=$((gsv_count + 1)) ;;
            \$GPVTG*) vtg_count=$((vtg_count + 1)) ;;
            \$GPGSA*) gsa_count=$((gsa_count + 1)) ;;
            \$GP*) other_count=$((other_count + 1)) ;;
        esac
    done << EOF
$batch
EOF
    
    # Create summary for logging
    local summary=""
    [ $gga_count -gt 0 ] && summary="${summary}GGA:$gga_count "
    [ $rmc_count -gt 0 ] && summary="${summary}RMC:$rmc_count "
    [ $gsv_count -gt 0 ] && summary="${summary}GSV:$gsv_count "
    [ $vtg_count -gt 0 ] && summary="${summary}VTG:$vtg_count "
    [ $gsa_count -gt 0 ] && summary="${summary}GSA:$gsa_count "
    [ $other_count -gt 0 ] && summary="${summary}OTHER:$other_count "
    
    echo "${summary:-EMPTY}"
}

# Main streaming loop
main() {
    log "Starting GPS stream to $ENDPOINT"
    log "Batch size: $BATCH_SIZE sentences"
    
    batch=""
    line_count=0
    total_sent=0
    
    # Continuously read GPS data
    cat /dev/mhi_LOOPBACK | while IFS= read -r line; do
        # Skip empty lines and validate NMEA format
        [ -z "$line" ] && continue
        
        # Basic NMEA validation - should start with $ and contain comma
        if ! echo "$line" | grep -q '^\$.*,'; then
            log "Skipping invalid NMEA line: ${line:0:30}..."
            continue
        fi
        
        # Add line to batch (use actual newlines, not literal \n)
        if [ -z "$batch" ]; then
            batch="$line"
        else
            batch="$batch
$line"
        fi
        
        line_count=$((line_count + 1))
        
        # Send batch when it reaches the desired size
        if [ $line_count -ge $BATCH_SIZE ]; then
            # Show sample of first sentence and analyze batch content
            first_sentence=$(echo "$batch" | head -1)
            batch_summary=$(analyze_batch "$batch")
            log "Sending batch of $line_count sentences [$batch_summary] (sample: ${first_sentence:0:40}...)"
            
            until send_batch "$batch"; do
                log "Retrying in $RETRY_DELAY seconds..."
                sleep $RETRY_DELAY
            done
            log "✅ Batch sent successfully"
            
            # Reset batch
            batch=""
            line_count=0
            total_sent=$((total_sent + BATCH_SIZE))
            
            # Log progress every 100 sentences
            if [ $((total_sent % 100)) -eq 0 ]; then
                log "📊 Total sentences sent: $total_sent"
            fi
        fi
    done
}

# Trap to handle graceful shutdown
trap 'log "Shutting down GPS stream..."; exit 0' INT TERM

# Check if curl is available
if ! command -v curl >/dev/null 2>&1; then
    log "ERROR: curl not found. Please install curl."
    exit 1
fi

# Test GPS device accessibility
if [ ! -r /dev/mhi_LOOPBACK ]; then
    log "ERROR: Cannot read from /dev/mhi_LOOPBACK. Check device permissions."
    exit 1
fi

# Start the main process
main