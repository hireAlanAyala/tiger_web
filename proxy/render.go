package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html"
	"log"
	"net/http"
	"strings"
)

// --- Types for JSON unmarshaling ---

type Product struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	PriceCents  int    `json:"price_cents"`
	Inventory   int    `json:"inventory"`
	Version     int    `json:"version"`
	Active      bool   `json:"active"`
}

type Collection struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type CollectionDetail struct {
	ID       string    `json:"id"`
	Name     string    `json:"name"`
	Products []Product `json:"products"`
}

type Order struct {
	ID         string `json:"id"`
	TotalCents int    `json:"total_cents"`
	ItemsCount int    `json:"items_count"`
}

type OrderDetail struct {
	ID         string      `json:"id"`
	TotalCents int         `json:"total_cents"`
	Items      []OrderItem `json:"items"`
}

type OrderItem struct {
	Name           string `json:"name"`
	Quantity       int    `json:"quantity"`
	PriceCents     int    `json:"price_cents"`
	LineTotalCents int    `json:"line_total_cents"`
}

type ListResponse[T any] struct {
	Data []T `json:"data"`
}

// --- SSE frame builder ---

// PatchElementsFrame builds a Datastar patch-elements SSE event.
func PatchElementsFrame(selector, mode, elements string) []byte {
	var buf bytes.Buffer
	buf.WriteString("event: datastar-patch-elements\n")
	if selector != "" {
		fmt.Fprintf(&buf, "data: selector %s\n", selector)
	}
	if mode != "" {
		fmt.Fprintf(&buf, "data: mode %s\n", mode)
	}
	for _, line := range strings.Split(elements, "\n") {
		fmt.Fprintf(&buf, "data: elements %s\n", line)
	}
	buf.WriteString("\n")
	return buf.Bytes()
}

// --- Helpers ---

func fmtPrice(cents int) string {
	return fmt.Sprintf("$%d.%02d", cents/100, cents%100)
}

// jsEsc escapes a string for use in a single-quoted JS literal inside a
// double-quoted HTML attribute.
func jsEsc(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `'`, `\'`)
	s = strings.ReplaceAll(s, `"`, `&quot;`)
	return s
}

func shortID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

const authOpt = `{headers:{'Authorization':'Bearer '+$token}}`

func authPayloadOpt(payload string) string {
	return `{headers:{'Authorization':'Bearer '+$token},payload:` + payload + `}`
}

// --- Product rendering ---

func renderProductList(body []byte) string {
	var resp ListResponse[Product]
	if err := json.Unmarshal(body, &resp); err != nil || len(resp.Data) == 0 {
		return `<div class="card">No products</div>`
	}
	var b strings.Builder
	for _, p := range resp.Data {
		renderProductCard(&b, p)
	}
	return b.String()
}

func renderProductCard(b *strings.Builder, p Product) {
	inactive := ""
	if !p.Active {
		inactive = ` <span class="error">[inactive]</span>`
	}
	fmt.Fprintf(b,
		`<div class="card">`+
			`<strong>%s</strong> &mdash; %s &mdash; inv: %d &mdash; v%d%s`+
			`<div class="meta">%s</div>`+
			`<div class="meta">%s</div>`+
			`<div class="row" style="margin-top:4px">`+
			`<button data-on:click="@delete('/products/%s',%s)">Delete</button> `+
			`<button data-on:click="`+
			`const n=prompt('New name:','%s'); if(!n) return; `+
			`const pr=parseInt(prompt('New price (cents):',%d)); if(isNaN(pr)) return; `+
			`@put('/products/%s',%s)`+
			`">Update</button>`+
			`</div></div>`,
		html.EscapeString(p.Name), fmtPrice(p.PriceCents), p.Inventory, p.Version, inactive,
		p.ID, html.EscapeString(p.Description),
		// Delete button
		p.ID, authOpt,
		// Update button
		jsEsc(p.Name), p.PriceCents,
		p.ID, authPayloadOpt(fmt.Sprintf(`{name:n,price_cents:pr,version:%d}`, p.Version)),
	)
}

// --- Collection rendering ---

func renderCollectionList(body []byte) string {
	var resp ListResponse[Collection]
	if err := json.Unmarshal(body, &resp); err != nil || len(resp.Data) == 0 {
		return `<div class="card">No collections</div>`
	}
	var b strings.Builder
	for _, c := range resp.Data {
		renderCollectionCard(&b, c)
	}
	return b.String()
}

func renderCollectionCard(b *strings.Builder, c Collection) {
	fmt.Fprintf(b,
		`<div class="card">`+
			`<strong>%s</strong>`+
			`<div class="meta">%s</div>`+
			`<div class="row" style="margin-top:4px">`+
			`<button data-on:click="@get('/collections/%s',%s)">View</button> `+
			`<button class="danger" data-on:click="@delete('/collections/%s',%s)">Delete</button> `+
			`<input id="add-%s" placeholder="Product ID" style="width:260px"> `+
			`<button data-on:click="`+
			`const pid=document.getElementById('add-%s').value; `+
			`if(!pid){alert('Enter a product ID');return;} `+
			`@post('/collections/%s/products/'+pid,%s)`+
			`">Add Product</button>`+
			`</div>`+
			`<div id="col-%s"></div>`+
			`</div>`,
		html.EscapeString(c.Name), c.ID,
		// View
		c.ID, authOpt,
		// Delete
		c.ID, authOpt,
		// Add member input + button
		c.ID, c.ID, c.ID, authOpt,
		// Detail container
		c.ID,
	)
}

