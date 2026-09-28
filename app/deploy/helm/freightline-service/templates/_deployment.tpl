{{/* Deployment for one service. Pod spec follows P02 M8's library chart excerpt. */}}
{{- define "freightline-service.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .svc.name }}
  labels:
    {{- include "freightline-service.labels" . | nindent 4 }}
spec:
  # Not `.svc.replicas | default 1`: sprig's default treats 0 as empty, so replicas=0 would
  # silently render as 1 (M5 finding). hasKey keeps an explicit 0.
  replicas: {{ if hasKey .svc "replicas" }}{{ .svc.replicas }}{{ else }}1{{ end }}
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      {{- include "freightline-service.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "freightline-service.labels" . | nindent 8 }}
    spec:
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 40
      securityContext:
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: app
          image: "{{ .svc.image.repository }}:{{ .svc.image.tag }}"
          imagePullPolicy: IfNotPresent
          ports:
            - { name: http, containerPort: 8080 }
          envFrom:
            - secretRef: { name: {{ .svc.name }}-db }   # DATABASE_URL
          env:
            {{- include "freightline-service.otelEnv" . | nindent 12 }}
            {{- range $k, $v := .svc.env }}
            - name: {{ $k }}
              value: {{ $v | quote }}
            {{- end }}
          startupProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 2
            failureThreshold: 30
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 2
            failureThreshold: 2
          livenessProbe:                 # process only, never the database
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            failureThreshold: 3
          lifecycle:
            preStop:
              sleep: { seconds: 10 }     # let endpoints drain before SIGTERM; no /bin/sleep needed
          resources:
            requests: { cpu: {{ .svc.resources.cpu }}, memory: {{ .svc.resources.memory }} }
            limits: { memory: {{ .svc.resources.memory }} }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: tmp
          emptyDir: {}
{{- end }}
