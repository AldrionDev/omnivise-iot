package com.omnivise.model;

import java.util.List;

/**
 * A device in the seeded, read-only server-room registry (issue #70).
 *
 * <p>Readings reference a device by {@link #deviceId()} and one of its declared
 * {@link Channel#channel()} names; {@link Channel#unit()} is the unit that
 * channel reports in.
 */
public record Device(
        String deviceId,
        String name,
        String kind,
        String location,
        List<Channel> channels
) {
    public record Channel(String channel, String unit) {
    }
}
