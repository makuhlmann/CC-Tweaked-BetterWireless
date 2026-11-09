// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.computer.enclave;

import dan200.computercraft.api.lua.ILuaAPI;
import dan200.computercraft.api.lua.LuaException;
import dan200.computercraft.api.lua.LuaFunction;
import dan200.computercraft.core.apis.CryptoAPI;
import org.jspecify.annotations.Nullable;

import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import java.util.function.Supplier;

/**
 * The enclave: a key store built into every computer, which programs can use but never read from.
 * <p>
 * A program can create a key here, then sign with it, use it in a key exchange, or encrypt with it, but the private key
 * itself never reaches Lua. Malicious software can still misuse a key while it runs on this computer, but can't copy it
 * anywhere else. The keys stay with the computer, even when it's broken and placed again.
 * <p>
 * Keys can also require a PIN. Such a key can't be used until a PIN is set with {@link #setPin}, and after that only
 * once the PIN has been entered with {@link #unlock} since the computer started. Three wrong PINs lock the enclave for a
 * minute, doubling each time.
 *
 * @cc.module enclave
 * @cc.usage Create a signing key, and use it without ever seeing it.
 * <pre>{@code
 * local public = enclave.publicKey("identity") or enclave.generate("identity", "ed25519")
 * local signature = enclave.sign("identity", "Hello, world!")
 * print(crypto.verify(public, "Hello, world!", signature)) -- true
 * }</pre>
 */
public class EnclaveAPI implements ILuaAPI {
    private final Supplier<Enclave> enclaveSupplier;
    private volatile @Nullable Enclave enclave;
    private volatile int unlocked = Enclave.LOCKED;

    /**
     * Create the API.
     *
     * @param enclave Finds this computer's enclave. This is called when the enclave is first used, rather than when the
     *                API is created.
     */
    public EnclaveAPI(Supplier<Enclave> enclave) {
        enclaveSupplier = enclave;
    }

    private Enclave enclave() {
        var enclave = this.enclave;
        if (enclave == null) this.enclave = enclave = enclaveSupplier.get();
        return enclave;
    }

    @Override
    public String[] getNames() {
        return new String[]{ "enclave" };
    }

    @Override
    public void startup() {
        unlocked = Enclave.LOCKED;
    }

    @Override
    public void shutdown() {
        unlocked = Enclave.LOCKED;
    }

    /**
     * Create a new key.
     *
     * @param name    The key's name, up to 64 characters.
     * @param kind    {@code "x25519"} for key exchange, {@code "ed25519"} for signatures, or {@code "secret"} for 32
     *                random bytes to use with {@link #hmac} and {@link #seal}.
     * @param options Options. {@code requirePin = true} means the key can only be used with the PIN. This can't be
     *                changed later.
     * @return The public key, or nothing for a secret.
     * @throws LuaException If the name is invalid or taken, the kind is unknown, or the enclave is full (32 keys).
     * @cc.tparam string name The key's name.
     * @cc.tparam string kind The kind of key.
     * @cc.tparam[opt] { requirePin? = boolean } options Options.
     * @cc.treturn string|nil The 32-byte public key, or nothing for a secret.
     */
    @LuaFunction
    public final Object @Nullable [] generate(String name, String kind, Optional<Map<?, ?>> options) throws LuaException {
        return wrap(enclave().generate(name, Enclave.Kind.of(kind), requirePin(options)));
    }

    /**
     * Store a key a program already has, such as one derived from a passphrase, so the program can delete its copy.
     *
     * @param name    The key's name, up to 64 characters.
     * @param kind    {@code "x25519"}, {@code "ed25519"} or {@code "secret"}.
     * @param key     The 32-byte private key or secret.
     * @param options Options, as for {@link #generate}.
     * @return The public key, or nothing for a secret.
     * @throws LuaException If the name is invalid or taken, the kind is unknown, the key is the wrong length, or the
     *                      enclave is full.
     * @cc.tparam string name The key's name.
     * @cc.tparam string kind The kind of key.
     * @cc.tparam string key The key.
     * @cc.tparam[opt] { requirePin? = boolean } options Options.
     * @cc.treturn string|nil The 32-byte public key, or nothing for a secret.
     */
    @LuaFunction("import")
    public final Object @Nullable [] importKey(String name, String kind, ByteBuffer key, Optional<Map<?, ?>> options) throws LuaException {
        return wrap(enclave().importKey(name, Enclave.Kind.of(kind), CryptoAPI.bytes(key, "key"), requirePin(options)));
    }

