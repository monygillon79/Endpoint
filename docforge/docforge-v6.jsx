import { useState, useCallback, useRef, useEffect } from "react";

// ─── Constants ────────────────────────────────────────────────────────────────
const MODEL = "claude-opus-4-20250514";

const DOC_TYPES = [
  { id: "network_overview",  label: "Network Overview & Diagram",  icon: "🌐", color: "#0ea5e9" },
  { id: "ad_runbook",        label: "AD Administration Runbook",    icon: "📘", color: "#8b5cf6" },
  { id: "disaster_recovery", label: "Disaster Recovery Plan",       icon: "🛡️", color: "#ef4444" },
  { id: "onboarding",        label: "Environment Onboarding Guide", icon: "🚀", color: "#10b981" },
  { id: "security_audit",    label: "Security Posture Report",      icon: "🔒", color: "#f59e0b" },
  { id: "gpo_documentation", label: "GPO Documentation",            icon: "📋", color: "#6366f1" },
];

const PROMPTS = {
  network_overview: `You are an IT documentation specialist. Generate a professional Network Overview document based on the provided IT environment data. Include:
1. Executive Summary (2-3 sentences)
2. Network Architecture — topology, sites, subnets, connectivity
3. Domain Controller Deployment — all DCs, roles, site assignments
4. DNS & DHCP Infrastructure — zones, forwarders, scopes with utilization
5. Replication Topology — site links, costs, frequency
6. Network Diagram (Mermaid graph TD showing sites, DCs, subnets, connections)
7. Recommendations — issues or improvements identified
Format in Markdown. Mermaid diagrams in \`\`\`mermaid blocks.`,

  ad_runbook: `You are an IT documentation specialist. Generate a professional Active Directory Administration Runbook. Include:
1. Environment Overview — domain, forest, functional levels
2. User Account Management — create/modify/disable/delete SOPs referencing actual OU structure
3. Group Management — naming conventions, group types observed
4. Computer Account Management — join procedures, OU placement
5. Password Policy Reference — actual policies in effect
6. Domain Controller Maintenance — health checks, FSMO roles, transfer procedures
7. Break-Glass Procedures — emergency access, DC recovery
8. Appendix: Key Distinguished Names and OU paths from the environment
Format in Markdown.`,

  disaster_recovery: `You are an IT documentation specialist. Generate a professional Disaster Recovery Plan. Include:
1. Executive Summary
2. Scope & Objectives — RTO/RPO based on infrastructure observed
3. Critical Infrastructure Inventory — DCs, DNS, DHCP, key servers
4. Risk Assessment — single points of failure identified in the data
5. Recovery Procedures: single DC failure, complete site failure, AD database corruption, DNS/DHCP failure, network connectivity loss
6. Backup Requirements based on the environment
7. Communication Plan template
8. Testing Schedule recommendation
9. Network Recovery Diagram (Mermaid showing failover paths)
Format in Markdown.`,

  onboarding: `You are an IT documentation specialist. Generate an Environment Onboarding Guide for new IT staff. Include:
1. Welcome & Environment Overview — domain, sites, scale
2. Architecture at a Glance — topology and Mermaid diagram
3. Key Infrastructure — DCs, DNS, DHCP with IPs and roles
4. Active Directory Structure — OU layout, group naming, user/computer counts
5. Group Policy Overview — key policies and enforcement
6. Network Layout — sites, subnets
7. Common Tasks Quick Reference — where to find things, key tools
8. Security Policies — password requirements, lockout policy
9. Escalation & Contacts template
Format in Markdown with a friendly but professional tone.`,

  security_audit: `You are an IT security analyst. Generate a Security Posture Report. Include:
1. Executive Summary with overall risk rating (Critical/High/Medium/Low)
2. Findings Summary Table (finding, severity, affected count)
3. Detailed Findings — analyze: stale/inactive accounts (90+ days), non-expiring passwords, locked accounts, legacy OS, unlinked/disabled GPOs, password policy strength, FSMO distribution, trust risks, firewall analysis, privileged group membership, service accounts
4. Compliance Gaps mapped to NIST 800-53 and CIS Benchmarks with control IDs
5. Prioritized Remediation Roadmap with effort estimates
Use actual numbers from the data. Format in Markdown.`,

  gpo_documentation: `You are an IT documentation specialist. Generate comprehensive Group Policy Documentation. Include:
1. GPO Inventory — all policies with status, version, and link targets
2. GPO Linkage Map — Mermaid diagram showing OU tree with GPO links
3. Policy Categories — security, configuration, software deployment
4. Unlinked/Disabled Policies — flag for cleanup review
5. WMI Filters in use
6. Policy Precedence Notes — potential conflicts
7. Settings Summary — key configuration settings found (if available)
8. Recommendations — cleanup candidates, missing policies
9. Change Management template for GPO modifications
Format in Markdown.`,
};

