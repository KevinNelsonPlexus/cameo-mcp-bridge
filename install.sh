#!/bin/bash
# install.sh - Install the Cameo MCP Bridge
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
# - Python setup: ensure uv exists, install/select Python, install cameo-mcp globally via uv tool.
# - Copilot registration: remove existing 'cameo-bridge' registration (if any), then register fresh.
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
echo ""

ensure_magicdraw_profile_dir

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
    copilot mcp add cameo-bridge -- cameo-mcp
else
    echo "Copilot CLI not found. Register manually with:"
    echo "  copilot mcp add cameo-bridge -- cameo-mcp"
fi
echo ""
echo "=== Installation complete ==="
echo ""
echo "Next steps:"
echo "  1. Restart CATIA Magic"
echo "  2. Open a project"
echo "  3. Start a new Claude Code session"
echo "  4. Say: 'Check cameo status'"