    /**
     * Get a key's public key.
     *
     * @param name The key's name.
     * @return The public key, or nothing if there's no such key or it's a secret.
     * @throws LuaException If the enclave can't be read.
     * @cc.treturn string|nil The 32-byte public key.
     */
    @LuaFunction
    public final Object @Nullable [] publicKey(String name) throws LuaException {
        return wrap(enclave().publicKey(name));
    }

    /**
     * List the keys in the enclave.
     *
     * @return A table of key names to their kind, and whether they need the PIN.
     * @throws LuaException If the enclave can't be read.
     * @cc.treturn { [string] = { kind = string, requirePin = boolean } } The keys.
     */
    @LuaFunction
    public final Map<String, Map<String, Object>> list() throws LuaException {
        var result = new HashMap<String, Map<String, Object>>();
        for (var entry : enclave().list().entrySet()) {
            result.put(entry.getKey(), Map.of("kind", entry.getValue().kind().id(), "requirePin", entry.getValue().requirePin()));
        }
        return result;
    }

    /**
     * Delete a key. It can't be recovered.
     *
     * @param name The key's name.
     * @return Whether there was such a key.
     * @throws LuaException If the enclave can't be read.
     */
    @LuaFunction
    public final boolean delete(String name) throws LuaException {
        return enclave().delete(name);
    }

    /**
     * Agree on a shared secret with X25519, using a stored key. This works like {@code crypto.exchange}.
     *
     * @param name      The name of an x25519 key.
     * @param publicKey The other side's public key.
     * @return The shared secret.
     * @throws LuaException If there's no such key, it's the wrong kind or locked, or the public key is invalid.
     * @cc.treturn string The 32-byte shared secret.
     */
    @LuaFunction
    public final byte[] exchange(String name, ByteBuffer publicKey) throws LuaException {
        return enclave().exchange(name, CryptoAPI.key(publicKey, "public key"), unlocked);
    }

    /**
     * Sign a string with a stored Ed25519 key. Check the signature with {@code crypto.verify}.
     *
     * @param name The name of an ed25519 key.
     * @param data The data to sign.
     * @return The signature.
     * @throws LuaException If there's no such key, or it's the wrong kind or locked.
     * @cc.treturn string The 64-byte signature.
     */
    @LuaFunction
    public final byte[] sign(String name, ByteBuffer data) throws LuaException {
        return enclave().sign(name, CryptoAPI.bytes(data, "data"), unlocked);
    }

    /**
     * Compute an HMAC-SHA256 with a stored secret.
     *
     * @param name The name of a secret.
     * @param data The data to authenticate.
     * @return The HMAC.
     * @throws LuaException If there's no such key, or it's the wrong kind or locked.
     * @cc.treturn string The 32-byte HMAC.
     */
    @LuaFunction
    public final byte[] hmac(String name, ByteBuffer data) throws LuaException {
        return enclave().hmac(name, CryptoAPI.bytes(data, "data"), unlocked);
    }

    /**
     * Encrypt and authenticate a string with a stored secret, using ChaCha20-Poly1305. This works like
     * {@code crypto.seal}. For example, files encrypted this way on a floppy disk can only be read on this computer.
     *
     * @param name      The name of a secret.
     * @param nonce     The 12-byte nonce. Never reuse one with the same key.
     * @param plaintext The data to encrypt.
     * @param aad       Additional data to authenticate but not encrypt. Optional.
     * @return The encrypted data.
     * @throws LuaException If there's no such key, it's the wrong kind or locked, or the nonce is the wrong length.
     * @cc.treturn string The ciphertext, 16 bytes longer than the plaintext.
     */
    @LuaFunction
    public final byte[] seal(String name, ByteBuffer nonce, ByteBuffer plaintext, Optional<ByteBuffer> aad) throws LuaException {
        return enclave().seal(name, CryptoAPI.nonce(nonce), CryptoAPI.bytes(plaintext, "plaintext"), CryptoAPI.aad(aad), unlocked);
    }

