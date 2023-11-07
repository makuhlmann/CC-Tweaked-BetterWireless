package dan200.computercraft.shared.util;

import dan200.computercraft.api.network.PacketReceiver;
import net.minecraft.world.phys.Vec3;

public class CachedConnection {
    private final PacketReceiver receiver;
    private Vec3 lastReceiverPos;
    private long lastUpdate;
    private double signalStrength;
    private double signalQuality;

    public CachedConnection(PacketReceiver receiver, double signalStrength, double signalQuality) {
        this.receiver = receiver;
        this.lastReceiverPos = receiver.getPosition();
        this.lastUpdate = receiver.getLevel().getDayTime();
        this.signalStrength = signalStrength;
        this.signalQuality = signalQuality;
    }

    public void updateCache(double signalStrength, double signalQuality) {
        this.signalStrength = signalStrength;
        this.signalQuality = signalQuality;
        this.lastReceiverPos = receiver.getPosition();
        this.lastUpdate = receiver.getLevel().getDayTime();
    }

    public double getSignalQuality() {
        if (isStillValid()) {
            return signalQuality;
        }
        return 0.0;
    }

    public double getSignalStrength() {
        if (isStillValid()) {
            return signalStrength;
        }
        return 0.0;
    }
    private boolean isStillValid() {
        return lastUpdate > receiver.getLevel().getDayTime() - 2400 && receiver.getPosition().equals(lastReceiverPos);
    }
}
