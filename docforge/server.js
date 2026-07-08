/**
 * DocForge Backend Server
 * IT documentation automation powered by Claude AI.
 *
 * Provides:
 *   POST /api/generate      – Streaming proxy to Anthropic Claude
 *   POST /api/export/docx   – Markdown → Word (.docx) export
 *   GET  /health            – Health check
 */

"use strict";

const path = require("path");
const express = require("express");
const cors = require("cors");
const helmet = require("helmet");
const morgan = require("morgan");
const rateLimit = require("express-rate-limit");
const {
  Document,
  Packer,
  Paragraph,
  TextRun,
  HeadingLevel,
  AlignmentType,
  Table,
  TableRow,
  TableCell,
  WidthType,
  BorderStyle,
  ShadingType,
} = require("docx");

// ---------------------------------------------------------------------------
// App setup
// ---------------------------------------------------------------------------

const app = express();
const PORT = process.env.PORT || 3001;

// Allowed CORS origins – extend via ALLOWED_ORIGINS env var (comma-separated)
const defaultOrigins = [
  `http://localhost:${process.env.PORT || 3001}`,
  "http://localhost:3000",
  "http://localhost:5173",
];
const allowedOrigins = process.env.ALLOWED_ORIGINS
  ? process.env.ALLOWED_ORIGINS.split(",").map((o) => o.trim())
  : defaultOrigins;

// ---------------------------------------------------------------------------
// Middleware
// ---------------------------------------------------------------------------

// Security headers – relaxed CSP so the embedded React app can load CDN resources
app.use(
  helmet({
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'self'"],
        scriptSrc: [
          "'self'",
          "'unsafe-inline'",  // Babel standalone needs this
          "'unsafe-eval'",    // Babel standalone needs this
          "https://unpkg.com",
          "https://cdnjs.cloudflare.com",
        ],
        styleSrc: ["'self'", "'unsafe-inline'", "https://fonts.googleapis.com"],
        fontSrc: ["'self'", "https://fonts.gstatic.com"],
        imgSrc: ["'self'", "data:"],
        connectSrc: [
          "'self'",
          "https://api.anthropic.com",
          "https://fonts.googleapis.com",
        ],
      },
    },
  })
);

// CORS
app.use(
  cors({
    origin: (origin, callback) => {
      // Allow same-origin requests (no Origin header), server-to-server calls,
      // curl, and any explicitly whitelisted origin.
      if (!origin || allowedOrigins.includes(origin)) {
        callback(null, true);
      } else {
        console.warn(`[CORS] Blocked request from origin: ${origin}`);
        callback(new Error(`CORS: origin '${origin}' not allowed`));
      }
    },
    methods: ["GET", "POST", "OPTIONS"],
    allowedHeaders: ["Content-Type", "Authorization"],
    credentials: true,
  })
);

// HTTP request logging
app.use(morgan("combined"));

// JSON body parsing – 50 MB to accommodate large environment data payloads
app.use(express.json({ limit: "50mb" }));

// ---------------------------------------------------------------------------
// Rate limiting – 20 requests / minute per IP on generation endpoint
// ---------------------------------------------------------------------------

const generateLimiter = rateLimit({
  windowMs: 60 * 1000, // 1 minute
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  message: {
    error: "Too many requests. Please wait before generating more documents.",
  },
});

// ---------------------------------------------------------------------------
// System Prompts
// ---------------------------------------------------------------------------

