# DocForge Backend

Node.js/Express backend for **DocForge** – an IT documentation automation tool that takes raw environment data (Active Directory, GPO, SCCM, network configs) and uses the Claude API to generate professional Markdown documentation, then exports it to Word (.docx).

---

## Quick Start

```bash
# 1. Install dependencies
npm install

# 2. Create your .env file
cp .env.example .env

# 3. Add your Anthropic API key to .env
#    Open .env and set ANTHROPIC_API_KEY=sk-ant-api03-...

# 4. Start the server
npm start

# Development mode (auto-restart on file changes)
npm run dev
```

The server starts on **port 3001** by default (`http://localhost:3001`).

---

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `ANTHROPIC_API_KEY` | Yes | – | Anthropic API key from console.anthropic.com |
| `PORT` | No | `3001` | Port the server listens on |
| `ALLOWED_ORIGINS` | No | `localhost:3000, localhost:5173` | Comma-separated CORS origins |

---

## API Endpoints

### `GET /health`

Health check.

**Response:**
```json
{ "status": "ok", "version": "1.0.0", "timestamp": "2025-01-01T00:00:00.000Z" }
```

---

### `POST /api/generate`

Streams Claude-generated IT documentation as a Server-Sent Events (SSE) response.

**Rate limit:** 20 requests per minute per IP.

**Request body:**
```json
{
  "docType": "network_overview",
  "envData": { ... },
  "apiKey": "sk-ant-..." 
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `docType` | string | Yes | One of the six doc types (see below) |
| `envData` | object | Yes | Raw IT environment data (AD export, network config, etc.) |
| `apiKey` | string | No | Per-request API key override (multi-tenant use) |

**Supported `docType` values:**

| Value | Output |
|---|---|
| `network_overview` | Network topology, subnets, DCs, DNS/DHCP, Mermaid diagram |
| `ad_runbook` | AD operations SOPs, FSMO, password policy, break-glass |
| `disaster_recovery` | RTO/RPO, recovery scenarios, failover Mermaid diagram |
| `onboarding` | New IT staff guide, key systems, common tasks |
| `security_audit` | Risk-rated findings, CIS/NIST gap table, remediation roadmap |
| `gpo_documentation` | GPO inventory, OU tree Mermaid diagram, policy analysis |

**Response:** `text/event-stream` – raw Anthropic SSE stream forwarded directly to the client.

**Example (curl):**
```bash
curl -N -X POST http://localhost:3001/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "docType": "network_overview",
    "envData": {
      "domain": "corp.example.com",
      "domain_controllers": [
        { "name": "DC01", "ip": "10.0.0.10", "site": "HQ", "os": "Windows Server 2022" }
      ],
      "sites": [{ "name": "HQ", "subnet": "10.0.0.0/24" }]
    }
  }'
```

---

### `POST /api/export/docx`

Converts a Markdown string to a formatted Word document (.docx) and streams the binary back.

**Request body:**
```json
{
  "content": "# My Document\n\nSome **bold** text...",
  "title": "Network Overview – ACME Corp",
  "filename": "network_overview_acme"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `content` | string | Yes | Markdown content to convert |
| `title` | string | Yes | Document title (appears at top of Word doc) |
| `filename` | string | No | Output filename without extension (defaults to `title`) |

**Response:** `application/vnd.openxmlformats-officedocument.wordprocessingml.document`
with `Content-Disposition: attachment; filename="<filename>.docx"`

**Markdown features converted:**
- Headings (`#` – `######`) → Word heading styles
- Unordered lists (`-`, `*`, `+`) → Word bullet lists (nested)
- Ordered lists (`1.`, `2.`) → Word numbered lists (nested)
- Fenced code blocks (` ``` `) → Courier New paragraphs with grey background
- Tables (`| col | col |`) → Word tables with styled header row
- Inline `**bold**`, `*italic*`, `` `code` ``
- Horizontal rules (`---`)

---

## Architecture Notes

- **Smart data segmentation:** Before sending to Claude, `envData` is filtered to only include fields relevant to the requested `docType`. This reduces token usage significantly (e.g. `network_overview` strips user/GPO data; `security_audit` strips DNS/DHCP topology data).
- **Streaming proxy:** The Anthropic SSE stream is piped directly to the client with no buffering, enabling real-time token-by-token display in the frontend.
- **No API key in browser:** The Anthropic key lives only in the server's environment. Frontend never sees it.
- **Multi-tenant override:** Enterprise builds can pass `apiKey` per-request to support per-customer billing isolation.

---

## Dependencies

| Package | Purpose |
|---|---|
| `express` | HTTP server framework |
| `cors` | Cross-Origin Resource Sharing |
| `helmet` | Security headers |
| `morgan` | HTTP request logging |
| `express-rate-limit` | Rate limiting |
| `docx` | Word document generation |
| `nodemon` (dev) | Auto-restart on file changes |

Node.js built-in `fetch` is used for the Anthropic API call (requires Node 18+).
