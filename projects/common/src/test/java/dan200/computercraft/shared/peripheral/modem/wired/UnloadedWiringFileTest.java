// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wired;

import dan200.computercraft.impl.network.wired.DormantWiring;
import it.unimi.dsi.fastutil.longs.LongOpenHashSet;
import it.unimi.dsi.fastutil.longs.LongSet;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.ChunkPos;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import java.util.zip.GZIPOutputStream;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Reading and writing the wiring file, above all files which aren't what was written: whatever is in one, reading it
 * gives what was saved or nothing, and never fails.
 */
public class UnloadedWiringFileTest {
    private interface Contents {
        void write(DataOutputStream output) throws IOException;
    }

    private static byte[] gzip(Contents contents) throws IOException {
        var bytes = new ByteArrayOutputStream();
        try (var output = new DataOutputStream(new GZIPOutputStream(bytes))) {
            contents.write(output);
        }
        return bytes.toByteArray();
    }

    private static Map<String, List<DormantWiring.Ports>> read(Path dir, byte[] contents) throws IOException {
        var file = dir.resolve("wiring.dat");
        Files.write(file, contents);
        return UnloadedWiring.read(file);
    }

    // Ports hold arrays, and so aren't equal to others with the same contents: compare them as lists.
    private static Map<String, List<List<Object>>> plain(Map<String, List<DormantWiring.Ports>> dimensions) {
        var result = new TreeMap<String, List<List<Object>>>();
        for (var dimension : dimensions.entrySet()) {
            var pieces = new ArrayList<List<Object>>();
            for (var piece : dimension.getValue()) {
                var positions = new ArrayList<Long>();
                for (var position : piece.positions()) positions.add(position);
                var sides = new ArrayList<Byte>();
                for (var side : piece.sides()) sides.add(side);
                pieces.add(List.of(piece.chunk(), positions, sides));
            }
            result.put(dimension.getKey(), pieces);
        }
        return result;
    }

    // Pieces in chunks anywhere in a world, with ports anywhere in their chunks.
    private static List<DormantWiring.Ports> randomPieces(Random random, int pieces, int maxPorts) {
        var list = new ArrayList<DormantWiring.Ports>();
        for (var p = 0; p < pieces; p++) {
            int chunkX = random.nextInt(2 * 1_800_000) - 1_800_000, chunkZ = random.nextInt(2 * 1_800_000) - 1_800_000;
            var ports = 1 + random.nextInt(maxPorts);
            var positions = new long[ports];
            var sides = new byte[ports];
            for (var i = 0; i < ports; i++) {
                positions[i] = BlockPos.asLong(chunkX * 16 + random.nextInt(16), random.nextInt(4096) - 2048, chunkZ * 16 + random.nextInt(16));
                sides[i] = (byte) random.nextInt(256);
            }
            list.add(new DormantWiring.Ports(ChunkPos.pack(chunkX, chunkZ), positions, sides));
        }
        return list;
    }

    private static Map<String, List<DormantWiring.Ports>> randomWiring(Random random, int dimensions, int pieces, int maxPorts) {
        var result = new TreeMap<String, List<DormantWiring.Ports>>();
        for (var d = 0; d < dimensions; d++) result.put("test:dimension_" + d, randomPieces(random, pieces, maxPorts));
        return result;
    }