// ─── Smart Segmentation ───────────────────────────────────────────────────────
// Send only sections relevant to each doc type — avoids truncation and cuts token cost
function segmentData(data, docType) {
  const ad = data.active_directory;
  const gp = data.group_policy;
  const net = data.network;
  const sc = data.sccm;
  const meta = data.metadata;

  // Summarised AD (no full accounts arrays for network/DR docs)
  const adMeta = ad ? {
    domain: ad.domain, domain_controllers: ad.domain_controllers, sites: ad.sites,
    organizational_units: ad.organizational_units,
    users: ad?.users ? { total_count: ad.users.total_count, enabled_count: ad.users.enabled_count, disabled_count: ad.users.disabled_count, locked_count: ad.users.locked_count, password_never_expires_count: ad.users.password_never_expires_count, stale_90_days: ad.users.stale_90_days } : null,
    groups: ad?.groups ? { total_count: ad.groups.total_count, security_count: ad.groups.security_count, distribution_count: ad.groups.distribution_count, groups: ad.groups.groups } : null,
    computers: ad?.computers ? { total_count: ad.computers.total_count, enabled_count: ad.computers.enabled_count, os_summary: ad.computers.os_summary, stale_90_days: ad.computers.stale_90_days } : null,
    password_policies: ad.password_policies, trusts: ad.trusts,
  } : null;

  switch (docType) {
    case "network_overview":
      return { metadata: meta, domain: ad?.domain, domain_controllers: ad?.domain_controllers, sites: ad?.sites, dns: net?.dns, dhcp: net?.dhcp, adapters: net?.adapters, routes: net?.routes, sccm_site: sc?.site };
    case "ad_runbook":
      return { metadata: meta, active_directory: adMeta, group_policy: { summary: gp?.summary, policies: gp?.policies } };
    case "disaster_recovery":
      return { metadata: meta, domain: ad?.domain, domain_controllers: ad?.domain_controllers, sites: ad?.sites, dns: net?.dns, dhcp: net?.dhcp, sccm: sc ? { site: sc.site, devices: { total_count: sc.devices?.total_count, client_installed: sc.devices?.client_installed } } : null };
    case "onboarding":
      return { metadata: meta, active_directory: adMeta, group_policy: { summary: gp?.summary, policies: gp?.policies }, network: { dns: net?.dns, dhcp: net?.dhcp, adapters: net?.adapters }, sccm: sc ? { site: sc.site } : null };
    case "security_audit":
      return { metadata: meta, users: ad?.users, computers: ad?.computers, password_policies: ad?.password_policies, trusts: ad?.trusts, privileged_groups: ad?.privileged_groups, service_accounts: ad?.service_accounts, group_policy: { summary: gp?.summary, policies: gp?.policies, unlinked_gpos: gp?.unlinked_gpos }, firewall: net?.firewall, sccm: sc ? { patch_compliance: sc.patch_compliance, bitlocker_status: sc.bitlocker_status, software_inventory: sc.software_inventory } : null };
    case "gpo_documentation":
      return { metadata: meta, organizational_units: ad?.organizational_units, group_policy: gp };
    default:
      return data;
  }
}

// ─── Merge Two Collections ────────────────────────────────────────────────────
function mergeCollections(base, overlay) {
  const merged = JSON.parse(JSON.stringify(base));
  ["active_directory", "group_policy", "sccm", "network"].forEach(f => {
    if (!merged[f] && overlay[f]) { merged[f] = overlay[f]; return; }
    if (merged[f] && overlay[f]) {
      Object.keys(overlay[f]).forEach(k => {
        if (merged[f][k] == null && overlay[f][k] != null) merged[f][k] = overlay[f][k];
      });
    }
  });
  merged.metadata = {
    ...merged.metadata, merged: true,
    merge_date: new Date().toISOString(),
    sources: [base.metadata?.collection_machine, overlay.metadata?.collection_machine].filter(Boolean),
    modules_completed: [...new Set([...(base.metadata?.modules_completed || []), ...(overlay.metadata?.modules_completed || [])])],
  };
  return merged;
}

// ─── Shared Styles ────────────────────────────────────────────────────────────
const codeStyle = { background: "#0f172a", border: "1px solid #1e293b", borderRadius: 8, padding: 16, overflowX: "auto", fontSize: 13, lineHeight: 1.5, color: "#e2e8f0", marginBottom: 16 };

