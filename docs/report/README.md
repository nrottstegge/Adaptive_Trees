# Adaptive Trees on a GPU — report

Final report by Nils Rottstegge for the 2026 Guest Student Programme at JSC,
Forschungszentrum Jülich. A VitePress article with interactive figures explaining
the algorithms, implementation, and benchmark results.

[Read the published report](https://nrottstegge.github.io/Adaptive_Trees/report/) ·
[Slides](https://nrottstegge.github.io/Adaptive_Trees/slides/) ·
[Repository overview](../../README.md)

## Rebuild

Requires Node.js 22 and npm. From the repository root:

```bash
cd docs/report
npm ci
npm run dev       # local development; use the URL printed by VitePress
npm run build     # static output: .vitepress/dist/
npm run preview   # preview the production build locally
```

For the published path, build with:

```bash
BASE=/Adaptive_Trees/report/ npm run build
```

The root [Pages workflow](../../.github/workflows/pages.yml) builds and publishes
the report together with the slides; deployment details are in the root README.
The checked-in assets are sufficient to rebuild without running GPU benchmarks.

## Edit and refresh assets

| Content | Location |
|---|---|
| Article, captions, timeline | `index.md` |
| Interactive figures | `.vitepress/components/` |
| Bibliography | `.vitepress/lib/refs.js` |
| Figure models | `.vitepress/lib/` |
| Styles | `.vitepress/theme/custom.css`, `.vitepress/theme/report.css` |
| Plots, CSVs, videos, viewer exports | `public/` |

After regenerating [benchmark plots](../../benchmarks/README.md), refresh assets
explicitly from this directory:

```bash
BENCH_DIR=../../benchmarks SLIDES_DIR=../slides npm run sync
```

This copies WebP plots, selected summary CSVs, slide videos, and viewer exports
into `public/`. The environment overrides are needed because the script's defaults
refer to the former separate repositories. Missing sources are skipped with a
warning. Neither `dev` nor `build` runs the sync script automatically.
