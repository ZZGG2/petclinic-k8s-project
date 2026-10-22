# Stage 1: Build WAR with MySQL profile
FROM maven:3.9-eclipse-temurin-17 AS builder
WORKDIR /build

# Git clone or copy source from spring-framework-petclinic
COPY pom.xml .
COPY src ./src
RUN mvn clean package -P MySQL -DskipTests

# Stage 2: Runtime on Tomcat 11 (Jakarta EE 10/11 compatible)
FROM tomcat:11.0-jdk17-temurin

# Remove default webapps and deploy as /petclinic context path
RUN rm -rf /usr/local/tomcat/webapps/*
COPY --from=builder /build/target/petclinic.war /usr/local/tomcat/webapps/petclinic.war

EXPOSE 8080
CMD ["catalina.sh", "run"]
