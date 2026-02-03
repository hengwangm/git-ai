# CodeBuddy + git-ai Integration Guide

This guide explains how to integrate CodeBuddy (Tencent Cloud Coding Assistant) with git-ai for AI code attribution tracking.

## Overview

Using git-ai's `agent-v1` protocol, we can automatically record AI code attribution when CodeBuddy edits files. This information is stored in git notes and can be used for:

- Tracking the percentage of AI-generated code in a project
- Identifying whether each line of code was written by a human or AI
- Understanding code origins during code review

## Prerequisites

1. **Install git-ai**

   ```bash
   # macOS / Linux
   curl -sSL https://usegitai.com/install.sh | bash
   
   # Verify installation
   git-ai --version
   ```

2. **Install Node.js** (v16 or later)

   ```bash
   # macOS
   brew install node
   
   # Ubuntu/Debian
   sudo apt install nodejs npm
   ```

3. **Install CodeBuddy IDE**

## Installation

### Method 1: Using Install Script (Recommended)

```bash
# Clone the repo or download the scripts
git clone https://github.com/git-ai-project/git-ai.git
cd git-ai/scripts

# Run installation (installs to current project)
./install-codebuddy-hooks.sh

# Or specify a project directory
./install-codebuddy-hooks.sh -p /path/to/your/project
```

### Method 2: Manual Configuration

1. Copy the adapter script to a permanent location:
   ```bash
   mkdir -p ~/.config/git-ai
   cp scripts/codebuddy-git-ai-hook.js ~/.config/git-ai/
   chmod +x ~/.config/git-ai/codebuddy-git-ai-hook.js
   ```

2. Add the following to your project's `.codebuddy/settings.json`:

   ```json
   {
     "hooks": {
       "PreToolUse": [
         {
           "matcher": "replace_in_file|write_to_file|create_file",
           "hooks": [
             {
               "type": "command",
               "command": "node ~/.config/git-ai/codebuddy-git-ai-hook.js",
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
               "command": "node ~/.config/git-ai/codebuddy-git-ai-hook.js",
               "timeout": 30
             }
           ]
         }
       ]
     }
   }
   ```

## Verify Installation

1. **Enable debug mode**
   ```bash
   export CODEBUDDY_GIT_AI_DEBUG=1
   ```

2. **Edit a file using CodeBuddy**, then check the log:
   ```bash
   cat /tmp/codebuddy-git-ai.log
   ```

3. **Check git-ai status**
   ```bash
   git-ai status
   ```

   You should see something like:
   ```
   you  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ ai
        0%                                  100%
        100% AI code accepted

   15 secs ago       +1      0  Codebuddy codebuddy
   25 secs ago     +476     -1  Codebuddy codebuddy
   ```

## Usage

After installation, CodeBuddy will automatically call git-ai to record attribution whenever it edits files.

### View Statistics

```bash
# View AI stats for a single commit
git ai stats HEAD

# View stats for a range
git ai stats main..HEAD

# View AI blame for a file
git ai blame src/main.rs
```

### Sample Output

```
┌──────────────────────────────────────────────────────────────┐
│              Authorship Summary for HEAD                     │
├──────────────────────────────────────────────────────────────┤
│  Human Lines:    150 (60%)                                   │
│  AI Lines:       100 (40%)                                   │
│  Tool:           codebuddy                                   │
│  Model:          codebuddy                                   │
└──────────────────────────────────────────────────────────────┘
```

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                     CodeBuddy IDE                               │
│   User requests AI to edit code                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              PreToolUse Hook Triggered                          │
│   → codebuddy-git-ai-hook.js receives stdin JSON                │
│   → Converts to agent-v1 format: {"type": "human", ...}         │
│   → Calls: git-ai checkpoint agent-v1 --hook-input stdin        │
│   → Marks human changes since last checkpoint                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              CodeBuddy Executes File Edit                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              PostToolUse Hook Triggered                         │
│   → codebuddy-git-ai-hook.js receives stdin JSON                │
│   → Converts to agent-v1 format: {"type": "ai_agent", ...}      │
│   → Calls: git-ai checkpoint agent-v1 --hook-input stdin        │
│   → Marks the AI edit                                           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              On git commit                                      │
│   → git-ai's post-commit hook triggers                          │
│   → Writes authorship log to refs/notes/ai                      │
└─────────────────────────────────────────────────────────────────┘
```

## Uninstall

```bash
./install-codebuddy-hooks.sh --uninstall -p /path/to/project
```

Or manually edit `.codebuddy/settings.json` to remove the hooks.

## Troubleshooting

### Q: git-ai checkpoint is not being called

Check:
1. Is git-ai in PATH: `which git-ai`
2. Is Node.js available: `which node`
3. View debug log: `cat /tmp/codebuddy-git-ai.log`

### Q: settings.json syntax error

Validate the JSON:
```bash
node -e "console.log(JSON.parse(require('fs').readFileSync('.codebuddy/settings.json')))"
```

### Q: No statistics showing

Ensure:
1. You're using CodeBuddy in a git repository
2. You've committed the changes
3. Check notes: `git notes --ref=ai list`

### Q: Sync notes to remote

```bash
git push origin refs/notes/ai
git fetch origin refs/notes/ai:refs/notes/ai
```

## Related Links

- [git-ai Documentation](https://usegitai.com/docs)
- [agent-v1 Protocol](https://usegitai.com/docs/cli/add-your-agent)
- [CodeBuddy Documentation](https://www.codebuddy.ai/docs)