    /**
     * Decrypt a string encrypted with {@link #seal}.
     *
     * @param name       The name of a secret.
     * @param nonce      The 12-byte nonce it was sealed with.
     * @param ciphertext The encrypted data.
     * @param aad        The additional data it was sealed with, if any.
     * @return The plaintext, or nothing if anything was changed.
     * @throws LuaException If there's no such key, it's the wrong kind or locked, or the nonce is the wrong length.
     * @cc.treturn string|nil The plaintext.
     */
    @LuaFunction
    public final Object @Nullable [] open(String name, ByteBuffer nonce, ByteBuffer ciphertext, Optional<ByteBuffer> aad) throws LuaException {
        return wrap(enclave().open(name, CryptoAPI.nonce(nonce), CryptoAPI.bytes(ciphertext, "ciphertext"), CryptoAPI.aad(aad), unlocked));
    }

    /**
     * Set, change or remove the PIN. Setting it also counts as entering it.
     * <p>
     * Removing the PIN doesn't free keys which need it: they can't be used again until a new PIN is set.
     *
     * @param newPin The new PIN, or {@code nil} to remove it.
     * @param oldPin The current PIN, if one is set.
     * @throws LuaException If the current PIN is missing or wrong, there were too many wrong guesses, or the new PIN is
     *                      empty or longer than 64 characters.
     * @cc.usage Set a PIN for the first time, then change it.
     * <pre>{@code
     * enclave.setPin("1234")
     * enclave.setPin("5678", "1234")
     * }</pre>
     */
    @LuaFunction
    public final void setPin(Optional<ByteBuffer> newPin, Optional<ByteBuffer> oldPin) throws LuaException {
        unlocked = enclave().setPin(pin(newPin), pin(oldPin));
    }

    /**
     * Enter the PIN, so keys which need it can be used until the computer stops or {@link #lock} is called.
     *
     * @param pin The PIN.
     * @return Whether the PIN was right.
     * @throws LuaException If the PIN is too long.
     * @cc.treturn boolean Whether the enclave is now unlocked.
     * @cc.treturn string|nil Why not: no PIN is set, the PIN was wrong, or there were too many wrong guesses.
     */
    @LuaFunction
    public final Object[] unlock(ByteBuffer pin) throws LuaException {
        try {
            unlocked = enclave().unlock(CryptoAPI.bytes(pin, "PIN"));
            return new Object[]{ true };
        } catch (LuaException e) {
            return new Object[]{ false, e.getMessage() };
        }
    }

    /**
     * Lock keys which need the PIN again, until it's next entered.
     */
    @LuaFunction
    public final void lock() {
        unlocked = Enclave.LOCKED;
    }

    /**
     * Get the state of the PIN.
     *
     * @return The PIN's state.
     * @throws LuaException If the enclave can't be read.
     * @cc.treturn { pin = boolean, unlocked = boolean, lockout = number } Whether a PIN is set, whether this computer
     * has entered it, and how many seconds until the PIN may be tried again after too many wrong guesses.
     */
    @LuaFunction
    public final Map<String, Object> status() throws LuaException {
        var status = enclave().status(unlocked);
        return Map.of("pin", status.hasPin(), "unlocked", status.unlocked(), "lockout", Math.ceil(status.lockoutMillis() / 1000.0));
    }

    private static Object @Nullable [] wrap(byte @Nullable [] value) {
        return value == null ? null : new Object[]{ value };
    }

    private static byte @Nullable [] pin(Optional<ByteBuffer> pin) throws LuaException {
        return pin.isPresent() ? CryptoAPI.bytes(pin.get(), "PIN") : null;
    }

    private static boolean requirePin(Optional<Map<?, ?>> options) throws LuaException {
        if (options.isEmpty()) return false;
        var value = options.get().get("requirePin");
        if (value == null) return false;
        if (!(value instanceof Boolean bool)) throw new LuaException("Option requirePin must be a boolean");
        return bool;
    }
}
