{{- define "maas.namespace" -}}
{{ .Values.namespace | default "opendatahub" }}
{{- end }}

{{- define "maas.labels" -}}
app.kubernetes.io/part-of: models-as-a-service
app.kubernetes.io/managed-by: helm
{{- end }}

{{- define "maas.gateway.namespace" -}}
{{ .Values.gateway.namespace | default "istio-system" }}
{{- end }}

{{- define "maas.gateway.name" -}}
{{ .Values.gateway.name | default "maas-default-gateway" }}
{{- end }}
