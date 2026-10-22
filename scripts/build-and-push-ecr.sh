#!/usr/bin/env bash
# WEB 및 WAS 컨테이너 이미지 빌드 & AWS ECR 푸시 스크립트
set -euo pipefail

export AWS_PAGER=""
REGION="${REGION:-ap-northeast-2}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
# 이미지 태그는 덮어쓰지 않고 새 태그로 올림 (노드의 이미지 캐시 때문에 같은 태그는 갱신이 안 될 수 있음)
WEB_TAG="${WEB_TAG:-v1}"
WAS_TAG="${WAS_TAG:-v1.2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "[1/4] ECR 리포지토리 생성 확인..."
for repo in petclinic-web petclinic-was; do
  aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1 || \
    aws ecr create-repository \
      --repository-name "$repo" \
      --image-scanning-configuration scanOnPush=true \
      --region "$REGION" >/dev/null
done

echo "[2/4] ECR Docker 로그인..."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR_URI"

echo "[3/4] WEB 이미지 빌드 및 푸시..."
docker build -t "${ECR_URI}/petclinic-web:${WEB_TAG}" "${ROOT_DIR}/docker/web"
docker push "${ECR_URI}/petclinic-web:${WEB_TAG}"

echo "[4/4] WAS 소스 준비 및 Multi-Stage 이미지 빌드/푸시..."
WAS_BUILD_DIR="/tmp/spring-framework-petclinic-build"
if [ ! -d "$WAS_BUILD_DIR" ]; then
  git clone --depth 1 https://github.com/spring-petclinic/spring-framework-petclinic.git "$WAS_BUILD_DIR"
fi
cp "${ROOT_DIR}/docker/was/Dockerfile" "${WAS_BUILD_DIR}/Dockerfile"
docker build -t "${ECR_URI}/petclinic-was:${WAS_TAG}" "$WAS_BUILD_DIR"
docker push "${ECR_URI}/petclinic-was:${WAS_TAG}"

echo "[완료] ECR 이미지 업로드 완료:"
echo "  - ${ECR_URI}/petclinic-web:${WEB_TAG}"
echo "  - ${ECR_URI}/petclinic-was:${WAS_TAG}"
