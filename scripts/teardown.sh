#!/usr/bin/env bash
# ==============================================================================
# 전체 리소스 삭제 (과금 방지)
#   사용법: source scripts/env.sh && bash scripts/teardown.sh
#   순서: DNS 레코드 → 워크로드(ALB·EBS) → Karpenter 노드 → 컨트롤러 → RDS
#        → EKS → IAM → Secrets Manager → ACM → ECR → (선택) Hosted Zone
#   VPC · 서브넷 · NAT · EIP · Bastion 은 콘솔에서 만들었으므로 마지막에 콘솔에서 삭제
# ==============================================================================
set -u
: "${REGION:?source scripts/env.sh 먼저 실행}"
step() { printf '\n[%s] %s\n' "$1" "$2"; }
ok()   { printf '  - %s\n' "$1"; }

read -r -p "클러스터(${CLUSTER})와 관련 AWS 리소스를 모두 삭제합니다. 계속하려면 delete 입력: " ans
[ "$ans" = "delete" ] || { echo "취소"; exit 1; }

# 1. Route 53 레코드 (Alias A, ACM 검증 CNAME 등 — NS/SOA 제외)
step 1 "Route 53 레코드 삭제 (${DOMAIN})"
if [ -n "${ZONE_ID:-}" ] && [ "$ZONE_ID" != "None" ]; then
  aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" --output json \
    | jq -c '{Changes: [.ResourceRecordSets[] | select(.Type != "NS" and .Type != "SOA") | {Action:"DELETE", ResourceRecordSet:.}]}' > /tmp/r53-del.json
  if [ "$(jq '.Changes | length' /tmp/r53-del.json)" -gt 0 ]; then
    aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch file:///tmp/r53-del.json >/dev/null && ok "레코드 삭제 완료"
  else ok "삭제할 레코드 없음"; fi
else ok "Hosted Zone 없음"; fi

# 2. 워크로드 (Gateway 삭제 → LBC가 ALB 삭제 / 네임스페이스 삭제 → PVC → EBS 삭제)
step 2 "petclinic 워크로드 삭제"
ALB_DNS=$(alb)
krender dev | kubectl delete -f - --ignore-not-found --wait=false >/dev/null 2>&1
kubectl delete namespace "$NS" --ignore-not-found --timeout=600s && ok "네임스페이스 삭제 완료"
if [ -n "$ALB_DNS" ]; then
  for _ in $(seq 1 30); do
    n=$(aws elbv2 describe-load-balancers --query "length(LoadBalancers[?DNSName=='${ALB_DNS}'])" --output text)
    [ "$n" = 0 ] && { ok "ALB 삭제 확인"; break; }; sleep 10
  done
fi

# 3. Karpenter 노드
step 3 "Karpenter 노드 정리"
kubectl delete nodepool --all --ignore-not-found >/dev/null 2>&1
for _ in $(seq 1 30); do
  n=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l)
  [ "$n" -eq 0 ] && { ok "NodeClaim 0개"; break; }; sleep 10
done
kubectl delete ec2nodeclass --all --ignore-not-found >/dev/null 2>&1

# 4. 컨트롤러
step 4 "Helm 릴리스 / GatewayClass 삭제"
helm uninstall keda -n keda >/dev/null 2>&1 && ok "KEDA"
helm uninstall external-secrets -n external-secrets >/dev/null 2>&1 && ok "External Secrets"
kubectl delete -f "$REPO_DIR/gateway/gatewayclass.yaml" --ignore-not-found >/dev/null 2>&1
helm uninstall aws-load-balancer-controller -n kube-system >/dev/null 2>&1 && ok "LB Controller"

# 5. RDS
step 5 "RDS 삭제"
if aws rds describe-db-instances --db-instance-identifier "$RDS_ID" >/dev/null 2>&1; then
  aws rds delete-db-instance --db-instance-identifier "$RDS_ID" --skip-final-snapshot --delete-automated-backups >/dev/null
  aws rds wait db-instance-deleted --db-instance-identifier "$RDS_ID" && ok "RDS 삭제 완료"