const SYSTEM_PROMPTS = {
  /**
   * Network topology overview: subnets, sites, DCs, DNS/DHCP, replication,
   * and a Mermaid diagram of the physical/logical layout.
   */
  network_overview: `You are a senior network architect producing professional IT infrastructure documentation for an enterprise environment.

Using the environment data provided, generate a comprehensive **Network Overview** document in Markdown format. The document must include:

1. **Executive Summary** – A concise paragraph describing the overall network architecture.
2. **Network Topology** – IP addressing scheme, VLAN layout, subnet allocation table (Name | Subnet | Gateway | VLAN ID | Purpose).
3. **Sites & Connectivity** – All physical/logical sites, WAN links, bandwidth, redundancy.
4. **Domain Controllers** – Hostnames, IP addresses, site assignments, OS versions, roles (FSMO if applicable).
5. **DNS Architecture** – Internal zones, forwarders, conditional forwarders, resolution flow.
6. **DHCP Infrastructure** – Scopes, lease duration, exclusions, failover configuration.
7. **AD Replication Topology** – Site links, replication intervals, schedules. Include a Mermaid diagram:
   \`\`\`mermaid
   graph TD
     ...
   \`\`\`
8. **Mermaid Network Diagram** – High-level logical diagram showing sites, DCs, and connectivity.
9. **Known Issues & Recommendations** – Bullet list of gaps or risks observed in the data.

Use professional IT documentation language. Format all tables using Markdown table syntax. Be specific – use actual hostnames, IPs, and values from the data provided, not placeholders.`,

  /**
   * Active Directory operations runbook: SOPs for day-to-day AD tasks,
   * password policy, FSMO roles, and break-glass procedures.
   */
  ad_runbook: `You are a senior Active Directory architect producing an operational runbook for IT administrators.

Using the environment data provided, generate a detailed **Active Directory Operations Runbook** in Markdown format. Include:

1. **Environment Overview** – Forest/domain structure, functional levels, trust relationships.
2. **FSMO Roles** – Table of all five FSMO roles: holder, IP, site, and transfer procedure.
3. **User Account Management SOPs**
   - Create new user (step-by-step with PowerShell examples)
   - Disable/delete user on offboarding
   - Unlock account / reset password
   - Group membership management
4. **Group Management SOPs** – Security vs. distribution groups, nesting rules, naming convention.
5. **Computer Object Management** – Join domain, move OU, remote wipe, stale object cleanup.
6. **Password & Lockout Policy** – Current policy table, how to modify via Fine-Grained Password Policies.
7. **Group Policy Overview** – Key GPOs, link order, precedence notes.
8. **Privileged Access & Break-Glass Procedures**
   - DA/EA account usage policy
   - Break-glass account location, how to activate, audit log review
9. **Routine Maintenance Checklist** – Weekly/monthly tasks (replication health, event log review, tombstone monitoring).
10. **Escalation Contacts** – Roles and responsibilities table.

Include PowerShell code blocks for all scriptable steps. Be specific to the environment data provided.`,

  /**
   * Disaster recovery plan: RTO/RPO, critical system inventory,
   * step-by-step recovery procedures, and Mermaid failover diagram.
   */
  disaster_recovery: `You are a senior IT resilience architect producing a Disaster Recovery Plan for an Active Directory environment.

Using the environment data provided, generate a comprehensive **Disaster Recovery Plan** in Markdown format. Include:

1. **Executive Summary** – Scope, objectives, and DR strategy overview.
2. **RTO / RPO Targets** – Table per system tier (Tier 0: DCs/AD, Tier 1: DNS/DHCP, Tier 2: File/App servers).
3. **Critical System Inventory** – All DCs and key servers with role, OS, IP, site, backup frequency.
4. **Recovery Team & Contacts** – RACI table: roles, responsibilities, contact info placeholders.
5. **Scenario A – Single Domain Controller Failure**
   - Detection, containment, recovery steps (PowerShell where applicable)
   - Estimated recovery time
6. **Scenario B – Site Failure / WAN Outage**
   - Steps to promote secondary site, redirect clients, validate replication
   - Mermaid failover diagram showing traffic rerouting
7. **Scenario C – AD Forest / Domain Corruption**
   - Authoritative restore procedure (step-by-step with DSRM boot)
   - USN rollback mitigation
   - Full forest rebuild from backup
8. **Backup & Recovery Infrastructure** – Backup targets, retention, tested restore procedures.
9. **DR Test Plan** – Quarterly test checklist, success criteria, sign-off template.
10. **Return to Normal Operations** – Steps to failback, replication validation, user communication.

Include PowerShell and command-line examples throughout. Use actual data from the environment provided.`,

  /**
   * IT staff onboarding guide: architecture orientation, key systems,
   * common tasks, tooling, and security policies for new hires.
   */
  onboarding: `You are a senior IT architect producing an onboarding guide for new IT staff joining the organization.

Using the environment data provided, generate a comprehensive **IT Staff Onboarding Guide** in Markdown format. Include:

1. **Welcome & Orientation** – Team structure, communication channels, escalation path.
2. **Environment Architecture Overview** – Domain structure, site map, key server inventory table.
3. **Access & Credentials**
   - Required accounts and how to request access
   - MFA enrollment steps
   - VPN / remote access setup
4. **Key Systems Inventory** – Table: System | Role | URL/IP | Notes
5. **Day-to-Day Tools**
   - Management consoles (ADUC, GPMC, SCCM/Intune, DNS Manager, DHCP Console)
   - Ticketing system and workflow
   - Monitoring dashboards
6. **Common Tasks (First 30 Days)**
   - Shadow a user provisioning request
   - Run a software deployment
   - Review replication and event logs
   - Attend change advisory board (CAB)
7. **Security Policies & Compliance**
   - Acceptable use, least-privilege, change management
   - Incident response – who to call, how to log
   - Data classification overview
8. **Gotchas & Tribal Knowledge** – Known quirks, legacy systems, things that often go wrong.
9. **Resources & Documentation Index** – Links to runbooks, vendor portals, internal wikis.

Write in a friendly but professional tone suitable for an experienced IT professional joining a new team.`,

  /**
   * Security audit report: risk-rated findings, stale accounts,
   * legacy OS, GPO weaknesses, CIS/NIST gaps, and remediation roadmap.
   */
  security_audit: `You are a senior cybersecurity consultant producing a formal IT Security Audit Report.

Using the environment data provided, generate a comprehensive **Security Audit Report** in Markdown format. Include:

1. **Audit Summary** – Scope, methodology, audit date, overall risk rating (Critical/High/Medium/Low).
2. **Executive Findings Summary** – Table: Finding | Risk | Affected Systems | Recommendation
3. **Identity & Access Management**
   - Stale user accounts (>90 days inactive) – list with last logon dates
   - Accounts with non-expiring passwords
   - Privileged account inventory (Domain Admins, Enterprise Admins)
   - Service accounts review
4. **Endpoint Security**
   - Legacy OS inventory (EOL Windows versions) with risk rating
   - Missing patch levels
   - BitLocker / encryption coverage
5. **Group Policy Security Analysis**
   - Missing or misconfigured security baselines
   - Unlinked or disabled GPOs
   - Password & lockout policy gaps vs. CIS Benchmark
6. **Network Security**
   - Firewall rule issues (overly permissive rules, any/any)
   - Exposed management ports
   - Network segmentation gaps
7. **Compliance Gap Analysis** – Table mapping findings to CIS Controls v8 and NIST CSF 2.0 functions.
8. **Detailed Finding Sheets** – For each Critical/High finding:
   - Description, Evidence, Risk, Recommendation, Remediation Steps, Owner
9. **Remediation Roadmap** – Prioritized 30/60/90-day action plan table.
10. **Positive Observations** – Controls working well.

Use risk ratings: CRITICAL | HIGH | MEDIUM | LOW | INFORMATIONAL. Be specific with data from the environment.`,

  /**
   * GPO documentation: full policy inventory, OU linkage map,
   * Mermaid OU tree, policy categories, and change management template.
   */
  gpo_documentation: `You are a senior Active Directory engineer producing comprehensive Group Policy documentation.

Using the environment data provided, generate a detailed **Group Policy Documentation** report in Markdown format. Include:

1. **Executive Summary** – Number of GPOs, overall policy health, key observations.
2. **GPO Inventory Table** – Full table: GPO Name | GUID | Status | Link Count | Last Modified | Description
3. **OU Structure & GPO Linkage Map**
   - Mermaid diagram showing OU hierarchy with linked GPOs:
   \`\`\`mermaid
   graph TD
     Domain["domain.com"]
     Domain --> OU_Computers["OU: Computers"]
     Domain --> OU_Users["OU: Users"]
   \`\`\`
4. **Policy Categories & Analysis**
   - Security Settings (password, lockout, audit, UAC, firewall)
   - Software Deployment (assigned vs. published)
   - User Configuration (logon scripts, drive maps, desktop restrictions)
   - Administrative Templates (browser, Office, Windows Update)
5. **Problematic Policies**
   - Unlinked GPOs (wasteful, potential confusion)
   - Disabled GPOs still in inventory
   - GPOs with no settings (empty shell)
   - Conflicting policies (same setting defined in multiple GPOs)
6. **WMI Filters** – Inventory and validation of WMI filter logic.
7. **Security Filtering & Delegation** – Non-standard ACLs, loopback processing.
8. **Policy Change Management Template** – Blank table for tracking future changes (Date | GPO | Change | Approver | Tested | Rollback Plan).
9. **Recommendations** – Prioritized list of improvements.

Be specific to the GPO data provided. Include actual GPO names, GUIDs, and linked OUs.`,
};