function inlineFmt(s) {
  return s
    .replace(/\*\*(.+?)\*\*/g, '<strong style="color:#f1f5f9;font-weight:600">$1</strong>')
    .replace(/\*(.+?)\*/g, "<em>$1</em>")
    .replace(/`([^`]+)`/g, '<code style="background:#1e293b;color:#93c5fd;padding:2px 6px;border-radius:4px;font-size:0.85em">$1</code>');
}

// ─── Mermaid Renderer ─────────────────────────────────────────────────────────
function MermaidDiagram({ code }) {
  const [svg, setSvg] = useState("");
  const [err, setErr] = useState(null);
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        if (!window.mermaid) {
          const s = document.createElement("script");
          s.src = "https://cdnjs.cloudflare.com/ajax/libs/mermaid/10.9.1/mermaid.min.js";
          await new Promise((res, rej) => { s.onload = res; s.onerror = rej; document.head.appendChild(s); });
          window.mermaid.initialize({ startOnLoad: false, theme: "dark", themeVariables: { primaryColor: "#1e3a5f", primaryTextColor: "#e2e8f0", primaryBorderColor: "#3b82f6", lineColor: "#64748b", secondaryColor: "#1e293b", tertiaryColor: "#0f172a" } });
        }
        const id = "mm-" + Math.random().toString(36).slice(2);
        const { svg: r } = await window.mermaid.render(id, code);
        if (!cancelled) setSvg(r);
      } catch (e) { if (!cancelled) setErr(e.message); }
    })();
    return () => { cancelled = true; };
  }, [code]);
  if (err) return <pre style={codeStyle}>{code}</pre>;
  if (!svg) return <div style={{ padding: 32, textAlign: "center", color: "#64748b" }}>Rendering diagram…</div>;
  return <div dangerouslySetInnerHTML={{ __html: svg }} style={{ display: "flex", justifyContent: "center", padding: "16px 0", overflow: "auto" }} />;
}

// ─── Markdown Renderer ────────────────────────────────────────────────────────
function MarkdownText({ text }) {
  const lines = text.split("\n"), els = [];
  let list = [], listType = null, codeBlock = null, tableRows = [];

  const flushList = () => {
    if (!list.length) return;
    const T = listType === "ol" ? "ol" : "ul";
    els.push(<T key={els.length} style={{ marginBottom: 12, paddingLeft: 24, color: "#cbd5e1" }}>{list.map((item, i) => <li key={i} style={{ marginBottom: 4, lineHeight: 1.6 }} dangerouslySetInnerHTML={{ __html: inlineFmt(item) }} />)}</T>);
    list = []; listType = null;
  };

  const flushTable = () => {
    if (!tableRows.length) return;
    const hdrs = tableRows[0], body = tableRows.slice(2);
    els.push(
      <div key={els.length} style={{ overflowX: "auto", marginBottom: 16 }}>
        <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13 }}>
          <thead><tr>{hdrs.map((h, i) => <th key={i} style={{ padding: "8px 12px", background: "#1e293b", color: "#93c5fd", borderBottom: "2px solid #334155", textAlign: "left", fontWeight: 600 }}>{h.trim()}</th>)}</tr></thead>
          <tbody>{body.map((row, ri) => <tr key={ri}>{row.map((cell, ci) => <td key={ci} style={{ padding: "6px 12px", borderBottom: "1px solid #1e293b", color: "#cbd5e1" }}>{cell.trim()}</td>)}</tr>)}</tbody>
        </table>
      </div>
    );
    tableRows = [];
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith("```") && !codeBlock) { flushList(); flushTable(); codeBlock = { lines: [] }; continue; }
    if (codeBlock) { if (line.startsWith("```")) { els.push(<pre key={els.length} style={codeStyle}><code>{codeBlock.lines.join("\n")}</code></pre>); codeBlock = null; } else codeBlock.lines.push(line); continue; }
    if (line.includes("|") && line.trim().startsWith("|")) {
      flushList();
      const cells = line.split("|").filter((_, idx, arr) => idx > 0 && idx < arr.length - 1);
      tableRows.push(cells); continue;
    } else { flushTable(); }
    const ul = line.match(/^(\s*)[-*]\s+(.*)/), ol = line.match(/^(\s*)\d+\.\s+(.*)/);
    if (ul) { if (listType !== "ul") flushList(); listType = "ul"; list.push(ul[2]); continue; }
    if (ol) { if (listType !== "ol") flushList(); listType = "ol"; list.push(ol[2]); continue; }
    flushList();
    if (/^#{1,6}\s/.test(line)) {
      const lvl = line.match(/^(#+)/)[1].length, txt = line.replace(/^#+\s*/, "");
      const sz = [28, 22, 18, 16, 14, 13][lvl - 1], clr = ["#60a5fa", "#93c5fd", "#bfdbfe", "#e2e8f0", "#cbd5e1", "#94a3b8"][lvl - 1];
      els.push(<div key={els.length} style={{ fontSize: sz, fontWeight: lvl <= 2 ? 700 : 600, color: clr, marginTop: lvl <= 2 ? 32 : 20, marginBottom: lvl <= 2 ? 16 : 10, borderBottom: lvl <= 2 ? "1px solid #1e293b" : "none", paddingBottom: lvl <= 2 ? 10 : 0 }} dangerouslySetInnerHTML={{ __html: inlineFmt(txt) }} />);
      continue;
    }
    if (line.trim() === "---" || line.trim() === "***") { els.push(<hr key={els.length} style={{ border: "none", borderTop: "1px solid #1e293b", margin: "24px 0" }} />); continue; }
    if (line.trim() === "") { els.push(<div key={els.length} style={{ height: 8 }} />); continue; }
    els.push(<p key={els.length} style={{ color: "#cbd5e1", lineHeight: 1.7, marginBottom: 8, fontSize: 14 }} dangerouslySetInnerHTML={{ __html: inlineFmt(line) }} />);
  }
  flushList(); flushTable();
  return <>{els}</>;
}

function RenderMarkdown({ content }) {
  const parts = content.split(/(```mermaid[\s\S]*?```)/g);
  return (
    <div>
      {parts.map((p, i) => {
        const m = p.match(/```mermaid\n([\s\S]*?)```/);
        return m ? <MermaidDiagram key={i} code={m[1].trim()} /> : <MarkdownText key={i} text={p} />;
      })}
    </div>
  );
}

