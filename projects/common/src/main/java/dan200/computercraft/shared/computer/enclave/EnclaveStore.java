// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.computer.enclave;

import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

/**
 * Every computer's {@link Enclave}, stored by computer ID in one directory of the world save.
 * <p>
 * Storing keys by ID means they move with a computer when it's broken and placed again, as its files do. The directory
 * isn't part of any computer's file system, so programs can't read it.
 */
public final class EnclaveStore {
    private final Path directory;
    private final Map<Integer, Enclave> enclaves = new HashMap<>();

    public EnclaveStore(Path directory) {
        this.directory = directory;
    }

    /**
     * Get a computer's enclave. Its file is only read when it's first used.
     *
     * @param computerId The computer's ID.
     * @return The computer's enclave.
     */
    public synchronized Enclave get(int computerId) {
        return enclaves.computeIfAbsent(computerId, id -> new Enclave(directory.resolve(id + ".json"), System::currentTimeMillis));
    }
}
