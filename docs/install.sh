#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Test after git-ai install-hooks

# ============================================================================
# CodeBuddy Support
# ============================================================================
# CodeBuddy 配置文件位置（优先级从高到低）：
#   1. 项目级: <workspace>/.codebuddy/settings.json
#   2. 用户级: ~/.codebuddy/settings.json
#
# 本脚本会在用户级配置中添加 git-ai hooks
# ============================================================================

# GitHub repository details
# Replaced during release builds with the actual repository (e.g., "git-ai-project/git-ai")
# When set to __REPO_PLACEHOLDER__, defaults to "git-ai-project/git-ai"
REPO="__REPO_PLACEHOLDER__"
if [ "$REPO" = "__REPO_PLACEHOLDER__" ]; then
    REPO="git-ai-project/git-ai"
fi

# Version placeholder - replaced during release builds with actual version (e.g., "v1.0.24")
# When set to __VERSION_PLACEHOLDER__, defaults to "latest"
PINNED_VERSION="__VERSION_PLACEHOLDER__"

# Embedded checksums - replaced during release builds with actual SHA256 checksums
# Format: "hash  filename|hash  filename|..." (pipe-separated)
# When set to __CHECKSUMS_PLACEHOLDER__, checksum verification is skipped
EMBEDDED_CHECKSUMS="__CHECKSUMS_PLACEHOLDER__"

# Function to print error messages
error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}Warning: $1${NC}" >&2
}

# Function to print success messages
success() {
    echo -e "${GREEN}$1${NC}"
}

# Function to verify checksum of downloaded binary
verify_checksum() {
    local file="$1"
    local binary_name="$2"

    # Skip verification if no checksums are embedded
    if [ "$EMBEDDED_CHECKSUMS" = "__CHECKSUMS_PLACEHOLDER__" ]; then
        return 0
    fi

    # Extract expected checksum for this binary
    local expected=""
    local old_ifs="$IFS"
    IFS='|' read -ra CHECKSUM_ENTRIES <<< "$EMBEDDED_CHECKSUMS"
    IFS="$old_ifs"
    for entry in "${CHECKSUM_ENTRIES[@]}"; do
        if [[ "$entry" =~ ^[[:xdigit:]]+[[:space:]]+$binary_name$ ]]; then
            expected=$(echo "$entry" | awk '{print $1}')
            break
        fi
    done

    if [ -z "$expected" ]; then
        error "No checksum found for $binary_name"
    fi

    # Calculate actual checksum
    local actual=""
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        warn "Neither sha256sum nor shasum available, skipping checksum verification"
        return 0
    fi

    if [ "$expected" != "$actual" ]; then
        rm -f "$file" 2>/dev/null || true
        error "Checksum verification failed for $binary_name\nExpected: $expected\nActual:   $actual"
    fi

    success "Checksum verified for $binary_name"
}

# Function to detect all shells with existing config files
# Returns shell configurations in format: "shell_name|config_file" (one per line)
detect_all_shells() {
    local shells=""
    
    # Check for bash configs (prefer .bashrc over .bash_profile)
    if [ -f "$HOME/.bashrc" ]; then
        shells="${shells}bash|$HOME/.bashrc\n"
    elif [ -f "$HOME/.bash_profile" ]; then
        shells="${shells}bash|$HOME/.bash_profile\n"
    fi
    
    # Check for zsh config
    if [ -f "$HOME/.zshrc" ]; then
        shells="${shells}zsh|$HOME/.zshrc\n"
    fi
    
    # Check for fish config
    if [ -f "$HOME/.config/fish/config.fish" ]; then
        shells="${shells}fish|$HOME/.config/fish/config.fish\n"
    fi
    
    # If no configs found, fall back to $SHELL detection and create config for that shell only
    if [ -z "$shells" ]; then
        local login_shell=""
        if [ -n "$SHELL" ]; then
            login_shell=$(basename "$SHELL")
        fi
        case "$login_shell" in
            fish)
                shells="fish|$HOME/.config/fish/config.fish"
                ;;
            zsh)
                shells="zsh|$HOME/.zshrc"
                ;;
            bash|*)
                shells="bash|$HOME/.bashrc"
                ;;
        esac
    fi
    
    # Remove trailing newline and output
    printf '%b' "$shells" | sed '/^$/d'
}