else ok "RDS 없음"; fi
aws rds delete-db-subnet-group --db-subnet-group-name petclinic-db-subnet-grp >/dev/null 2>&1 && ok "DB 서브넷 그룹"
RDS_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=petclinic-rds-sg --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[ -n "$RDS_SG" ] && [ "$RDS_SG" != None ] && aws ec2 delete-security-group --group-id "$RDS_SG" 2>/dev/null && ok "RDS 보안 그룹"

# 6. EKS (노드그룹, IRSA/Karpenter/Pod Identity 관련 CloudFormation 스택 포함)
step 6 "EKS 클러스터 삭제 (10~15분)"
eksctl delete cluster --name "$CLUSTER" --region "$REGION" --wait && ok "클러스터 삭제 완료"

# 7. 직접 만든 IAM 역할 / 정책
step 7 "IAM 정리"
for role in petclinic-keda-cloudwatch petclinic-eso-secretsmanager; do
  for pol in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$pol"
  done
  aws iam delete-role --role-name "$role" 2>/dev/null && ok "$role"
done
LBC_POLICY=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy-PetClinic'].Arn" --output text)
[ -n "$LBC_POLICY" ] && aws iam delete-policy --policy-arn "$LBC_POLICY" 2>/dev/null && ok "LBC 정책"

# 8. Secrets Manager
step 8 "Secrets Manager 삭제"
for s in petclinic/dev/db petclinic/prod/db; do
  aws secretsmanager delete-secret --secret-id "$s" --force-delete-without-recovery >/dev/null 2>&1 && ok "$s"
done

# 9. ACM (ALB가 지워진 뒤에만 삭제 가능)
step 9 "ACM 인증서 삭제"
[ -n "${CERT_ARN:-}" ] && [ "$CERT_ARN" != None ] && aws acm delete-certificate --certificate-arn "$CERT_ARN" 2>/dev/null && ok "$DOMAIN"

# 10. ECR
step 10 "ECR 리포지토리 삭제"
for repo in petclinic-web petclinic-was; do
  aws ecr delete-repository --repository-name "$repo" --force >/dev/null 2>&1 && ok "$repo"
done

# 11. Hosted Zone (도메인을 계속 쓸 거면 남겨 둠, 월 $0.50)
step 11 "Route 53 Hosted Zone"
read -r -p "  Hosted Zone(${DOMAIN})도 삭제할까요? 가비아 네임서버를 되돌리기 전까지 도메인이 응답하지 않습니다 [y/N]: " z
if [ "$z" = y ] && [ -n "${ZONE_ID:-}" ] && [ "$ZONE_ID" != None ]; then
  aws route53 delete-hosted-zone --id "$ZONE_ID" >/dev/null && ok "삭제 완료"
else ok "유지"; fi

# 12. 남은 과금 리소스 확인
step 12 "남은 리소스 (콘솔에서 VPC · Bastion · NAT · EIP 삭제)"
ok "NAT Gateway : $(aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending --query 'length(NatGateways)' --output text)"
ok "Elastic IP  : $(aws ec2 describe-addresses --query 'length(Addresses)' --output text)"
ok "ALB / NLB   : $(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text)"
ok "EBS 볼륨    : $(aws ec2 describe-volumes --query 'length(Volumes)' --output text)  (Bastion 루트 볼륨 1개는 정상)"
ok "EC2 실행 중 : $(aws ec2 describe-instances --filters Name=instance-state-name,Values=running --query 'length(Reservations[].Instances[])' --output text)  (Bastion 1대는 정상)"
echo
echo "콘솔 삭제 순서: Bastion EC2 → NAT Gateway → Elastic IP 해제 → VPC 삭제(서브넷·라우팅 테이블·IGW 함께 삭제됨)"
