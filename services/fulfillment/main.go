// Command fulfillment consumes OrderPlaced events from the Dapr pub/sub component and dispatches them.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

type subscription struct {
	PubsubName string `json:"pubsubname"`
	Topic      string `json:"topic"`
	Route      string `json:"route"`
}

// cloudEvent is the envelope Dapr wraps every published message in.
type cloudEvent struct {
	ID   string `json:"id"`
	Data Order  `json:"data"`
}

type Order struct {
	OrderID string  `json:"order_id"`
	UserID  string  `json:"user_id"`
	Total   float64 `json:"total"`
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Simulated warehouse processing time, the equivalent of robot-shop's dispatch delay.
	maxDelay, _ := strconv.Atoi(env("DISPATCH_MAX_DELAY_MS", "500"))

	sub := subscription{PubsubName: env("PUBSUB_NAME", "pubsub"), Topic: env("ORDERS_TOPIC", "orders"), Route: "/orders"}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("GET /dapr/subscribe", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode([]subscription{sub})
	})
	mux.HandleFunc("POST /orders", func(w http.ResponseWriter, r *http.Request) {
		var ev cloudEvent
		if err := json.NewDecoder(r.Body).Decode(&ev); err != nil {
			// DROP tells Dapr not to redeliver a message that can never be parsed.
			logger.Error("malformed event", "err", err)
			writeStatus(w, "DROP")
			return
		}
		if maxDelay > 0 {
			time.Sleep(time.Duration(rand.IntN(maxDelay)) * time.Millisecond)
		}
		logger.Info("order dispatched", "order_id", ev.Data.OrderID, "user_id", ev.Data.UserID, "total", ev.Data.Total)
		writeStatus(w, "SUCCESS")
	})

	srv := &http.Server{Addr: ":" + env("PORT", "8080"), Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		logger.Info("fulfillment listening", "addr", srv.Addr, "topic", sub.Topic)
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

func writeStatus(w http.ResponseWriter, status string) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"status": status})
}

func env(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return fallback
}
