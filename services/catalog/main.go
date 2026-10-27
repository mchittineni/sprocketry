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
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
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

type server struct {
	db *pgxpool.Pool
}

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

	// Exec without arguments uses the simple protocol, which allows multiple statements.
	if _, err := db.Exec(ctx, schema); err != nil {
		logger.Error("apply schema", "err", err)
		os.Exit(1)
	}

	s := &server{db: db}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("GET /readyz", s.ready)
	mux.HandleFunc("GET /products", s.listProducts)
	mux.HandleFunc("GET /products/{sku}", s.getProduct)

	srv := &http.Server{Addr: ":" + env("PORT", "8080"), Handler: mux, ReadHeaderTimeout: 5 * time.Second}
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