// ─── Environment Overview ─────────────────────────────────────────────────────
function EnvironmentOverview({ data }) {
  const ad = data.active_directory, gp = data.group_policy, sc = data.sccm;
  const stats = [
    { label: "Domain",    value: ad?.domain?.dns_root || "—",      sub: ad?.domain?.domain_mode,                                  color: "#3b82f6" },
    { label: "Users",     value: ad?.users?.total_count || 0,       sub: `${ad?.users?.enabled_count || 0} enabled`,               color: "#10b981" },
    { label: "Computers", value: ad?.computers?.total_count || 0,   sub: `${ad?.computers?.os_summary?.length || 0} OS types`,     color: "#8b5cf6" },
    { label: "DCs",       value: ad?.domain_controllers?.length || 0, sub: `${ad?.sites?.sites?.length || 0} sites`,               color: "#f59e0b" },
    { label: "GPOs",      value: gp?.summary?.total_count || 0,     sub: `${gp?.summary?.enabled_count || 0} active`,              color: "#6366f1" },
    { label: "Groups",    value: ad?.groups?.total_count || 0,      sub: `${ad?.groups?.security_count || 0} security`,            color: "#ec4899" },
    ...(sc ? [{ label: "SCCM Devices", value: sc.devices?.total_count || 0,   sub: `${sc.devices?.client_installed || 0} with client`, color: "#14b8a6" }] : []),
    ...(sc ? [{ label: "Applications", value: sc.applications?.length || 0,   sub: `${sc.collections?.device_collections?.length || 0} collections`, color: "#f97316" }] : []),
  ];
  return (
    <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))", gap: 12, marginBottom: 24 }}>
      {stats.map((s, i) => (
        <div key={i} style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: 12, padding: "14px 16px", borderTop: `3px solid ${s.color}` }}>
          <div style={{ fontSize: 11, fontWeight: 600, color: "#64748b", textTransform: "uppercase", letterSpacing: "0.08em", marginBottom: 6 }}>{s.label}</div>
          <div style={{ fontSize: 22, fontWeight: 700, color: "#f1f5f9", letterSpacing: "-0.02em" }}>{typeof s.value === "number" ? s.value.toLocaleString() : s.value}</div>
          <div style={{ fontSize: 11, color: "#64748b", marginTop: 2 }}>{s.sub}</div>
        </div>
      ))}
    </div>
  );
}

// ─── Settings Modal ───────────────────────────────────────────────────────────
function SettingsModal({ apiKey, backendUrl, onSave, onClose }) {
  const [key, setKey] = useState(apiKey);
  const [url, setUrl] = useState(backendUrl);
  const inp = { width: "100%", background: "#1e293b", border: "1px solid #334155", borderRadius: 8, padding: "10px 14px", color: "#e2e8f0", fontSize: 13, outline: "none", boxSizing: "border-box" };
  const lbl = { display: "block", fontSize: 11, fontWeight: 600, color: "#64748b", textTransform: "uppercase", letterSpacing: "0.06em", marginBottom: 8 };
  return (
    <div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.75)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 1000 }} onClick={onClose}>
      <div style={{ background: "#0f172a", border: "1px solid #334155", borderRadius: 16, padding: 32, width: 460, maxWidth: "90vw" }} onClick={e => e.stopPropagation()}>
        <div style={{ fontSize: 18, fontWeight: 700, color: "#f1f5f9", marginBottom: 24 }}>⚙️ Settings</div>
        <div style={{ marginBottom: 20 }}>
          <label style={lbl}>Anthropic API Key <span style={{ color: "#475569", fontWeight: 400, textTransform: "none" }}>(held in memory only)</span></label>
          <input value={key} onChange={e => setKey(e.target.value)} type="password" placeholder="sk-ant-api03-…" style={inp} />
        </div>
        <div style={{ marginBottom: 28 }}>
          <label style={lbl}>Backend URL <span style={{ color: "#475569", fontWeight: 400, textTransform: "none" }}>(optional — leave blank for direct API)</span></label>
          <input value={url} onChange={e => setUrl(e.target.value)} placeholder="http://localhost:3001" style={inp} />
          <div style={{ marginTop: 6, fontSize: 11, color: "#475569" }}>Point to your DocForge backend server to proxy API calls and enable .docx export.</div>
        </div>
        <div style={{ display: "flex", gap: 10, justifyContent: "flex-end" }}>
          <button onClick={onClose} style={{ background: "#1e293b", border: "1px solid #334155", color: "#94a3b8", padding: "8px 18px", borderRadius: 8, cursor: "pointer", fontSize: 13 }}>Cancel</button>
          <button onClick={() => onSave(key, url)} style={{ background: "linear-gradient(135deg,#1d4ed8,#3b82f6)", border: "none", color: "#fff", padding: "8px 18px", borderRadius: 8, cursor: "pointer", fontSize: 13, fontWeight: 600 }}>Save</button>
        </div>
      </div>
    </div>
  );
}

