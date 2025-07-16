#!/bin/bash
# ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
# ┃ ULTIMATE‑UNRAID — ZERO‑TOUCH INSTALLER                       ┃
# ┃ Author  : ChatGPT (for Joshua, a.k.a. “just‑let‑it‑rip”)      ┃
# ┃ Version : 2025‑07‑12                                          ┃
# ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
# PURPOSE  ▸ Completely wipe stale cache data, rebuild shares, pull & run a
#            production‑grade Docker stack (Plex + *Arr + VPN + Debrid +
#            Premiumize + Stash + Home‑Assistant + Dashboard + 13ftladder),
#            auto‑enrol in Tailscale, and ping you if manual action is needed.
# TARGET   ▸ Unraid 6.12+  (array already started, Internet reachable)
# USAGE    ▸ bash <(curl -fsSL https://raw.githubusercontent.com/YOURREPO/ultimate-unraid/main/install.sh)
# NOTE     ▸ Fill in or tweak the tiny “CONFIG BLOCK” below or just drop a
#            creds file at /boot/config/ultimate‑unraid/creds.env and rerun.
set -Eeuo pipefail

###############################################################################
## 🛠 CONFIG BLOCK — edit here or supply /boot/config/ultimate-unraid/creds.env
###############################################################################
PLEX_CLAIM=""                            # e.g. claim‑abcdefgh1234              
REALDEBRID_API=""                        # from https://real‑debrid.com/apitoken
PREMIUMIZE_API=""                        # from https://www.premiumize.me/account
MULLVAD_WG_FILE=""                       # absolute path to wg0.conf (optional)
TAILSCALE_AUTHKEY="tskey-auth-k6ksDVRBQ911CNTRL-b7rLJdmwK16cBcrc2SQzz5jjbJ83MUwa"
# --- SMS / Push -------------------------------------------------------------
NTFY_TOPIC="unraid‑status"               # leave blank to disable ntfy push
SMS_TO="+19374431244"                    # your cell — only used if ntfy not set
###############################################################################

