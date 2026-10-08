<script setup lang="ts">
// Optional frontmatter: cols: 1fr 2fr  (column widths of the ::left:: / ::right:: split)
defineProps({
  cols: { type: String, default: '1fr 1fr' },
})
const base = import.meta.env.BASE_URL
</script>

<template>
  <div class="layout-wrapper">
    <!-- Content area.
         Default: write plain markdown. The first "# heading" is the title, a "## heading"
         directly after it is the subtitle, everything else is the body.
         Optional slots: ::title:: / ::subtitle:: (instead of headings),
         ::center:: (content centered below the title block) and
         ::left:: / ::right:: (two columns below the title block). -->
    <div class="content">
      <div v-if="$slots.title" class="title">
        <slot name="title" />
      </div>

      <div v-if="$slots.subtitle" class="subtitle">
        <slot name="subtitle" />
      </div>

      <div class="body" :class="{ auto: !$slots.title }">
        <slot />
      </div>

      <!-- Optional ::center:: slot: content centered horizontally and vertically
           in the space below the title block (shares the body styles) -->
      <div v-if="$slots.center" class="body center">
        <slot name="center" />
      </div>

      <!-- Optional ::left:: / ::right:: slots: two columns below the title block -->
      <div
        v-if="$slots.left || $slots.right"
        class="body split"
        :style="{ gridTemplateColumns: cols }"
      >
        <div class="split-col"><slot name="left" /></div>
        <div class="split-col"><slot name="right" /></div>
      </div>
    </div>

    <!-- Footer: text left, slide counter in the middle, logo right -->
    <div class="band-bottom">
      <div class="corner-text">Member of the Helmholtz Association</div>

      <div class="slide-counter">
        {{ $slidev.nav.currentPage }} / {{ $slidev.nav.total }}
      </div>

      <div class="logo-wrapper">
        <slot name="logo">
          <!-- Default fallback if no logo slot is provided -->
          <span class="default-logo"><img :src="`${base}fzj.svg`" class="logo-img" /></span>
        </slot>
      </div>
    </div>
  </div>
</template>

<style scoped>
.layout-wrapper {
  position: relative;
  width: 100%;
  height: 100%;
  overflow: hidden;
  container-type: size;
  --slide-width: 100cqw;
  --slide-height: 100cqh;

  /* FZJ color palette */
  --fzj-white: #ffffff;
  --fzj-blue: #023d6b;
  --fzj-blue2: #adbde3;
  --fzj-gray: #ebebeb;

  /* Theme variables (light mode): white background, black text,
     title / subtitle / footer text in FZJ blue */
  --fzj-bg: var(--fzj-white);
  --fzj-text: #000000;
  --fzj-accent: var(--fzj-blue);
  --fzj-on-accent: var(--fzj-white); /* text on top of accent-colored shapes (list numbers) */
  --fzj-logo-filter: none;

  background-color: var(--fzj-bg);
  color: var(--fzj-text);
}

/* Dark mode (Slidev puts the class "dark" on <html>): black background, white text,
   title / subtitle / footer text in the light blue of the palette.
   If the logo is too dark on black, set --fzj-logo-filter: brightness(0) invert(1); */
:global(html.dark) .layout-wrapper {
  --fzj-bg: #000000;
  --fzj-text: #ffffff;
  --fzj-accent: var(--fzj-blue2);
  --fzj-on-accent: #000000;
  --fzj-logo-filter: none;
}

/* Content: 5% of slide height from the top, left and right;
   ends above the footer band so nothing runs into the footer. */
.content {
  position: absolute;
  top: calc(var(--slide-height) * 0.05);
  left: calc(var(--slide-height) * 0.05);
  right: calc(var(--slide-height) * 0.05);
  bottom: 20%; /* height of .band-bottom */
  overflow: hidden;
  display: flex;
  flex-direction: column;
}

/* ::center:: slot: fills the remaining height and centers its content */
.center {
  flex: 1 1 0;
  min-height: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  text-align: center;
}

.body {
  font-family: 'PT Sans', sans-serif;
  color: var(--fzj-text);
}

/* ::left:: / ::right:: slots: two columns, gap = 5% of the slide height */
.split {
  flex: 1 1 0;
  min-height: 0;
  display: grid;
  grid-template-columns: 1fr 1fr; /* overridden by the "cols" frontmatter */
  gap: calc(var(--slide-height) * 0.05);
  align-items: start;
}

.split-col {
  min-width: 0; /* lets wide content (tables, code) shrink instead of overflowing */
}

/* ---------- Title (first h1) and subtitle (h2 right after it), in FZJ blue ---------- */

/* With ::title:: / ::subtitle:: slots */
.title :deep(h1),
.title :deep(p) {
  font-family: 'Noto Sans';
  font-size: 2rem;
  text-transform: uppercase;
  line-height: 1.05;
  margin: 0;
  padding: 0;
  font-weight: 800;
}

.subtitle {
  margin-top: 0.4rem;
}

.subtitle :deep(h2),
.subtitle :deep(p) {
  font-family: 'Noto Sans';
  font-size: 1.5rem;
  text-transform: none;
  line-height: 1.1;
  margin: 0;
  padding: 0;
  font-weight: 400;
}

.body:not(.auto) {
  margin-top: 1.2rem;
}

