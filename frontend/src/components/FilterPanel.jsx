/**
 * FilterPanel Component
 *
 * Provides search and filtering controls for sensor data.
 *
 * Props:
 * - searchTerm: Current search text
 * - onSearchChange: Callback when search input changes
 * - typeFilter: Currently selected sensor type filter
 * - onTypeChange: Callback when type filter changes
 * - locationFilter: Currently selected location filter
 * - onLocationChange: Callback when location filter changes
 * - onClearFilters: Callback when clear button is clicked
 */
const FilterPanel = ({
  searchTerm,
  onSearchChange,
  typeFilter,
  onTypeChange,
  locationFilter,
  onLocationChange,
  onClearFilters,
}) => {
  return (
    <div className="bg-white rounded-lg shadow p-6 mb-6">
      <div className="flex flex-col md:flex-row gap-4">
        {/* Search Input */}
        <div className="flex-1">
          <label
            htmlFor="search"
            className="block text-sm font-medium text-gray-700 mb-2"
          >
            Search
          </label>
          <input
            id="search"
            type="text"
            placeholder="Search by sensor ID or location..."
            value={searchTerm}
            onChange={(e) => onSearchChange(e.target.value)}
            className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          />
        </div>

        {/* Type Filter Dropdown */}
        <div className="flex-1">
          <label
            htmlFor="typeFilter"
            className="block text-sm font-medium text-gray-700 mb-2"
          >
            Sensor Type
          </label>
          <select
            id="typeFilter"
            value={typeFilter}
            onChange={(e) => onTypeChange(e.target.value)}
            className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          >
            <option value="all">All Types</option>
            <option value="temperature">Temperature</option>
            <option value="humidity">Humidity</option>
            <option value="light">Light</option>
            <option value="pressure">Pressure</option>
          </select>
        </div>

        {/* Location Filter Dropdown */}
        <div className="flex-1">
          <label
            htmlFor="locationFilter"
            className="block text-sm font-medium text-gray-700 mb-2"
          >
            Location
          </label>
          <select
            id="locationFilter"
            value={locationFilter}
            onChange={(e) => onLocationChange(e.target.value)}
            className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          >
            <option value="all">All Locations</option>
            <option value="Office Room 1">Office Room 1</option>
            <option value="Office Room 2">Office Room 2</option>
            <option value="Meeting Room">Meeting Room</option>
            <option value="Entrance">Entrance</option>
            <option value="Lobby">Lobby</option>
            <option value="Server Room">Server Room</option>
          </select>
        </div>

        {/* Clear Filters Button */}
        <div className="flex items-end">
          <button
            onClick={onClearFilters}
            className="px-6 py-2 bg-gray-600 text-white rounded-lg hover:bg-gray-700 transition-colors"
          >
            Clear Filters
          </button>
        </div>
      </div>
    </div>
  );
};

export default FilterPanel;
