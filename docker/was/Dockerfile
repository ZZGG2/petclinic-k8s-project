# Stage 1: Build WAR with MySQL profile
FROM maven:3.9-eclipse-temurin-17 AS builder
WORKDIR /build

# Git clone or copy source from spring-framework-petclinic
COPY pom.xml .
COPY src ./src

# [Fix] MySQL 드라이버 좌표 변경 대응
#  - mysql:mysql-connector-java 는 8.0.31부터 com.mysql:mysql-connector-j 로 이전됨
#  - 8.1.0은 옛 좌표(mysql:mysql-connector-java)에 jar가 없어 의존성 해결 실패
#  - 원본 소스는 건드리지 않고, 빌드 시점에만 pom.xml의 groupId/artifactId를 교체
RUN sed -i \
      -e 's#<groupId>mysql</groupId>#<groupId>com.mysql</groupId>#' \
      -e 's#<artifactId>mysql-connector-java</artifactId>#<artifactId>mysql-connector-j</artifactId>#' \
      pom.xml \
 && grep -n -A1 "<groupId>com.mysql</groupId>" pom.xml
RUN mvn clean package -P MySQL -DskipTests

# Stage 2: Runtime on Tomcat 11 (Jakarta EE 10/11 compatible)
FROM tomcat:11.0-jdk17-temurin

# Remove default webapps and deploy as /petclinic context path
# [Fix] war 파일 대신 "압축 해제된 디렉터리"로 배포
#  - 디렉터리로 풀어두면 K8s에서 WEB-INF/classes/spring/data-access.properties 파일 하나만
#    Secret(subPath)으로 교체해 DB 접속 정보를 "런타임"에 주입할 수 있음
RUN rm -rf /usr/local/tomcat/webapps/*
COPY --from=builder /build/target/petclinic.war /tmp/petclinic.war
RUN mkdir -p /usr/local/tomcat/webapps/petclinic \
 && cd /usr/local/tomcat/webapps/petclinic \
 && jar -xf /tmp/petclinic.war \
 && rm /tmp/petclinic.war \
 && ls WEB-INF/classes/spring/data-access.properties

# [Fix] Maven 리소스 필터링이 XML의 ${jdbc.*} 플레이스홀더까지 빌드 시점 값(localhost)으로 치환함
#  → datasource-config.xml 에 p:url="jdbc:mysql://localhost:3306/..." 가 "하드코딩"되어
#    -D 옵션이나 properties 파일로는 절대 바꿀 수 없음 (트러블슈팅으로 확인)
#  → 빌드가 끝난 뒤 XML을 다시 플레이스홀더로 되돌려 런타임 설정(data-access.properties)을 읽게 함
#    (빌드 전에 고치면 Maven이 다시 치환하므로 반드시 "빌드 후"에 수정)
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
