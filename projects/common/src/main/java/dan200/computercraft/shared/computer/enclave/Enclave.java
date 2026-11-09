// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.computer.enclave;

import com.google.gson.*;
import dan200.computercraft.api.lua.LuaException;
import dan200.computercraft.core.crypto.Crypto;
import org.jspecify.annotations.Nullable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.BufferedWriter;
import java.io.IOException;
import java.io.Writer;
import java.nio.channels.Channels;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.InvalidKeyException;
import java.security.PrivateKey;
import java.util.*;
import java.util.function.LongSupplier;

/**
 * One computer's key store. Programs can use its keys, but never read their private parts.
 * <p>
 * Keys are kept in a file on the server, outside the computer's file system, so no program can reach them. Keys may
 * require a PIN: they can't be used until one is set, and then only once it has been entered since the computer
 * started. Which PIN a computer last entered is tracked by the caller (see {@link EnclaveAPI}), as a "PIN version" which
 * changes whenever the PIN does.
 * <p>
 * All methods are thread-safe.
 */
public final class Enclave {
    private static final Logger LOG = LoggerFactory.getLogger(Enclave.class);
    private static final Gson GSON = new GsonBuilder().setPrettyPrinting().create();

    /** The PIN version of a computer which hasn't entered the PIN. */
    public static final int LOCKED = -1;

    public static final int MAX_KEYS = 32;
    public static final int MAX_NAME_LENGTH = 64;
    public static final int MAX_PIN_LENGTH = 64;

    private static final int PIN_ITERATIONS = 20_000;
    private static final int MAX_ATTEMPTS = 3;
    private static final long LOCKOUT_MILLIS = 60_000;
    private static final int MAX_LOCKOUT_DOUBLINGS = 10;

    /**
     * The kinds of key an enclave can hold.
     */
    public enum Kind {
        X25519("x25519", Crypto.KeyKind.X25519),
        ED25519("ed25519", Crypto.KeyKind.ED25519),
        SECRET("secret", null);

        private final String id;
        private final Crypto.@Nullable KeyKind pair;

        Kind(String id, Crypto.@Nullable KeyKind pair) {
            this.id = id;
            this.pair = pair;
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
         * @return The kind of key.
         * @throws LuaException If there's no kind with this name.
         */
        public static Kind of(String id) throws LuaException {
            for (var kind : values()) {
                if (kind.id.equals(id)) return kind;
            }
            throw new LuaException("Unknown key kind '" + id + "' (expected x25519, ed25519 or secret)");
        }
    }

    /**
     * A PIN was wrong, missing, or can't be tried yet. These are expected, unlike other errors such as an unreadable
     * enclave.
     */
    public static final class PinException extends LuaException {
        private static final long serialVersionUID = 1L;

        PinException(String message) {
            super(message);
        }
    }

    /**
     * What a program may know about a key.
     *
     * @param kind       The kind of key.
     * @param requirePin Whether the key can only be used with the PIN.
     */
    public record KeyInfo(Kind kind, boolean requirePin) {
    }

    /**
     * The state of the PIN, for one computer.
     *
     * @param hasPin        Whether a PIN is set.
     * @param unlocked      Whether this computer has entered it.
     * @param lockoutMillis How long until the PIN may be tried again, after too many wrong guesses.
     */
    public record Status(boolean hasPin, boolean unlocked, long lockoutMillis) {
    }

    /**
     * A stored key. {@link #key} is the private key or secret: it must never leave this class, which is the whole point
     * of the enclave. Only copies of {@link #publicKey} are handed out.
     */
    private static final class Entry {
        final Kind kind;
        final byte[] key;
        final byte @Nullable [] publicKey;
        final boolean requirePin;
        private @Nullable PrivateKey parsed;

        Entry(Kind kind, byte[] key, boolean requirePin) {
            this.kind = kind;
            this.key = key;
            this.requirePin = requirePin;
            publicKey = kind.pair == null ? null : Crypto.publicKey(kind.pair, key);
        }

        PrivateKey privateKey() {
            var parsed = this.parsed;
            if (parsed == null) this.parsed = parsed = Crypto.privateKey(Objects.requireNonNull(kind.pair), key);
            return parsed;
        }
    }

    @SuppressWarnings("ArrayRecordComponent")
    private record Pin(byte[] salt, byte[] hash, int iterations) {
    }

    private final Path file;
    private final Path newFile;
    private final LongSupplier clock;

    private boolean loaded;
    private boolean broken;
    private final Map<String, Entry> keys = new TreeMap<>();
    private @Nullable Pin pin;
    private int pinVersion;
    private int failures;
    private int lockouts;
    private long lockedUntil;

