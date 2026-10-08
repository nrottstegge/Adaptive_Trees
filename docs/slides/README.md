# Adaptive Trees on a GPU — slides

Presentation by Nils Rottstegge for the 2026 Guest Student Programme at JSC,
Forschungszentrum Jülich. Covers adaptive GPU octrees, FMM-aware refinement,
CUDA graph updates, binary trees, and benchmark results.

[View the published slides](https://nrottstegge.github.io/Adaptive_Trees/slides/) ·
[Report](https://nrottstegge.github.io/Adaptive_Trees/report/) ·
[Repository overview](../../README.md)

## Rebuild

Requires Node.js 22 and npm. From the repository root:

```bash
cd docs/slides
npm ci
npm run dev
```

Slidev opens the local presentation in your browser. To build the static deck:

```bash
npm run build                             # output: dist/
npm run build -- --base /Adaptive_Trees/slides/  # GitHub Pages path
```

The root [Pages workflow](../../.github/workflows/pages.yml) builds and publishes
the deck together with the report; deployment details are in the root README.

## Edit and refresh assets

- `slides.md`: slide content and speaker notes.
- `components/`, `layouts/`, `lib/`, `style.css`: interactive figures, layouts, references, and styling.
- `public/`: bundled benchmark figures, videos (`gifs/`), and exported viewers (`viewer/`).

The checked-in assets are sufficient to rebuild. To refresh benchmark figures,
follow [the benchmark instructions](../../benchmarks/README.md), then copy the
required plots from `benchmarks/plots/` into `public/bench/` (including `talk/`).
Slide assets are not synchronized automatically.
