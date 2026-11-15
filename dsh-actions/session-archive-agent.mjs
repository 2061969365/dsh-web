import crypto from 'node:crypto'
import fs from 'node:fs'
import net from 'node:net'
import path from 'node:path'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)
const ROOT = process.env.DSH_HOME
const RUN_DIR = process.env.RUN_DIR
const STATE_REPO = process.env.STATE_REPO
const STATE_TAG = process.env.STATE_TAG || 'dsh-state'
const TOKEN = process.env.SESSION_ARCHIVE_TOKEN || process.env.STATE_REPO_TOKEN || ''
const SOCKET = RUN_DIR ? path.join(RUN_DIR, 'session-archive.sock') : ''
const LOG = RUN_DIR ? path.join(RUN_DIR, 'session-archive.log') : ''

if (!ROOT || !RUN_DIR || !SOCKET) {
  throw new Error('DSH_HOME and RUN_DIR are required')
}

const SAFE_ID = /^[A-Za-z0-9._-]+$/
const SAFE_PATH = /^sessions\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/
const SAFE_RELEASE = /^[A-Za-z0-9._-]+$/
const SAFE_ASSET = /^[A-Za-z0-9._-]+$/
const SHA256 = /^[0-9a-f]{64}$/
const locks = new Map()

function log(message) {
  const line = `[${new Date().toISOString()}] ${message}\n`
  try {
    fs.appendFileSync(LOG, line, { mode: 0o600 })
  } catch {
    process.stderr.write(line)
  }
}

function readIndex() {
  try {
    return JSON.parse(fs.readFileSync(path.join(ROOT, '.session-archive', 'index.json'), 'utf8'))
  } catch {
    return { sessions: {} }
  }
}

function currentLog(directory) {
  try {
    const names = fs.readdirSync(directory)
      .filter(name => /^session\.v[0-9]+\.jsonl(?:\.zstd)?$/.test(name))
      .sort()
    if (names.length === 0) return null
    const preferred = names.find(name => name === 'session.v4.jsonl.zstd')
      ?? names.find(name => name === 'session.v4.jsonl')
      ?? names[names.length - 1]
    return path.join(directory, preferred)
  } catch {
    return null
  }
}

function sha256(file) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256')
    fs.createReadStream(file)
      .on('data', chunk => hash.update(chunk))
      .on('end', () => resolve(hash.digest('hex')))
      .on('error', reject)
  })
}

function enoughDisk(bytes) {
  try {
    const stat = fs.statfsSync(ROOT)
    return Number(stat.bavail) * Number(stat.bsize) > bytes * 2 + 512 * 1024 * 1024
  } catch {
    return true
  }
}

async function run(command, args, options = {}) {
  const result = await execFileAsync(command, args, {
    timeout: 10 * 60 * 1000,
    maxBuffer: 16 * 1024 * 1024,
    ...options,
    env: { ...process.env, ...options.env },
  })
  if (result.stderr) log(`${command} stderr: ${result.stderr.trim().slice(0, 2000)}`)
  return result
}

