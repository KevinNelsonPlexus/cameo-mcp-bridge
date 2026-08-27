#!/bin/bash
# install.sh - Install the Cameo MCP Bridge
#
# Usage:
#   ./install.sh                    Secure install (default): TLS + shared-secret auth.
#   ./install.sh --allow-insecure   Explicitly authorize INSECURE plaintext mode (dev only).
#   ./install.sh --help             Show usage.
#
# What this installer does:
# - Ensures MagicDraw has been launched at least once so host settings/license state exist in ~/.magicdraw.
# - Builds the Java plugin (default: inside the MagicDraw Docker image; optional: local Java 17 build).
# - Installs plugin files into ~/.magicdraw/2024x/plugins/com.claude.cameo.bridge on the host machine.
# - Installs the Python MCP server as a user-global uv tool and registers it with Copilot CLI.
#
# Assumptions:
# - The user is on Linux with Docker available for container-based build/launch flow.
# - MagicDraw settings are persisted on the host at ~/.magicdraw (mounted into the container).
# - The MagicDraw Docker image contains the toolchain needed for plugin builds.
# - The user has permission to install user-level tools under ~/.local/bin.
#
# How it works:
# - Prompt-driven preflight: verify/guide first MagicDraw launch + automatic license-evidence check.
# - Plugin build: INSTALL_MODE=container-build (default) or INSTALL_MODE=local-build.
# - Plugin deploy: copy built plugin payload into host ~/.magicdraw/2024x plugin directory.
# - Security provisioning: generate a random secret + self-signed TLS keystore under
#   ~/.cameo-mcp-bridge. The Java plugin reads the keystore/secret directly from that
#   directory to serve HTTPS and enforce bearer-token auth. The Python MCP server never
#   reads that file -- it instead receives the same secret (as a bearer token) and the
#   server's public certificate (for TLS trust) via its own Copilot MCP registration env vars.
#   Security is fail-closed: without --allow-insecure, both the plugin and the MCP server
#   refuse to run at all if the shared secret / TLS material is missing or unusable.
# - Python setup: ensure uv exists, install/select Python, install cameo-mcp globally via uv tool.
# - Copilot registration: remove existing 'cameo-bridge' registration (if any), then register fresh
#   with CAMEO_BRIDGE_TOKEN / CAMEO_BRIDGE_CA_CERT env vars.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST_HOME="${HOME}"
DOCKER_DISPLAY="${DOCKER_DISPLAY:-${DISPLAY:-:0}}"
MAGICDRAW_IMAGE="${MAGICDRAW_IMAGE:-plexusna.jfrog.io/ep-oci-dev-local/plxs-pd/magicdraw:2024x-refresh2_1.2.0}"
INSTALL_MODE="${INSTALL_MODE:-container-build}"
CAMEO_HOME="${CAMEO_HOME:-/MagicDraw/AM_NM_LEG_MagicDraw.AllOS/1/no_install}"
MAGICDRAW_SETTINGS_HOME="${HOME}/.magicdraw"
CAMEO_PLUGIN_HOME="${CAMEO_PLUGIN_HOME:-${MAGICDRAW_SETTINGS_HOME}/2024x}"
UV_PYTHON_VERSION="${UV_PYTHON_VERSION:-3.11}"
CAMEO_BRIDGE_HOME="${CAMEO_BRIDGE_HOME:-${HOME}/.cameo-mcp-bridge}"
# TLS + bearer-token auth are enabled by default and are fail-closed: if the
# shared secret cannot be established, neither the plugin nor the MCP server
# will run. Pass --allow-insecure to explicitly authorize the plaintext,
# unauthenticated fallback (NOT recommended; local development only).
CAMEO_BRIDGE_ENABLE_TLS="${CAMEO_BRIDGE_ENABLE_TLS:-true}"

usage() {
    cat <<'EOF'
Usage: ./install.sh [OPTIONS]

Options:
  --allow-insecure   Explicitly authorize INSECURE plaintext mode. The bridge will
                     run without TLS and without shared-secret authentication, so
                     ANY local client can drive the open MagicDraw project.
                     Development only.
  -h, --help         Show this help and exit.

By default the installer provisions a random shared secret and a self-signed TLS
certificate. Only the plugin and MCP server provisioned by the same install run can
talk to each other, and both fail closed if that secret is missing or unusable.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --allow-insecure)
            CAMEO_BRIDGE_ENABLE_TLS="false"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown option '$1'"
            echo ""
            usage
            exit 1
            ;;
    esac
