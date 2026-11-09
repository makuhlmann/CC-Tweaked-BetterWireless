// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.core.apis;

import dan200.computercraft.api.lua.ILuaAPI;
import dan200.computercraft.api.lua.LuaException;
import dan200.computercraft.api.lua.LuaFunction;
import dan200.computercraft.core.crypto.Crypto;
import org.jspecify.annotations.Nullable;

import java.nio.ByteBuffer;
import java.security.InvalidKeyException;
import java.util.Optional;

/**
 * Cryptography: random numbers, hashes, key derivation, key exchange, signatures and authenticated encryption.
 * <p>
 * Everything works on strings of bytes. Keys, hashes and shared secrets are 32 bytes long, and signatures 64. To print
 * them, convert them to hex with something like {@code (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end))}.
 * <p>
 * Keys created with this API are ordinary strings, so any program on the computer can read them. To keep a key where
 * programs can use it but never read it, use the {@code enclave} API.
 *
 * @cc.module crypto
 */
public class CryptoAPI implements ILuaAPI {
    /** The longest string any function accepts, in bytes. */
    public static final int MAX_DATA = 1 << 20;

    /** The most PBKDF2 iterations we allow, to bound how long one call can take. */
    public static final int MAX_PBKDF2_ITERATIONS = 100_000;

    /** The longest key PBKDF2 can derive, in bytes. */
    public static final int MAX_PBKDF2_LENGTH = 256;

    @Override
    public String[] getNames() {
        return new String[]{ "crypto" };
    }

    /**
     * Generate cryptographically secure random bytes, suitable for keys and nonces.
     *
     * @param length The number of bytes to generate.
     * @return The random bytes.
     * @throws LuaException If the length is negative or too long.
     * @cc.treturn string The random bytes.
     */
    @LuaFunction
    public final byte[] random(int length) throws LuaException {
        if (length < 0 || length > MAX_DATA) throw new LuaException("Length must be between 0 and " + MAX_DATA);
        return Crypto.random(length);
    }

    /**
     * Compute the SHA-256 hash of a string.
     *
     * @param data The data to hash.
     * @return The hash.
     * @throws LuaException If the data is too long.
     * @cc.treturn string The 32-byte hash.
     * @cc.usage Hash a string.
     * <pre>{@code
     * local hash = crypto.sha256("Hello, world!")
     * print((hash:gsub(".", function(c) return ("%02x"):format(c:byte()) end)))
     * }</pre>
     */
    @LuaFunction
    public final byte[] sha256(ByteBuffer data) throws LuaException {
        return Crypto.sha256(bytes(data, "data"));
    }

    /**
     * Compute the HMAC-SHA256 of a string: a hash which can only be computed, or checked, by someone with the key.
     *
     * @param key  The key.
     * @param data The data to authenticate.
     * @return The HMAC.
     * @throws LuaException If the key or data are too long.
     * @cc.treturn string The 32-byte HMAC.
     * @see #constantTimeEquals To compare an HMAC with the one you expected.
     */
    @LuaFunction
    public final byte[] hmac(ByteBuffer key, ByteBuffer data) throws LuaException {
        return Crypto.hmac(bytes(key, "key"), bytes(data, "data"));
    }

    /**
     * Derive keys from a shared secret with HKDF-SHA256 (RFC 5869).
     *
     * @param ikm    The input key material, such as a shared secret from {@link #exchange}.
     * @param salt   A salt. May be empty.
     * @param info   What the key is for, so different uses get different keys. May be empty.
     * @param length The number of bytes to produce, at most 8160.
     * @return The derived key material.
     * @throws LuaException If an argument is too long, or the length is out of range.
     * @cc.treturn string The derived key material.
     */
    @LuaFunction
    public final byte[] hkdf(ByteBuffer ikm, ByteBuffer salt, ByteBuffer info, int length) throws LuaException {
        if (length < 0 || length > Crypto.MAX_HKDF_LENGTH) {
            throw new LuaException("Length must be between 0 and " + Crypto.MAX_HKDF_LENGTH);
        }
        return Crypto.hkdf(bytes(ikm, "ikm"), bytes(salt, "salt"), bytes(info, "info"), length);
    }

