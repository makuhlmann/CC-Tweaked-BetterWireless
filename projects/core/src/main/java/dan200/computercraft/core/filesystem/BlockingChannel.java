// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.core.filesystem;

import dan200.computercraft.core.computer.TimeoutState;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.channels.SeekableByteChannel;

/**
 * A computer's open file, which tells the computer's timeout whenever it waits on the disk: reading, writing, seeking
 * and closing.
 *
 * @see TimeoutState#startBlocking()
 */
public final class BlockingChannel implements SeekableByteChannel {
    private final SeekableByteChannel channel;
    private final TimeoutState timeout;

    BlockingChannel(SeekableByteChannel channel, TimeoutState timeout) {
        this.channel = channel;
        this.timeout = timeout;
    }

    @Override
    public int read(ByteBuffer dst) throws IOException {
        timeout.startBlocking();
        try {
            return channel.read(dst);
        } finally {
            timeout.stopBlocking();
        }
    }

    @Override
    public int write(ByteBuffer src) throws IOException {
        timeout.startBlocking();
        try {
            return channel.write(src);
        } finally {
            timeout.stopBlocking();
        }
    }

    @Override
    public long position() throws IOException {
        timeout.startBlocking();
        try {
            return channel.position();
        } finally {
            timeout.stopBlocking();
        }
    }

    @Override
    public SeekableByteChannel position(long newPosition) throws IOException {
        timeout.startBlocking();
        try {
            channel.position(newPosition);
            return this;
        } finally {
            timeout.stopBlocking();
        }
    }

    @Override
    public long size() throws IOException {
        timeout.startBlocking();
        try {
            return channel.size();
        } finally {
            timeout.stopBlocking();
        }
    }

    @Override
    public SeekableByteChannel truncate(long size) throws IOException {
        timeout.startBlocking();
        try {
            channel.truncate(size);
            return this;
        } finally {
            timeout.stopBlocking();
        }
    }

    /**
     * Write what's been written to the disk itself, if the file underneath can do that.
     *
     * @param metaData Whether to write the file's metadata too.
     * @throws IOException If it can't be written.
     * @see FileChannel#force(boolean)
     */
    public void force(boolean metaData) throws IOException {
        if (!(channel instanceof FileChannel file)) return;
        timeout.startBlocking();
        try {
            file.force(metaData);
        } finally {
            timeout.stopBlocking();
        }
    }

    @Override
    public boolean isOpen() {
        return channel.isOpen();
    }

    @Override
    public void close() throws IOException {
        timeout.startBlocking();
        try {
            channel.close();
        } finally {
            timeout.stopBlocking();
        }
    }
}
