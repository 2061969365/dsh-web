import fs from 'node:fs'
import net from 'node:net'
import path from 'node:path'

const REQUEST_TIMEOUT_MS = 10 * 60 * 1000

function archivedIds() {
  const home = process.env.DSH_HOME
  if (!home) return new Set()
  try {
    const document = JSON.parse(fs.readFileSync(path.join(home, '.session-archive', 'index.json'), 'utf8'))
    return new Set(Object.keys(document?.sessions ?? {}))
  } catch {
    return new Set()
  }
}

function restore(socketPath, id) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath)
    let buffer = ''
    let settled = false
    const finish = (error, value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      socket.destroy()
      if (error) reject(error)
      else resolve(value)
    }
    const timer = setTimeout(() => finish(new Error('session archive restore timed out')), REQUEST_TIMEOUT_MS)
    socket.setEncoding('utf8')
    socket.on('connect', () => socket.write(`${JSON.stringify({ id })}\n`))
    socket.on('data', chunk => {
      buffer += chunk
      const end = buffer.indexOf('\n')
      if (end < 0) return
      try {
        const result = JSON.parse(buffer.slice(0, end))
        if (result?.ok === true) finish(undefined, result)
        else finish(new Error(String(result?.error ?? 'session archive restore failed')))
      } catch (error) {
        finish(error instanceof Error ? error : new Error(String(error)))
      }
    })
    socket.on('error', error => finish(error))
    socket.on('close', () => {
      if (!settled) finish(new Error('session archive agent closed the connection'))
    })
  })
}

export const name = 'session-archive'
export const inject = ['sessionPersistence']

export function apply(ctx) {
  const service = ctx.sessionPersistence
  if (!service || typeof service.open !== 'function') {
    console.error('session-archive: sessionPersistence.open is not available')
    return
  }
  const original = service.open.bind(service)
  const archived = archivedIds()
  ctx.effect(() => {
    try {
      service.open = async (id, access, options) => {
        const key = String(id)
        if (archived.has(key)) {
          const socketPath = process.env.DSH_SESSION_ARCHIVE_SOCKET
          if (!socketPath) {
            throw new Error(`session ${key} is archived but DSH_SESSION_ARCHIVE_SOCKET is not set`)
          }
          await restore(socketPath, key)
          archived.delete(key)
        }
        return original(id, access, options)
      }
    } catch (error) {
      console.error(`session-archive: cannot patch sessionPersistence.open: ${error instanceof Error ? error.message : String(error)}`)
      return () => {}
    }
    return () => {
      try {
        service.open = original
      } catch {
        // Best effort when the service is being disposed.
      }
    }
  })
}
