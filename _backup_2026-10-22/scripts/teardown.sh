#!/usr/bin/env bash
# 프로젝트 리소스 8단계 역순 안전 삭제 스크립트 (과금 방지)
# 순서:
#   1. 워크로드 삭제
#   2. NodePool 삭제 (Karpenter 노드가 종료될 때까지 대기)
#   3. Ingress 삭제 (ALB 소멸 확인)
#   4. PVC 삭제 (EBS 소멸 확인)
#   5. RDS 삭제
#   6. eksctl delete cluster
#   7. ECR 삭제
#   8. NAT GW · EIP 잔여 확인
set -u

export AWS_PAGER=""
REGION="${REGION:-ap-northeast-2}"
CLUSTER="${CLUSTER:-petclinic-eks}"
RDS_ID="${RDS_ID:-petclinic-rds}"
NS="petclinic"

ok() { printf '[✔] %s\n' "$1"; }
info() { printf '[ℹ] %s\n' "$1"; }

read -r -p "EKS 클러스터(${CLUSTER}), Karpenter 노드, ALB, EBS, RDS(${RDS_ID}), ECR을 모두 삭제합니다. 계속하려면 delete 입력: " ans
[ "$ans" = "delete" ] || { echo "취소했습니다."; exit 1; }

# 1. 워크로드 삭제 (Ingress, PVC는 3, 4단계에서 명시적으로 확인하며 삭제하기 위해 Deployment/StatefulSet/Job/CronJob/KEDA 먼저 정리)
info "1/8 워크로드(KEDA ScaledObject, Deployment, StatefulSet, Job, CronJob) 삭제 중..."
kubectl delete -f keda/ --ignore-not-found 2>/dev/null
kubectl delete deploy,sts,job,cronjob,hpa,pdb --all -n "$NS" --ignore-not-found 2>/dev/null
ok "1/8 워크로드 삭제 완료"

# 2. NodePool 삭제 및 Karpenter 프로비저닝 노드 종료 대기
info "2/8 Karpenter NodePool 및 EC2NodeClass 삭제 중..."
kubectl delete -f karpenter/nodepool.yaml --ignore-not-found 2>/dev/null
for _ in $(seq 1 30); do
  KARP_NODES=$(kubectl get nodes -l karpenter.sh/nodepool --no-headers 2>/dev/null | wc -l)
  if [ "$KARP_NODES" -eq 0 ]; then
    ok "2/8 Karpenter 동적 노드 모두 종료 확인"
    break
  fi
  info "  Karpenter 노드 종료 대기 중... (남은 노드: ${KARP_NODES})"
  sleep 10
done
kubectl delete -f karpenter/ec2nodeclass.yaml --ignore-not-found 2>/dev/null

# 3. Ingress 삭제 및 ALB 소멸 확인
info "3/8 Ingress 삭제 및 AWS ALB 소멸 대기 중..."
ALB=$(kubectl get ingress petclinic-ingress -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
kubectl delete ingress --all -n "$NS" --ignore-not-found 2>/dev/null
if [ -n "$ALB" ]; then
  for _ in $(seq 1 30); do
    ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?DNSName=='$ALB'].LoadBalancerArn" --output text 2>/dev/null)
    if [ -z "$ALB_ARN" ]; then
      ok "3/8 AWS ALB 소멸 확인 완료"
      break
    fi
    info "  ALB 삭제 대기 중... ($ALB)"
    sleep 10
  done
else
  ok "3/8 삭제할 ALB 없음"
fi

# 4. PVC 삭제 및 EBS 볼륨 소멸 확인
info "4/8 PVC 삭제 및 AWS EBS 볼륨 소멸 대기 중..."
kubectl delete pvc --all -n "$NS" --ignore-not-found 2>/dev/null
kubectl delete namespace "$NS" --ignore-not-found 2>/dev/null
sleep 15
REM_VOLS=$(aws ec2 describe-volumes --region "$REGION" \
  --filters Name=tag:kubernetes.io/created-for/pvc/namespace,Values="$NS" Name=status,Values=available,in-use \
  --query 'length(Volumes)' --output text 2>/dev/null || echo "0")
ok "4/8 PVC 삭제 완료 (남은 petclinic EBS 볼륨: ${REM_VOLS})"

# 5. RDS 삭제
info "5/8 Amazon RDS (${RDS_ID}) 삭제 확인 중..."
if aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --region "$REGION" >/dev/null 2>&1; then
  aws rds delete-db-instance \
    --db-instance-identifier "$RDS_ID" \
    --skip-final-snapshot \
    --delete-automated-backups \
    --region "$REGION" >/dev/null
  aws rds wait db-instance-deleted --db-instance-identifier "$RDS_ID" --region "$REGION"
  ok "5/8 RDS 인스턴스(${RDS_ID}) 삭제 완료"
else
  ok "5/8 RDS 인스턴스(${RDS_ID}) 없음 (건너뜀)"
fi

# 6. eksctl delete cluster
info "6/8 EKS 클러스터 (${CLUSTER}) 삭제 중..."
eksctl delete cluster --name "$CLUSTER" --region "$REGION" --wait && ok "6/8 EKS 클러스터 삭제 완료"

# 7. ECR 삭제
info "7/8 ECR 리포지토리 삭제 중..."
for repo in petclinic-web petclinic-was; do
  aws ecr delete-repository --repository-name "$repo" --force --region "$REGION" >/dev/null 2>&1 || true
done
ok "7/8 ECR 리포지토리(petclinic-web, petclinic-was) 삭제 완료"

# 8. NAT GW · EIP 등 잔여 과금 리소스 최종 확인
info "8/8 잔여 과금 리소스(NAT Gateway, Elastic IP, ALB, EBS) 최종 점검..."
NAT_COUNT=$(aws ec2 describe-nat-gateways --region "$REGION" --filter Name=state,Values=available,pending --query 'length(NatGateways)' --output text)
EIP_COUNT=$(aws ec2 describe-addresses --region "$REGION" --query 'length(Addresses)' --output text)
ALB_COUNT=$(aws elbv2 describe-load-balancers --region "$REGION" --query 'length(LoadBalancers)' --output text)
VOL_COUNT=$(aws ec2 describe-volumes --region "$REGION" --filters Name=status,Values=available,in-use --query 'length(Volumes)' --output text)

echo "========================================================"
ok "Teardown 완료! 현재 리전(${REGION}) 잔여 리소스 현황:"
echo "  - 활성 NAT Gateway : ${NAT_COUNT}"
echo "  - 할당된 Elastic IP : ${EIP_COUNT}"
echo "  - 남은 LoadBalancer: ${ALB_COUNT}"
echo "  - 남은 EBS 볼륨     : ${VOL_COUNT}"
echo "========================================================"
