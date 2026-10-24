# _next — Stage 3~4에서 하나씩 base로 옮길 파일 (참고용, Kustomize에 포함되지 않음)

| 파일 | 내용 | 적용 단계 |
|---|---|---|
| `web-deployment.yaml` | Nginx + 네이티브 Sidecar(log-agent), Probe, resources, topologySpread | Stage 3 |
| `was-svc-hpa-pdb.yaml` | WAS Service + HPA + PDB | Stage 3 (PDB) / Stage 4 (HPA) |
| `web-svc-pdb.yaml` | WEB Service + PDB | Stage 3 |
| `db-report-cronjob.yaml` | DB 현황 리포트 CronJob | Stage 3 |

> WAS의 3종 Probe / resources / topologySpread 원본은 Git 히스토리(`k8s/base/was-deployment.yaml`, 커밋 `efca73c` 이전)에 있습니다.