done

find_java17_home() {
    # Find a usable local Java 17 home for local Gradle builds.
    for candidate in "${JDK17_HOME:-}" "${JAVA17_HOME:-}" "${JAVA_HOME:-}"; do
        if [ -n "${candidate:-}" ] && [ -x "$candidate/bin/java" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

require_command() {
    # Fail fast when a required CLI dependency is missing.
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command '$cmd' was not found on PATH."
        exit 1
    fi
}

provision_bridge_security() {
    # Generate a random secret and a self-signed TLS keypair for the bridge.
    #
    # The Java plugin loads the keystore + secret directly from
    # CAMEO_BRIDGE_HOME at startup, serves HTTPS with it, and requires the
    # secret as a bearer token on every request. The Python MCP server never
    # reads this directory -- it is instead handed the same secret and the
    # public certificate through its own Copilot MCP registration env vars
    # (CAMEO_BRIDGE_TOKEN / CAMEO_BRIDGE_CA_CERT), so client and server never
    # share a single file at runtime.
    require_command openssl

    echo "Provisioning bridge TLS certificate and auth secret..."
    mkdir -p "$CAMEO_BRIDGE_HOME"
    chmod 700 "$CAMEO_BRIDGE_HOME"

    # Clear any marker left by a previous --allow-insecure install so this run
    # cannot be silently downgraded to plaintext.
    rm -f "$CAMEO_BRIDGE_HOME/allow-insecure"

    BRIDGE_TOKEN="$(openssl rand -hex 32)"

    local san_config key_path cert_path p12_path token_path
    san_config="$(mktemp)"
    key_path="$(mktemp)"
    cert_path="$CAMEO_BRIDGE_HOME/server.crt"
    p12_path="$CAMEO_BRIDGE_HOME/server.p12"
    token_path="$CAMEO_BRIDGE_HOME/token"

    cat > "$san_config" <<'EOF'
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = cameo-mcp-bridge-local

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
EOF

    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$key_path" -out "$cert_path" \
        -config "$san_config" -extensions v3_req >/dev/null 2>&1

    openssl pkcs12 -export \
        -inkey "$key_path" -in "$cert_path" \
        -name cameo-mcp-bridge -out "$p12_path" \
        -passout "pass:${BRIDGE_TOKEN}" >/dev/null 2>&1

    rm -f "$san_config" "$key_path"
    chmod 600 "$p12_path"

    printf '%s' "$BRIDGE_TOKEN" > "$token_path"
    chmod 600 "$token_path"
    chmod 644 "$cert_path"

    BRIDGE_CA_CERT="$cert_path"
    echo "Bridge secret + TLS keystore written to: $CAMEO_BRIDGE_HOME"
    echo ""
}

provision_insecure_mode() {
    # Record an explicit, on-disk authorization for plaintext mode.
    #
    # The plugin only ever runs unauthenticated when this marker (or an
    # equivalent env/system-property override) is present. Stale secret/TLS
    # material is removed so the previous secure pairing cannot linger and so
    # the two sides cannot disagree about which mode is in effect.
    echo "Recording explicit authorization for INSECURE plaintext mode..."
    mkdir -p "$CAMEO_BRIDGE_HOME"
    chmod 700 "$CAMEO_BRIDGE_HOME"
    rm -f "$CAMEO_BRIDGE_HOME/token" "$CAMEO_BRIDGE_HOME/server.p12" "$CAMEO_BRIDGE_HOME/server.crt"
    printf '%s\n' "Created by install.sh --allow-insecure. Delete this file and re-run install.sh to restore TLS + shared-secret auth." \
        > "$CAMEO_BRIDGE_HOME/allow-insecure"
    chmod 600 "$CAMEO_BRIDGE_HOME/allow-insecure"
    echo "Insecure-mode marker written to: $CAMEO_BRIDGE_HOME/allow-insecure"
    echo ""
}

prompt_yes_no() {
    # Ask an interactive yes/no question with a configurable default.
    local prompt="$1"
    local default="${2:-N}"
    local answer
    local hint="[y/N]"

    if [ "$default" = "Y" ]; then
        hint="[Y/n]"
    fi

    while true; do
        read -r -p "$prompt $hint " answer
        if [ -z "$answer" ]; then
            answer="$default"
        fi

        case "$answer" in
            y|Y|yes|YES)
                return 0
                ;;
            n|N|no|NO)
                return 1
                ;;
            *)
                echo "Please answer 'y' or 'n'."
                ;;
        esac
    done
}

