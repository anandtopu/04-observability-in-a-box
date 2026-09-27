{{/* ClusterIP Service and PodDisruptionBudget for one service. */}}
{{- define "freightline-service.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ .svc.name }}
  labels:
    {{- include "freightline-service.labels" . | nindent 4 }}
spec:
  selector:
    {{- include "freightline-service.selectorLabels" . | nindent 4 }}
  ports:
    - { name: http, port: 8080, targetPort: http }
{{- end }}

{{- define "freightline-service.pdb" -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .svc.name }}
  labels:
    {{- include "freightline-service.labels" . | nindent 4 }}
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      {{- include "freightline-service.selectorLabels" . | nindent 6 }}
{{- end }}

{{/* Everything one service needs, separated as YAML documents. */}}
{{- define "freightline-service.all" -}}
{{ include "freightline-service.deployment" . }}
---
{{ include "freightline-service.service" . }}
---
{{ include "freightline-service.pdb" . }}
{{- end }}
