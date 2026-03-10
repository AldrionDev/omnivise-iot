/**
 * SensorCard Component
 * 
 * Displays a single sensor metric in a card format.
 * 
 * Props:
 * - icon: React element (e.g., <Thermometer />)
 * - title: Sensor type name (e.g., "Temperature")
 * - value: Current sensor value (e.g., 22.5 or "--")
 * - unit: Unit of measurement (e.g., "°C", "%", "lux", "hPa")
 * - color: Tailwind color class for icon (e.g., "text-red-500")
 */
const SensorCard = ({ icon, title, value, unit, color }) => {
  return (
    <div className="bg-white rounded-lg shadow p-6">
      <div className="flex items-center justify-between">
        <div>
          <p className="text-gray-500 text-sm">{title}</p>
          <p className="text-2xl font-bold text-gray-900">
            {value}{unit}
          </p>
        </div>
        <div className={color}>{icon}</div>
      </div>
    </div>
  );
};

export default SensorCard;