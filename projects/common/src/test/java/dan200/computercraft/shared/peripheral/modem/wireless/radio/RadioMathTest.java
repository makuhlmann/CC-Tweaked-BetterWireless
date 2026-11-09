// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;

import static org.junit.jupiter.api.Assertions.*;

public class RadioMathTest {
    @Test
    public void freeSpaceLoss() {
        // Well known reference values: 1km at 2.4GHz is ~100dB, and every doubling of distance adds ~6dB.
        assertEquals(100.05, RadioMath.freeSpaceLoss(1000, 2400), 0.05);
        assertEquals(6.02, RadioMath.freeSpaceLoss(2000, 150) - RadioMath.freeSpaceLoss(1000, 150), 0.01);
    }

    @Test
    public void groundReflectionLoss() {
        // Close in, we're limited by free space loss.
        assertEquals(RadioMath.freeSpaceLoss(10, 150), RadioMath.groundReflectionLoss(10, 150, 2, 2), 1e-9);
        // Further out, loss is 40log(d) - 20log(h1 h2), and so independent of frequency.
        assertEquals(40 * Math.log10(5000) - 20 * Math.log10(4), RadioMath.groundReflectionLoss(5000, 150, 2, 2), 1e-9);
        // Raising an antenna 4x gains 12dB.
        assertEquals(12.04, RadioMath.groundReflectionLoss(5000, 150, 2, 2) - RadioMath.groundReflectionLoss(5000, 150, 2, 8), 0.01);
    }

    @Test
    public void knifeEdgeLoss() {
        assertEquals(0, RadioMath.knifeEdgeLoss(-1));
        // Grazing incidence loses 6dB.
        assertEquals(6.0, RadioMath.knifeEdgeLoss(0), 0.1);
        assertEquals(20.5, RadioMath.knifeEdgeLoss(2.4), 0.1);
        // Loss is monotonic.
        for (var v = -0.7; v < 10; v += 0.1) assertTrue(RadioMath.knifeEdgeLoss(v + 0.1) > RadioMath.knifeEdgeLoss(v));
    }

    @Test
    public void deygoutSingleEdgeIsKnifeEdge() {
        double[] distance = { 0, 400, 1000 };
        double[] height = { 0, 20, 0 };
        var lambda = RadioMath.wavelength(150);

        var expected = RadioMath.knifeEdgeLoss(RadioMath.fresnelParameter(20, 400, 600, lambda));
        assertEquals(expected, RadioMath.deygoutLoss(distance, height, 0, 2, 0, 0, lambda, 1), 1e-9);
    }

    @Test
    public void deygoutAddsSecondaryEdges() {
        double[] distance = { 0, 300, 600, 1000 };
        double[] height = { 0, 25, 25, 0 };
        var lambda = RadioMath.wavelength(150);

        var single = RadioMath.deygoutLoss(new double[]{ 0, 300, 1000 }, new double[]{ 0, 25, 0 }, 0, 2, 0, 0, lambda, 1);
        var both = RadioMath.deygoutLoss(distance, height, 0, 3, 0, 0, lambda, 1);
        assertTrue(both > single, "Two ridges should be worse than one");
    }

    @Test
    public void clearPathHasNoDiffraction() {
        double[] distance = { 0, 500, 1000 };
        double[] height = { 0, 0, 0 };
        assertEquals(0, RadioMath.deygoutLoss(distance, height, 0, 2, 50, 50, RadioMath.wavelength(150), 1));
    }

    @Test
    public void materialAttenuation() {
        // Concrete at 2.4GHz is in the tens of dB per metre (a 20cm wall is ~10-15dB).
        var concrete = RadioMaterial.ROCK.attenuation(2400);
        assertTrue(concrete > 40 && concrete < 100, "Concrete at 2.4GHz: " + concrete);

        // Losses grow with frequency.
        assertTrue(RadioMaterial.ROCK.attenuation(150) < concrete);
        assertTrue(RadioMaterial.VEGETATION.attenuation(150) < RadioMaterial.VEGETATION.attenuation(2400));

        // Relative ordering of common materials.
        assertTrue(RadioMaterial.GLASS.attenuation(2400) < RadioMaterial.ROCK.attenuation(2400));
        assertTrue(RadioMaterial.WOOD.attenuation(2400) < RadioMaterial.BRICK.attenuation(2400));
        assertTrue(RadioMaterial.WATER.attenuation(2400) > RadioMaterial.ROCK.attenuation(2400));
        assertEquals(1000, RadioMaterial.METAL.attenuation(150));
        assertEquals(0, RadioMaterial.AIR.attenuation(2400));
    }

    @Test
    public void voxelRayCoversWholeLength() {
        var lengths = new double[1];
        var voxels = new ArrayList<int[]>();
        VoxelRay.traverse(0.5, 0.5, 0.5, 10.2, 3.7, -4.1, Double.POSITIVE_INFINITY, (x, y, z, enter, exit) -> {
            lengths[0] += exit - enter;
            voxels.add(new int[]{ x, y, z });
            return true;
        });

        assertEquals(Math.sqrt(9.7 * 9.7 + 3.2 * 3.2 + 4.6 * 4.6), lengths[0], 1e-9);

        // Every step moves to a face-adjacent voxel.
        for (var i = 1; i < voxels.size(); i++) {
            var a = voxels.get(i - 1);
            var b = voxels.get(i);
            assertEquals(1, Math.abs(a[0] - b[0]) + Math.abs(a[1] - b[1]) + Math.abs(a[2] - b[2]));
        }
        assertArrayEquals(new int[]{ 10, 3, -5 }, voxels.getLast());
    }

    @Test
    public void voxelRayAxisAligned() {
        var count = new int[1];
        VoxelRay.traverse(0.5, 0.5, 0.5, 0.5, 0.5, 8.5, Double.POSITIVE_INFINITY, (x, y, z, enter, exit) -> {
            assertEquals(0, x);
            assertEquals(count[0], z);
            count[0]++;
            return true;
        });
        assertEquals(9, count[0]);
    }

    @Test
    public void fillUnknownInterpolates() {
        double[] values = { Double.NaN, 10, Double.NaN, Double.NaN, 40, Double.NaN };
        PropagationModel.fillUnknown(values, 0);
        assertArrayEquals(new double[]{ 10, 10, 20, 30, 40, 40 }, values, 1e-9);

        double[] unknown = { Double.NaN, Double.NaN };
        PropagationModel.fillUnknown(unknown, 64);
        assertArrayEquals(new double[]{ 64, 64 }, unknown);
    }
}
