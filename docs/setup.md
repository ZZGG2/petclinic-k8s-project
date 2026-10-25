# 구축 순서

실제로 진행한 순서를 그대로 정리했습니다. 명령은 Bastion(Ubuntu 24.04)에서 실행하고, `source scripts/env.sh`로 공통 변수와 함수를 불러온 상태를 기준으로 합니다.

| 함수 | 설명 |
|---|---|
| `krender [dev\|prod]` | Kustomize 렌더링 + `envsubst`로 계정 ID, ALB, 도메인, 인증서 값 치환 |
| `kdiff` / `kapply` | 렌더링 결과를 `kubectl diff` / `kubectl apply` |
| `alb` | Gateway가 만든 ALB 주소 |

---

## 0. 네트워크 · Bastion (콘솔)

| 리소스 | 설정 |
|---|---|
| VPC | `10.0.0.0/16`, DNS hostnames 활성화 |
| Public 서브넷 | `10.0.0.0/24`(2a), `10.0.10.0/24`(2c) · 태그 `kubernetes.io/role/elb=1` |
| Private 노드 서브넷 | `10.0.40.0/24`(2a), `10.0.50.0/24`(2c) · 태그 `kubernetes.io/role/internal-elb=1`, `karpenter.sh/discovery=petclinic-eks` |
| Private DB 서브넷 | `10.0.60.0/24`(2a), `10.0.70.0/24`(2c) |
| IGW, NAT Gateway | NAT는 2a에 1개, Private 라우팅 테이블 `0.0.0.0/0 → NAT` |
| Bastion | t3.medium, Public 2a, SSH는 내 IP만 허용 |

Bastion 도구: Docker, AWS CLI v2, kubectl 1.36, eksctl, helm, jq, gettext-base(envsubst)

## 1. 이미지 빌드

```bash
bash scripts/build-and-push-ecr.sh        # petclinic-web:v1.2, petclinic-was:v1.2
```

WAS Dockerfile에서 처리하는 것
- `mysql:mysql-connector-java` → `com.mysql:mysql-connector-j` 좌표 교체 (빌드 전)
- WAR를 디렉터리로 풀어서 배포 (설정 파일 하나만 교체할 수 있게)
- Maven 필터링으로 하드코딩된 `datasource-config.xml` 값을 `${jdbc.*}` 플레이스홀더로 복원 (빌드 후)

## 2. EKS 클러스터

```bash
envsubst '${CLUSTER} ${REGION} ${VPC_ID} ${PUB_A} ${PUB_C} ${PRIV_NODE_A} ${PRIV_NODE_C}' \
  < eks/cluster-config.yaml > eks/cluster.rendered.yaml
eksctl create cluster -f eks/cluster.rendered.yaml
```

- `ng-system` m7i-flex.large × 2, Taint `CriticalAddonsOnly=true:NoSchedule` (Stage 4부터)
- 애드온: vpc-cni, coredns, kube-proxy, eks-pod-identity-agent, aws-ebs-csi-driver, metrics-server
- Karpenter 1.14.2 (IAM Role, SQS 큐, 컨트롤러)

## 3. AWS Load Balancer Controller + Gateway API

LBC는 시작할 때 Gateway API CRD가 있는지 보고 Gateway 컨트롤러를 켜기 때문에 CRD를 먼저 설치합니다.

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.4.1/config/crd/gateway/gateway-crds.yaml

curl -sSLo /tmp/iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.4.1/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy-PetClinic --policy-document file:///tmp/iam-policy.json
eksctl create iamserviceaccount --cluster "$CLUSTER" --namespace kube-system --name aws-load-balancer-controller \
  --attach-policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy-PetClinic" --approve

helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --version 3.4.0 \
  --set clusterName="$CLUSTER" --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$REGION" --set vpcId="$VPC_ID" \
  --set 'tolerations[0].key=CriticalAddonsOnly' --set 'tolerations[0].operator=Exists' --set 'tolerations[0].effect=NoSchedule'

kubectl apply -f gateway/gatewayclass.yaml
```

## 4. 애플리케이션 (dev)

```bash
kdiff      # 변경 내용 미리 보기
kapply     # = krender dev | kubectl apply -f -
```

dev는 클러스터 안의 MySQL StatefulSet, prod는 RDS를 사용합니다. prod로 전환할 때는 dev 전용 리소스(StatefulSet, Headless Service, Seed Job)를 먼저 지우고 `kapply prod`를 실행합니다. `kubectl apply`는 매니페스트에서 빠진 리소스를 지우지 않기 때문입니다.

RDS: MySQL 8.4, db.t4g.micro, Single-AZ, Private DB 서브넷, 보안 그룹은 EKS 노드 보안 그룹에서 오는 3306만 허용

## 5. 오토스케일링

```bash
# Karpenter
kubectl apply -f karpenter/ec2nodeclass.yaml -f karpenter/nodepool.yaml
aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name ng-system \
  --taints 'addOrUpdateTaints=[{key=CriticalAddonsOnly,value=true,effect=NO_SCHEDULE}]'

# KEDA + CloudWatch 읽기 권한 (EKS Pod Identity)
helm upgrade -i keda kedacore/keda -n keda --create-namespace --version 2.21.0 -f helm/keda-values.yaml
aws eks create-pod-identity-association --cluster-name "$CLUSTER" --namespace keda --service-account keda-operator \
  --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/petclinic-keda-cloudwatch"
```

HPA(`k8s/base/was-hpa.yaml`)와 ScaledObject(`k8s/base/web-scaledobject.yaml`)는 `kapply`에 포함되어 있습니다. HPA를 처음 붙일 때는 Deployment의 `replicas`를 지우기 전에 `kubectl apply set-last-applied`로 기록을 맞춰야 파드 수가 1로 떨어지지 않습니다.

## 6. Secrets Manager + External Secrets

```bash
aws secretsmanager create-secret --name petclinic/dev/db \
  --secret-string '{"DB_ADMIN_USER":"root","DB_ADMIN_PASSWORD":"...","DB_PASSWORD":"..."}'

aws eks create-pod-identity-association --cluster-name "$CLUSTER" --namespace external-secrets \
  --service-account external-secrets --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/petclinic-eso-secretsmanager"
helm upgrade -i external-secrets external-secrets/external-secrets -n external-secrets --create-namespace \
  -f helm/external-secrets-values.yaml
```

IAM 정책은 `secretsmanager:GetSecretValue`, `DescribeSecret`을 `petclinic/*`에만 허용합니다. 비밀번호를 교체할 때는 Secrets Manager 값 변경 → ExternalSecret 강제 동기화 → Seed Job으로 `ALTER USER` → WAS 재시작 순서로 진행합니다.

## 7. Route 53 + HTTPS

1. 가비아에서 도메인 구입 → Route 53 Hosted Zone 생성 → 가비아 네임서버를 Route 53 네임서버 4개로 변경
2. ACM 인증서(`zzgg2.cloud`, `*.zzgg2.cloud`)를 서울 리전에서 DNS 검증으로 발급
3. `kapply` (Gateway에 HTTPS 리스너, HTTP는 301 리다이렉트)
4. Route 53에 Alias A 레코드 (`zzgg2.cloud`, `www.zzgg2.cloud` → ALB)

## 점검 · 삭제

```bash
bash scripts/verify.sh       # 워크로드, External Secrets, 비밀번호 일관성, HTTPS, 오토스케일링 점검
bash scripts/teardown.sh     # 전체 삭제 (VPC · Bastion · NAT은 콘솔에서)
```
