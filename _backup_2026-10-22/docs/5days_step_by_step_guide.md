# 📘 PetClinic EKS 프로젝트 5단계(5일) 점진적 확장 가이드라인

처음부터 모든 인프라와 쿠버네티스 부가 기능을 한꺼번에 깔면 구조가 한눈에 들어오지 않고, 에러가 났을 때 원인을 찾기도 어렵습니다.
따라서 이 가이드라인은 **[Stage 1] 가장 단순한 3-Tier(MVP)를 먼저 끝까지 연결해 브라우저 화면을 띄운 뒤**, **[Stage 2 ~ 4] 매일 한 가지 테마씩 기능을 추가하며 비교·검증**하고, **[Stage 5] 통합 시나리오 시연 및 안전 삭제**로 마무리하도록 재구성했습니다.

---

## 🧭 한눈에 보는 작업 위치 & 5단계 진화 흐름

### 1) 명령어를 실행하는 3곳 (`📍 실행 위치` 표시 참고)
| 표시 아이콘 | 작업 위치 설명 | 주로 하는 작업 |
| :--- | :--- | :--- |
| 🖥️ **`[내 PC 터미널 / 브라우저]`** | 본인 노트북의 PowerShell/터미널 및 크롬 브라우저 | Bastion으로 `ssh` 접속, 브라우저로 ALB 웹 화면 확인 |
| 🌐 **`[AWS CloudShell]`** | AWS 콘솔 우측 상단 `[>_]` 아이콘 클릭 | **1일차 맨 처음 VPC·서브넷·Bastion 생성**과 **5일차 맨 마지막 VPC 삭제** 때만 사용 |
| 🐧 **`[Bastion EC2 셸]`** | Public 서브넷에 띄운 작업용 관리 서버 (`ubuntu@bastion`) | **프로젝트의 95% 작업 수행** (`docker build`, `eksctl`, `kubectl`, `helm`, `teardown`) |

### 2) 5단계(Stage 1 ~ 5) 점진적 빌드업 요약
* **Stage 1 (1일차)**: 부가 기능 전혀 없이 **가장 단순한 3-Tier(`ALB → WEB → WAS → 기본 MySQL`)** 컨테이너 빌드 및 첫 개통 (**`k8s/stage1-mvp/`**)
* **Stage 2 (2일차)**: DB 고도화 — WAS 자동 초기화 비활성화(`empty.sql`), 최소 권한 `Seed Job` 분리, **Kustomize(`dev` StatefulSet vs `prod` RDS)** 전환
* **Stage 3 (3일차)**: 파드 안정성 & 운영 디테일 추가 — **WAS 3종 Probe(`/owners`) → WEB 네이티브 Sidecar → `LimitRange` · `ResourceQuota` · `PDB` · `CronJob`**
* **Stage 4 (4일차)**: 오토스케일링 3단계 추가 — **① WAS CPU `HPA` → ② WEB `KEDA` (CloudWatch+Cron) → ③ 클러스터 노드 `Karpenter`**
* **Stage 5 (5일차)**: **통합 시나리오 4종 시연** (KEDA→Karpenter 연쇄, StatefulSet 복구 등) 및 **8단계 역순 Teardown**

---

## 📅 Stage 1 (1일차): 기본 인프라 구축 & 가장 단순한 3-Tier MVP 개통

> **🎯 Stage 1 목표**: StatefulSet, RDS, Kustomize, Sidecar, Probe, Quota, KEDA는 오늘 신경 쓰지 않습니다! 오직 **내가 빌드한 WEB·WAS 컨테이너가 EKS 위에서 기본 MySQL 파드와 연결되어 ALB 주소로 열리는 것**까지 먼저 성공시킵니다.

---

### Step 1-1. 초기 VPC · 서브넷(6개) · IGW · NAT GW(1개) 생성
> 📍 **실행 위치**: 🌐 **`[AWS CloudShell]`** (AWS 콘솔 우측 상단 `[>_]` 아이콘 클릭)

추후 Stage 2~4에서 RDS와 Karpenter, ALB를 바로 붙일 수 있도록 서브넷 6개와 필수 태그만 처음에 깔끔하게 잡아 둡니다.

