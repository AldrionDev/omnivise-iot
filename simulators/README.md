# 🤖 Sensor Data Simulator

Continuously generates random IoT sensor data and writes it to MongoDB.

## 📋 Features

- **Supports 5 sensor types**:
  - 🌡️ Temperature: 15-30°C
  - 💧 Humidity: 40-80%
  - 🚶 Motion sensor: true/false
  - 💡 Light intensity: 0-1000 lux
  - 🌡️ Atmospheric pressure: 980-1040 hPa

- **Random data generation**: Multiple locations and sensor IDs
- **Configurable interval**: Default 5 seconds
- **MongoDB integration**: Directly writes data to the `sensor_readings` collection

## 🚀 Running

### Locally (with Maven)

1. **Build**:

   ```bash
   mvn clean package
   ```

2. **Run**:
   ```bash
   java -jar target/sensor-data-simulator-1.0.0.jar
   ```

### With Docker

1. **Build Docker image**:

   ```bash
   docker build -t omnivise-sensor-simulator .
   ```

2. **Run container**:
   ```bash
   docker run --rm \
     --network omnivise-iot_omnivise-network \
     -e MONGO_URI=mongodb://admin:admin123@mongodb:27017 \
     -e MONGO_DATABASE=omnivise_iot \
     -e INTERVAL_SECONDS=5 \
     omnivise-sensor-simulator
   ```

### With Docker Compose

Already configured in the root `docker-compose.yml`, just start it:

```bash
docker-compose up -d sensor-simulator
```

## ⚙️ Environment Variables

| Variable           | Default                                    | Description                    |
| ------------------ | ------------------------------------------ | ------------------------------ |
| `MONGO_URI`        | `mongodb://admin:admin123@localhost:27017` | MongoDB connection string      |
| `MONGO_DATABASE`   | `omnivise_iot`                             | Database name                  |
| `MONGO_COLLECTION` | `sensor_readings`                          | Collection name                |
| `INTERVAL_SECONDS` | `5`                                        | Generation interval in seconds |

## 📊 Generated Data Format

```json
{
  "sensor_id": "sensor_042",
  "type": "temperature",
  "value": 22.5,
  "unit": "°C",
  "location": "Office Room 1",
  "timestamp": "2026-02-24T10:30:00Z"
}
```

## 🛠️ Development

**Requirements**:

- Java 17+
- Maven 3.8+
- MongoDB 7.0+ (running container)

**Build commands**:

```bash
# Compile
mvn clean compile

# Test (if there are tests)
mvn test

# Create Fat JAR
mvn clean package
```

## 📝 Usage Examples

### Faster generation (every 1 second)

```bash
INTERVAL_SECONDS=1 java -jar target/sensor-data-simulator-1.0.0.jar
```

### Using a different MongoDB server

```bash
MONGO_URI=mongodb://user:pass@remote-server:27017 \
java -jar target/sensor-data-simulator-1.0.0.jar
```

## 🔍 Verification

Check the data in **Mongo Express**:

- URL: http://localhost:8081
- Database: `omnivise_iot`
- Collection: `sensor_readings`

Or with **MongoDB shell**:

```bash
docker exec -it omnivise-mongodb mongosh -u admin -p admin123

use omnivise_iot
db.sensor_readings.find().sort({timestamp: -1}).limit(10)
```

## 🐛 Troubleshooting

**MongoDB connection error**:

- Check if MongoDB container is running: `docker ps`
- View MongoDB logs: `docker logs omnivise-mongodb`

**Permission denied**:

- Make Maven wrapper executable: `chmod +x mvnw`

---

**Made with ❤️ for OmniVise IoT**
