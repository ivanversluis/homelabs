#!/usr/bin/env node
'use strict';

// Refresh only the Git-managed AGENTS.md section; preserve operator TUI edits.
const fs = require('node:fs');
const path = require('node:path');
const BEGIN = '<!-- BEGIN OPENCLAW-K8S-DIAGNOSTICS-GITOPS -->';
const END = '<!-- END OPENCLAW-K8S-DIAGNOSTICS-GITOPS -->';
function block(text, origin) {
  const a = text.indexOf(BEGIN);
  const b = text.indexOf(END);
  if (a < 0 || b < a || text.indexOf(BEGIN, a + BEGIN.length) !== -1 ||
      text.indexOf(END, b + END.length) !== -1) {
    throw new Error(origin + ': missing or duplicate GitOps markers');
  }
  return text.slice(a, b + END.length);
}
function sync(sourcePath, targetPath) {
  const source = fs.readFileSync(sourcePath, 'utf8');
  const managed = block(source, sourcePath);
  fs.mkdirSync(path.dirname(targetPath), { recursive: true });
  let output = source;
  if (fs.existsSync(targetPath)) {
    if (fs.lstatSync(targetPath).isSymbolicLink())
      throw new Error(targetPath + ': refusing symbolic link');
    const old = fs.readFileSync(targetPath, 'utf8');
    const a = old.indexOf(BEGIN), b = old.indexOf(END);
    if (a >= 0 || b >= 0) {
      block(old, targetPath);
      output = old.slice(0, a) + managed + old.slice(b + END.length);
    } else {
      output = old.replace(/\s*$/, '\n\n') + managed + '\n';
    }
    if (output === old) return;
  }
  const temp = targetPath + '.gitops-' + process.pid;
  try {
    fs.writeFileSync(temp, output, { mode: 0o600, flag: 'wx' });
    fs.renameSync(temp, targetPath);
  } finally {
    if (fs.existsSync(temp)) fs.unlinkSync(temp);
  }
}
if (require.main === module) {
  if (process.argv.length !== 4) {
    console.error('Usage: node sync-agents.js <Git AGENTS.md> <workspace AGENTS.md>');
    process.exitCode = 2;
  } else {
    try { sync(process.argv[2], process.argv[3]); }
    catch (e) { console.error(e.message); process.exitCode = 1; }
  }
}
module.exports = { sync, BEGIN, END };
