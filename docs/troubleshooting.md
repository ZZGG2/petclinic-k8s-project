# 트러블슈팅 기록

| # | 단계 | 증상 | 원인 | 해결 |
|---|---|---|---|---|
| 1 | 준비 | Ingress 기반 계획 | 커뮤니티 ingress-nginx 컨트롤러가 2026년 3월 지원 종료 (Ingress API 자체는 유지) | AWS Load Balancer Controller의 Gateway API 구현으로 변경 |
| 2 | 준비 | Gateway 매니페스트 적용 실패 예상 | LBC v3.4.1 CRD는 `gateway.k8s.aws/v1beta1`만 제공 (최신 문서는 `v1`) | 설치할 버전의 CRD 파일을 직접 확인해 `v1beta1`로 작성 |
| 3 | 1 | WAS 이미지 빌드 실패 `Could not find artifact mysql:mysql-connector-java:jar:8.1.0` | 8.0.31부터 좌표가 `com.mysql:mysql-connector-j`로 바뀜 | Dockerfile에서 빌드 전에 `pom.xml` 좌표 교체 |
| 4 | 1 | WAS 파드 CrashLoopBackOff | `catalina.sh`가 `JAVA_OPTS`를 `eval`로 펼쳐 URL의 `&`, 비밀번호의 `#`이 셸 문법으로 해석됨 | 셸을 거치지 않는 `JDK_JAVA_OPTIONS` 사용 |
| 5 | 1 | 파드는 Running인데 `/petclinic/` 404, `Connection refused` | Maven 리소스 필터링이 XML의 `${jdbc.url}`까지 `localhost`로 바꿔 둠. `-D` 옵션으로도 바꿀 수 없음 | 빌드 후 XML 플레이스홀더 복원 + 설정 파일을 Secret `subPath`로 교체. [상세](troubleshooting-was-db-connection.md) |
| 6 | 2 | ExternalName Service 생성 실패 `spec.externalName: Required value` | `RDS_ENDPOINT`를 `export` 없이 선언해 `envsubst`가 빈 값으로 치환 | 파이프로 넘기는 변수는 `export`, 이후 `kapply` 함수로 통일 |
| 7 | 3 | DB를 멈춰도 `/vets`는 200 | `findVets()`에 `@Cacheable` 적용 | readiness는 매번 DB를 조회하는 `/owners?lastName=` 사용 |
| 8 | 4 | HPA 도입 시 replicas가 1로 떨어질 위험 | 매니페스트에서 `replicas`를 지우면 `kubectl apply`가 필드 삭제로 판단 | HPA 먼저 생성 → `kubectl apply set-last-applied` → `apply` |
| 9 | 4 | KEDA 계산이 맞지 않음 (계획 단계) | `RequestCountPerTarget`은 이미 파드 수로 나눈 값이라 `AverageValue` 계산과 겹침 | 대상 그룹 총 요청 수 `RequestCount` + 파드당 목표값 |
| 10 | 4 | Taint 후 파드가 Pending, 노드 생성 안 됨 | NodePool이 적용되지 않음 (EC2NodeClass만 존재) | NodePool 적용 → 1분 안에 Spot 노드 생성 |
| 11 | 4 | Karpenter 버전 | 계획에 있던 1.3.x는 Kubernetes 1.32까지만 지원 | EKS 1.36과 호환되는 1.14.2 사용 |
| 12 | 5 | External Secrets 전환 후 새 WAS 기동 실패, CronJob 실패 | Secrets Manager에 넣은 비밀번호가 실제 DB와 다름 (기존 Secret 삭제 후 값을 읽음) | 실행 중인 옛 WAS 파드와 DB 파드에서 원래 값을 확인해 복구. `maxUnavailable: 0`이라 서비스는 유지됨 |
| 13 | 5 | 비밀번호 교체 후 WAS만 옛 값 사용 | `subPath`로 마운트한 파일은 Secret이 바뀌어도 갱신되지 않음 | 교체 순서에 WAS 재시작 포함 (CronJob은 새 파드라 자동 반영) |
| 14 | 공통 | 새 이미지 롤아웃이 멈춤 `ImagePullBackOff ... not found` | 태그를 올린 매니페스트는 적용했지만 이미지 푸시가 안 됨 (ECR 로그인 토큰 12시간 만료) | 재로그인 후 푸시. 옛 파드는 계속 서비스 |

## 3-Tier 장애를 확인한 순서

```text
사용자 → ALB → WEB(Nginx) → WAS(Tomcat) → Service(petclinic-db) → DB
```

| 확인 | 배제되는 구간 |
|---|---|
| `curl https://도메인/` vs `/petclinic/` | ALB → WEB |
| WEB 파드에서 `wget http://petclinic-was:8080/petclinic/` | Nginx 프록시 |
| `kubectl get endpointslices` | Service ↔ 파드 라벨 |
| WAS 파드에서 `/dev/tcp/petclinic-db/3306` | 네트워크, DNS |
| DB 파드에서 `mysql -u... -e "SELECT 1"` | DB 계정, 권한 |
| WAS 파드에서 단일 Java 파일로 JDBC 접속 | 드라이버, 애플리케이션 외부 요인 |

여기까지 모두 정상이면 원인은 애플리케이션 설정에 있다고 보고 빌드 결과물(WAR 내부)을 확인했습니다.
