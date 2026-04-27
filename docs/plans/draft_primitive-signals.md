# Primitive Signals — Client-Side UI State

## What

A minimal reactive layer for client-side UI state. Primitive values only (booleans, numbers, strings). No objects, no arrays, no derived signals, no dependency graph. The server renders full HTML with binding metadata; a ~30-40 line runtime watches for signal changes and updates the DOM directly.

## Why

Most "interactivity" on the web is cosmetic — toggles, tabs, dropdowns, form input, active states. The industry routes this through application-level frameworks (React, Vue, Svelte) that introduce build steps, virtual DOMs, dependency graphs, and learning curves. None of that is necessary when the server is the application and the client is just moving values around between server responses.

Tiger already renders full HTML server-side. What's missing is a way to handle the small UI state that lives between server round-trips — without adopting a framework.

### Design constraints

- **Primitives only.** No objects (eliminates identity vs equality, accidental mutation, deep comparison). No arrays (eliminates list diffing, splice tracking, proxy complexity).
- **No derived signals.** Expressions inline in the markup. One level deep — source signals to DOM. No graph, no diamonds, no glitches, no topological sorting.
- **Vanilla syntax.** Standard `onclick`/`oninput` handlers. `{{expr}}` for output. No custom attributes in authored HTML, no framework API, no imports.
- **Server is truth.** Complex logic is a server swap via Idiomorph. Every server response can include a fresh `<script type="ui">` that resets signal state.

### What this eliminates vs SPA frameworks

| Concern | SPA frameworks | This |
|---|---|---|
| Runtime size | 30-80KB | ~40 lines |
| Build step | Required | None |
| Learning curve | Weeks | Already know HTML and JS |
| Debugging | Framework devtools | Browser devtools |
| Failure modes | Stale state, hydration mismatch, memory leaks, zombie subscriptions | None — server corrects on every response |

## Syntax

### Declaring signals

```html
<script type="ui">
  let count = 0
  let open = false
  let tab = 'details'
</script>
```

Browsers ignore unknown script types. Scoped to the parent element. Valid HTML.

### Reading signals in markup

The developer writes `{{expr}}` using any vanilla JS expression over the declared signals:

```html
<span>{{count}}</span>
<span>{{count > 0 ? 'has items' : 'empty'}}</span>
<div hidden="{{!open}}">Menu content</div>
<div class="{{'tab ' + (tab === 'details' ? 'active' : '')}}">Details</div>
```

The server renders the expression to its current value and emits a `data-ui` binding attribute:

```html
<span data-ui="count:textContent">0</span>
```

The browser sees the rendered value. The `{{}}` syntax never reaches the DOM. The runtime reads `data-ui` attributes on boot, builds a binding map, and strips them.

### Writing signals from events

The developer writes vanilla event handlers:

```html
<button onclick="count++">+</button>
<button onclick="open = !open">Toggle</button>
<input oninput="name = this.value">
```

The server detects that the handler references declared signals and transpiles to a `data-ui-*` attribute (CSP-safe — no inline script execution):

```html
<button data-ui-click="count++">+</button>
```

The developer never writes `data-ui-*`. They write `onclick`. The server does the rewriting.

### Write handlers — `new Function` + `with`

The runtime wraps handler strings in a function with signals in scope:

```js
const fn = new Function('signals', 'event', `
  with (signals) { ${handlerString} }
`)
```

No parser, no eval of user input. The handler strings are developer-authored template code transpiled by the server — same trust level as a `<script>` tag. `with` puts all signals in scope so `count++`, `if (dragging) { dragX = event.clientX }`, and any vanilla JS just works.

This requires CSP `unsafe-eval`. The server controls the CSP header and knows it's emitting these handlers. If `unsafe-eval` becomes a problem for a specific deployment, the internals can be swapped to a mini parser without changing the authored syntax — `onclick="count++"` stays the same regardless of how the runtime executes it. The API is the HTML; the execution strategy is plumbing.

## How the runtime works

1. On boot: find all `<script type="ui">`, extract declarations, build a proxy per scope
2. Find all `data-ui` attributes, build a binding map: `signal name → [{element, property}]`
3. Strip `data-ui` attributes (clean DOM)
4. Find all `data-ui-*` event attributes, attach listeners
5. On signal change: proxy setter fires, loop bindings for that signal, re-evaluate expression, set `el[prop]`