detect_std_git() {
    local git_path=""

    # Prefer the actual executable path, ignoring aliases and functions
    if git_path=$(type -P git 2>/dev/null); then
        :
    else
        git_path=$(command -v git 2>/dev/null || true)
    fi

    # Last resort
    if [ -z "$git_path" ]; then
        git_path=$(which git 2>/dev/null || true)
    fi

	# Ensure we never return a path for git that contains git-ai (recursive)
	if [ -n "$git_path" ] && [[ "$git_path" == *"git-ai"* ]]; then
		git_path=""
	fi

    # If detection failed or was our own shim, try to recover from saved config
    if [ -z "$git_path" ]; then
        local cfg_json="$HOME/.git-ai/config.json"
        if [ -f "$cfg_json" ]; then
            # Extract git_path value without jq
            local cfg_git_path
            cfg_git_path=$(sed -n 's/.*"git_path"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' "$cfg_json" | head -n1 || true)
            if [ -n "$cfg_git_path" ] && [[ "$cfg_git_path" != *"git-ai"* ]]; then
                if "$cfg_git_path" --version >/dev/null 2>&1; then
                    git_path="$cfg_git_path"
                fi
            fi
        fi
    fi

    # Try common system git paths as fallback (note: IFS is modified, so we loop explicitly)
    if [ -z "$git_path" ]; then
        for p in /usr/bin/git /usr/local/bin/git /opt/homebrew/bin/git; do
            if [ -x "$p" ] && "$p" --version >/dev/null 2>&1; then
                git_path="$p"
                break
            fi
        done
    fi

    # Fail if we couldn't find a standard git
    if [ -z "$git_path" ]; then
        error "Could not detect a standard git binary on PATH. Please ensure you have Git installed and available on your PATH. If you believe this is a bug with the installer, please file an issue at https://github.com/git-ai-project/git-ai/issues."
    fi

    # Verify detected git is usable
    if ! "$git_path" --version >/dev/null 2>&1; then
        error "Detected git at $git_path is not usable (--version failed). Please ensure you have Git installed and available on your PATH. If you believe this is a bug with the installer, please file an issue at https://github.com/git-ai-project/git-ai/issues."
    fi

    echo "$git_path"
}

# Detect standard git path (needed early for install)
STD_GIT_PATH=$(detect_std_git)

# Detect OS and architecture
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

# Map architecture to binary name
case $ARCH in
    "x86_64")
        ARCH="x64"
        ;;
    "aarch64"|"arm64")
        ARCH="arm64"
        ;;
    *)
        error "Unsupported architecture: $ARCH"
        ;;
esac

# Map OS to binary name
case $OS in
    "darwin")
        OS="macos"
        ;;
    "linux")
        OS="linux"
        ;;
    *)
        error "Unsupported operating system: $OS"
        ;;
esac

# Determine binary name
BINARY_NAME="git-ai-${OS}-${ARCH}"

# Determine release tag
# Priority: 1. Pinned version (for release builds), 2. Environment variable, 3. "latest"
if [ "$PINNED_VERSION" != "__VERSION_PLACEHOLDER__" ]; then
    # Version-pinned install script from a release
    RELEASE_TAG="$PINNED_VERSION"
    DOWNLOAD_URL="https://usegitai.com/worker/releases/download/${RELEASE_TAG}/${BINARY_NAME}"
elif [ -n "${GIT_AI_RELEASE_TAG:-}" ] && [ "${GIT_AI_RELEASE_TAG:-}" != "latest" ]; then
    # Environment variable override
    RELEASE_TAG="$GIT_AI_RELEASE_TAG"
    DOWNLOAD_URL="https://usegitai.com/worker/releases/download/${RELEASE_TAG}/${BINARY_NAME}"
else
    # Default to latest
    RELEASE_TAG="latest"
    DOWNLOAD_URL="https://usegitai.com/worker/releases/download/latest/${BINARY_NAME}"
fi

# Install into the user's bin directory ~/.git-ai/bin
INSTALL_DIR="$HOME/.git-ai/bin"

# Create directory if it doesn't exist
mkdir -p "$INSTALL_DIR"

# Download and install
echo "Downloading git-ai (release: ${RELEASE_TAG})..."
TMP_FILE="${INSTALL_DIR}/git-ai.tmp.$$"
if ! curl --fail --location --silent --show-error -o "$TMP_FILE" "$DOWNLOAD_URL"; then
    rm -f "$TMP_FILE" 2>/dev/null || true
    error "Failed to download binary (HTTP error)"
