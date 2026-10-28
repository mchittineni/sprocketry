# Java bytecode is the same on every CPU, so the build stage runs on the builder's own CPU and multi-arch
# builds need no emulation. Only the runtime stage differs per architecture.
FROM --platform=$BUILDPLATFORM maven:3.9.16-eclipse-temurin-25 AS build
WORKDIR /src
COPY pom.xml ./
RUN mvn -B -q dependency:go-offline
COPY src ./src
# Tests run in CI (they need a database); the image build only packages. Extracting the jar puts the
# dependencies in their own directory and starts faster than running the nested jar.
RUN mvn -B -q package -DskipTests \
 && java -Djarmode=tools -jar target/profile.jar extract --destination /out

FROM eclipse-temurin:25.0.4_7-jre-noble
WORKDIR /app
COPY --from=build /out /app
# Numeric uid needs no passwd entry, so the runtime stage has no RUN step. Nothing is written outside
# /tmp (JVM perf data, Tomcat's work directory), so the root filesystem can be read-only.
USER 10001
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/profile.jar"]
