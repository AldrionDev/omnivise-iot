# ============================================
# Stage 1: Build the application with Maven
# ============================================
FROM maven:3.9-eclipse-temurin-21-alpine AS builder

WORKDIR /app

COPY pom.xml .
RUN mvn dependency:go-offline -B

COPY src ./src
RUN mvn clean package -DskipTests

# ============================================
# Stage 2: Create the runtime image
# ============================================
FROM eclipse-temurin:21-jre-alpine

# Install wget for healthcheck
RUN apk add --no-cache wget

WORKDIR /app

# Copy ONLY the fat JAR (exclude original-*)
COPY --from=builder /app/target/omnivise-backend-*.jar app.jar

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "app.jar"]