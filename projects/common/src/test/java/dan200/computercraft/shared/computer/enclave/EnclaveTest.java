// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.computer.enclave;

import dan200.computercraft.api.lua.LuaException;
import dan200.computercraft.core.crypto.Crypto;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HexFormat;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.*;

public class EnclaveTest {
    private static final byte[] PIN = "1234".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] WRONG_PIN = "0000".getBytes(StandardCharsets.US_ASCII);

    // RFC 8032, test 2.
    private static final byte[] ED25519_SECRET = HexFormat.of().parseHex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb");
    private static final byte[] ED25519_PUBLIC = HexFormat.of().parseHex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c");
    private static final byte[] ED25519_SIGNATURE = HexFormat.of().parseHex("92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00");

    @TempDir
    Path dir;

    private final AtomicLong clock = new AtomicLong(1_000_000);
    private Path file;

    @BeforeEach
    public void setup() {
        file = dir.resolve("enclave").resolve("7.json");
    }

    private Enclave open() {
        return new Enclave(file, clock::get);
    }

    @Test
    public void generatedKeysWork() throws LuaException {
        var enclave = open();
        var exchangePublic = enclave.generate("dh", Enclave.Kind.X25519, false);
        var signPublic = enclave.generate("sign", Enclave.Kind.ED25519, false);
        assertNull(enclave.generate("secret", Enclave.Kind.SECRET, false));

        // Key exchange agrees with an outside key pair.
        assertNotNull(exchangePublic);
        var peer = Crypto.generateKeyPair(Crypto.KeyKind.X25519);
        assertArrayEquals(
            assertDoesNotThrow(() -> Crypto.exchange(Crypto.privateKey(Crypto.KeyKind.X25519, peer.privateKey()), exchangePublic)),
            enclave.exchange("dh", peer.publicKey(), Enclave.LOCKED)
        );

        // Signatures verify with the public key.
        assertNotNull(signPublic);
        assertTrue(Crypto.verify(signPublic, new byte[]{ 1, 2, 3 }, enclave.sign("sign", new byte[]{ 1, 2, 3 }, Enclave.LOCKED)));

        // Secrets seal and open.
        var nonce = new byte[12];
        var sealed = enclave.seal("secret", nonce, new byte[]{ 4, 5 }, new byte[0], Enclave.LOCKED);
        assertArrayEquals(new byte[]{ 4, 5 }, enclave.open("secret", nonce, sealed, new byte[0], Enclave.LOCKED));
        assertEquals(32, enclave.hmac("secret", new byte[0], Enclave.LOCKED).length);
    }

    @Test
    public void importedKeysMatchRfc8032() throws LuaException {
        var enclave = open();
        assertArrayEquals(ED25519_PUBLIC, enclave.importKey("sign", Enclave.Kind.ED25519, ED25519_SECRET, false));
        assertArrayEquals(ED25519_SIGNATURE, enclave.sign("sign", new byte[]{ 0x72 }, Enclave.LOCKED));
    }

    @Test
    public void keysPersist() throws LuaException {
        open().importKey("sign", Enclave.Kind.ED25519, ED25519_SECRET, false);

        var reopened = open();
        assertArrayEquals(ED25519_PUBLIC, reopened.publicKey("sign"));
        assertArrayEquals(ED25519_SIGNATURE, reopened.sign("sign", new byte[]{ 0x72 }, Enclave.LOCKED));
        assertEquals(new Enclave.KeyInfo(Enclave.Kind.ED25519, false), reopened.list().get("sign"));
    }

    @Test
    public void rejectsBadNamesAndKinds() throws LuaException {
        var enclave = open();
        enclave.generate("key", Enclave.Kind.ED25519, false);

        assertEquals("There is already a key named 'key'", assertThrows(LuaException.class, () -> enclave.generate("key", Enclave.Kind.SECRET, false)).getMessage());
        assertThrows(LuaException.class, () -> enclave.generate("", Enclave.Kind.SECRET, false));
        assertThrows(LuaException.class, () -> enclave.generate("x".repeat(65), Enclave.Kind.SECRET, false));
        assertEquals("'key' is an ed25519 key, not a x25519", assertThrows(LuaException.class, () -> enclave.exchange("key", new byte[32], Enclave.LOCKED)).getMessage());
        assertEquals("There is no key named 'missing'", assertThrows(LuaException.class, () -> enclave.sign("missing", new byte[0], Enclave.LOCKED)).getMessage());
        assertThrows(LuaException.class, () -> enclave.importKey("short", Enclave.Kind.SECRET, new byte[5], false));
    }

    @Test
    public void isLimitedInSize() throws LuaException {
        var enclave = open();
        for (var i = 0; i < Enclave.MAX_KEYS; i++) enclave.generate("key" + i, Enclave.Kind.SECRET, false);
        assertThrows(LuaException.class, () -> enclave.generate("one too many", Enclave.Kind.SECRET, false));

        assertTrue(enclave.delete("key0"));
        assertFalse(enclave.delete("key0"));
        enclave.generate("one more", Enclave.Kind.SECRET, false);
    }

    @Test
    public void pinProtectedKeysNeedAPin() throws LuaException {
        var enclave = open();
        enclave.generate("sim", Enclave.Kind.ED25519, true);
        enclave.generate("plain", Enclave.Kind.ED25519, false);

        // Without a PIN, the protected key can't be used at all. Others work as normal.
        assertEquals("'sim' needs a PIN, but none is set", assertThrows(LuaException.class, () -> enclave.sign("sim", new byte[0], Enclave.LOCKED)).getMessage());
        enclave.sign("plain", new byte[0], Enclave.LOCKED);

        // Setting the PIN counts as entering it.
        var unlocked = enclave.setPin(PIN, null);
        enclave.sign("sim", new byte[0], unlocked);

        // A computer which hasn't entered it, such as after a reboot, is locked out.
        assertEquals("'sim' is locked until the PIN is entered", assertThrows(LuaException.class, () -> enclave.sign("sim", new byte[0], Enclave.LOCKED)).getMessage());
        enclave.sign("sim", new byte[0], enclave.unlock(PIN));
    }

    @Test
    public void changingThePinNeedsTheOldOne() throws LuaException {
        var enclave = open();
        enclave.generate("sim", Enclave.Kind.ED25519, true);
        var first = enclave.setPin(PIN, null);

        assertThrows(LuaException.class, () -> enclave.setPin(WRONG_PIN, null));
        assertEquals("Wrong PIN", assertThrows(LuaException.class, () -> enclave.setPin(WRONG_PIN, WRONG_PIN)).getMessage());

        var second = enclave.setPin(WRONG_PIN, PIN);
        // The old PIN version no longer unlocks anything.
        assertThrows(LuaException.class, () -> enclave.sign("sim", new byte[0], first));
        enclave.sign("sim", new byte[0], second);

        // Removing the PIN makes protected keys unusable again.
        assertEquals(Enclave.LOCKED, enclave.setPin(null, WRONG_PIN));
        assertThrows(LuaException.class, () -> enclave.sign("sim", new byte[0], second));
    }

    @Test
    public void wrongPinsLockOut() throws LuaException {
        var enclave = open();
        enclave.setPin(PIN, null);

        for (var i = 0; i < 3; i++) assertEquals("Wrong PIN", assertThrows(LuaException.class, () -> enclave.unlock(WRONG_PIN)).getMessage());

        // Locked out, even with the right PIN, and even after reloading.
        assertThat(assertThrows(LuaException.class, () -> enclave.unlock(PIN)).getMessage(), "Too many wrong PINs. Try again in 60 seconds");
        assertThat(assertThrows(LuaException.class, () -> open().unlock(PIN)).getMessage(), "Too many wrong PINs. Try again in 60 seconds");
        assertEquals(60_000, open().status(Enclave.LOCKED).lockoutMillis());

        // A minute later the right PIN works, and resets the count.
        clock.addAndGet(60_000);
        enclave.unlock(PIN);

        // The next lockout lasts twice as long, unless the PIN was entered in between.
        for (var i = 0; i < 3; i++) assertThrows(LuaException.class, () -> enclave.unlock(WRONG_PIN));
        assertEquals(60_000, enclave.status(Enclave.LOCKED).lockoutMillis());
        clock.addAndGet(60_000);
        for (var i = 0; i < 3; i++) assertThrows(LuaException.class, () -> enclave.unlock(WRONG_PIN));
        assertEquals(120_000, enclave.status(Enclave.LOCKED).lockoutMillis());
    }

    @Test
    public void unreadableFilesAreNotOverwritten() throws Exception {
        Files.createDirectories(file.getParent());
        Files.writeString(file, "not json");

        var enclave = open();
        assertThrows(LuaException.class, () -> enclave.generate("key", Enclave.Kind.SECRET, false));
        assertEquals("not json", Files.readString(file));

        // That isn't a PIN problem, so unlocking mustn't report it as one.
        var error = assertThrows(LuaException.class, () -> enclave.unlock(PIN));
        assertFalse(error instanceof Enclave.PinException, "Unreadable enclave should not be a PIN error");
    }

    @Test
    public void pinFailuresArePinExceptions() throws LuaException {
        var enclave = open();
        assertThrows(Enclave.PinException.class, () -> enclave.unlock(PIN));
        enclave.setPin(PIN, null);
        assertThrows(Enclave.PinException.class, () -> enclave.unlock(WRONG_PIN));
    }

    @Test
    public void importsUnclampedX25519Keys() throws LuaException {
        var enclave = open();
        var key = new byte[32];
        java.util.Arrays.fill(key, (byte) 0xff);
        assertArrayEquals(Crypto.publicKey(Crypto.KeyKind.X25519, key), enclave.importKey("dh", Enclave.Kind.X25519, key, false));
    }

    private static void assertThat(String actual, String expected) {
        assertEquals(expected, actual);
    }
}
