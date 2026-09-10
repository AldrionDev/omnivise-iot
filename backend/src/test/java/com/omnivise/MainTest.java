package com.omnivise;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

/**
 * Unit tests for {@link Main#resolveMongoUri}.
 *
 * <p>An explicit non-empty {@code MONGO_URI} is authoritative. When it is absent
 * or empty, the legacy host/port/user/password URI construction is used, and
 * authentication is only added when both a username and a password are present.
 */
class MainTest {

    @Test
    void explicitMongoUriTakesPrecedenceOverLegacyFields() {
        assertEquals(
                "mongodb://mongodb:27017/?replicaSet=rs0",
                Main.resolveMongoUri(
                        "mongodb://mongodb:27017/?replicaSet=rs0",
                        "legacy-host",
                        "27018",
                        "legacy-user",
                        "legacy-password"));
    }

    @Test
    void userAndPasswordProduceAuthenticatedLegacyUri() {
        assertEquals(
                "mongodb://legacy-user:legacy-password@mongo-host:27019/?directConnection=true",
                Main.resolveMongoUri(
                        "",
                        "mongo-host",
                        "27019",
                        "legacy-user",
                        "legacy-password"));
    }

    @Test
    void hostOnlyConfigurationProducesUnauthenticatedLegacyUri() {
        assertEquals(
                "mongodb://localhost:27017",
                Main.resolveMongoUri(
                        null,
                        "localhost",
                        "27017",
                        null,
                        null));
    }

    @Test
    void emptyMongoUriFallsBackToUnauthenticatedLegacyUri() {
        assertEquals(
                "mongodb://mongo-host:27019",
                Main.resolveMongoUri(
                        "",
                        "mongo-host",
                        "27019",
                        null,
                        null));
    }

    @Test
    void incompleteLegacyCredentialsFallBackToUnauthenticatedLegacyUri() {
        assertEquals(
                "mongodb://mongo-host:27019",
                Main.resolveMongoUri(
                        null,
                        "mongo-host",
                        "27019",
                        "legacy-user",
                        ""));
    }

    @Test
    void clampLimitKeepsAnInRangeValueUnchanged() {
        assertEquals(50, Main.clampLimit(50));
    }

    @Test
    void clampLimitRaisesANonPositiveValueToOne() {
        assertEquals(1, Main.clampLimit(0));
        assertEquals(1, Main.clampLimit(-10));
    }

    @Test
    void clampLimitCapsAnExcessiveValueAtFiveHundred() {
        assertEquals(500, Main.clampLimit(10_000));
    }
}