    @Test
    public void readsBackWhatWasWritten(@TempDir Path dir) {
        var file = dir.resolve("computercraft").resolve("wiring.dat");
        var random = new Random(1);

        // Many small pieces, a few with very many ports, a dimension with none, and the largest and smallest numbers.
        var wiring = randomWiring(random, 5, 2000, 4);
        wiring.put("test:large", randomPieces(random, 3, 100_000));
        wiring.put("test:empty", List.of());
        wiring.put("test:extremes", List.of(
            new DormantWiring.Ports(ChunkPos.pack(-2097152, -2097152), new long[]{ BlockPos.asLong(-33554432, -2048, -33554432) }, new byte[]{ -128 }),
            new DormantWiring.Ports(ChunkPos.pack(2097151, 2097151), new long[]{ BlockPos.asLong(33554431, 2047, 33554431) }, new byte[]{ 127 }),
            new DormantWiring.Ports(0, new long[]{ 0, BlockPos.asLong(15, -1, 15) }, new byte[]{ 0, -1 })
        ));

        UnloadedWiring.write(file, wiring);
        assertEquals(plain(wiring), plain(UnloadedWiring.read(file)));

        // Writing again replaces the file, and leaves no other behind.
        var smaller = randomWiring(random, 1, 1, 1);
        UnloadedWiring.write(file, smaller);
        assertEquals(plain(smaller), plain(UnloadedWiring.read(file)));
        UnloadedWiring.write(file, Map.of());
        assertEquals(Map.of(), UnloadedWiring.read(file));
        assertEquals(List.of("wiring.dat"), Arrays.asList(Objects.requireNonNull(file.getParent().toFile().list())));
    }

    @Test
    public void readsNothingFromFilesWhichArentWiring(@TempDir Path dir) throws IOException {
        var json = "{ \"minecraft:overworld\": [] }".getBytes(StandardCharsets.UTF_8);

        assertEquals(Map.of(), read(dir, new byte[0]), "An empty file");
        assertEquals(Map.of(), read(dir, new byte[]{ 0x1f }), "Half of gzip's magic number");
        assertEquals(Map.of(), read(dir, gzip(output -> {
        })), "Nothing, compressed");
        assertEquals(Map.of(), read(dir, json), "JSON");
        assertEquals(Map.of(), read(dir, gzip(output -> output.write(json))), "JSON, compressed");
        // NBT, as Minecraft's own compressed files are.
        assertEquals(Map.of(), read(dir, gzip(output -> {
            output.writeByte(10);
            output.writeUTF("");
            output.writeByte(0);
        })), "NBT");

        var random = new Random(2);
        for (var i = 0; i < 200; i++) {
            var bytes = new byte[random.nextInt(200)];
            random.nextBytes(bytes);
            assertEquals(Map.of(), read(dir, bytes), "Random bytes");
            assertEquals(Map.of(), read(dir, gzip(output -> output.write(bytes))), "Random bytes, compressed");
        }

        // A folder where the file should be.
        Files.createDirectory(dir.resolve("folder.dat"));
        assertEquals(Map.of(), UnloadedWiring.read(dir.resolve("folder.dat")));
    }

    @Test
    public void readsNothingFromFilesOfOtherVersions(@TempDir Path dir) throws IOException {
        for (var version : new int[]{ 0, 3, -1, Integer.MAX_VALUE }) {
            assertEquals(Map.of(), read(dir, gzip(output -> {
                output.writeInt(version);
                output.writeInt(1);
                output.writeUTF("minecraft:overworld");
                output.writeInt(0);
            })), "Version " + version);
        }
    }

    /**
     * More dimensions, pieces or ports than the file holds, or fewer than none: nothing is read, and no room is made
     * for that many.
     *
     * @param dir A directory for the file.
     * @throws IOException If the file can't be written.
     */
    @Test
    public void readsNothingFromFilesWithImpossibleCounts(@TempDir Path dir) throws IOException {
        for (var count : new int[]{ -1, Integer.MIN_VALUE, Integer.MAX_VALUE, 1 << 24, 5, 0 }) {
            if (count != 0) {
                assertEquals(Map.of(), read(dir, gzip(output -> {
                    output.writeInt(1);
                    output.writeInt(count);
                })), "Dimensions: " + count);

                assertEquals(Map.of(), read(dir, gzip(output -> {
                    output.writeInt(1);
                    output.writeInt(1);
                    output.writeUTF("minecraft:overworld");
                    output.writeInt(count);
                })), "Pieces: " + count);
            }

            // A piece has at least one port.
            assertEquals(Map.of(), read(dir, gzip(output -> {
                output.writeInt(1);
                output.writeInt(1);
                output.writeUTF("minecraft:overworld");
                output.writeInt(1);
                output.writeLong(0);
                output.writeInt(count);
            })), "Ports: " + count);
        }
    }