// ─── Main App ─────────────────────────────────────────────────────────────────
export default function DocForge() {
  const [envData,      setEnvData]      = useState(null);
  const [apiKey,       setApiKey]       = useState("");
  const [backendUrl,   setBackendUrl]   = useState("");
  const [showSettings, setShowSettings] = useState(false);
  const [selectedDoc,  setSelectedDoc]  = useState(null);
  const [generating,   setGenerating]   = useState(false);
  const [streamText,   setStreamText]   = useState("");
  const [error,        setError]        = useState(null);
  const [dragOver,     setDragOver]     = useState(false);
  const docCache   = useRef(new Map());
  const fileInputRef = useRef(null);
  const mergeInputRef = useRef(null);
  const abortCtrl  = useRef(null);

  const parseJSON = file => new Promise((res, rej) => {
    const r = new FileReader();
    r.onload = e => { try { res(JSON.parse(e.target.result)); } catch { rej(new Error("Invalid JSON file.")); } };
    r.onerror = () => rej(new Error("Could not read file."));
    r.readAsText(file);
  });

  const isValidCollection = d => d && d.metadata && (d.active_directory || d.group_policy || d.network || d.sccm);

  const loadFile = useCallback(async file => {
    try {
      const parsed = await parseJSON(file);
      if (!isValidCollection(parsed)) { setError("Not a valid DocForge collection file. Expected metadata + at least one data module."); return; }
      setEnvData(parsed); setError(null); docCache.current.clear(); setSelectedDoc(null); setStreamText("");
    } catch (e) { setError(e.message); }
  }, []);

  const mergeFile = useCallback(async file => {
    if (!envData) return;
    try {
      const parsed = await parseJSON(file);
      if (!isValidCollection(parsed)) { setError("Not a valid DocForge collection file."); return; }
      setEnvData(mergeCollections(envData, parsed));
      docCache.current.clear(); setError(null);
    } catch (e) { setError(e.message); }
  }, [envData]);

  const handleDrop = useCallback(async e => {
    e.preventDefault(); setDragOver(false);
    const files = Array.from(e.dataTransfer.files).filter(f => f.name.endsWith(".json"));
    if (!files.length) return;
    if (!envData) {
      await loadFile(files[0]);
      if (files[1]) await mergeFile(files[1]);
    } else {
      await mergeFile(files[0]);
    }
  }, [envData, loadFile, mergeFile]);

  // ── Generate document with streaming ──────────────────────────────────────
  const generateDoc = async docType => {
    if (!apiKey && !backendUrl) { setShowSettings(true); setError("Configure your API key or backend URL first."); return; }

    // Serve from cache if available
    if (docCache.current.has(docType)) {
      setSelectedDoc(docType); setStreamText(docCache.current.get(docType)); return;
    }

    setSelectedDoc(docType); setGenerating(true); setStreamText(""); setError(null);
    if (abortCtrl.current) abortCtrl.current.abort();
    abortCtrl.current = new AbortController();

    const segmented = segmentData(envData, docType);
    const payload = JSON.stringify(segmented, null, 2);

    try {
      let response;
      if (backendUrl) {
        response = await fetch(`${backendUrl.replace(/\/$/, "")}/api/generate`, {
          method: "POST", signal: abortCtrl.current.signal,
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ docType, envData: segmented }),
        });
      } else {
        response = await fetch("https://api.anthropic.com/v1/messages", {
          method: "POST", signal: abortCtrl.current.signal,
          headers: { "Content-Type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01", "anthropic-dangerous-direct-browser-access": "true" },
          body: JSON.stringify({
            model: MODEL, max_tokens: 8192, stream: true,
            system: PROMPTS[docType],
            messages: [{ role: "user", content: `Here is the IT environment data. Generate the documentation:\n\n${payload}` }],
          }),
        });
      }

      if (!response.ok) {
        const errData = await response.json().catch(() => ({}));
        throw new Error(errData.error?.message || `API error ${response.status}`);
      }

      // ── SSE stream processing ──
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buf = "", full = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        const lines = buf.split("\n"); buf = lines.pop();
        for (const line of lines) {
          if (!line.startsWith("data: ")) continue;
          const chunk = line.slice(6).trim();
          if (chunk === "[DONE]") break;
          try {
            const parsed = JSON.parse(chunk);
            // Anthropic SSE: content_block_delta → delta.text
            const delta = parsed.type === "content_block_delta" && parsed.delta?.type === "text_delta"
              ? parsed.delta.text : "";
            if (delta) { full += delta; setStreamText(t => t + delta); }
          } catch { /* skip malformed lines */ }
        }
      }
      docCache.current.set(docType, full);
    } catch (e) {
      if (e.name !== "AbortError") setError(`Generation failed: ${e.message}`);
    } finally {
      setGenerating(false);
    }
  };

  // ── Export helpers ────────────────────────────────────────────────────────
  const downloadBlob = (blob, filename) => {
    const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = filename; a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  };

  const exportMarkdown = () => {
    const content = docCache.current.get(selectedDoc) || streamText;
    const name = DOC_TYPES.find(d => d.id === selectedDoc)?.label.replace(/\s+/g, "_") || selectedDoc;
    downloadBlob(new Blob([content], { type: "text/markdown" }), `${name}.md`);
  };

  const exportHTML = () => {
    const content = docCache.current.get(selectedDoc) || streamText;
    const label = DOC_TYPES.find(d => d.id === selectedDoc)?.label || selectedDoc;
    const name = label.replace(/\s+/g, "_");
    // Word-compatible HTML — user can open in Word and Save As .docx
    const html = `<!DOCTYPE html><html><head><meta charset="utf-8"><title>${label}</title>
<style>
  body{font-family:Calibri,sans-serif;max-width:800px;margin:40px auto;color:#1a1a1a;line-height:1.6;font-size:11pt}
  h1{color:#1a3a6b;font-size:18pt;border-bottom:2pt solid #1a3a6b;padding-bottom:4pt;margin-top:24pt}
  h2{color:#1a3a6b;font-size:14pt;margin-top:18pt}h3{color:#2a5298;font-size:12pt;margin-top:14pt}
  table{border-collapse:collapse;width:100%;margin:12pt 0}td,th{border:1pt solid #ccc;padding:6pt 10pt;font-size:10pt}
  th{background:#1a3a6b;color:#fff;font-weight:bold}tr:nth-child(even){background:#f5f8ff}
  code{background:#f0f0f0;padding:1pt 4pt;border-radius:2pt;font-family:Courier New;font-size:9.5pt}
  pre{background:#f5f5f5;border:1pt solid #ddd;padding:10pt;border-radius:3pt;overflow-x:auto;font-family:Courier New;font-size:9pt}
  blockquote{border-left:3pt solid #1a3a6b;margin-left:0;padding-left:12pt;color:#555}
</style></head><body>
<h1>${label}</h1>
<p style="color:#666;font-size:9pt;margin-bottom:20pt">Generated by DocForge · ${new Date().toLocaleDateString()} · ${envData?.metadata?.collected_by || ""}</p>
${content
  .replace(/^# (.+)$/gm, "<h1>$1</h1>")
  .replace(/^## (.+)$/gm, "<h2>$1</h2>")
  .replace(/^### (.+)$/gm, "<h3>$1</h3>")
  .replace(/^#### (.+)$/gm, "<h4>$1</h4>")
  .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
  .replace(/\*(.+?)\*/g, "<em>$1</em>")
  .replace(/`([^`]+)`/g, "<code>$1</code>")
  .replace(/^---$/gm, "<hr>")
  .replace(/^[-*] (.+)$/gm, "<li>$1</li>")
  .replace(/(<li>.*<\/li>\n?)+/g, m => `<ul>${m}</ul>`)
  .replace(/\n\n/g, "</p><p>")
  .replace(/^(?!<[hpulio])/gm, "<p>").replace(/$(?!<\/[hpulio])/gm, "</p>")}
</body></html>`;
    downloadBlob(new Blob([html], { type: "text/html" }), `${name}.html`);
  };

  const exportDocx = async () => {
    if (!backendUrl) { setError("Connect a backend server to enable .docx export."); return; }
    const content = docCache.current.get(selectedDoc) || streamText;
    const label = DOC_TYPES.find(d => d.id === selectedDoc)?.label || selectedDoc;
    try {
      const r = await fetch(`${backendUrl.replace(/\/$/, "")}/api/export/docx`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ content, title: label, filename: selectedDoc }),
      });
      if (!r.ok) throw new Error(`Export failed: ${r.status}`);
      downloadBlob(await r.blob(), `${selectedDoc}.docx`);
    } catch (e) { setError(e.message); }
  };

  // ─── Shared style values ────────────────────────────────────────────────────
  const font = "'IBM Plex Sans','SF Pro Display',-apple-system,system-ui,sans-serif";
  const btnBase = { background: "#1e293b", border: "1px solid #334155", color: "#94a3b8", padding: "5px 12px", borderRadius: 6, cursor: "pointer", fontSize: 12, fontWeight: 500 };
  const currentContent = docCache.current.get(selectedDoc) || streamText;

  // ─── Landing screen ─────────────────────────────────────────────────────────
  if (!envData) {
    return (
      <div style={{ minHeight: "100vh", background: "#020617", color: "#e2e8f0", fontFamily: font, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", padding: 32 }}>
        <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@300;400;500;600;700&display=swap" rel="stylesheet" />
        {showSettings && <SettingsModal apiKey={apiKey} backendUrl={backendUrl} onSave={(k, u) => { setApiKey(k); setBackendUrl(u); setShowSettings(false); }} onClose={() => setShowSettings(false)} />}

        <div style={{ textAlign: "center", maxWidth: 640, width: "100%" }}>
          <div style={{ display: "inline-flex", alignItems: "center", gap: 12, marginBottom: 32 }}>
            <div style={{ width: 48, height: 48, background: "linear-gradient(135deg,#3b82f6,#1d4ed8)", borderRadius: 12, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 22, fontWeight: 700, color: "#fff", boxShadow: "0 0 32px rgba(59,130,246,0.3)" }}>D</div>
            <span style={{ fontSize: 32, fontWeight: 700, letterSpacing: "-0.03em", color: "#f1f5f9" }}>DocForge</span>
          </div>
          <p style={{ fontSize: 18, color: "#94a3b8", marginBottom: 48, lineHeight: 1.6, fontWeight: 300 }}>Transform raw IT environment data into<br />professional documentation in seconds.</p>

          <div
            onDrop={handleDrop}
            onDragOver={e => { e.preventDefault(); setDragOver(true); }}
            onDragLeave={() => setDragOver(false)}
            onClick={() => fileInputRef.current?.click()}
            style={{ border: `2px dashed ${dragOver ? "#3b82f6" : "#1e293b"}`, borderRadius: 16, padding: "48px 32px", cursor: "pointer", background: dragOver ? "rgba(59,130,246,0.05)" : "#0f172a", transition: "all 0.2s", marginBottom: 20 }}
          >
            <input ref={fileInputRef} type="file" accept=".json" multiple onChange={e => { const fs = Array.from(e.target.files); if (fs[0]) loadFile(fs[0]).then(() => fs[1] && mergeFile(fs[1])); }} style={{ display: "none" }} />
            <div style={{ fontSize: 40, marginBottom: 16 }}>📁</div>
            <div style={{ fontSize: 16, fontWeight: 500, marginBottom: 8 }}>Drop your DocForge collection JSON here</div>
            <div style={{ fontSize: 13, color: "#64748b" }}>Drop 2 files to auto-merge · generated by Collect-ITEnvironment.ps1</div>
          </div>

          <button onClick={() => setShowSettings(true)} style={{ ...btnBase, padding: "10px 24px", fontSize: 13, width: "100%", justifyContent: "center" }}>⚙️ Configure API Key / Backend URL</button>
          {(apiKey || backendUrl) && <div style={{ marginTop: 8, fontSize: 12, color: "#34d399" }}>✓ {backendUrl ? `Backend: ${backendUrl}` : "Direct API configured"}</div>}
          {error && <div style={{ marginTop: 16, padding: "12px 16px", background: "rgba(239,68,68,0.1)", border: "1px solid rgba(239,68,68,0.3)", borderRadius: 8, color: "#fca5a5", fontSize: 13 }}>{error}</div>}
        </div>
      </div>
    );
  }

  // ─── Main dashboard ─────────────────────────────────────────────────────────
  return (
    <div style={{ minHeight: "100vh", background: "#020617", color: "#e2e8f0", fontFamily: font }}>
      <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@300;400;500;600;700&display=swap" rel="stylesheet" />
      <style>{`@keyframes spin{to{transform:rotate(360deg)}}@keyframes pulse{0%,100%{opacity:1}50%{opacity:0.4}}`}</style>
      {showSettings && <SettingsModal apiKey={apiKey} backendUrl={backendUrl} onSave={(k, u) => { setApiKey(k); setBackendUrl(u); setShowSettings(false); }} onClose={() => setShowSettings(false)} />}

      {/* ── Header ── */}
      <div style={{ borderBottom: "1px solid #1e293b", padding: "13px 24px", display: "flex", alignItems: "center", justifyContent: "space-between", background: "#0f172a", position: "sticky", top: 0, zIndex: 50 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <div style={{ width: 30, height: 30, background: "linear-gradient(135deg,#3b82f6,#1d4ed8)", borderRadius: 7, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 14, fontWeight: 700, color: "#fff" }}>D</div>
          <span style={{ fontSize: 17, fontWeight: 700, letterSpacing: "-0.02em" }}>DocForge</span>
          {envData.metadata?.merged && <span style={{ fontSize: 10, background: "rgba(16,185,129,0.15)", color: "#34d399", border: "1px solid rgba(16,185,129,0.25)", borderRadius: 10, padding: "2px 8px" }}>MERGED</span>}
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <span style={{ fontSize: 11, color: "#475569" }}>{envData.metadata?.collection_machine} · {new Date(envData.metadata?.collection_date).toLocaleDateString()}</span>
          <button onClick={() => setShowSettings(true)} style={btnBase}>⚙️</button>
          <button onClick={() => mergeInputRef.current?.click()} style={btnBase}>+ Merge</button>
          <input ref={mergeInputRef} type="file" accept=".json" onChange={e => e.target.files[0] && mergeFile(e.target.files[0])} style={{ display: "none" }} />
          <button onClick={() => { setEnvData(null); setStreamText(""); setSelectedDoc(null); docCache.current.clear(); }} style={btnBase}>↩ New</button>
        </div>
      </div>

      <div style={{ maxWidth: 1280, margin: "0 auto", padding: 24, display: "flex", gap: 24, alignItems: "flex-start" }}>

        {/* ── Sidebar ── */}
        <div style={{ width: 240, flexShrink: 0, position: "sticky", top: 70 }}>
          <div style={{ fontSize: 10, fontWeight: 600, color: "#64748b", textTransform: "uppercase", letterSpacing: "0.08em", marginBottom: 10 }}>Documents</div>
          {DOC_TYPES.map(dt => {
            const cached = docCache.current.has(dt.id);
            const active = selectedDoc === dt.id;
            return (
              <button key={dt.id} onClick={() => generateDoc(dt.id)} disabled={generating && !active}
                style={{ display: "flex", alignItems: "center", gap: 9, width: "100%", background: active ? "rgba(59,130,246,0.12)" : "transparent", border: `1px solid ${active ? "#3b82f6" : "transparent"}`, borderRadius: 8, padding: "9px 11px", cursor: generating && !active ? "not-allowed" : "pointer", marginBottom: 3, textAlign: "left", transition: "all 0.12s", opacity: generating && !active ? 0.45 : 1 }}>
                <span style={{ fontSize: 15 }}>{dt.icon}</span>
                <span style={{ flex: 1, fontSize: 12, color: active ? "#93c5fd" : "#94a3b8", fontWeight: active ? 600 : 400, lineHeight: 1.3 }}>{dt.label}</span>
                {cached && !active && <div style={{ width: 6, height: 6, borderRadius: "50%", background: "#10b981", flexShrink: 0 }} title="Cached — instant load" />}
                {active && generating && <div style={{ width: 12, height: 12, border: "2px solid #1e293b", borderTopColor: "#3b82f6", borderRadius: "50%", animation: "spin 0.7s linear infinite", flexShrink: 0 }} />}
              </button>
            );
          })}

          {/* Collection info */}
          <div style={{ marginTop: 20, padding: 14, background: "#0f172a", border: "1px solid #1e293b", borderRadius: 10, fontSize: 11 }}>
            <div style={{ fontWeight: 600, color: "#475569", marginBottom: 8, textTransform: "uppercase", fontSize: 10, letterSpacing: "0.06em" }}>Modules</div>
            {(envData.metadata?.modules_completed || []).map(m => <div key={m} style={{ color: "#34d399", marginBottom: 3 }}>✓ {m}</div>)}
            {(envData.metadata?.warnings || []).slice(0, 4).map((w, i) => <div key={i} style={{ color: "#f59e0b", marginBottom: 3 }}>⚠ {w.module}</div>)}
            {(envData.metadata?.errors || []).slice(0, 4).map((e, i) => <div key={i} style={{ color: "#f87171", marginBottom: 3 }}>✗ {e.module}</div>)}
          </div>
        </div>

        {/* ── Main panel ── */}
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 10, fontWeight: 600, color: "#64748b", textTransform: "uppercase", letterSpacing: "0.08em", marginBottom: 12 }}>Environment Overview</div>
          <EnvironmentOverview data={envData} />

          {/* Warnings banner */}
          {(envData.metadata?.warnings || []).length > 0 && (
            <div style={{ background: "rgba(245,158,11,0.07)", border: "1px solid rgba(245,158,11,0.2)", borderRadius: 8, padding: "10px 14px", marginBottom: 16, fontSize: 12, color: "#fbbf24" }}>
              ⚠️ {envData.metadata.warnings.slice(0, 3).map(w => `${w.module}: ${w.message}`).join(" · ")}
            </div>
          )}

          {/* Placeholder */}
          {!selectedDoc && !error && (
            <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: 12, padding: "56px 32px", textAlign: "center", color: "#475569" }}>
              <div style={{ fontSize: 36, marginBottom: 12 }}>📄</div>
              <div style={{ fontSize: 15, color: "#64748b" }}>Select a document type from the sidebar to generate documentation</div>
              <div style={{ fontSize: 12, color: "#334155", marginTop: 8 }}>Each doc type queries only the relevant sections of your environment data</div>
            </div>
          )}

          {/* Error banner */}
          {error && <div style={{ background: "rgba(239,68,68,0.07)", border: "1px solid rgba(239,68,68,0.2)", borderRadius: 8, padding: "12px 16px", marginBottom: 16, color: "#fca5a5", fontSize: 13 }}>{error}</div>}

          {/* Document output (streaming or cached) */}
          {(generating || currentContent) && (
            <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: 12, overflow: "hidden" }}>
              {/* Doc toolbar */}
              <div style={{ borderBottom: "1px solid #1e293b", padding: "12px 18px", display: "flex", alignItems: "center", justifyContent: "space-between", background: "#0a0f1e" }}>
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  {generating
                    ? <div style={{ width: 8, height: 8, borderRadius: "50%", background: "#3b82f6", animation: "pulse 1s infinite" }} />
                    : <div style={{ width: 8, height: 8, borderRadius: "50%", background: "#10b981" }} />}
                  <span style={{ fontSize: 13, fontWeight: 600, color: "#e2e8f0" }}>{DOC_TYPES.find(d => d.id === selectedDoc)?.label}</span>
                  {currentContent && <span style={{ fontSize: 11, color: "#475569" }}>{(currentContent.length / 1024).toFixed(1)} KB</span>}
                  {generating && <span style={{ fontSize: 11, color: "#64748b", animation: "pulse 1.5s infinite" }}>Streaming…</span>}
                </div>
                {!generating && currentContent && (
                  <div style={{ display: "flex", gap: 6 }}>
                    <button onClick={() => { docCache.current.delete(selectedDoc); setStreamText(""); generateDoc(selectedDoc); }} style={btnBase}>↺</button>
                    <button onClick={exportMarkdown} style={btnBase}>⬇ .md</button>
                    <button onClick={exportHTML} style={{ ...btnBase, color: "#93c5fd" }}>⬇ .html</button>
                    {backendUrl && <button onClick={exportDocx} style={{ background: "linear-gradient(135deg,#1d4ed8,#3b82f6)", border: "none", color: "#fff", padding: "5px 12px", borderRadius: 6, cursor: "pointer", fontSize: 12, fontWeight: 600 }}>⬇ .docx</button>}
                  </div>
                )}
              </div>
              {/* Content */}
              <div style={{ padding: "24px 28px", maxHeight: "70vh", overflowY: "auto" }}>
                {currentContent
                  ? <RenderMarkdown content={currentContent} />
                  : <div style={{ color: "#475569", fontSize: 13 }}>Analyzing your environment data — first words appear in seconds…</div>}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
