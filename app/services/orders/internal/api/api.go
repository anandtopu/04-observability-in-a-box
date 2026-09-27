// Package api implements the P04-lite orders API: POST /v1/orders and GET /v1/orders/{id}.
// P02 confirms orders asynchronously over Kafka; P04-lite has no Kafka, so orders reserves
// stock with a synchronous HTTP call to inventory. That still yields one trace across two
// services and two languages, which is what P04 needs to observe.
package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

const schema = `
CREATE TABLE IF NOT EXISTS orders (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key text NOT NULL UNIQUE,
  sku             text NOT NULL,
  qty             int  NOT NULL CHECK (qty > 0),
  ship_to         text NOT NULL,
  consignee_name  text NOT NULL,
  status          text NOT NULL DEFAULT 'PENDING',
  created_at      timestamptz NOT NULL DEFAULT now()
)`

// Migrate creates the schema. Good enough for a lab stand-in; P02 uses real migrations.
func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	_, err := pool.Exec(ctx, schema)
	return err
}

type Order struct {
	ID            string    `json:"id"`
	SKU           string    `json:"sku"`
	Qty           int       `json:"qty"`
	ShipTo        string    `json:"ship_to"`
	ConsigneeName string    `json:"consignee_name"`
	Status        string    `json:"status"`
	CreatedAt     time.Time `json:"created_at"`
}

type InventoryClient struct {
	base string
	http *http.Client
}

// NewInventoryClient returns a client whose transport injects traceparent and records a
// client span per call, so inventory's server span becomes a child of orders' span.
func NewInventoryClient(base string) *InventoryClient {
	return &InventoryClient{base: base, http: &http.Client{Transport: otelhttp.NewTransport(http.DefaultTransport)}}
}

var errOutOfStock = errors.New("out of stock")

// Reserve asks inventory to hold stock for the order, within P02's 300 ms budget.
func (c *InventoryClient) Reserve(ctx context.Context, o Order) error {
	ctx, cancel := context.WithTimeout(ctx, 300*time.Millisecond)
	defer cancel()
	body, _ := json.Marshal(map[string]any{"order_id": o.ID, "sku": o.SKU, "qty": o.Qty})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base+"/v1/reservations", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusCreated, http.StatusOK:
		return nil
	case http.StatusConflict:
		return errOutOfStock
	default:
		return fmt.Errorf("inventory returned %d", resp.StatusCode)
	}
}

// Register mounts the orders API on mux.
func Register(mux *http.ServeMux, pool *pgxpool.Pool, inv *InventoryClient) {
	fault5xx, _ := strconv.ParseFloat(os.Getenv("FAULT_5XX_RATE"), 64) // P03's fault hook; M6 burn tests use it

	mux.HandleFunc("POST /v1/orders", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		if fault5xx > 0 && rand.Float64() < fault5xx {
			slog.ErrorContext(ctx, "injected fault", "fault", "FAULT_5XX_RATE", "rate", fault5xx)
			http.Error(w, "injected fault", http.StatusInternalServerError)
			return
		}
		key := r.Header.Get("Idempotency-Key")
		if key == "" {
			http.Error(w, "Idempotency-Key header is required", http.StatusBadRequest)
			return
		}
		var in Order
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.SKU == "" || in.Qty <= 0 {
			http.Error(w, "body must be {sku, qty>0, ship_to, consignee_name}", http.StatusBadRequest)
			return
		}

		o, created, err := insertOrder(ctx, pool, key, in)
		if err != nil {
			slog.ErrorContext(ctx, "insert order", "err", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		if created {
			o.Status = reserve(ctx, pool, inv, o)
		}
		// ship_to and consignee_name are PII: they are logged in-cluster on purpose, so
		// that M7's attributes/pii processor has something real to strip on export.
		slog.InfoContext(ctx, "order accepted", "order_id", o.ID, "sku", o.SKU, "qty", o.Qty,
			"status", o.Status, "replay", !created, "ship_to", o.ShipTo, "consignee_name", o.ConsigneeName)
		w.Header().Set("Location", "/v1/orders/"+o.ID)
		writeJSON(w, http.StatusAccepted, o)
	})

	mux.HandleFunc("GET /v1/orders/{id}", func(w http.ResponseWriter, r *http.Request) {
		o, err := getOrder(r.Context(), pool, r.PathValue("id"))
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			http.Error(w, "not found", http.StatusNotFound)
		case err != nil:
			http.Error(w, "bad order id", http.StatusBadRequest)
		default:
			writeJSON(w, http.StatusOK, o)
		}
	})
}

// insertOrder creates a PENDING order, or returns the existing one for a replayed key.
func insertOrder(ctx context.Context, pool *pgxpool.Pool, key string, in Order) (Order, bool, error) {
	o := in
	err := pool.QueryRow(ctx, `
		INSERT INTO orders (idempotency_key, sku, qty, ship_to, consignee_name)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (idempotency_key) DO NOTHING
		RETURNING id::text, status, created_at`, key, in.SKU, in.Qty, in.ShipTo, in.ConsigneeName).
		Scan(&o.ID, &o.Status, &o.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		err = pool.QueryRow(ctx, `SELECT id::text FROM orders WHERE idempotency_key = $1`, key).Scan(&o.ID)
		if err != nil {
			return Order{}, false, err
		}
		o, err = getOrder(ctx, pool, o.ID)
		return o, false, err
	}
	return o, err == nil, err
}

// reserve moves the order to CONFIRMED or REJECTED. If inventory is slow or down the
// order stays PENDING (P02's degraded pre-check) instead of failing the request.
func reserve(ctx context.Context, pool *pgxpool.Pool, inv *InventoryClient, o Order) string {
	status := "CONFIRMED"
	if err := inv.Reserve(ctx, o); errors.Is(err, errOutOfStock) {
		status = "REJECTED"
	} else if err != nil {
		slog.WarnContext(ctx, "inventory precheck degraded", "order_id", o.ID, "err", err)
		return "PENDING"
	}
	if _, err := pool.Exec(ctx, `UPDATE orders SET status = $2 WHERE id = $1`, o.ID, status); err != nil {
		slog.ErrorContext(ctx, "update status", "order_id", o.ID, "err", err)
		return "PENDING"
	}
	return status
}

func getOrder(ctx context.Context, pool *pgxpool.Pool, id string) (Order, error) {
	var o Order
	err := pool.QueryRow(ctx, `
		SELECT id::text, sku, qty, ship_to, consignee_name, status, created_at
		FROM orders WHERE id = $1::uuid`, id).
		Scan(&o.ID, &o.SKU, &o.Qty, &o.ShipTo, &o.ConsigneeName, &o.Status, &o.CreatedAt)
	return o, err
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
