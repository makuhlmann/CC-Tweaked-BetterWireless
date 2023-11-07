package dan200.computercraft.shared.util;

import net.minecraft.core.Vec3i;
import net.minecraft.world.phys.Vec3;

public class VectorHelpers {

    public static Vec3 floorVec3(Vec3 vector) {
        return new Vec3(Math.floor(vector.x), Math.floor(vector.y), Math.floor(vector.z));
    }

    public static Vec3 roundVec3(Vec3 vector) {
        return new Vec3(Math.round(vector.x), Math.round(vector.y), Math.round(vector.z));
    }

    public static Vec3i roundToVec3i(Vec3 vector) {
        return new Vec3i((int)Math.round(vector.x), (int)Math.round(vector.y), (int)Math.round(vector.z));
    }
}
