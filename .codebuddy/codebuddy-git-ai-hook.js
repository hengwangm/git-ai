#!/usr/bin/env node
/**
 * CodeBuddy -> git-ai 适配脚本
 * 将 CodeBuddy 的 hook 数据转换为 git-ai agent-v1 格式
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
 * 查找 CodeBuddy IDE 会话的 messages 目录
 * @param {string} sessionId - 会话 ID
 * @returns {string|null} - messages 目录路径或 null
 */
function findSessionMessagesDir(sessionId) {
  if (!sessionId) return null;
  
  try {
    const homeDir = process.env.HOME || '';
    const dataDir = path.join(homeDir, 'Library', 'Application Support', 'CodeBuddyExtension', 'Data');
    
    if (!fs.existsSync(dataDir)) return null;
    
    // 遍历 Data 目录下的用户目录
    const userDirs = fs.readdirSync(dataDir).filter(d => {
      const fullPath = path.join(dataDir, d);
      return fs.statSync(fullPath).isDirectory() && d !== 'Public' && d !== 'default';
    });
    
    for (const userId of userDirs) {
      const historyBase = path.join(dataDir, userId, 'CodeBuddyIDE', userId, 'history');
      if (!fs.existsSync(historyBase)) continue;
      
      const workspaceDirs = fs.readdirSync(historyBase).filter(d => {
        const fullPath = path.join(historyBase, d);
        return fs.statSync(fullPath).isDirectory();
      });
      
      for (const workspaceHash of workspaceDirs) {
        const messagesDir = path.join(historyBase, workspaceHash, sessionId, 'messages');
        if (fs.existsSync(messagesDir)) {
          log(`Found session messages dir: ${messagesDir}`);
          return messagesDir;
        }
      }
    }
    return null;
  } catch (e) {
    log(`Error finding session messages dir: ${e.message}`);
    return null;
  }
}

/**
 * 从 CodeBuddy IDE 的会话历史中提取模型名
 * @param {string} sessionId - 会话 ID
 * @returns {string|null} - 模型名或 null
 */
function extractModelFromCodeBuddyIDE(sessionId) {
  const messagesDir = findSessionMessagesDir(sessionId);
  if (!messagesDir) return null;
  
  try {
    const messageFiles = fs.readdirSync(messagesDir)
      .filter(f => f.endsWith('.json'))
      .map(f => ({
        path: path.join(messagesDir, f),
        mtime: fs.statSync(path.join(messagesDir, f)).mtime
      }))
      .sort((a, b) => b.mtime - a.mtime);
    
    for (const msgFile of messageFiles) {
      try {
        const content = fs.readFileSync(msgFile.path, 'utf-8');
        const message = JSON.parse(content);
        
        if (message.extra) {
          const extra = typeof message.extra === 'string' 
            ? JSON.parse(message.extra) : message.extra;
          
          if (extra.modelId) {
            log(`Found model from IDE history: ${extra.modelId}`);
            return extra.modelId;
          }
        }
      } catch { continue; }
    }
    return null;
  } catch (e) {
    log(`Error extracting model: ${e.message}`);
    return null;
  }
}

/**
 * 从 IDE 会话历史构建完整的 transcript
 * @param {string} sessionId - 会话 ID
 * @param {number} maxMessages - 最大消息数量（默认 50）
 * @returns {object} - { messages: [...] }
 */
