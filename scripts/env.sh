# ==============================================================================
# Bastion 공통 환경 변수 + 자주 쓰는 함수
#   사용법: source scripts/env.sh   (~/.bashrc 에 등록해 두면 편함)
#   값은 AWS/클러스터에서 조회하므로 파일에 ID나 비밀번호를 적지 않음
# ==============================================================================
export AWS_PAGER=""
export REGION="${REGION:-ap-northeast-2}"
export AWS_DEFAULT_REGION="$REGION"
export CLUSTER="${CLUSTER:-petclinic-eks}"
export NS="${NS:-petclinic}"
export RDS_ID="${RDS_ID:-petclinic-rds}"
export DOMAIN="${DOMAIN:-zzgg2.cloud}"
export REPO_DIR="${REPO_DIR:-$HOME/petclinic-k8s-project}"

export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
export ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# 콘솔에서 만든 네트워크 (Name 태그로 조회)
_subnet() { aws ec2 describe-subnets --filters "Name=tag:Name,Values=$1" --query 'Subnets[0].SubnetId' --output text 2>/dev/null; }
export VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=petclinic-vpc" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
export PUB_A=$(_subnet petclinic-pub-a)       PUB_C=$(_subnet petclinic-pub-c)
export PRIV_NODE_A=$(_subnet petclinic-node-a) PRIV_NODE_C=$(_subnet petclinic-node-c)
export PRIV_DB_A=$(_subnet petclinic-db-a)     PRIV_DB_C=$(_subnet petclinic-db-c)

# ALB / 대상 그룹 (KEDA CloudWatch dimension)
alb() { kubectl get gateway petclinic-gateway -n "$NS" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null; echo; }
_alb_dns=$(alb)
if [ -n "$_alb_dns" ]; then
  _alb_arn=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='${_alb_dns}'].LoadBalancerArn" --output text 2>/dev/null)
  _tg_arn=$(aws elbv2 describe-target-groups --load-balancer-arn "$_alb_arn" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
  export ALB_DIM="${_alb_arn#*:loadbalancer/}" TG_DIM="${_tg_arn##*:}"
fi

# 도메인 / 인증서 / RDS
export ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --query "HostedZones[?Name=='${DOMAIN}.'].Id | [0]" --output text 2>/dev/null | sed 's|/hostedzone/||')
export CERT_ARN=$(aws acm list-certificates --query "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn | [0]" --output text 2>/dev/null)
export RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null)

# Kustomize 렌더링 + envsubst (치환할 변수를 명시해 다른 $ 표현은 건드리지 않음)
kvars='${AWS_ACCOUNT_ID} ${RDS_ENDPOINT} ${ALB_DIM} ${TG_DIM} ${DOMAIN} ${CERT_ARN}'
krender() { kubectl kustomize "$REPO_DIR/k8s/overlays/${1:-dev}" | envsubst "$kvars"; }
kdiff()   { krender "$1" | kubectl diff -f -; }
kapply()  { krender "$1" | kubectl apply -f -; }