    /**
     * Create an enclave. Nothing is read until it is first used.
     *
     * @param file  The file the enclave is stored in.
     * @param clock The current time in milliseconds, for PIN lockouts.
     */
    public Enclave(Path file, LongSupplier clock) {
        this.file = file;
        newFile = file.resolveSibling(file.getFileName() + ".new");
        this.clock = clock;
    }

    /**
     * Create a new key.
     *
     * @param name       The key's name.
     * @param kind       The kind of key.
     * @param requirePin Whether the key may only be used with the PIN.
     * @return The public key, or {@code null} for a secret.
     * @throws LuaException If the name is invalid or taken, or the enclave is full.
     */
    public synchronized byte @Nullable [] generate(String name, Kind kind, boolean requirePin) throws LuaException {
        var key = kind.pair == null ? Crypto.random(Crypto.KEY_LENGTH) : Crypto.generateKeyPair(kind.pair).privateKey();
        return add(name, kind, key, requirePin);
    }

    /**
     * Store a key a program already has.
     *
     * @param name       The key's name.
     * @param kind       The kind of key.
     * @param key        The 32-byte private key or secret.
     * @param requirePin Whether the key may only be used with the PIN.
     * @return The public key, or {@code null} for a secret.
     * @throws LuaException If the name is invalid or taken, the key is the wrong length, or the enclave is full.
     */
    public synchronized byte @Nullable [] importKey(String name, Kind kind, byte[] key, boolean requirePin) throws LuaException {
        if (key.length != Crypto.KEY_LENGTH) throw new LuaException("The key must be " + Crypto.KEY_LENGTH + " bytes");
        return add(name, kind, key.clone(), requirePin);
    }

    private byte @Nullable [] add(String name, Kind kind, byte[] key, boolean requirePin) throws LuaException {
        load();
        if (name.isEmpty() || name.length() > MAX_NAME_LENGTH) {
            throw new LuaException("Key names must be between 1 and " + MAX_NAME_LENGTH + " characters");
        }
        if (keys.containsKey(name)) throw new LuaException("There is already a key named '" + name + "'");
        if (keys.size() >= MAX_KEYS) throw new LuaException("The enclave is full (at most " + MAX_KEYS + " keys)");

        var entry = new Entry(kind, key, requirePin);
        keys.put(name, entry);
        save();
        return entry.publicKey == null ? null : entry.publicKey.clone();
    }

    /**
     * Get a key's public key.
     *
     * @param name The key's name.
     * @return The public key, or {@code null} if there's no such key or it's a secret.
     * @throws LuaException If the enclave can't be read.
     */
    public synchronized byte @Nullable [] publicKey(String name) throws LuaException {
        load();
        var entry = keys.get(name);
        return entry == null || entry.publicKey == null ? null : entry.publicKey.clone();
    }

    /**
     * List the keys in this enclave.
     *
     * @return Each key's name and what kind it is.
     * @throws LuaException If the enclave can't be read.
     */
    public synchronized Map<String, KeyInfo> list() throws LuaException {
        load();
        var result = new TreeMap<String, KeyInfo>();
        for (var entry : keys.entrySet()) result.put(entry.getKey(), new KeyInfo(entry.getValue().kind, entry.getValue().requirePin));
        return result;
    }

    /**
     * Delete a key.
     *
     * @param name The key's name.
     * @return Whether there was such a key.
     * @throws LuaException If the enclave can't be read.
     */
    public synchronized boolean delete(String name) throws LuaException {
        load();
        if (keys.remove(name) == null) return false;
        save();
        return true;
    }

    /**
     * Perform an X25519 key exchange with a stored key.
     *
     * @param name      The key's name.
     * @param publicKey The other side's public key.
     * @param unlocked  The PIN version this computer has entered.
     * @return The shared secret.
     * @throws LuaException If there's no such key, it's the wrong kind or locked, or the public key is invalid.
     */
    public synchronized byte[] exchange(String name, byte[] publicKey, int unlocked) throws LuaException {
        var entry = use(name, Kind.X25519, unlocked);
        try {
            return Crypto.exchange(entry.privateKey(), publicKey);
        } catch (InvalidKeyException e) {
            throw new LuaException("Invalid public key");
        }
    }

    /**
     * Sign data with a stored Ed25519 key.
     *
     * @param name     The key's name.
     * @param data     The data to sign.
     * @param unlocked The PIN version this computer has entered.
     * @return The signature.
     * @throws LuaException If there's no such key, or it's the wrong kind or locked.
     */
    public synchronized byte[] sign(String name, byte[] data, int unlocked) throws LuaException {
        return Crypto.sign(use(name, Kind.ED25519, unlocked).privateKey(), data);
    }

