// Command catalog serves the product catalogue from PostgreSQL.
package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Product struct {
	SKU         string  `json:"sku"`
	Name        string  `json:"name"`
	Description string  `json:"description"`
	Category    string  `json:"category"`
	Price       float64 `json:"price"`
	Stock       int     `json:"stock"`
}

// schema is idempotent, so it is safe to apply on every start.
//
//go:embed schema.sql
var schema string

const schemaLock = "SELECT pg_advisory_xact_lock(hashtext('catalog-schema'));\n"

// ReservationItem is one line of an order whose stock is being held.
type ReservationItem struct {
	SKU      string `json:"sku"`
	Quantity int    `json:"quantity"`
}

type server struct {
	db *pgxpool.Pool
}

type outOfStockError struct{ sku string }

func (e *outOfStockError) Error() string { return "out of stock: " + e.sku }

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	db, err := pgxpool.New(ctx, env("DATABASE_URL", "postgres://sprocketry:sprocketry@localhost:5432/catalog"))
	if err != nil {
		logger.Error("connect database", "err", err)
		os.Exit(1)
	}
	defer db.Close()

	if err := applySchema(ctx, db); err != nil {
		logger.Error("apply schema", "err", err)
		os.Exit(1)
	}

	s := &server{db: db}
	srv := &http.Server{Addr: ":" + env("PORT", "8080"), Handler: s.routes(), ReadHeaderTimeout: 5 * time.Second}
	go func() {
		logger.Info("catalog listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("serve", "err", err)
			stop()
		}
	}()

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
}

// applySchema runs on every replica's start. Exec without arguments uses the simple protocol, which
// allows multiple statements and runs them as one transaction. Concurrent CREATE TABLE IF NOT EXISTS on an
// empty database fails all but one caller, so the advisory lock makes replicas take turns.
func applySchema(ctx context.Context, db *pgxpool.Pool) error {
	_, err := db.Exec(ctx, schemaLock+schema)
	return err
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("GET /readyz", s.ready)
	mux.HandleFunc("GET /products", s.listProducts)
	mux.HandleFunc("GET /products/{sku}", s.getProduct)
	mux.HandleFunc("POST /orders/{id}/reservation", s.reserve)
	mux.HandleFunc("DELETE /orders/{id}/reservation", s.release)
	return mux
}

func (s *server) ready(w http.ResponseWriter, r *http.Request) {
	if err := s.db.Ping(r.Context()); err != nil {
		http.Error(w, "database unavailable", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (s *server) listProducts(w http.ResponseWriter, r *http.Request) {
	query := `SELECT sku, name, description, category, price, stock FROM products`
	args := []any{}
	if c := r.URL.Query().Get("category"); c != "" {
		query += ` WHERE category = $1`
		args = append(args, c)
	}
	rows, err := s.db.Query(r.Context(), query+` ORDER BY name`, args...)
	if err != nil {
		writeError(w, err)
		return
	}
	products, err := pgx.CollectRows(rows, pgx.RowToStructByPos[Product])
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, products)
}

func (s *server) getProduct(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.Query(r.Context(),
		`SELECT sku, name, description, category, price, stock FROM products WHERE sku = $1`, r.PathValue("sku"))
	if err != nil {
		writeError(w, err)
		return
	}
	p, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Product])
	if errors.Is(err, pgx.ErrNoRows) {
		http.Error(w, "product not found", http.StatusNotFound)
		return
	}
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, p)
}

// reserve takes an order's items out of stock, all or nothing. Reserving the same order again is a
// no-op, so payment can retry safely: 201 means newly reserved, 200 means it already was.
func (s *server) reserve(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Items []ReservationItem `json:"items"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil || len(req.Items) == 0 {
		http.Error(w, "items are required", http.StatusBadRequest)
		return
	}
	seen := map[string]bool{}
	for _, it := range req.Items {
		if it.SKU == "" || it.Quantity <= 0 || seen[it.SKU] {
			http.Error(w, "each item needs a unique sku and a positive quantity", http.StatusBadRequest)
			return
		}
		seen[it.SKU] = true
	}
	// Concurrent orders lock product rows in the same order, so they cannot deadlock.
	slices.SortFunc(req.Items, func(a, b ReservationItem) int { return strings.Compare(a.SKU, b.SKU) })

	orderID := r.PathValue("id")
	err := pgx.BeginFunc(r.Context(), s.db, func(tx pgx.Tx) error {
		for _, it := range req.Items {
			if _, err := tx.Exec(r.Context(),
				`INSERT INTO reservations (order_id, sku, quantity) VALUES ($1, $2, $3)`, orderID, it.SKU, it.Quantity); err != nil {
				return err
			}
			tag, err := tx.Exec(r.Context(),
				`UPDATE products SET stock = stock - $2 WHERE sku = $1 AND stock >= $2`, it.SKU, it.Quantity)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				return &outOfStockError{sku: it.SKU}
			}
		}
		return nil
	})

	var pgErr *pgconn.PgError
	var oos *outOfStockError
	switch {
	case err == nil:
		w.WriteHeader(http.StatusCreated)
	case errors.As(err, &pgErr) && pgErr.Code == "23505": // unique_violation: this order is already reserved
		w.WriteHeader(http.StatusOK)
	case errors.As(err, &pgErr) && pgErr.Code == "23503": // foreign_key_violation
		http.Error(w, "unknown sku", http.StatusNotFound)
	case errors.As(err, &oos):
		http.Error(w, oos.Error(), http.StatusConflict)
	default:
		writeError(w, err)
	}
}

// release puts an order's reserved stock back. Releasing an unknown order is a no-op.
func (s *server) release(w http.ResponseWriter, r *http.Request) {
	_, err := s.db.Exec(r.Context(), `
		WITH released AS (DELETE FROM reservations WHERE order_id = $1 RETURNING sku, quantity)
		UPDATE products p SET stock = p.stock + released.quantity FROM released WHERE p.sku = released.sku`,
		r.PathValue("id"))
	if err != nil {
		writeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, err error) {
	slog.Error("request failed", "err", err)
	http.Error(w, "internal error", http.StatusInternalServerError)
}

func env(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return fallback
}
