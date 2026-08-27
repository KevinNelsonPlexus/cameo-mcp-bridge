package com.claude.cameo.bridge;

import com.claude.cameo.bridge.handlers.ContainmentTreeHandler;
import com.claude.cameo.bridge.handlers.AdvancedCapabilityHandler;
import com.claude.cameo.bridge.handlers.CriteriaHandler;
import com.claude.cameo.bridge.handlers.DataHubHandler;
import com.claude.cameo.bridge.handlers.DiagramHandler;
import com.claude.cameo.bridge.handlers.ElementMutationHandler;
import com.claude.cameo.bridge.handlers.ElementQueryHandler;
import com.claude.cameo.bridge.handlers.ExtensionProbeHandler;
import com.claude.cameo.bridge.handlers.GenericTableHandler;
import com.claude.cameo.bridge.handlers.ImportExportHandler;
import com.claude.cameo.bridge.handlers.MacroHandler;
import com.claude.cameo.bridge.handlers.MatrixHandler;
import com.claude.cameo.bridge.handlers.ProfileHandler;
import com.claude.cameo.bridge.handlers.ProjectHandler;
import com.claude.cameo.bridge.handlers.PropertyDumpHandler;
import com.claude.cameo.bridge.handlers.RelationMapHandler;
import com.claude.cameo.bridge.handlers.RelationshipHandler;
import com.claude.cameo.bridge.handlers.ReportWizardHandler;
import com.claude.cameo.bridge.handlers.ScriptProbeHandler;
import com.claude.cameo.bridge.handlers.SimulationHandler;
import com.claude.cameo.bridge.handlers.SnapshotHandler;
import com.claude.cameo.bridge.handlers.SpecificationHandler;
import com.claude.cameo.bridge.handlers.TeamworkHandler;
import com.claude.cameo.bridge.handlers.TypedDiagramHandler;
import com.claude.cameo.bridge.handlers.UiStateHandler;
import com.claude.cameo.bridge.handlers.ValidationHandler;
import com.claude.cameo.bridge.handlers.VariantHandler;
import com.claude.cameo.bridge.util.BridgeCapabilities;
import com.claude.cameo.bridge.util.BridgeSecurity;
import com.nomagic.magicdraw.core.Application;
import com.nomagic.magicdraw.core.Project;
import com.nomagic.magicdraw.openapi.uml.SessionManager;
import com.sun.net.httpserver.Filter;
import com.sun.net.httpserver.HttpContext;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsServer;
import com.sun.net.httpserver.HttpExchange;
import com.google.gson.JsonObject;
import javax.swing.SwingUtilities;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executors;
import java.util.logging.Level;
import java.util.logging.Logger;

public class HttpBridgeServer {

    private static final Logger LOG = Logger.getLogger(HttpBridgeServer.class.getName());
    private final HttpServer server;
    private final BridgeSecurity security;
    private final Filter authFilter;

    public HttpBridgeServer(int port) throws IOException {
        security = BridgeSecurity.load();

        if (security.isSecure()) {
            HttpsServer httpsServer = HttpsServer.create(new InetSocketAddress("0.0.0.0", port), 0);
            httpsServer.setHttpsConfigurator(new HttpsConfigurator(security.sslContext()));
            server = httpsServer;
            LOG.info("CameoMCPBridge: TLS + bearer-token authentication enabled");
        } else {
            server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        }

        authFilter = new Filter() {
            @Override
            public String description() {
                return "CameoMCPBridge bearer-token authentication";
            }

            @Override
            public void doFilter(HttpExchange exchange, Chain chain) throws IOException {
                if (!security.isSecure() || "OPTIONS".equals(exchange.getRequestMethod())) {
                    chain.doFilter(exchange);
                    return;
                }
                String header = exchange.getRequestHeaders().getFirst("Authorization");
                if (!security.isValidAuthorizationHeader(header)) {
                    sendError(exchange, 401, "UNAUTHORIZED",
                            "Missing or invalid bearer token. Re-run install.sh, "
                                    + "or ensure CAMEO_BRIDGE_TOKEN is set for the MCP server.");
                    return;
                }
                chain.doFilter(exchange);
            }
        };

        server.setExecutor(Executors.newFixedThreadPool(4));
        registerHandlers();
    }

    /** Creates a context and attaches the bearer-token auth filter to it. */
    private HttpContext secureContext(String path, HttpHandler handler) {
        HttpContext context = server.createContext(path, handler);
        context.getFilters().add(authFilter);
        return context;
    }

