#!/usr/bin/env node
/**
 * CodeBuddy -> git-ai agent-v1 适配脚本 (Node.js 版本)
 *
 * 将 CodeBuddy 的 hook 数据转换为 git-ai agent-v1 格式，
 * 实现 AI 代码归属追踪。
 *
 * 使用方法:
 * 1. 确保 git-ai 已安装并在 PATH 中
 * 2. 在项目的 .codebuddy/settings.json 中配置 hooks
 * 3. 脚本会自动将 CodeBuddy 的数据转换为 git-ai 格式
 *
 * 配置示例 (.codebuddy/settings.json):
 * {
 *   "hooks": {
 *     "PreToolUse": [{
 *       "matcher": "replace_in_file|write_to_file|create_file",
 *       "hooks": [{
 *         "type": "command",
 *         "command": "node /path/to/codebuddy-git-ai-hook.js",
 *         "timeout": 30
 *       }]
 *     }],
 *     "PostToolUse": [{
 *       "matcher": "replace_in_file|write_to_file|create_file",
 *       "hooks": [{
 *         "type": "command",
 *         "command": "node /path/to/codebuddy-git-ai-hook.js",
 *         "timeout": 30
 *       }]
 *     }]
 *   }
 * }
 */

const { spawn, execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// 调试模式
const DEBUG = process.env.CODEBUDDY_GIT_AI_DEBUG === '1';
const LOG_FILE = '/tmp/codebuddy-git-ai.log';

// 文件编辑相关的工具
const FILE_EDIT_TOOLS = new Set([
  'write_to_file',
  'replace_in_file',
  'create_file',
  'write',
  'edit',
  'multiedit',
  'multi_edit',
  'insert',
  'delete',
  'replace',
  'patch'
]);

/**
 * 写入调试日志
 */
function log(message) {
  if (DEBUG) {
    const timestamp = new Date().toISOString();
    fs.appendFileSync(LOG_FILE, `[${timestamp}] ${message}\n`);
  }
}

/**
 * 获取 git-ai 的完整路径
 */
function getGitAiPath() {
  // 常见的安装位置
  const possiblePaths = [
    process.env.GIT_AI_PATH,
    `${process.env.HOME}/.git-ai/bin/git-ai`,
    '/usr/local/bin/git-ai',
    '/opt/homebrew/bin/git-ai',
    'git-ai'  // 依赖 PATH
  ];
  
  for (const p of possiblePaths) {
    if (!p) continue;
    try {
      // 尝试执行 --version 验证
      execSync(`"${p}" --version`, { stdio: 'ignore' });
      return p;
    } catch {
      continue;
    }
  }
  
  // 最后尝试 which
  try {
    const result = execSync('which git-ai', { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'ignore'] });
    return result.trim();
  } catch {
    return null;
  }
}

// 缓存 git-ai 路径
let _gitAiPath = null;

/**
 * 检查 git-ai 是否已安装
 */
function isGitAiInstalled() {
  if (_gitAiPath === null) {
    _gitAiPath = getGitAiPath();
  }
  return _gitAiPath !== null;
}

/**
 * 检查是否是文件编辑相关的工具
 */
function isFileEditTool(toolName) {
  if (!toolName) return false;
  return FILE_EDIT_TOOLS.has(toolName.toLowerCase());
}

/**
 * 从 stdin 读取 JSON 数据
 */
async function readStdin() {
  return new Promise((resolve) => {
    const chunks = [];
    
    process.stdin.on('data', (chunk) => {
      chunks.push(chunk);
    });
    
    process.stdin.on('end', () => {
      const input = Buffer.concat(chunks).toString('utf-8').trim();
      if (!input) {
        resolve({});
        return;
      }
      
      try {
        resolve(JSON.parse(input));
      } catch (e) {
        log(`Failed to parse stdin JSON: ${e.message}`);
        resolve({});
      }
    });
    
    // 设置超时
    setTimeout(() => {
      resolve({});
    }, 5000);
  });
}

/**
 * 获取仓库工作目录
 */
