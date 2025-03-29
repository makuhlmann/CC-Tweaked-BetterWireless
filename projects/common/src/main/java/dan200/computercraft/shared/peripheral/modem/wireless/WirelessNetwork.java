// Copyright Daniel Ratcliffe, 2011-2022. Do not distribute without permission.
//
// SPDX-License-Identifier: LicenseRef-CCPL

package dan200.computercraft.shared.peripheral.modem.wireless;

import dan200.computercraft.api.lua.LuaException;
import dan200.computercraft.api.network.Packet;
import dan200.computercraft.api.network.PacketNetwork;
import dan200.computercraft.api.network.PacketReceiver;
import dan200.computercraft.shared.peripheral.modem.ModemPeripheral;
import dan200.computercraft.shared.util.WirelessHelpers;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Vec3i;
import net.minecraft.util.Tuple;

import java.util.*;
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

    private static void tryTransmit(PacketReceiver receiver, Packet packet, double range, boolean interdimensional) {
        var sender = packet.sender();
        if (receiver.getLevel() == sender.getLevel()) {
            var level = receiver.getLevel();
            var receiveRange = Math.max(range, receiver.getRange()); // Ensure range is symmetrical
            var distanceSq = receiver.getPosition().distanceToSqr(sender.getPosition());

            // Interdimensional - just send it
            if (interdimensional && receiver.isInterdimensional()) {
                receiver.receiveSameDimension(packet, Math.sqrt(distanceSq), 0.0);
                return;
            }

            // Don't do anything if target modem ain't listening
            try {
                if(!((ModemPeripheral)receiver).isOpen(packet.channel())) {
                    return;
                }
            } catch (LuaException ignored) {}

            boolean noCache = false;

            // 65534 -> Default GPS, exclude from low range for now
            if (packet.channel() > 1024 && packet.channel() != 65534) {
                // High frequency local wireless
                receiveRange /= 8;
                noCache = true;
            }

            if (distanceSq <= receiveRange * receiveRange) {
                Vec3i senderBlockPosition = WirelessHelpers.floorToVec3i(sender.getPosition());
                Vec3i receiverBlockPosition = WirelessHelpers.floorToVec3i(receiver.getPosition());

                // No need for distance calc for yourself
                if (senderBlockPosition.equals(receiverBlockPosition)) {
                    //System.out.println("Skipped self distance check");
                    receiver.receiveSameDimension(packet, 0.0, receiveRange);
                    return;
                }

                //TODO: Signal range & Different degradation based on channel - 3 groups? (low, mid, high)
                if (!noCache) {
                    var cachedSignalDegradation = ((WirelessModemPeripheral)sender).getCachedSignalDegradation(receiverBlockPosition);
                    if (cachedSignalDegradation != Integer.MAX_VALUE) {
                        //System.out.println("Cache hit for " + sender.getSenderID() + " -> " + receiverBlockPosition.toString() + "!");
                        if (cachedSignalDegradation > receiveRange) {
                            return;
                        }
                        receiver.receiveSameDimension(packet, Math.sqrt(distanceSq), receiveRange - cachedSignalDegradation);
                        return;
                    }
                }


                List<Vec3i> obstructionBlocks = WirelessHelpers.Bresenham3D(senderBlockPosition, receiverBlockPosition);
                var signalDegradation = 0.0;
                var diagonalCompensation = WirelessHelpers.getDiagonalCompensation(senderBlockPosition, receiverBlockPosition);

                for (Vec3i blockVector : obstructionBlocks) {
                    var explosionResistance = level.getBlockState(new BlockPos(blockVector))
                        .getBlock()
                        .getExplosionResistance();
                    if (explosionResistance >= 100)
                        explosionResistance /= 4;
                    signalDegradation += (signalDegradation / 100.0 * explosionResistance + 1.0) * diagonalCompensation;

                    if (signalDegradation > receiveRange) {
                        break;
                    }
                }

                ((WirelessModemPeripheral)sender).addCachedSignalDegradation(receiverBlockPosition, signalDegradation);
                if (signalDegradation <= receiveRange) {
                    receiver.receiveSameDimension(packet, Math.sqrt(distanceSq), receiveRange - signalDegradation);
                }
            }
        } else {
            if (interdimensional && receiver.isInterdimensional()) {
                receiver.receiveDifferentDimension(packet);
            }
        }
    }

    @Override
    public boolean isWireless() {
        return true;
    }
}
