## Sources

Incidents and supply chain
- Google Cloud Service Control incident (2025-06-12): https://status.cloud.google.com/incidents/ow5i3PPK96RduMcb1SsW
- CISA, tj-actions/changed-files compromise (2025-03-18): https://www.cisa.gov/news-events/alerts/2025/03/18/supply-chain-compromise-third-party-tj-actionschanged-files-cve-2025-30066-and-reviewdogaction
- Trivy advisory GHSA-69fq-xp46-6x23 (March 2026): https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23
- Cloudflare "Fail Small" plan and completion: https://blog.cloudflare.com/fail-small-resilience-plan/ · https://blog.cloudflare.com/code-orange-fail-small-complete/
- GitHub Actions secure use and OIDC: https://docs.github.com/en/actions/reference/security/secure-use · https://docs.github.com/en/actions/reference/security/oidc

Platform and delivery
- Kubernetes, Ingress-NGINX retirement: https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/
- Argo Rollouts releases: https://github.com/argoproj/argo-rollouts/releases
- OWASP Top 10:2025: https://top10.owasp.org/2025
- RFC 9457, Problem Details for HTTP APIs: https://www.rfc-editor.org/rfc/rfc9457
- Standard Webhooks specification: https://www.standardwebhooks.com/

Observability (P04)
- OpenTelemetry CNCF status: https://www.cncf.io/projects/opentelemetry/
- Prometheus OTLP guide and feature flags: https://prometheus.io/docs/guides/opentelemetry/ · https://prometheus.io/docs/prometheus/latest/feature_flags/
- Collector exporterhelper (queue, batch): https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md
- Collector contrib changelog (renames): https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/CHANGELOG.md
- Grafana Loki, OTLP ingestion: https://grafana.com/docs/loki/latest/send-data/otel/
- Loki Helm chart move to grafana-community: https://github.com/grafana/loki/tree/main/production/helm/loki · https://github.com/grafana-community/helm-charts
- Grafana Tempo 3.0 release notes: https://grafana.com/docs/tempo/latest/release-notes/v3-0/
- Alloy OpenTelemetry Engine; Grafana Agent EOL: https://grafana.com/docs/alloy/latest/set-up/otel_engine/ · https://grafana.com/docs/agent/latest/
- Sloth: https://github.com/slok/sloth
- Google SRE Workbook, "Alerting on SLOs": https://sre.google/workbook/alerting-on-slos/
- Opsgenie shutdown: https://www.atlassian.com/software/opsgenie/migration

## Related / Next

- **Next projects:** [P05-P08 Cloud, multi-cloud and IaC](./02-cloud-multicloud-and-iac.md) moves Freightline onto AWS, Azure and GCP; [P21-P24 Security and reliability](./06-security-and-reliability.md) hardens it and runs the game day on P04's telemetry.
- **Curriculum:** [C07 API design & integration](../02-curriculum/C07-api-design-and-integration.md) · [C09 Containers & Kubernetes](../02-curriculum/C09-containers-and-kubernetes.md) · [C10 DevOps & CI/CD](../02-curriculum/C10-devops-and-cicd.md) · [C12 Observability & monitoring](../02-curriculum/C12-observability-and-monitoring.md) · [C15 Production readiness & incident response](../02-curriculum/C15-production-readiness-and-incident-response.md)
- **Practice:** [Debugging and log-analysis drills](../04-drills/02-debugging-and-log-analysis-drills.md) · [Deployment and incident drills](../04-drills/03-deployment-and-incident-drills.md)
- **Interview:** [T091-T120 distributed systems, observability and AI](../07-interview/05-technical-questions-systems-observability-ai.md) · [SD01-SD14 core infrastructure design](../07-interview/06-systems-design-core-infrastructure.md)
- **Plans and templates:** [90-day plan](../08-plans/03-90-day-plan.md) · [Production readiness checklist](../../08-templates/production-readiness-checklist.md) · [Incident report template](../../08-templates/incident-report-template.md)