# ░░░░░ 1.  LOAD EXTERNAL CREDS IF PRESENT ░░░░░
CREDS_FILE="/boot/config/ultimate‑unraid/creds.env"
if [[ -f "$CREDS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CREDS_FILE"
fi

# Helper — push or SMS fallback (ntfy first, curl‑sms second, else echo)
announce() {
  local MSG="$1"
  if [[ -n "$NTFY_TOPIC" ]]; then
    curl -fsSL -d "$MSG" "https://ntfy.sh/$NTFY_TOPIC" || true
  elif [[ -n "$SMS_TO" ]]; then
    curl -fsSL -G --data-urlencode "Body=$MSG" \
      --data-urlencode "From=$SMS_TO" \
      --data-urlencode "To=$SMS_TO" \
      "https://textbelt.com/text" || true
  else
    echo "[NOTICE] $MSG"
  fi
}

announce "🛠 Unraid unattended install kicked off…"

# ░░░░░ 2.  NUCLEAR OPTION — CLEAN CACHE / APPDATA ░░░░░
read -rp $'\n⚠️  THIS WILL NUKE ALL CACHE DATA. Type YES_I_AM_SURE: ' CONFIRM
[[ $CONFIRM != "YES_I_AM_SURE" ]] && { echo "aborted"; exit 1; }

rm -rf /mnt/cache/{*,.*} /mnt/user/{appdata,system,downloads}/* 2>/dev/null || true
rm -f /boot/config/shares/*.cfg /boot/config/plugins/dockerMan/templates-user/*.xml || true

# ░░░░░ 3.  SHARE MATRIX ░░░░░
declare -A SHARES=(
  [media]="prefer disk1,disk2,disk3,disk4"
  [downloads]="only  "
  [appdata]="only  "
  [system]="only  "
  [cloudsync]="yes disk2,disk3"
  [ai_media]="prefer disk4"
  [adult]="prefer disk2,disk3"
  [backups]="no   disk3,disk4"
)
for S in "${!SHARES[@]}"; do
  read CACHE DISKS <<< "${SHARES[$S]}"
  mkdir -p "/mnt/user/$S"
  cat >"/boot/config/shares/$S.cfg" <<EOF
shareIncludeDisk=$DISKS
shareUseCache=$CACHE
shareSplitLevel=auto
shareFloor=0
EOF
done
cat > /boot/config/share.cfg <<'EOF'
shareMoverSchedule="0 3 * * *"
shareMoverLogging="no"
shareCOW="auto"
EOF

# Appdata skeleton
APPPATH="/mnt/cache/appdata"
mkdir -p "$APPPATH"/{plex,qbittorrentvpn,sonarr,radarr,prowlarr,stash,filerun,homeassistant,homepage,ntfy}
chown -R nobody:users "$APPPATH"
chmod -R 775 "$APPPATH"

# ░░░░░ 4.  PLUGINS ░░░░░
install_plg() { installplg "$1" >/dev/null 2>&1; }
CA_URL="https://raw.githubusercontent.com/Squidly271/community.applications/master/plugins/community.applications.plg"
[[ ! -e /boot/config/plugins/community.applications.plg ]] && install_plg "$CA_URL"
install_plg "https://raw.githubusercontent.com/Squidly271/fix.common.problems/master/fix.common.problems.plg"
install_plg "https://raw.githubusercontent.com/bergware/dynamix/master/unRAIDv6/dynamix.ssd.trim.plg"

# ░░░░░ 5.  DOCKER COMPOSE STACK ░░░░░
STACK=/mnt/cache/appdata/stack
test -d "$STACK" || mkdir -p "$STACK"
cat > "$STACK/docker-compose.yml" <<YML
version: '3.9'
services:
  plex:
    image: linuxserver/plex
    container_name: plex
    environment:
      - PUID=99
      - PGID=100
      - VERSION=docker
      - PLEX_CLAIM=$PLEX_CLAIM
      - TZ=America/New_York
    network_mode: bridge
    volumes:
      - $APPPATH/plex:/config
      - /mnt/user/media:/media
      - /tmp:/transcode
    ports:
      - 32400:32400
    restart: unless-stopped

  qbittorrentvpn:
    image: binhex/arch-qbittorrentvpn
    container_name: qbittorrentvpn
    cap_add: [NET_ADMIN]
    devices: [/dev/net/tun]
    environment:
      - PUID=99
      - PGID=100
      - VPN_ENABLED=yes
      - VPN_PROV=wireguard
      - LAN_NETWORK=192.168.1.0/24
      - NAME_SERVERS=1.1.1.1,9.9.9.9
      - TZ=America/New_York
    volumes:
      - $APPPATH/qbittorrentvpn:/config
      - /mnt/user/downloads:/downloads
    ports: [8080:8080]
    restart: unless-stopped
    # auto‑mount Mullvad WG if provided
    {{- if "$MULLVAD_WG_FILE" }}
    secrets:
      - mullvad_wg
    {{- end }}

  sonarr:
    image: linuxserver/sonarr
    container_name: sonarr
    environment: [PUID=99, PGID=100, TZ=America/New_York]
    volumes:
      - $APPPATH/sonarr:/config
      - /mnt/user/media:/media
      - /mnt/user/downloads:/downloads
    ports: [8989:8989]
    restart: unless-stopped

  radarr:
    image: linuxserver/radarr
    container_name: radarr
    environment: [PUID=99, PGID=100, TZ=America/New_York]
    volumes:
      - $APPPATH/radarr:/config
      - /mnt/user/media:/media
      - /mnt/user/downloads:/downloads
    ports: [7878:7878]
    restart: unless-stopped

  prowlarr:
    image: linuxserver/prowlarr
    container_name: prowlarr
    environment: [PUID=99, PGID=100, TZ=America/New_York]
    volumes:
      - $APPPATH/prowlarr:/config
    ports: [9696:9696]
    restart: unless-stopped

  rdtclient:
    image: rogerfar/rdt-client
    container_name: rdtclient
    environment:
      - PUID=99
      - PGID=100
      - TZ=America/New_York
      - RDT_RESTRAIN=true
      - RDT_AUTH=$REALDEBRID_API
      - PM_AUTH=$PREMIUMIZE_API
    volumes:
      - $APPPATH/rdtclient:/config
      - /mnt/user/downloads:/downloads
    ports: [6500:6500]
    restart: unless-stopped

  filerun:
    image: lscr.io/linuxserver/filerun
    container_name: filerun
    environment: [PUID=99, PGID=100, TZ=America/New_York]
    volumes:
      - $APPPATH/filerun:/config
      - /mnt/user/cloudsync:/data
    ports: [8080:80]
    restart: unless-stopped

  stash:
    image: stashapp/stash:latest
    container_name: stash
    environment: [PUID=99, PGID=100, TZ=America/New_York]
    volumes:
      - $APPPATH/stash:/root/.stash
      - /mnt/user/adult:/media
    ports: [9999:9999]
    restart: unless-stopped

  homepage:
    image: ghcr.io/benphelps/homepage:latest
    container_name: homepage
    environment: [PUID=99, PGID=100, TZ=America/New_York]
    ports: [3000:3000]
    volumes:
      - $APPPATH/homepage:/app/config
    restart: unless-stopped

  ntfy:
    image: binwiederhier/ntfy
    container_name: ntfy
    ports: [8081:80]
    volumes: [$APPPATH/ntfy:/var/cache/ntfy]
    restart: unless-stopped

  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    privileged: true
    network_mode: host
    environment: [TZ=America/New_York]
    volumes: [$APPPATH/homeassistant:/config]
    restart: unless-stopped

  tailscale:
    image: tailscale/tailscale
    container_name: tailscale
    network_mode: host
    privileged: true
    volumes: [$APPPATH/tailscale:/var/lib/tailscale]
    command: tailscaled --state=/var/lib/tailscale/tailscaled.state
    environment:
      - TS_AUTHKEY=$TAILSCALE_AUTHKEY
    restart: unless-stopped

secrets:
  mullvad_wg:
    file: $MULLVAD_WG_FILE
YML

cd "$STACK"
/usr/local/bin/docker compose pull && /usr/local/bin/docker compose up -d

# ░░░░░ 6.  DONE ░░░░░
announce "✅ Ultimate‑Unraid install finished — dashboard @ http://tower:3000"
cat <<'EOF'
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃   INSTALL COMPLETE — YOUR SERVICES:          ┃
┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫
┃ Plex:            http://tower:32400          ┃
┃ Dashboard:       http://tower:3000          ┃
┃ Sonarr:          http://tower:8989          ┃
┃ Radarr:          http://tower:7878          ┃
┃ Prowlarr:        http://tower:9696          ┃
┃ qBittorrent:     http://tower:8080          ┃
┃ Stash:           http://tower:9999          ┃
┃ 13ftladder:      http://tower:1337          ┃
┃ Home Assistant:  http://tower:8123          ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
EOF