has_magicdraw_license_evidence() {
    # Detect likely local MagicDraw license artifacts under ~/.magicdraw.
    if [ ! -d "${MAGICDRAW_SETTINGS_HOME}" ]; then
        return 1
    fi

    # In the containerized 2024x setup, presence of this persisted profile directory
    # indicates first-run state (including license/config) has been written locally.
    if [ -d "${MAGICDRAW_SETTINGS_HOME}/2024x" ]; then
        return 0
    fi

    if find "${MAGICDRAW_SETTINGS_HOME}" -maxdepth 6 -type f \
        \( -iname "*.lic" -o -iname "*license*" -o -iname "*licence*" -o -iname "*activation*" \) \
        | grep -q .; then
        return 0
    fi

    return 1
}

ensure_uv() {
    # Ensure uv is installed; optionally bootstrap it using Astral's installer.
    if command -v uv >/dev/null 2>&1; then
        return 0
    fi

    echo "uv is required to manage Python and virtual environments for MCP server install."
    if ! prompt_yes_no "Install uv now using: curl -LsSf https://astral.sh/uv/install.sh | sh ?" "Y"; then
        echo "Error: uv is required to continue."
        exit 1
    fi

    bash -lc "curl -LsSf https://astral.sh/uv/install.sh | sh"

    export PATH="${HOME}/.local/bin:${PATH}"
    if command -v uv >/dev/null 2>&1; then
        return 0
    fi

    echo "Error: uv installation completed but 'uv' is not on PATH."
    echo "Please add \$HOME/.local/bin to PATH and rerun the installer."
    exit 1
}

launch_magicdraw_container() {
    # Launch MagicDraw container with host mounts so ~/.magicdraw is persisted locally.
    require_command docker
    echo ""
    echo "Launching MagicDraw container..."
    docker run --name magicdraw --rm -ti \
        -e DISPLAY="${DOCKER_DISPLAY}" \
        -e HOME="${HOST_HOME}" \
        -v "${HOST_HOME}:${HOST_HOME}" \
        -v "${HOST_HOME}/.magicdraw:/root/.magicdraw" \
        -v /tmp/.X11-unix:/tmp/.X11-unix \
        --ipc=host \
        "${MAGICDRAW_IMAGE}"
}

ensure_magicdraw_profile_dir() {
    # Guarantee ~/.magicdraw exists and license setup has been completed before plugin install.
    echo "MagicDraw must be launched at least once so license/configuration are stored on the host."
    echo "Expected settings directory: ${MAGICDRAW_SETTINGS_HOME}"
    echo "Plugin install directory: ${CAMEO_PLUGIN_HOME}"
    echo ""
    echo "If this is your first run, complete these steps inside MagicDraw:"
    echo "  1. Acquire/activate your license"
    echo "  2. Accept 'Use Default' when prompted for Import Configuration"
    echo "  3. Exit MagicDraw cleanly"
    echo ""

    if [ ! -d "${MAGICDRAW_SETTINGS_HOME}" ]; then
        if prompt_yes_no "Launch MagicDraw container now using ${MAGICDRAW_IMAGE}?" "Y"; then
            launch_magicdraw_container
        else
            echo "Please launch MagicDraw manually and then rerun this installer."
            exit 1
        fi
    fi

    if [ ! -d "${MAGICDRAW_SETTINGS_HOME}" ]; then
        echo "Error: ${MAGICDRAW_SETTINGS_HOME} was not created."
        echo "Launch MagicDraw once, complete license/configuration, and rerun installer."
        exit 1
    fi

    if [ ! -w "${MAGICDRAW_SETTINGS_HOME}" ]; then
        echo "Error: ${MAGICDRAW_SETTINGS_HOME} is not writable by user $(id -un)."
        echo "This commonly happens when Docker created files as root."
        echo "Fix ownership and rerun:"
        echo "  sudo chown -R $(id -u):$(id -g) \"${MAGICDRAW_SETTINGS_HOME}\""
        exit 1
    fi

    if has_magicdraw_license_evidence; then
        echo "Detected MagicDraw license evidence in ${MAGICDRAW_SETTINGS_HOME}."
        return 0
    fi

    echo "No license evidence was found under ${MAGICDRAW_SETTINGS_HOME}."
    echo "You need to launch MagicDraw and complete license activation."
    if prompt_yes_no "Launch MagicDraw container now to acquire/refresh the license?" "Y"; then
        launch_magicdraw_container
    else
        echo "Please launch MagicDraw, acquire the license, and rerun installer."
        exit 1
    fi

    if ! has_magicdraw_license_evidence; then
        echo "Error: license evidence is still not present under ${MAGICDRAW_SETTINGS_HOME}."
        echo "Complete license activation in MagicDraw and rerun installer."
        exit 1
    fi
}

