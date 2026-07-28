import type { Argv } from "yargs"
import { createServer } from "http"
import { AddressInfo } from "net"
import open from "open"

/**
 * `understudy oauth-token --issuer <url>` — mint a Worklyn access token via
 * OAuth 2.1 (dynamic client registration + PKCE + loopback redirect).
 *
 * This is the command named by `<issuer>/.well-known/opencode`'s
 * `auth.command`. opencode SPAWNS it and reads the token off **stdout**, so
 * the single hard rule here is:
 *
 *     stdout carries the token and nothing else.
 *
 * Every byte of progress, prompting and error reporting goes to stderr. A
 * stray console.log in this file corrupts the credential silently — which is
 * far worse than failing — hence `note()` rather than any logger.
 *
 * Flow (server half is shipped and covered by yangu's bomba/auth_e2e_test.ts):
 *
 *   POST <issuer>/oauth/register            → client_id            (RFC 7591)
 *   GET  <issuer>/oauth/authorize?…         → browser consent
 *   → 302 back to http://127.0.0.1:<port>/callback?code=…
 *   → we 302 the browser on to <issuer>/oauth/connected?client_id=…  (branded)
 *   POST <issuer>/oauth/token               → access_token (mcpat_…)
 *
 * The loopback port is ephemeral (bound on :0) and registered per-run, so
 * nothing needs a fixed port reserved and two concurrent logins cannot
 * collide.
 */

/** Scopes the CLI needs: read the user's atoms + spend their LLM quota. */
const SCOPE = "atom:read llm"

const CLIENT_NAME = "understudy"

/** How long we wait for the human. Beyond this, tell them how to retry. */
const TIMEOUT_MS = 5 * 60 * 1000

// ── stderr-only user feedback ────────────────────────────────────
// Deliberately not UI/Prompt: those write to stdout.

const DIM = "\x1b[2m"
const BOLD = "\x1b[1m"
const RESET = "\x1b[0m"
const GREEN = "\x1b[32m"
const RED = "\x1b[31m"

function note(msg = "") {
  process.stderr.write(msg + "\n")
}

/** Braille spinner on stderr; no-op when stderr isn't a TTY (CI, pipes). */
function spinner(label: string) {
  if (!process.stderr.isTTY) {
    note(`${DIM}… ${label}${RESET}`)
    return { stop: (_final?: string) => {} }
  }
  const frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  let i = 0
  const timer = setInterval(() => {
    process.stderr.write(`\r${DIM}${frames[i++ % frames.length]} ${label}${RESET}\x1b[K`)
  }, 80)
  return {
    stop(final?: string) {
      clearInterval(timer)
      process.stderr.write(`\r\x1b[K`)
      if (final) note(final)
    },
  }
}

// ── PKCE ─────────────────────────────────────────────────────────

function b64url(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

async function pkce() {
  const verifier = b64url(crypto.getRandomValues(new Uint8Array(64)))
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))
  return { verifier, challenge: b64url(new Uint8Array(digest)) }
}

// ── loopback listener ────────────────────────────────────────────

interface Captured {
  code: string
}

/**
 * Bind an ephemeral loopback listener and resolve with the authorization
 * code. The browser is sent on to the issuer's branded confirmation page so
 * the user gets a real "you're connected" screen rather than a bare local
 * response — the contract roadmap/cli-connect-flow.md specifies.
 */
function listenForCode(issuer: string, clientIdRef: { current: string }) {
  let resolve!: (v: Captured) => void
  let reject!: (e: Error) => void
  const promise = new Promise<Captured>((res, rej) => {
    resolve = res
    reject = rej
  })

  const server = createServer((req, res) => {
    const url = new URL(req.url || "/", "http://127.0.0.1")
    if (url.pathname !== "/callback") {
      res.writeHead(404).end()
      return
    }

    const error = url.searchParams.get("error")
    if (error) {
      const description = url.searchParams.get("error_description") || error
      // Denied/failed: keep the user in the browser, on our page, with the
      // reason — not on a dead localhost tab.
      res.writeHead(302, { location: `${issuer}/oauth/connected?error=${encodeURIComponent(description)}` }).end()
      reject(new Error(description))
      return
    }

    const code = url.searchParams.get("code")
    if (!code) {
      res.writeHead(400, { "content-type": "text/plain" }).end("missing code")
      reject(new Error("authorization response carried no code"))
      return
    }

    res
      .writeHead(302, {
        location: `${issuer}/oauth/connected?client_id=${encodeURIComponent(clientIdRef.current)}`,
      })
      .end()
    resolve({ code })
  })

  const ready = new Promise<string>((res) => {
    // :0 → the OS picks a free port. 127.0.0.1 (not localhost) so we never
    // bind ::1 and get a redirect_uri the server can't match.
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address() as AddressInfo
      res(`http://127.0.0.1:${port}/callback`)
    })
  })

  return { promise, ready, close: () => server.close() }
}