    /**
     * Derive a key from a password with PBKDF2-HMAC-SHA256.
     * <p>
     * More iterations make guessing the password slower, but also make this call slower. A few thousand iterations is
     * plenty for most uses.
     *
     * @param password   The password.
     * @param salt       A salt, which should be random and stored alongside the result.
     * @param iterations The number of iterations, at most 100,000.
     * @param length     The number of bytes to produce, at most 256.
     * @return The derived key.
     * @throws LuaException If an argument is out of range.
     * @cc.treturn string The derived key.
     */
    @LuaFunction
    public final byte[] pbkdf2(ByteBuffer password, ByteBuffer salt, int iterations, int length) throws LuaException {
        if (iterations < 1 || iterations > MAX_PBKDF2_ITERATIONS) {
            throw new LuaException("Iterations must be between 1 and " + MAX_PBKDF2_ITERATIONS);
        }
        if (length < 1 || length > MAX_PBKDF2_LENGTH) {
            throw new LuaException("Length must be between 1 and " + MAX_PBKDF2_LENGTH);
        }
        return Crypto.pbkdf2(bytes(password, "password"), bytes(salt, "salt"), iterations, length);
    }

    /**
     * Generate a new key pair.
     *
     * @param kind {@code "x25519"} for key exchange, or {@code "ed25519"} for signatures.
     * @return The private and public keys.
     * @throws LuaException If the kind is unknown.
     * @cc.treturn string The 32-byte private key. Keep this secret.
     * @cc.treturn string The 32-byte public key, which can be shared with anyone.
     */
    @LuaFunction
    public final Object[] generateKeyPair(String kind) throws LuaException {
        var pair = Crypto.generateKeyPair(keyKind(kind));
        return new Object[]{ pair.privateKey(), pair.publicKey() };
    }

    /**
     * Agree on a shared secret using X25519.
     * <p>
     * Each side combines its own private key with the other's public key, and both get the same secret. Nobody who only
     * sees the public keys can work it out. Use {@link #hkdf} to turn the secret into keys.
     *
     * @param privateKey Our X25519 private key.
     * @param publicKey  The other side's X25519 public key.
     * @return The shared secret.
     * @throws LuaException If either key is the wrong length, or the public key is invalid.
     * @cc.treturn string The 32-byte shared secret.
     * @cc.usage Two key pairs agree on the same secret.
     * <pre>{@code
     * local alicePrivate, alicePublic = crypto.generateKeyPair("x25519")
     * local bobPrivate, bobPublic = crypto.generateKeyPair("x25519")
     * print(crypto.exchange(alicePrivate, bobPublic) == crypto.exchange(bobPrivate, alicePublic)) -- true
     * }</pre>
     */
    @LuaFunction
    public final byte[] exchange(ByteBuffer privateKey, ByteBuffer publicKey) throws LuaException {
        var key = Crypto.privateKey(Crypto.KeyKind.X25519, key(privateKey, "private key"));
        try {
            return Crypto.exchange(key, key(publicKey, "public key"));
        } catch (InvalidKeyException e) {
            throw new LuaException("Invalid public key");
        }
    }

    /**
     * Sign a string with Ed25519.
     *
     * @param privateKey The Ed25519 private key.
     * @param data       The data to sign.
     * @return The signature.
     * @throws LuaException If the key is the wrong length or the data is too long.
     * @cc.treturn string The 64-byte signature.
     */
    @LuaFunction
    public final byte[] sign(ByteBuffer privateKey, ByteBuffer data) throws LuaException {
        return Crypto.sign(Crypto.privateKey(Crypto.KeyKind.ED25519, key(privateKey, "private key")), bytes(data, "data"));
    }

    /**
     * Check an Ed25519 signature.
     *
     * @param publicKey The signer's Ed25519 public key.
     * @param data      The data which was signed.
     * @param signature The signature.
     * @return Whether the signature is valid.
     * @throws LuaException If the key is the wrong length or the data is too long.
     */
    @LuaFunction
    public final boolean verify(ByteBuffer publicKey, ByteBuffer data, ByteBuffer signature) throws LuaException {
        return Crypto.verify(key(publicKey, "public key"), bytes(data, "data"), bytes(signature, "signature"));
    }

