// SPDX-FileCopyrightText: 2018 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.core.filesystem;

import com.google.common.io.Files;
import dan200.computercraft.api.filesystem.MountConstants;
import dan200.computercraft.api.filesystem.WritableMount;
import dan200.computercraft.api.lua.LuaException;
import dan200.computercraft.api.lua.ObjectArguments;
import dan200.computercraft.core.TestFiles;
import dan200.computercraft.core.apis.handles.ReadHandle;
import dan200.computercraft.core.apis.handles.WriteHandle;
import dan200.computercraft.core.computer.TimeoutState;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.SeekableByteChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.OpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.List;
import java.util.Set;

import static org.hamcrest.MatcherAssert.assertThat;
import static org.hamcrest.Matchers.greaterThan;
import static org.junit.jupiter.api.Assertions.*;

public class FileSystemTest {
    private static final File ROOT = TestFiles.get("filesystem").toFile();
    private static final long CAPACITY = 1000000;

    private static FileSystem mkFs() throws FileSystemException {
        WritableMount writableMount = new WritableFileMount(ROOT, CAPACITY);
        return new FileSystem("hdd", writableMount);

    }

    /**
     * Ensures writing a file truncates it.
     *
     * @throws FileSystemException When the file system cannot be constructed.
     * @throws LuaException        When Lua functions fail.
     * @throws IOException         When reading and writing from strings
     */
    @Test
    public void testWriteTruncates() throws FileSystemException, LuaException, IOException {
        var fs = mkFs();

        {
            var writer = fs.openForWrite("out.txt", MountConstants.WRITE_OPTIONS);
            var handle = WriteHandle.of(writer.get(), writer, false, true);
            handle.write(new ObjectArguments("This is a long line"));
            handle.close();
        }

        assertEquals("This is a long line", Files.asCharSource(new File(ROOT, "out.txt"), StandardCharsets.UTF_8).read());

        {
            var writer = fs.openForWrite("out.txt", MountConstants.WRITE_OPTIONS);
            var handle = WriteHandle.of(writer.get(), writer, false, true);
            handle.write(new ObjectArguments("Tiny line"));
            handle.close();
        }

        assertEquals("Tiny line", Files.asCharSource(new File(ROOT, "out.txt"), StandardCharsets.UTF_8).read());
    }

    @Test
    public void testUnmountCloses() throws FileSystemException {
        var fs = mkFs();
        WritableMount mount = new WritableFileMount(new File(ROOT, "child"), CAPACITY);
        fs.mountWritable("disk", "disk", mount);

        var writer = fs.openForWrite("disk/out.txt", MountConstants.WRITE_OPTIONS);
        var handle = WriteHandle.of(writer.get(), writer, false, true);

        fs.unmount("disk");

        var err = assertThrows(LuaException.class, () -> handle.write(new ObjectArguments("Tiny line")));
        assertEquals("attempt to use a closed file", err.getMessage());
    }

    /**
     * Everything a computer's file system does on the disk (opening, reading, writing, closing, listing, moving...)
     * comes within a wait the computer's timeout is told of, so a stalling disk doesn't time the computer out.
     *
     * @throws FileSystemException When the file system cannot be constructed.
     * @throws LuaException        When Lua functions fail.
     */
    @Test
    public void testDiskWaitsAreMarked() throws FileSystemException, LuaException {
        var timeout = new CountingTimeout();
        var mount = new CheckedMount(new WritableFileMount(new File(ROOT, "waits"), CAPACITY), timeout);
        var fs = new FileSystem("hdd", mount, timeout);

        if (fs.exists("dir")) fs.delete("dir");
        fs.makeDir("dir");
        {
            var writer = fs.openForWrite("dir/a.txt", MountConstants.WRITE_OPTIONS);
            var handle = WriteHandle.of(writer.get(), writer, false, true);
            handle.write(new ObjectArguments("Some text"));
            handle.flush();
            handle.close();
        }
        {
            var writer = fs.openForWrite("dir/a.txt", MountConstants.APPEND_OPTIONS);
            var handle = WriteHandle.of(writer.get(), writer, false, false);
            handle.write(new ObjectArguments(", and more"));
            handle.close();
        }
        assertTrue(fs.exists("dir/a.txt"));
        assertTrue(fs.isDir("dir"));
        assertEquals(19, fs.getSize("dir/a.txt"));
        assertEquals(19, fs.getAttributes("dir/a.txt").size());
        assertEquals(List.of("a.txt"), fs.list("dir"));
        {
            var reader = fs.openForRead("dir/a.txt");
            var handle = new ReadHandle(reader.get(), reader, false);
            var read = handle.readAll();
            assertNotNull(read);
            assertArrayEquals("Some text, and more".getBytes(StandardCharsets.UTF_8), (byte[]) read[0]);
            handle.close();
        }
        fs.copy("dir/a.txt", "dir/b.txt");
        fs.move("dir/b.txt", "dir/c.txt");
        fs.delete("dir/c.txt");
        fs.isReadOnly("dir/a.txt");
        fs.getFreeSpace("dir");
        fs.getCapacity("dir");

        // A file left open is closed once the file system is.
        fs.openForWrite("dir/d.txt", MountConstants.WRITE_OPTIONS);
        fs.close();

        assertEquals(0, timeout.depth, "Every wait should end");
        assertThat("The mount should have been used", mount.calls, greaterThan(20));
    }