// ── HTTP helpers ─────────────────────────────────────────────────

async function registerClient(issuer: string, redirectUri: string): Promise<string> {
  const res = await fetch(`${issuer}/oauth/register`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ client_name: CLIENT_NAME, redirect_uris: [redirectUri] }),
  })
  if (!res.ok) {
    throw new Error(`client registration failed (${res.status}): ${(await res.text()).slice(0, 200)}`)
  }
  const body = (await res.json()) as { client_id?: string }
  if (!body.client_id) throw new Error("client registration returned no client_id")
  return body.client_id
}

async function exchangeCode(input: {
  issuer: string
  code: string
  verifier: string
  clientId: string
  redirectUri: string
}): Promise<string> {
  const res = await fetch(`${input.issuer}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code: input.code,
      code_verifier: input.verifier,
      client_id: input.clientId,
      redirect_uri: input.redirectUri,
    }).toString(),
  })
  const body = (await res.json().catch(() => ({}))) as { access_token?: string; error_description?: string }
  if (!res.ok || !body.access_token) {
    throw new Error(`token exchange failed (${res.status}): ${body.error_description ?? "no access_token"}`)
  }
  return body.access_token
}

// ── command ──────────────────────────────────────────────────────

interface Args {
  issuer: string
}

export const OauthTokenCommand = {
  command: "oauth-token",
  // Hidden: this is spawned by opencode's well-known auth flow, not a
  // command humans are meant to discover.
  describe: false as const,
  builder: (yargs: Argv) =>
    yargs.option("issuer", {
      describe: "Worklyn deployment to authenticate against",
      type: "string" as const,
      default: "https://worklyn.me",
    }),
  async handler(args: Args) {
    const issuer = args.issuer.replace(/\/+$/, "")
    const clientIdRef = { current: "" }
    const listener = listenForCode(issuer, clientIdRef)

    try {
      const redirectUri = await listener.ready

      note()
      note(`${BOLD}Connect understudy to Worklyn${RESET}`)
      note(`${DIM}${issuer}${RESET}`)
      note()

      const reg = spinner("registering this device")
      clientIdRef.current = await registerClient(issuer, redirectUri)
      reg.stop()

      const { verifier, challenge } = await pkce()
      const authorizeUrl =
        `${issuer}/oauth/authorize?` +
        new URLSearchParams({
          client_id: clientIdRef.current,
          redirect_uri: redirectUri,
          code_challenge: challenge,
          code_challenge_method: "S256",
          response_type: "code",
          scope: SCOPE,
        })

      note(`${DIM}Opening your browser to approve access…${RESET}`)
      note(`${DIM}If it doesn't open, paste this:${RESET}`)
      note(`  ${authorizeUrl}`)
      note()
      await open(authorizeUrl).catch(() => undefined)

      const wait = spinner("waiting for you to approve in the browser")
      let captured: Captured
      try {
        captured = await Promise.race([
          listener.promise,
          new Promise<never>((_, rej) =>
            setTimeout(() => rej(new Error("timed out waiting for approval")), TIMEOUT_MS),
          ),
        ])
      } finally {
        wait.stop()
      }

      const ex = spinner("completing sign-in")
      const token = await exchangeCode({
        issuer,
        code: captured.code,
        verifier,
        clientId: clientIdRef.current,
        redirectUri,
      })
      ex.stop(`${GREEN}✓${RESET} Connected to Worklyn`)
      note()

      // THE payload. Nothing else may ever be written to stdout.
      process.stdout.write(token)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      note()
      note(`${RED}✗${RESET} ${message}`)
      note(`${DIM}Run \`understudy auth login ${issuer}\` to try again.${RESET}`)
      note()
      process.exitCode = 1
    } finally {
      listener.close()
    }
  },
}