No virtual DOM. No diffing. No tree walking. Direct property assignment by address.

## Server swap — the escape hatch for everything complex

Any interaction that needs real logic hits the server. The server returns HTML. Idiomorph morphs it into the DOM. If the response includes a new `<script type="ui">`, the runtime re-initializes signals with the server's values.

```
User clicks "Save" → POST to server → server returns new HTML
  → Idiomorph swaps DOM
  → new <script type="ui"> resets signals to server truth
```

The client can drift between responses — signals hold cosmetic state that may be stale. The server corrects on every interaction that matters. The client is never authoritative.

## Stress-tested examples

### Multi-step form wizard

Every field is a primitive. Steps are show/hide.

```html
<script type="ui">
  let step = 1
  let name = ''
  let email = ''
  let plan = 'free'
</script>

<div hidden="{{step !== 1}}">
  <input oninput="name = this.value" placeholder="Name">
  <input oninput="email = this.value" placeholder="Email">
  <button onclick="step = 2">Next</button>
</div>

<div hidden="{{step !== 2}}">
  <button onclick="plan = 'free'" class="{{plan === 'free' ? 'selected' : ''}}">Free</button>
  <button onclick="plan = 'pro'" class="{{plan === 'pro' ? 'selected' : ''}}">Pro</button>
  <button onclick="step = 1">Back</button>
  <button onclick="step = 3">Next</button>
</div>

<div hidden="{{step !== 3}}">
  <p>Name: {{name}}</p>
  <p>Email: {{email}}</p>
  <p>Plan: {{plan}}</p>
  <button onclick="step = 2">Back</button>
  <button action="/signup" method="POST">Submit</button>
</div>
```

### Filter controls (signals hold the knobs, server holds the data)

```html
<script type="ui">
  let sort = 'price'
  let inStock = true
  let minPrice = 0
  let maxPrice = 100
</script>

<select oninput="sort = this.value">
  <option value="price">Price</option>
  <option value="name">Name</option>
</select>
<label>
  <input type="checkbox" onclick="inStock = !inStock" checked="{{inStock}}"> In stock only
</label>
<input type="range" min="0" max="500" oninput="minPrice = Number(this.value)">
<input type="range" min="0" max="500" oninput="maxPrice = Number(this.value)">
<span>{{minPrice}} - {{maxPrice}}</span>
```

Controls are all primitives. Applying the filter submits to the server. The server returns filtered results as HTML.

### Inline edit with server reset

```html
<script type="ui">
  let editing = false
  let draft = 'Original title'
</script>

<span hidden="{{editing}}">{{draft}}</span>
<input hidden="{{!editing}}" oninput="draft = this.value">
<button onclick="editing = !editing">{{editing ? 'Cancel' : 'Edit'}}</button>
<button hidden="{{!editing}}" action="/update-title" method="POST">Save</button>
```

Client holds draft state freely. On save, the server returns new HTML with a fresh `<script type="ui">` containing `let draft = 'New title'`. Idiomorph swaps, runtime re-initializes. Server is the reset button.

### Color picker (compound expressions, no derived signals)

```html
<script type="ui">
  let r = 128
  let g = 128
  let b = 128
</script>

<input type="range" min="0" max="255" oninput="r = Number(this.value)"> {{r}}
<input type="range" min="0" max="255" oninput="g = Number(this.value)"> {{g}}
<input type="range" min="0" max="255" oninput="b = Number(this.value)"> {{b}}
<div style="{{'background: rgb(' + r + ',' + g + ',' + b + ')'}}">Preview</div>
```

Expressions are verbose but correct. No derived signal needed — if an expression is complex enough to want one, it belongs on the server.

### Drag and drop (stress test — complex handlers, 60fps, event access)