function getRepoWorkingDir(hookData) {
  // 1. 从环境变量获取
  const projectDir = process.env.CODEBUDDY_PROJECT_DIR;
  if (projectDir) {
    return projectDir;
  }
  
  // 2. 从 hookData 获取
  const cwd = hookData.cwd || hookData.repo_working_dir || hookData.workspace_root;
  if (cwd) {
    return cwd;
  }
  
  // 3. 从 file_path 推断 git 根目录
  const filePath = getFilePath(hookData);
  if (filePath) {
    try {
      const result = execSync(`git -C "${path.dirname(filePath)}" rev-parse --show-toplevel`, {
        encoding: 'utf-8',
        stdio: ['pipe', 'pipe', 'ignore']
      });
      return result.trim();
    } catch {
      // 忽略错误
    }
  }
  
  // 4. 默认使用当前目录
  return process.cwd();
}

/**
 * 获取编辑的文件路径
 */
function getFilePath(hookData) {
  // 从 tool_input 获取
  const toolInput = hookData.tool_input || {};
  return toolInput.filePath || toolInput.file_path || toolInput.path || null;
}

/**
 * 获取编辑的文件路径列表
 */
function getEditedFilepaths(hookData) {
  const paths = [];
  
  const filePath = getFilePath(hookData);
  if (filePath) {
    paths.push(filePath);
  }
  
  // 去重
  return [...new Set(paths)];
}

/**
 * 获取模型名称
 */
function getModelName(hookData) {
  return hookData.model || 
         hookData.model_name || 
         process.env.CODEBUDDY_MODEL || 
         'codebuddy';
}

/**
 * 获取会话 ID
 */
function getConversationId(hookData) {
  return hookData.session_id || 
         hookData.conversation_id || 
         process.env.CODEBUDDY_SESSION_ID || 
         `codebuddy-${process.pid}`;
}

/**
 * 构建 transcript
 * 
 * git-ai agent-v1 要求的格式:
 * {
 *   "messages": [
 *     {"type": "user", "text": "...", "timestamp": "..."},
 *     {"type": "assistant", "text": "...", "timestamp": "..."},
 *     {"type": "tool_use", "name": "...", "input": {...}, "timestamp": "..."}
 *   ]
 * }
 */
function buildTranscript(hookData) {
  const messages = [];
  const timestamp = new Date().toISOString();
  
  // 如果已有 transcript，直接返回
  if (hookData.transcript && hookData.transcript.messages) {
    return hookData.transcript;
  }
  
  // 如果有 transcript_path，尝试读取
  if (hookData.transcript_path && fs.existsSync(hookData.transcript_path)) {
    try {
      const content = fs.readFileSync(hookData.transcript_path, 'utf-8');
      // 可能是 JSONL 格式
      if (hookData.transcript_path.endsWith('.jsonl')) {
        for (const line of content.split('\n')) {
          if (!line.trim()) continue;
          try {
            const entry = JSON.parse(line);
            const msgType = entry.type || 'unknown';
            if (msgType === 'human' || msgType === 'user') {
              messages.push({
                type: 'user',
                text: entry.message?.content || entry.text || '',
                timestamp: entry.timestamp || timestamp
              });
            } else if (msgType === 'assistant' || msgType === 'ai') {
              messages.push({
                type: 'assistant',
                text: entry.message?.content || entry.text || '',
                timestamp: entry.timestamp || timestamp
              });
            }
          } catch {
            continue;
          }
        }
      } else {
        // 尝试作为 JSON 读取
        const data = JSON.parse(content);
        if (data.messages) {
          return data;
        }
      }
    } catch (e) {
      log(`Failed to read transcript: ${e.message}`);
    }
  }
  
  // 至少添加一个工具使用记录
  const toolName = hookData.tool_name || 'unknown';
  const toolInput = hookData.tool_input || {};
  
  if (toolName !== 'unknown') {
    messages.push({
      type: 'tool_use',
      name: toolName,
      input: typeof toolInput === 'object' ? toolInput : {},
      timestamp
    });
  }
  
  return { messages };
}

/**
 * 调用 git-ai checkpoint agent-v1
 */
