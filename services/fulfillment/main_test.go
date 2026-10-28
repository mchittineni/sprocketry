package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func post(t *testing.T, h http.Handler, body string) string {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/orders", strings.NewReader(body)))
	var resp struct{ Status string }
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	return resp.Status
}

func TestSubscriptionIsAdvertised(t *testing.T) {
	sub := subscription{PubsubName: "pubsub", Topic: "orders", Route: "/orders"}
	rec := httptest.NewRecorder()
	routes(sub, 0, newSeenOrders(10)).ServeHTTP(rec, httptest.NewRequest("GET", "/dapr/subscribe", nil))

	var got []subscription
	if err := json.NewDecoder(rec.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0] != sub {
		t.Errorf("got %+v", got)
	}
}

func TestOrderIsDispatched(t *testing.T) {
	h := routes(subscription{}, 0, newSeenOrders(10))
	if got := post(t, h, `{"id":"e1","data":{"order_id":"o1","user_id":"u1","total":12.5}}`); got != "SUCCESS" {
		t.Errorf("want SUCCESS, got %s", got)
	}
}

func TestUnprocessableEventsAreDropped(t *testing.T) {
	h := routes(subscription{}, 0, newSeenOrders(10))
	for name, body := range map[string]string{
		"malformed json":   `{`,
		"missing order id": `{"id":"e1","data":{"user_id":"u1"}}`,
	} {
		if got := post(t, h, body); got != "DROP" {
			t.Errorf("%s: want DROP, got %s", name, got)
		}
	}
}

func TestDuplicateOrderIsAcknowledgedOnce(t *testing.T) {
	seen := newSeenOrders(10)
	h := routes(subscription{}, 0, seen)
	ev := `{"id":"e1","data":{"order_id":"o1"}}`

	if got := post(t, h, ev); got != "SUCCESS" {
		t.Fatalf("first: want SUCCESS, got %s", got)
	}
	// Acknowledged, so Dapr stops redelivering, but not dispatched again.
	if got := post(t, h, ev); got != "SUCCESS" {
		t.Fatalf("duplicate: want SUCCESS, got %s", got)
	}
	if seen.add("o1") {
		t.Error("o1 should already be recorded")
	}
}

func TestSeenOrdersEvictsOldest(t *testing.T) {
	seen := newSeenOrders(2)
	for _, id := range []string{"a", "b", "c"} {
		if !seen.add(id) {
			t.Fatalf("%s should be new", id)
		}
	}
	if !seen.add("a") {
		t.Error("a should have been evicted")
	}
	if seen.add("c") {
		t.Error("c should still be remembered")
	}
}