// ---------------------------------------------------------------------------
// Smart data segmentation
// Extracts only the fields relevant to each doc type to reduce token usage.
// ---------------------------------------------------------------------------

/**
 * Returns a filtered subset of envData relevant to the requested docType.
 * Falls back to the full envData object if the docType has no filter defined.
 *
 * @param {string} docType
 * @param {object} envData
 * @returns {object}
 */
function segmentEnvData(docType, envData) {
  if (!envData || typeof envData !== "object") return envData;

  const segments = {
    network_overview: [
      "domain",
      "domain_controllers",
      "sites",
      "site_links",
      "dns",
      "dhcp",
      "subnets",
      "vlans",
      "wan_links",
      "network_devices",
    ],
    ad_runbook: [
      "domain",
      "forest",
      "domain_controllers",
      "fsmo_roles",
      "organizational_units",
      "groups",
      "password_policies",
      "fine_grained_policies",
      "gpo_summary",
      "trusts",
      "functional_levels",
    ],
    disaster_recovery: [
      "domain",
      "domain_controllers",
      "sites",
      "site_links",
      "servers",
      "backup_infrastructure",
      "dns",
      "dhcp",
      "critical_systems",
    ],
    onboarding: [
      "domain",
      "forest",
      "domain_controllers",
      "sites",
      "servers",
      "key_applications",
      "tools",
      "organizational_units",
      "contacts",
      "network_summary",
    ],
    security_audit: [
      "domain",
      "users",
      "privileged_accounts",
      "stale_accounts",
      "computers",
      "servers",
      "password_policies",
      "fine_grained_policies",
      "gpos",
      "gpo_summary",
      "firewall_rules",
      "network_acls",
      "os_inventory",
      "patch_summary",
      "audit_policies",
      "service_accounts",
    ],
    gpo_documentation: [
      "domain",
      "organizational_units",
      "gpos",
      "gpo_links",
      "wmi_filters",
      "gpo_permissions",
      "gpo_settings_summary",
    ],
  };

  const keys = segments[docType];
  if (!keys) return envData; // Unknown docType – pass everything

  const filtered = {};
  for (const key of keys) {
    if (key in envData) {
      filtered[key] = envData[key];
    }
  }

  // Always include top-level metadata if present
  if (envData.metadata) filtered.metadata = envData.metadata;
  if (envData.organization) filtered.organization = envData.organization;

  return filtered;
}

