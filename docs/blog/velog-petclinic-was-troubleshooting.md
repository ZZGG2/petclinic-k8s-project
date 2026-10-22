# [EKS] Spring PetClinic WAS가 DB에 붙지 않던 이유 — 세 겹으로 숨어 있던 원인 추적기

> **환경**
> - Amazon EKS 1.36 / AWS Load Balancer Controller v3.4.1 (Gateway API)
> - WEB: `nginx:1.30-alpine` (정적 페이지 + `/petclinic/` 리버스 프록시)
> - WAS: `tomcat:11.0-jdk17-temurin` + `spring-framework-petclinic` (Spring Framework 7, **WAR 패키징**)
> - DB: `mysql:8.4` (Stage 1 MVP용 단일 Deployment)

부트캠프 Kubernetes 개인 프로젝트로 PetClinic 3-Tier(WEB → WAS → DB)를 EKS에 올리는 중이었습니다.
WEB 랜딩 페이지는 ALB 주소로 잘 열렸는데, **`/petclinic/`만 들어가면 Tomcat 404**가 떴습니다.

결론부터 말하면 원인은 하나가 아니라 **세 겹**이었고, 하나를 고칠 때마다 그 뒤에 숨어 있던 다음 문제가 드러났습니다.

| 순서 | 증상 | 원인 | 해결 |
|---|---|---|---|
| 1 | WAS 파드 `CrashLoopBackOff` | `catalina.sh`가 `JAVA_OPTS`를 `eval`로 펼치면서 `&`, `#`이 셸 문법으로 해석됨 | `JDK_JAVA_OPTIONS` 사용 |
| 2 | 파드는 Running인데 `/petclinic/` 404 | `-Djdbc.url`이 적용되지 않고 `localhost`로 접속 | (가설) 설정 파일을 Secret으로 교체 |
| 3 | 파일을 바꿔도 여전히 404 | **Maven 리소스 필터링**이 XML의 `${jdbc.url}`까지 `localhost`로 치환해 버림 | 빌드 후 XML 플레이스홀더 복원 |

---

## 1. 첫 번째 벽: WAS 파드 CrashLoopBackOff

### 증상

WAS Deployment에는 DB 접속 정보를 JVM 시스템 프로퍼티로 넘기고 있었습니다.

```yaml
env:
  - name: JAVA_OPTS
    value: >-
      -Dspring.profiles.active=jpa
      -Djdbc.url=jdbc:mysql://petclinic-db:3306/petclinic?useUnicode=true&characterEncoding=UTF-8
      -Djdbc.username=petclinic
      -Djdbc.password=PetClinicApp#2026
```

파드가 뜨자마자 죽고, 재시작을 반복했습니다.

```bash
kubectl logs -n petclinic deploy/petclinic-was --previous
```

### 원인: catalina.sh의 eval

Tomcat의 시작 스크립트 `catalina.sh`는 내부에서 `JAVA_OPTS`를 **`eval`로 펼쳐서** java를 실행합니다. 그래서 값 안의 특수문자가 **셸 문법으로 해석**됩니다.

| 문자 | 위치 | 셸에서의 의미 | 결과 |
|---|---|---|---|
| `&` | JDBC URL의 쿼리 스트링 | 백그라운드 실행 | java가 옵션 일부만 받은 채 백그라운드로 분리됨 |
| `#` | 비밀번호 | 주석 시작 | 그 뒤의 `-classpath ... Bootstrap start`가 통째로 무시됨 |

결국 Tomcat 메인 프로세스가 제대로 시작되지 않고 컨테이너가 종료됐던 것입니다.

### 해결: JDK_JAVA_OPTIONS

`JDK_JAVA_OPTIONS`는 셸이 아니라 **java 런처가 직접 읽는 환경변수**입니다(JDK 9+). `eval`을 거치지 않으므로 `&`, `#`이 그냥 문자로 전달됩니다.

```yaml
env:
  - name: JDK_JAVA_OPTIONS   # JAVA_OPTS → JDK_JAVA_OPTIONS
    value: >-
      -Djdbc.url=jdbc:mysql://petclinic-db:3306/petclinic?useUnicode=true&characterEncoding=UTF-8
      ...
```

