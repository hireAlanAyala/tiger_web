# Live Partial Updates

Post-launch optimization for replacing full-page SSE refreshes with targeted partial HTML swaps.

## The problem

You launched with `.sync` in your mutation renders. It works — every mutation triggers a full dashboard re-render pushed to SSE subscribers. But the dashboard prefetches 5 entity types and the render is expensive. A single product write re-runs all of it when only the product list changed.

```typescript
// [render] .create_product
export function renderCreateProduct(ctx: CreateProductContext): RenderEffects {
    return render()
        .append("#toast", '<div class="toast">Product created</div>')
        .sync("/dashboard");  // re-runs entire dashboard prefetch + render
}
```

Creating a product re-runs the dashboard's prefetch (products + orders + stats) and re-renders everything. Wasteful.

## The fix

Replace `.sync` with targeted `.replace`. The mutation's render already has the context — render just the changed section.

### Before (full-page refresh via SSE)

```typescript
// [render] .create_product
export function renderCreateProduct(ctx: CreateProductContext): RenderEffects {
    return render()
        .append("#toast", '<div class="toast">Product created</div>')
        .sync("/dashboard");  // slow — re-runs all 5 queries
}
```

### After (partial update)

```typescript
// [render] .create_product
export function renderCreateProduct(ctx: CreateProductContext): RenderEffects {
    return render()
        .append("#toast", '<div class="toast">Product created</div>')
        .replace("#product-list", renderProductTable(ctx.prefetched.products));  // fast — data already prefetched
}
```

No dashboard re-render. The mutation's prefetch already has the product data. The render produces an effect that replaces just the product list section for SSE subscribers. The client swaps it into `#product-list`.

## When to do this

Not at launch. Start with `.sync` — simple, correct, fast enough for most traffic. Switch to targeted `.replace` when:

- Dashboard prefetch is measurably slow
- You have many concurrent SSE subscribers
- Mutations are frequent and only touch one section of the page

This is a performance optimization, not an architecture change. Same render function, same builder. You're just replacing one effect with another.

## What doesn't change

- Handlers still have zero SSE awareness — just status and writes
- Render is still a pure function returning data
- The client still receives SSE events — the swap target is in the effect
- Full page load still works the same — first visit gets the complete dashboard via string return
