#!/bin/bash

# =========================================================================
#  Copyright (c) 2026 Wayne M. Thornton (wmthornton-dev@outlook.com)
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions
#  are met:
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#
#  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
#  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
#  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
#  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
#  OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
#  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
#  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
#  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
#  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
#  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# =========================================================================

# ================= CONFIGURATION =================
OBS_HOST="localhost"
OBS_PORT="4455"
# If your OBS setup requires a password, enter that here
# otherwise leave blank
OBS_PASS=""
SINK_NAME="Meeting_Recorder"
SINK_DESC="Discord_Meeting_Recorder"
OBS_SCENE="Discord_Meeting"

# ================= ARGUMENT PARSING =================
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -h, --host <HOST>      OBS WebSocket Host"
    echo "  -P, --port <PORT>      OBS WebSocket Port"
    echo "  -p, --password <PASS>  OBS WebSocket Password"
    echo "  -n, --name <NAME>      Internal Sink Name"
    echo "  -s, --scene <SCENE>    OBS Scene to switch to"
    exit 1
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--host) OBS_HOST="$2"; shift ;;
        -P|--port) OBS_PORT="$2"; shift ;;
        -p|--password) OBS_PASS="$2"; shift ;;
        -n|--name) SINK_NAME="$2"; SINK_DESC="Discord_$2"; shift ;;
        -s|--scene) OBS_SCENE="$2"; shift ;;
        --help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# ================= AUDIO SETUP =================

NULL_SINK_ID=""
LOOPBACK_ID=""

cleanup_audio() {
    echo -e "\nCleaning up audio devices..."
    if [ ! -z "$LOOPBACK_ID" ]; then pactl unload-module "$LOOPBACK_ID" 2>/dev/null; fi
    if [ ! -z "$NULL_SINK_ID" ]; then pactl unload-module "$NULL_SINK_ID" 2>/dev/null; fi
    
    # SAFETY: Unmute all microphones on exit to avoid confusion later
    echo "Unmuting all microphones..."
    pactl list short sources | grep -v "\.monitor" | cut -f2 | xargs -I {} pactl set-source-mute "{}" 0
    echo "Done."
}

trap cleanup_audio EXIT

setup_audio() {
    echo "Checking Audio System..."
    if ! command -v pactl &> /dev/null; then echo "Error: 'pactl' not found."; exit 1; fi

    echo ">> Creating Virtual Sink ($SINK_DESC)..."
    NULL_SINK_ID=$(pactl load-module module-null-sink sink_name=$SINK_NAME sink_properties=device.description=$SINK_DESC)
    if [ -z "$NULL_SINK_ID" ]; then echo "Error: Failed to create virtual sink."; exit 1; fi

    echo ">> Creating Loopback..."
    LOOPBACK_ID=$(pactl load-module module-loopback source=$SINK_NAME.monitor)
}

# Toggles mute on ALL physical microphones found on the system
toggle_mic() {
    # Get list of all REAL sources (excluding monitors/virtual sinks)
    # grep -v ".monitor" to ignore internal audio loops
    MICS=$(pactl list short sources | grep -v "\.monitor" | cut -f2)

    # Toggle the specific DEFAULT source to determine target state
    DEFAULT_MIC=$(pactl get-default-source)
    pactl set-source-mute "$DEFAULT_MIC" toggle
    
    # Check the status of the default mic
    IS_MUTED=$(pactl get-source-mute "$DEFAULT_MIC" | awk '{print $2}')
    
    # Force that state onto ALL other mics (Sync them all)
    if [ "$IS_MUTED" == "yes" ]; then
        echo "$MICS" | xargs -I {} pactl set-source-mute "{}" 1
        echo -e "\r\033[K🔴 SYSTEM MUTED (Discord sending SILENCE)"
    else
        echo "$MICS" | xargs -I {} pactl set-source-mute "{}" 0
        echo -e "\r\033[K🟢 SYSTEM LIVE"
    fi
}

