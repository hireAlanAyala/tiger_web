# UI-Agnostic Render Strategy

## What

The render function returns an HTML string. The framework serves it. What's in that string — vanilla HTML, React SSR output, Svelte SSR output, a canvas tag, an iframe — is the developer's choice and responsibility.

The framework owns everything before the string (route, prefetch, handle). The developer owns everything in the string and everything after it in the browser.

## Why

Most frameworks sit between the developer and their frontend tools. Astro owns the build, pins framework versions, decides hydration strategy. Next.js couples to React entirely. When the framework's adapter lags behind a framework release, the developer is stuck.

We don't sit in between. The developer talks directly to React, Vite, Svelte, or nothing at all. There's no middle layer to go stale, conflict, or constrain.

This also means the default path (vanilla HTML + primitive signals) ships zero JS and needs zero build tooling. Adding framework complexity is an opt-in decision with visible cost, not a default tax on every page.

## The boundary

| We own | We don't own |
|---|---|
| Route matching | Client-side bundling |
| Prefetch (SQL → data) | Framework SSR calls |
| Handle (business logic, DB writes) | Hydration strategy |
| Calling `render()` and serving the string | What's in the string |
| `<script type="ui">` signal runtime | React/Svelte/Vue runtime |
| Idiomorph for server swaps | Framework lifecycle after hydration |
| Serving static files from `/static` | Building those static files |

**The contract:** `render(ctx) → string`. That's the interface. It can't break because there's nothing to break.

## Default path: vanilla HTML + primitive signals

Zero JS, zero build step, zero framework knowledge.

```ts
// [render] .product_list
export function render(ctx) {
  return `
    <script type="ui">
      let search = ''
    </script>

    <input oninput="search = this.value" placeholder="Filter...">

    ${ctx.prefetched.products.map(p => `
      <div class="card">
        <strong>${esc(p.name)}</strong> — ${price(p.price_cents)}
      </div>
    `).join("")}
  `;
}
```

This is the blessed path. Most pages live here. They're the fastest pages on the web because they ship nothing to the browser.

## Escape hatch: bring your own framework

### Adding React (full walkthrough)

**1. Install dependencies:**

```bash
npm install react react-dom
npm install vite @vitejs/plugin-react  # for bundling
```

**2. Create a component (standard React):**

```tsx
// client/components/SalesChart.tsx
import { BarChart } from 'some-chart-lib';

export default function SalesChart({ data }) {
  return <BarChart data={data} />;
}
```

**3. Create a client entry point (one-time):**

```tsx
// client/entry.tsx
import { hydrateRoot } from 'react-dom/client';

const modules = import.meta.glob('./components/*.tsx', { eager: true });

document.querySelectorAll('[data-component]').forEach(el => {
  const name = el.dataset.component;
  const Component = modules[`./components/${name}.tsx`].default;
  const props = JSON.parse(el.dataset.props);
  hydrateRoot(el, <Component {...props} />);
});
```

**4. Vite config (one-time):**

```ts
// vite.config.ts
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  build: {
    rollupOptions: { input: 'client/entry.tsx' },
    outDir: 'static',
  },
});
```

**5. Create an SSR helper (one-time):**

```ts
// lib/react-ssr.ts
import ReactDOMServer from 'react-dom/server';

export function renderReact(name: string, Component: any, props: any) {
  const html = ReactDOMServer.renderToString(<Component {...props} />);
  return `
    <div data-component="${name}" data-props='${JSON.stringify(props)}'>
      ${html}
    </div>
  `;
}
```

**6. Use in a handler:**

```ts
import { renderReact } from '../lib/react-ssr';
import SalesChart from '../client/components/SalesChart';

// [render] .dashboard
export function render(ctx) {
  return `
    <script type="ui">
      let tab = 'overview'
    </script>

    <button onclick="tab = 'overview'">Overview</button>
    <button onclick="tab = 'chart'">Chart</button>

    <div hidden="{{tab !== 'overview'}}">
      <h1>Dashboard</h1>
      <p>Revenue: ${price(ctx.prefetched.revenue)}</p>
    </div>

    <div hidden="{{tab !== 'chart'}}">
      ${renderReact('SalesChart', SalesChart, { data: ctx.prefetched.sales })}
    </div>

    <script type="module" src="/static/entry.js"></script>
  `;
}
```

**Build:** `npx vite build` (dev: `npx vite build --watch`)

**Adding a new React component from this point:** create the file in `client/components/`, call `renderReact` in render. Vite's glob import picks it up automatically. No registry, no config change.

### Adding Svelte

Same pattern, different SSR call.

**1. Install:**

```bash
npm install svelte
npm install vite @sveltejs/vite-plugin-svelte
```

**2. Component (standard Svelte):**

