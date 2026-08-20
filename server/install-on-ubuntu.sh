#!/bin/bash
# Installs whisper.cpp as a transcription server on an Ubuntu machine.
# Run it once on the server:  bash install-on-ubuntu.sh
# After that the server runs permanently on port 8643 (systemd, starts at boot).
set -euo pipefail

MODEL="small"   # ~466 MB, a good compromise on CPU. Alternative: "large-v3-turbo-q5_0" (~574 MB, better quality, much slower)
PORT=8643       # 8642 is often taken by something else, so 8643 is the default here
INSTALL_DIR="$HOME/whisper-server"

echo "==> Installing packages"
sudo apt-get update
sudo apt-get install -y build-essential cmake git curl

echo "==> Cloning and building whisper.cpp"
if [ ! -d "$INSTALL_DIR/whisper.cpp" ]; then
  mkdir -p "$INSTALL_DIR"
  git clone https://github.com/ggml-org/whisper.cpp "$INSTALL_DIR/whisper.cpp"
fi
cd "$INSTALL_DIR/whisper.cpp"
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"

echo "==> Downloading the model ($MODEL)"
bash ./models/download-ggml-model.sh "$MODEL"

echo "==> Determining the bind address"
# Only listen on the Tailscale IP when Tailscale is running. Otherwise anyone on
# the LAN could use the server unauthenticated and send audio to it.
BIND_ADDR="0.0.0.0"
if command -v tailscale >/dev/null 2>&1; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  if [ -n "$TS_IP" ]; then
    BIND_ADDR="$TS_IP"
    echo "    Tailscale found, the server listens on $BIND_ADDR only (not on the whole LAN)."
  fi
fi
if [ "$BIND_ADDR" = "0.0.0.0" ]; then
  if [ "${ALLOW_LAN:-0}" = "1" ]; then
    echo "    WARNING: the server listens on ALL interfaces (ALLOW_LAN=1)."
    echo "    Anyone on the network can use it without a login. Lock it down, for example with:"
    echo "      sudo ufw allow from <mac-ip> to any port $PORT && sudo ufw enable"
  else
    echo "ERROR: no Tailscale found. The server would listen unauthenticated on the whole network." >&2
    echo "Either install Tailscale (https://tailscale.com/download) or allow it deliberately:" >&2
    echo "    ALLOW_LAN=1 bash install-on-ubuntu.sh" >&2
    exit 1
  fi
fi

echo "==> Setting up the systemd service"
sudo tee /etc/systemd/system/whisper-server.service > /dev/null <<EOF
[Unit]
Description=Whisper.cpp Transcription Server (Orbly)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR/whisper.cpp
ExecStart=$INSTALL_DIR/whisper.cpp/build/bin/whisper-server -m $INSTALL_DIR/whisper.cpp/models/ggml-$MODEL.bin --host $BIND_ADDR --port $PORT --inference-path /inference -t $(nproc)
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now whisper-server

if [ "$BIND_ADDR" != "0.0.0.0" ]; then
  IP="$BIND_ADDR"
else
  IP=$(hostname -I | awk '{print $1}')
fi
echo ""
echo "=================================================================="
echo "Done, the Whisper server is running."
echo "Enter this URL in Orbly (Settings -> own server):"
echo ""
echo "    http://$IP:$PORT/inference"
echo ""
echo "Check the status:  systemctl status whisper-server"
echo "Read the logs:     journalctl -u whisper-server -f"
echo "=================================================================="
