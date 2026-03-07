package com.omnivise.handler;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Consumer;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.omnivise.model.SensorReading;

import io.javalin.websocket.WsConfig;
import io.javalin.websocket.WsContext;

/**
 * WebSocketHandler manages WebSocket connections for real-time sensor data
 * updates.
 * It allows clients to subscribe to updates and broadcasts new sensor readings
 * to all connected clients.
 */
public class WebSocketHandler {
    // Store WebSocket connections: Context -> Session ID
    private final Map<WsContext, String> clients = new ConcurrentHashMap<>();
    // Generate unique session IDs for logging
    private final AtomicInteger sessionCounter = new AtomicInteger(0);
    // JSON serializer for WebSocket messages
    private final ObjectMapper objectMapper = new ObjectMapper();

    /**
     * Configures WebSocket endpoint handlers.
     * 
     * @return Consumer that configures WsConfig with all handlers.
     */
    public Consumer<WsConfig> getWebSocketConfig() {
        return ws -> {
            ws.onConnect(this::onConnect);
            ws.onClose(this::onClose);
            ws.onError(ctx -> {
                String sessionId = clients.get(ctx);
                System.err.println("⚠️ WebSocket error: " + sessionId);
                if (ctx.error() != null) {
                    ctx.error().printStackTrace();
                }
            });
        };
    }

    private void onConnect(WsContext ctx) {
        String sessionId = "ws-" + sessionCounter.incrementAndGet();
        clients.put(ctx, sessionId);
        System.out.println("🔗 WebSocket connected: " + sessionId + " (Total: " + clients.size() + ")");
    }

    private void onClose(WsContext ctx) {
        String sessionId = clients.remove(ctx);
        System.out.println("❌ WebSocket disconnected: " + sessionId + " (Total: " + clients.size() + ")");
    }

    public void broadcast(SensorReading reading) {
        if (clients.isEmpty()) {
            return;
        }

        try {
            // Serialize SensorReading to JSON
            String jsonMessage = objectMapper.writeValueAsString(reading);

            clients.forEach((ctx, sessionId) -> {
                try {
                    ctx.send(jsonMessage);
                } catch (Exception e) {
                    System.err.println("⚠️ Failed to send WebSocket message to " + sessionId);
                    e.printStackTrace();
                }
            });
        } catch (Exception e) {
            System.err.println("⚠️ Failed to serialize SensorReading to JSON: " + e.getMessage());
            e.printStackTrace();
        }
    }

    public int getClientCount() {
        return clients.size();
    }

}