```svelte
<!-- client/components/Editor.svelte -->
<script>
  export let code;
  export let language;
</script>

<pre><code class={language}>{code}</code></pre>
```

**3. SSR helper:**

```ts
// lib/svelte-ssr.ts
export function renderSvelte(name: string, Component: any, props: any) {
  const { html } = Component.render(props);
  return `
    <div data-svelte="${name}" data-props='${JSON.stringify(props)}'>
      ${html}
    </div>
  `;
}
```

**4. Client entry (separate from React, or combined):**

```ts
// client/svelte-entry.ts
const modules = import.meta.glob('./components/*.svelte', { eager: true });

document.querySelectorAll('[data-svelte]').forEach(el => {
  const name = el.dataset.svelte;
  const Component = modules[`./components/${name}.svelte`].default;
  const props = JSON.parse(el.dataset.props);
  new Component({ target: el, hydrate: true, props });
});
```

**5. Use in a handler:**

```ts
import { renderSvelte } from '../lib/svelte-ssr';
import Editor from '../client/components/Editor.svelte';

// [render] .code_editor
export function render(ctx) {
  return `
    <h1>Edit</h1>
    ${renderSvelte('Editor', Editor, {
      code: ctx.prefetched.file.content,
      language: ctx.prefetched.file.language,
    })}
    <script type="module" src="/static/svelte-entry.js"></script>
  `;
}
```

### Adding any other framework

The pattern is always:

1. `npm install` the framework
2. Write an SSR helper (~10 lines): call the framework's `renderToString` equivalent, wrap in a `<div>` with `data-*` props
3. Write a client entry (~10 lines): find the `data-*` divs, hydrate
4. Configure Vite (or any bundler) for the framework's file format
5. Call the helper in `render()`

The framework doesn't know and doesn't care. Each SSR framework is a function that returns a string. Each client framework is a script that hydrates a div.

## Coexistence

Signals, React, and Svelte on the same page:

```ts
// [render] .dashboard
export function render(ctx) {
  return `
    <script type="ui">
      let tab = 'overview'
    </script>

    <button onclick="tab = 'overview'">Overview</button>
    <button onclick="tab = 'chart'">Chart</button>
    <button onclick="tab = 'editor'">Editor</button>

    <!-- Vanilla HTML + signals — zero JS -->
    <div hidden="{{tab !== 'overview'}}">
      <p>Revenue: ${price(ctx.prefetched.revenue)}</p>
    </div>

    <!-- React — hydrates into its div -->
    <div hidden="{{tab !== 'chart'}}">
      ${renderReact('SalesChart', SalesChart, { data: ctx.prefetched.sales })}
    </div>

    <!-- Svelte — hydrates into its div -->
    <div hidden="{{tab !== 'editor'}}">
      ${renderSvelte('Editor', Editor, { code: ctx.prefetched.snippet })}
    </div>

    <script type="module" src="/static/react-entry.js"></script>
    <script type="module" src="/static/svelte-entry.js"></script>
  `;
}
```

No conflicts. Each framework owns its div. Signals own the page around them. The tab toggle is instant — no framework involved.

## Scaling

| Stage | What the developer does | JS shipped |
|---|---|---|
| Day 1 | Vanilla HTML + signals | 0 |
| Need a chart | Add one React component, set up Vite once | React + chart lib |
| Need a code editor | Add one Svelte component | Svelte + editor |
| 50 pages of MUI | `renderReact` helper + Vite glob imports | React + MUI (code-split per page) |

At no point does the developer rewrite anything. Each step adds to what exists. Vanilla pages stay vanilla. React pages stay React. The cost of each page is visible by what it imports.

## What we circumvent

Problems that Astro, Next.js, and other meta-frameworks hit:

| Problem | Why it exists elsewhere | Why we don't have it |
|---|---|---|
| Build coupling | Framework owns Vite config, plugin versions conflict | No build — developer owns theirs |
| Framework version lock-in | Adapter must support each version | No adapter — developer imports directly |
| Hydration strategy rigidity | Framework decides when/how to hydrate | Developer writes their own hydration |
| SSR runtime bugs | Framework's SSR pipeline has its own bugs | Developer calls `renderToString` directly |
| Island state sharing | Islands can't share state across frameworks | `uiSignals` is a global JS object, any code can read/write |
| Major version migrations | Framework API changes break config and adapters | No API — the contract is `render() → string` |

## The speed bump

Setting up Vite and writing a hydrate script is ~15 minutes of friction. This is intentional. It tells the developer: you're leaving the blessed path, make sure it's worth it.

A toggle button is not worth it — the vanilla version is one line. A rich data grid is worth it — MUI's DataGrid does things vanilla HTML can't.

The friction is proportional to the complexity being adopted. Vanilla pages: zero friction. One React component: 15 minutes. The developer always knows what they're paying for.