build_java_plugin_local() {
    # Build plugin locally using host Java 17 when INSTALL_MODE=local-build.
    if GRADLE_JAVA_HOME="$(find_java17_home)"; then
        echo "Using Java from: $GRADLE_JAVA_HOME"
        JAVA_HOME="$GRADLE_JAVA_HOME" PATH="$GRADLE_JAVA_HOME/bin:$PATH" \
            bash ./gradlew -Dorg.gradle.java.home="$GRADLE_JAVA_HOME" assemblePlugin -PcameoHome="$CAMEO_HOME"
        return 0
    fi

    echo "Error: Java was not found. Please install openjdk-17-jdk (sudo apt install openjdk-17-jdk),"
    echo "or run with INSTALL_MODE=container-build to build inside the MagicDraw Docker image."
    exit 1
}

build_java_plugin_in_container() {
    # Build plugin in the MagicDraw container using image-provided Java/toolchain.
    require_command docker
    docker run --rm -t \
        --entrypoint /bin/bash \
        -v "${SCRIPT_DIR}:${SCRIPT_DIR}" \
        -w "${SCRIPT_DIR}/plugin" \
        "${MAGICDRAW_IMAGE}" \
        -lc "set -euo pipefail; bash ./gradlew assemblePlugin -PcameoHome='${CAMEO_HOME}'"
}

echo "=== Cameo MCP Bridge Installer ==="
echo "CAMEO_HOME: $CAMEO_HOME"
echo "CAMEO_PLUGIN_HOME: $CAMEO_PLUGIN_HOME"
echo "INSTALL_MODE: $INSTALL_MODE"
echo "MAGICDRAW_IMAGE: $MAGICDRAW_IMAGE"
echo "UV_PYTHON_VERSION: $UV_PYTHON_VERSION"
echo "CAMEO_BRIDGE_ENABLE_TLS: $CAMEO_BRIDGE_ENABLE_TLS"
echo ""

ensure_magicdraw_profile_dir

# Generate the random secret + self-signed TLS keystore used to secure the
# bridge (BRIDGE_TOKEN / BRIDGE_CA_CERT are set as side effects for later use).
# This is the default; set CAMEO_BRIDGE_ENABLE_TLS=false to opt out (dev only).
BRIDGE_TOKEN=""
BRIDGE_CA_CERT=""
if [ "$CAMEO_BRIDGE_ENABLE_TLS" = "true" ]; then
    provision_bridge_security
else
    echo "WARNING: --allow-insecure specified -- skipping TLS/auth provisioning."
    echo "The bridge will run in INSECURE plaintext mode with NO authentication,"
    echo "so any local client will be able to drive the open MagicDraw project."
    echo "This is not recommended outside local development."
    echo ""
    provision_insecure_mode
fi