async function restore(id, entry) {
  if (!SAFE_ID.test(id) || !SAFE_PATH.test(entry.path) || !SAFE_RELEASE.test(entry.release)
      || !SAFE_ASSET.test(entry.asset) || !SHA256.test(entry.sha256)) {
    throw new Error('archive index entry is invalid')
  }
  const target = path.resolve(ROOT, entry.path)
  const root = path.resolve(ROOT)
  if (!target.startsWith(`${root}${path.sep}`)) throw new Error('archive path escapes DSH_HOME')
  const fullBytes = Number(entry.full_bytes)
  if (!Number.isSafeInteger(fullBytes) || fullBytes <= 0) throw new Error('archive full_bytes is invalid')

  const present = currentLog(target)
  if (present && fs.statSync(present).size >= fullBytes) return { ok: true, status: 'present' }

  if (!STATE_REPO) throw new Error('STATE_REPO is not configured')
  if (!TOKEN) throw new Error('no state token is configured for the archive agent')
  if (!enoughDisk(fullBytes)) throw new Error('not enough free disk space to restore the archived session')

  const temporary = fs.mkdtempSync(path.join(RUN_DIR, 'session-restore-'))
  try {
    log(`restoring ${id} from ${entry.release}/${entry.asset}`)
    await run('gh', [
      'release', 'download', entry.release,
      '--repo', STATE_REPO,
      '--pattern', entry.asset,
      '--dir', temporary,
      '--clobber',
    ], { env: { GH_TOKEN: TOKEN, GH_PROMPT_DISABLED: '1' } })

    const archive = path.join(temporary, entry.asset)
    if (!fs.existsSync(archive)) throw new Error(`archive asset ${entry.asset} was not downloaded`)
    if ((await sha256(archive)) !== entry.sha256) throw new Error('archive asset SHA-256 mismatch')

    const extract = path.join(temporary, 'extract')
    fs.mkdirSync(extract)
    await run('tar', ['--zstd', '-xpf', archive, '-C', extract, '--no-same-owner'])

    const relative = entry.path.split('/').slice(1)
    const extracted = path.join(extract, ...relative)
    const extractedLog = currentLog(extracted)
    if (!extractedLog || fs.statSync(extractedLog).size < fullBytes) {
      throw new Error('extracted session log is missing or smaller than the archive index')
    }

    fs.rmSync(target, { recursive: true, force: true })
    fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 })
    fs.renameSync(extracted, target)
    fs.chmodSync(target, 0o700)
    for (const name of fs.readdirSync(target)) {
      try {
        fs.chmodSync(path.join(target, name), 0o600)
      } catch {
        // Directories and special files keep their extracted modes.
      }
    }
    const restoredLog = currentLog(target)
    if (restoredLog) {
      const now = new Date()
      fs.utimesSync(restoredLog, now, now)
    }
    log(`restored ${id} (${fullBytes} bytes)`)
    return { ok: true, status: 'restored' }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}

function withLock(id, operation) {
  const previous = locks.get(id) ?? Promise.resolve()
  const next = previous.catch(() => {}).then(operation)
  locks.set(id, next)
  next.finally(() => {
    if (locks.get(id) === next) locks.delete(id)
  }).catch(() => {})
  return next
}

async function handle(id) {
  if (typeof id !== 'string' || !SAFE_ID.test(id)) {
    return { ok: false, error: 'invalid session id' }
  }
  const index = readIndex()
  const entry = index?.sessions?.[id]
  if (entry === undefined) return { ok: true, status: 'present' }
  try {
    return await withLock(id, () => restore(id, entry))
  } catch (error) {
    log(`restore ${id} failed: ${error instanceof Error ? error.message : String(error)}`)
    return { ok: false, error: error instanceof Error ? error.message : String(error) }
  }
}

const server = net.createServer(socket => {
  socket.setEncoding('utf8')
  let buffer = ''
  let settled = false
  const reply = value => {
    if (settled) return
    settled = true
    socket.end(`${JSON.stringify(value)}\n`)
  }
  socket.on('data', chunk => {
    buffer += chunk
    if (buffer.length > 4096) {
      reply({ ok: false, error: 'request is too large' })
      return
    }
    const end = buffer.indexOf('\n')
    if (end < 0) return
    try {
      const request = JSON.parse(buffer.slice(0, end))
      void handle(request?.id).then(reply, error => {
        reply({ ok: false, error: error instanceof Error ? error.message : String(error) })
      })
    } catch {
      reply({ ok: false, error: 'invalid request JSON' })
    }
  })
  socket.on('error', error => log(`socket error: ${error.message}`))
})

function shutdown() {
  try {
    server.close()
  } catch {
    // The server may not have started.
  }
  try {
    fs.rmSync(SOCKET, { force: true })
  } catch {
    // Best effort.
  }
  process.exit(0)
}

process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
process.on('exit', () => {
  try {
    fs.rmSync(SOCKET, { force: true })
  } catch {
    // Best effort.
  }
})

fs.rmSync(SOCKET, { force: true })
server.listen(SOCKET, () => {
  fs.chmodSync(SOCKET, 0o600)
  log(`listening on ${SOCKET} (release ${STATE_TAG})`)
})
