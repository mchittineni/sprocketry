package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// newTestServer serves the catalog from a freshly seeded database. It needs a disposable PostgreSQL
// database in TEST_DATABASE_URL, which it wipes, so the tests skip when that is not set.
func newTestServer(t *testing.T) (*httptest.Server, *pgxpool.Pool) {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		// CI always provides a database, so a missing one there is a broken pipeline, not a reason to pass.
		if os.Getenv("CI") != "" {
			t.Fatal("TEST_DATABASE_URL not set in CI")
		}
		t.Skip("TEST_DATABASE_URL not set; skipping database tests")
	}
	ctx := context.Background()
	db, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	if _, err := db.Exec(ctx, "DROP TABLE IF EXISTS reservations, products"); err != nil {
		t.Fatal(err)
	}
	if err := applySchema(ctx, db); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer((&server{db: db}).routes())
	t.Cleanup(srv.Close)
	return srv, db
}

func do(t *testing.T, method, url, body string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, url, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })
	return resp
}

func stock(t *testing.T, db *pgxpool.Pool, sku string) int {
	t.Helper()
	var n int
	if err := db.QueryRow(context.Background(), "SELECT stock FROM products WHERE sku = $1", sku).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestListProductsFiltersByCategory(t *testing.T) {
	srv, _ := newTestServer(t)
	resp := do(t, "GET", srv.URL+"/products?category=home", "")

	var products []Product
	if err := json.NewDecoder(resp.Body).Decode(&products); err != nil {
		t.Fatal(err)
	}
	if len(products) != 2 {
		t.Fatalf("want 2 home products, got %d", len(products))
	}
	for _, p := range products {
		if p.Category != "home" {
			t.Errorf("got %s in category %s", p.SKU, p.Category)
		}
	}
}

func TestGetProduct(t *testing.T) {
	srv, _ := newTestServer(t)

	resp := do(t, "GET", srv.URL+"/products/RB-002", "")
	var p Product
	if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
		t.Fatal(err)
	}
	if p.Name != "Sweep Bot" || p.Price != 349 {
		t.Errorf("got %+v", p)
	}

	if resp := do(t, "GET", srv.URL+"/products/NOPE", ""); resp.StatusCode != http.StatusNotFound {
		t.Errorf("unknown sku: want 404, got %d", resp.StatusCode)
	}
}

func TestReserveTakesStockOnceAndReleaseReturnsIt(t *testing.T) {
	srv, db := newTestServer(t)
	body := `{"items":[{"sku":"RB-002","quantity":3},{"sku":"RB-001","quantity":2}]}`

	if resp := do(t, "POST", srv.URL+"/orders/o1/reservation", body); resp.StatusCode != http.StatusCreated {
		t.Fatalf("reserve: want 201, got %d", resp.StatusCode)
	}
	if resp := do(t, "POST", srv.URL+"/orders/o1/reservation", body); resp.StatusCode != http.StatusOK {
		t.Fatalf("replay: want 200, got %d", resp.StatusCode)
	}
	if got := stock(t, db, "RB-002"); got != 37 {
		t.Errorf("RB-002 stock after reserve: want 37, got %d", got)
	}

	if resp := do(t, "DELETE", srv.URL+"/orders/o1/reservation", ""); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("release: want 204, got %d", resp.StatusCode)
	}
	if got := stock(t, db, "RB-002"); got != 40 {
		t.Errorf("RB-002 stock after release: want 40, got %d", got)
	}
	if got := stock(t, db, "RB-001"); got != 12 {
		t.Errorf("RB-001 stock after release: want 12, got %d", got)
	}
}

func TestReserveIsAllOrNothing(t *testing.T) {
	srv, db := newTestServer(t)
	// RB-004 has 8 in stock, so the whole order is refused and RB-002 is left untouched.
	resp := do(t, "POST", srv.URL+"/orders/o1/reservation", `{"items":[{"sku":"RB-002","quantity":1},{"sku":"RB-004","quantity":9}]}`)

	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("want 409, got %d", resp.StatusCode)
	}
	if got := stock(t, db, "RB-002"); got != 40 {
		t.Errorf("RB-002 stock: want 40, got %d", got)
	}
}

func TestReserveRejectsBadRequests(t *testing.T) {
	srv, _ := newTestServer(t)
	for name, tc := range map[string]struct {
		body string
		want int
	}{
		"no items":       {`{"items":[]}`, http.StatusBadRequest},
		"zero quantity":  {`{"items":[{"sku":"RB-002","quantity":0}]}`, http.StatusBadRequest},
		"duplicate sku":  {`{"items":[{"sku":"RB-002","quantity":1},{"sku":"RB-002","quantity":1}]}`, http.StatusBadRequest},
		"malformed json": {`{`, http.StatusBadRequest},
		"unknown sku":    {`{"items":[{"sku":"NOPE","quantity":1}]}`, http.StatusNotFound},
	} {
		t.Run(name, func(t *testing.T) {
			if resp := do(t, "POST", srv.URL+"/orders/o1/reservation", tc.body); resp.StatusCode != tc.want {
				t.Errorf("want %d, got %d", tc.want, resp.StatusCode)
			}
		})
	}
}

// Many orders racing for the last units must never oversell.
func TestConcurrentReservationsNeverOversell(t *testing.T) {
	srv, db := newTestServer(t)
	var wg sync.WaitGroup
	codes := make(chan int, 20)
	for i := range 20 {
		wg.Go(func() {
			req, _ := http.NewRequest("POST", srv.URL+"/orders/o"+string(rune('a'+i))+"/reservation",
				strings.NewReader(`{"items":[{"sku":"RB-004","quantity":1}]}`))
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Error(err)
				return
			}
			_ = resp.Body.Close()
			codes <- resp.StatusCode
		})
	}
	wg.Wait()
	close(codes)

	created := 0
	for c := range codes {
		if c == http.StatusCreated {
			created++
		}
	}
	if created != 8 {
		t.Errorf("RB-004 has 8 in stock: want 8 reservations, got %d", created)
	}
	if got := stock(t, db, "RB-004"); got != 0 {
		t.Errorf("RB-004 stock: want 0, got %d", got)
	}
}

// Every replica applies the schema on start; on an empty database they must not fail each other.
func TestConcurrentSchemaApplySucceeds(t *testing.T) {
	_, db := newTestServer(t)
	ctx := context.Background()
	if _, err := db.Exec(ctx, "DROP TABLE IF EXISTS reservations, products"); err != nil {
		t.Fatal(err)
	}

	var wg sync.WaitGroup
	errs := make(chan error, 4)
	for range 4 {
		wg.Go(func() { errs <- applySchema(ctx, db) })
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Error(err)
		}
	}
}