func renderCollectionDetail(body []byte) string {
	var detail CollectionDetail
	if err := json.Unmarshal(body, &detail); err != nil {
		return `<div class="meta">Error loading collection</div>`
	}
	if len(detail.Products) == 0 {
		return `<div class="meta">No products</div>`
	}
	var b strings.Builder
	b.WriteString(`<table><tr><th>Name</th><th>Price</th><th>Inv</th><th></th></tr>`)
	for _, p := range detail.Products {
		fmt.Fprintf(&b,
			`<tr><td>%s</td><td>%s</td><td>%d</td>`+
				`<td><button class="danger" data-on:click="@delete('/collections/%s/products/%s',%s)">Remove</button></td></tr>`,
			html.EscapeString(p.Name), fmtPrice(p.PriceCents), p.Inventory,
			detail.ID, p.ID, authOpt,
		)
	}
	b.WriteString(`</table>`)
	return b.String()
}

// --- Order rendering ---

func renderOrderList(body []byte) string {
	var resp ListResponse[Order]
	if err := json.Unmarshal(body, &resp); err != nil || len(resp.Data) == 0 {
		return `<div class="card">No orders</div>`
	}
	var b strings.Builder
	for _, o := range resp.Data {
		renderOrderCard(&b, o)
	}
	return b.String()
}

func renderOrderCard(b *strings.Builder, o Order) {
	fmt.Fprintf(b,
		`<div class="card">`+
			`Order <strong>%s...</strong> &mdash; %s &mdash; %d items `+
			`<button data-on:click="@get('/orders/%s',%s)">Details</button>`+
			`<div id="od-%s"></div>`+
			`</div>`,
		shortID(o.ID), fmtPrice(o.TotalCents), o.ItemsCount,
		o.ID, authOpt,
		o.ID,
	)
}

func renderOrderDetail(body []byte) string {
	var detail OrderDetail
	if err := json.Unmarshal(body, &detail); err != nil {
		return `<div class="meta">Error loading order</div>`
	}
	if len(detail.Items) == 0 {
		return `<div class="meta">No items</div>`
	}
	var b strings.Builder
	b.WriteString(`<table><tr><th>Product</th><th>Qty</th><th>Price</th><th>Line Total</th></tr>`)
	for _, i := range detail.Items {
		fmt.Fprintf(&b,
			`<tr><td>%s</td><td>%d</td><td>%s</td><td>%s</td></tr>`,
			html.EscapeString(i.Name), i.Quantity, fmtPrice(i.PriceCents), fmtPrice(i.LineTotalCents),
		)
	}
	fmt.Fprintf(&b,
		`<tr><td colspan="3"><strong>Total</strong></td><td><strong>%s</strong></td></tr></table>`,
		fmtPrice(detail.TotalCents),
	)
	return b.String()
}

// --- Datastar response router ---

// renderDatastarResponse writes SSE patch-elements events based on the
// request path and method. For mutations it re-fetches the parent list
// so the UI stays in sync.
func renderDatastarResponse(w http.ResponseWriter, method, path, tigerAddr, token string, status int, body []byte) {
	log.Printf("datastar: %s %s → status=%d body=%d bytes", method, path, status, len(body))
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) == 0 {
		return
	}
	resource := parts[0]

	// Mutations: re-fetch the appropriate resource after the write.
	if method != "GET" {
		if resource == "collections" && len(parts) >= 4 && parts[2] == "products" {
			// Collection member add/remove → refresh collection detail.
			detailPath := "/" + parts[0] + "/" + parts[1]
			_, detailBody := httpDoFull("GET", tigerAddr+detailPath, token, "", nil)
			w.Write(PatchElementsFrame("#col-"+parts[1], "inner", renderCollectionDetail(detailBody)))
			return
		}
		// All other mutations → refresh the parent list.
		refetchStatus, refetchBody := httpDoFull("GET", tigerAddr+"/"+resource, token, "", nil)
		log.Printf("datastar: refetch %s → status=%d body=%d bytes", resource, refetchStatus, len(refetchBody))
		body = refetchBody
		parts = []string{resource}
	}

	switch resource {
	case "products":
		if len(parts) == 1 {
			w.Write(PatchElementsFrame("#product-list", "inner", renderProductList(body)))
		}
	case "collections":
		if len(parts) == 1 {
			w.Write(PatchElementsFrame("#collection-list", "inner", renderCollectionList(body)))
		} else if len(parts) == 2 {
			w.Write(PatchElementsFrame("#col-"+parts[1], "inner", renderCollectionDetail(body)))
		}
	case "orders":
		if len(parts) == 1 {
			w.Write(PatchElementsFrame("#order-list", "inner", renderOrderList(body)))
		} else if len(parts) == 2 {
			w.Write(PatchElementsFrame("#od-"+parts[1], "inner", renderOrderDetail(body)))
		}
	}
}
