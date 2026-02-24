// MongoDB inicializáló script
// this automatically run once the MongoDB conteiner runs

print("🚀 MongoDB inicializálás kezdése...");

// Váltás az omnivise_iot adatbázisra (ha nem létezik, létrehozza)
db = db.getSiblingDB("omnivise_iot");

print("📦 Adatbázis létrehozva: omnivise_iot");

// Create Collection (collection) 
db.createCollection("sensor_readings");

print("📋 Gyűjtemény létrehozva: sensor_readings");

// Create an index on the timestamp field (for faster queries)
db.sensor_readings.createIndex({ timestamp: -1 });

print("🔍 Index létrehozva: timestamp");

// Insert initial test data
const testData = [
  {
    sensor_id: "sensor_001",
    type: "temperature",
    value: 22.5,
    unit: "°C",
    location: "Office Room 1",
    timestamp: new Date("2026-02-24T08:00:00Z"),
  },
  {
    sensor_id: "sensor_002",
    type: "humidity",
    value: 65.2,
    unit: "%",
    location: "Office Room 1",
    timestamp: new Date("2026-02-24T08:05:00Z"),
  },
  {
    sensor_id: "sensor_003",
    type: "temperature",
    value: 21.8,
    unit: "°C",
    location: "Server Room",
    timestamp: new Date("2026-02-24T08:10:00Z"),
  },
  {
    sensor_id: "sensor_004",
    type: "motion",
    value: true,
    unit: "boolean",
    location: "Entrance",
    timestamp: new Date("2026-02-24T08:15:00Z"),
  },
  {
    sensor_id: "sensor_005",
    type: "light",
    value: 450,
    unit: "lux",
    location: "Office Room 2",
    timestamp: new Date("2026-02-24T08:20:00Z"),
  },
];

db.sensor_readings.insertMany(testData);

print("✅ " + testData.length + " test data inserted!");

// Check: how many documents are in the collection
const count = db.sensor_readings.countDocuments();
print(
  "📊 All " +
    count +
    " document is located in the sensor_readings collection.",
);

print("🎉 MongoDB initialization complete!");
