# Adaptive Trees on a GPU

Work by Nils Rottstegge during the 2026 Guest Student Programme at the Jülich
Supercomputing Centre (JSC), Forschungszentrum Jülich: GPU-aware adaptive trees
for the Fast Multipole Method (FMM). This repository brings together the CUDA
library, benchmark suite, presentation, and final report.

- [Read the report](https://nrottstegge.github.io/Adaptive_Trees/report/)
- [View the slides](https://nrottstegge.github.io/Adaptive_Trees/slides/)

| Location | Contents and instructions |
|---|---|
| `include/`, `src/`, `tests/` | CUDA library, example, regression tests, snapshot benchmark |
| [benchmarks/](benchmarks/README.md) | Pinned implementation comparisons, recorded results, analysis and plots |
| [docs/slides/](docs/slides/README.md) | Slidev presentation and bundled media |
| [docs/report/](docs/report/README.md) | VitePress report and interactive figures |

## Build the library and tests

Run from the repository root on a machine with an NVIDIA GPU, a compatible
CUDA toolkit and C++20 host compiler, CMake 3.22+, Git, and Thrust's CMake package
(from CUDA/CCCL). The test build downloads Catch2 3.7.1, so initial configuration
needs network access.

```bash
git clone https://github.com/nrottstegge/Adaptive_Trees.git
cd Adaptive_Trees
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=120
cmake --build build -j
ctest --test-dir build --output-on-failure
./build/tests/tree_example
```

Replace `120` with your GPU's CUDA architecture; it is also the project's default.
If CMake cannot locate Thrust, add `-DThrust_DIR=/path/to/lib/cmake/thrust`.
Use `-DBUILD_TESTING=OFF` for a library-only build. Downstream CMake projects can
use `add_subdirectory()` and link `adaptive_octree::adaptive_octree`.

## Use the library

Include `<adaptive_octree/tree.hpp>` and select
`adaptive_octree::Tree<Real, adaptive_octree::TreeType::Octree>` or
`TreeType::Binary`. Both expose sorted particle keys (`P`), a permutation (`Perm`),
leaf boundaries (`K`), populations (`N`), and optional tree views.
[tests/tree_example.cu](tests/tree_example.cu) shows configuration, device inputs,
building, updates, and buffer resizing. Its optional input file uses `charge x y z`
rows or `ESC`; the default uses the included test fixture.

Octrees support Morton/Hilbert keys and LeafCount/NFCount refinement. Binary trees
bisect the longest box side and support LeafCount only. `build()` converges from
the root; `update()` uses a fixed number of passes and supports CUDA graph capture.
Check `doBuffersNeedResize()` outside capture, resize if needed, and recapture
before replaying with new buffers. A clear resize flag does not imply convergence.

## Benchmarks and published documentation

The local `tests/bench_snapshots.cu` compares direct updates with graph replay.
Configure with `-DADAPTIVE_OCTREE_BENCH_CSV=ON`, then run, for example:

```bash
./build/tests/bench_snapshots --tree octree --criterion leafcount --dataset /path/to/particles.dat
```

This benchmark's single-file format is `x y z charge`. Large datasets are supplied
separately. For historical version comparisons and rebuilding plots from included
results, follow [benchmarks/README.md](benchmarks/README.md).

The report and slides build independently with Node.js 22 and npm; no GPU is
needed. Their READMEs give local commands. [.github/workflows/pages.yml](.github/workflows/pages.yml)
builds both and publishes `docs/index.html`, `/slides/`, and `/report/` to GitHub
Pages on pushes to `main` that change `docs/**` or the workflow, or on a manual run.
