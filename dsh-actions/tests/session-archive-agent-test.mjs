import crypto from 'node:crypto'
import fs from 'node:fs'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import { execFileSync, spawn } from 'node:child_process'

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-agent-test-'))
const home = path.join(root, 'home')
const run = path.join(root, 'run')
const bin = path.join(root, 'bin')
const release = path.join(root, 'release')
const full = path.join(root, 'full')
const target = path.join(home, 'sessions', 'proj', 's1')
const socket = path.join(run, 'session-archive.sock')
for (const directory of [target, run, bin, release, path.join(full, 'sessions', 'proj', 's1')]) {
  fs.mkdirSync(directory, { recursive: true })
}

const fullJsonl = path.join(root, 'full.jsonl')
fs.writeFileSync(fullJsonl, '{"type":"session","id":"s1"}\n{"type":"event","i":1}\n{"type":"event","i":2}\n')
const fullLog = path.join(full, 'sessions', 'proj', 's1', 'session.v4.jsonl.zstd')
fs.writeFileSync(fullLog, execFileSync('zstd', ['-q', '-c', fullJsonl]))
fs.writeFileSync(path.join(full, 'sessions', 'proj', 's1', 'state.json'), '{"title":"archived"}\n')
fs.writeFileSync(path.join(target, 'state.json'), '{"title":"archived"}\n')
fs.writeFileSync(path.join(target, 'session.v4.jsonl.zstd'), execFileSync('zstd', ['-q', '-c', '{"type":"session","id":"s1"}\n']))
const fullBytes = fs.statSync(fullLog).size

const asset = `session-s1-${crypto.createHash('sha256').update(fs.readFileSync(fullLog)).digest('hex').slice(0, 16)}.tar.zst`
const assetPath = path.join(release, asset)
execFileSync('tar', ['-C', path.join(full, 'sessions'), '--zstd', '-cf', assetPath, 'proj/s1'])
const archiveSha = crypto.createHash('sha256').update(fs.readFileSync(assetPath)).digest('hex')
fs.mkdirSync(path.join(home, '.session-archive'), { recursive: true })
fs.writeFileSync(path.join(home, '.session-archive', 'index.json'), JSON.stringify({
  version: 1,
  sessions: {
    s1: {
      project: 'proj',
      path: 'sessions/proj/s1',
      release: 'test-state',
      asset,
      sha256: archiveSha,
      full_bytes: fullBytes,
      updated_at: '2026-01-01T00:00:00Z',
      archived_at: '2026-01-01T00:00:00Z',
    },
  },
}, null, 2))

const gh = path.join(bin, 'gh')
fs.writeFileSync(gh, `#!/bin/sh
set -eu
pattern=
dir=
while [ $# -gt 0 ]; do
  case "$1" in
    --pattern) pattern=$2; shift 2 ;;
    --dir) dir=$2; shift 2 ;;
    *) shift ;;
  esac
done
cp "${release}/$pattern" "$dir/$pattern"
`, { mode: 0o755 })

const agent = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', 'session-archive-agent.mjs')
const child = spawn(process.execPath, [agent], {
  env: {
    ...process.env,
    DSH_HOME: home,
    RUN_DIR: run,
    STATE_REPO: 'test/repo',
    STATE_TAG: 'test-state',
    SESSION_ARCHIVE_TOKEN: 'token',
    PATH: `${bin}${path.delimiter}${process.env.PATH ?? ''}`,
  },
  stdio: ['ignore', 'ignore', 'pipe'],
})
let stderr = ''
child.stderr.setEncoding('utf8')
child.stderr.on('data', chunk => { stderr += chunk })

async function waitForSocket() {
  for (let i = 0; i < 200; i += 1) {
    if (fs.existsSync(socket)) return
    if (child.exitCode !== null) throw new Error(`agent exited: ${stderr}`)
    await new Promise(resolve => setTimeout(resolve, 50))
  }
  throw new Error(`agent socket did not appear: ${stderr}`)
}

function request(id) {
  return new Promise((resolve, reject) => {
    const client = net.createConnection(socket)
    let buffer = ''
    client.setEncoding('utf8')
    client.on('connect', () => client.write(`${JSON.stringify({ id })}\n`))
    client.on('data', chunk => {
      buffer += chunk
      if (buffer.includes('\n')) {
        resolve(JSON.parse(buffer.slice(0, buffer.indexOf('\n'))))
        client.end()
      }
    })
    client.on('error', reject)
  })
}

try {
  await waitForSocket()
  const result = await request('s1')
  if (result.ok !== true || result.status !== 'restored') throw new Error(`unexpected response: ${JSON.stringify(result)}`)
  const restored = path.join(target, 'session.v4.jsonl.zstd')
  if (fs.statSync(restored).size !== fullBytes) throw new Error('restored log size mismatch')
  const text = execFileSync('zstd', ['-q', '-dc', restored], { encoding: 'utf8' })
  if (!text.includes('"i":2')) throw new Error('restored log is incomplete')
  console.log('session archive agent test passed')
} finally {
  child.kill('SIGTERM')
  fs.rmSync(root, { recursive: true, force: true })
}
