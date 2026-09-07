package com.omnivise;

public class MainTest {

    public void testExplicitMongoUriTakesPrecedence() {
        assertEquals(
                "mongodb://mongodb:27017/?replicaSet=rs0",
                Main.resolveMongoUri(
                        "mongodb://mongodb:27017/?replicaSet=rs0",
                        "legacy-host",
                        "27018",
                        "legacy-user",
                        "legacy-password"));
    }

    public void testAbsentMongoUriUsesUnauthenticatedLegacyFallback() {
        assertEquals(
                "mongodb://localhost:27017",
                Main.resolveMongoUri(
                        null,
                        "localhost",
                        "27017",
                        null,
                        null));
    }

    public void testEmptyMongoUriUsesUnauthenticatedLegacyFallback() {
        assertEquals(
                "mongodb://mongo-host:27019",
                Main.resolveMongoUri(
                        "",
                        "mongo-host",
                        "27019",
                        null,
                        null));
    }

    public void testEmptyMongoUriPreservesAuthenticatedLegacyFallback() {
        assertEquals(
                "mongodb://legacy-user:legacy-password@mongo-host:27019/?directConnection=true",
                Main.resolveMongoUri(
                        "",
                        "mongo-host",
                        "27019",
                        "legacy-user",
                        "legacy-password"));
    }

    public void testIncompleteLegacyCredentialsUseUnauthenticatedFallback() {
        assertEquals(
                "mongodb://mongo-host:27019",
                Main.resolveMongoUri(
                        null,
                        "mongo-host",
                        "27019",
                        "legacy-user",
                        ""));
    }

    private static void assertEquals(String expected, String actual) {
        if (!expected.equals(actual)) {
            throw new AssertionError(
                    "expected <" + expected + "> but was <" + actual + ">");
        }
    }
}
