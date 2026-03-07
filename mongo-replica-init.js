// mongo-replica-init.js
// Initializes MongoDB as a single-node replica set for Change Stream support

try {
  // Check if replica set is already initialized
  const rsStatus = rs.status();
  print("✅ Replica set already initialized:", rsStatus.set);
} catch (error) {
  // Replica set not initialized yet, let's initialize it
  print("🔧 Initializing single-node replica set...");

  const config = {
    _id: "rs0",
    members: [{ _id: 0, host: "localhost:27017" }],
  };

  rs.initiate(config);

  print("✅ Replica set initialized successfully!");
  print("   Name: rs0");
  print("   Primary: localhost:27017");
}
