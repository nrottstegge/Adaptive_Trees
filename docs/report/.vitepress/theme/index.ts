import DefaultTheme from 'vitepress/theme'
import type { Theme } from 'vitepress'
import './custom.css'
import './report.css'

// Every .vue file in .vitepress/components/ is available in index.md as <FileName />.
const modules = import.meta.glob('../components/*.vue', { eager: true }) as Record<string, any>

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    for (const [path, mod] of Object.entries(modules)) {
      const name = path.split('/').pop()!.replace(/\.vue$/, '')
      app.component(name, mod.default)
    }
  }
} satisfies Theme
