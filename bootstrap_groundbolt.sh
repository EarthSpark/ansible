#!/usr/bin/env bash
set -euo pipefail

# GroundBolt one-liner bootstrapper
#
# Runs ON the target device. It resolves configuration into a durable inventory,
# downloads the Ansible playbook + templates (from a local web server or a git
# repo), then runs the playbook against localhost to provision the host.
#
# Run as root on the target. The script prompts for any secrets it doesn't
# already have, so the simplest invocation needs nothing else:
#
#   curl -fsSL http://<WEBSERVER>/bootstrap_groundbolt.sh \
#     | sudo bash -s -- --fileserver http://<WEBSERVER>
#
#   <WEBSERVER> is host:port of the machine serving this repo (see README.md).
#   Find it by running THIS on the serving machine (not the target):
#     macOS:  echo "http://$(ipconfig getifaddr en0):8000"
#     Linux:  echo "http://$(hostname -I | awk '{print $1}'):8000"
#
# Pulling from git instead of a web server (recommended: forward your SSH agent
# with `ssh -A` so the target authenticates to GitLab with your key, and use
# `sudo -E` so the forwarded SSH_AUTH_SOCK survives the sudo):
#
#   curl -fsSL <RAW_SCRIPT_URL> \
#     | sudo -E bash -s -- --repo git@gitlab.com:sparkmeter/earthspark/ansible.git --ref main
#
# Configuration & secrets:
# - Resolved into /etc/groundbolt/inventory.ini (mode 0600) and reused on every
#   later run. The first run prompts for the secrets (NETBIRD_SETUP_KEY,
#   GHCR_REGISTRY_USER, GHCR_REGISTRY_TOKEN) and the per-device GATEWAY_SERIAL;
#   VAULT_POSTGRES_PASSWORD is generated once and persisted.
# - Adding a new variable to INVENTORY_SPECS below makes the next run prompt for
#   just that one (the script is re-fetched each run, so the list is current).
# - Any value may be pre-seeded as an environment variable to skip the prompt
#   (export VAR=... and run with `sudo -E`). A value already in the inventory
#   wins over the environment; to change it, edit the file or delete the line.
# - FORCE_REPULL / RESET_DATABASE are per-run flags read from the environment
#   (default false); they are not persisted.
#
# Notes:
# - Installs Docker and the NetBird client, then deploys the docker-compose stack.
# - Ansible runs against localhost (local connection), not over SSH.

REPO_URL=""
REPO_REF="main"
FILESERVER_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_URL="$2"; shift 2;;
    --ref)
      REPO_REF="$2"; shift 2;;
    --fileserver)
      FILESERVER_URL="$2"; shift 2;;
    *)
      echo "Unknown argument: $1" >&2; exit 1;;
  esac
done

# Detect Ubuntu/Debian
if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script currently supports Debian/Ubuntu (apt-based) systems only." >&2
  exit 1
fi

