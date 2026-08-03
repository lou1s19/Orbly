#!/bin/bash
# Installiert whisper.cpp als Transkriptions-Server auf einem Ubuntu-Server.
# Einmal auf dem Server ausführen:  bash install-on-ubuntu.sh
# Danach läuft der Server dauerhaft auf Port 8643 (systemd, startet bei Boot mit).
set -euo pipefail

MODEL="small"   # ~466 MB, guter Kompromiss auf CPU. Alternativ: "large-v3-turbo-q5_0" (~574 MB, bessere Qualität, deutlich langsamer)
PORT=8643       # 8642 ist auf Louis' Server schon von einem anderen Dienst belegt
INSTALL_DIR="$HOME/whisper-server"

echo "==> Pakete installieren"
sudo apt-get update
sudo apt-get install -y build-essential cmake git curl

echo "==> whisper.cpp klonen & bauen"
if [ ! -d "$INSTALL_DIR/whisper.cpp" ]; then
  mkdir -p "$INSTALL_DIR"
  git clone https://github.com/ggml-org/whisper.cpp "$INSTALL_DIR/whisper.cpp"
fi
cd "$INSTALL_DIR/whisper.cpp"
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"

echo "==> Modell herunterladen ($MODEL)"
bash ./models/download-ggml-model.sh "$MODEL"

echo "==> Bind-Adresse bestimmen"
# Nur auf der Tailscale-IP lauschen, wenn Tailscale läuft - sonst kann jeder
# im LAN den Server unauthentifiziert nutzen und Audio hinschicken.
BIND_ADDR="0.0.0.0"
if command -v tailscale >/dev/null 2>&1; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  if [ -n "$TS_IP" ]; then
    BIND_ADDR="$TS_IP"
    echo "    Tailscale gefunden - Server lauscht nur auf $BIND_ADDR (nicht im ganzen LAN)."
  fi
fi
if [ "$BIND_ADDR" = "0.0.0.0" ]; then
  if [ "${ALLOW_LAN:-0}" = "1" ]; then
    echo "    WARNUNG: Server lauscht auf ALLEN Interfaces (ALLOW_LAN=1)."
    echo "    Jeder im Netz kann ihn ohne Anmeldung nutzen. Absichern z. B. mit:"
    echo "      sudo ufw allow from <Mac-IP> to any port $PORT && sudo ufw enable"
  else
    echo "FEHLER: Kein Tailscale gefunden. Der Server würde unauthentifiziert im ganzen Netz lauschen." >&2
    echo "Entweder Tailscale installieren (https://tailscale.com/download) oder bewusst freigeben:" >&2
    echo "    ALLOW_LAN=1 bash install-on-ubuntu.sh" >&2
    exit 1
  fi
fi

echo "==> systemd-Service einrichten"
sudo tee /etc/systemd/system/whisper-server.service > /dev/null <<EOF
[Unit]
Description=Whisper.cpp Transcription Server (FlowWhisper)
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
echo "Fertig! Der Whisper-Server läuft."
echo "Trage in FlowWhisper (Einstellungen -> Ubuntu-Server) diese URL ein:"
echo ""
echo "    http://$IP:$PORT/inference"
echo ""
echo "Status prüfen:   systemctl status whisper-server"
echo "Logs ansehen:    journalctl -u whisper-server -f"
echo "=================================================================="
