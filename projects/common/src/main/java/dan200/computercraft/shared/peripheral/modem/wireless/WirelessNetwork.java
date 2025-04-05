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
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.chunk.LevelChunk;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

public class WirelessNetwork implements PacketNetwork {
    private static final Logger log = LoggerFactory.getLogger(WirelessNetwork.class);
    private final Set<PacketReceiver> receivers = Collections.newSetFromMap(new ConcurrentHashMap<>());

    private final static ArrayList<Vec3i> obstructionBlocks = new ArrayList<Vec3i>(2048);
    private final static ArrayList<BlockPos> unloadedBlocks = new ArrayList<BlockPos>(2048);

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
            var distance = receiver.getPosition().distanceTo(sender.getPosition());

            // Interdimensional - just send it
            if (interdimensional && receiver.isInterdimensional()) {
                receiver.receiveSameDimension(packet, distance, 0.0);
                return;
            }

            // Don't do anything if target modem ain't listening
            try {
                if(!((ModemPeripheral)receiver).isOpen(packet.channel())) {
                    return;
                }
            } catch (LuaException ignored) {}

            boolean useCache = true;

            // 65534 -> Default GPS, exclude from low range for now
            if (packet.channel() > 1024 && packet.channel() != 65534) {
                // High frequency local wireless
                receiveRange /= 8;
                useCache = false;
            }

            if (distance <= receiveRange) {
                Vec3i senderBlockPosition = WirelessHelpers.floorToVec3i(sender.getPosition());
                Vec3i receiverBlockPosition = WirelessHelpers.floorToVec3i(receiver.getPosition());

                // No need for distance calc for yourself
                if (senderBlockPosition.equals(receiverBlockPosition)) {
                    //System.out.println("Skipped self distance check");
                    receiver.receiveSameDimension(packet, 0.0, receiveRange);
                    return;
                }

                //TODO: Signal range & Different degradation based on channel - 3 groups? (low, mid, high)
                if (useCache) {
                    var cachedSignalDegradation = ((WirelessModemPeripheral)sender).getCachedSignalDegradation(receiverBlockPosition);
                    if (cachedSignalDegradation != Integer.MAX_VALUE) {
                        //System.out.println("Cache hit for " + sender.getSenderID() + " -> " + receiverBlockPosition.toString() + "!");
                        if (cachedSignalDegradation > receiveRange) {
                            return;
                        }
                        receiver.receiveSameDimension(packet, distance, receiveRange - cachedSignalDegradation);
                        return;
                    }
                }

                var timer = System.currentTimeMillis(); // yes this is vulnerable to leap seconds, fight me

                WirelessHelpers.Bresenham3D(obstructionBlocks, senderBlockPosition, receiverBlockPosition);

                if (timer + 500 <= System.currentTimeMillis()) {
                    log.warn("Bresenham3D took longer than 1 tick - " + obstructionBlocks.size() + " in " + (System.currentTimeMillis() - timer) + "ms");
                }

                var signalDegradation = distance;
                var diagonalCompensation = WirelessHelpers.getDiagonalCompensation(senderBlockPosition, receiverBlockPosition);

                var cancelled = false;

                unloadedBlocks.clear();



                Map<Vec3i, Double> signalDegradationCumulative = new ConcurrentHashMap<>();
                timer = System.currentTimeMillis();
                long finalTimer = timer;
                obstructionBlocks.parallelStream().forEach((blockVector) -> {
                    if (finalTimer + 500 <= System.currentTimeMillis()) {
                        return;
                    }
                    var currentBlockPos = new BlockPos(blockVector);
                    if (!level.isEmptyBlock(currentBlockPos)) {
                        var currentBlockState = level.getBlockState(currentBlockPos);
                        if (!currentBlockState.isAir()) {
                            var explosionResistance = currentBlockState.getBlock().getExplosionResistance();
                            if (explosionResistance >= 100)
                                explosionResistance /= 4;
                            signalDegradationCumulative.put(blockVector, Math.sqrt(explosionResistance) * 10.0 * diagonalCompensation);
                        }
                    }
                });

                if (timer + 500 <= System.currentTimeMillis()) {
                    log.warn("Dist measure timeout - " + (System.currentTimeMillis() - timer) + "ms [" + senderBlockPosition.getX() + ","
                        + senderBlockPosition.getY() + ","
                        + senderBlockPosition.getZ() + "] and ["
                        + receiverBlockPosition.getX() + ","
                        + receiverBlockPosition.getY() + ","
                        + receiverBlockPosition.getZ() + "]"
                        + " - blocks tested: " + signalDegradationCumulative.size() + "/" + obstructionBlocks.size());
                    cancelled = true;
                }

                for (var key : signalDegradationCumulative.keySet()) {
                    signalDegradation += signalDegradationCumulative.get(key);
                }

                if (cancelled) {
                    // Extrapolating the signal degradation for the rest of the path
                    signalDegradation = ((signalDegradation - distance) / (double) signalDegradationCumulative.size() / obstructionBlocks.size()) + distance;
                } else {
                    ((WirelessModemPeripheral)sender).addCachedSignalDegradation(receiverBlockPosition, signalDegradation);
                }

                if (signalDegradation <= receiveRange) {
                    receiver.receiveSameDimension(packet, distance, receiveRange - signalDegradation);
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
