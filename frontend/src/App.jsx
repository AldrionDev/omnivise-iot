import { useState, useEffect } from 'react';
import { Activity, Thermometer, Droplets, Lightbulb, Gauge } from 'lucide-react';

function App() {
  const [isConnected, setIsConnected] = useState(false);
  const [sensorData, setSensorData] = useState([]);

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
              <div className={`w-3 h-3 rounded-full ${isConnected ? 'bg-green-500' : 'bg-red-500'}`}></div>
              <span className="text-sm text-gray-600">
                {isConnected ? 'Connected' : 'Disconnected'}
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
              value="--"
              unit="°C"
              color="text-orange-600"
            />
            <SensorCard
              icon={<Droplets className="w-6 h-6" />}
              title="Humidity"
              value="--"
              unit="%"
              color="text-blue-600"
            />
            <SensorCard
              icon={<Lightbulb className="w-6 h-6" />}
              title="Light"
              value="--"
              unit="lux"
              color="text-yellow-600"
            />
            <SensorCard
              icon={<Gauge className="w-6 h-6" />}
              title="Pressure"
              value="--"
              unit="hPa"
              color="text-purple-600"
            />
          </div>

          {/* Data Table */}
          <div className="bg-white shadow rounded-lg p-6">
            <h2 className="text-xl font-semibold mb-4">Recent Sensor Readings</h2>
            {sensorData.length === 0 ? (
              <p className="text-gray-500 text-center py-8">
                No sensor data yet. Connect to WebSocket to receive real-time updates.
              </p>
            ) : (
              <div className="overflow-x-auto">
                <table className="min-w-full divide-y divide-gray-200">
                  <thead className="bg-gray-50">
                    <tr>
                      <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Sensor ID</th>
                      <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Type</th>
                      <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Value</th>
                      <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Location</th>
                      <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Timestamp</th>
                    </tr>
                  </thead>
                  <tbody className="bg-white divide-y divide-gray-200">
                    {sensorData.map((reading, index) => (
                      <tr key={index}>
                        <td className="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900">{reading.sensorId}</td>
                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">{reading.type}</td>
                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">{reading.value} {reading.unit}</td>
                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">{reading.location}</td>
                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">{reading.timestamp}</td>
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
