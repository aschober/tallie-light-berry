# Bash script to upload a Berry file to Tasmota device
#!/bin/bash
# Check if the correct number of arguments is provided
echo "Berry file upload to Tasmota device"
echo "========================================"
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <berry_file_path>"
    exit 1
fi

BERRY_FILE_PATH="$1"
# TASMOTA_IP="192.168.1.250"
TASMOTA_IP="10.193.168.131"
FILENAME=$(basename "$BERRY_FILE_PATH")

# .tapp files go into /.extensions/ so Tasmota loads them as Extensions.
# .be files upload to root /.
if [[ "$BERRY_FILE_PATH" == *.tapp ]]; then
    # Check if the disabled variant (trailing _) exists on the device —
    # if so, preserve that suffix so autorun state is unchanged.
    LISTING=$(curl -s "http://${TASMOTA_IP}/ufsd?download=/.extensions")
    if echo "$LISTING" | grep -q "${FILENAME}_"; then
        DEST_PATH="/.extensions/${FILENAME}_"
        echo "Found disabled extension (${FILENAME}_) — uploading with _ suffix"
    else
        DEST_PATH="/.extensions/${FILENAME}"
    fi
elif [[ "$BERRY_FILE_PATH" == *.be ]]; then
    DEST_PATH="/${FILENAME}"
else
    echo "Error: The file must have a .be or .tapp extension: $BERRY_FILE_PATH"
    exit 1
fi

echo "Tasmota IP:  $TASMOTA_IP"
echo "Local file:  $BERRY_FILE_PATH"
echo "Destination: $DEST_PATH"
echo ""
echo "Uploading to ${TASMOTA_IP}..."
echo ""

# If destination filename differs from source (e.g. trailing _ suffix),
# create a temp copy with the target name so Tasmota stores it correctly.
DEST_FILENAME=$(basename "$DEST_PATH")
UPLOAD_FILE="$BERRY_FILE_PATH"
TEMP_FILE=""
if [[ "$DEST_FILENAME" != "$FILENAME" ]]; then
    TEMP_FILE="$(dirname "$BERRY_FILE_PATH")/${DEST_FILENAME}"
    cp "$BERRY_FILE_PATH" "$TEMP_FILE"
    UPLOAD_FILE="$TEMP_FILE"
fi

DEST_DIR=$(dirname "$DEST_PATH")/
if curl --fail --output /dev/null -F "ufsu=@${UPLOAD_FILE}" "http://${TASMOTA_IP}/ufsu?filepath=${DEST_DIR}"; then
    [ -n "$TEMP_FILE" ] && rm -f "$TEMP_FILE"
    echo ""
    echo "Upload successful. Restarting Berry VM..."
    curl -s "http://${TASMOTA_IP}/cm?cmnd=BrRestart"
    echo ""
else
    [ -n "$TEMP_FILE" ] && rm -f "$TEMP_FILE"
    echo ""
    echo "Upload failed!"
fi
