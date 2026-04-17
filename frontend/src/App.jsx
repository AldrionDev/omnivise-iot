import {
  Activity,
  Droplets,
  Gauge,
  Lightbulb,
  Thermometer,
} from "lucide-react";
import { useEffect, useState } from "react";
import FilterPanel from "./components/FilterPanel";
import SensorCard from "./components/SensorCard";
import SensorTable from "./components/SensorTable";

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

  const [searchTerm, setSearchTerm] = useState("");
  const [typeFilter, setTypeFilter] = useState("all");
  const [locationFilter, setLocationFilter] = useState("all");

  // Filtered data based on search and filters
  const filteredData = sensorData.filter((reading) => {
    const matchesSearch =
      searchTerm === "" ||
      // Search term filter (sensor ID or location contains the search term)
      reading.sensorId.toLowerCase().includes(searchTerm.toLowerCase()) ||
      reading.location.toLowerCase().includes(searchTerm.toLowerCase());

    // Type filter
    const matchesType = typeFilter === "all" || reading.type === typeFilter;

    // Location filter
    const matchesLocation =
      locationFilter === "all" || reading.location === locationFilter;

    //Include only if All filters match
    return matchesSearch && matchesType && matchesLocation;
  });

  useEffect(() => {
    // WebSocket URL (backend)
    const wsUrl = import.meta.env.VITE_WS_URL || "ws://localhost:8080/ws/sensors";
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

          {/* Filter Panel */}
          <FilterPanel
            searchTerm={searchTerm}
            onSearchChange={setSearchTerm}
            typeFilter={typeFilter}
            onTypeChange={setTypeFilter}
            locationFilter={locationFilter}
            onLocationChange={setLocationFilter}
            onClearFilters={() => {
              setSearchTerm("");
              setTypeFilter("all");
              setLocationFilter("all");
            }}
          />

          {/* Data Table */}
          <SensorTable data={filteredData} hasData={sensorData.length > 0} />
        </div>
      </main>
    </div>
  );
}

export default App;