```bash
# [AWS CloudShell에서 복사-붙여넣기]
export AWS_PAGER=""
export REGION="ap-northeast-2"
export CLUSTER="petclinic-eks"

# 1) VPC 생성 (10.0.0.0/16) 및 DNS 호스트네임 활성화
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=petclinic-vpc},{Key=Project,Value=petclinic-k8s}]' \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}"

# 2) 서브넷 6개 생성 (Public 2, Private Node 2, Private DB 2)
PUB_A=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.0.0/24 --availability-zone ap-northeast-2a \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=petclinic-pub-a},{Key=kubernetes.io/role/elb,Value=1},{Key=kubernetes.io/cluster/${CLUSTER},Value=shared}]" \
  --query 'Subnet.SubnetId' --output text)
PUB_C=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.10.0/24 --availability-zone ap-northeast-2c \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=petclinic-pub-c},{Key=kubernetes.io/role/elb,Value=1},{Key=kubernetes.io/cluster/${CLUSTER},Value=shared}]" \
  --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id "$PUB_A" --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id "$PUB_C" --map-public-ip-on-launch

PRIV_NODE_A=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.40.0/24 --availability-zone ap-northeast-2a \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=petclinic-node-a},{Key=kubernetes.io/role/internal-elb,Value=1},{Key=karpenter.sh/discovery,Value=${CLUSTER}}]" \
  --query 'Subnet.SubnetId' --output text)
PRIV_NODE_C=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.50.0/24 --availability-zone ap-northeast-2c \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=petclinic-node-c},{Key=kubernetes.io/role/internal-elb,Value=1},{Key=karpenter.sh/discovery,Value=${CLUSTER}}]" \
  --query 'Subnet.SubnetId' --output text)

PRIV_DB_A=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.60.0/24 --availability-zone ap-northeast-2a \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=petclinic-db-a}]" \
  --query 'Subnet.SubnetId' --output text)
PRIV_DB_C=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.70.0/24 --availability-zone ap-northeast-2c \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=petclinic-db-c}]" \
  --query 'Subnet.SubnetId' --output text)

# 3) Internet Gateway (IGW) 및 Public 라우팅 테이블 연결
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=petclinic-igw}]' \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"

PUB_RTB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=petclinic-pub-rtb}]' \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$PUB_RTB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
aws ec2 associate-route-table --subnet-id "$PUB_A" --route-table-id "$PUB_RTB"
aws ec2 associate-route-table --subnet-id "$PUB_C" --route-table-id "$PUB_RTB"

# 4) NAT Gateway 1개 생성 및 Private 라우팅 테이블 연결
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=petclinic-nat-eip}]' \
  --query 'AllocationId' --output text)
NAT_GW=$(aws ec2 create-nat-gateway --subnet-id "$PUB_A" --allocation-id "$EIP_ALLOC" \
  --tag-specifications 'ResourceType=nat-gateway,Tags=[{Key=Name,Value=petclinic-nat-gw}]' \
  --query 'NatGateway.NatGatewayId' --output text)
echo "NAT Gateway 생성 대기 중 (약 1~2분)..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW"

PRIV_RTB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=petclinic-priv-rtb}]' \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$PRIV_RTB" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_GW"
for sub in "$PRIV_NODE_A" "$PRIV_NODE_C" "$PRIV_DB_A" "$PRIV_DB_C"; do
  aws ec2 associate-route-table --subnet-id "$sub" --route-table-id "$PRIV_RTB"
done
echo "✅ VPC 및 서브넷 구성 완료!"
```

---

### Step 1-2. Bastion (작업용 관리 EC2) 생성 및 접속
> 📍 **실행 위치**: 🌐 **`[AWS CloudShell]`** (이어서 실행)

```bash
# 1) SSH 키페어 및 Bastion 보안 그룹 생성
aws ec2 create-key-pair --key-name petclinic-key --query 'KeyMaterial' --output text > ~/petclinic-key.pem
chmod 400 ~/petclinic-key.pem

BASTION_SG=$(aws ec2 create-security-group --group-name petclinic-bastion-sg \
  --description "Bastion SSH access" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$BASTION_SG" --protocol tcp --port 22 --cidr 0.0.0.0/0

# 2) Ubuntu 24.04 EC2 (t3.medium, 30GB) 생성
AMI_ID=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query 'Parameter.Value' --output text)
BASTION_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type t3.medium --key-name petclinic-key \
  --subnet-id "$PUB_A" --security-group-ids "$BASTION_SG" \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=petclinic-bastion}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids "$BASTION_ID"
BASTION_IP=$(aws ec2 describe-instances --instance-ids "$BASTION_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "✅ Bastion 공인 IP: $BASTION_IP"
```

* 이제 `ssh -i ~/petclinic-key.pem ubuntu@$BASTION_IP` 명령으로 **Bastion EC2에 접속**합니다.

---

### Step 1-3. Bastion 도구 설치 및 환경 변수 설정
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 셸]`**

```bash
# 1) Docker, AWS CLI v2, kubectl, eksctl, helm 설치
sudo apt-get update && sudo apt-get install -y ca-certificates curl gnupg unzip git jq docker.io
sudo usermod -aG docker ubuntu && newgrp docker

curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install && rm -rf /tmp/aws*

curl -sSLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

curl -sSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin/

curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 2) AWS 자격 증명 입력 (Access Key, Secret Key, 리전: ap-northeast-2)
aws configure

# 3) 공통 환경변수 파일(~/petclinic-env.sh) 생성
cat > ~/petclinic-env.sh <<'EOF'
export AWS_PAGER=""
export REGION="ap-northeast-2"
export AWS_DEFAULT_REGION="ap-northeast-2"
export CLUSTER="petclinic-eks"
export NS="petclinic"
export RDS_ID="petclinic-rds"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

export VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=petclinic-vpc" --query 'Vpcs[0].VpcId' --output text)
export PUB_A=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=petclinic-pub-a" --query 'Subnets[0].SubnetId' --output text)
export PUB_C=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=petclinic-pub-c" --query 'Subnets[0].SubnetId' --output text)
export PRIV_NODE_A=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=petclinic-node-a" --query 'Subnets[0].SubnetId' --output text)
export PRIV_NODE_C=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=petclinic-node-c" --query 'Subnets[0].SubnetId' --output text)
export PRIV_DB_A=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=petclinic-db-a" --query 'Subnets[0].SubnetId' --output text)
export PRIV_DB_C=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=petclinic-db-c" --query 'Subnets[0].SubnetId' --output text)
EOF
echo "source ~/petclinic-env.sh" >> ~/.bashrc
source ~/petclinic-env.sh
```

프로젝트 폴더(`petclinic-k8s-project`)를 Bastion의 `~/petclinic-k8s-project`에 위치한 뒤 이동합니다:
```bash
cd ~/petclinic-k8s-project
```

---

### Step 1-4. WEB & WAS 컨테이너 이미지 빌드 및 ECR 푸시
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 셸]`** (`~/petclinic-k8s-project`)

가장 먼저 우리가 띄울 두 개의 애플리케이션 이미지(`petclinic-web:v1`, `petclinic-was:v1`)를 빌드해서 ECR에 올립니다.
* **WEB**: `default.conf`에 `/` 정적 서빙과 `location /petclinic/ { proxy_pass http://petclinic-was:8080; }` 설정 포함
* **WAS**: `./mvnw clean package -P MySQL -DskipTests`로 빌드한 `petclinic.war`를 `tomcat:11.0-jdk17-temurin`에 복사

```bash
# 1) WEB 단독 로컬 동작 확인
docker build -t petclinic-web:v1 ./docker/web
docker run -d --name web-test -p 8081:80 petclinic-web:v1
curl -s http://localhost:8081/healthz   # 출력: ok
docker rm -f web-test

# 2) ECR 리포지토리 생성 + WEB(v1) & WAS(v1) 빌드 및 푸시 일괄 실행
bash scripts/build-and-push-ecr.sh

# 3) 추후 롤링 업데이트 시연용 petclinic-web:v2도 미리 빌드해 푸시
sed -i 's/AWS 3-Tier Architecture/AWS EKS 3-Tier Architecture (v2)/g' ./docker/web/index.html
docker build -t "${ECR_URI}/petclinic-web:v2" ./docker/web
docker push "${ECR_URI}/petclinic-web:v2"
git checkout ./docker/web/index.html 2>/dev/null || true
```

---

### Step 1-5. EKS 클러스터 생성 및 기본 노드풀 · ALB Controller 준비
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 셸]`** (`~/petclinic-k8s-project`)

```bash
# 1) Step 1-1에서 생성한 VPC/서브넷 ID를 반영하여 EKS 클러스터 생성 (약 15~20분 소요)
cat > eks/00-cluster-config.yaml <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER}
  region: ${REGION}
  version: "1.36"
  tags:
    Project: petclinic-k8s
    karpenter.sh/discovery: ${CLUSTER}

vpc:
  id: "${VPC_ID}"
  subnets:
    public:
      ap-northeast-2a: { id: "${PUB_A}" }
      ap-northeast-2c: { id: "${PUB_C}" }
    private:
      ap-northeast-2a: { id: "${PRIV_NODE_A}" }
      ap-northeast-2c: { id: "${PRIV_NODE_C}" }

iam:
  withOIDC: true

addonsConfig:
  autoApplyPodIdentityAssociations: true

autoModeConfig:
  enabled: false

karpenter:
  version: "1.3.0"
  createServiceAccount: true
  withSpotInterruptionQueue: true

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: eks-pod-identity-agent
  - name: aws-ebs-csi-driver
  - name: metrics-server

managedNodeGroups:
  - name: ng-system
    instanceType: m7i-flex.large
    desiredCapacity: 2
    minSize: 2
    maxSize: 3
    volumeSize: 20
    privateNetworking: true
    subnets:
      - "${PRIV_NODE_A}"
      - "${PRIV_NODE_C}"
    labels:
      role: system
    taints:
      - key: CriticalAddonsOnly
        value: "true"
        effect: NoSchedule
EOF

eksctl create cluster -f eks/00-cluster-config.yaml
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