# Ensure sudo
if [[ $EUID -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Installing sudo..."
    apt-get update -y && apt-get install -y sudo
  fi
  exec sudo -E bash "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Configuration: resolve into a durable, secret-bearing inventory.
#
# Each value resolves as: existing inventory value > environment variable >
# generated / default / interactive prompt. Done up front so the operator can
# answer prompts, then leave the rest unattended.
# ---------------------------------------------------------------------------
INVENTORY_FILE="/etc/groundbolt/inventory.ini"

# key:kind:default     kind = secret | plain | opt | autogen
INVENTORY_SPECS=(
  "GATEWAY_SERIAL:plain:"
  "FLASHER_SERIAL:opt:"
  "NETBIRD_SETUP_KEY:secret:"
  "NETBIRD_MANAGEMENT_URL:opt:"
  "NETBIRD_UP_ARGS:opt:--allow-server-ssh"
  "SYMMETRICDS_TAG:opt:3.7.38.0"
  "SPARKMETER_TAG:opt:2.0-dev.2"
  "SPARKNET_HTTP_TAG:opt:0.9.9"
  "VAULT_POSTGRES_PASSWORD:autogen:"
  "GHCR_REGISTRY_USER:plain:"
  "GHCR_REGISTRY_TOKEN:secret:"
)

inv_get() {
  # Print the stored value of $1 from the existing inventory, or nothing.
  [[ -f "$INVENTORY_FILE" ]] || return 0
  local line
  line="$(grep -m1 "^$1=" "$INVENTORY_FILE" || true)"
  printf '%s' "${line#*=}"
}

prompt_tty() {
  # $1 = label, $2 = 1 for hidden (secret). Echoes the entered value to stdout.
  # Reads from /dev/tty so it works under `curl ... | bash` (stdin is the pipe).
  local label="$1" secret="${2:-0}" val=""
  [[ -e /dev/tty ]] || return 0
  printf '%s' "$label" > /dev/tty
  if [[ "$secret" == "1" ]]; then
    IFS= read -r -s val < /dev/tty || true
    printf '\n' > /dev/tty
  else
    IFS= read -r val < /dev/tty || true
  fi
  printf '%s' "$val"
}

resolve_inventory() {
  RESOLVED_KEYS=(); RESOLVED_VALS=()
  local spec key kind def val
  for spec in "${INVENTORY_SPECS[@]}"; do
    key="${spec%%:*}"
    kind="${spec#*:}"; def="${kind#*:}"; kind="${kind%%:*}"
    val="$(inv_get "$key")"                          # 1. reuse persisted value
    if [[ -z "$val" ]]; then val="${!key:-}"; fi     # 2. environment
    if [[ -z "$val" ]]; then                         # 3. generate / default / prompt
      case "$kind" in
        autogen) val="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)";;
        opt)     val="$def";;
        secret)  val="$(prompt_tty "Enter $key (hidden, blank to skip): " 1)";;
        plain)   val="$(prompt_tty "Enter $key: " 0)";;
      esac
    fi
    RESOLVED_KEYS+=("$key"); RESOLVED_VALS+=("$val")
  done
}

write_inventory() {
  mkdir -p "$(dirname "$INVENTORY_FILE")"
  local i
  ( umask 077
    {
      echo "[groundbolt]"
      echo "localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3"
      echo ""
      echo "[groundbolt:vars]"
      for i in "${!RESOLVED_KEYS[@]}"; do
        printf '%s=%s\n' "${RESOLVED_KEYS[$i]}" "${RESOLVED_VALS[$i]}"
      done
    } > "$INVENTORY_FILE"
  )
  chmod 600 "$INVENTORY_FILE"
}

echo "Resolving configuration into $INVENTORY_FILE ..."
resolve_inventory
write_inventory

if [[ -z "$(inv_get NETBIRD_SETUP_KEY)" ]]; then
  echo "WARNING: NETBIRD_SETUP_KEY is empty. NetBird will not register unless this peer is already logged in." >&2
fi

if [[ -z "$(inv_get GHCR_REGISTRY_USER)" || -z "$(inv_get GHCR_REGISTRY_TOKEN)" ]]; then
  echo "WARNING: GHCR_REGISTRY_USER/GHCR_REGISTRY_TOKEN is empty. The ghcr.io docker login and image pulls will fail without GHCR credentials." >&2
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates gnupg lsb-release git python3 python3-pip python3-venv

# Create a working dir
WORKDIR="/opt/groundbolt-setup"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Function: download required files from a simple HTTP file server
fetch_from_fileserver() {
  local base_url="$1"
  echo "Fetching Ansible files from $base_url ..."
  # List of required files relative to the server root (served from the repo dir)
  local files=(
    "playbook.yml"
    "templates/docker-compose.yml.j2"
    "templates/compose.d/prod-symmetricds.env.j2"
    "templates/udev/98-usb-serial.rules.j2"
    "templates/wifi/hostapd.conf.j2"
    "templates/wifi/dhcpd.conf.j2"
  )
  for rel in "${files[@]}"; do
    mkdir -p "$(dirname "$rel")"
    echo " - $rel"
    curl -fsSL "$base_url/$rel" -o "$rel"
  done
}