# Build the Java plugin
echo "Building Java plugin..."
cd "$SCRIPT_DIR/plugin"
case "$INSTALL_MODE" in
    container-build)
        build_java_plugin_in_container
        ;;
    local-build)
        build_java_plugin_local
        ;;
    *)
        echo "Error: unsupported INSTALL_MODE '$INSTALL_MODE'. Use 'container-build' or 'local-build'."
        exit 1
        ;;
esac

PLUGIN_DIST_DIR="$SCRIPT_DIR/plugin/build/plugin-dist/com.claude.cameo.bridge"
if [ ! -d "$PLUGIN_DIST_DIR" ]; then
    echo "Error: plugin build output was not found at: $PLUGIN_DIST_DIR"
    echo "The plugin build did not complete successfully."
    exit 1
fi

echo "Build complete."
echo ""

# Deploy plugin into host-persisted MagicDraw plugin directory (~/.magicdraw/2024x/plugins/...).
echo "Deploying plugin to Cameo..."
mkdir -p "$CAMEO_PLUGIN_HOME/plugins/com.claude.cameo.bridge"
if [ ! -w "$CAMEO_PLUGIN_HOME" ]; then
    echo "Error: ${CAMEO_PLUGIN_HOME} is not writable by user $(id -un)."
    echo "Fix ownership and rerun:"
    echo "  sudo chown -R $(id -u):$(id -g) \"${MAGICDRAW_SETTINGS_HOME}\""
    exit 1
fi
cp -r build/plugin-dist/com.claude.cameo.bridge/* "$CAMEO_PLUGIN_HOME/plugins/com.claude.cameo.bridge/"
echo "Plugin deployed to: $CAMEO_PLUGIN_HOME/plugins/com.claude.cameo.bridge/"
echo ""

# Install Python MCP server globally for the current user via uv tool management.
echo "Installing Python MCP server..."
cd "$SCRIPT_DIR/mcp-server"
ensure_uv
uv python install "$UV_PYTHON_VERSION" --quiet
uv tool install --python "$UV_PYTHON_VERSION" --editable "$SCRIPT_DIR/mcp-server" --force

export PATH="${HOME}/.local/bin:${PATH}"
if ! command -v cameo-mcp >/dev/null 2>&1; then
    echo "Error: 'cameo-mcp' was not found after uv tool install."
    echo "Please ensure \$HOME/.local/bin is on PATH and rerun the installer."
    exit 1
fi
echo "Python server installed."
echo ""

# Register/refresh Copilot MCP entry so reruns are idempotent.
echo "Registering MCP server with Copilot..."
if command -v copilot >/dev/null 2>&1; then
    if copilot mcp list 2>/dev/null | grep -qE '(^|[[:space:]])cameo-bridge([[:space:]]|$)'; then
        echo "Existing Copilot MCP registration found for 'cameo-bridge'; removing it..."
        copilot mcp remove cameo-bridge
    fi
    if [ -n "$BRIDGE_TOKEN" ]; then
        copilot mcp add cameo-bridge \
            --env "CAMEO_BRIDGE_TOKEN=${BRIDGE_TOKEN}" \
            --env "CAMEO_BRIDGE_CA_CERT=${BRIDGE_CA_CERT}" \
            -- cameo-mcp
    else
        copilot mcp add cameo-bridge \
            --env "CAMEO_BRIDGE_ALLOW_INSECURE=true" \
            -- cameo-mcp
    fi
else
    echo "Copilot CLI not found. Register manually with:"
    if [ -n "$BRIDGE_TOKEN" ]; then
        echo "  copilot mcp add cameo-bridge --env CAMEO_BRIDGE_TOKEN=<token> --env CAMEO_BRIDGE_CA_CERT=<cert-path> -- cameo-mcp"
        echo "  (token: ${BRIDGE_TOKEN})"
        echo "  (cert:  ${BRIDGE_CA_CERT})"
    else
        echo "  copilot mcp add cameo-bridge --env CAMEO_BRIDGE_ALLOW_INSECURE=true -- cameo-mcp"
    fi
fi
echo ""
echo "=== Installation complete ==="
echo ""
echo "Next steps:"
echo "  1. Restart CATIA Magic"
echo "  2. Open a project"
echo "  3. Start a new Claude Code session"
echo "  4. Say: 'Check cameo status'"