/* Plain markdown (no markers) */
.auto :deep(h1:first-child) {
  font-family: 'Noto Sans';
  font-size: 2rem;
  text-transform: uppercase;
  line-height: 1.05;
  margin: 0;
  padding: 0;
  font-weight: 800;
}

.auto :deep(h1:first-child + h2) {
  font-family: 'Noto Sans';
  font-size: 1.5rem;
  text-transform: none;
  line-height: 1.1;
  margin: 0.4rem 0 0;
  padding: 0;
  font-weight: 400;
}

/* Space between the title block and the rest of the body */
.auto :deep(h1:first-child + h2 + *),
.auto :deep(h1:first-child + :not(h2)) {
  margin-top: 1.2rem;
}

/* Always the accent color (FZJ blue, light blue in dark mode), including nested
   elements (links, bold, code), regardless of theme styles */
.title,
.subtitle,
.title :deep(*),
.subtitle :deep(*),
.auto :deep(h1:first-child),
.auto :deep(h1:first-child *),
.auto :deep(h1:first-child + h2),
.auto :deep(h1:first-child + h2 *) {
  color: var(--fzj-accent) !important;
}

/* ---------- Lists ---------- */

/* Remove default markers (the reset styles hide them anyway); we draw our own */
.body :deep(ul),
.body :deep(ol) {
  list-style: none;
  padding-left: 0;
  margin: 0.4em 0;
}

.body :deep(li) {
  position: relative;
  padding-left: 1.6em;
  margin: 0.35em 0;
  line-height: 1.4;
}

.body :deep(li > p) {
  margin: 0;
}

/* Item list: small square in FZJ blue */
.body :deep(ul > li)::before {
  content: '';
  position: absolute;
  left: 0.15em;
  top: 0.5em;
  width: 0.4em;
  height: 0.4em;
  background-color: var(--fzj-accent);
}

/* Enumeration: number in a square in FZJ blue (nested lists restart at 1) */
.body :deep(ol) {
  counter-reset: fzj-item;
}

.body :deep(ol > li) {
  counter-increment: fzj-item;
}

.body :deep(ol > li)::before {
  content: counter(fzj-item);
  position: absolute;
  left: 0;
  top: 0.133em;
  width: 1.6em;
  height: 1.6em;
  display: flex;
  align-items: center;
  justify-content: center;
  box-sizing: border-box;
  background-color: var(--fzj-accent);
  color: var(--fzj-on-accent);
  font-size: 0.75em;
  font-weight: 700;
  line-height: 1;
}

/* ---------- Tables ---------- */

.body :deep(table) {
  width: 100%;                /* full width of the content area */
  border-collapse: collapse;
}

.body :deep(th),
.body :deep(td) {
  padding: 0.4em 0.8em;       /* wider cells */
  text-align: left;           /* markdown column alignment (:---:) still wins */
}

/* Header line and thin row lines */
.body :deep(th) {
  border-bottom: 2px solid var(--fzj-accent);
}

.body :deep(td) {
  border-bottom: 1px solid color-mix(in srgb, var(--fzj-accent) 30%, transparent);
}

/* Column separator: vertical line between neighboring columns */
.body :deep(th + th),
.body :deep(td + td) {
  border-left: 1px solid var(--fzj-accent);
}

/* ---------- Math (KaTeX) in sans-serif ---------- */

/* Digits, operators and text */
.content :deep(.katex) {
  font-family: 'Noto Sans', sans-serif;
}

/* Variables and Greek letters (italic), roman and bold math, and the "main" roman font.
   The big symbols (integrals, sums, brackets) keep KaTeX's own symbol fonts. */
.content :deep(.katex .mathnormal),
.content :deep(.katex .mathit),
.content :deep(.katex .mathrm),
.content :deep(.katex .mathbf),
.content :deep(.katex .boldsymbol),
.content :deep(.katex .mainrm) {
  font-family: 'Noto Sans', sans-serif;
}

/* ---------- Footer ---------- */

/* Bottom: 20% White footer band */
.band-bottom {
  position: absolute;
  top: 80%;
  left: 0;
  width: 100%;
  height: 20%;
  background-color: var(--fzj-bg);
}

/* Bottom-left footer text: 5% of slide height from the left and bottom edges */
.corner-text {
  position: absolute;
  left: calc(var(--slide-height) * 0.05);
  bottom: calc(var(--slide-height) * 0.05);
  font-family: 'Noto Sans';
  font-size: 0.8rem;
  font-weight: 100;
  line-height: 1;
  white-space: nowrap;
  color: var(--fzj-accent);
}

/* Slide counter: horizontally centered, same baseline and style as the corner text */
.slide-counter {
  position: absolute;
  left: 50%;
  transform: translateX(-50%);
  bottom: calc(var(--slide-height) * 0.05);
  font-family: 'Noto Sans';
  font-size: 0.8rem;
  font-weight: 100;
  line-height: 1;
  color: var(--fzj-accent);
}

/* Logo: height = 8% of slide height, 5% from the bottom and right edges */
.logo-wrapper {
  position: absolute;
  bottom: calc(var(--slide-height) * 0.05);
  right: calc(var(--slide-height) * 0.05);
}

.logo-img {
  display: block;
  height: calc(var(--slide-height) * 0.08);
  width: auto;
  max-width: none;
  filter: var(--fzj-logo-filter);
}
</style>
