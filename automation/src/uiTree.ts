export interface Bounds {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

export interface UiNode {
  text: string;
  resourceId: string;
  contentDesc: string;
  className: string;
  packageName: string;
  clickable: boolean;
  enabled: boolean;
  scrollable: boolean;
  checked: boolean;
  bounds: Bounds;
  depth: number;
}

/** Fields are combined with AND. `text` and `contentDesc` are exact; the `*Contains` forms ignore case. */
export interface Selector {
  text?: string;
  textContains?: string;
  resourceId?: string;
  contentDesc?: string;
  contentDescContains?: string;
  className?: string;
  clickable?: boolean;
}

function unescapeXml(s: string): string {
  return s.replace(/&(#x[0-9a-fA-F]+|#\d+|lt|gt|amp|quot|apos);/g, (_match, entity: string) => {
    switch (entity) {
      case "lt": return "<";
      case "gt": return ">";
      case "amp": return "&";
      case "quot": return '"';
      case "apos": return "'";
    }
    const code = entity.startsWith("#x") ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
    return Number.isInteger(code) && code >= 0 && code <= 0x10ffff ? String.fromCodePoint(code) : "";
  });
}

function parseAttributes(tag: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of tag.matchAll(/([\w:.-]+)="([^"]*)"/g)) out[m[1]!] = unescapeXml(m[2]!);
  return out;
}

function parseBounds(value: string | undefined): Bounds {
  const m = /\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]/.exec(value ?? "");
  if (!m) return { left: 0, top: 0, right: 0, bottom: 0 };
  return { left: Number(m[1]), top: Number(m[2]), right: Number(m[3]), bottom: Number(m[4]) };
}

/** Parses the XML that `uiautomator dump` prints into a flat list in document order. */
export function parseUiTree(xml: string): UiNode[] {
  const nodes: UiNode[] = [];
  let depth = -1;
  // A tag may hold quoted attribute values that contain ">", so quoted strings are matched as a unit.
  const tag = /<(\/?)node\b((?:[^>"]|"[^"]*")*?)(\/?)>/g;
  for (const m of xml.matchAll(tag)) {
    if (m[1] === "/") { depth--; continue; }
    depth++;
    const a = parseAttributes(m[2] ?? "");
    nodes.push({
      text: a["text"] ?? "",
      resourceId: a["resource-id"] ?? "",
      contentDesc: a["content-desc"] ?? "",
      className: a["class"] ?? "",
      packageName: a["package"] ?? "",
      clickable: a["clickable"] === "true",
      enabled: a["enabled"] === "true",
      scrollable: a["scrollable"] === "true",
      checked: a["checked"] === "true",
      bounds: parseBounds(a["bounds"]),
      depth,
    });
    if (m[3] === "/") depth--;
  }
  return nodes;
}

export function hasSelector(sel: Selector): boolean {
  return Object.values(sel).some((v) => v !== undefined);
}

/** Nodes matching every given field that also have an on-screen area, in document order. */
export function findNodes(nodes: UiNode[], sel: Selector): UiNode[] {
  const lower = (s: string) => s.toLowerCase();
  return nodes.filter((n) => {
    if (n.bounds.right <= n.bounds.left || n.bounds.bottom <= n.bounds.top) return false;
    if (sel.text !== undefined && n.text !== sel.text) return false;
    if (sel.textContains !== undefined && !lower(n.text).includes(lower(sel.textContains))) return false;
    if (sel.resourceId !== undefined && n.resourceId !== sel.resourceId && !n.resourceId.endsWith("/" + sel.resourceId)) return false;
    if (sel.contentDesc !== undefined && n.contentDesc !== sel.contentDesc) return false;
    if (sel.contentDescContains !== undefined && !lower(n.contentDesc).includes(lower(sel.contentDescContains))) return false;
    if (sel.className !== undefined && n.className !== sel.className && !n.className.endsWith("." + sel.className)) return false;
    if (sel.clickable !== undefined && n.clickable !== sel.clickable) return false;
    return true;
  });
}

export function center(b: Bounds): { x: number; y: number } {
  return { x: Math.round((b.left + b.right) / 2), y: Math.round((b.top + b.bottom) / 2) };
}

/** One short line per node, indented by depth, for an agent (or a person) to read. */
export function describeNode(n: UiNode): string {
  const parts = [n.className.split(".").pop() || "node"];
  if (n.text) parts.push(`text=${JSON.stringify(n.text.length > 80 ? n.text.slice(0, 80) + "…" : n.text)}`);
  if (n.resourceId) parts.push(`id=${n.resourceId}`);
  if (n.contentDesc) parts.push(`desc=${JSON.stringify(n.contentDesc.length > 80 ? n.contentDesc.slice(0, 80) + "…" : n.contentDesc)}`);
  parts.push(`bounds=[${n.bounds.left},${n.bounds.top}][${n.bounds.right},${n.bounds.bottom}]`);
  const flags = [n.clickable && "clickable", n.scrollable && "scrollable", n.checked && "checked", !n.enabled && "disabled"].filter(Boolean);
  if (flags.length) parts.push(flags.join(","));
  return "  ".repeat(Math.min(n.depth, 12)) + parts.join(" ");
}

/** Keeps nodes that carry text, a description, an id, or can be tapped or scrolled. */
export function compactTree(nodes: UiNode[], maxNodes = 300): { text: string; shown: number; total: number } {
  const interesting = nodes.filter((n) => n.text || n.contentDesc || n.resourceId || n.clickable || n.scrollable);
  const shown = interesting.slice(0, maxNodes);
  const lines = shown.map(describeNode);
  if (interesting.length > shown.length) lines.push(`… ${interesting.length - shown.length} more nodes not shown`);
  return { text: lines.join("\n"), shown: shown.length, total: nodes.length };
}