// ---------------------------------------------------------------------------
// Helper: build the user message sent to Claude
// ---------------------------------------------------------------------------

/**
 * Constructs the Claude user prompt from docType and segmented environment data.
 *
 * @param {string} docType
 * @param {object} segmentedData
 * @returns {string}
 */
function buildUserMessage(docType, segmentedData) {
  const label = docType
    .replace(/_/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
  return (
    `Generate a ${label} document based on the following IT environment data.\n\n` +
    `## Environment Data\n\n` +
    "```json\n" +
    JSON.stringify(segmentedData, null, 2) +
    "\n```\n\n" +
    "Generate the complete document now. Be thorough and specific to the data provided. " +
    "Do not use placeholder text – use actual values from the environment data."
  );
}

// ---------------------------------------------------------------------------
// Route: POST /api/generate – Streaming Claude proxy
// ---------------------------------------------------------------------------

app.post("/api/generate", generateLimiter, async (req, res) => {
  const { docType, envData, apiKey: bodyApiKey } = req.body;

  // --- Input validation ---
  if (!docType || typeof docType !== "string") {
    return res.status(400).json({ error: "Missing or invalid field: docType" });
  }
  if (!envData || (typeof envData !== "object" && typeof envData !== "string")) {
    return res.status(400).json({ error: "Missing or invalid field: envData" });
  }
  if (!SYSTEM_PROMPTS[docType]) {
    return res.status(400).json({
      error: `Unknown docType '${docType}'. Valid types: ${Object.keys(SYSTEM_PROMPTS).join(", ")}`,
    });
  }

  const anthropicKey = bodyApiKey || process.env.ANTHROPIC_API_KEY;
  if (!anthropicKey) {
    return res.status(500).json({
      error:
        "No Anthropic API key configured. Set ANTHROPIC_API_KEY in environment or pass apiKey in the request.",
    });
  }

  // --- Segment data and build prompt ---
  let parsedEnvData;
  try {
    parsedEnvData =
      typeof envData === "string" ? JSON.parse(envData) : envData;
  } catch {
    return res.status(400).json({ error: "envData is not valid JSON" });
  }

  const segmented = segmentEnvData(docType, parsedEnvData);
  const userMessage = buildUserMessage(docType, segmented);
  const systemPrompt = SYSTEM_PROMPTS[docType];

  // --- Set SSE headers before streaming ---
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");
  res.setHeader("X-Accel-Buffering", "no"); // Disable Nginx proxy buffering if present
  res.flushHeaders();

  // Handle client disconnect
  let clientGone = false;
  req.on("close", () => {
    clientGone = true;
  });

  try {
    // --- Call Anthropic Messages API with streaming ---
    const anthropicRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": anthropicKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-opus-4-20250514",
        max_tokens: 8192,
        stream: true,
        system: systemPrompt,
        messages: [{ role: "user", content: userMessage }],
      }),
    });

    // --- Handle Anthropic error responses ---
    if (!anthropicRes.ok) {
      let errorBody;
      try {
        errorBody = await anthropicRes.json();
      } catch {
        errorBody = { message: anthropicRes.statusText };
      }

      const message =
        errorBody?.error?.message ||
        errorBody?.message ||
        `Anthropic API error: ${anthropicRes.status}`;

      if (!clientGone) {
        res.write(
          `event: error\ndata: ${JSON.stringify({ error: message })}\n\n`
        );
        res.end();
      }
      return;
    }

    // --- Pipe the SSE stream from Anthropic to the client ---
    const reader = anthropicRes.body.getReader();
    const decoder = new TextDecoder();

    while (true) {
      if (clientGone) break;

      const { done, value } = await reader.read();
      if (done) break;

      const chunk = decoder.decode(value, { stream: true });
      if (!clientGone) {
        res.write(chunk);
      }
    }

    if (!clientGone) {
      res.end();
    }
  } catch (err) {
    console.error("[/api/generate] Error:", err);
    if (!clientGone) {
      const message =
        err.code === "ECONNREFUSED"
          ? "Could not connect to Anthropic API. Check your network."
          : err.message || "Internal server error";
      res.write(
        `event: error\ndata: ${JSON.stringify({ error: message })}\n\n`
      );
      res.end();
    }
  }
});

