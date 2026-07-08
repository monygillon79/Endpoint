# DocForge (web app)

Full-stack prototype that turns raw IT environment data into polished documentation. Upload the `.dfpkg`/JSON bundle produced by `Collect-ITEnvironment.ps1`, pick a document type (environment overview, AD structure, GPO reference, SCCM estate, network design), and DocForge streams a formatted document generated via the Anthropic Messages API.

## Components

| Path | Role |
|---|---|
| `backend/server.js` | Node 18+ Express server: upload handling (`.dfpkg` gzip decompression), smart data segmentation, streaming SSE proxy to the Messages API, document export |
| `backend/public/index.html` | Self-contained browser UI served by the backend |
| `docforge-v6.jsx` | React component version of the frontend (streaming, response caching, drop-2-files auto-merge) |
| `Start-DocForge.bat` | One-click local launcher: dependency check, `npm install`, server start, browser open at `http://localhost:3001` |
| `backend/README.md` | Full API reference for the backend |

## Design decisions

- **API key stays server-side** — the browser never sees it (`.env`, see `backend/.env.example`).
- **Smart segmentation:** the environment bundle is filtered to only the fields relevant to the requested document type before generation, keeping requests small and output focused.
- **Streaming end-to-end:** the SSE stream is piped to the client unbuffered, so long documents render token-by-token instead of after a multi-minute wait.
- **Auto-merge:** drop two collection files (e.g., AD-only + SCCM-only) and the frontend merges them into one environment view.

## Quick start

```
cd backend
npm install
cp .env.example .env    # add your API key
npm start               # http://localhost:3001
```

Or run `Start-DocForge.bat` from the project root on Windows.