    /**
     * Encrypt and authenticate a string with ChaCha20-Poly1305.
     * <p>
     * The result can only be decrypted with the same key and nonce, and any change to it is detected. A nonce must never
     * be used twice with the same key: use a counter, or 12 random bytes.
     *
     * @param key       The 32-byte key.
     * @param nonce     The 12-byte nonce.
     * @param plaintext The data to encrypt.
     * @param aad       Additional data to authenticate but not encrypt, such as a header. Optional.
     * @return The encrypted data.
     * @throws LuaException If the key or nonce are the wrong length, or the data is too long.
     * @cc.treturn string The ciphertext, 16 bytes longer than the plaintext.
     * @cc.usage Encrypt and decrypt a message.
     * <pre>{@code
     * local key, nonce = crypto.random(32), crypto.random(12)
     * local sealed = crypto.seal(key, nonce, "Hello, world!")
     * print(crypto.open(key, nonce, sealed)) -- Hello, world!
     * }</pre>
     */
    @LuaFunction
    public final byte[] seal(ByteBuffer key, ByteBuffer nonce, ByteBuffer plaintext, Optional<ByteBuffer> aad) throws LuaException {
        return Crypto.seal(key(key, "key"), nonce(nonce), bytes(plaintext, "plaintext"), aad(aad));
    }

    /**
     * Decrypt a string encrypted with {@link #seal}.
     *
     * @param key        The 32-byte key.
     * @param nonce      The 12-byte nonce it was sealed with.
     * @param ciphertext The encrypted data.
     * @param aad        The additional data it was sealed with, if any.
     * @return The plaintext, or {@code nil} if anything was changed.
     * @throws LuaException If the key or nonce are the wrong length, or the data is too long.
     * @cc.treturn string|nil The plaintext, or {@code nil} if the key, nonce, ciphertext or additional data don't match.
     */
    @LuaFunction
    public final Object @Nullable [] open(ByteBuffer key, ByteBuffer nonce, ByteBuffer ciphertext, Optional<ByteBuffer> aad) throws LuaException {
        var plaintext = Crypto.open(key(key, "key"), nonce(nonce), bytes(ciphertext, "ciphertext"), aad(aad));
        return plaintext == null ? null : new Object[]{ plaintext };
    }

    /**
     * Compare two strings in constant time. Use this rather than {@code ==} to check HMACs and similar secrets, as the
     * time {@code ==} takes can reveal how much of the string matched.
     *
     * @param a The first string.
     * @param b The second string.
     * @return Whether the strings are equal.
     * @throws LuaException If either string is too long.
     */
    @LuaFunction("equals")
    public final boolean constantTimeEquals(ByteBuffer a, ByteBuffer b) throws LuaException {
        return Crypto.constantTimeEquals(bytes(a, "a"), bytes(b, "b"));
    }

    /**
     * Get the contents of a string argument, checking its length.
     *
     * @param buffer The argument.
     * @param name   The argument's name, for errors.
     * @return The argument's bytes.
     * @throws LuaException If the argument is too long.
     */
    public static byte[] bytes(ByteBuffer buffer, String name) throws LuaException {
        if (buffer.remaining() > MAX_DATA) throw new LuaException("The " + name + " is too long (at most 1 MiB)");
        var bytes = new byte[buffer.remaining()];
        buffer.duplicate().get(bytes);
        return bytes;
    }

    /**
     * Get a 32-byte key argument.
     *
     * @param buffer The argument.
     * @param name   The argument's name, for errors.
     * @return The key's bytes.
     * @throws LuaException If the key is the wrong length.
     */
    public static byte[] key(ByteBuffer buffer, String name) throws LuaException {
        if (buffer.remaining() != Crypto.KEY_LENGTH) {
            throw new LuaException("The " + name + " must be " + Crypto.KEY_LENGTH + " bytes");
        }
        return bytes(buffer, name);
    }

    /**
     * Get a 12-byte nonce argument.
     *
     * @param buffer The argument.
     * @return The nonce's bytes.
     * @throws LuaException If the nonce is the wrong length.
     */
    public static byte[] nonce(ByteBuffer buffer) throws LuaException {
        if (buffer.remaining() != Crypto.NONCE_LENGTH) {
            throw new LuaException("The nonce must be " + Crypto.NONCE_LENGTH + " bytes");
        }
        return bytes(buffer, "nonce");
    }

    /**
     * Get an optional additional data argument.
     *
     * @param buffer The argument.
     * @return The additional data, or an empty array.
     * @throws LuaException If it is too long.
     */
    public static byte[] aad(Optional<ByteBuffer> buffer) throws LuaException {
        return buffer.isPresent() ? bytes(buffer.get(), "additional data") : new byte[0];
    }

    private static Crypto.KeyKind keyKind(String kind) throws LuaException {
        var result = Crypto.KeyKind.of(kind);
        if (result == null) throw new LuaException("Unknown key kind '" + kind + "' (expected x25519 or ed25519)");
        return result;
    }
}
