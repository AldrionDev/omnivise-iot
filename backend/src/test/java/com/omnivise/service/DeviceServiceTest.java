package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.Optional;

import org.bson.Document;
import org.junit.jupiter.api.Test;

import com.omnivise.model.Device;

/**
 * In-memory device registry behaviour (issue #70).
 *
 * <p>The registry is seeded and read-only. {@code DeviceService} loads the
 * {@code devices} documents once and answers "all devices" / "one device" from
 * memory. These tests drive the load-and-query behaviour through the
 * package-private {@code List<Document>} seam so no live MongoDB is needed.
 */
class DeviceServiceTest {

    private static Document rackDoc() {
        return new Document()
                .append("deviceId", "rack-a1")
                .append("name", "Rack A1")
                .append("kind", "rack")
                .append("location", "Server Room / Rack A1")
                .append("channels", List.of(
                        new Document().append("channel", "intake_temp").append("unit", "°C"),
                        new Document().append("channel", "door_contact").append("unit", "state")));
    }

    private static Document upsDoc() {
        return new Document()
                .append("deviceId", "ups-1")
                .append("name", "UPS 1")
                .append("kind", "ups")
                .append("location", "Server Room / Power")
                .append("channels", List.of(
                        new Document().append("channel", "load_pct").append("unit", "%")));
    }

    @Test
    void loadsEveryDocumentIntoTheRegistryMappingNestedChannels() {
        DeviceService service = new DeviceService(List.of(rackDoc(), upsDoc()));

        Device rack = service.getDevice("rack-a1").orElseThrow();

        assertEquals("rack-a1", rack.deviceId());
        assertEquals("Rack A1", rack.name());
        assertEquals("rack", rack.kind());
        assertEquals("Server Room / Rack A1", rack.location());
        assertEquals(
                List.of(new Device.Channel("intake_temp", "°C"), new Device.Channel("door_contact", "state")),
                rack.channels());
    }

    @Test
    void returnsAllDevicesInSeedOrder() {
        DeviceService service = new DeviceService(List.of(rackDoc(), upsDoc()));

        List<Device> all = service.getAllDevices();

        assertEquals(List.of("rack-a1", "ups-1"), all.stream().map(Device::deviceId).toList());
    }

    @Test
    void getDeviceReturnsPresentForAKnownId() {
        DeviceService service = new DeviceService(List.of(rackDoc()));

        assertTrue(service.getDevice("rack-a1").isPresent());
    }

    @Test
    void getDeviceReturnsEmptyForAnUnknownId() {
        DeviceService service = new DeviceService(List.of(rackDoc()));

        Optional<Device> found = service.getDevice("no-such-device");

        assertFalse(found.isPresent());
    }

    @Test
    void anEmptyRegistryHasNoDevices() {
        DeviceService service = new DeviceService(List.of());

        assertTrue(service.getAllDevices().isEmpty());
        assertFalse(service.getDevice("rack-a1").isPresent());
    }

    // ------------------------------------------------------------------
    // Unit resolution for the history endpoint (issue #72)
    // ------------------------------------------------------------------

    @Test
    void findChannelUnitReturnsTheRegisteredUnitForAKnownDeviceAndChannel() {
        DeviceService service = new DeviceService(List.of(rackDoc(), upsDoc()));

        assertEquals(Optional.of("°C"), service.findChannelUnit("rack-a1", "intake_temp"));
        assertEquals(Optional.of("state"), service.findChannelUnit("rack-a1", "door_contact"));
        assertEquals(Optional.of("%"), service.findChannelUnit("ups-1", "load_pct"));
    }

    @Test
    void findChannelUnitReturnsEmptyForAKnownDeviceButUnknownChannel() {
        DeviceService service = new DeviceService(List.of(rackDoc()));

        assertEquals(Optional.empty(), service.findChannelUnit("rack-a1", "no_such_channel"));
    }

    @Test
    void findChannelUnitReturnsEmptyForAnUnknownDevice() {
        DeviceService service = new DeviceService(List.of(rackDoc()));

        assertEquals(Optional.empty(), service.findChannelUnit("no-such-device", "intake_temp"));
    }
}
