{{/*
Callers pass a dict: (dict "root" $ "svc" $svc), where $svc is one .Values.services entry with its key added as name:
  name, image {repository, tag}, replicas, resources {cpu, memory}, env {KEY: value}
*/}}

{{- define "freightline-service.labels" -}}
app.kubernetes.io/name: {{ .svc.name }}
app.kubernetes.io/part-of: freightline
app.kubernetes.io/version: {{ .svc.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}

{{- define "freightline-service.selectorLabels" -}}
app.kubernetes.io/name: {{ .svc.name }}
{{- end }}

{{/*
The OpenTelemetry environment contract (P02 M7). Applications read only these variables and
never name a backend: where telemetry goes is the gateway's decision (ADR-P04-1).
*/}}
{{- define "freightline-service.otelEnv" -}}
# Downward API first: Kubernetes expands $(VAR) only from variables defined earlier in this list.
- name: POD_UID                        # unique per pod, stable for its lifetime
  valueFrom: { fieldRef: { fieldPath: metadata.uid } }
- name: POD_TEMPLATE_HASH              # which ReplicaSet (rollout revision) this pod belongs to; P03 compares canary vs stable on it
  valueFrom: { fieldRef: { fieldPath: "metadata.labels['pod-template-hash']" } }
- name: OTEL_SERVICE_NAME
  value: {{ .svc.name }}
# service.instance.id: without it two replicas push identical series, so Prometheus sees
# counters "reset" and rate() spikes (spec section 12). Prometheus maps it to `instance`.
- name: OTEL_RESOURCE_ATTRIBUTES
  value: "service.namespace=freightline,deployment.environment.name={{ .root.Values.global.environment }},service.version={{ .svc.image.tag }},service.instance.id=$(POD_UID),freightline.pod_template_hash=$(POD_TEMPLATE_HASH)"
# Histogram samples keep the trace ID of a sampled request: the metric -> trace hop (FR-4).
- name: OTEL_METRICS_EXEMPLAR_FILTER
  value: trace_based
# Python only (Go filters in code, see orders main.go): no spans or metrics for kubelet probes.
- name: OTEL_PYTHON_FASTAPI_EXCLUDED_URLS
  value: "healthz,readyz"
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ .root.Values.global.otlpEndpoint | quote }}
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: grpc
- name: OTEL_SEMCONV_STABILITY_OPT_IN   # Python emits the same stable metric names as Go
  value: http,database
- name: OTEL_TRACES_SAMPLER
  value: parentbased_traceidratio
- name: OTEL_TRACES_SAMPLER_ARG
  value: {{ .root.Values.global.traceSampleRatio | quote }}
- name: OTEL_LOGS_EXPORTER             # logs go to stdout for the node agent (ADR-P04-2)
  value: none
{{- end }}
