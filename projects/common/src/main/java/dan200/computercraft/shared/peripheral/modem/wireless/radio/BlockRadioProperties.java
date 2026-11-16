// SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
//
// SPDX-License-Identifier: MPL-2.0

package dan200.computercraft.shared.peripheral.modem.wireless.radio;

import net.minecraft.core.BlockPos;
import net.minecraft.tags.BlockTags;
import net.minecraft.tags.FluidTags;
import net.minecraft.tags.TagKey;
import net.minecraft.world.level.EmptyBlockGetter;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.SoundType;
import net.minecraft.world.level.block.state.BlockState;

import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Works out what a block is made of, and so how much it attenuates radio signals.
 * <p>
 * There is no reliable "material" property on blocks any more, so we guess from a block's sound type (which is a decent
 * proxy for what it is made of), a few tags, and its collision shape.
 * <p>
 * Blocks people build with (planks, logs, bricks, cobblestone, stone bricks, glass, wool, metal) are marked as built:
 * a wall one block thick stands for a much thinner real wall, so they lose less than natural terrain of the same
 * material (see {@link RadioEnvironment#builtLossScale()}). Natural rock is stone as the world generates it (the base
 * stone tags, terracotta, ores, and a few more); dirt, sand, snow, ice, water and plants are always natural.
 */
public final class BlockRadioProperties {
    private static final IdentityHashMap<SoundType, RadioMaterial> SOUND_MATERIALS = new IdentityHashMap<>();
    private static final Map<BlockState, BlockRadioInfo> CACHE = new ConcurrentHashMap<>();

    /** Plants and other blocks with no collision are mostly air. */
    private static final float NON_SOLID_FILL = 0.1f;

    /** Tags of rock as the world generates it. */
    private static final List<TagKey<Block>> NATURAL_ROCK_TAGS = List.of(
        BlockTags.BASE_STONE_OVERWORLD, BlockTags.BASE_STONE_NETHER, BlockTags.STONE_ORE_REPLACEABLES,
        BlockTags.DEEPSLATE_ORE_REPLACEABLES, BlockTags.TERRACOTTA, BlockTags.IRON_ORES, BlockTags.COPPER_ORES,
        BlockTags.GOLD_ORES
    );

    /** Natural rock (and crystal) which none of those tags has. */
    private static final Set<Block> NATURAL_ROCK = Set.of(
        Blocks.SANDSTONE, Blocks.RED_SANDSTONE, Blocks.END_STONE, Blocks.BEDROCK, Blocks.OBSIDIAN, Blocks.CRYING_OBSIDIAN,
        Blocks.CALCITE, Blocks.DRIPSTONE_BLOCK, Blocks.MAGMA_BLOCK, Blocks.SMOOTH_BASALT, Blocks.AMETHYST_BLOCK,
        Blocks.BUDDING_AMETHYST, Blocks.NETHER_QUARTZ_ORE, Blocks.NETHER_GOLD_ORE, Blocks.ANCIENT_DEBRIS, Blocks.GLOWSTONE,
        Blocks.COAL_ORE, Blocks.DEEPSLATE_COAL_ORE, Blocks.REDSTONE_ORE, Blocks.DEEPSLATE_REDSTONE_ORE, Blocks.LAPIS_ORE,
        Blocks.DEEPSLATE_LAPIS_ORE, Blocks.DIAMOND_ORE, Blocks.DEEPSLATE_DIAMOND_ORE, Blocks.EMERALD_ORE,
        Blocks.DEEPSLATE_EMERALD_ORE
    );

    static {
        for (var sound : new SoundType[]{
            SoundType.WOOD, SoundType.NETHER_WOOD, SoundType.CHERRY_WOOD, SoundType.BAMBOO_WOOD, SoundType.BAMBOO,
            SoundType.LADDER, SoundType.SCAFFOLDING, SoundType.STEM, SoundType.CHISELED_BOOKSHELF, SoundType.SHELF,
            SoundType.HANGING_SIGN, SoundType.NETHER_WOOD_HANGING_SIGN, SoundType.BAMBOO_WOOD_HANGING_SIGN,
            SoundType.CHERRY_WOOD_HANGING_SIGN, SoundType.CREAKING_HEART,
        }) {
            SOUND_MATERIALS.put(sound, RadioMaterial.WOOD);
        }

        for (var sound : new SoundType[]{
            SoundType.NETHER_BRICKS, SoundType.MUD_BRICKS, SoundType.DEEPSLATE_BRICKS, SoundType.DEEPSLATE_TILES,
            SoundType.TUFF_BRICKS, SoundType.RESIN_BRICKS, SoundType.DECORATED_POT, SoundType.DECORATED_POT_CRACKED,
            SoundType.PACKED_MUD,
        }) {
            SOUND_MATERIALS.put(sound, RadioMaterial.BRICK);
        }

        for (var sound : new SoundType[]{
            SoundType.METAL, SoundType.ANVIL, SoundType.CHAIN, SoundType.LANTERN, SoundType.COPPER, SoundType.COPPER_BULB,
            SoundType.COPPER_GRATE, SoundType.COPPER_GOLEM_STATUE, SoundType.NETHERITE_BLOCK, SoundType.IRON,
            SoundType.HEAVY_CORE, SoundType.VAULT, SoundType.TRIAL_SPAWNER, SoundType.SPAWNER, SoundType.LODESTONE,
        }) {
            SOUND_MATERIALS.put(sound, RadioMaterial.METAL);
        }

        for (var sound : new SoundType[]{ SoundType.GLASS, SoundType.AMETHYST, SoundType.AMETHYST_CLUSTER }) {
            SOUND_MATERIALS.put(sound, RadioMaterial.GLASS);
        }

        for (var sound : new SoundType[]{ SoundType.WOOL, SoundType.MOSS_CARPET, SoundType.STRAW_BED }) {
            SOUND_MATERIALS.put(sound, RadioMaterial.FABRIC);
        }

        for (var sound : new SoundType[]{ SoundType.SAND, SoundType.SUSPICIOUS_SAND, SoundType.SOUL_SAND }) {
            SOUND_MATERIALS.put(sound, RadioMaterial.DRY_GROUND);
        }

        for (var sound : new SoundType[]{
            SoundType.GRAVEL, SoundType.SUSPICIOUS_GRAVEL, SoundType.ROOTED_DIRT, SoundType.NYLIUM, SoundType.SOUL_SOIL,
            SoundType.MOSS, SoundType.SCULK, SoundType.SCULK_CATALYST, SoundType.SCULK_SENSOR, SoundType.SCULK_SHRIEKER,
            SoundType.WART_BLOCK, SoundType.MANGROVE_ROOTS,
        }) {
            SOUND_MATERIALS.put(sound, RadioMaterial.GROUND);
        }

        for (var sound : new SoundType[]{
            SoundType.MUD, SoundType.MUDDY_MANGROVE_ROOTS, SoundType.SLIME_BLOCK, SoundType.HONEY_BLOCK,
            SoundType.WET_SPONGE, SoundType.FROGSPAWN, SoundType.CORAL_BLOCK,
        }) {
            SOUND_MATERIALS.put(sound, RadioMaterial.WET_GROUND);
        }

        for (var sound : new SoundType[]{ SoundType.SNOW, SoundType.POWDER_SNOW }) {
            SOUND_MATERIALS.put(sound, RadioMaterial.SNOW);
        }

        for (var sound : new SoundType[]{
            SoundType.GRASS, SoundType.WET_GRASS, SoundType.CROP, SoundType.HARD_CROP, SoundType.VINE, SoundType.LILY_PAD,
            SoundType.SWEET_BERRY_BUSH, SoundType.NETHER_WART, SoundType.FUNGUS, SoundType.ROOTS, SoundType.WEEPING_VINES,
            SoundType.TWISTING_VINES, SoundType.NETHER_SPROUTS, SoundType.CAVE_VINES, SoundType.SPORE_BLOSSOM,
            SoundType.AZALEA, SoundType.FLOWERING_AZALEA, SoundType.AZALEA_LEAVES, SoundType.CHERRY_LEAVES,
            SoundType.POPLAR_LEAVES, SoundType.BIG_DRIPLEAF, SoundType.SMALL_DRIPLEAF, SoundType.HANGING_ROOTS,
            SoundType.GLOW_LICHEN, SoundType.PINK_PETALS, SoundType.LEAF_LITTER, SoundType.CHERRY_SAPLING,
            SoundType.BAMBOO_SAPLING, SoundType.CACTUS_FLOWER, SoundType.SHELF_MUSHROOM, SoundType.RED_SHRUB,
        }) {
            SOUND_MATERIALS.put(sound, RadioMaterial.VEGETATION);
        }
    }

    private BlockRadioProperties() {
    }

    /**
     * Get the radio properties of a block state.
     *
     * @param state The block state.
     * @return The block's radio properties.
     */
    public static BlockRadioInfo get(BlockState state) {
        if (state.isAir()) return BlockRadioInfo.AIR;

        var info = CACHE.get(state);
        if (info != null) return info;

        info = compute(state);
        CACHE.put(state, info);
        return info;
    }

    private static BlockRadioInfo compute(BlockState state) {
        var fluid = state.getFluidState();
        if (!fluid.isEmpty()) {
            // Lava is molten rock; treat it like waterlogged ground.
            return BlockRadioInfo.full(fluid.is(FluidTags.WATER) ? RadioMaterial.WATER : RadioMaterial.WET_GROUND);
        }

        if (state.is(BlockTags.LEAVES)) return BlockRadioInfo.full(RadioMaterial.VEGETATION);
        if (state.is(BlockTags.ICE)) return BlockRadioInfo.full(RadioMaterial.ICE);

        double fill;
        try {
            var shape = state.getCollisionShape(EmptyBlockGetter.INSTANCE, BlockPos.ZERO);
            fill = 0;
            for (var box : shape.toAabbs()) fill += box.getXsize() * box.getYsize() * box.getZsize();
        } catch (RuntimeException e) {
            // Some modded blocks expect a real level here. Assume they're solid.
            fill = 1;
        }
        var solid = fill > 0;
        fill = solid ? Math.min(1, fill) : NON_SOLID_FILL;

        var material = SOUND_MATERIALS.get(state.getSoundType());
        if (material == null) {
            // Grass blocks share the GRASS sound with plants, so we check for dirt explicitly.
            if (state.is(BlockTags.DIRT) || state.is(BlockTags.SAND)) {
                material = state.is(BlockTags.SAND) ? RadioMaterial.DRY_GROUND : RadioMaterial.GROUND;
            } else {
                // Everything else (stone, deepslate, ores, modded blocks) is treated as rock if solid, wood otherwise.
                material = solid ? RadioMaterial.ROCK : RadioMaterial.WOOD;
            }
        } else if (material == RadioMaterial.VEGETATION && state.is(BlockTags.DIRT)) {
            material = RadioMaterial.GROUND;
        }

        return new BlockRadioInfo(material, (float) fill, isBuilt(state, material));
    }

    /**
     * Whether a block is one people build with, rather than natural terrain.
     *
     * @param state    The block state.
     * @param material The material it was found to be made of.
     * @return Whether it's built.
     */
    private static boolean isBuilt(BlockState state, RadioMaterial material) {
        return switch (material) {
            case ROCK, WOOD, BRICK, GLASS, FABRIC, METAL -> !isNaturalRock(state);
            default -> false;
        };
    }

    private static boolean isNaturalRock(BlockState state) {
        if (NATURAL_ROCK.contains(state.getBlock())) return true;
        for (var tag : NATURAL_ROCK_TAGS) {
            if (state.is(tag)) return true;
        }
        return false;
    }
}