fi

# Basic validation: ensure file is not empty
if [ ! -s "$TMP_FILE" ]; then
    rm -f "$TMP_FILE" 2>/dev/null || true
    error "Downloaded file is empty"
fi

# Verify checksum if embedded (release builds only)
verify_checksum "$TMP_FILE" "$BINARY_NAME"

mv -f "$TMP_FILE" "${INSTALL_DIR}/git-ai"

# Make executable
chmod +x "${INSTALL_DIR}/git-ai"
# Symlink git to git-ai
ln -sf "${INSTALL_DIR}/git-ai" "${INSTALL_DIR}/git"

# Symlink git-og to the detected standard git path
ln -sf "$STD_GIT_PATH" "${INSTALL_DIR}/git-og"

# Remove quarantine attribute on macOS
if [ "$OS" = "macos" ]; then
    xattr -d com.apple.quarantine "${INSTALL_DIR}/git-ai" 2>/dev/null || true
fi

success "Successfully installed git-ai into ${INSTALL_DIR}"
success "You can now run 'git-ai' from your terminal"

# Print installed version
INSTALLED_VERSION=$(${INSTALL_DIR}/git-ai --version 2>&1 || echo "unknown")
echo "Installed git-ai ${INSTALLED_VERSION}"

# [DISABLED] Login functionality removed for internal deployment
# NEED_LOGIN=false
# if [ -n "${INSTALL_NONCE:-}" ] && [ -n "${API_BASE:-}" ]; then
#     if ! ${INSTALL_DIR}/git-ai exchange-nonce; then
#         NEED_LOGIN=true
#     fi
# fi

echo "Setting up IDE/agent hooks..."
if ! ${INSTALL_DIR}/git-ai install-hooks; then
    warn "Warning: Failed to set up IDE/agent hooks. Please try running 'git-ai install-hooks' manually."
else
    success "Successfully set up IDE/agent hooks"
fi

# ============================================================================
# CodeBuddy Configuration
# ============================================================================
# CodeBuddy 使用 settings.json 配置 hooks
# 配置文件位置优先级：
#   1. 项目级: <workspace>/.codebuddy/settings.json（用户手动配置）
#   2. 用户级: ~/.codebuddy/settings.json（本脚本自动配置）
#
# 由于 git-ai 目前不原生支持 CodeBuddy，使用 codebuddy-git-ai-hook.js 桥接
# ============================================================================