    @Test
    public void readsNothingFromFilesCutShort(@TempDir Path dir) throws IOException {
        var file = dir.resolve("wiring.dat");
        UnloadedWiring.write(file, randomWiring(new Random(3), 3, 20, 3));
        var bytes = Files.readAllBytes(file);
        for (var length = 0; length < bytes.length; length++) {
            assertEquals(Map.of(), read(dir, Arrays.copyOf(bytes, length)), "Cut to " + length + " of " + bytes.length + " bytes");
        }

        // Cut short before it was compressed, too: in the middle of a name or a piece, and between dimensions.
        var whole = new ByteArrayOutputStream();
        try (var output = new DataOutputStream(whole)) {
            output.writeInt(1);
            output.writeInt(2);
            for (var name : new String[]{ "minecraft:overworld", "minecraft:the_nether" }) {
                output.writeUTF(name);
                output.writeInt(2);
                for (var i = 0; i < 2; i++) {
                    output.writeLong(0);
                    output.writeInt(1);
                    output.writeLong(BlockPos.asLong(i, 64, i));
                    output.writeByte(4);
                }
            }
        }
        var wholeBytes = whole.toByteArray();
        for (var length = 0; length < wholeBytes.length; length++) {
            var cut = Arrays.copyOf(wholeBytes, length);
            assertEquals(Map.of(), read(dir, gzip(output -> output.write(cut))), "Cut to " + length + " of " + wholeBytes.length + " bytes");
        }
        assertEquals(2, read(dir, gzip(output -> output.write(wholeBytes))).size());
    }

    /**
     * A file which has been damaged holds what was saved (if the damage was to something which doesn't matter), or
     * nothing: never wiring which wasn't saved, which would connect networks which aren't.
     *
     * @param dir A directory for the file.
     * @throws IOException If the file can't be written.
     */
    @Test
    public void readsNothingWrongFromDamagedFiles(@TempDir Path dir) throws IOException {
        var file = dir.resolve("wiring.dat");
        var wiring = randomWiring(new Random(4), 2, 30, 3);
        UnloadedWiring.write(file, wiring);
        var bytes = Files.readAllBytes(file);
        var expected = plain(wiring);

        for (var i = 0; i < bytes.length; i++) {
            for (var bit : new int[]{ 0x01, 0x10, 0x80 }) {
                var damaged = bytes.clone();
                damaged[i] ^= (byte) bit;
                var read = plain(read(dir, damaged));
                if (!read.isEmpty()) assertEquals(expected, read, "With bit " + bit + " of byte " + i + " changed");
            }
        }

        // Something more after the wiring isn't a file we wrote, either.
        assertEquals(Map.of(), read(dir, gzip(output -> {
            output.writeInt(1);
            output.writeInt(0);
            output.writeByte(0);
        })));
    }

    @Test
    public void skipsDimensionsWhoseNamesArentNames(@TempDir Path dir) throws IOException {
        var read = read(dir, gzip(output -> {
            output.writeInt(1);
            output.writeInt(3);
            for (var name : new String[]{ "Not A Dimension", "minecraft:overworld", "a:b:c" }) {
                output.writeUTF(name);
                output.writeInt(1);
                output.writeLong(ChunkPos.pack(7, 0));
                output.writeInt(1);
                output.writeLong(BlockPos.asLong(7 * 16 + 9, 64, 0));
                output.writeByte(4);
            }
        }));
        assertEquals(Set.of("minecraft:overworld"), read.keySet());
        assertEquals(ChunkPos.pack(7, 0), read.get("minecraft:overworld").get(0).chunk());
    }

    @Test
    public void readsNothingFromFilesWithAPortOutsideItsChunk(@TempDir Path dir) throws IOException {
        // A port one block past the chunk's edge: only a file made by hand has one, and it would join what isn't joined.
        assertEquals(Map.of(), read(dir, gzip(output -> {
            output.writeInt(1);
            output.writeInt(1);
            output.writeUTF("minecraft:overworld");
            output.writeInt(1);
            output.writeLong(ChunkPos.pack(0, 0));
            output.writeInt(2);
            output.writeLong(BlockPos.asLong(15, 64, 0));
            output.writeByte(4);
            output.writeLong(BlockPos.asLong(16, 64, 0));
            output.writeByte(4);
        })));
    }

