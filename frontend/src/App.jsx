import {
  Activity,
  Droplets,
  Gauge,
  Lightbulb,
  Thermometer,
} from "lucide-react";
import { useEffect, useState } from "react";

function App() {
  // WebSocket connection state
  const [isConnected, setIsConnected] = useState(false);
  // Sensor data from WebSocket
  const [sensorData, setSensorData] = useState([]);

  // Latest values for each sensor type
  const [latestValues, setLatestValues] = useState({
    temperature: "--",
    humidity: "--",
    light: "--",
    pressure: "--",
  });

  useEffect(() => {
    // WebSocket URL (backend)
    const wsUrl = "ws://localhost:8080/ws/sensors";
    const ws = new WebSocket(wsUrl);

    // When connection opens
    ws.onopen = () => {
      console.log("WebSocket connected");
      setIsConnected(true);
    };

    // When a message is received
    ws.onmessage = (event) => {
      try {
        // Parse JSON string to JavaScript object
        const reading = JSON.parse(event.data);
        console.log("📨 Sensor data received:", reading);

        // Add to sensor data array (keep last 50)
        setSensorData((prevData) => {
          const newData = [reading, ...prevData]; // Add to beginning
          return newData.slice(0, 50); // Keep only 50 latest
        });

        // Update latest values for sensor cards
        if (reading.type === "temperature") {
          setLatestValues((prev) => ({ ...prev, temperature: reading.value }));
        } else if (reading.type === "humidity") {
          setLatestValues((prev) => ({ ...prev, humidity: reading.value }));
        } else if (reading.type === "light") {
          setLatestValues((prev) => ({ ...prev, light: reading.value }));
        } else if (reading.type === "pressure") {
          setLatestValues((prev) => ({ ...prev, pressure: reading.value }));
        }
      } catch (error) {
        console.error("Failed to parse sensor data:", error);
      }
    };

    // When connection closes
    ws.onclose = () => {
      console.log("WebSocket disconnected");
      setIsConnected(false);
    };

    // When an error occurs
    ws.onerror = (error) => {
      console.error("WebSocket error:", error);
      setIsConnected(false);
    };

    // Cleanup: close WebSocket when component unmounts
    return () => {
      ws.close();
    };
  }, []);

  return (
    <div className="min-h-screen bg-gray-100">
      {/* Header */}
      <header className="bg-white shadow">
        <div className="max-w-7xl mx-auto py-6 px-4 sm:px-6 lg:px-8">
          <div className="flex items-center justify-between">
            <h1 className="text-3xl font-bold text-gray-900 flex items-center gap-2">
              <Activity className="w-8 h-8 text-blue-600" />
              OmniVise IoT Dashboard
            </h1>
            <div className="flex items-center gap-2">
              <div
                className={`w-3 h-3 rounded-full ${isConnected ? "bg-green-500" : "bg-red-500"}`}
              ></div>
              <span className="text-sm text-gray-600">
                {isConnected ? "Connected" : "Disconnected"}
              </span>
            </div>
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="max-w-7xl mx-auto py-6 sm:px-6 lg:px-8">
        <div className="px-4 py-6 sm:px-0">
          {/* Sensor Grid */}
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
            <SensorCard
              icon={<Thermometer className="w-6 h-6" />}
              title="Temperature"
              value={latestValues.temperature}
              unit="°C"
              color="text-orange-600"
            />
            <SensorCard
              icon={<Droplets className="w-6 h-6" />}
              title="Humidity"
              value={latestValues.humidity}
              unit="%"
              color="text-blue-600"
            />
            <SensorCard
              icon={<Lightbulb className="w-6 h-6" />}
              title="Light"
              value={latestValues.light}
              unit="lux"
              color="text-yellow-600"
            />
            <SensorCard
              icon={<Gauge className="w-6 h-6" />}
              title="Pressure"
              value={latestValues.pressure}
              unit="hPa"
              color="text-purple-600"
            />
          </div>

          {/* Data Table */}
          <div className="bg-white shadow rounded-lg p-6">
            <h2 className="text-xl font-semibold mb-4">
              Recent Sensor Readings
            </h2>
            {sensorData.length === 0 ? (
              <p className="text-gray-500 text-center py-8">
                No sensor data yet. Connect to WebSocket to receive real-time
                updates.
              </p>
            ) : (
              <div className="overflow-x-auto">
                <table className="min-w-full divide-y divide-gray-200">
                  <thead className="bg-gray-50">
                    <tr>
                      <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                        Sensor ID
                      </th>
                      <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                        Type
                      </th>
                      <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                        Value
                      </th>
                      <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                        Location
                      </th>
                      <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                        Timestamp
                      </th>
                    </tr>
                  </thead>
                  <tbody className="bg-white divide-y divide-gray-200">
                    {sensorData.map((reading, index) => (
                      <tr key={index}>
                        <td className="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900">
                          {reading.sensorId}
                        </td>
                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                          {reading.type}
                        </td>
                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                          {reading.value} {reading.unit}
                        </td>
                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                          {reading.location}
                        </td>
                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                          {reading.timestamp}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </div>
      </main>
    </div>
  );
}

// Sensor Card Component
function SensorCard({ icon, title, value, unit, color }) {
  return (
    <div className="bg-white shadow rounded-lg p-6">
      <div className="flex items-center justify-between mb-2">
        <div className={color}>{icon}</div>
        <span className="text-2xl font-bold">{value}</span>
      </div>
      <p className="text-gray-600 text-sm">{title}</p>
      <p className="text-gray-400 text-xs">{unit}</p>
    </div>
  );
}

export default App;
