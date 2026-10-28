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
	"sync"
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

	srv := &http.Server{Addr: ":" + env("PORT", "8080"), Handler: routes(sub, maxDelay, newSeenOrders(10000)), ReadHeaderTimeout: 5 * time.Second}
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

func routes(sub subscription, maxDelay int, seen *seenOrders) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("GET /dapr/subscribe", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode([]subscription{sub})
	})
	mux.HandleFunc("POST /orders", func(w http.ResponseWriter, r *http.Request) {
		var ev cloudEvent
		if err := json.NewDecoder(r.Body).Decode(&ev); err != nil || ev.Data.OrderID == "" {
			// DROP tells Dapr not to redeliver a message that can never be processed.
			slog.Error("malformed event", "err", err, "event_id", ev.ID)
			writeStatus(w, "DROP")
			return
		}
		// Delivery is at least once, and a retried checkout republishes the same order ID.
		if !seen.add(ev.Data.OrderID) {
			slog.Info("duplicate order ignored", "order_id", ev.Data.OrderID)
			writeStatus(w, "SUCCESS")
			return
		}
		if maxDelay > 0 {
			time.Sleep(time.Duration(rand.IntN(maxDelay)) * time.Millisecond)
		}
		slog.Info("order dispatched", "order_id", ev.Data.OrderID, "user_id", ev.Data.UserID, "total", ev.Data.Total)
		writeStatus(w, "SUCCESS")
	})
	return mux
}

// seenOrders remembers the most recent order IDs, oldest evicted first. It lives in this process only,
// which is enough while fulfillment runs as a single replica.
type seenOrders struct {
	mu    sync.Mutex
	limit int
	ids   map[string]struct{}
	order []string
}

func newSeenOrders(limit int) *seenOrders {
	return &seenOrders{limit: limit, ids: map[string]struct{}{}}
}

// add records id and reports whether it is new.
func (s *seenOrders) add(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.ids[id]; ok {
		return false
	}
	s.ids[id] = struct{}{}
	s.order = append(s.order, id)
	if len(s.order) > s.limit {
		delete(s.ids, s.order[0])
		s.order = s.order[1:]
	}
	return true
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