function callGitAiCheckpoint(payload) {
  return new Promise((resolve) => {
    const payloadJson = JSON.stringify(payload);
    log(`Calling git-ai with payload: ${payloadJson.substring(0, 500)}...`);
    
    const gitAiCmd = _gitAiPath || 'git-ai';
    const child = spawn(gitAiCmd, ['checkpoint', 'agent-v1', '--hook-input', 'stdin'], {
      stdio: ['pipe', 'pipe', 'pipe']
    });
    
    let stdout = '';
    let stderr = '';
    
    child.stdout.on('data', (data) => {
      stdout += data.toString();
    });
    
    child.stderr.on('data', (data) => {
      stderr += data.toString();
    });
    
    child.on('close', (code) => {
      if (code !== 0) {
        log(`git-ai checkpoint failed (code ${code}): ${stderr}`);
        resolve(false);
      } else {
        log(`git-ai checkpoint success: ${stdout}`);
        resolve(true);
      }
    });
    
    child.on('error', (err) => {
      log(`git-ai checkpoint error: ${err.message}`);
      resolve(false);
    });
    
    // 写入 payload 并关闭 stdin
    child.stdin.write(payloadJson);
    child.stdin.end();
    
    // 设置超时
    setTimeout(() => {
      child.kill();
      log('git-ai checkpoint timed out');
      resolve(false);
    }, 25000);
  });
}

/**
 * 处理 PreToolUse 事件 - 标记人类更改
 */
async function handlePreToolUse(hookData) {
  const toolName = hookData.tool_name || '';
  
  // 只处理文件编辑相关的工具
  if (!isFileEditTool(toolName)) {
    log(`Skipping non-edit tool: ${toolName}`);
    return;
  }
  
  const repoDir = getRepoWorkingDir(hookData);
  const editedFiles = getEditedFilepaths(hookData);
  
  const payload = {
    type: 'human',
    repo_working_dir: repoDir
  };
  
  // 如果知道将要编辑的文件，可以加速处理
  if (editedFiles.length > 0) {
    payload.will_edit_filepaths = editedFiles;
  }
  
  await callGitAiCheckpoint(payload);
}

/**
 * 处理 PostToolUse 事件 - 标记 AI 更改
 */
async function handlePostToolUse(hookData) {
  const toolName = hookData.tool_name || '';
  
  // 只处理文件编辑相关的工具
  if (!isFileEditTool(toolName)) {
    log(`Skipping non-edit tool: ${toolName}`);
    return;
  }
  
  const repoDir = getRepoWorkingDir(hookData);
  const editedFiles = getEditedFilepaths(hookData);
  const model = getModelName(hookData);
  const conversationId = getConversationId(hookData);
  const transcript = buildTranscript(hookData);
  
  const payload = {
    type: 'ai_agent',
    repo_working_dir: repoDir,
    agent_name: 'codebuddy',
    model,
    conversation_id: conversationId,
    edited_filepaths: editedFiles,
    transcript
  };
  
  await callGitAiCheckpoint(payload);
}

/**
 * 主入口
 */
async function main() {
  try {
    // 检查 git-ai 是否安装
    if (!isGitAiInstalled()) {
      log('git-ai is not installed, skipping');
      console.log('{}');
      return;
    }
    
    // 读取 hook 数据
    const hookData = await readStdin();
    log(`Received hook data: ${JSON.stringify(hookData).substring(0, 500)}`);
    
    // 获取事件类型
    const hookEvent = hookData.hook_event_name || 
                      process.env.CODEBUDDY_HOOK_EVENT || 
                      'unknown';
    
    log(`Hook event: ${hookEvent}`);
    
    // 根据事件类型处理
    switch (hookEvent) {
      case 'PreToolUse':
      case 'pre_tool_use':
      case 'beforeEdit':
        await handlePreToolUse(hookData);
        break;
        
      case 'PostToolUse':
      case 'post_tool_use':
      case 'afterEdit':
      case 'afterFileEdit':
        await handlePostToolUse(hookData);
        break;
        
      default:
        log(`Unknown hook event: ${hookEvent}`);
    }
    
    // 返回空响应
    console.log('{}');
    
  } catch (e) {
    // 确保不会阻塞 CodeBuddy
    log(`Fatal error: ${e.message}`);
    console.log('{}');
  }
}

main();
