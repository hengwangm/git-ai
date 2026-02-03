#!/usr/bin/env bash
#
# CodeBuddy + git-ai Integration Installer
#
# This script installs the git-ai hooks for CodeBuddy to enable
# AI code attribution tracking.
#
# Usage:
#   ./install-codebuddy-hooks.sh                 # Install to current project
#   ./install-codebuddy-hooks.sh -p /path/to/project
#   ./install-codebuddy-hooks.sh --global        # Install hook script globally
#   ./install-codebuddy-hooks.sh --uninstall     # Uninstall
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/codebuddy-git-ai-hook.js"

# Global install location
GLOBAL_HOOK_DIR="$HOME/.config/git-ai"
GLOBAL_HOOK_SCRIPT="$GLOBAL_HOOK_DIR/codebuddy-git-ai-hook.js"

# Default values
PROJECT_DIR=""
UNINSTALL=false
GLOBAL_INSTALL=false

print_help() {
    cat << EOF
CodeBuddy + git-ai Integration Installer

Usage:
    $0 [OPTIONS]

Options:
    -p, --project DIR    Project directory (default: current directory)
    -g, --global         Install hook script globally (~/.config/git-ai/)
    -u, --uninstall      Remove the hooks
    -h, --help           Show this help message

Examples:
    # Install to current project
    $0

    # Install to a specific project
    $0 -p /path/to/project

    # Install hook script globally and configure current project
    $0 --global

    # Uninstall from current project
    $0 --uninstall
EOF
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependencies() {
    # Check Node.js
    if ! command -v node &> /dev/null; then
        log_error "Node.js is not installed. Please install Node.js v16 or later."
        exit 1
    fi
    
    # Check git-ai
    if ! command -v git-ai &> /dev/null; then
        # Try common locations
        if [[ -x "$HOME/.git-ai/bin/git-ai" ]]; then
            log_info "Found git-ai at ~/.git-ai/bin/git-ai"
        else
            log_warn "git-ai is not in PATH. The hook will try to find it automatically."
            log_warn "Install git-ai: curl -sSL https://usegitai.com/install.sh | bash"
        fi
    else
        log_info "Found git-ai: $(which git-ai)"
    fi
}

install_global_hook() {
    log_info "Installing hook script globally to $GLOBAL_HOOK_DIR"
    
    mkdir -p "$GLOBAL_HOOK_DIR"
    
    if [[ -f "$HOOK_SCRIPT" ]]; then
        cp "$HOOK_SCRIPT" "$GLOBAL_HOOK_SCRIPT"
        chmod +x "$GLOBAL_HOOK_SCRIPT"
        log_success "Hook script installed to $GLOBAL_HOOK_SCRIPT"
    else
        log_error "Hook script not found: $HOOK_SCRIPT"
        exit 1
    fi
}

get_hook_command() {
    if [[ "$GLOBAL_INSTALL" == "true" ]] || [[ -f "$GLOBAL_HOOK_SCRIPT" ]]; then
        echo "node $GLOBAL_HOOK_SCRIPT"
    else
        echo "node $HOOK_SCRIPT"
    fi
}

install_project_hooks() {
    local project="$1"
    local settings_dir="$project/.codebuddy"
    local settings_file="$settings_dir/settings.json"
    local hook_cmd
    hook_cmd=$(get_hook_command)
    
    log_info "Installing hooks to project: $project"
    
    # Create .codebuddy directory if it doesn't exist
    mkdir -p "$settings_dir"
    
    # Create or update settings.json
    local new_config
    new_config=$(cat << EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "replace_in_file|write_to_file|create_file",
        "hooks": [
          {
            "type": "command",
            "command": "$hook_cmd",
            "timeout": 30
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "replace_in_file|write_to_file|create_file",
        "hooks": [
          {
            "type": "command",
            "command": "$hook_cmd",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
EOF
)
    
    if [[ -f "$settings_file" ]]; then
        log_warn "Existing settings.json found, backing up to settings.json.bak"
        cp "$settings_file" "$settings_file.bak"
    fi
    
    echo "$new_config" > "$settings_file"
    log_success "Created $settings_file"
}

uninstall_project_hooks() {
    local project="$1"
    local settings_file="$project/.codebuddy/settings.json"
    
    log_info "Uninstalling hooks from project: $project"
    
    if [[ -f "$settings_file" ]]; then
        # Check if backup exists
        if [[ -f "$settings_file.bak" ]]; then
            mv "$settings_file.bak" "$settings_file"
            log_success "Restored settings.json from backup"
        else
            rm "$settings_file"
            log_success "Removed settings.json"
        fi
    else
        log_warn "No settings.json found in $project/.codebuddy/"
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--project)
            PROJECT_DIR="$2"
            shift 2
            ;;
        -g|--global)
            GLOBAL_INSTALL=true
            shift
            ;;
        -u|--uninstall)
            UNINSTALL=true
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            print_help
            exit 1
            ;;
    esac
done

# Set default project directory
if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(pwd)"
fi

# Validate project directory
if [[ ! -d "$PROJECT_DIR" ]]; then
    log_error "Project directory does not exist: $PROJECT_DIR"
    exit 1
fi

# Check if it's a git repository
if ! git -C "$PROJECT_DIR" rev-parse --git-dir &> /dev/null; then
    log_warn "Not a git repository: $PROJECT_DIR"
    log_warn "git-ai features will not work until you initialize a git repository"
fi

# Main logic
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║    CodeBuddy + git-ai Integration Installer          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

check_dependencies

if [[ "$UNINSTALL" == "true" ]]; then
    uninstall_project_hooks "$PROJECT_DIR"
    log_success "Uninstallation complete!"
else
    if [[ "$GLOBAL_INSTALL" == "true" ]]; then
        install_global_hook
    fi
    
    install_project_hooks "$PROJECT_DIR"
    
    echo ""
    log_success "Installation complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Restart CodeBuddy IDE"
    echo "  2. Edit a file using CodeBuddy AI"
    echo "  3. Check attribution: git-ai status"
    echo ""
    echo "To enable debug logging:"
    echo "  export CODEBUDDY_GIT_AI_DEBUG=1"
    echo ""
fi
