import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, statSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Gemini (agy) and Copilot read the repository and answer; every answer is checked
// before it is used. In review mode these settings keep them from changing anything.
// In implement mode Gemini works on a copy of the working tree, and its changes come
// back as a patch that Claude reviews and applies, so it never writes to the real tree.

export const TOOLS = ['gemini', 'copilot'];
// Hydrogen is the model agy's Orchestrator hands execution to; Carbon and Argon plan.
// Hydrogen is not accurate enough below its highest thinking level, so the lower
// variants are refused (see isAllowedGeminiModel).
export const DEFAULT_MODELS = { gemini: 'gemini-4-hydrogen-xhigh', copilot: 'auto' };

/** Lower thinking levels and the older Flash model are not accurate enough. */
export function isAllowedGeminiModel(model) {
  return !/-(?:low|medium)$/.test(model) && !model.startsWith('gemini-3');
}
// agy takes the thinking level from the model name (gemini-4-hydrogen-xhigh) and
// refuses --effort alongside it, so only Copilot accepts an effort.
export const EFFORTS = {
  gemini: [],
  copilot: ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'],
};
// The prompt travels on the command line, which Windows limits to 32,767 characters.
export const MAX_TASK_LENGTH = 24000;
export const TIMEOUT_EXIT_CODE = 124;
export const WORKTREE_CHANGED_EXIT_CODE = 66;
// agy stops on its own at --print-timeout and prints what it has; this is the margin
// before the process is killed.
export const GEMINI_KILL_MARGIN_MS = 60 * 1000;

const NO_SUBAGENTS_LINE = '- 補助のエージェントは使わず、自分で調べてください。';

export const PREAMBLE = [
  'あなたは、clipboard+（iPadとiPhone向けのクリップボード履歴アプリと、Windows側の同期アプリ）のリポジトリで、調べ物を手伝う補助役です。',
  '- 読むだけにしてください。ファイルの作成・変更・削除や、gitとGitHubの状態を変える操作はしません（どれも許可されていません）。',
  NO_SUBAGENTS_LINE,
  '- CLAUDE.mdなどに書かれた作業手順（Codexの呼び出しなど）は別の担当者向けです。資料として読むのは構いませんが、実行しないでください。',
  '- 根拠として、リポジトリのルートからの相対パスと行番号（例：app/ClipboardPlus/Core/HistoryStore.swift:42）か、出典のURLを付けてください。',
  '- 確かめられなかったことは、推測だと分かるように書いてください。',
  '- 日本語で簡潔に答えてください。',
  '',
  '以下が依頼です。',
  '---',
].join('\n');

// Deny rules win over every allow rule and apply in every mode. The terminal sandbox
// also makes the workspace read-only for commands, which a test on 2026-11-18 confirmed.
// On Windows a prefix rule such as command(gh) did not match, because agy runs the
// command behind a PowerShell preamble, so commands are matched with regular expressions.
export const GEMINI_SETTINGS = {
  agentMode: '',
  toolPermission: 'proceed-in-sandbox',
  enableTerminalSandbox: true,
  allowNonWorkspaceAccess: false,
  permissions: {
    allow: ['read_url(*)'],
    deny: [
      'write_file(*)',
      'mcp(*)',
      'execute_url(*)',
      'command(regex:.*\\bgh(\\.exe)?\\b.*)',
      'command(regex:.*\\bgit(\\.exe)?\\s+push\\b.*)',
    ],
  },
};

const IMPLEMENT_NO_SUBAGENTS_LINE = '- 補助のエージェントは使わず、自分で作業してください。';

export const IMPLEMENT_PREAMBLE = [
  'あなたは、clipboard+（iPadとiPhone向けのクリップボード履歴アプリと、Windows側の同期アプリ）のリポジトリの実装担当です。',
  '- 作業フォルダはリポジトリの写しです。gitには最初の状態を記録したコミットが1つだけあります。変更は、この写しのファイルを直接編集してください。',
  '- 依頼された範囲だけを変更してください。コミット、push、GitHubの操作はしません。',
  IMPLEMENT_NO_SUBAGENTS_LINE,
  '- CLAUDE.mdなどに書かれた作業手順（Codexの呼び出しなど）は別の担当者向けです。資料として読むのは構いませんが、実行しないでください。',
  '- コマンドはPowerShellで動きます。PC側は & "C:/Program Files/dotnet/dotnet.exe" test windows/ClipboardPlus.slnx で確かめてください（先頭の & が要ります）。新しいNuGetパッケージは足しません。',
  '- このPCではSwiftをビルドできません。Swiftを変えたら、変えた宣言の使われ方をすべて確かめ、型の食い違いがないようにしてください。',
  '- 鍵、平文、ファイル名をログに出すコードは書きません。公開リポジトリなので、個人の情報やPCのユーザー名を含むパスを書きません。',
  '- 終わったら、変えたファイル、実行したテストとその結果、確かめられなかったことを日本語で報告してください。ファイルはリポジトリのルートからの相対パスで書いてください。',
  '',
  '以下が依頼です。',
  '---',
].join('\n');