기동 로그 첫 줄에 아래 메시지가 찍히면 적용된 것입니다.

```text
NOTE: Picked up JDK_JAVA_OPTIONS: -Djdbc.url=jdbc:mysql://petclinic-db:3306/...
```

파드는 이제 `Running`이 됐습니다. 그런데…

---

## 2. 두 번째 벽: Running인데 /petclinic/ 은 404

### 증상

```bash
curl -s -o /dev/null -w "%{http_code}\n" "http://$ALB/petclinic/"
# 404  (Apache Tomcat 기본 404 페이지)
```

WAS 로그에는 이런 에러가 있었습니다.

```text
SEVERE [main] org.apache.tomcat.jdbc.pool.ConnectionPool.init Unable to create initial connections of pool.
    com.mysql.cj.jdbc.exceptions.CommunicationsException: Communications link failure
    Caused by: java.net.ConnectException: Connection refused
...
SEVERE [main] org.apache.catalina.core.StandardContext.startInternal One or more listeners failed to start.
```

> **"Running인데 서비스는 안 되는" 상태**
> Spring 컨텍스트 초기화가 DB 연결 실패로 중단되면서 **애플리케이션 배포만 실패**하고, Tomcat 프로세스 자체는 살아 있었습니다. 그래서 쿠버네티스 입장에서는 정상(Running)으로 보이고, `/petclinic` 컨텍스트가 없으니 404가 납니다.
> 이런 상태를 쿠버네티스가 감지하게 해주는 것이 바로 **readinessProbe**입니다.

### 첫 번째 의심: 타이밍?

처음에는 "WAS가 MySQL 초기화보다 먼저 떠서 그렇다"고 생각했습니다. 하지만 DB 파드는 16분째 Running인데 **WAS를 재시작해도 똑같이 실패**했습니다. 타이밍 문제는 아니었습니다.

### 구간을 잘라서 확인하기

`Connection refused`는 **IP까지는 도달했는데 그 포트에서 아무도 받아주지 않는다**는 뜻입니다. 그래서 WAS → DB 구간을 하나씩 잘라서 확인했습니다.

```bash
# ① Service가 DB 파드를 가리키는지
kubectl get endpointslices -n petclinic -l kubernetes.io/service-name=petclinic-db
# petclinic-db-xxxxx   IPv4   3306   10.0.50.240   → 정상

# ② WAS 파드에서 DB 포트로 TCP 연결
kubectl exec -n petclinic deploy/petclinic-was -- \
  bash -c 'timeout 3 bash -c "echo > /dev/tcp/petclinic-db/3306" && echo "TCP OPEN" || echo "TCP FAIL"'
# TCP OPEN   → 정상

# ③ DB 계정 로그인
kubectl exec -n petclinic deploy/petclinic-db-mvp -- \
  mysql -upetclinic -p'PetClinicApp#2026' -e "SELECT 1;"
# 1   → 정상

# ④ JVM이 받은 옵션
kubectl logs -n petclinic deploy/petclinic-was | grep "Command line argument: -Djdbc"
# -Djdbc.url=jdbc:mysql://petclinic-db:3306/...   → 정상
```

**네트워크, DB, 계정, JVM 옵션이 전부 정상**인데 앱만 `Connection refused`입니다.
남는 해석은 하나였습니다. **앱이 실제로는 `petclinic-db`가 아닌 다른 주소로 접속하고 있다.**

### war 안의 설정 파일 확인

```bash
kubectl exec -n petclinic deploy/petclinic-was -- \
  cat /usr/local/tomcat/webapps/petclinic/WEB-INF/classes/spring/data-access.properties | grep jdbc
```

```properties
jdbc.url=jdbc:mysql://localhost:3306/petclinic?useUnicode=true
jdbc.username=petclinic
jdbc.password=petclinic
```

