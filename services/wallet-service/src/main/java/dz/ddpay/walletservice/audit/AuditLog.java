package dz.ddpay.walletservice.audit;

import java.util.Map;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

/** Writes to the append-only audit_log, in the same transaction as the change it describes. */
@Component
public class AuditLog {

    private final JdbcClient jdbc;

    public AuditLog(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /** actorType must be one of: user, merchant, admin, system. */
    public void record(String actorType, UUID actorId, String action,
                       String entityType, UUID entityId, Map<String, ?> details) {
        jdbc.sql("""
                INSERT INTO public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
                VALUES (:actorType, :actorId, :action, :entityType, :entityId, CAST(:details AS jsonb))
                """)
            .param("actorType", actorType)
            .param("actorId", actorId)
            .param("action", action)
            .param("entityType", entityType)
            .param("entityId", entityId)
            .param("details", toJson(details))
            .update();
    }

    static String toJson(Map<String, ?> details) {
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<String, ?> e : details.entrySet()) {
            if (!first) sb.append(',');
            first = false;
            sb.append(quote(e.getKey())).append(':');
            Object v = e.getValue();
            if (v == null) sb.append("null");
            else if (v instanceof Boolean || v instanceof Number) sb.append(v);
            else sb.append(quote(String.valueOf(v)));
        }
        return sb.append('}').toString();
    }

    private static String quote(String s) {
        StringBuilder sb = new StringBuilder("\"");
        for (char ch : s.toCharArray()) {
            switch (ch) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                default -> {
                    if (ch < 0x20) sb.append(String.format("\\u%04x", (int) ch));
                    else sb.append(ch);
                }
            }
        }
        return sb.append('"').toString();
    }
}