    @Test
    public void readsBackChunksWithNoWiring(@TempDir Path dir) {
        var file = dir.resolve("wiring.dat");
        var random = new Random(7);
        var wiring = randomWiring(random, 2, 5, 3);
        var empty = new TreeMap<String, LongSet>();
        empty.put("test:dimension_0", new LongOpenHashSet(new long[]{ ChunkPos.pack(1, 2), ChunkPos.pack(-3, 4) }));
        // A dimension may have chunks with no wiring, and no wiring.
        empty.put("test:only_empty", new LongOpenHashSet(new long[]{ 0 }));

        assertTrue(UnloadedWiring.write(file, wiring, empty));
        var contents = UnloadedWiring.readAll(file);
        var pieces = new TreeMap<>(wiring);
        pieces.put("test:only_empty", List.of());
        assertEquals(plain(pieces), plain(contents.pieces()));
        assertEquals(empty, new TreeMap<>(contents.empty()));
    }

    @Test
    public void readsFilesOfTheFirstVersion(@TempDir Path dir) throws IOException {
        var read = read(dir, gzip(output -> {
            output.writeInt(1);
            output.writeInt(1);
            output.writeUTF("minecraft:overworld");
            output.writeInt(1);
            output.writeLong(0);
            output.writeInt(1);
            output.writeLong(BlockPos.asLong(3, 64, 4));
            output.writeByte(4);
        }));
        assertEquals(Set.of("minecraft:overworld"), read.keySet());
        assertEquals(1, read.get("minecraft:overworld").size());
    }

    @Test
    public void doesNotFailWhenItCannotWrite(@TempDir Path dir) throws IOException {
        var wiring = randomWiring(new Random(5), 1, 1, 1);

        // The folder the file should be in is a file.
        var notAFolder = dir.resolve("computercraft");
        Files.writeString(notAFolder, "in the way");
        assertFalse(UnloadedWiring.write(notAFolder.resolve("wiring.dat"), wiring), "Says it wasn't written");
        assertEquals("in the way", Files.readString(notAFolder));

        // The file is a folder, with something in it: what's there stays.
        var file = dir.resolve("wiring.dat");
        Files.createDirectories(file.resolve("inside"));
        UnloadedWiring.write(file, wiring);
        assertTrue(Files.isDirectory(file.resolve("inside")));
        assertEquals(Map.of(), UnloadedWiring.read(file));
    }

    /**
     * Wiring of dimensions which haven't been used since the server started (or are no longer there) is kept as it was
     * read, and nothing is written while nothing changes.
     *
     * @param dir A directory for the file.
     * @throws IOException If the file can't be written.
     */
    @Test
    public void keepsWiringOfDimensionsNeverUsed(@TempDir Path dir) throws IOException {
        var file = dir.resolve("computercraft").resolve("wiring.dat");

        // With no file, and nothing changed, ticking writes none.
        var empty = new UnloadedWiring(file);
        for (var i = 0; i < 3 * 20 * 60; i++) empty.tick();
        assertFalse(Files.exists(file));

        var wiring = randomWiring(new Random(6), 3, 10, 3);
        UnloadedWiring.write(file, wiring);
        var bytes = Files.readAllBytes(file);

        var unloaded = new UnloadedWiring(file);
        Files.delete(file);
        for (var i = 0; i < 3 * 20 * 60; i++) unloaded.tick();
        assertFalse(Files.exists(file), "Not written again");

        // Saving (as when the server stops) writes it all back.
        unloaded.save();
        assertEquals(plain(wiring), plain(UnloadedWiring.read(file)));
        assertArrayEquals(bytes, Files.readAllBytes(file), "The same wiring makes the same file");
    }
}
