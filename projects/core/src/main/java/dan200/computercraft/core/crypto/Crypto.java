// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.core.crypto;

import org.jspecify.annotations.Nullable;

import javax.crypto.AEADBadTagException;
import javax.crypto.Cipher;
import javax.crypto.KeyAgreement;
import javax.crypto.Mac;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import java.security.*;
import java.security.interfaces.EdECPrivateKey;
import java.security.interfaces.XECPrivateKey;
import java.security.spec.*;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.Locale;

/**
 * Cryptographic primitives, built on the JDK's standard providers. Everything works on raw byte arrays: keys are 32
 * bytes, as in the RFCs, rather than the JDK's encoded forms.
 * <p>
 * All methods are thread-safe.
 */
public final class Crypto {
    /** The length of keys, shared secrets and hashes, in bytes. */
    public static final int KEY_LENGTH = 32;

    /** The length of a ChaCha20-Poly1305 nonce, in bytes. */
    public static final int NONCE_LENGTH = 12;

    /** The length of a ChaCha20-Poly1305 authentication tag, in bytes. */
    public static final int TAG_LENGTH = 16;

    /** The length of an Ed25519 signature, in bytes. */
    public static final int SIGNATURE_LENGTH = 64;

    /** The longest output HKDF can produce, in bytes. */
    public static final int MAX_HKDF_LENGTH = 255 * KEY_LENGTH;

    private static final SecureRandom RANDOM = new SecureRandom();

    // The DER (X.509 SubjectPublicKeyInfo) prefixes for raw public keys.
    private static final byte[] X25519_PUBLIC_PREFIX = HexFormat.of().parseHex("302a300506032b656e032100");
    private static final byte[] ED25519_PUBLIC_PREFIX = HexFormat.of().parseHex("302a300506032b6570032100");

    private Crypto() {
    }

    /**
     * The kinds of key pair we support.
     */
    public enum KeyKind {
        X25519("x25519", "X25519"),
        ED25519("ed25519", "Ed25519");

        private final String id;
        private final String algorithm;

        KeyKind(String id, String algorithm) {
            this.id = id;
            this.algorithm = algorithm;
        }

        private NamedParameterSpec parameters() {
            return this == X25519 ? NamedParameterSpec.X25519 : NamedParameterSpec.ED25519;
        }

        private byte[] publicPrefix() {
            return this == X25519 ? X25519_PUBLIC_PREFIX : ED25519_PUBLIC_PREFIX;
        }

        /**
         * The name of this kind, as used in Lua.
         *
         * @return The kind's name.
         */
        public String id() {
            return id;
        }

        /**
         * Find a kind of key from its name.
         *
         * @param id The name, such as {@code "x25519"}.
         * @return The kind of key, or {@code null} if there's none with this name.
         */
        public static @Nullable KeyKind of(String id) {
            for (var kind : values()) {
                if (kind.id.equals(id.toLowerCase(Locale.ROOT))) return kind;
            }
            return null;
        }
    }

    /**
     * A raw key pair.
     *
     * @param privateKey The 32-byte private key: an X25519 scalar or an Ed25519 seed.
     * @param publicKey  The 32-byte public key.
     */
    @SuppressWarnings("ArrayRecordComponent")
    public record RawKeyPair(byte[] privateKey, byte[] publicKey) {
    }

    /**
     * Generate cryptographically secure random bytes.
     *
     * @param length The number of bytes.
     * @return The random bytes.
     */
    public static byte[] random(int length) {
        var bytes = new byte[length];
        RANDOM.nextBytes(bytes);
        return bytes;
    }

    /**
     * Compute the SHA-256 hash of some data.
     *
     * @param data The data to hash.
     * @return The 32-byte hash.
     */
    public static byte[] sha256(byte[] data) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(data);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /**
     * Compute the HMAC-SHA256 of some data.
     *
     * @param key  The key. This may be empty.
     * @param data The data to authenticate.
     * @return The 32-byte HMAC.
     */
    public static byte[] hmac(byte[] key, byte[] data) {
        var mac = mac(key);
        return mac.doFinal(data);
    }

    /**
     * Derive keys with HKDF-SHA256 (RFC 5869).
     *
     * @param ikm    The input keying material.
     * @param salt   The salt. An empty salt is treated as 32 zero bytes, as in the RFC.
     * @param info   Context for this derivation.
     * @param length The number of bytes to produce, at most {@link #MAX_HKDF_LENGTH}.
     * @return The derived bytes.
     */
    public static byte[] hkdf(byte[] ikm, byte[] salt, byte[] info, int length) {
        if (length < 0 || length > MAX_HKDF_LENGTH) throw new IllegalArgumentException("Invalid HKDF length " + length);

        var mac = mac(hmac(salt, ikm));
        var output = new byte[length];
        var block = new byte[0];
        for (int i = 1, offset = 0; offset < length; i++) {
            mac.update(block);
            mac.update(info);
            mac.update((byte) i);
            block = mac.doFinal();
            var count = Math.min(block.length, length - offset);
            System.arraycopy(block, 0, output, offset, count);
            offset += count;
        }
        return output;
    }

