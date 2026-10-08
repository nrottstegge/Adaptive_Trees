<script setup lang="ts">
import { computed } from 'vue'
const props = defineProps({
  headerImage: {
    type: String,
    default: 'https://placehold.co/80x20', // fallback when the slide doesn't set one
  },
  date: { type: String, default: '' },
  author: { type: String, default: '' },
})
const base = import.meta.env.BASE_URL
// Public assets must resolve beneath the deployment base, including on deep links.
const headerImageUrl = computed(() => {
  const image = props.headerImage
  if (/^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(image)) return image
  return base + image.replace(/^\/+/, '')
})
</script>

<template>
  <div class="layout-wrapper">
    <!-- Background Bands -->
    <div class="band-top">
      <div class="image-container">
         <img :src="headerImageUrl" alt="" />
      </div>
    </div>
    <div class="band-middle">
      <div class="title-block">
        <div class="title">
          <slot />
        </div>

        <div v-if="$slots.subtitle" class="subtitle">
          <slot name="subtitle" />
        </div>

        <div v-if="$slots.date || (props.date || $slidev?.configs?.date) || $slots.author || (props.author || $slidev?.configs?.author)" class="meta">
          <span v-if="$slots.date || (props.date || $slidev?.configs?.date)" class="date">
            <slot name="date">{{ (props.date || $slidev?.configs?.date) }}</slot>
          </span>
          <span
            v-if="($slots.date || (props.date || $slidev?.configs?.date)) && ($slots.author || (props.author || $slidev?.configs?.author))"
            class="separator"
          >|</span>
          <span v-if="$slots.author || (props.author || $slidev?.configs?.author)" class="author">
            <slot name="author">{{ (props.author || $slidev?.configs?.author) }}</slot>
          </span>
        </div>
      </div>
    </div>
    
    <div class="band-bottom">
        <div class="corner-text">Member of the Helmholtz Association</div>
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

.image-container {
  /* Positioning relative to the slide */
  position: absolute;
  
  /* Indents: 5% of slide height from top, left, and right, variable set in layout wrapper*/
  top: calc(var(--slide-height)*0.05);
  left: calc(var(--slide-height)*0.05);
  right: calc(var(--slide-height)*0.05);
  
  /* Height calculation: 
     50% of total height (bottom limit) - 5% (top offset) = 45% 
     So the height should be 45vh */
  height: 100%;
  
  /* Optional: Add a border or background to visualize the container */
  /* border: 1px solid red; */
  border: 0px solid red;
  background-color: rgba(25, 255, 255, 1.00);
}

.default-hero {
/*  max-width: inherit;
  max-height: inherit;
  height: inherit;
  width: inherit/
  height: 100%;
  width: 200%;*/
/*  width: 90vh;
  height: 45vh;*/
}

.image-container img{
  width: 100%;
  height: 100%;
  border: 0px;
  margin-top: 0px;
  border-top: 0px;
  padding-top: 0px;
  object-fit: cover;
  object-position: center;
}

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

  /* Theme variables (light mode) */
  --fzj-bg: var(--fzj-white);
  --fzj-accent: var(--fzj-blue);
  --fzj-logo-filter: none;

  background-color: var(--fzj-bg);
}

/* Dark mode (Slidev puts the class "dark" on <html>): black instead of white.
   The blue band stays blue. If the logo is too dark on black, set
   --fzj-logo-filter: brightness(0) invert(1); */
:global(html.dark) .layout-wrapper {
  --fzj-bg: #000000;
  --fzj-accent: var(--fzj-blue2);
  --fzj-logo-filter: none;
}

/* Top: 50% White */
.band-top {
  position: absolute;
  top: 0px;
  left: 0px;
  right: 0px;
  width: 100%;
  height: 50%;
  background-color: var(--fzj-bg);
}

/* Middle: 30% Blue */
.band-middle {
  position: absolute;
  top: 50%;
  left: 0;
  width: 100%;
  height: 30%;
  background-color: var(--fzj-blue);
  display: flex;
  align-items: center;
  overflow: hidden; /* never draw outside the blue box */
}

/* Content stack inside the blue box */
.title-block {
  width: 100%;
  max-height: 100%;
  box-sizing: border-box;
  padding: 0 calc(var(--slide-height)*0.05);
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
  overflow: hidden;
}

/* Bottom: 20% White */
.band-bottom {
  position: absolute;
  top: 80%;
  left: 0;
  width: 100%;
  height: 20%;
  background-color: var(--fzj-bg);
  flex-direction: columns;
  justify-content: space between;
  align-items: end;
}

/* Logo: height = 8% of slide height */
.logo-img {
  display: block;
  height: calc(var(--slide-height) * 0.08);
  width: auto;
  max-width: none;
  filter: var(--fzj-logo-filter);
}

/* Bottom-left corner text: 5% of slide height from the left and bottom edges */
.corner-text {
  position: absolute;
  left: calc(var(--slide-height) * 0.05);
  bottom: calc(var(--slide-height) * 0.05);
  font-family: 'Noto Sans';
  font-size: 0.8rem;
  font-weight: 100;
  line-height: 1;
  color: var(--fzj-accent);
}

/* Logo Wrapper */
.logo-wrapper {
  position: absolute;
  bottom: calc(var(--slide-height) * 0.05); /* 5% of slide height from the bottom edge */
  right: calc(var(--slide-height) * 0.05); /* 5% of slide height from the right edge */
  justify-content: flex-start !important;
}

/* Styling for Markdown content inside the blue area.
   Horizontal/vertical spacing comes from .title-block, so margins are 0 here. */
.band-middle :deep(h1) {
  font-family: 'Noto Sans';
  font-size: 2rem;
  text-transform: uppercase;
  line-height: 1.05;
  color: var(--fzj-white);
  margin: 0;
  padding: 0;
  font-weight: 800;
}

.band-middle :deep(h2),
.subtitle,
.subtitle :deep(p) {
  font-family: 'Noto Sans';
  font-size: 1.5rem;
  text-transform: none;
  line-height: 1.1;
  color: var(--fzj-white);
  margin: 0;
  padding: 0;
  font-weight: 400;
}

.band-middle :deep(p) {
  font-family: 'PT Sans', sans-serif;
  font-size: 1.1rem;
  line-height: 1.3;
  color: color-mix(in srgb, var(--fzj-white) 85%, transparent);
  margin: 0;
  font-weight: 300;
}

/* "date | name" on a single line, directly below the subtitle */
.meta {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  margin-top: 0.4rem;
  font-family: 'PT Sans', sans-serif;
  font-size: 1rem;
  line-height: 1.2;
  color: color-mix(in srgb, var(--fzj-white) 85%, transparent);
  font-weight: 300;
}

.meta :deep(p) {
  margin: 0;
  font-size: inherit;
  line-height: inherit;
}

</style>