`./mvnw package -P MySQL`로 빌드할 때 Maven 프로파일 값이 이 파일에 박혀 있었습니다.
여기서 저는 **"`-D` 덮어쓰기가 동작하지 않으니, 이 파일 자체를 런타임에 교체하자"**고 판단했습니다.

### 시도한 해결: Secret + subPath로 설정 파일 교체

1) WAR를 이미지 안에서 **압축 해제된 디렉터리**로 배포하도록 Dockerfile을 바꿨습니다. (war는 zip이라 안의 파일 하나만 바꿀 수 없기 때문)

```dockerfile
COPY --from=builder /build/target/petclinic.war /tmp/petclinic.war
RUN mkdir -p /usr/local/tomcat/webapps/petclinic \
 && cd /usr/local/tomcat/webapps/petclinic \
 && jar -xf /tmp/petclinic.war \
 && rm /tmp/petclinic.war
```

2) 올바른 접속 정보를 담은 `data-access.properties`를 **Secret**으로 만들고, `subPath`로 **파일 하나만** 덮어썼습니다.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: petclinic-was-dbconfig
  namespace: petclinic
type: Opaque
stringData:
  data-access.properties: |
    jdbc.initLocation=classpath:db/mysql/schema.sql
    jdbc.dataLocation=classpath:db/mysql/data.sql
    jpa.showSql=false
    jpa.database=MYSQL
    jdbc.driverClassName=com.mysql.cj.jdbc.Driver
    jdbc.url=jdbc:mysql://petclinic-db:3306/petclinic?useUnicode=true&characterEncoding=UTF-8
    jdbc.username=petclinic
    jdbc.password=PetClinicApp#2026
```

```yaml
volumeMounts:
  - name: dbconfig
    mountPath: /usr/local/tomcat/webapps/petclinic/WEB-INF/classes/spring/data-access.properties
    subPath: data-access.properties   # 디렉터리 전체가 아니라 "파일 하나만" 교체
    readOnly: true
volumes:
  - name: dbconfig
    secret:
      secretName: petclinic-was-dbconfig
```

> **subPath를 쓰는 이유**
> `subPath` 없이 마운트하면 `spring/` 디렉터리 **전체**가 Secret 내용으로 바뀌어서, 같은 폴더의 `business-config.xml` 등 다른 설정 파일이 사라집니다.

> **이미지 태그는 새로 올리기**
> 같은 `v1` 태그로 덮어 푸시하면, 노드에 캐시된 옛 이미지가 그대로 쓰일 수 있습니다(고정 태그의 기본 `imagePullPolicy`는 `IfNotPresent`). 수정할 때마다 `v1.1`, `v1.2`처럼 **새 태그**를 붙였습니다.

파드 안에서 확인해 보니 파일은 제대로 바뀌어 있었습니다.

```bash
kubectl exec -n petclinic deploy/petclinic-was -- \
  grep jdbc.url /usr/local/tomcat/webapps/petclinic/WEB-INF/classes/spring/data-access.properties
# jdbc.url=jdbc:mysql://petclinic-db:3306/petclinic?...   ✅
```

그런데 **여전히 `Connection refused`** 였습니다.

---

## 3. 세 번째 벽: 진짜 범인은 Maven 리소스 필터링

### 앱을 빼고 직접 접속해 보기

설정 파일까지 고쳤는데도 같은 결과라면 제 가설 자체를 의심해야 했습니다. 그래서 **앱을 거치지 않고, 같은 파드에서 같은 JDBC 드라이버로** 직접 접속해 봤습니다. Java 11+의 **단일 소스 파일 실행** 기능을 쓰면 컴파일 없이 바로 돌릴 수 있습니다.

```bash
kubectl exec -n petclinic deploy/petclinic-was -- bash -c 'cat > /tmp/T.java <<EOF
public class T {
  public static void main(String[] a) throws Exception {
    System.out.println("DNS  : " + java.net.InetAddress.getByName("petclinic-db"));
    try (var s = new java.net.Socket("petclinic-db", 3306)) { System.out.println("TCP  : OK"); }
    try (var c = java.sql.DriverManager.getConnection(
          "jdbc:mysql://petclinic-db:3306/petclinic?useUnicode=true&characterEncoding=UTF-8",
          "petclinic", "PetClinicApp#2026")) {
      System.out.println("JDBC : OK  MySQL " + c.getMetaData().getDatabaseProductVersion());
    }
  }
}
EOF
java -cp "/usr/local/tomcat/webapps/petclinic/WEB-INF/lib/*" /tmp/T.java'
```

```text
DNS  : petclinic-db/172.20.82.52
TCP  : OK
JDBC : OK  MySQL 8.4.13
```

**드라이버로 직접 접속하면 성공합니다.** 문제는 확실히 앱 내부에 있다는 뜻입니다.

### localhost가 남아 있는 곳 찾기

```bash
kubectl exec -n petclinic deploy/petclinic-was -- \
  grep -rl "localhost:3306" /usr/local/tomcat/webapps/petclinic