// ---------------------------------------------------------------------------
// Markdown → docx conversion helpers
// ---------------------------------------------------------------------------

/**
 * Parse a markdown line and return an array of TextRun objects,
 * handling **bold**, *italic*, and `inline code`.
 *
 * @param {string} text
 * @returns {TextRun[]}
 */
function parseInlineMarkdown(text) {
  const runs = [];
  // Captures: **bold**, *italic*, `code`, or plain text segments
  const pattern = /(\*\*(.+?)\*\*|\*(.+?)\*|`([^`]+)`|([^*`]+))/g;
  let match;

  while ((match = pattern.exec(text)) !== null) {
    if (match[2] !== undefined) {
      runs.push(new TextRun({ text: match[2], bold: true }));
    } else if (match[3] !== undefined) {
      runs.push(new TextRun({ text: match[3], italics: true }));
    } else if (match[4] !== undefined) {
      runs.push(
        new TextRun({
          text: match[4],
          font: "Courier New",
          size: 18, // 9pt
          shading: { type: ShadingType.CLEAR, color: "F0F0F0", fill: "F0F0F0" },
        })
      );
    } else if (match[5] !== undefined) {
      runs.push(new TextRun({ text: match[5] }));
    }
  }

  return runs.length > 0 ? runs : [new TextRun({ text })];
}

