import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Adaptive Trees on a GPU',
  description: 'GSP 2026 report — efficient GPU-aware adaptive tree construction for the Fast Multipole Method (JSC, Forschungszentrum Jülich)',
  base: process.env.BASE || '/',
  appearance: false,
  srcExclude: ['README.md'],
  head: [['link', { rel: 'icon', href: (process.env.BASE || '/') + 'header_octree.svg' }]],
  themeConfig: {
    nav: [],
    outline: { level: [2, 3], label: 'Contents' },
    sidebar: false,
    docFooter: { prev: false, next: false }
  },
  vite: {
    server: { allowedHosts: true } // let the dev server answer on remote hostnames
  },
  markdown: {
    math: true // requires markdown-it-mathjax3
  },
  vue: {
    template: {
      compilerOptions: {
        isCustomElement: (tag) => tag.startsWith('mjx-')
      }
    }
  }
})