```

```text
/usr/local/tomcat/webapps/petclinic/META-INF/maven/.../pom.xml
/usr/local/tomcat/webapps/petclinic/WEB-INF/classes/spring/datasource-config.xml   ← !!
```

`datasource-config.xml`을 열어 보니 이렇게 되어 있었습니다.

```xml
<!-- 원본 소스 (GitHub) -->
<bean id="dataSource" class="org.apache.tomcat.jdbc.pool.DataSource"
      p:driverClassName="${jdbc.driverClassName}" p:url="${jdbc.url}"
      p:username="${jdbc.username}" p:password="${jdbc.password}"/>

<!-- 빌드된 war 안의 실제 파일 -->
<bean id="dataSource" class="org.apache.tomcat.jdbc.pool.DataSource"
      p:driverClassName="com.mysql.cj.jdbc.Driver" p:url="jdbc:mysql://localhost:3306/petclinic?useUnicode=true"
      p:username="petclinic" p:password="petclinic"/>
```

### 원인: Maven 리소스 필터링

이 프로젝트는 `-P MySQL` 프로파일에서 `jdbc.url`, `jdbc.username` 같은 **Maven 속성**을 정의하고, `src/main/resources`에 **리소스 필터링**을 걸어 둡니다.

```xml
<!-- pom.xml (MySQL 프로파일) -->
<properties>
    <jdbc.url>jdbc:mysql://localhost:3306/petclinic?useUnicode=true</jdbc.url>
    <jdbc.username>petclinic</jdbc.username>
    ...
</properties>
```

필터링은 `.properties`만이 아니라 **리소스 디렉터리의 모든 파일**에 적용됩니다. 그래서 Spring이 런타임에 채워야 할 XML 속 `${jdbc.url}`까지 Maven이 **빌드 시점에 `localhost`로 치환**해 버렸습니다.

```text
빌드 전:  p:url="${jdbc.url}"                                   ← Spring이 런타임에 채울 자리
빌드 후:  p:url="jdbc:mysql://localhost:3306/petclinic..."     ← 이미 확정된 값
```

**덮어쓸 자리 자체가 사라졌기 때문에** `-Djdbc.url`도, properties 파일 교체도 아무 효과가 없었던 것입니다.

> **가설 수정**
> 2단계에서 저는 "`system-properties-mode="OVERRIDE"`로 `-D` 덮어쓰기가 안 된다"고 생각했지만, 이건 틀린 추정이었습니다. 덮어쓰기 기능 자체는 정상이었고, **덮어쓸 플레이스홀더가 빌드 단계에서 이미 사라진 것**이 진짜 원인이었습니다.

### 해결: 빌드 "후"에 XML 플레이스홀더 복원

빌드 전에 소스를 고치면 Maven이 다시 치환하므로, **war를 푼 뒤**에 XML을 플레이스홀더로 되돌립니다.

```dockerfile
# Stage 2: Runtime
FROM tomcat:11.0-jdk17-temurin