# Python embedded function for OBS WebSocket v5 Authentication
# No other legit way to do this without sever access and/or violation
# of Discord TOS
obs_cmd() {
    REQUEST_TYPE="$1"
    python3 -c "
import sys, json, base64, hashlib, socket, os
host = '$OBS_HOST'; port = int('$OBS_PORT'); password = '$OBS_PASS'; request_type = '$REQUEST_TYPE'; request_data_str = os.environ.get('REQ_DATA', '{}')

def send_json(ws, data):
    msg = json.dumps(data)
    frame = bytearray(); frame.append(0x81)
    length = len(msg)
    if length <= 125: frame.append(length | 0x80)
    elif length <= 65535: frame.append(126 | 0x80); frame.extend(length.to_bytes(2, 'big'))
    else: frame.append(127 | 0x80); frame.extend(length.to_bytes(8, 'big'))
    frame.extend(b'\x00\x00\x00\x00'); frame.extend(bytes(m ^ 0 for m in msg.encode('utf-8'))); ws.send(frame)

def recv_json(ws):
    head = ws.recv(2)
    if not head: return None
    length = head[1] & 127
    if length == 126: length = int.from_bytes(ws.recv(2), 'big')
    elif length == 127: length = int.from_bytes(ws.recv(8), 'big')
    payload = ws.recv(length); return json.loads(payload.decode('utf-8'))

try:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM); sock.connect((host, port))
    key = base64.b64encode(b'IsThisRandomEnough?').decode()
    handshake = (f'GET / HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n')
    sock.send(handshake.encode()); sock.recv(4096); hello = recv_json(sock)
    auth_data = None
    if 'authentication' in hello['d']:
        salt = hello['d']['authentication']['salt']; challenge = hello['d']['authentication']['challenge']
        secret = base64.b64encode(hashlib.sha256((password + salt).encode()).digest()).decode()
        auth_response = base64.b64encode(hashlib.sha256((secret + challenge).encode()).digest()).decode()
        auth_data = auth_response
    send_json(sock, {'op': 1, 'd': {'rpcVersion': 1, 'authentication': auth_data}}); recv_json(sock)
    req_payload = {'requestType': request_type, 'requestId': 'req'}; data_dict = json.loads(request_data_str)
    if data_dict: req_payload['requestData'] = data_dict
    send_json(sock, {'op': 6, 'd': req_payload})
    while True:
        msg = recv_json(sock)
        if msg['op'] == 7: sys.exit(0 if msg['d']['requestStatus']['result'] else 1)
except Exception: sys.exit(1)
"
}

# ================= MAIN EXECUTION =================

setup_audio

echo "--------------------------------------------------------"
echo "AUDIO SETUP COMPLETE"
echo "   1. Open Discord Settings -> Voice & Video"
echo "   2. Set OUTPUT DEVICE to: '$SINK_DESC'"
echo "--------------------------------------------------------"
echo "Press [ENTER] when ready..."
read -r

if ! pgrep -x "obs" > /dev/null; then echo "Error: OBS is not running."; exit 1; fi

echo "Connecting to OBS..."
export REQ_DATA="{\"sceneName\": \"$OBS_SCENE\"}"
obs_cmd "SetCurrentProgramScene"
unset REQ_DATA

obs_cmd "StartRecord"
if [ $? -eq 0 ]; then
    echo "OBS Recording STARTED."
    echo "---------------------------------"
    echo "   [m] Toggle Mute (MUTES ALL MICROPHONES)"
    echo "   [q] Stop Recording and Exit"
    echo "---------------------------------"
else
    echo "Failed to start recording."; exit 1
fi

while true; do
    read -n 1 -s key
    case "$key" in
        m|M)
            toggle_mic
            ;;
        q|Q)
            echo -e "\nStopping recording..."
            break
            ;;
    esac
done

obs_cmd "StopRecord"
echo "Recording Stopped."