# Obtain the playbook + templates: clone the repo (durable, refreshed on re-run)
# or download from a file server.
PLAYBOOK_PATH="playbook.yml"
REPO_DIR="${WORKDIR}/repo"
if [[ -n "$REPO_URL" ]]; then
  if [[ -d "$REPO_DIR/.git" ]]; then
    echo "Refreshing existing checkout in $REPO_DIR ..."
    git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
    git -C "$REPO_DIR" fetch --depth=1 origin "$REPO_REF"
    git -C "$REPO_DIR" checkout -f FETCH_HEAD
  else
    rm -rf "$REPO_DIR"
    echo "Cloning $REPO_URL@$REPO_REF into $REPO_DIR ..."
    git clone --depth=1 --branch "$REPO_REF" "$REPO_URL" "$REPO_DIR"
  fi
  cd "$REPO_DIR"
elif [[ -n "$FILESERVER_URL" ]]; then
  fetch_from_fileserver "$FILESERVER_URL" || {
    echo "Failed to download files from $FILESERVER_URL" >&2
    exit 1
  }
else
  cat >&2 <<'EOM'
ERROR: no file source given. Pass one of:
  --fileserver http://<WEBSERVER>   (a web server serving this repo; see README.md)
  --repo <REPO_URL> [--ref <BRANCH>]

To find the URL of your web server, run THIS on the machine serving the files:
  macOS:  echo "http://$(ipconfig getifaddr en0):8000"
  Linux:  echo "http://$(hostname -I | awk '{print $1}'):8000"
Then re-run with --fileserver <that-url>.
EOM
  exit 1
fi

if [[ ! -f "$PLAYBOOK_PATH" ]]; then
  echo "Could not find $PLAYBOOK_PATH. Provide --repo REPO_URL or a valid --fileserver BASE_URL." >&2
  exit 1
fi

# Install Ansible in a virtual environment (avoids PEP 668 issues)
VENV_DIR="${WORKDIR}/.venv"
if [[ ! -d "${VENV_DIR}" ]]; then
  echo "Creating Python virtualenv at ${VENV_DIR}..."
  python3 -m venv "${VENV_DIR}"
fi

"${VENV_DIR}/bin/pip" install --upgrade pip
"${VENV_DIR}/bin/pip" install "ansible>=8" "ansible-core>=2.15" "jmespath" \
  "docker" "jsonschema" "pyyaml"

# Install required Ansible collections (into venv context)
if ! "${VENV_DIR}/bin/ansible-galaxy" collection list 2>/dev/null | grep -q community.docker; then
  "${VENV_DIR}/bin/ansible-galaxy" collection install community.docker
fi

# Run the playbook. Per-run flags come from the environment (default false) via
# --extra-vars so they are not baked into the durable inventory.
ANSIBLE_STDOUT_CALLBACK=debug "${VENV_DIR}/bin/ansible-playbook" \
  -i "$INVENTORY_FILE" "$PLAYBOOK_PATH" \
  -e "FORCE_REPULL=${FORCE_REPULL:-false}" \
  -e "RESET_DATABASE=${RESET_DATABASE:-false}" || {
  echo "Playbook failed" >&2
  exit 1
}

echo ""
echo "GroundBolt setup complete."
echo "- Configuration persisted at ${INVENTORY_FILE}"
echo "- Docker services are deployed under /opt/groundbolt"
echo "- SymmetricDS env at /etc/compose.d/prod-symmetricds.env"

# NetBird state and the correct next step.
if command -v netbird >/dev/null 2>&1; then
  if netbird status 2>/dev/null | grep -qi 'Management:.*Connected'; then
    nb_ip="$(netbird status 2>/dev/null | awk -F': ' '/NetBird IP:/{print $2; exit}')"
    if [ -n "${nb_ip:-}" ]; then
      echo "- NetBird is up. This device's mesh address: ${nb_ip}"
    else
      echo "- NetBird is up (run 'netbird status' for the mesh address)."
    fi
  else
    nb_cmd="sudo netbird up"
    nb_mgmt="$(inv_get NETBIRD_MANAGEMENT_URL)"
    nb_args="$(inv_get NETBIRD_UP_ARGS)"
    if [ -n "$nb_mgmt" ]; then nb_cmd="$nb_cmd --management-url $nb_mgmt"; fi
    if [ -n "$nb_args" ]; then nb_cmd="$nb_cmd $nb_args"; fi
    echo "- NetBird is installed but NOT registered (no setup key was provided)."
    echo "  To enable remote access, run this on the device and open the login URL it prints:"
    echo "      ${nb_cmd}"
  fi
fi
echo "- Access the app on http://localhost/ (or over the NetBird mesh address above)"
