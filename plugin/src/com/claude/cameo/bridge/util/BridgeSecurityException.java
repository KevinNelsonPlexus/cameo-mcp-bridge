package com.claude.cameo.bridge.util;

import java.io.IOException;

/**
 * Raised when the bridge cannot establish its install-time TLS + bearer-token
 * security and insecure operation has not been explicitly authorized.
 *
 * <p>This is deliberately fatal: the bridge must never silently downgrade to
 * plaintext, because doing so would let any local client -- including ones
 * that never ran {@code install.sh} and hold no shared secret -- drive the
 * open MagicDraw project.
 */
public class BridgeSecurityException extends IOException {

    private static final long serialVersionUID = 1L;

    public BridgeSecurityException(String message) {
        super(message);
    }

    public BridgeSecurityException(String message, Throwable cause) {
        super(message, cause);
    }
}
