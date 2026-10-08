<script setup>
import { useData } from 'vitepress'
// Title band in the style of the FZJ slide template; text comes from the front matter of index.md.
const { frontmatter } = useData()
</script>

<template>
  <header class="hero">
    <div class="band"><FzjTitleArt /></div>
    <div class="bar">
      <div class="kicker">{{ frontmatter.kicker }}</div>
      <h1 class="t">{{ frontmatter.title }}</h1>
      <div class="st">{{ frontmatter.subtitle }}</div>
      <div class="info">
        <span>{{ frontmatter.author }}</span><i></i><span>{{ frontmatter.affiliation }}</span><i></i><span>{{ frontmatter.period }}</span>
      </div>
    </div>
  </header>
</template>

<style scoped>
.hero { margin: 0 0 2rem; }
.band { height: 150px; overflow: hidden; background: var(--fzj-lightblue); }
.bar { background: var(--fzj-blue); color: white; padding: 18px 24px 20px; }
.kicker { font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--fzj-lightblue); font-weight: 700; }
.t { font-size: 2rem !important; line-height: 1.15 !important; font-weight: 700; text-transform: uppercase; color: white !important; margin: 4px 0 0 !important; border: none !important; padding: 0 !important; }
.st { font-size: 1.1rem; font-weight: 700; color: var(--fzj-lightblue); margin-top: 6px; }
.info { font-size: 0.85rem; margin-top: 14px; display: flex; flex-wrap: wrap; align-items: center; gap: 4px; }
.info i { display: inline-block; width: 1px; height: 1em; background: white; margin: 0 0.6em; }
</style>
