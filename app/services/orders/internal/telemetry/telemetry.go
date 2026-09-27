// Package telemetry wires the OpenTelemetry SDK from the standard OTEL_* environment
// (the P02 contract): OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES and
// OTEL_EXPORTER_OTLP_ENDPOINT. The code never names a backend; the gateway decides.
package telemetry

import (
	"context"
	"errors"
	"log/slog"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

// Setup installs global tracer and meter providers that push OTLP/gRPC.
// The returned function flushes and stops both; call it on shutdown.
func Setup(ctx context.Context) (func(context.Context) error, error) {
	// WithFromEnv reads OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES, so
	// service.namespace, service.version and (from M1) service.instance.id come from the chart.
	res, err := resource.New(ctx, resource.WithFromEnv(), resource.WithTelemetrySDK())
	if err != nil {
		return nil, err
	}

	// Both exporters read OTEL_EXPORTER_OTLP_ENDPOINT. They retry and drop on failure,
	// so the app keeps serving when the gateway is down (it is not installed until M4).
	traceExp, err := otlptracegrpc.New(ctx)
	if err != nil {
		return nil, err
	}
	metricExp, err := otlpmetricgrpc.New(ctx)
	if err != nil {
		return nil, err
	}

	// The sampler comes from OTEL_TRACES_SAMPLER / _ARG (parentbased_traceidratio in the chart).
	tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(traceExp), sdktrace.WithResource(res))
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExp)), sdkmetric.WithResource(res))
	otel.SetTracerProvider(tp)
	otel.SetMeterProvider(mp)
	// W3C traceparent in and out, so orders -> inventory is one trace.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))

	return func(ctx context.Context) error {
		return errors.Join(tp.Shutdown(ctx), mp.Shutdown(ctx))
	}, nil
}

// LogHandler adds trace_id and span_id to every JSON log line written with a context
// that carries a span. The P04 agent lifts these fields into Loki structured metadata.
type LogHandler struct{ slog.Handler }

func (h LogHandler) Handle(ctx context.Context, r slog.Record) error {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		r.AddAttrs(slog.String("trace_id", sc.TraceID().String()), slog.String("span_id", sc.SpanID().String()))
	}
	return h.Handler.Handle(ctx, r)
}

func (h LogHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return LogHandler{h.Handler.WithAttrs(attrs)}
}

func (h LogHandler) WithGroup(name string) slog.Handler { return LogHandler{h.Handler.WithGroup(name)} }
