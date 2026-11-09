// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.core.crypto;

import org.junit.jupiter.api.Test;

import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.InvalidKeyException;
import java.util.HexFormat;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Tests for {@link Crypto}, mostly against the test vectors published with each algorithm's RFC.
 */
public class CryptoTest {
    private static final HexFormat HEX = HexFormat.of();

    private static byte[] hex(String hex) {
        return HEX.parseHex(hex);
    }

    private static byte[] ascii(String text) {
        return text.getBytes(StandardCharsets.US_ASCII);
    }

    private static byte[] repeat(int value, int length) {
        var bytes = new byte[length];
        java.util.Arrays.fill(bytes, (byte) value);
        return bytes;
    }

    @Test
    public void sha256() {
        assertArrayEquals(hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), Crypto.sha256(ascii("abc")));
    }

    @Test
    public void hmacRfc4231() {
        assertArrayEquals(
            hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"),
            Crypto.hmac(repeat(0x0b, 20), ascii("Hi There"))
        );
        assertArrayEquals(
            hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"),
            Crypto.hmac(ascii("Jefe"), ascii("what do ya want for nothing?"))
        );
    }

    @Test
    public void hmacEmptyKey() {
        assertArrayEquals(
            hex("b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad"),
            Crypto.hmac(new byte[0], new byte[0])
        );
    }

    @Test
    public void hkdfRfc5869() {
        // Test case 1
        assertArrayEquals(
            hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"),
            Crypto.hkdf(repeat(0x0b, 22), hex("000102030405060708090a0b0c"), hex("f0f1f2f3f4f5f6f7f8f9"), 42)
        );
        // Test case 3: no salt or info.
        assertArrayEquals(
            hex("8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"),
            Crypto.hkdf(repeat(0x0b, 22), new byte[0], new byte[0], 42)
        );
    }

    @Test
    public void pbkdf2Rfc7914() {
        assertArrayEquals(
            hex("55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783"),
            Crypto.pbkdf2(ascii("passwd"), ascii("salt"), 1, 64)
        );
    }

    @Test
    public void pbkdf2MatchesJdk() throws Exception {
        // The JDK's version only takes text passwords, but should agree with ours on them.
        var factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256");
        var expected = factory.generateSecret(new PBEKeySpec("Password".toCharArray(), ascii("NaCl"), 2000, 40 * 8)).getEncoded();
        assertArrayEquals(expected, Crypto.pbkdf2(ascii("Password"), ascii("NaCl"), 2000, 40));
    }

    private static final byte[] ALICE_PRIVATE = hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
    private static final byte[] ALICE_PUBLIC = hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");
    private static final byte[] BOB_PRIVATE = hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
    private static final byte[] BOB_PUBLIC = hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
    private static final byte[] SHARED = hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742");

    @Test
    public void x25519PublicKeyRfc7748() {
        assertArrayEquals(ALICE_PUBLIC, Crypto.publicKey(Crypto.KeyKind.X25519, ALICE_PRIVATE));
        assertArrayEquals(BOB_PUBLIC, Crypto.publicKey(Crypto.KeyKind.X25519, BOB_PRIVATE));
    }

    @Test
    public void x25519ExchangeRfc7748() throws InvalidKeyException {
        assertArrayEquals(SHARED, Crypto.exchange(Crypto.privateKey(Crypto.KeyKind.X25519, ALICE_PRIVATE), BOB_PUBLIC));
        assertArrayEquals(SHARED, Crypto.exchange(Crypto.privateKey(Crypto.KeyKind.X25519, BOB_PRIVATE), ALICE_PUBLIC));
    }

    @Test
    public void x25519AcceptsUnclampedScalars() throws InvalidKeyException {
        // X25519 clamps private keys when they're used. Imported keys needn't be clamped already, so check one which
        // isn't gives the same results whichever way round the exchange is done.
        var unclamped = repeat(0xff, 32);
        var publicKey = Crypto.publicKey(Crypto.KeyKind.X25519, unclamped);
        var other = Crypto.generateKeyPair(Crypto.KeyKind.X25519);
        assertArrayEquals(
            Crypto.exchange(Crypto.privateKey(Crypto.KeyKind.X25519, unclamped), other.publicKey()),
            Crypto.exchange(Crypto.privateKey(Crypto.KeyKind.X25519, other.privateKey()), publicKey)
        );
    }

    @Test
    public void x25519RejectsLowOrderPoints() {
        // u = 0 is a point of small order, which would give an all-zero secret.
        var key = Crypto.privateKey(Crypto.KeyKind.X25519, ALICE_PRIVATE);
        assertThrows(InvalidKeyException.class, () -> Crypto.exchange(key, new byte[32]));
    }

    @Test
    public void ed25519Rfc8032() {
        // Test 1: the empty message.
        var secret1 = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
        var public1 = hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
        var signature1 = hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b");
        assertArrayEquals(public1, Crypto.publicKey(Crypto.KeyKind.ED25519, secret1));
        assertArrayEquals(signature1, Crypto.sign(Crypto.privateKey(Crypto.KeyKind.ED25519, secret1), new byte[0]));
        assertTrue(Crypto.verify(public1, new byte[0], signature1));

        // Test 2: a one-byte message.
        var secret2 = hex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb");
        var public2 = hex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c");
        var signature2 = hex("92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00");
        assertArrayEquals(public2, Crypto.publicKey(Crypto.KeyKind.ED25519, secret2));
        assertArrayEquals(signature2, Crypto.sign(Crypto.privateKey(Crypto.KeyKind.ED25519, secret2), hex("72")));
        assertTrue(Crypto.verify(public2, hex("72"), signature2));

        // Tampering with anything fails.
        assertFalse(Crypto.verify(public2, hex("73"), signature2));
        assertFalse(Crypto.verify(public1, hex("72"), signature2));
        assertFalse(Crypto.verify(public2, hex("72"), new byte[10]));
    }

    private static final byte[] AEAD_KEY = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
    private static final byte[] AEAD_NONCE = hex("070000004041424344454647");
    private static final byte[] AEAD_AAD = hex("50515253c0c1c2c3c4c5c6c7");
    private static final byte[] AEAD_PLAINTEXT = ascii("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.");
    private static final byte[] AEAD_SEALED = hex(
        "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116"
            + "1ae10b594f09e26a7e902ecbd0600691"
    );

    @Test
    public void chaCha20Poly1305Rfc8439() {
        assertArrayEquals(AEAD_SEALED, Crypto.seal(AEAD_KEY, AEAD_NONCE, AEAD_PLAINTEXT, AEAD_AAD));
        assertArrayEquals(AEAD_PLAINTEXT, Crypto.open(AEAD_KEY, AEAD_NONCE, AEAD_SEALED, AEAD_AAD));
    }

    @Test
    public void openRejectsTampering() {
        var tampered = AEAD_SEALED.clone();
        tampered[5] ^= 1;
        assertNull(Crypto.open(AEAD_KEY, AEAD_NONCE, tampered, AEAD_AAD));
        assertNull(Crypto.open(AEAD_KEY, AEAD_NONCE, AEAD_SEALED, new byte[0]));
        assertNull(Crypto.open(AEAD_KEY, hex("000000000000000000000000"), AEAD_SEALED, AEAD_AAD));
        assertNull(Crypto.open(AEAD_KEY, AEAD_NONCE, new byte[3], AEAD_AAD));
    }

    @Test
    public void sealWorksRepeatedly() {
        // The JDK refuses to reuse a nonce on the same Cipher object. We make a new one each time, so sealing the same
        // message twice must work (even though callers shouldn't do it).
        assertArrayEquals(AEAD_SEALED, Crypto.seal(AEAD_KEY, AEAD_NONCE, AEAD_PLAINTEXT, AEAD_AAD));
        assertArrayEquals(AEAD_SEALED, Crypto.seal(AEAD_KEY, AEAD_NONCE, AEAD_PLAINTEXT, AEAD_AAD));
    }

    @Test
    public void generatedKeyPairsAreConsistent() throws InvalidKeyException {
        for (var kind : Crypto.KeyKind.values()) {
            var pair = Crypto.generateKeyPair(kind);
            assertEquals(32, pair.privateKey().length);
            assertArrayEquals(pair.publicKey(), Crypto.publicKey(kind, pair.privateKey()), kind + " public key");
        }

        var a = Crypto.generateKeyPair(Crypto.KeyKind.X25519);
        var b = Crypto.generateKeyPair(Crypto.KeyKind.X25519);
        assertArrayEquals(
            Crypto.exchange(Crypto.privateKey(Crypto.KeyKind.X25519, a.privateKey()), b.publicKey()),
            Crypto.exchange(Crypto.privateKey(Crypto.KeyKind.X25519, b.privateKey()), a.publicKey())
        );
    }

    @Test
    public void constantTimeEquals() {
        assertTrue(Crypto.constantTimeEquals(hex("0102"), hex("0102")));
        assertFalse(Crypto.constantTimeEquals(hex("0102"), hex("0103")));
        assertFalse(Crypto.constantTimeEquals(hex("0102"), hex("010203")));
    }
}
