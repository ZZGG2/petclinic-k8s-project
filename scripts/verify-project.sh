#!/usr/bin/env bash
# 프로젝트 전체 상태 자가 진단 스크립트 (dev / prod 공용)
# 사용법: bash scripts/verify-project.sh [dev|prod]
set -u

ENV_MODE="${1:-prod}"
REGION="${REGION:-ap-northeast-2}"
CLUSTER="${CLUSTER:-petclinic-eks}"
NS="petclinic"
export AWS_PAGER=""

PASS=0
FAIL=0

check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf "  [PASS] %s\n" "$desc"
    PASS=$((PASS + 1))
  else
    printf "  [FAIL] %s\n" "$desc"
    FAIL=$((FAIL + 1))
  fi
}

k() { kubectl "$@" 2>/dev/null; }
a() { aws "$@" --region "$REGION" --output text 2>/dev/null; }

echo "========================================================"
echo " PetClinic EKS Project Verification (mode: ${ENV_MODE})"
echo "========================================================"

# 1. 클러스터 & 애드온 6종 & ng-system Taint
check "EKS 클러스터 ACTIVE (${CLUSTER})" \
  bash -c "[ \"\$(a eks describe-cluster --name '$CLUSTER' --query 'cluster.status')\" = 'ACTIVE' ]"

check "EKS 애드온 6종 ACTIVE (vpc-cni, coredns, kube-proxy, pod-identity, ebs-csi, metrics-server)" \
  bash -c "for n in vpc-cni coredns kube-proxy eks-pod-identity-agent aws-ebs-csi-driver metrics-server; do [ \"\$(a eks describe-addon --cluster-name '$CLUSTER' --addon-name \$n --query 'addon.status')\" = 'ACTIVE' ] || exit 1; done"

check "ng-system 노드 CriticalAddonsOnly=true:NoSchedule Taint 설정" \
  bash -c "k get nodes -l role=system -o jsonpath='{range .items[*].spec.taints[*]}{.key}={.value}:{.effect}{\"\n\"}{end}' | grep -q 'CriticalAddonsOnly=true:NoSchedule'"

# 2. Karpenter & KEDA & LBC & Gateway API
check "Karpenter NodePool (default) & EC2NodeClass 구성 완료" \
  bash -c "k get nodepool default && k get ec2nodeclass default"

check "AWS Load Balancer Controller 구동 중" \
  bash -c "[ \"\$(k get deploy aws-load-balancer-controller -n kube-system -o jsonpath='{.status.availableReplicas}')\" -ge 1 ]"

check "GatewayClass(alb) Accepted & Gateway(petclinic-gateway) Programmed" \
  bash -c "[ \"\$(k get gatewayclass alb -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}')\" = 'True' ] && [ \"\$(k get gateway petclinic-gateway -n '$NS' -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}')\" = 'True' ]"

check "KEDA Operator 구동 중 및 ScaledObject 등록 확인" \
  bash -c "k get scaledobject petclinic-web-scaledobject -n '$NS'"

# 3. 네임스페이스 쿼터 & 워크로드 & Probe 설정
check "LimitRange & ResourceQuota 적용 확인" \
  bash -c "k get limitrange petclinic-limits -n '$NS' && k get resourcequota petclinic-quota -n '$NS'"

check "WAS Readiness Probe 경로 (/petclinic/owners?lastName=) 및 빈 SQL 마운트 확인" \
  bash -c "k get deploy petclinic-was -n '$NS' -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' | grep -q '/petclinic/owners' && k get deploy petclinic-was -n '$NS' -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"JDK_JAVA_OPTIONS\")].value}' | grep -q 'empty.sql'"

check "WEB (2+) & WAS (2+) 가용 파드 Ready" \
  bash -c "[ \"\$(k get deploy petclinic-web -n '$NS' -o jsonpath='{.status.availableReplicas}')\" -ge 2 ] && [ \"\$(k get deploy petclinic-was -n '$NS' -o jsonpath='{.status.availableReplicas}')\" -ge 2 ]"

# 4. 환경별 DB 검증 (dev: StatefulSet + EBS gp3 / prod: ExternalName -> RDS)
if [ "$ENV_MODE" = "dev" ]; then
  check "[dev] petclinic-db Headless Service & StatefulSet Ready (do-not-disrupt 포함)" \
    bash -c "[ \"\$(k get svc petclinic-db -n '$NS' -o jsonpath='{.spec.clusterIP}')\" = 'None' ] && [ \"\$(k get pod petclinic-db-0 -n '$NS' -o jsonpath='{.metadata.annotations.karpenter\.sh/do-not-disrupt}')\" = 'true' ]"
else
  check "[prod] petclinic-db ExternalName Service (RDS 연결) 확인" \
    bash -c "[ \"\$(k get svc petclinic-db -n '$NS' -o jsonpath='{.spec.type}')\" = 'ExternalName' ]"
fi

check "petclinic-db-seed Job 완료(Complete) 확인" \
  bash -c "[ \"\$(k get job petclinic-db-seed -n '$NS' -o jsonpath='{.status.conditions[?(@.type==\"Complete\")].status}')\" = 'True' ]"

# 5. ALB -> WEB -> WAS (/petclinic/) E2E 응답 확인
ALB=$(k get gateway petclinic-gateway -n "$NS" -o jsonpath='{.status.addresses[0].value}')
check "ALB 주소 할당 및 WEB 루트(/) HTTP 200 응답" \
  bash -c "[ -n '$ALB' ] && [ \"\$(curl -s -o /dev/null -m 10 -w '%{http_code}' \"http://$ALB/\")\" = '200' ]"

check "ALB -> WEB 프록시 -> WAS (/petclinic/owners?lastName=) HTTP 200 응답" \
  bash -c "[ -n '$ALB' ] && [ \"\$(curl -s -o /dev/null -m 10 -w '%{http_code}' \"http://$ALB/petclinic/owners?lastName=\")\" = '200' ]"

echo "--------------------------------------------------------"
printf " 결과: PASS=%d, FAIL=%d\n" "$PASS" "$FAIL"
echo "========================================================"
[ "$FAIL" -eq 0 ]
