# Bash script to upload a Berry file to Tasmota device
#!/bin/bash
# Check if the correct number of arguments is provided
echo "Berry file upload to Tasmota device"
echo "========================================"
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <berry_file_path>"
    exit 1
fi
# Assign arguments to variables
BERRY_FILE_PATH="$1"
# TASMOTA_IP="192.168.1.250"
TASMOTA_IP="10.193.168.131"

echo "Tasmota IP: $TASMOTA_IP"
echo "File path: $BERRY_FILE_PATH"
echo ""
# Check if file ends with .be or .tapp extension
if [[ ! "$BERRY_FILE_PATH" == *.be && ! "$BERRY_FILE_PATH" == *.tapp ]]; then
    echo "Error: The file must have a .be or .tapp extension: $BERRY_FILE_PATH"
    exit 1
fi
echo "Uploading file to ${TASMOTA_IP}..."
echo ""
# Use curl to upload the file and return success or failure
if curl --fail --output /dev/null -F "ufsu=@${BERRY_FILE_PATH}" http://${TASMOTA_IP}/ufsu; then
    echo '\nBerry upload successful. Restarting Berry VM...'
    curl http://${TASMOTA_IP}/cm?cmnd=BrRestart
    echo "\n"
else
    echo '\nBerry upload failed!\n'
fi