setup_codebuddy_hooks() {
    local codebuddy_dir="$HOME/.codebuddy"
    local settings_file="$codebuddy_dir/settings.json"
    local hook_script="$codebuddy_dir/codebuddy-git-ai-hook.js"
    
    # CodeBuddy hooks 配置
    # 注意：command 使用绝对路径，因为执行时工作目录是项目目录
    local codebuddy_hooks_config
    codebuddy_hooks_config=$(cat <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "replace_in_file|write_to_file|create_file",
        "hooks": [
          {
            "type": "command",
            "command": "${codebuddy_dir}/codebuddy-git-ai-hook.js",
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
            "command": "${codebuddy_dir}/codebuddy-git-ai-hook.js",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
EOF
)

    # codebuddy-git-ai-hook.js 脚本内容
    # 这个脚本负责调用 git-ai 记录 AI 归属信息
    local hook_script_content='#!/usr/bin/env node
/**
 * CodeBuddy Git-AI Hook
 * 
 * 这个脚本在 CodeBuddy 进行文件编辑时被调用
 * 负责调用 git-ai 记录 AI 代码归属信息
 * 
 * 配置位置优先级：
 *   1. 项目级: <workspace>/.codebuddy/settings.json
 *   2. 用户级: ~/.codebuddy/settings.json
 */

const { execSync, spawn } = require("child_process");
const path = require("path");
const fs = require("fs");

const DEBUG = process.env.CODEBUDDY_GIT_AI_DEBUG === "1";

function debug(...args) {
  if (DEBUG) {
    console.error("[codebuddy-git-ai-hook]", ...args);
  }
}

function findGitAi() {
  // 优先使用 ~/.git-ai/bin/git-ai
  const homeGitAi = path.join(
    process.env.HOME || process.env.USERPROFILE,
    ".git-ai",
    "bin",
    "git-ai"
  );
  if (fs.existsSync(homeGitAi)) {
    return homeGitAi;
  }

  // 尝试从 PATH 中找
  try {
    const result = execSync("which git-ai", { encoding: "utf8" }).trim();
    if (result) return result;
  } catch (e) {
    // ignore
  }

  return null;
}

async function main() {
  const gitAiPath = findGitAi();
  if (!gitAiPath) {
    debug("git-ai not found, skipping");
    return;
  }

  debug("Using git-ai at:", gitAiPath);

  // 读取 stdin（CodeBuddy 会传入 hook 数据）
  let stdinData = "";
  if (!process.stdin.isTTY) {
    stdinData = fs.readFileSync(0, "utf8");
    debug("stdin data:", stdinData.substring(0, 200));
  }

  // 调用 git-ai checkpoint
  // 使用 "codebuddy" 作为 agent 标识（如果 git-ai 不支持，会回退到通用处理）
  const args = ["checkpoint", "codebuddy", "--hook-input", "stdin"];
  
  debug("Calling:", gitAiPath, args.join(" "));

  const child = spawn(gitAiPath, args, {
    stdio: ["pipe", "inherit", "inherit"],
    env: {
      ...process.env,
      GIT_AI_AGENT: "codebuddy",
    },
  });

  if (stdinData) {
    child.stdin.write(stdinData);
    child.stdin.end();
  }

  child.on("close", (code) => {
    debug("git-ai exited with code:", code);
  });
}

main().catch((err) => {
  if (DEBUG) {
    console.error("[codebuddy-git-ai-hook] Error:", err);
  }
});
'

    # 创建 CodeBuddy 配置目录
    mkdir -p "$codebuddy_dir"
    
    # 写入 hook 脚本
    echo "$hook_script_content" > "$hook_script"
    chmod +x "$hook_script"
    success "  ✓ CodeBuddy hook script installed at $hook_script"
    
    # 检查是否已经配置
    if [ -f "$settings_file" ]; then
        # 检查是否已经包含 codebuddy-git-ai-hook
        if grep -q "codebuddy-git-ai-hook" "$settings_file" 2>/dev/null; then
            echo "  ✓ CodeBuddy hooks already configured in settings.json"
            return 0
        fi
        
        # 已有配置但没有 git-ai hooks，自动合并
        # 备份原配置
        local backup_file="$settings_file.backup.$(date +%Y%m%d%H%M%S)"
        cp "$settings_file" "$backup_file"
        echo "  → Backup created at $backup_file"
        
        # 使用 node 来合并 JSON（因为 jq 可能不存在）
        # 注意：HOOK_SCRIPT_PATH 通过环境变量传入，避免 shell 变量展开问题
        local merge_script='
const fs = require("fs");
const settingsFile = process.env.SETTINGS_FILE;
const hookScriptPath = process.env.HOOK_SCRIPT_PATH;
const existing = JSON.parse(fs.readFileSync(settingsFile, "utf8"));

// hooks 配置
const gitAiHook = {
  "matcher": "replace_in_file|write_to_file|create_file",
  "hooks": [
    {
      "type": "command",
      "command": hookScriptPath,
      "timeout": 30
    }
  ]
};

// 确保 hooks 对象存在
if (!existing.hooks) {
  existing.hooks = {};
}

// 追加 PreToolUse
if (!existing.hooks.PreToolUse) {
  existing.hooks.PreToolUse = [];
}
existing.hooks.PreToolUse.push(gitAiHook);

// 追加 PostToolUse
if (!existing.hooks.PostToolUse) {
  existing.hooks.PostToolUse = [];
}
existing.hooks.PostToolUse.push(gitAiHook);

fs.writeFileSync(settingsFile, JSON.stringify(existing, null, 2) + "\n");
console.log("OK");
'
        if SETTINGS_FILE="$settings_file" HOOK_SCRIPT_PATH="$hook_script" node -e "$merge_script" 2>/dev/null; then
            success "  ✓ CodeBuddy hooks merged into $settings_file"
            return 0
        else
            warn "Failed to merge hooks automatically"
            warn "Please manually add git-ai hooks to $settings_file"
            echo ""
            echo "Add the following hooks configuration:"
            echo "$codebuddy_hooks_config"
            return 1
        fi
    fi
    
    # 创建新的配置文件
    echo "$codebuddy_hooks_config" > "$settings_file"
    success "  ✓ CodeBuddy settings configured at $settings_file"
    return 0
}

echo ""
echo "Setting up CodeBuddy hooks..."
if setup_codebuddy_hooks; then
    success "Successfully set up CodeBuddy hooks"
else
    warn "CodeBuddy hooks need manual configuration"
fi

# Write JSON config at ~/.git-ai/config.json (always overwrite for internal deployment)
CONFIG_DIR="$HOME/.git-ai"
CONFIG_JSON_PATH="$CONFIG_DIR/config.json"
mkdir -p "$CONFIG_DIR"

TMP_CFG="$CONFIG_JSON_PATH.tmp.$$"
# ============================================================================
# Default configuration for internal deployment:
# - telemetry_oss: off          关闭 OSS telemetry (Sentry 错误上报)
# - disable_version_checks: true 关闭版本检查
# - disable_auto_updates: true   关闭自动更新
# - prompt_storage: notes        使用 git notes 存储 prompts（不依赖外部服务）
# ============================================================================
cat >"$TMP_CFG" <<EOF
{
  "git_path": "${STD_GIT_PATH}",
  "telemetry_oss": "off",
  "disable_version_checks": true,
  "disable_auto_updates": true,
  "prompt_storage": "notes"
}
EOF
mv -f "$TMP_CFG" "$CONFIG_JSON_PATH"
success "Config written at $CONFIG_JSON_PATH"

# Add to PATH in all detected shell configurations
SHELLS_CONFIGURED=""
SHELLS_ALREADY_CONFIGURED=""

while IFS='|' read -r shell_name config_file; do
    [ -z "$shell_name" ] && continue
    
    # Generate shell-appropriate PATH command
    if [ "$shell_name" = "fish" ]; then
        path_cmd="fish_add_path -g \"$INSTALL_DIR\""
        # Create fish config directory if it doesn't exist (for fallback case)
        mkdir -p "$(dirname "$config_file")"
    else
        path_cmd="export PATH=\"$INSTALL_DIR:\$PATH\""
    fi
    
    # Create config file if it doesn't exist (for fallback case when no configs found)
    touch "$config_file"
    
    # Append if not already present
    if ! grep -qsF "$INSTALL_DIR" "$config_file"; then
        echo "" >> "$config_file"
        echo "# Added by git-ai installer on $(date)" >> "$config_file"
        echo "$path_cmd" >> "$config_file"
        SHELLS_CONFIGURED="${SHELLS_CONFIGURED}${shell_name}|${config_file}\n"
    else
        SHELLS_ALREADY_CONFIGURED="${SHELLS_ALREADY_CONFIGURED}${shell_name}|${config_file}\n"
    fi
done <<< "$(detect_all_shells)"

# Display results to user
if [ -n "$SHELLS_CONFIGURED" ]; then
    echo ""
    echo "Updated shell configurations:"
    printf '%b' "$SHELLS_CONFIGURED" | while IFS='|' read -r shell_name config_file; do
        [ -z "$shell_name" ] && continue
        success "  ✓ $config_file"
    done
    
    echo ""
    echo "To apply changes immediately:"
    printf '%b' "$SHELLS_CONFIGURED" | while IFS='|' read -r shell_name config_file; do
        [ -z "$shell_name" ] && continue
        if [ "$shell_name" = "fish" ]; then
            echo "  - For fish: source $config_file"
        else
            echo "  - For $shell_name: source $config_file"
        fi
    done
fi

if [ -n "$SHELLS_ALREADY_CONFIGURED" ]; then
    echo ""
    echo "Already configured (no changes needed):"
    printf '%b' "$SHELLS_ALREADY_CONFIGURED" | while IFS='|' read -r shell_name config_file; do
        [ -z "$shell_name" ] && continue
        echo "  ✓ $config_file"
    done
fi

if [ -z "$SHELLS_CONFIGURED" ] && [ -z "$SHELLS_ALREADY_CONFIGURED" ]; then
    echo ""
    echo "Could not detect any shell config files."
    echo "Please add the following line to your shell config and restart:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi

echo ""
echo -e "${YELLOW}Close and reopen your terminal and IDE sessions to use git-ai.${NC}"

# [DISABLED] Login functionality removed for internal deployment
# if [ "$NEED_LOGIN" = true ]; then
#     echo ""
#     echo "Launching login..."
#     ${INSTALL_DIR}/git-ai login
# fi