/**
 * Detect the heading level from a markdown heading line.
 * Returns { level: HeadingLevel, text: string } or null if not a heading.
 *
 * @param {string} line
 * @returns {{ level: string, text: string } | null}
 */
function detectHeading(line) {
  const match = line.match(/^(#{1,6})\s+(.+)$/);
  if (!match) return null;

  const hashes = match[1].length;
  const levelMap = {
    1: HeadingLevel.HEADING_1,
    2: HeadingLevel.HEADING_2,
    3: HeadingLevel.HEADING_3,
    4: HeadingLevel.HEADING_4,
    5: HeadingLevel.HEADING_5,
    6: HeadingLevel.HEADING_6,
  };
  return { level: levelMap[hashes] || HeadingLevel.HEADING_6, text: match[2] };
}

/**
 * Parse a markdown table block (array of raw lines) into a docx Table.
 *
 * @param {string[]} tableLines
 * @returns {Table}
 */
function parseMarkdownTable(tableLines) {
  const rows = [];

  for (let i = 0; i < tableLines.length; i++) {
    const line = tableLines[i].trim();

    // Skip separator row (e.g. |---|---|)
    if (/^\|?[\s:]*[-]+[\s:]*(\|[\s:]*[-]+[\s:]*)*\|?$/.test(line)) continue;

    const cells = line
      .replace(/^\|/, "")
      .replace(/\|$/, "")
      .split("|")
      .map((c) => c.trim());

    const isHeader = i === 0;

    rows.push(
      new TableRow({
        tableHeader: isHeader,
        children: cells.map(
          (cellText) =>
            new TableCell({
              shading: isHeader
                ? {
                    type: ShadingType.CLEAR,
                    color: "FFFFFF",
                    fill: "2E74B5",
                  }
                : undefined,
              children: [
                new Paragraph({
                  children: [
                    new TextRun({
                      text: cellText,
                      bold: isHeader,
                      color: isHeader ? "FFFFFF" : undefined,
                    }),
                  ],
                  alignment: AlignmentType.LEFT,
                }),
              ],
              width: {
                size: Math.floor(9000 / cells.length),
                type: WidthType.DXA,
              },
            })
        ),
      })
    );
  }

  return new Table({
    rows,
    width: { size: 9000, type: WidthType.DXA },
    borders: {
      top: { style: BorderStyle.SINGLE, size: 1, color: "CCCCCC" },
      bottom: { style: BorderStyle.SINGLE, size: 1, color: "CCCCCC" },
      left: { style: BorderStyle.SINGLE, size: 1, color: "CCCCCC" },
      right: { style: BorderStyle.SINGLE, size: 1, color: "CCCCCC" },
      insideH: { style: BorderStyle.SINGLE, size: 1, color: "CCCCCC" },
      insideV: { style: BorderStyle.SINGLE, size: 1, color: "CCCCCC" },
    },
  });
}

/**
 * Convert a markdown string to an array of docx Paragraph / Table objects.
 *
 * Handles:
 *   - ATX headings (# through ######)
 *   - Unordered lists (-, *, +)
 *   - Ordered lists (1., 2., ...)
 *   - Fenced code blocks (``` ... ```)
 *   - Markdown tables (| col | col |)
 *   - Inline bold, italic, inline code
 *   - Blank lines as paragraph spacers
 *   - Horizontal rules (---, ***, ___)
 *
 * @param {string} markdown
 * @returns {Array<Paragraph|Table>}
 */
function markdownToDocxElements(markdown) {
  const elements = [];
  const lines = markdown.split("\n");
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    // ---- Fenced code block ----
    if (line.trimStart().startsWith("```")) {
      const codeLines = [];
      i++; // skip opening fence
      while (i < lines.length && !lines[i].trimStart().startsWith("```")) {
        codeLines.push(lines[i]);
        i++;
      }
      i++; // skip closing fence

      for (const codeLine of codeLines) {
        elements.push(
          new Paragraph({
            children: [
              new TextRun({
                text: codeLine || " ",
                font: "Courier New",
                size: 18, // 9pt
              }),
            ],
            spacing: { before: 0, after: 0 },
            shading: {
              type: ShadingType.CLEAR,
              color: "FFFFFF",
              fill: "F5F5F5",
            },
          })
        );
      }
      // Spacer after code block
      elements.push(new Paragraph({ text: "" }));
      continue;
    }

    // ---- Markdown table ----
    if (line.trimStart().startsWith("|")) {
      const tableLines = [];
      while (i < lines.length && lines[i].trimStart().startsWith("|")) {
        tableLines.push(lines[i]);
        i++;
      }
      if (tableLines.length >= 2) {
        elements.push(parseMarkdownTable(tableLines));
        elements.push(new Paragraph({ text: "" })); // spacer after table
      }
      continue;
    }

    // ---- ATX Heading ----
    const heading = detectHeading(line);
    if (heading) {
      elements.push(
        new Paragraph({
          text: heading.text,
          heading: heading.level,
        })
      );
      i++;
      continue;
    }

    // ---- Unordered list item ----
    const ulMatch = line.match(/^(\s*)([-*+])\s+(.+)$/);
    if (ulMatch) {
      const indent = Math.floor(ulMatch[1].length / 2);
      elements.push(
        new Paragraph({
          children: parseInlineMarkdown(ulMatch[3]),
          bullet: { level: Math.min(indent, 8) },
        })
      );
      i++;
      continue;
    }

    // ---- Ordered list item ----
    const olMatch = line.match(/^(\s*)\d+\.\s+(.+)$/);
    if (olMatch) {
      const indent = Math.floor(olMatch[1].length / 2);
      elements.push(
        new Paragraph({
          children: parseInlineMarkdown(olMatch[2]),
          numbering: {
            reference: "default-numbering",
            level: Math.min(indent, 8),
          },
        })
      );
      i++;
      continue;
    }

    // ---- Blank line → spacer paragraph ----
    if (line.trim() === "") {
      elements.push(new Paragraph({ text: "" }));
      i++;
      continue;
    }

    // ---- Horizontal rule ----
    if (/^[-*_]{3,}$/.test(line.trim())) {
      elements.push(
        new Paragraph({
          border: {
            bottom: {
              style: BorderStyle.SINGLE,
              size: 6,
              color: "CCCCCC",
              space: 1,
            },
          },
          text: "",
        })
      );
      i++;
      continue;
    }

    // ---- Regular paragraph ----
    elements.push(
      new Paragraph({
        children: parseInlineMarkdown(line),
        spacing: { after: 120 },
      })
    );
    i++;
  }

  return elements;
}

// ---------------------------------------------------------------------------
// Route: POST /api/export/docx – Markdown → Word document
// ---------------------------------------------------------------------------

app.post("/api/export/docx", async (req, res) => {
  const { content, title, filename } = req.body;

  if (!content || typeof content !== "string") {
    return res.status(400).json({ error: "Missing or invalid field: content" });
  }
  if (!title || typeof title !== "string") {
    return res.status(400).json({ error: "Missing or invalid field: title" });
  }

  // Sanitise filename – strip path traversal characters
  const safeFilename = (filename || title)
    .replace(/[^a-zA-Z0-9_\- ]/g, "_")
    .replace(/\s+/g, "_")
    .substring(0, 100);

  try {
    const bodyElements = markdownToDocxElements(content);

    const doc = new Document({
      numbering: {
        config: [
          {
            reference: "default-numbering",
            levels: Array.from({ length: 9 }, (_, idx) => ({
              level: idx,
              format: "decimal",
              text: `%${idx + 1}.`,
              alignment: AlignmentType.LEFT,
              style: {
                paragraph: {
                  indent: { left: 720 * (idx + 1), hanging: 360 },
                },
              },
            })),
          },
        ],
      },
      styles: {
        default: {
          document: {
            run: { font: "Calibri", size: 22 }, // 11pt body text
          },
        },
      },
      sections: [
        {
          properties: {},
          children: [
            // Document title
            new Paragraph({
              text: title,
              heading: HeadingLevel.TITLE,
              spacing: { after: 400 },
            }),
            // Generated-by line
            new Paragraph({
              children: [
                new TextRun({
                  text: `Generated by DocForge on ${new Date().toUTCString()}`,
                  italics: true,
                  color: "888888",
                  size: 18, // 9pt
                }),
              ],
              spacing: { after: 600 },
            }),
            ...bodyElements,
          ],
        },
      ],
    });

    const buffer = await Packer.toBuffer(doc);

    res.setHeader(
      "Content-Type",
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    );
    res.setHeader(
      "Content-Disposition",
      `attachment; filename="${safeFilename}.docx"`
    );
    res.setHeader("Content-Length", buffer.length);
    res.send(buffer);
  } catch (err) {
    console.error("[/api/export/docx] Error:", err);
    res
      .status(500)
      .json({ error: "Failed to generate Word document: " + err.message });
  }
});

// ---------------------------------------------------------------------------
// Route: GET /health – Health check
// ---------------------------------------------------------------------------

app.get("/health", (_req, res) => {
  res.json({
    status: "ok",
    version: "1.0.0",
    timestamp: new Date().toISOString(),
  });
});

// ---------------------------------------------------------------------------
// Static frontend – serve the embedded React app from public/
// ---------------------------------------------------------------------------

app.use(express.static(path.join(__dirname, "public")));

// SPA fallback – any unmatched GET returns index.html
app.get("*", (req, res) => {
  if (!req.path.startsWith("/api")) {
    res.sendFile(path.join(__dirname, "public", "index.html"));
  }
});

// ---------------------------------------------------------------------------
// 404 handler
// ---------------------------------------------------------------------------

app.use((_req, res) => {
  res.status(404).json({ error: "Not found" });
});

// ---------------------------------------------------------------------------
// Global error handler
// ---------------------------------------------------------------------------

// eslint-disable-next-line no-unused-vars
app.use((err, _req, res, _next) => {
  console.error("[Unhandled error]", err);
  res
    .status(err.status || 500)
    .json({ error: err.message || "Internal server error" });
});

// ---------------------------------------------------------------------------
// Start server
// ---------------------------------------------------------------------------

app.listen(PORT, () => {
  console.log(`[DocForge] Server running on port ${PORT}`);
  console.log(`[DocForge] Allowed origins: ${allowedOrigins.join(", ")}`);
  console.log(
    `[DocForge] Anthropic API key: ${
      process.env.ANTHROPIC_API_KEY ? "configured" : "NOT SET"
    }`
  );
});

module.exports = app; // Export for testing
