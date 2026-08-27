package com.claude.cameo.bridge.util;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * Loads the install-time-generated TLS keystore and bearer-token secret used
 * to secure the HTTP bridge between the Java plugin and the Python MCP
 * server.
 *
 * <p>{@code install.sh} generates a random secret, uses it as the password
 * protecting a self-signed TLS keystore, and writes both the keystore and the
 * secret under {@code ~/.cameo-mcp-bridge}. Only this plugin reads that
 * directory -- the Python client instead receives the same secret (as a
 * bearer token) and the server's public certificate through its own
 * environment variables set up by the installer, so neither side reads the
 * other's files.
 *
 * <p>Candidate bridge-home directories are tried in order: an explicit
 * {@code cameo.mcp.bridgeHome} system property override, {@code
 * CAMEO_BRIDGE_HOME} environment variable, the JVM's {@code user.home}, and
 * the {@code HOME} environment variable. The last two can disagree when
 * MagicDraw runs inside a container as a different user than the one that
 * ran {@code install.sh} on the host (e.g. root inside Docker without {@code
 * HOME} pointed at the mounted host home) -- checking both makes discovery
 * resilient to that mismatch.
 *
 * <p>Security is <em>fail-closed</em>. If the material is missing or cannot be
 * loaded, {@link #load()} throws {@link BridgeSecurityException} and the bridge
 * refuses to start, rather than silently downgrading to plaintext. Plaintext
 * operation is only possible when it has been explicitly authorized, via
 * {@code install.sh --allow-insecure} (which writes the {@code allow-insecure}
 * marker file), the {@code cameo.mcp.allowInsecure} system property, or the
 * {@code CAMEO_BRIDGE_ALLOW_INSECURE} environment variable.
 */
public final class BridgeSecurity {

    private static final Logger LOG = Logger.getLogger(BridgeSecurity.class.getName());
    private static final String BRIDGE_DIR_NAME = ".cameo-mcp-bridge";
    private static final String TOKEN_FILE = "token";
    private static final String KEYSTORE_FILE = "server.p12";
    private static final String INSECURE_MARKER_FILE = "allow-insecure";

    private final String bearerToken;
    private final SSLContext sslContext;

    private BridgeSecurity(String bearerToken, SSLContext sslContext) {
        this.bearerToken = bearerToken;
        this.sslContext = sslContext;
    }

    /**
     * Builds the ordered list of bridge-home directories to search for TLS/token
     * material.
     *
     * <p>An explicit override ({@code cameo.mcp.bridgeHome} or {@code
     * CAMEO_BRIDGE_HOME}) is authoritative and suppresses the implicit
     * candidates, so pointing the bridge at a specific home can never silently
     * resolve to a different one. Only when no override is given do we consider
     * both {@code user.home} and {@code HOME}, which can disagree when
     * MagicDraw runs in a container as a different user than the one that ran
     * {@code install.sh} on the host.
     */
    private static List<Path> resolveBridgeHomeCandidates() {
        Set<Path> explicit = new LinkedHashSet<>();

        String override = System.getProperty("cameo.mcp.bridgeHome");
        if (override != null && !override.isBlank()) {
            explicit.add(Paths.get(override));
        }

        String envOverride = System.getenv("CAMEO_BRIDGE_HOME");
        if (envOverride != null && !envOverride.isBlank()) {
            explicit.add(Paths.get(envOverride));
        }

        if (!explicit.isEmpty()) {
            return new ArrayList<>(explicit);
        }

        Set<Path> candidates = new LinkedHashSet<>();

        String userHome = System.getProperty("user.home");
        if (userHome != null && !userHome.isBlank()) {
            candidates.add(Paths.get(userHome, BRIDGE_DIR_NAME));
        }

        String envHome = System.getenv("HOME");
        if (envHome != null && !envHome.isBlank()) {
            candidates.add(Paths.get(envHome, BRIDGE_DIR_NAME));
        }

        if (candidates.isEmpty()) {
            candidates.add(Paths.get(BRIDGE_DIR_NAME));
        }

        return new ArrayList<>(candidates);
    }

    private static boolean hasSecurityMaterial(Path bridgeHome) {
        return Files.isReadable(bridgeHome.resolve(TOKEN_FILE))
                && Files.isReadable(bridgeHome.resolve(KEYSTORE_FILE));
    }

    private static boolean isTruthy(String value) {
        return value != null && ("true".equalsIgnoreCase(value.trim()) || "1".equals(value.trim()));
    }

    /**
     * Whether plaintext, unauthenticated operation has been explicitly authorized.
     *
     * <p>Insecure mode is opt-in only. It is never inferred from missing files,
     * so a broken or partial install fails loudly instead of quietly dropping
     * authentication.
     */
    private static boolean isInsecureExplicitlyAllowed(List<Path> candidates) {
        if (isTruthy(System.getProperty("cameo.mcp.allowInsecure"))
                || isTruthy(System.getenv("CAMEO_BRIDGE_ALLOW_INSECURE"))) {
            return true;
        }
        for (Path candidate : candidates) {
            if (Files.isReadable(candidate.resolve(INSECURE_MARKER_FILE))) {
                return true;
            }
        }
        return false;
    }

    /**
     * Loads the TLS keystore + bearer token generated by {@code install.sh}.
     *
     * @throws BridgeSecurityException if the material is missing or unusable and
     *     insecure operation has not been explicitly authorized.
     */
    public static BridgeSecurity load() throws BridgeSecurityException {
        List<Path> candidates = resolveBridgeHomeCandidates();
        boolean insecureAllowed = isInsecureExplicitlyAllowed(candidates);

        Path bridgeHome = null;
        for (Path candidate : candidates) {
            if (hasSecurityMaterial(candidate)) {
                bridgeHome = candidate;
                break;
            }
        }

        if (bridgeHome == null) {
            if (insecureAllowed) {
                LOG.warning("CameoMCPBridge: no TLS/token material found in " + candidates
                        + " -- starting in INSECURE plaintext mode because insecure operation"
                        + " was explicitly authorized.");
                return new BridgeSecurity(null, null);
            }
            throw new BridgeSecurityException(
                    "No TLS/token material found in " + candidates + ". The bridge refuses to start"
                            + " without TLS and bearer-token authentication. Run install.sh to provision"
                            + " the shared secret, or run install.sh --allow-insecure to explicitly"
                            + " authorize plaintext mode.");
        }

        try {
            String token = new String(Files.readAllBytes(bridgeHome.resolve(TOKEN_FILE)),
                    StandardCharsets.UTF_8).trim();
            if (token.isEmpty()) {
                throw new IOException("token file is empty: " + bridgeHome.resolve(TOKEN_FILE));
            }

            KeyStore keyStore = KeyStore.getInstance("PKCS12");
            try (InputStream in = Files.newInputStream(bridgeHome.resolve(KEYSTORE_FILE))) {
                keyStore.load(in, token.toCharArray());
            }

            KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
            kmf.init(keyStore, token.toCharArray());

            SSLContext context = SSLContext.getInstance("TLS");
            context.init(kmf.getKeyManagers(), null, null);

            LOG.info("CameoMCPBridge: loaded TLS keystore and bearer token from " + bridgeHome);
            return new BridgeSecurity(token, context);
        } catch (IOException | GeneralSecurityException e) {
            if (insecureAllowed) {
                LOG.log(Level.WARNING, "CameoMCPBridge: failed to load TLS/token material from "
                        + bridgeHome + " -- starting in INSECURE plaintext mode because insecure"
                        + " operation was explicitly authorized.", e);
                return new BridgeSecurity(null, null);
            }
            throw new BridgeSecurityException(
                    "Failed to load TLS/token material from " + bridgeHome + ": " + e
                            + ". The bridge refuses to start without TLS and bearer-token"
                            + " authentication. Re-run install.sh to reprovision the shared secret.",
                    e);
        }
    }

    /** Whether TLS + bearer-token enforcement is active. */
    public boolean isSecure() {
        return bearerToken != null && sslContext != null;
    }

    public SSLContext sslContext() {
        return sslContext;
    }

    /**
     * Validates an {@code Authorization} header value against the loaded secret.
     *
     * <p>Returns {@code true} unconditionally in insecure mode, which is only
     * reachable when plaintext operation was explicitly authorized.
     */
    public boolean isValidAuthorizationHeader(String headerValue) {
        if (bearerToken == null) {
            return true; // insecure mode: explicitly authorized, no auth required
        }
        if (headerValue == null || !headerValue.startsWith("Bearer ")) {
            return false;
        }
        String presented = headerValue.substring("Bearer ".length());
        byte[] presentedBytes = presented.getBytes(StandardCharsets.UTF_8);
        byte[] expectedBytes = bearerToken.getBytes(StandardCharsets.UTF_8);
        return MessageDigest.isEqual(presentedBytes, expectedBytes);
    }
}