    /**
     * Derive a key from a password with PBKDF2-HMAC-SHA256.
     * <p>
     * We implement this ourselves, as the JDK's version only accepts passwords as characters, and Lua strings are bytes.
     *
     * @param password   The password.
     * @param salt       The salt.
     * @param iterations The number of iterations.
     * @param length     The number of bytes to produce.
     * @return The derived key.
     */
    public static byte[] pbkdf2(byte[] password, byte[] salt, int iterations, int length) {
        if (iterations < 1) throw new IllegalArgumentException("Iterations must be positive");
        if (length < 0) throw new IllegalArgumentException("Invalid PBKDF2 length " + length);

        var mac = mac(password);
        var output = new byte[length];
        for (int block = 1, offset = 0; offset < length; block++) {
            mac.update(salt);
            mac.update(new byte[]{ (byte) (block >>> 24), (byte) (block >>> 16), (byte) (block >>> 8), (byte) block });
            var u = mac.doFinal();
            var t = u.clone();
            for (var i = 1; i < iterations; i++) {
                u = mac.doFinal(u);
                for (var j = 0; j < t.length; j++) t[j] ^= u[j];
            }

            var count = Math.min(t.length, length - offset);
            System.arraycopy(t, 0, output, offset, count);
            offset += count;
        }
        return output;
    }

