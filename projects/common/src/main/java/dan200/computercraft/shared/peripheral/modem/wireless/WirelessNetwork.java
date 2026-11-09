// Copyright Daniel Ratcliffe, 2011-2022. Do not distribute without permission.
//
// SPDX-License-Identifier: LicenseRef-CCPL

package dan200.computercraft.shared.peripheral.modem.wireless;

import dan200.computercraft.api.network.Packet;
import dan200.computercraft.api.network.PacketNetwork;
import dan200.computercraft.api.network.PacketReceiver;
import dan200.computercraft.shared.config.Config;
import dan200.computercraft.shared.peripheral.modem.ModemPeripheral;
import dan200.computercraft.shared.peripheral.modem.wireless.radio.RadioPropagationService;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.chunk.LevelChunk;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

public class WirelessNetwork implements PacketNetwork {
    private final Set<PacketReceiver> receivers = Collections.newSetFromMap(new ConcurrentHashMap<>());
    private final RadioPropagationService propagation = new RadioPropagationService();

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

        var sender = packet.sender();
        if (!Config.radioEnabled || !(sender.getLevel() instanceof ServerLevel level)) {
            for (var device : receivers) tryTransmit(device, packet, range, false);
            return;
        }

        // Find everything which could plausibly hear this packet, and leave the rest to the propagation model.
        var settings = propagation.settings();
        var band = settings.band(packet.channel());
        var origin = sender.getPosition();
        List<PacketReceiver> candidates = null;
        for (var receiver : receivers) {
            if (receiver.getLevel() != level) {
                if (receiver.isInterdimensional()) receiver.receiveDifferentDimension(packet);
                continue;
            }

            var distance = receiver.getPosition().distanceTo(origin);

            // Ender modems are not radios, and so hear everything.
            if (receiver.isInterdimensional()) {
                receiver.receiveSameDimension(packet, distance);
                continue;
            }

            if (receiver == sender) continue;
            if (receiver instanceof ModemPeripheral modem && !modem.getModemState().isOpen(packet.channel())) continue;
            if (!settings.isPossible(distance, band)) continue;

            if (candidates == null) candidates = new ArrayList<>();
            candidates.add(receiver);
        }

        if (candidates != null) propagation.submit(packet, level, origin, candidates);
    }

    @Override
    public void transmitInterdimensional(Packet packet) {
        Objects.requireNonNull(packet, "packet cannot be null");
        for (var device : receivers) tryTransmit(device, packet, 0, true);
    }

    private static void tryTransmit(PacketReceiver receiver, Packet packet, double range, boolean interdimensional) {
        var sender = packet.sender();
        if (receiver.getLevel() == sender.getLevel()) {
            var receiveRange = Math.max(range, receiver.getRange()); // Ensure range is symmetrical
            var distanceSq = receiver.getPosition().distanceToSqr(sender.getPosition());
            if (interdimensional || receiver.isInterdimensional() || distanceSq <= receiveRange * receiveRange) {
                receiver.receiveSameDimension(packet, Math.sqrt(distanceSq));
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

    /**
     * Deliver any queued packets. This should be called at the start of every server tick.
     */
    public void tick() {
        propagation.tick();
    }

    public void onChunkUnload(LevelChunk chunk) {
        if (Config.radioEnabled) propagation.onChunkUnload(chunk);
    }

    public void close() {
        propagation.close();
    }
}