    /**
     * A timeout which keeps count of how deep in waits on the disk the file system is.
     */
    private static final class CountingTimeout extends TimeoutState {
        int depth;

        @Override
        public void refresh() {
        }

        @Override
        public void startBlocking() {
            depth++;
        }

        @Override
        public void stopBlocking() {
            depth--;
        }
    }

    /**
     * A mount which checks it, and the files it opens, are only used within a wait on the disk.
     */
    private static final class CheckedMount implements WritableMount {
        private final WritableMount mount;
        private final CountingTimeout timeout;
        int calls;

        CheckedMount(WritableMount mount, CountingTimeout timeout) {
            this.mount = mount;
            this.timeout = timeout;
        }

        private void check() {
            calls++;
            assertThat("Disk used outside a wait", timeout.depth, greaterThan(0));
        }

        @Override
        public boolean exists(String path) throws IOException {
            check();
            return mount.exists(path);
        }

        @Override
        public boolean isDirectory(String path) throws IOException {
            check();
            return mount.isDirectory(path);
        }

        @Override
        public void list(String path, List<String> contents) throws IOException {
            check();
            mount.list(path, contents);
        }

        @Override
        public long getSize(String path) throws IOException {
            check();
            return mount.getSize(path);
        }

        @Override
        public BasicFileAttributes getAttributes(String path) throws IOException {
            check();
            return mount.getAttributes(path);
        }

        @Override
        public SeekableByteChannel openForRead(String path) throws IOException {
            check();
            return new CheckedChannel(mount.openForRead(path));
        }

        @Override
        public void makeDirectory(String path) throws IOException {
            check();
            mount.makeDirectory(path);
        }

        @Override
        public void delete(String path) throws IOException {
            check();
            mount.delete(path);
        }

        @Override
        public void rename(String source, String dest) throws IOException {
            check();
            mount.rename(source, dest);
        }

        @Override
        public SeekableByteChannel openFile(String path, Set<OpenOption> options) throws IOException {
            check();
            return new CheckedChannel(mount.openFile(path, options));
        }

        @Override
        public long getRemainingSpace() throws IOException {
            check();
            return mount.getRemainingSpace();
        }

        @Override
        public long getCapacity() {
            check();
            return mount.getCapacity();
        }

        @Override
        public boolean isReadOnly(String path) throws IOException {
            check();
            return mount.isReadOnly(path);
        }

        private final class CheckedChannel implements SeekableByteChannel {
            private final SeekableByteChannel channel;

            CheckedChannel(SeekableByteChannel channel) {
                this.channel = channel;
            }

            @Override
            public int read(ByteBuffer dst) throws IOException {
                check();
                return channel.read(dst);
            }

            @Override
            public int write(ByteBuffer src) throws IOException {
                check();
                return channel.write(src);
            }

            @Override
            public long position() throws IOException {
                check();
                return channel.position();
            }

            @Override
            public SeekableByteChannel position(long newPosition) throws IOException {
                check();
                channel.position(newPosition);
                return this;
            }

            @Override
            public long size() throws IOException {
                check();
                return channel.size();
            }

            @Override
            public SeekableByteChannel truncate(long size) throws IOException {
                check();
                channel.truncate(size);
                return this;
            }

            @Override
            public boolean isOpen() {
                return channel.isOpen();
            }

            @Override
            public void close() throws IOException {
                check();
                channel.close();
            }
        }
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("sanitiseCases")
    public void testSanitize(String input, String output) {
        assertEquals(output, FileSystem.sanitizePath(input, false));
    }

    public static String[][] sanitiseCases() {
        return new String[][]{
            new String[]{ "a//b", "a/b" },
            new String[]{ "a/./b", "a/b" },
            new String[]{ "a/../b", "b" },
            new String[]{ "a/.../b", "a/b" },
            new String[]{ "a/. ./b", "a/b" },
            new String[]{ " a ", "a" },
            new String[]{ "a b c", "a b c" },
        };
    }
}
