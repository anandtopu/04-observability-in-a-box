// orders: the P04-lite stand-in for Freightline's Go service (P02 M1/M2 lifecycle).
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"github.com/anandtopu/04-observability-in-a-box/app/services/orders/internal/api"
	"github.com/anandtopu/04-observability-in-a-box/app/services/orders/internal/telemetry"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	// Lowercase levels (info, warn, error) match inventory's logs and the agent's severity mapping.
	lower := func(_ []string, a slog.Attr) slog.Attr {
		if a.Key == slog.LevelKey {
			a.Value = slog.StringValue(strings.ToLower(a.Value.String()))
		}
		return a
	}
	log := slog.New(telemetry.LogHandler{Handler: slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{ReplaceAttr: lower})})
	slog.SetDefault(log)

	shutdownOTel, err := telemetry.Setup(ctx)
	if err != nil {
		log.Error("otel setup", "err", err)
		os.Exit(1)
	}

	cfg, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Error("db config", "err", err)
		os.Exit(1)
	}
	cfg.ConnConfig.Tracer = otelpgx.NewTracer() // one client span per SQL statement
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		log.Error("db pool", "err", err)
		os.Exit(1)
	}
	var ready atomic.Bool
	mux := http.NewServeMux()
	api.Register(mux, pool, api.NewInventoryClient(getenv("INVENTORY_URL", "http://inventory:8080")))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		if !ready.Load() || pool.Ping(r.Context()) != nil {
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})

	// Kubelet probes are about 0.6 req/s of free "good" traffic per pod: they would inflate
	// the availability SLO and keep idle rates above zero. Filtered requests are still served,
	// but produce no span and no histogram sample (P04 M1).
	notProbe := func(r *http.Request) bool { return r.URL.Path != "/healthz" && r.URL.Path != "/readyz" }
	// Span names follow HTTP semconv ("POST /v1/orders"). otelhttp calls the formatter again
	// after routing, when ServeMux has filled in r.Pattern; before that only the method is known.
	spanName := func(_ string, r *http.Request) string {
		if r.Pattern != "" {
			return r.Pattern
		}
		return r.Method
	}
	apiHandler := otelhttp.NewHandler(routeLabel(mux), "orders",
		otelhttp.WithFilter(notProbe), otelhttp.WithSpanNameFormatter(spanName))
	srv := &http.Server{Addr: ":8080", Handler: apiHandler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 60 * time.Second}
	go func() {
		if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
			log.Error("listen", "addr", srv.Addr, "err", err)
			stop()
		}
	}()
	log.Info("orders started", "addr", srv.Addr)

	// Readiness waits for the schema. Postgres may be in initdb or restarting when this pod
	// starts, so retry instead of exiting: /healthz stays green (the process is fine) and
	// /readyz keeps traffic away until the database is usable. No restart is recorded.
	go func() {
		for attempt := 1; ctx.Err() == nil; attempt++ {
			// Bound each attempt: with no Postgres pod behind the Service, a TCP connect can
			// hang for the kernel's SYN timeout (~2 minutes) instead of failing fast.
			attemptCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
			err := api.Migrate(attemptCtx, pool)
			cancel()
			if err == nil {
				ready.Store(true)
				log.Info("database ready", "attempts", attempt)
				return
			}
			log.Warn("database not ready, retrying", "err", err, "attempt", attempt)
			select {
			case <-ctx.Done():
			case <-time.After(min(time.Duration(attempt)*time.Second, 5*time.Second)):
			}
		}
	}()

	<-ctx.Done() // SIGTERM arrives after the chart's preStop sleep
	ready.Store(false)
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	pool.Close()
	_ = shutdownOTel(shutdownCtx) // flush the last spans and metric points
	log.Info("shutdown complete")
}

// routeLabel adds the matched route as http.route to the server span and to the duration
// histogram. ServeMux writes the pattern into r.Pattern while routing, so it is known once the
// handler returns. Bounded cardinality: a route template, never an order ID.
func routeLabel(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		next.ServeHTTP(w, r)
		_, route, ok := strings.Cut(r.Pattern, " ")
		if !ok {
			return // no route matched (404)
		}
		trace.SpanFromContext(r.Context()).SetAttributes(attribute.String("http.route", route))
		if l, found := otelhttp.LabelerFromContext(r.Context()); found {
			l.Add(attribute.String("http.route", route))
		}
	})
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
