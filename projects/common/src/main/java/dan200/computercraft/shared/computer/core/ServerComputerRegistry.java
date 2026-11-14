// Copyright Daniel Ratcliffe, 2011-2022. Do not distribute without permission.
//
// SPDX-License-Identifier: LicenseRef-CCPL

package dan200.computercraft.shared.computer.core;

import it.unimi.dsi.fastutil.objects.Object2IntMap;
import it.unimi.dsi.fastutil.objects.Object2IntOpenHashMap;
import org.jspecify.annotations.Nullable;

import java.util.*;

public class ServerComputerRegistry {
    private static final Random RANDOM = new Random();

    /**
     * How long, in ticks, a computer may be handed over to another block for. See {@link #reserve(UUID)}.
     * <p>
     * This must be at least two: a block entity added during a tick first ticks on the next one, after
     * {@link #update()}.
     */
    static final int HAND_OVER_TICKS = 20;

    private final int sessionId = RANDOM.nextInt();
    private final Map<UUID, ServerComputer> computersByInstanceUuid = new HashMap<>();

    /** Computers which a newly loaded block wants to take over, and for how many more ticks. */
    private final Object2IntMap<UUID> reserved = new Object2IntOpenHashMap<>();

    /** Computers whose block was removed while another wanted them, and how many more ticks they're kept for. */
    private final Object2IntMap<UUID> released = new Object2IntOpenHashMap<>();

    public int getSessionID() {
        return sessionId;
    }

    @Nullable
    public ServerComputer get(@Nullable UUID instanceID) {
        return instanceID != null ? computersByInstanceUuid.get(instanceID) : null;
    }

    @Nullable
    public ServerComputer get(int sessionId, @Nullable UUID instanceId) {
        return sessionId == this.sessionId ? get(instanceId) : null;
    }

    void update() {
        var it = computersByInstanceUuid.values().iterator();
        while (it.hasNext()) {
            var computer = it.next();
            if (computer.hasTimedOut()) {
                computer.unload();
                computer.onRemoved();
                it.remove();
                computersByInstanceUuid.remove(computer.getInstanceUUID());
            } else {
                computer.tickServer();
            }
        }

        // Forget blocks which didn't take over their computer in time, and close computers nobody took over.
        countDown(reserved);
        for (var instance : countDown(released)) {
            var computer = computersByInstanceUuid.get(instance);
            if (computer != null) remove(computer);
        }
    }

    /**
     * Count down the ticks left for each computer in a map, removing those which have run out.
     *
     * @param ticks The ticks left for each computer.
     * @return The computers which ran out.
     */
    private static List<UUID> countDown(Object2IntMap<UUID> ticks) {
        if (ticks.isEmpty()) return List.of();

        List<UUID> expired = new ArrayList<>(0);
        var it = ticks.object2IntEntrySet().iterator();
        while (it.hasNext()) {
            var entry = it.next();
            var left = entry.getIntValue() - 1;
            if (left > 0) {
                entry.setValue(left);
            } else {
                it.remove();
                expired.add(entry.getKey());
            }
        }
        return expired;
    }

    void add(ServerComputer computer) {
        var instanceUUID = computer.getInstanceUUID();

        if (computersByInstanceUuid.containsKey(instanceUUID)) {
            throw new IllegalStateException("Duplicate computer " + instanceUUID);
        }

        computersByInstanceUuid.put(instanceUUID, computer);
    }

    void remove(ServerComputer computer) {
        computer.unload();
        computer.onRemoved();
        computersByInstanceUuid.remove(computer.getInstanceUUID());
        reserved.removeInt(computer.getInstanceUUID());
        released.removeInt(computer.getInstanceUUID());
    }

    void close() {
        for (var computer : getComputers()) computer.unload();
        computersByInstanceUuid.clear();
        reserved.clear();
        released.clear();
    }

    /**
     * Note that a newly loaded block would like to take over a running computer, as its block entity was copied from
     * that computer's.
     * <p>
     * Some mods move blocks by copying their block entity to the new position, and only then removing the original.
     * Sable does this when it turns blocks into a moving object. This lets the computer keep running through such a
     * move: the copy reserves the computer here, the original then {@linkplain #release(ServerComputer) releases} it
     * rather than shutting it down, and the copy {@linkplain #claim(UUID) claims} it when it next ticks.
     * <p>
     * Where the original isn't removed (for instance, if the block was copied with {@code /clone}), it never releases
     * the computer, and so the copy can't claim it, and starts its own.
     *
     * @param instanceID The instance ID of the computer.
     */
    public void reserve(UUID instanceID) {
        if (computersByInstanceUuid.containsKey(instanceID)) reserved.put(instanceID, HAND_OVER_TICKS);
    }

    /**
     * Give up a computer whose block was removed. If another block {@linkplain #reserve(UUID) wants} it, it is kept
     * running for that block to {@linkplain #claim(UUID) claim}, and closed if it doesn't in time.
     *
     * @param computer The computer.
     * @return Whether the computer is being handed over. If not, the caller should close it.
     */
    public boolean release(ServerComputer computer) {
        var instance = computer.getInstanceUUID();
        if (computersByInstanceUuid.get(instance) != computer || !reserved.containsKey(instance)) return false;

        reserved.removeInt(instance);
        released.put(instance, HAND_OVER_TICKS);
        return true;
    }

    /**
     * Take over a computer which this block {@linkplain #reserve(UUID) reserved}, if its old block has since
     * {@linkplain #release(ServerComputer) released} it.
     *
     * @param instanceID The instance ID of the computer.
     * @return The computer, or {@code null} if it wasn't released (and so is either gone, or still in use).
     */
    public @Nullable ServerComputer claim(UUID instanceID) {
        reserved.removeInt(instanceID);
        return released.removeInt(instanceID) > 0 ? computersByInstanceUuid.get(instanceID) : null;
    }

    public Collection<ServerComputer> getComputers() {
        return computersByInstanceUuid.values();
    }
}