    private static Mac mac(byte[] key) {
        try {
            var mac = Mac.getInstance("HmacSHA256");
            // SecretKeySpec rejects empty keys. HMAC pads keys with zeros to the block size, so an empty key is the
            // same as a single zero byte.
            mac.init(new SecretKeySpec(key.length == 0 ? new byte[1] : key, "HmacSHA256"));
            return mac;
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    /**
     * Generate a new key pair.
     *
     * @param kind The kind of key pair.
     * @return The new key pair.
     */
    public static RawKeyPair generateKeyPair(KeyKind kind) {
        try {
            var generator = KeyPairGenerator.getInstance(kind.algorithm);
            generator.initialize(kind.parameters(), RANDOM);
            var pair = generator.generateKeyPair();
            return new RawKeyPair(rawPrivate(kind, pair.getPrivate()), rawPublic(kind, pair.getPublic()));
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    /**
     * Compute the public key for a private key.
     *
     * @param kind       The kind of key.
     * @param privateKey The 32-byte private key.
     * @return The 32-byte public key.
     */
    public static byte[] publicKey(KeyKind kind, byte[] privateKey) {
        checkLength(privateKey, KEY_LENGTH, "Private key");
        try {
            // The JDK has no way to compute a public key from a private one, but its key pair generators take the
            // private key straight from the random source, so we give them one which returns the key we want.
            var generator = KeyPairGenerator.getInstance(kind.algorithm);
            generator.initialize(kind.parameters(), new FixedRandom(privateKey));
            var pair = generator.generateKeyPair();
            if (!Arrays.equals(rawPrivate(kind, pair.getPrivate()), privateKey)) {
                throw new IllegalStateException("Key pair generator did not use the given private key");
            }
            return rawPublic(kind, pair.getPublic());
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    /**
     * Convert a raw private key to a JDK key object. Callers which use a key often should keep the result.
     *
     * @param kind       The kind of key.
     * @param privateKey The 32-byte private key.
     * @return The private key.
     */
    public static PrivateKey privateKey(KeyKind kind, byte[] privateKey) {
        checkLength(privateKey, KEY_LENGTH, "Private key");
        try {
            KeySpec spec = kind == KeyKind.X25519
                ? new XECPrivateKeySpec(kind.parameters(), privateKey.clone())
                : new EdECPrivateKeySpec(kind.parameters(), privateKey.clone());
            return KeyFactory.getInstance(kind.algorithm).generatePrivate(spec);
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    private static PublicKey parsePublic(KeyKind kind, byte[] publicKey) throws InvalidKeyException {
        checkLength(publicKey, KEY_LENGTH, "Public key");
        var encoded = Arrays.copyOf(kind.publicPrefix(), kind.publicPrefix().length + KEY_LENGTH);
        System.arraycopy(publicKey, 0, encoded, kind.publicPrefix().length, KEY_LENGTH);
        try {
            return KeyFactory.getInstance(kind.algorithm).generatePublic(new X509EncodedKeySpec(encoded));
        } catch (InvalidKeySpecException e) {
            throw new InvalidKeyException("Invalid public key", e);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    private static byte[] rawPrivate(KeyKind kind, PrivateKey key) {
        var bytes = kind == KeyKind.X25519 ? ((XECPrivateKey) key).getScalar() : ((EdECPrivateKey) key).getBytes();
        return bytes.orElseThrow(() -> new IllegalStateException("Private key has no raw form"));
    }

    private static byte[] rawPublic(KeyKind kind, PublicKey key) {
        var encoded = key.getEncoded();
        if (encoded == null || encoded.length != kind.publicPrefix().length + KEY_LENGTH) {
            throw new IllegalStateException("Unexpected public key encoding");
        }
        return Arrays.copyOfRange(encoded, kind.publicPrefix().length, encoded.length);
    }

    /**
     * Perform an X25519 key exchange.
     *
     * @param privateKey Our X25519 private key.
     * @param publicKey  The other side's 32-byte public key.
     * @return The 32-byte shared secret.
     * @throws InvalidKeyException If the public key is invalid, or the result is all zeros (meaning the public key was
     *                             a low-order point, which an attacker can use to force a known secret).
     */
    public static byte[] exchange(PrivateKey privateKey, byte[] publicKey) throws InvalidKeyException {
        try {
            var agreement = KeyAgreement.getInstance("X25519");
            agreement.init(privateKey);
            agreement.doPhase(parsePublic(KeyKind.X25519, publicKey), true);
            var secret = agreement.generateSecret();

            var zero = 0;
            for (var b : secret) zero |= b;
            if (zero == 0) throw new InvalidKeyException("Invalid public key");
            return secret;
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /**
     * Sign some data with Ed25519.
     *
     * @param privateKey The Ed25519 private key.
     * @param data       The data to sign.
     * @return The 64-byte signature.
     */
    public static byte[] sign(PrivateKey privateKey, byte[] data) {
        try {
            var signature = Signature.getInstance("Ed25519");
            signature.initSign(privateKey);
            signature.update(data);
            return signature.sign();
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    /**
     * Check an Ed25519 signature.
     *
     * @param publicKey The signer's 32-byte public key.
     * @param data      The data which was signed.
     * @param signature The signature.
     * @return Whether the signature is valid. This is {@code false} for public keys which aren't valid points.
     */
    public static boolean verify(byte[] publicKey, byte[] data, byte[] signature) {
        checkLength(publicKey, KEY_LENGTH, "Public key");
        if (signature.length != SIGNATURE_LENGTH) return false;
        try {
            var verifier = Signature.getInstance("Ed25519");
            verifier.initVerify(parsePublic(KeyKind.ED25519, publicKey));
            verifier.update(data);
            return verifier.verify(signature);
        } catch (InvalidKeyException | SignatureException e) {
            return false;
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /**
     * Encrypt and authenticate some data with ChaCha20-Poly1305.
     *
     * @param key       The 32-byte key.
     * @param nonce     The 12-byte nonce. This must never be reused with the same key.
     * @param plaintext The data to encrypt.
     * @param aad       Additional data to authenticate, but not encrypt. This may be empty.
     * @return The ciphertext, followed by a 16-byte authentication tag.
     */
    public static byte[] seal(byte[] key, byte[] nonce, byte[] plaintext, byte[] aad) {
        try {
            return cipher(Cipher.ENCRYPT_MODE, key, nonce, aad).doFinal(plaintext);
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    /**
     * Decrypt and check data encrypted by {@link #seal(byte[], byte[], byte[], byte[])}.
     *
     * @param key        The 32-byte key.
     * @param nonce      The 12-byte nonce.
     * @param ciphertext The ciphertext and tag.
     * @param aad        The additional data it was sealed with.
     * @return The plaintext, or {@code null} if the ciphertext, tag or additional data were changed.
     */
    public static byte @Nullable [] open(byte[] key, byte[] nonce, byte[] ciphertext, byte[] aad) {
        if (ciphertext.length < TAG_LENGTH) return null;
        try {
            return cipher(Cipher.DECRYPT_MODE, key, nonce, aad).doFinal(ciphertext);
        } catch (AEADBadTagException e) {
            return null;
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    private static Cipher cipher(int mode, byte[] key, byte[] nonce, byte[] aad) throws GeneralSecurityException {
        checkLength(key, KEY_LENGTH, "Key");
        checkLength(nonce, NONCE_LENGTH, "Nonce");

        var cipher = Cipher.getInstance("ChaCha20-Poly1305");
        cipher.init(mode, new SecretKeySpec(key, "ChaCha20"), new IvParameterSpec(nonce));
        if (aad.length > 0) cipher.updateAAD(aad);
        return cipher;
    }

    /**
     * Compare two byte arrays in constant time, so the time taken doesn't reveal where they differ.
     *
     * @param a The first array.
     * @param b The second array.
     * @return Whether they are equal.
     */
    public static boolean constantTimeEquals(byte[] a, byte[] b) {
        return MessageDigest.isEqual(a, b);
    }

    private static void checkLength(byte[] bytes, int length, String what) {
        if (bytes.length != length) throw new IllegalArgumentException(what + " must be " + length + " bytes");
    }

    /**
     * A "random" source which returns a fixed key, for {@link #publicKey(KeyKind, byte[])}.
     */
    @SuppressWarnings("serial")
    private static final class FixedRandom extends SecureRandom {
        private final byte[] bytes;
        private boolean used;

        FixedRandom(byte[] bytes) {
            this.bytes = bytes;
        }

        @Override
        public void nextBytes(byte[] output) {
            if (used || output.length != bytes.length) throw new IllegalStateException("Unexpected use of FixedRandom");
            System.arraycopy(bytes, 0, output, 0, bytes.length);
            used = true;
        }
    }
}
