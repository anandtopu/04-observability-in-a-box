package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"testing"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	"github.com/anandtopu/04-observability-in-a-box/app/services/orders/internal/telemetry"
)

type failingRT struct{}

func (failingRT) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("context deadline exceeded")
}

// A failed inventory call must be logged with the HTTP POST client span's span_id (not the caller's),
// so Grafana's "Logs for this span" on the failing span returns the line (M8 game day, step 4).
func TestFailedCallIsLoggedInTheClientSpan(t *testing.T) {
	spans := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(spans))
	otel.SetTracerProvider(tp)
	var buf bytes.Buffer
	slog.SetDefault(slog.New(telemetry.LogHandler{Handler: slog.NewJSONHandler(&buf, nil)}))

	ctx, parent := tp.Tracer("test").Start(context.Background(), "POST /v1/orders")
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, "http://inventory:8080/v1/reservations", nil)
	client := &http.Client{Transport: otelhttp.NewTransport(spanLogTransport{failingRT{}})}
	if _, err := client.Do(req); err == nil {
		t.Fatal("expected an error")
	}
	parent.End()

	var line map[string]any
	if err := json.Unmarshal(buf.Bytes(), &line); err != nil {
		t.Fatalf("log line is not JSON: %q", buf.String())
	}
	var clientSpan string
	for _, s := range spans.Ended() {
		if s.Name() == "HTTP POST" {
			clientSpan = s.SpanContext().SpanID().String()
		}
	}
	if clientSpan == "" {
		t.Fatalf("no HTTP POST span recorded")
	}
	if line["msg"] != "inventory call failed" || line["span_id"] != clientSpan {
		t.Fatalf("want msg %q with span_id %s (the client span), got msg %v span_id %v (parent %s)",
			"inventory call failed", clientSpan, line["msg"], line["span_id"], parent.SpanContext().SpanID())
	}
	if line["trace_id"] != parent.SpanContext().TraceID().String() {
		t.Fatalf("trace_id %v is not the request's trace", line["trace_id"])
	}
}