function buildTranscriptFromIDE(sessionId, maxMessages = 50) {
  const messagesDir = findSessionMessagesDir(sessionId);
  if (!messagesDir) return { messages: [] };
  
  try {
    const messageFiles = fs.readdirSync(messagesDir)
      .filter(f => f.endsWith('.json'))
      .map(f => ({
        path: path.join(messagesDir, f),
        mtime: fs.statSync(path.join(messagesDir, f)).mtime
      }))
      .sort((a, b) => a.mtime - b.mtime); // 按时间升序
    
    const messages = [];
    const recentFiles = messageFiles.slice(-maxMessages);
    
    for (const msgFile of recentFiles) {
      try {
        const content = fs.readFileSync(msgFile.path, 'utf-8');
        const msg = JSON.parse(content);
        const timestamp = msgFile.mtime.toISOString();
        
        if (msg.role === 'user') {
          // 提取用户输入
          const extra = msg.extra ? (typeof msg.extra === 'string' ? JSON.parse(msg.extra) : msg.extra) : {};
          let text = '';
          
          // 优先从 sourceContentBlocks 获取原始用户输入
          if (extra.sourceContentBlocks && extra.sourceContentBlocks[0]) {
            text = extra.sourceContentBlocks[0].text || '';
          } else if (msg.message) {
            // 从 message 解析
            try {
              const msgData = typeof msg.message === 'string' ? JSON.parse(msg.message) : msg.message;
              if (msgData.content && msgData.content[0] && msgData.content[0].text) {
                // 尝试提取 <user_query> 中的内容
                const fullText = msgData.content[0].text;
                const userQueryMatch = fullText.match(/<user_query>\n?([\s\S]*?)\n?<\/user_query>/);
                text = userQueryMatch ? userQueryMatch[1].trim() : fullText.substring(0, 500);
              }
            } catch { }
          }
          
          if (text) {
            messages.push({ type: 'user', text, timestamp });
          }
          
        } else if (msg.role === 'assistant') {
          // 提取 AI 回复
          let text = '';
          
          if (msg.message) {
            try {
              const msgData = typeof msg.message === 'string' ? JSON.parse(msg.message) : msg.message;
              if (msgData.content) {
                // 只提取文本部分，忽略 tool-call
                for (const item of msgData.content) {
                  if (item.type === 'text' && item.text) {
                    text += item.text + '\n';
                  }
                }
              }
            } catch { }
          }
          
          if (text.trim()) {
            messages.push({ type: 'assistant', text: text.trim().substring(0, 2000), timestamp });
          }
        }
        // 注意：tool 消息不包含在 transcript 中，因为 git-ai 只需要 user/assistant/tool_use
      } catch { continue; }
    }
    
    // 统计消息类型
    const userCount = messages.filter(m => m.type === 'user').length;
    const assistantCount = messages.filter(m => m.type === 'assistant').length;
    const toolCount = messages.filter(m => m.type === 'tool_use').length;
    log(`Built transcript with ${messages.length} messages (user: ${userCount}, assistant: ${assistantCount}, tool: ${toolCount})`);
    return { messages };
  } catch (e) {
    log(`Error building transcript: ${e.message}`);
    return { messages: [] };
  }
}

/**
 * 获取模型名称
 * 优先级：hook 数据 > 环境变量 > IDE 会话历史
 */
function getModelName(hookData) {
  // 1. hook 数据中直接提供
  if (hookData.model) return hookData.model;
  if (hookData.model_name) return hookData.model_name;
  
  // 2. 环境变量
  if (process.env.CODEBUDDY_MODEL) return process.env.CODEBUDDY_MODEL;
  
  // 3. 从 IDE 会话历史中提取（最准确）
  const sessionId = hookData.session_id;
  if (sessionId) {
    const model = extractModelFromCodeBuddyIDE(sessionId);
    if (model) return model;
  }
  
  // 4. 默认值
  return 'codebuddy';
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
 * 优先从 IDE 会话历史构建完整的 user/assistant 消息，再添加当前 tool_use
 */
function buildTranscript(hookData) {
  const timestamp = new Date().toISOString();
  
  // 如果已有 transcript，直接返回
  if (hookData.transcript && hookData.transcript.messages && hookData.transcript.messages.length > 0) {
    return hookData.transcript;
  }
  
  // 从 IDE 会话历史构建 transcript
  const sessionId = hookData.session_id;
  const transcript = sessionId ? buildTranscriptFromIDE(sessionId, 30) : { messages: [] };
  
  // 添加当前工具使用记录
  const toolName = hookData.tool_name;
  const toolInput = hookData.tool_input || {};
  
  if (toolName) {
    transcript.messages.push({
      type: 'tool_use',
      name: toolName,
      input: typeof toolInput === 'object' ? toolInput : {},
      timestamp
    });
  }
  
  return transcript;
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
  // 记录 hook 启动时间用于性能分析
  const hookStartTime = Date.now();
  const hookVersion = '1.0.1';
  
  log(`[Main] CodeBuddy Git-AI Hook v${hookVersion} starting...`);
  log(`[Main] Node version: ${process.version}`);
  log(`[Main] Platform: ${process.platform}`);
  log(`[Main] Current working directory: ${process.cwd()}`);
  log(`[Main] Environment CODEBUDDY_HOOK_EVENT: ${process.env.CODEBUDDY_HOOK_EVENT || 'not set'}`);
  
  try {
    // 检查 git-ai 是否安装
    if (!isGitAiInstalled()) {
      log('git-ai is not installed, skipping');
      console.log('{}');
      return;
    }
    
    log(`[Main] git-ai installation verified, took ${Date.now() - hookStartTime}ms`);
    
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
