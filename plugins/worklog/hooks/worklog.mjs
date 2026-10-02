#!/usr/bin/env node
// Claude Code hook: after a turn that changed files, asks the session to log its work in the Obsidian vault.
// "snapshot" runs on UserPromptSubmit, "check" on Stop, "procedure" prints the procedure for /log-work.
import { execFileSync } from 'node:child_process';
import {
  copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync,
} from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const vault = process.env.AGENT_CAPSULE_VAULT_DEST || '/vault';
const stateDir = join(homedir(), '.claude', 'worklog');
const noise = [
  '**/*.lock', '**/go.sum', '**/package-lock.json', '**/pnpm-lock.yaml', '**/vendor/**', '**/*.pb.go',
  '**/zz_generated*',
].map((glob) => `:(exclude,glob)${glob}`);
const maxListed = 20;

const stripFrontmatter = (text) => text.replace(/^---\n[\s\S]*?\n---\n+/, '').trim();

function readProcedure() {
  const custom = process.env.AGENT_CAPSULE_WORKLOG_PROCEDURE;
  if (custom && existsSync(custom)) {
    const text = stripFrontmatter(readFileSync(custom, 'utf8'));
    if (text) return text;
  }
  return stripFrontmatter(readFileSync(new URL('../procedure.md', import.meta.url), 'utf8'));
}

function git(dir, args, env = {}) {
  return execFileSync('git', ['-C', dir, ...args], {
    encoding: 'utf8',
    env: { ...process.env, ...env },
    stdio: ['ignore', 'pipe', 'ignore'],
  }).trim();
}

// A throwaway index also captures untracked files and leaves the real index alone. Seeding it from the real one
// spares git from rehashing unchanged files.
function snapshot(top) {
  const dir = mkdtempSync(join(tmpdir(), 'worklog-'));
  const env = { GIT_INDEX_FILE: join(dir, 'index') };
  try {
    const index = git(top, ['rev-parse', '--path-format=absolute', '--git-path', 'index']);
    if (existsSync(index)) copyFileSync(index, env.GIT_INDEX_FILE);
    git(top, ['add', '-A'], env);
    return git(top, ['write-tree'], env);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function reason(top, numstat) {
  const rows = numstat.split('\n').map((row) => row.split('\t'));
  const listed = rows.slice(0, maxListed).map(([added, deleted, path]) =>
    added === '-' ? `- ${path} (binary)` : `- ${path} (+${added} -${deleted})`);
  if (rows.length > maxListed) listed.push(`- and ${rows.length - maxListed} more`);
  const today = execFileSync('date', ['+%A %F, ISO week %G-W%V'], { encoding: 'utf8' }).trim();
  return [
    `Stop hook: automatic work log. Today is ${today}.`,
    `Files changed in ${top} during this turn, lockfiles and generated files left out:`,
    ...listed,
    '',
    'First apply this test: does this work introduce a durable change to behavior, architecture, configuration or',
    'project knowledge that would be worth finding later? Formatting, line wrapping, typos, version bumps and',
    'reverted experiments do not pass. If it does not pass, reply only "Nothing to log." and stop. Otherwise log',
    'it with the procedure below, through the obsidian MCP tools only.',
    '',
    readProcedure(),
  ].join('\n');
}

const mode = process.argv[2];
if (mode === 'procedure') {
  process.stdout.write(`${readProcedure()}\n`);
  process.exit(0);
}
if (mode !== 'snapshot' && mode !== 'check') throw new Error('usage: worklog.mjs snapshot|check|procedure');

const input = JSON.parse(readFileSync(0, 'utf8'));
const sessionId = String(input.session_id ?? '');
if (!/^[\w-]+$/.test(sessionId)) process.exit(0);

let top;
try {
  top = git(input.cwd || process.cwd(), ['rev-parse', '--show-toplevel']);
} catch {
  process.exit(0);
}
// Logging edits the vault, which would then count as new work.
let vaultRoot = resolve(vault);
try {
  vaultRoot = realpathSync(vault);
} catch {
  // A missing vault cannot contain the repository.
}
if (`${top}/`.startsWith(`${vaultRoot}/`)) process.exit(0);

const stateFile = join(stateDir, sessionId);
const save = (state) => {
  mkdirSync(stateDir, { recursive: true });
  writeFileSync(stateFile, JSON.stringify(state));
};

if (mode === 'snapshot') {
  save({ top, tree: snapshot(top), skip: String(input.prompt ?? '').includes('#no-doc') });
} else {
  let base = null;
  try {
    base = JSON.parse(readFileSync(stateFile, 'utf8'));
  } catch {
    // No prompt seen yet in this session: this check only sets the baseline.
  }
  const tree = snapshot(top);
  // A turn can start without a prompt, when a background task ends: rebaseline so it does not see this work again.
  save({ top, tree, skip: false });
  if (!input.stop_hook_active && base?.top === top && !base.skip) {
    const numstat = git(top, ['-c', 'core.quotePath=false', 'diff', '--numstat', base.tree, tree, '--', '.', ...noise]);
    if (numstat) process.stdout.write(JSON.stringify({ decision: 'block', reason: reason(top, numstat) }));
  }
}