```html
<script type="ui">
  let dragging = false
  let dragX = 0
  let dragY = 0
  let offsetX = 0
  let offsetY = 0
</script>

<div
  style="{{'position:absolute; left:' + dragX + 'px; top:' + dragY + 'px; cursor:grab'}}"
  onmousedown="dragging = true; offsetX = event.clientX - dragX; offsetY = event.clientY - dragY"
  onmouseup="dragging = false"
>
  Drag me
</div>

<body onmousemove="if (dragging) { dragX = event.clientX - offsetX; dragY = event.clientY - offsetY }">
```

Reveals: handlers need `event` access, multi-statement handlers, conditionals in handlers, 60fps update rate. Primitives hold — position is just two numbers. The `new Function` + `with` approach handles all of this without a parser. A mini-parser approach would need to support `if`, semicolons, and `event` — effectively reimplementing JS.

### Multi-element drag (stress test — scaling, constraint-driven design)

Naive approach: 5 signals per element, manually numbered (`drag1X`, `drag2X`, ...). 10 elements = 50 signals, a massive `onmousemove`, and silent typo bugs. Doesn't scale.

The primitives-only constraint forces the right answer — signals for state the HTML reads, vanilla JS for imperative DOM work:

```html
<script type="ui">
  let activeId = ''
</script>

<script>
  let offX = 0, offY = 0

  function grab(e) {
    uiSignals.activeId = e.target.dataset.id
    const rect = e.target.getBoundingClientRect()
    offX = e.clientX - rect.left
    offY = e.clientY - rect.top
  }

  function move(e) {
    if (!uiSignals.activeId) return
    const el = document.querySelector(`[data-id="${uiSignals.activeId}"]`)
    el.style.left = (e.clientX - offX) + 'px'
    el.style.top = (e.clientY - offY) + 'px'
  }

  function drop(e) {
    uiSignals.activeId = ''
    // POST final positions to server if needed
  }
</script>

<div data-id="card1" style="position:absolute;left:0;top:0" onmousedown="grab(event)">Card 1</div>
<div data-id="card2" style="position:absolute;left:100px;top:100px" onmousedown="grab(event)">Card 2</div>
<div data-id="card3" style="position:absolute;left:200px;top:200px" onmousedown="grab(event)">Card 3</div>

<body onmousemove="move(event)" onmouseup="drop(event)">
```

The signal (`activeId`) tracks state the rest of the page cares about — is something being dragged? The pixel movement is vanilla DOM manipulation. No need to route 60fps coordinates through the proxy.

**The constraint is the design.** If arrays or object signals existed, someone would model all drag states in a signal array and fight mutation tracking at 60fps. Primitives-only makes that impossible, so the developer naturally uses signals for declarative state and vanilla JS for imperative work. Each tool does what it's good at.

### Toast notifications (stress test — imperative side effects, multiple instances)

One toast is trivial with signals:

```html
<script type="ui">
  let toast = ''
  let toastVisible = false
</script>

<script>
  function showToast(msg) {
    uiSignals.toast = msg
    uiSignals.toastVisible = true
    setTimeout(() => { uiSignals.toastVisible = false }, 3000)
  }
</script>

<div class="toast" hidden="{{!toastVisible}}">{{toast}}</div>
<button onclick="showToast('Item added to cart')">Add to cart</button>
```

But stacking multiple toasts needs a list — which needs arrays. Server swap is unreasonable for a 3-second cosmetic notification. Fixed slots (`toast1`, `toast2`, `toast3`) work but are ugly.

The right answer: **vanilla JS owns it entirely.** Toasts are imperative — "create element, append, remove after N seconds." That's not reactive state, it's a side effect.

```html
<script>
  function showToast(msg) {
    const el = document.createElement('div')
    el.className = 'toast'
    el.textContent = msg
    document.querySelector('.toasts').appendChild(el)
    setTimeout(() => el.remove(), 3000)
  }
</script>

<div class="toasts"></div>
<button onclick="showToast('Item added')">Add</button>
<button onclick="showToast('Saved')">Save</button>
```

No signals. 8 lines of vanilla JS. Stacks naturally. Same pattern as multi-element drag: the primitives-only constraint redirects imperative work to vanilla JS, which handles it better than any reactive system would.

**Recurring pattern across stress tests:** every case that primitives can't express cleanly turns out to be imperative work that vanilla JS solves in fewer lines than a signal-based approach would require. The constraint isn't exposing a limitation — it's exposing the correct boundary between declarative state (signals) and imperative side effects (vanilla JS).

