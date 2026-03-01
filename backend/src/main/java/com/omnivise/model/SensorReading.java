package com.omnivise.model;

public record SensorReading(
        String sensorId,
        String type,
        Object value,
        String unit,
        String location,
        String timestamp
) {
    // Records automatically generate:
    // -  constructor, 
    // -  getters (sensorId(), type(), value(), unit(), location(), timestamp()), 
    // -  equals(), hashCode(), and toString() methods
}