# 2) 앱 파드가 스케줄링될 수 있도록 Karpenter 기본 NodePool 등록
NODE_SG=$(aws eks describe-cluster --name "$CLUSTER" --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
aws ec2 create-tags --resources "$NODE_SG" --tags Key=karpenter.sh/discovery,Value="$CLUSTER"
NODE_ROLE_NAME=$(aws iam list-roles --query "Roles[?contains(RoleName, 'eksctl-${CLUSTER}-nodegroup-ng-system-NodeInstanceRole')].RoleName" --output text)
sed -i "s|role:.*|role: \"${NODE_ROLE_NAME}\"|" karpenter/ec2nodeclass.yaml
kubectl apply -f karpenter/ec2nodeclass.yaml
kubectl apply -f karpenter/nodepool.yaml

# 3) 외부 접속(Ingress -> ALB)을 위한 AWS Load Balancer Controller 설치
curl -sSLo /tmp/iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json
POLICY_ARN=$(aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy-PetClinic \
  --policy-document file:///tmp/iam-policy.json --query 'Policy.Arn' --output text 2>/dev/null || \
  aws iam list-policies --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy-PetClinic'].Arn" --output text)

eksctl create iamserviceaccount --cluster="$CLUSTER" --namespace=kube-system \
  --name=aws-load-balancer-controller --attach-policy-arn="$POLICY_ARN" \
  --override-existing-serviceaccounts --approve

helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName="$CLUSTER" --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller --set region="$REGION" --set vpcId="$VPC_ID" \
  --set tolerations[0].key=CriticalAddonsOnly --set tolerations[0].operator=Exists --set tolerations[0].effect=NoSchedule --wait
```

---

### Step 1-6. 🎉 [Stage 1 핵심] 가장 단순한 3-Tier MVP 배포 및 첫 개통 확인!
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 셸]`** 및 🖥️ **`[내 PC 웹 브라우저]`**

복잡한 설정이 하나도 없는 [`k8s/stage1-mvp/00-mvp-all-in-one.yaml`](file:///C:/Users/tkdxm/.gemini/antigravity/scratch/petclinic-k8s-project/k8s/stage1-mvp/00-mvp-all-in-one.yaml) 파일 하나로 **Namespace + 기본 MySQL 파드 + WAS 파드 + WEB 파드 + ALB Ingress**만 배포합니다.

```bash
# 1) MVP 매니페스트 내 AWS_ACCOUNT_ID 치환 후 배포
sed -i "s|\${AWS_ACCOUNT_ID}|${AWS_ACCOUNT_ID}|g" k8s/stage1-mvp/00-mvp-all-in-one.yaml
kubectl apply -f k8s/stage1-mvp/00-mvp-all-in-one.yaml

# 2) 파드 3개(mysql, was, web)가 모두 Running이 될 때까지 확인
kubectl get pods -n petclinic -w   # 모두 Running이 되면 Ctrl+C

# 3) 생성된 ALB 주소 확인 (약 2분 후 프로비저닝 완료)
ALB=$(kubectl get ingress petclinic-ingress -n petclinic -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "🌐 Stage 1 MVP 접속 주소: http://$ALB/"
curl -I "http://$ALB/"
```

* 🖥️ **`[내 PC 웹 브라우저]`**: `http://<ALB주소>/`에 접속해 랜딩 페이지가 뜨는지, **`[PetClinic 열기 →]`**를 클릭해 `/petclinic/` 화면과 `Find Owners` 조회가 잘 되는지 확인합니다!
* **💡 Stage 1 완료 시점의 한계(내일 해결할 과제)**:
  1. 지금 DB(`petclinic-db-mvp`)는 일반 `Deployment`라 파드가 재시작되면 추가한 반려동물 데이터가 전부 날아갑니다.
  2. WAS가 기동할 때마다 DB 초기화 스크립트(`schema.sql`)를 직접 실행할 수 있는 과도한 권한을 갖고 있습니다.

---

## 📅 Stage 2 (2일차): DB 영속성 · 최소 권한 분리 & Kustomize (`dev` vs `prod`)

> **🎯 Stage 2 목표**: 어제 띄운 임시 DB 파드를 걷어내고, **① 최소 권한 `Seed Job` 분리 + WAS 빈 SQL 마운트**, **② `dev` 환경(`StatefulSet` + EBS `gp3`)**, **③ `prod` 환경(Single-AZ `RDS` + `ExternalName`)**을 Kustomize로 분리해 적용합니다.

---

### Step 2-1. Stage 1 임시 DB 정리 & WAS 빈 SQL 마운트 + 최소 권한 `Seed Job` 이해
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 셸]`** (`~/petclinic-k8s-project`)

1. **왜 바꾸나요?**
   * `data.sql`은 `INSERT IGNORE`로 되어 있어 중복 크래시는 안 나지만, 보안상 **DDL(`schema.sql`)과 초기 데이터 적재는 관리자 계정을 쓰는 `Job`(`petclinic-db-seed`)이 1회만 실행**하고, **WAS는 DML(`SELECT, INSERT, UPDATE`) 권한만 가진 계정**으로 돌아야 합니다.
   * 이를 위해 [`k8s/base/config-secret.yaml`](file:///C:/Users/tkdxm/.gemini/antigravity/scratch/petclinic-k8s-project/k8s/base/config-secret.yaml)의 `empty.sql`(`SELECT 1;`)을 WAS에 마운트하고 `-Djdbc.initLocation=file:/config/empty.sql`로 WAS 내장 초기화를 비활성화합니다.

```bash
# Stage 1에서 띄웠던 임시 MySQL Deployment만 삭제 (Ingress와 네임스페이스는 유지되어 ALB 주소가 바뀌지 않습니다!)
kubectl delete deployment petclinic-db-mvp -n petclinic
kubectl delete svc petclinic-db -n petclinic
```

---

### Step 2-2. `dev` 환경 배포 (`StatefulSet` + EBS `gp3` + `Seed Job`) 및 최소 권한 검증
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 셸]`** (`~/petclinic-k8s-project`)

```bash
# 1) base 매니페스트에 AWS_ACCOUNT_ID 반영
sed -i "s|\${AWS_ACCOUNT_ID}|${AWS_ACCOUNT_ID}|g" k8s/base/was-deployment.yaml
sed -i "s|\${AWS_ACCOUNT_ID}|${AWS_ACCOUNT_ID}|g" k8s/base/web-deployment.yaml

# 2) Kustomize dev 오버레이 배포 (gp3 StorageClass + Headless Service + StatefulSet + Seed Job)
kubectl apply -k k8s/overlays/dev

# 3) EBS gp3 PVC 바인딩 및 Seed Job 완료 대기
kubectl get pvc -n petclinic
kubectl wait --for=condition=complete job/petclinic-db-seed -n petclinic --timeout=180s
kubectl logs job/petclinic-db-seed -n petclinic

# 4) 최소 권한 검증: WAS용 계정(petclinic)으로 SELECT는 성공하고, DROP TABLE은 거부되는지 확인!
kubectl exec -n petclinic petclinic-db-0 -- \
  mysql -upetclinic -p'PetClinicApp#2026' petclinic -e "SELECT COUNT(*) FROM owners;"

kubectl exec -n petclinic petclinic-db-0 -- \
  mysql -upetclinic -p'PetClinicApp#2026' petclinic -e "DROP TABLE visits;"
# -> ERROR 1142 (42000): DROP command denied 출력 확인!
```

---

### Step 2-3. `prod` 환경용 Amazon RDS (Single-AZ) 생성
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 셸]`** (`~/petclinic-k8s-project`)

가이드의 *"DB만 빼고 컨테이너화"* 요구사항을 만족하는 `prod` 환경을 위해 Private DB 서브넷에 Single-AZ RDS를 생성합니다.

```bash
# 1) DB 서브넷 그룹 및 RDS 전용 보안 그룹(노드 SG의 3306 포트만 허용) 생성
aws rds create-db-subnet-group \
  --db-subnet-group-name petclinic-db-subnet-grp \
  --db-subnet-group-description "Private DB Subnet Group" \
  --subnet-ids "$PRIV_DB_A" "$PRIV_DB_C"

NODE_SG=$(aws eks describe-cluster --name "$CLUSTER" --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
RDS_SG=$(aws ec2 create-security-group --group-name petclinic-rds-sg \
  --description "Allow MySQL 3306 from EKS Nodes" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$RDS_SG" --protocol tcp --port 3306 --source-group "$NODE_SG"

# 2) Single-AZ RDS (MySQL 8.4) 생성 (약 5~8분 소요)
aws rds create-db-instance \
  --db-instance-identifier "$RDS_ID" \
  --db-instance-class db.t3.micro \
  --engine mysql --engine-version "8.4.3" \
  --master-username root --master-user-password "PetClinicAdmin#2026" \
  --allocated-storage 20 --storage-type gp3 \
  --db-subnet-group-name petclinic-db-subnet-grp \
  --vpc-security-group-ids "$RDS_SG" \
  --no-publicly-accessible --no-multi-az --backup-retention-period 0

aws rds wait db-instance-available --db-instance-identifier "$RDS_ID"
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --query 'DBInstances[0].Endpoint.Address' --output text)
echo "export RDS_ENDPOINT=${RDS_ENDPOINT}" >> ~/petclinic-env.sh
echo "export RDS_SG=${RDS_SG}" >> ~/petclinic-env.sh
source ~/petclinic-env.sh
echo "✅ RDS 생성 완료: $RDS_ENDPOINT"
```

---

### Step 2-4. `prod` 환경(`ExternalName` → RDS) 전환 및 검증
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 셸]`** (`~/petclinic-k8s-project`)

두 환경 모두 쿠버네티스 Service 이름을 `petclinic-db`로 맞췄기 때문에, **WAS 매니페스트는 단 한 줄도 고치지 않고** `petclinic-db` Service만 `ExternalName`으로 교체하면 즉시 RDS로 연결됩니다.

```bash
# 1) prod 오버레이에 RDS 엔드포인트 기입
sed -i "s|\${RDS_ENDPOINT}|${RDS_ENDPOINT}|g" k8s/overlays/prod/db-externalname-svc.yaml

# 2) 기존 Headless Service 및 Job 삭제 후 prod 오버레이 적용
kubectl delete svc petclinic-db -n petclinic
kubectl delete job petclinic-db-seed -n petclinic
kubectl apply -k k8s/overlays/prod

# 3) petclinic-db Service가 ExternalName(RDS 주소)으로 바뀌었는지 확인 및 Seed Job 완료 대기
kubectl get svc petclinic-db -n petclinic
kubectl wait --for=condition=complete job/petclinic-db-seed -n petclinic --timeout=180s
kubectl logs job/petclinic-db-seed -n petclinic

# 4) 브라우저 또는 curl로 WAS가 RDS 데이터를 정상 조회하는지 확인
ALB=$(kubectl get ingress petclinic-ingress -n petclinic -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -I "http://$ALB/petclinic/owners?lastName="
```

---

## 📅 Stage 3 (3일차): 파드 안정성 & 운영 디테일 하나씩 점검·확인

> **🎯 Stage 3 목표**: `k8s/base/`에 적용된 수업 핵심 디테일 4가지(**① 캐시 우회 3종 Probe**, **② 네이티브 Sidecar 로그 스트리밍**, **③ LimitRange & ResourceQuota**, **④ PDB & CronJob**)가 각각 어떻게 동작하는지 하나씩 검증합니다.

---

### Step 3-1. 기능 ① — WAS 3종 Probe 검증 (`/petclinic/vets` 캐시 우회 확인)
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 셸]`**

* **핵심 포인트**: `ClinicServiceImpl.findVets()`에는 `@Cacheable("vets")`가 걸려 있어 첫 호출 이후 DB를 거치지 않습니다. 그래서 [`k8s/base/was-deployment.yaml`](file:///C:/Users/tkdxm/.gemini/antigravity/scratch/petclinic-k8s-project/k8s/base/was-deployment.yaml)에서는 매번 DB 쿼리를 실행하는 **`/petclinic/owners?lastName=`**를 `readinessProbe`로 설정했습니다.

```bash
# WAS 파드에 설정된 Startup / Liveness / Readiness Probe 경로 직접 확인
kubectl describe pod -n petclinic -l tier=was | grep -E "Liveness|Readiness|Startup"
```

---

### Step 3-2. 기능 ② — WEB 네이티브 Sidecar (`log-agent`) 동작 확인
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 셸]`**

* **핵심 포인트**: [`k8s/base/web-deployment.yaml`](file:///C:/Users/tkdxm/.gemini/antigravity/scratch/petclinic-k8s-project/k8s/base/web-deployment.yaml)에서 `initContainers`에 `restartPolicy: Always`를 부여한 `log-agent` 사이드카가 `emptyDir` 볼륨을 통해 Nginx의 `/var/log/nginx/access.log`를 실시간 스트리밍합니다.

```bash
# 1) WEB 파드의 READY가 2/2 (nginx + log-agent)인지 확인
kubectl get pods -n petclinic -l tier=web

# 2) ALB로 요청을 몇 번 보낸 뒤 사이드카(log-agent) 컨테이너 로그 출력 확인
ALB=$(kubectl get ingress petclinic-ingress -n petclinic -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://$ALB/healthz" >/dev/null
kubectl logs -n petclinic -l tier=web -c log-agent --tail=10
```

---

### Step 3-3. 기능 ③ & ④ — `LimitRange` · `ResourceQuota` · `PDB` · `CronJob` 동작 확인
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 셸]`**

```bash
# 1) 네임스페이스 ResourceQuota 사용량 vs 상한(피크 + maxSurge 1 고려) 확인
kubectl describe resourcequota petclinic-quota -n petclinic
kubectl describe limitrange petclinic-limitrange -n petclinic

# 2) PodDisruptionBudget (minAvailable: 1) 상태 확인
kubectl get pdb -n petclinic

# 3) DB 현황 리포트 CronJob을 수동으로 즉시 1회 트리거하여 결과 로그 확인
kubectl create job --from=cronjob/petclinic-report manual-report-test -n petclinic
kubectl wait --for=condition=complete job/manual-report-test -n petclinic --timeout=60s
kubectl logs job/manual-report-test -n petclinic
kubectl delete job manual-report-test -n petclinic
```

---

## 📅 Stage 4 (4일차): 오토스케일링 3단계 확장 (HPA → KEDA → Karpenter)

> **🎯 Stage 4 목표**: 오토스케일링 3종을 한꺼번에 보지 않고 **① WAS(CPU 기반 HPA) → ② WEB(ALB 요청 수 & 시간대 기반 KEDA) → ③ 노드(Pending 파드 기반 Karpenter)** 순서로 하나씩 동작을 확인합니다.

---

### Step 4-1. 1단계 — WAS CPU 기반 `HPA (2~4)` 단독 테스트
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 셸]`**

```bash
# 1) 현재 WAS HPA 상태 확인 (minReplicas: 2, maxReplicas: 4)
kubectl get hpa petclinic-was-hpa -n petclinic

# 2) 2분간 WAS(/petclinic/owners?lastName=)에 부하를 주어 WAS 파드가 2 -> 4개로 늘어나는지 확인
kubectl run was-hpa-test --rm -i --tty --image=busybox:1.37 --restart=Never -n petclinic -- \
  /bin/sh -c "END=\$((SECONDS+120)); while [ \$SECONDS -lt \$END ]; do wget -q -O- 'http://petclinic-was:8080/petclinic/owners?lastName=' >/dev/null; done"

kubectl get hpa petclinic-was-hpa -n petclinic
kubectl get pods -n petclinic -l tier=was
```

---

### Step 4-2. 2단계 — KEDA 설치(Pod Identity) 및 WEB `ScaledObject` 추가
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 셸]`** (`~/petclinic-k8s-project`)

정적 파일 서빙과 리버스 프록시를 수행하는 WEB(Nginx) 티어는 CPU보다 **유입 요청 수(ALB `RequestCountPerTarget`)**와 **업무 시간대(`cron`)**로 스케일링하는 것이 적합하므로 KEDA를 설치해 연결합니다.

```bash
# 1) KEDA Helm 설치 (ng-system 노드에 배치)
helm repo add kedacore https://kedacore.github.io/charts && helm repo update
helm upgrade -i keda kedacore/keda --namespace keda --create-namespace \
  --set tolerations[0].key=CriticalAddonsOnly --set tolerations[0].operator=Exists --set tolerations[0].effect=NoSchedule --wait

