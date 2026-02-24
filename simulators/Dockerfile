# Multi-stage Docker build for Sensor Data Simulator
# Stage 1: Build stage - Compiling code with Maven
FROM maven:3.9-eclipse-temurin-17-alpine AS build

WORKDIR /app

# First, copy only pom.xml (for caching)
COPY pom.xml .

# Download dependencies (this is cached if pom.xml doesn't change)
RUN mvn dependency:go-offline -B

# Copy source code and build
COPY src ./src
RUN mvn clean package -DskipTests

# Stage 2: Runtime stage - Contains only the runnable JAR
FROM eclipse-temurin:17-jre-alpine

# Metadata
LABEL maintainer="omnivise-iot"
LABEL description="IoT Sensor Data Simulator"

WORKDIR /app

# Copy fat JAR from build stage
COPY --from=build /app/target/sensor-data-simulator-1.0.0.jar /app/simulator.jar

# Create non-root user for security reasons
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

# Default environment variables
ENV MONGO_URI=mongodb://admin:admin123@mongodb:27017
ENV MONGO_DATABASE=omnivise_iot
ENV MONGO_COLLECTION=sensor_readings
ENV INTERVAL_SECONDS=5

# Healthcheck - checks if the container is running
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD pgrep -f java || exit 1

# Start application
ENTRYPOINT ["java", "-jar", "/app/simulator.jar"]