RUN rm -rf /usr/local/tomcat/webapps/*
COPY --from=builder /build/target/petclinic.war /tmp/petclinic.war
RUN mkdir -p /usr/local/tomcat/webapps/petclinic \
 && cd /usr/local/tomcat/webapps/petclinic \
 && jar -xf /tmp/petclinic.war \
 && rm /tmp/petclinic.war

# Maven 필터링으로 하드코딩된 값을 다시 ${...} 플레이스홀더로 복원
RUN cd /usr/local/tomcat/webapps/petclinic/WEB-INF/classes/spring \
 && sed -i -E \
      -e 's#p:driverClassName="[^"]*"#p:driverClassName="${jdbc.driverClassName}"#' \
      -e 's#p:url="[^"]*"#p:url="${jdbc.url}"#' \
      -e 's#p:username="[^"]*"#p:username="${jdbc.username}"#' \
      -e 's#p:password="[^"]*"#p:password="${jdbc.password}"#' \
      datasource-config.xml \
 && grep -n "p:url" datasource-config.xml \
 && ! grep -q "localhost:3306" datasource-config.xml

EXPOSE 8080
CMD ["catalina.sh", "run"]
```

- 마지막 줄의 `! grep -q "localhost:3306"`은 **localhost가 하나라도 남아 있으면 이미지 빌드 자체를 실패**시키는 안전장치입니다. 같은 문제가 쿠버네티스까지 넘어가기 전에 빌드 단계에서 바로 드러납니다.
- 이제 XML이 `${jdbc.url}`을 갖고 있으므로, 2단계에서 만들어 둔 **Secret(`data-access.properties`) 주입 방식이 그대로 동작**합니다.

```bash
kubectl logs -n petclinic deploy/petclinic-was | grep -E "Server startup|SEVERE"
# Server startup in [xxxx] milliseconds   ✅
```

<!-- 여기에 브라우저 /petclinic/ → Find Owners 성공 화면 캡처 -->

---

## 4. 정리 & 배운 점

### 3-Tier 장애는 구간을 잘라서 본다

```text
사용자 → ALB → WEB(Nginx) → WAS(Tomcat) → Service(petclinic-db) → DB(MySQL)
```

| 확인 방법 | 무엇을 배제하나 |
|---|---|
| `curl http://$ALB/` vs `/petclinic/` | ALB → WEB 구간 |
| WEB 파드에서 `wget http://petclinic-was:8080/petclinic/` | Nginx 프록시 설정 |
| `kubectl get endpointslices` | Service ↔ 파드 라벨 매칭 |
| WAS 파드에서 `/dev/tcp/petclinic-db/3306` | 네트워크 / DNS |
| DB 파드에서 `mysql -u... -e "SELECT 1"` | DB 계정 / 권한 |
| WAS 파드에서 **단일 Java 파일로 JDBC 직접 접속** | 드라이버 / 앱 외부 요인 |

마지막 단계까지 전부 정상이면 **문제는 앱 내부 설정**이라고 확신할 수 있습니다.

### 핵심 교훈

1. **`JAVA_OPTS`에 특수문자를 넣지 말 것.** Tomcat은 `eval`로 펼칩니다. 값에 `&`, `#`, 공백이 들어가면 `JDK_JAVA_OPTIONS`를 쓰는 게 안전합니다.
2. **"Running ≠ 서비스 가능".** 앱 배포가 실패해도 프로세스는 살아 있을 수 있습니다. readinessProbe가 필요한 이유입니다.
3. **설정은 이미지에 굽지 말고 런타임에 주입한다.** 그리고 빌드 도구(Maven 필터링)가 **어디까지** 값을 박아 넣는지 실제 산출물(war 내부)을 열어서 확인해야 합니다.
4. **결과만 보고 원인을 단정하지 말 것.** "덮어쓰기 기능이 고장났다"는 그럴듯한 추정이었지만 틀렸습니다. 한 겹씩 직접 시험하는 과정이 결국 진짜 원인을 찾아줬습니다.

### 참고

- Tomcat `catalina.sh` — `JAVA_OPTS`/`CATALINA_OPTS` 처리 방식
- JDK `JDK_JAVA_OPTIONS` 환경변수 (JDK 9+)
- Maven Resources Plugin — Filtering
- Kubernetes — Volumes `subPath`