# 2) EKS Pod Identity로 KEDA Operator에 CloudWatch 읽기 권한(CloudWatchReadOnlyAccess) 부여
cat > /tmp/pod-identity-trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }
  ]
}
EOF
aws iam create-role --role-name keda-cloudwatch-pod-identity-role --assume-role-policy-document file:///tmp/pod-identity-trust.json 2>/dev/null || true
aws iam attach-role-policy --role-name keda-cloudwatch-pod-identity-role --policy-arn arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess

aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER" --namespace keda \
  --service-account keda-operator \
  --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/keda-cloudwatch-pod-identity-role"
kubectl rollout restart deploy keda-operator -n keda

# 3) 현재 ALB 및 TargetGroup Dimension을 추출하여 keda/web-scaledobject.yaml에 반영 후 적용
ALB=$(kubectl get ingress petclinic-ingress -n petclinic -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
ALB_ARN=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$ALB'].LoadBalancerArn" --output text)
ALB_DIM=$(echo "$ALB_ARN" | awk -F'loadbalancer/' '{print $2}')
TG_ARN=$(aws elbv2 describe-target-groups --load-balancer-arn "$ALB_ARN" --query 'TargetGroups[0].TargetGroupArn' --output text)
TG_DIM=$(echo "$TG_ARN" | awk -F':' '{print $6}')

sed -i "s|\${ALB_DIMENSION}|${ALB_DIM}|g" keda/web-scaledobject.yaml
sed -i "s|\${TG_DIMENSION}|${TG_DIM}|g" keda/web-scaledobject.yaml
kubectl apply -f keda/web-scaledobject.yaml

# 4) KEDA ScaledObject가 READY=True 상태가 되었는지 확인
kubectl get scaledobject,hpa -n petclinic
```

---

### Step 4-3. 3단계 — Karpenter `NodePool` 상한(`limits.cpu`) 및 `do-not-disrupt` 보호 확인
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 셸]`**

```bash
# 1) Karpenter NodePool의 클러스터 상한(limits.cpu: 16) 및 Consolidation 설정 확인
kubectl describe nodepool default

# 2) 현재 Karpenter가 띄운 앱 노드 목록 및 용량 타입(spot / on-demand) 확인
kubectl get nodes -L karpenter.sh/nodepool -L karpenter.sh/capacity-type
```

---

## 📅 Stage 5 (5일차): 4대 운영 시나리오 통합 시연 · 문서화 · 8단계 Teardown

> **🎯 Stage 5 목표**: Stage 1~4에 걸쳐 하나씩 쌓아 올린 전체 아키텍처의 **연쇄 동작 시나리오 4가지**를 시연·캡처하고, **8단계 역순 Teardown**으로 과금 리소스를 완전히 정리합니다.
> *(시연 시 Bastion SSH 창을 **터미널 1(모니터링)**과 **터미널 2(명령 실행)** 2개로 띄워 두면 편리합니다.)*

---

### 🔥 시나리오 1: KEDA → Karpenter 연쇄 확장 및 Consolidation 축소
* 📍 **모니터링**: 🐧 **`[Bastion EC2 — 터미널 1]`**
  ```bash
  watch -n 2 "kubectl get pods -n petclinic -l tier=web -o wide; echo '---'; kubectl get scaledobject,hpa -n petclinic; echo '---'; kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type"
  ```
* 📍 **부하 발생 (5분 이상 지속)**: 🐧 **`[Bastion EC2 — 터미널 2]`**
  ```bash
  ALB=$(kubectl get ingress petclinic-ingress -n petclinic -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

  # 6분(360초) 동안 지속 부하 발생 -> KEDA가 web 파드 확장 -> Pending 발생 시 Karpenter 노드 추가 -> 종료 후 Consolidation 축소
  kubectl run load-generator --rm -i --tty --image=busybox:1.37 --restart=Never -- \
    /bin/sh -c "END=\$((SECONDS+360)); while [ \$SECONDS -lt \$END ]; do
      for i in 1 2 3 4 5 6 7 8 9 10; do wget -q -O- http://$ALB/ >/dev/null 2>&1 & done;
      sleep 0.2;
    done; wait"
  ```

---

### 🔥 시나리오 2: `StatefulSet` 장애 복구 및 AZ 정합성 확인 (`dev` 환경)
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 — 터미널 2]`**

```bash
# 1) dev 오버레이 상태에서 petclinic-db-0의 현재 노드 및 가용 영역(AZ) 기록
kubectl delete svc petclinic-db -n petclinic 2>/dev/null || true
kubectl delete job petclinic-db-seed -n petclinic 2>/dev/null || true
kubectl apply -k k8s/overlays/dev