### Upload progress (stress test — async operations, XHR callbacks)

```html
<script type="ui">
  let progress = 0
  let status = 'idle'
</script>

<script>
  function startUpload(e) {
    const file = e.target.files[0]
    uiSignals.status = 'uploading'
    uiSignals.progress = 0
    const xhr = new XMLHttpRequest()
    xhr.upload.onprogress = (e) => {
      uiSignals.progress = Math.round(e.loaded / e.total * 100)
    }
    xhr.onload = () => {
      uiSignals.status = 'done'
      Idiomorph.morph(document.querySelector('.upload'), xhr.responseText)
    }
    xhr.onerror = () => { uiSignals.status = 'error' }
    xhr.open('POST', '/upload')
    xhr.send(file)
  }
</script>

<div class="upload">
  <input type="file" onchange="startUpload(event)">
  <div hidden="{{status === 'idle'}}">
    <div style="{{'width:' + progress + '%'}}" class="bar"></div>
    <span>{{progress}}%</span>
  </div>
  <span hidden="{{status !== 'error'}}" class="error">Upload failed</span>
</div>
```

Signals: progress number and status string — declarative state the HTML reads. The upload itself is vanilla XHR. On completion, server returns HTML and Idiomorph swaps. Async operations don't strain the model — vanilla JS does the work, signals display the result.

### Countdown timer (stress test — intervals, computed display)

```html
<script type="ui">
  let seconds = 300
  let running = false
</script>

<script>
  let interval = null
  function toggle() {
    if (uiSignals.running) {
      clearInterval(interval)
      uiSignals.running = false
    } else {
      uiSignals.running = true
      interval = setInterval(() => {
        uiSignals.seconds--
        if (uiSignals.seconds <= 0) {
          clearInterval(interval)
          uiSignals.running = false
        }
      }, 1000)
    }
  }
</script>

<span>{{Math.floor(seconds / 60)}}:{{(seconds % 60).toString().padStart(2, '0')}}</span>
<button onclick="toggle()">{{running ? 'Pause' : 'Start'}}</button>
```

Two primitives. Timer scheduling is vanilla JS. Display formatting is an inline expression. No derived signals needed.

## Third-party JS interaction

If signals are exposed on a global (e.g. `window.__ui`), third-party scripts can read and write them:

```js
// Analytics reads state
trackEvent('tab_changed', { tab: uiSignals.tab })

// Chat widget opens a modal
uiSignals.modalOpen = true

// Stripe callback updates UI
uiSignals.paymentStep = 'confirmed'
```

Writes go through the same proxy — the DOM updates. The risk is a third-party setting unexpected values (`count = 999`), but since signals are cosmetic and the server corrects on the next response, the worst case is a visual glitch between swaps. No security issue — the server never trusts client state.

Default: **expose read and write freely.** The server is authoritative. Client state is always cosmetic and always correctable.

## What this doesn't do

- Client-side routing
- Optimistic updates
- Offline mode
- List rendering (server's job)
- Conditional DOM insertion/removal (use `hidden` for show/hide, server swap for structural changes)

These are SPA concerns. This isn't an SPA. The server is the application. Signals are the animation layer.

## Why no derived signals

Derived signals create a dependency graph. Graphs introduce diamonds, glitches, topological sorting, and scheduling. All of that complexity exists to cache computed values. But:

1. Expressions here are trivial — arithmetic, ternaries, string concat on primitives. Nothing to cache.
2. Repeating `{{count * 2}}` in three places is declarative repetition, not logic duplication.
3. If an expression is complex enough to want caching, it's computing data — which belongs on the server.

No derived signals means no graph. No graph means no graph problems.

## Why no arrays

Arrays reintroduce mutation ambiguity (`push`, `splice`, index assignment), require Proxy trapping or immutable-update discipline, and demand loop syntax in templates plus DOM node insertion/removal. Every array use case (tag lists, multi-select, reorder) is a server swap at tiger-web's latency (~3ms). The constraint keeps the runtime trivial and pushes structural changes to where they're already solved.