    /**
     * Compute an HMAC with a stored secret.
     *
     * @param name     The key's name.
     * @param data     The data to authenticate.
     * @param unlocked The PIN version this computer has entered.
     * @return The HMAC.
     * @throws LuaException If there's no such key, or it's the wrong kind or locked.
     */
    public synchronized byte[] hmac(String name, byte[] data, int unlocked) throws LuaException {
        return Crypto.hmac(use(name, Kind.SECRET, unlocked).key, data);
    }

    /**
     * Encrypt data with a stored secret.
     *
     * @param name      The key's name.
     * @param nonce     The 12-byte nonce.
     * @param plaintext The data to encrypt.
     * @param aad       Additional data to authenticate.
     * @param unlocked  The PIN version this computer has entered.
     * @return The ciphertext and tag.
     * @throws LuaException If there's no such key, or it's the wrong kind or locked.
     */
    public synchronized byte[] seal(String name, byte[] nonce, byte[] plaintext, byte[] aad, int unlocked) throws LuaException {
        return Crypto.seal(use(name, Kind.SECRET, unlocked).key, nonce, plaintext, aad);
    }

    /**
     * Decrypt data with a stored secret.
     *
     * @param name       The key's name.
     * @param nonce      The 12-byte nonce.
     * @param ciphertext The ciphertext and tag.
     * @param aad        Additional data it was sealed with.
     * @param unlocked   The PIN version this computer has entered.
     * @return The plaintext, or {@code null} if anything was changed.
     * @throws LuaException If there's no such key, or it's the wrong kind or locked.
     */
    public synchronized byte @Nullable [] open(String name, byte[] nonce, byte[] ciphertext, byte[] aad, int unlocked) throws LuaException {
        return Crypto.open(use(name, Kind.SECRET, unlocked).key, nonce, ciphertext, aad);
    }

    private Entry use(String name, Kind kind, int unlocked) throws LuaException {
        load();
        var entry = keys.get(name);
        if (entry == null) throw new LuaException("There is no key named '" + name + "'");
        if (entry.kind != kind) {
            throw new LuaException("'" + name + "' is " + article(entry.kind) + " key, not " + article(kind));
        }
        if (entry.requirePin) {
            if (pin == null) throw new LuaException("'" + name + "' needs a PIN, but none is set");
            if (unlocked != pinVersion) throw new LuaException("'" + name + "' is locked until the PIN is entered");
        }
        return entry;
    }

    private static String article(Kind kind) {
        return (kind == Kind.ED25519 ? "an " : "a ") + kind.id;
    }

    /**
     * Set, change or remove the PIN.
     *
     * @param newPin The new PIN, or {@code null} to remove it.
     * @param oldPin The current PIN, which is needed if one is set.
     * @return The new PIN version, which counts as having entered the new PIN, or {@link #LOCKED} if it was removed.
     * @throws LuaException If the current PIN is wrong or missing, the enclave is locked out, or the new PIN is invalid.
     */
    public synchronized int setPin(byte @Nullable [] newPin, byte @Nullable [] oldPin) throws LuaException {
        load();
        if (newPin != null && (newPin.length == 0 || newPin.length > MAX_PIN_LENGTH)) {
            throw new LuaException("The PIN must be between 1 and " + MAX_PIN_LENGTH + " characters");
        }

        var current = pin;
        if (current != null) {
            if (oldPin == null) throw new PinException("The current PIN is needed to change it");
            if (!checkPin(current, oldPin)) throw new PinException("Wrong PIN");
        } else if (newPin == null) {
            return LOCKED;
        }

        if (newPin == null) {
            pin = null;
        } else {
            var salt = Crypto.random(16);
            pin = new Pin(salt, Crypto.pbkdf2(newPin, salt, PIN_ITERATIONS, Crypto.KEY_LENGTH), PIN_ITERATIONS);
        }
        pinVersion++;
        save();
        return newPin == null ? LOCKED : pinVersion;
    }

    /**
     * Enter the PIN, unlocking keys which need it.
     *
     * @param attempt The PIN.
     * @return The PIN version, to pass to the methods which use keys.
     * @throws PinException If no PIN is set, the PIN is wrong, or there have been too many wrong guesses.
     * @throws LuaException  If the enclave can't be read or saved.
     */
    public synchronized int unlock(byte[] attempt) throws LuaException {
        load();
        var current = pin;
        if (current == null) throw new PinException("No PIN is set");
        if (!checkPin(current, attempt)) throw new PinException("Wrong PIN");
        return pinVersion;
    }

