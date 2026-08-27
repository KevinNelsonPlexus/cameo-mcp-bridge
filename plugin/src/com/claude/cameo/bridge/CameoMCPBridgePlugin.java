package com.claude.cameo.bridge;

import com.nomagic.magicdraw.plugins.Plugin;
import com.nomagic.magicdraw.core.Application;
import com.claude.cameo.bridge.util.BridgeSecurityException;
import java.util.logging.Logger;

public class CameoMCPBridgePlugin extends Plugin {

    private static final Logger LOG = Logger.getLogger(CameoMCPBridgePlugin.class.getName());
    private HttpBridgeServer server;

    @Override
    public void init() {
        int port = Integer.parseInt(System.getProperty("cameo.mcp.port", "18740"));
        try {
            server = new HttpBridgeServer(port);
            server.start();
            String message = "CameoMCPBridge: HTTP server started on port " + port
                + (server.isSecure() ? " (TLS + bearer-token auth enabled)" : " (INSECURE: plaintext mode explicitly authorized)");
            Application.getInstance().getGUILog().log(message);
            LOG.info(message);
        } catch (BridgeSecurityException e) {
            // Fail closed: never fall back to an unauthenticated bridge.
            String message = "CameoMCPBridge: refusing to start -- " + e.getMessage();
            LOG.severe(message);
            Application.getInstance().getGUILog().showError(message);
        } catch (Exception e) {
            LOG.severe("CameoMCPBridge: Failed to start HTTP server: " + e.getMessage());
            Application.getInstance().getGUILog().showError(
                "CameoMCPBridge: Failed to start HTTP server: " + e.getMessage());
        }
    }

    @Override
    public boolean close() {
        if (server != null) {
            server.stop();
            LOG.info("CameoMCPBridge: HTTP server stopped");
        }
        return true;
    }

    @Override
    public boolean isSupported() {
        return true;
    }
}