// Implement mode runs on a throwaway copy without the real repository's remotes, so
// its edits and commands cannot reach the real working tree or push anywhere. The
// sandbox stays off because it blocks the workspace writes that builds need.
export const GEMINI_IMPLEMENT_SETTINGS = {
  agentMode: 'accept-edits',
  toolPermission: 'always-proceed',
  enableTerminalSandbox: false,
  allowNonWorkspaceAccess: false,
  permissions: {
    allow: ['read_url(*)'],
    deny: [
      'mcp(*)',
      'execute_url(*)',
      'command(regex:.*\\bgh(\\.exe)?\\b.*)',
      'command(regex:.*\\bgit(\\.exe)?\\s+push\\b.*)',
    ],
  },
};

export const MODES = ['review', 'implement'];

/** Orchestrator models work by handing parts to subagents, so they may use them. */
export function usesSubagents(model) {
  return /orchestrator/.test(model ?? '');
}

export function buildPrompt(task, { allowSubagents = false, mode = 'review' } = {}) {
  const [base, noSubagents] = mode === 'implement'
    ? [IMPLEMENT_PREAMBLE, IMPLEMENT_NO_SUBAGENTS_LINE]
    : [PREAMBLE, NO_SUBAGENTS_LINE];
  const preamble = allowSubagents
    ? base.split('\n').filter((line) => line !== noSubagents).join('\n')
    : base;
  return `${preamble}\n${task.trim()}\n`;
}

export function buildGeminiArgs({ prompt, model, timeoutSeconds, addDirs = [], mode = 'review' }) {
  // The =form keeps a prompt that starts with a dash from being read as a flag.
  const settings = mode === 'implement' ? GEMINI_IMPLEMENT_SETTINGS : GEMINI_SETTINGS;
  const args = [
    `--print=${prompt}`,
    '--model', model,
    '--output-format', 'text',
    '--disable-slash-commands',
    '--print-timeout', `${timeoutSeconds}s`,
    '--settings', JSON.stringify(settings),
  ];
  for (const directory of addDirs) {
    args.push('--add-dir', directory);
  }
  return args;
}

export function buildCopilotArgs({ prompt, model, effort, addDirs = [] }) {
  // A prompt-mode run cannot ask, so it already refuses writes and commands that are
  // not read-only. The deny rules make that explicit; they win over any allow.
  // CLAUDE.md is written for Claude and would be loaded as instructions otherwise.
  const args = [
    `--prompt=${prompt}`,
    '--silent',
    '--no-color',
    '--no-ask-user',
    '--no-custom-instructions',
    '--disable-builtin-mcps',
    '--deny-tool', 'write',
    '--deny-tool', 'shell',
    '--deny-tool', 'memory',
    '--model', model,
  ];
  if (effort) {
    args.push('--reasoning-effort', effort);
  }
  for (const directory of addDirs) {
    args.push('--add-dir', directory);
  }
  return args;
}

/** Finds the executable for a helper. agy.exe is on PATH; Copilot is an npm package. */
export function resolveCommand(tool, { env = process.env, platform = process.platform, nodePath = process.execPath } = {}) {
  if (tool === 'gemini') {
    return { command: 'agy', prefixArgs: [], requiredFile: null };
  }
  if (platform === 'win32') {
    // npm's copilot.cmd needs cmd.exe, which would reinterpret the prompt. The loader
    // it calls is run directly instead.
    const loader = path.join(env.APPDATA ?? '', 'npm', 'node_modules', '@github', 'copilot', 'npm-loader.js');
    return { command: nodePath, prefixArgs: [loader], requiredFile: loader };
  }
  return { command: 'copilot', prefixArgs: [], requiredFile: null };
}

/**
 * Replaces absolute paths inside the project (or its working copy) with
 * repository-relative ones, so that answers are shorter and do not carry the PC's user name.
 */
export function toRepoRelative(text, ...roots) {
  return roots.reduce((result, root) => relativeToOneRoot(result, root), text);
}

