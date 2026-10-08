# Adaptive Trees on a GPU — GSP 2026 report

Interactive scientific article (VitePress, JSC blog template) on my Guest Student Programme project.

```bash
npm install
npm run dev        # http://localhost:5173/
npm run build      # static site → .vitepress/dist
```

| What | Where |
|---|---|
| Text, sections, captions, commit timeline (front matter) | `index.md` |
| Interactive figures (usable in `index.md` as `<FileName />`) | `.vitepress/components/*.vue` |
| Bibliography (`<Cite id="…" />`, numbered by first citation) | `.vitepress/lib/refs.js` |
| Toy models used by the figures | `.vitepress/lib/` |
| Article typography (template) / figure styles | `.vitepress/theme/custom.css` / `report.css` |
| Plots, CSVs, videos, 3D viewer exports | `public/` |

`npm run sync` refreshes `public/` from `../adaptive-octree-bench` (plots, CSVs) and
`../presentation/Adaptive_Trees_Slides` (videos, viewer exports) after re-running the benchmark pipeline.
Figures and tables are numbered automatically.