NODE_BEFORE=$(kubectl get pod petclinic-db-0 -n petclinic -o jsonpath='{.spec.nodeName}')
ZONE_BEFORE=$(kubectl get node "$NODE_BEFORE" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
echo "삭제 전 -> Node: $NODE_BEFORE | AZ: $ZONE_BEFORE"

# 2) DB 파드 강제 삭제 후 동일한 이름(petclinic-db-0), 동일한 PVC, 동일한 AZ로 복구되는지 확인
kubectl delete pod petclinic-db-0 -n petclinic
kubectl wait --for=condition=ready pod/petclinic-db-0 -n petclinic --timeout=120s

NODE_AFTER=$(kubectl get pod petclinic-db-0 -n petclinic -o jsonpath='{.spec.nodeName}')
ZONE_AFTER=$(kubectl get node "$NODE_AFTER" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
echo "복구 후 -> Node: $NODE_AFTER | AZ: $ZONE_AFTER"
```

---

### 🔥 시나리오 3: 무중단 롤링 업데이트 (`v1 → v2`) 및 즉시 롤백
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 — 터미널 2]`**

```bash
kubectl set image deploy/petclinic-web nginx="${ECR_URI}/petclinic-web:v2" -n petclinic
kubectl annotate deploy/petclinic-web kubernetes.io/change-cause="Update web to v2" -n petclinic --overwrite
kubectl rollout status deploy/petclinic-web -n petclinic
kubectl rollout history deploy/petclinic-web -n petclinic

# 롤백 실행
kubectl rollout undo deploy/petclinic-web -n petclinic
kubectl rollout status deploy/petclinic-web -n petclinic
```

---

### 🔥 시나리오 4: 노드 유지보수 `kubectl drain` & `PDB` 보호 확인
> 📍 **실행 위치**: 🐧 **`[Bastion EC2 — 터미널 2]`**

```bash
APP_NODE=$(kubectl get nodes -l tier=app -o jsonpath='{.items[0].metadata.name}')
kubectl drain "$APP_NODE" --ignore-daemonsets --delete-emptydir-data
kubectl get pods -n petclinic -o wide
kubectl uncordon "$APP_NODE"
```

---

### 🧹 최종 단계: 8단계 역순 안전 삭제 (Teardown)

1. 📍 **1~7단계 (워크로드 → NodePool → Ingress/ALB → PVC/EBS → RDS → EKS → ECR)**: 🐧 **`[Bastion EC2 셸]`**
   ```bash
   bash scripts/teardown.sh

   source ~/petclinic-env.sh
   aws rds delete-db-subnet-group --db-subnet-group-name petclinic-db-subnet-grp 2>/dev/null || true
   aws ec2 delete-security-group --group-id "$RDS_SG" 2>/dev/null || true
   ```

2. 📍 **8단계 (Bastion EC2 · NAT GW · EIP 완전 삭제 및 잔여 확인)**: 🌐 **`[AWS CloudShell]`**
   ```bash
   export AWS_PAGER=""
   export REGION="ap-northeast-2"

   BASTION_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=petclinic-bastion" "Name=instance-state-name,Values=running,stopped" --query 'Reservations[0].Instances[0].InstanceId' --output text)
   [ "$BASTION_ID" != "None" ] && aws ec2 terminate-instances --instance-ids "$BASTION_ID" && aws ec2 wait instance-terminated --instance-ids "$BASTION_ID"

   NAT_GW=$(aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=petclinic-nat-gw" "Name=state,Values=available" --query 'NatGateways[0].NatGatewayId' --output text)
   if [ "$NAT_GW" != "None" ]; then
     aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW"
     aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_GW"
   fi
   EIP_ALLOC=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=petclinic-nat-eip" --query 'Addresses[0].AllocationId' --output text)
   [ "$EIP_ALLOC" != "None" ] && aws ec2 release-address --allocation-id "$EIP_ALLOC"

   echo "남은 NAT GW : $(aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending --query 'length(NatGateways)' --output text)"
   echo "남은 EIP    : $(aws ec2 describe-addresses --query 'length(Addresses)' --output text)"
   echo "남은 ALB    : $(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text)"
   ```