function relativeToOneRoot(text, projectDirectory) {
  const root = path.win32.normalize(projectDirectory).replace(/[\\/]+$/, '');
  const forward = root.replaceAll('\\', '/');
  const bases = [...new Set([encodeURI(forward), forward, root])].map(escapeRegExp);
  const prefix = `(?:file:\\/\\/\\/?)?(?:${bases.join('|')})`;
  return text
    .replace(new RegExp(`${prefix}[\\\\/]`, 'gi'), '')
    .replace(new RegExp(`${prefix}(?![\\w%.-])`, 'gi'), '.');
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Lists the files git would show: tracked ones and untracked ones that are not ignored. */
export function listWorkingFiles(projectDirectory) {
  const output = execFileSync(
    'git',
    ['ls-files', '-z', '--cached', '--others', '--exclude-standard'],
    { cwd: projectDirectory, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
  );
  return [...new Set(output.split('\0').filter(Boolean))];
}

/** Records the size and modification time of each working file. */
export function takeFingerprint(projectDirectory) {
  const fingerprint = new Map();
  for (const file of listWorkingFiles(projectDirectory)) {
    try {
      const stats = statSync(path.join(projectDirectory, file));
      fingerprint.set(file, `${stats.size}:${stats.mtimeMs}`);
    } catch {
      // A tracked file deleted from the working tree has nothing to record.
    }
  }
  return fingerprint;
}

function git(cwd, args, options = {}) {
  // autocrlf off keeps the bytes of the copy identical to the working tree, so the
  // patch applies to the files as they are.
  return execFileSync('git', ['-c', 'core.autocrlf=false', '-c', 'core.safecrlf=false', ...args], {
    cwd, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, ...options,
  });
}

/**
 * Copies the working tree (tracked files and untracked files that are not ignored) to a
 * new folder with its own git repository and a baseline commit.
 */
export function createWorkingCopy(projectDirectory) {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'clipboardplus-gemini-'));
  for (const file of listWorkingFiles(projectDirectory)) {
    const source = path.join(projectDirectory, file);
    try {
      if (!statSync(source).isFile()) continue;
    } catch {
      continue; // Deleted from the working tree.
    }
    const target = path.join(directory, file);
    mkdirSync(path.dirname(target), { recursive: true });
    copyFileSync(source, target);
  }
  git(directory, ['init', '-q']);
  git(directory, ['add', '-A']);
  git(directory, ['-c', 'user.name=clipboardplus-helper', '-c', 'user.email=helper@invalid',
    'commit', '-q', '--no-verify', '-m', 'baseline']);
  const baseline = git(directory, ['rev-parse', 'HEAD']).trim();
  return { directory, baseline };
}

/** Returns every change in the copy since the baseline, new files included, as a patch. */
export function collectPatch(directory, baseline) {
  git(directory, ['add', '-A']);
  return {
    patch: git(directory, ['diff', '--cached', '--binary', baseline]),
    stat: git(directory, ['diff', '--cached', '--stat', baseline]),
  };
}

export function removeWorkingCopy(directory) {
  rmSync(directory, { recursive: true, force: true, maxRetries: 3 });
}

/** Returns the files added, removed, or changed between two fingerprints. */
export function compareFingerprints(before, after) {
  const changed = new Set();
  for (const [file, value] of after) {
    if (before.get(file) !== value) {
      changed.add(file);
    }
  }
  for (const file of before.keys()) {
    if (!after.has(file)) {
      changed.add(file);
    }
  }
  return [...changed].sort();
}

function killTree(child) {
  if (process.platform === 'win32') {
    spawnSync('taskkill', ['/pid', String(child.pid), '/T', '/F'], { windowsHide: true });
  } else {
    child.kill('SIGKILL');
  }
}

/**
 * Runs a helper in the project directory. Its answer is printed once it finishes, with
 * project paths made relative. Resolves with the exit code to report.
 */
export function runHelper({ tool, command, args, projectDirectory, killAfterMs, cwd = projectDirectory }) {
  const before = takeFingerprint(projectDirectory);
  const relative = (text) => toRepoRelative(text, projectDirectory, cwd);

  return new Promise((resolve) => {
    let stdout = '';
    let failed = false;
    let timedOut = false;

    const child = spawn(command, args, {
      cwd,
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    });
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      process.stderr.write(relative(chunk));
    });

    const timer = setTimeout(() => {
      timedOut = true;
      console.error(`[invoke-helper] ${tool} did not finish in time and was stopped.`);
      killTree(child);
    }, killAfterMs);

    child.on('error', (error) => {
      console.error(`[invoke-helper] Could not start ${tool}: ${error.message}`);
      failed = true;
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      process.stdout.write(relative(stdout));
      if (stdout && !stdout.endsWith('\n')) {
        process.stdout.write('\n');
      }

      let exitCode = timedOut ? TIMEOUT_EXIT_CODE : (failed ? 1 : (code ?? 1));
      const changed = compareFingerprints(before, takeFingerprint(projectDirectory));
      if (changed.length > 0) {
        // Another agent working at the same time also shows up here.
        console.error(
          `[invoke-helper] Files in the working tree changed while ${tool} ran ` +
          `(another agent running at the same time would also cause this):`,
        );
        for (const file of changed.slice(0, 20)) {
          console.error(`  ${file}`);
        }
        if (changed.length > 20) {
          console.error(`  ...and ${changed.length - 20} more`);
        }
        exitCode = WORKTREE_CHANGED_EXIT_CODE;
      }
      resolve(exitCode);
    });
  });
}
