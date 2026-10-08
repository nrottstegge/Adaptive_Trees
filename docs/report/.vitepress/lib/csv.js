import { withBase } from 'vitepress'
// Minimal CSV loader (handles quoted fields). Files live in public/data (see scripts/sync-assets.mjs).
export function parseCsv(text) {
  const rows = []
  let row = [], cur = '', q = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (q) { if (c === '"' && text[i + 1] === '"') { cur += '"'; i++ } else if (c === '"') q = false; else cur += c }
    else if (c === '"') q = true
    else if (c === ',') { row.push(cur); cur = '' }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(cur); rows.push(row); row = []; cur = '' }
    else cur += c
  }
  if (cur || row.length) { row.push(cur); rows.push(row) }
  const [head, ...body] = rows.filter(r => r.length > 1)
  return body.map(r => Object.fromEntries(head.map((h, i) => [h, r[i]])))
}
export async function loadCsv(path) {
  const r = await fetch(withBase(path))
  if (!r.ok) throw new Error(`${path}: ${r.status}`)
  return parseCsv(await r.text())
}
