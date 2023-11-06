// Copyright Daniel Ratcliffe, 2011-2022. Do not distribute without permission.
//
// SPDX-License-Identifier: LicenseRef-CCPL

package dan200.computercraft.shared.peripheral.modem.wireless;

import dan200.computercraft.api.network.Packet;
import dan200.computercraft.api.network.PacketNetwork;
import dan200.computercraft.api.network.PacketReceiver;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Vec3i;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.phys.Vec3;

import java.util.Collections;
import java.util.Objects;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

public class WirelessNetwork implements PacketNetwork {
    private final Set<PacketReceiver> receivers = Collections.newSetFromMap(new ConcurrentHashMap<>());

    @Override
    public void addReceiver(PacketReceiver receiver) {
        Objects.requireNonNull(receiver, "device cannot be null");
        receivers.add(receiver);
    }

    @Override
    public void removeReceiver(PacketReceiver receiver) {
        Objects.requireNonNull(receiver, "device cannot be null");
        receivers.remove(receiver);
    }

    @Override
    public void transmitSameDimension(Packet packet, double range) {
        Objects.requireNonNull(packet, "packet cannot be null");
        for (var device : receivers) tryTransmit(device, packet, range, false);
    }

    @Override
    public void transmitInterdimensional(Packet packet) {
        Objects.requireNonNull(packet, "packet cannot be null");
        for (var device : receivers) tryTransmit(device, packet, 0, true);
    }

    private static Vec3 floorVec3(Vec3 vector) {
        return new Vec3(Math.floor(vector.x), Math.floor(vector.y), Math.floor(vector.z));
    }

    private static Vec3 roundVec3(Vec3 vector) {
        return new Vec3(Math.round(vector.x), Math.round(vector.y), Math.round(vector.z));
    }

    private static Vec3i roundToVec3i(Vec3 vector) {
        return new Vec3i((int)Math.round(vector.x), (int)Math.round(vector.y), (int)Math.round(vector.z));
    }

    private static void tryTransmit(PacketReceiver receiver, Packet packet, double range, boolean interdimensional) {
        var sender = packet.sender();
        if (receiver.getLevel() == sender.getLevel()) {
            var receiveRange = Math.max(range, receiver.getRange()); // Ensure range is symmetrical
            var distanceSq = receiver.getPosition().distanceToSqr(sender.getPosition());
            if (interdimensional || receiver.isInterdimensional() || distanceSq <= receiveRange * receiveRange) {
                // Get current level
                var level = receiver.getLevel();

                // Convert pos to int
                Vec3 senderPos = floorVec3(sender.getPosition());
                Vec3 receiverPos = floorVec3(receiver.getPosition());

                // Get normalized direction
                Vec3 direction = receiverPos.subtract(senderPos);
                direction = direction.normalize();

                var signalStrength = 0.0;
                var blocksTraversed = 0;

                for (var current = senderPos; !roundVec3(current).equals(receiverPos); current = current.add(direction)) {
                    var expResist = level.getBlockState(new BlockPos(roundToVec3i(current))).getBlock().getExplosionResistance();
                    signalStrength += signalStrength / 100.0 * expResist + 1.0;

                    if (signalStrength > receiveRange) {
                        return; // Too far away already
                    }

                    blocksTraversed++;
                }

                var distance = Math.sqrt(distanceSq);
                signalStrength *= (distance / blocksTraversed);
                receiver.receiveSameDimension(packet, signalStrength, signalStrength / distance);
            }
        } else {
            if (interdimensional || receiver.isInterdimensional()) {
                receiver.receiveDifferentDimension(packet);
            }
        }
    }

    @Override
    public boolean isWireless() {
        return true;
    }
}