    private void registerHandlers() {
        secureContext("/status", this::handleStatus);
        secureContext("/capabilities", this::handleCapabilities);
        secureContext("/api/v1/status", this::handleStatus);
        secureContext("/api/v1/capabilities", this::handleCapabilities);
        secureContext("/api/v1/project", new ProjectHandler());
        secureContext("/api/v1/ui", new UiStateHandler());
        secureContext("/api/v1/inspect/diagrams", new PropertyDumpHandler());
        secureContext("/api/v1/containment-tree", new ContainmentTreeHandler());
        secureContext("/api/v1/containment-tree/children", new ContainmentTreeHandler());

        // Route /elements by HTTP method and sub-path
        ElementQueryHandler queryHandler = new ElementQueryHandler();
        ElementMutationHandler mutationHandler = new ElementMutationHandler();
        SpecificationHandler specificationHandler = new SpecificationHandler();
        secureContext("/api/v1/elements/interface-flow-properties", queryHandler);
        secureContext("/api/v1/elements", exchange -> {
            String path = exchange.getRequestURI().getPath();
            // Route /specification sub-paths to SpecificationHandler (GET and PUT)
            if (path.contains("/specification")) {
                specificationHandler.handle(exchange);
            } else if ("GET".equals(exchange.getRequestMethod())) {
                queryHandler.handle(exchange);
            } else {
                mutationHandler.handle(exchange);
            }
        });

        secureContext("/api/v1/relationships", new RelationshipHandler());
        secureContext("/api/v1/diagrams", new DiagramHandler());
        secureContext("/api/v1/relation-maps", new RelationMapHandler());
        secureContext("/api/v1/snapshots", new SnapshotHandler());
        secureContext("/api/v1/probes", new ScriptProbeHandler());
        secureContext("/api/v1/validation", new ValidationHandler());
        secureContext("/api/v1/matrices", new MatrixHandler());
        secureContext("/api/v1/generic-tables", new GenericTableHandler());
        AdvancedCapabilityHandler advancedCapabilityHandler = new AdvancedCapabilityHandler();
        secureContext("/api/v1/reports", new ReportWizardHandler());
        secureContext("/api/v1/import-export", new ImportExportHandler());
        secureContext("/api/v1/criteria", new CriteriaHandler());
        secureContext("/api/v1/profiles", new ProfileHandler());
        secureContext("/api/v1/typed-diagrams", new TypedDiagramHandler());
        secureContext("/api/v1/requirements", advancedCapabilityHandler);
        secureContext("/api/v1/simulation", new SimulationHandler());
        secureContext("/api/v1/teamwork", new TeamworkHandler());
        secureContext("/api/v1/datahub", new DataHubHandler());
        secureContext("/api/v1/variants", new VariantHandler());
        secureContext("/api/v1/extensions", new ExtensionProbeHandler());
        secureContext("/api/v1/macros", new MacroHandler());
        secureContext("/api/v1/session/reset", this::handleSessionReset);
    }

    public void start() {
        server.start();
    }

    public boolean isSecure() {
        return security.isSecure();
    }

    public void stop() {
        server.stop(2);
    }

    private void handleStatus(HttpExchange exchange) throws IOException {
        if (!allowGetOrOptions(exchange, "GET")) {
            return;
        }

        JsonObject response = BridgeCapabilities.buildStatus(server.getAddress().getPort());
        sendJson(exchange, 200, response);
    }

    private void handleCapabilities(HttpExchange exchange) throws IOException {
        if (!allowGetOrOptions(exchange, "GET")) {
            return;
        }

        JsonObject response = BridgeCapabilities.buildCapabilities(server.getAddress().getPort());
        sendJson(exchange, 200, response);
    }

    private boolean allowGetOrOptions(HttpExchange exchange, String allowedMethod) throws IOException {
        if ("OPTIONS".equals(exchange.getRequestMethod())) {
            exchange.getResponseHeaders().set("Access-Control-Allow-Methods", allowedMethod + ", OPTIONS");
            exchange.getResponseHeaders().set("Access-Control-Allow-Headers", "Content-Type");
            exchange.sendResponseHeaders(204, -1);
            return false;
        }
        if (!allowedMethod.equals(exchange.getRequestMethod())) {
            sendError(exchange, 405, "METHOD_NOT_ALLOWED", "Only " + allowedMethod + " is supported");
            return false;
        }
        return true;
    }

    /**
     * POST /api/v1/session/reset - Force-close any stuck SessionManager session.
     *
     * When a macro crashes mid-session, all subsequent API calls that create
     * sessions will fail with "Session is already created". This endpoint
     * cancels (or closes) the dangling session so work can continue without
     * restarting Cameo.
     *
     * Runs on the Swing EDT because SessionManager operations must execute on
     * the same thread that created the session.
     */
    private void handleSessionReset(HttpExchange exchange) throws IOException {
        if (!"POST".equals(exchange.getRequestMethod())) {
            sendError(exchange, 405, "METHOD_NOT_ALLOWED", "Only POST is supported");
            return;
        }

        Project project = Application.getInstance().getProject();
        if (project == null) {
            sendError(exchange, 400, "NO_PROJECT", "No project is open in Cameo");
            return;
        }

        try {
            CompletableFuture<JsonObject> future = new CompletableFuture<>();

            SwingUtilities.invokeLater(() -> {
                SessionManager sm = SessionManager.getInstance();
                JsonObject response = new JsonObject();

                if (!sm.isSessionCreated(project)) {
                    response.addProperty("reset", false);
                    response.addProperty("message", "No active session");
                    future.complete(response);
                    return;
                }

                // Try cancel first (rolls back partial changes), fall back to close
                try {
                    sm.cancelSession(project);
                    response.addProperty("reset", true);
                    future.complete(response);
                } catch (Exception cancelEx) {
                    LOG.log(Level.WARNING, "cancelSession failed, trying closeSession", cancelEx);
                    try {
                        sm.closeSession(project);
                        response.addProperty("reset", true);
                        future.complete(response);
                    } catch (Exception closeEx) {
                        LOG.log(Level.SEVERE, "closeSession also failed", closeEx);
                        future.completeExceptionally(new RuntimeException(
                                "cancelSession failed: " + cancelEx.getMessage()
                                        + "; closeSession failed: " + closeEx.getMessage()));
                    }
                }
            });

            JsonObject result = future.get(30, java.util.concurrent.TimeUnit.SECONDS);
            sendJson(exchange, 200, result);
        } catch (Exception e) {
            sendError(exchange, 500, "SESSION_RESET_FAILED", e.getMessage());
        }
    }

    public static void sendJson(HttpExchange exchange, int status, JsonObject json) throws IOException {
        byte[] bytes = json.toString().getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    public static void sendError(HttpExchange exchange, int status, String code, String message) throws IOException {
        JsonObject error = new JsonObject();
        error.addProperty("error", true);
        error.addProperty("code", code);
        error.addProperty("message", message);
        sendJson(exchange, status, error);
    }
}
