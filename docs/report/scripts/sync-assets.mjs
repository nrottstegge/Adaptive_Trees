// Copies plots, benchmark CSVs, videos and viewer exports into public/.
// Runs automatically before `npm run dev` / `npm run build`; run `npm run sync` after re-plotting.
//
// Sources (override with env vars):
//   BENCH_DIR  = ../adaptive-octree-bench          (plots/, plots/talk/, data/)
//   SLIDES_DIR = ../presentation/Adaptive_Trees_Slides  (public/gifs/*.mp4, public/viewer/*.html)
//
// Missing sources are skipped with a warning, so the report still builds (components show placeholders).
import { cpSync, existsSync, mkdirSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const BENCH = resolve(root, process.env.BENCH_DIR || '../adaptive-octree-bench')
const SLIDES = resolve(root, process.env.SLIDES_DIR || '../presentation/Adaptive_Trees_Slides')
const PUB = join(root, 'public')

const jobs = [
  // [source dir, file filter, destination dir]
  [join(BENCH, 'plots'), f => f.endsWith('.webp'), join(PUB, 'bench')],
  [join(BENCH, 'plots/talk'), f => f.endsWith('.webp'), join(PUB, 'bench/talk')],
  [join(BENCH, 'data'), f => ['implementation_runtime_summary.csv', 'full_pipeline.csv'].includes(f), join(PUB, 'data')],
  [join(SLIDES, 'public/gifs'), f => /\.(mp4|webm|gif)$/.test(f), join(PUB, 'media')],
  [join(SLIDES, 'public/viewer'), f => f.endsWith('.html'), join(PUB, 'viewer')],
]

let copied = 0, skipped = 0
for (const [src, keep, dst] of jobs) {
  if (!existsSync(src)) { console.warn(`[sync] missing source, skipped: ${src}`); continue }
  mkdirSync(dst, { recursive: true })
  for (const f of readdirSync(src)) {
    const s = join(src, f), d = join(dst, f)
    if (!statSync(s).isFile() || !keep(f)) continue
    if (existsSync(d) && statSync(d).mtimeMs >= statSync(s).mtimeMs && statSync(d).size === statSync(s).size) { skipped++; continue }
    cpSync(s, d)
    copied++
  }
}
console.log(`[sync] ${copied} file(s) copied, ${skipped} up to date → public/`)