    private boolean checkPin(Pin current, byte[] attempt) throws LuaException {
        var remaining = lockedUntil - clock.getAsLong();
        if (remaining > 0) {
            throw new PinException("Too many wrong PINs. Try again in " + ((remaining + 999) / 1000) + " seconds");
        }

        if (Crypto.constantTimeEquals(Crypto.pbkdf2(attempt, current.salt, current.iterations, Crypto.KEY_LENGTH), current.hash)) {
            if (failures != 0 || lockouts != 0) {
                failures = 0;
                lockouts = 0;
                save();
            }
            return true;
        }

        if (++failures >= MAX_ATTEMPTS) {
            failures = 0;
            lockedUntil = clock.getAsLong() + (LOCKOUT_MILLIS << Math.min(lockouts, MAX_LOCKOUT_DOUBLINGS));
            lockouts++;
        }
        save();
        return false;
    }

    /**
     * Get the state of the PIN.
     *
     * @param unlocked The PIN version this computer has entered.
     * @return The PIN's state.
     * @throws LuaException If the enclave can't be read.
     */
    public synchronized Status status(int unlocked) throws LuaException {
        load();
        return new Status(pin != null, pin != null && unlocked == pinVersion, Math.max(0, lockedUntil - clock.getAsLong()));
    }

    private void load() throws LuaException {
        if (broken) throw new LuaException("This computer's enclave can't be read");
        if (loaded) return;

        if (Files.isRegularFile(file)) {
            try (var reader = Files.newBufferedReader(file, StandardCharsets.UTF_8)) {
                read(JsonParser.parseReader(reader).getAsJsonObject());
            } catch (IOException | RuntimeException e) {
                // Don't overwrite a file we can't read: the keys in it may still be recoverable.
                LOG.error("Cannot read enclave '{}'", file, e);
                broken = true;
                keys.clear();
                pin = null;
                throw new LuaException("This computer's enclave can't be read");
            }
        }
        loaded = true;
    }

    private void read(JsonObject json) {
        var decoder = Base64.getDecoder();
        for (var entry : json.getAsJsonObject("keys").entrySet()) {
            var key = entry.getValue().getAsJsonObject();
            var kind = Kind.valueOf(key.get("kind").getAsString().toUpperCase(Locale.ROOT));
            keys.put(entry.getKey(), new Entry(kind, decoder.decode(key.get("key").getAsString()), key.get("requirePin").getAsBoolean()));
        }

        if (json.has("pin")) {
            var pin = json.getAsJsonObject("pin");
            this.pin = new Pin(
                decoder.decode(pin.get("salt").getAsString()), decoder.decode(pin.get("hash").getAsString()),
                pin.get("iterations").getAsInt()
            );
        }
        failures = json.get("failures").getAsInt();
        lockouts = json.get("lockouts").getAsInt();
        lockedUntil = json.get("lockedUntil").getAsLong();
    }

    private JsonObject write() {
        var encoder = Base64.getEncoder();
        var json = new JsonObject();
        json.addProperty("version", 1);

        var keys = new JsonObject();
        for (var entry : this.keys.entrySet()) {
            var key = new JsonObject();
            key.addProperty("kind", entry.getValue().kind.id);
            key.addProperty("key", encoder.encodeToString(entry.getValue().key));
            key.addProperty("requirePin", entry.getValue().requirePin);
            keys.add(entry.getKey(), key);
        }
        json.add("keys", keys);

        var pin = this.pin;
        if (pin != null) {
            var pinJson = new JsonObject();
            pinJson.addProperty("salt", encoder.encodeToString(pin.salt));
            pinJson.addProperty("hash", encoder.encodeToString(pin.hash));
            pinJson.addProperty("iterations", pin.iterations);
            json.add("pin", pinJson);
        }
        json.addProperty("failures", failures);
        json.addProperty("lockouts", lockouts);
        json.addProperty("lockedUntil", lockedUntil);
        return json;
    }

    private void save() throws LuaException {
        // As with IDAssigner, write to a temporary file and then move it over the original, so we're less likely to
        // lose keys if the game is stopped part way through.
        try {
            Files.createDirectories(Objects.requireNonNull(file.getParent()));
            try (var channel = FileChannel.open(newFile, StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE)) {
                Writer writer = new BufferedWriter(Channels.newWriter(channel, StandardCharsets.UTF_8));
                GSON.toJson(write(), writer);
                writer.flush();
                channel.force(false);
            }

            try {
                Files.move(newFile, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException | UnsupportedOperationException e) {
                Files.move(newFile, file, StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (IOException e) {
            LOG.error("Cannot save enclave '{}'", file, e);
            throw new LuaException("Cannot save the enclave");
        }
    }
}
