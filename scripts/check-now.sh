#!/usr/bin/env bash
# 현재 상태 점검 (Stage 4 + 4.5-1 index.html + 4.5-2 Secrets Manager)
# 사용법: bash scripts/check-now.sh
set -u
NS=petclinic
REGION="${REGION:-ap-northeast-2}"
PASS=0; FAIL=0; WARN=0
ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
ng()   { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
wn()   { printf '  [WARN] %s\n' "$1"; WARN=$((WARN+1)); }
chk()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else ng "$d"; fi; }
SPF=/usr/local/tomcat/webapps/petclinic/WEB-INF/classes/spring/data-access.properties

echo "== 1. 롤아웃 / 파드"
for d in petclinic-was petclinic-web; do
  chk "$d 롤아웃 완료" kubectl rollout status deploy/$d -n $NS --timeout=10s
  rs_cnt=$(kubectl get pods -n $NS -l tier=${d#petclinic-} --no-headers 2>/dev/null | awk '{print $1}' | sed -E 's/-[a-z0-9]+$//' | sort -u | wc -l)
  [ "$rs_cnt" -eq 1 ] && ok "$d 파드가 모두 같은 버전(ReplicaSet 1개)" || ng "$d 에 옛/새 파드가 섞여 있음 (ReplicaSet ${rs_cnt}개)"
done
bad=$(kubectl get pods -n $NS --no-headers | awk '$3!="Running" && $3!="Completed" && $1 !~ /^petclinic-report-/ {print $1" "$3}')
[ -z "$bad" ] && ok "비정상 파드 없음 (report 이력 제외)" || ng "비정상 파드: $bad"
notready=$(kubectl get pods -n $NS --no-headers | awk '$3=="Running" {split($2,a,"/"); if (a[1]!=a[2]) print $1}')
[ -z "$notready" ] && ok "Running 파드 모두 Ready" || ng "Ready 아닌 파드: $notready"

echo "== 2. 이미지 태그"
was_img=$(kubectl get deploy petclinic-was -n $NS -o jsonpath='{.spec.template.spec.containers[0].image}')
web_img=$(kubectl get deploy petclinic-web -n $NS -o jsonpath='{.spec.template.spec.containers[0].image}')
[[ "$was_img" == *":v1.2" ]] && ok "WAS 이미지 v1.2" || ng "WAS 이미지: $was_img"
[[ "$web_img" == *":v1.1" ]] && ok "WEB 이미지 v1.1" || ng "WEB 이미지: $web_img"

echo "== 3. External Secrets"
chk "SecretStore Ready" bash -c "[ \"\$(kubectl get secretstore aws-secrets-manager -n $NS -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = True ]"
for es in petclinic-db-secret petclinic-was-dbconfig; do
  chk "ExternalSecret $es Ready" bash -c "[ \"\$(kubectl get externalsecret $es -n $NS -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = True ]"
  chk "Secret $es 소유자 = ExternalSecret" bash -c "[ \"\$(kubectl get secret $es -n $NS -o jsonpath='{.metadata.ownerReferences[0].kind}')\" = ExternalSecret ]"
done

echo "== 4. 비밀번호 일관성 (값은 출력하지 않음)"
SM=$(aws secretsmanager get-secret-value --secret-id petclinic/dev/db --region "$REGION" --query SecretString --output text 2>/dev/null)
SM_APP=$(echo "$SM" | jq -r .DB_PASSWORD 2>/dev/null); SM_ADMIN=$(echo "$SM" | jq -r .DB_ADMIN_PASSWORD 2>/dev/null)
K_APP=$(kubectl get secret petclinic-db-secret -n $NS -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)
F_APP=$(kubectl get secret petclinic-was-dbconfig -n $NS -o jsonpath='{.data.data-access\.properties}' | base64 -d | sed -n 's/^jdbc.password=//p')
[ -n "$SM_APP" ] && [ "$SM_APP" != null ] && ok "Secrets Manager 앱 비밀번호 존재 (${#SM_APP}자)" || ng "Secrets Manager 앱 비밀번호 비어 있음"
[ "$SM_APP" = "$K_APP" ] && ok "Secrets Manager = K8s Secret(petclinic-db-secret)" || ng "Secrets Manager ≠ petclinic-db-secret (force-sync 필요)"
[ "$SM_APP" = "$F_APP" ] && ok "Secrets Manager = WAS properties 템플릿" || ng "Secrets Manager ≠ petclinic-was-dbconfig (force-sync 필요)"
chk "DB 로그인: 앱 계정 (Secrets Manager 값)" kubectl exec -n $NS petclinic-db-0 -- mysql -upetclinic -p"$SM_APP" -e "SELECT 1"
chk "DB 로그인: root (Secrets Manager 값)" kubectl exec -n $NS petclinic-db-0 -- mysql -uroot -p"$SM_ADMIN" -e "SELECT 1"
i=0
for p in $(kubectl get pods -n $NS -l tier=was -o name); do
  P_APP=$(kubectl exec -n $NS ${p#pod/} -- sed -n 's/^jdbc.password=//p' $SPF 2>/dev/null)
  i=$((i+1)); [ "$P_APP" = "$SM_APP" ] && ok "WAS 파드 #$i 가 최신 비밀번호 사용" || ng "WAS 파드 #$i (${p#pod/}) 가 옛 비밀번호 사용 → 재시작 필요"
done
unset SM SM_APP SM_ADMIN K_APP F_APP P_APP
vers=$(aws secretsmanager list-secret-version-ids --secret-id petclinic/dev/db --region "$REGION" --query 'length(Versions)' --output text 2>/dev/null)
[ "${vers:-0}" -ge 2 ] && ok "Secrets Manager 버전 ${vers}개 (교체 이력 있음)" || wn "Secrets Manager 버전 ${vers:-?}개 — 로테이션 실험은 아직 안 한 상태"

echo "== 5. 리포트 CronJob (새 Secret으로 실행)"
kubectl delete job check-report -n $NS --ignore-not-found >/dev/null 2>&1
kubectl create job --from=cronjob/petclinic-report check-report -n $NS >/dev/null 2>&1
if kubectl wait --for=condition=complete job/check-report -n $NS --timeout=150s >/dev/null 2>&1; then
  ok "리포트 Job 성공: $(kubectl logs job/check-report -n $NS 2>/dev/null | tail -1 | sed 's/.*\] //')"
else ng "리포트 Job 실패: $(kubectl logs job/check-report -n $NS 2>/dev/null | tail -1)"; fi
kubectl delete job check-report -n $NS --ignore-not-found >/dev/null 2>&1

echo "== 6. 외부 접속 (ALB)"
ALB=$(kubectl get gateway petclinic-gateway -n $NS -o jsonpath='{.status.addresses[0].value}')
[ -n "$ALB" ] && ok "ALB 주소: http://$ALB/" || ng "Gateway 주소 없음"
BASE="http://$ALB"; [ -n "${DOMAIN:-}" ] && BASE="https://$DOMAIN"
ok "점검 대상: $BASE"
c1=$(curl -s -o /tmp/idx.html -w '%{http_code}' -m 10 "$BASE/")
[ "$c1" = 200 ] && ok "/ → 200" || ng "/ → $c1"
grep -q 'data-ver="v1"' /tmp/idx.html && grep -q 'PetClinic on Amazon EKS' /tmp/idx.html && ok "/ 가 새 발표용 페이지(v1)" || ng "/ 가 새 index.html 이 아님"
c2=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$BASE/petclinic/owners?lastName=")
[ "$c2" = 200 ] && ok "/petclinic/owners → 200 (WEB→WAS→DB)" || ng "/petclinic/owners → $c2"
c3=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$BASE/healthz")
[ "$c3" = 200 ] && ok "/healthz → 200" || ng "/healthz → $c3"
if [ -n "${DOMAIN:-}" ]; then
  r=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -m 10 "http://$DOMAIN/")
  [[ "$r" == 301\ https://$DOMAIN* ]] && ok "http://$DOMAIN → 301 HTTPS 리다이렉트" || ng "HTTP 리다이렉트 이상: $r"
fi

echo "== 7. 오토스케일링 / 노드"
chk "WAS HPA 지표 수집 중" bash -c "kubectl get hpa petclinic-was-hpa -n $NS -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' | grep -qE '^[0-9]+$'"
chk "KEDA ScaledObject Ready" bash -c "[ \"\$(kubectl get scaledobject petclinic-web-scaledobject -n $NS -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = True ]"
chk "Karpenter NodePool Ready" bash -c "[ \"\$(kubectl get nodepool default -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = True ]"
app_on_sys=$(kubectl get pods -n $NS -l 'tier in (was,web)' -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | while read n; do kubectl get node "$n" -o jsonpath='{.metadata.labels.role}'; echo; done | grep -c system)
[ "$app_on_sys" -eq 0 ] && ok "WEB/WAS가 모두 Karpenter 노드에 있음" || wn "WEB/WAS ${app_on_sys}개가 아직 ng-system 노드에 있음"
leftover=$(kubectl get deploy inflate -n default --no-headers 2>/dev/null | wc -l)
[ "$leftover" -eq 0 ] && ok "실험용 inflate 정리됨" || wn "default/inflate 남아 있음 (비용)"

echo "== 8. Git 평문 비밀번호"
if [ -d ~/petclinic-k8s-project/k8s ]; then
  hits=$(grep -rlE 'PetClinic(App|Admin)#' ~/petclinic-k8s-project/k8s --include=*.yaml 2>/dev/null | grep -v stage1-mvp)
  [ -z "$hits" ] && ok "k8s/ 에 평문 비밀번호 없음 (stage1-mvp 제외)" || ng "평문 비밀번호 남은 파일: $hits"
fi

echo "--------------------------------------------"
printf ' PASS=%d  FAIL=%d  WARN=%d\n' "$PASS" "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ]
