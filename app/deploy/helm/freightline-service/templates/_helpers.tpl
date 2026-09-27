{{/*
Callers pass a dict: (dict "root" $ "svc" $svc), where $svc is one entry of .Values.services:
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
- name: OTEL_SERVICE_NAME
  value: {{ .svc.name }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: "service.namespace=freightline,deployment.environment.name={{ .root.Values.global.environment }},service.version={{ .svc.image.tag }}"
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
