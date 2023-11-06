<!--
SPDX-FileCopyrightText: 2017 The CC: Tweaked Developers

SPDX-License-Identifier: MPL-2.0
-->

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./doc/logo-darkmode.png">
  <source media="(prefers-color-scheme: light)" srcset="./doc/logo.png">
  <img alt="CC: Tweaked" src="./doc/logo.png">
</picture>

## About this fork
This fork is an experimental proof of concept to test a more "true to life" wireless signal calculation. While
the original CC: Tweaked mod only accounts for distance as the limiting factor, this modification accounts for
signal degradation through obstacles. For this, every message has to have its path traced from the sender to the
recipient, which can be a very resource intensive calculation. Thus this is not recommended to be used with large
maps with many endpoints.

The calculation is simple: by default the range is set to 1024 meters. For every block of air traversed, 1 meter
of signal strength is removed. For every block in the path, a calculation based on the [blast resistance](https://minecraft.wiki/w/Explosion#Blast_resistance) is subtracted
from the signal strength.

The formula for a given block is: signalStrength += signalStrength / 100 * blastResistance + 1

This has the effect that obstacles close to the sender do not cause a large signal degradation, but obstacles far away
from the sender do. This can also have the side effect that one endpoint can receive messages from another one, but
responses would not arrive due to worse signal degradation.

Since signalStrength replaces distance as the parameter, an additional value called signalQuality has been added as
well. The distance can be calculated by multiplying signalStrength and signalQuality. A signal quality of 1.0 means that
the path between the endpoints is unobstructed and should at best allow for a range of 1024 blocks.

Hint: due to the potential high range, chunks with computers may unload before reaching the range limit. Using cheats
or with administrative permission you can use a command to prevent a chunk from unloading:

```/forceload add ~ ~```

## CC: Tweaked

CC: Tweaked is a mod for Minecraft which adds programmable computers, turtles and more to the game. A fork of the
much-beloved [ComputerCraft], it continues its legacy with improved performance and stability, along with a wealth of
new features.

CC: Tweaked can be installed from [CurseForge] or [Modrinth]. It runs on both [Minecraft Forge] and [Fabric].

## Contributing
Any contribution is welcome, be that using the mod, reporting bugs or contributing code. If you want to get started
developing the mod, [check out the instructions here](CONTRIBUTING.md#developing).

## Community
If you need help getting started with CC: Tweaked, want to show off your latest project, or just want to chat about
ComputerCraft, do check out our [forum] and [GitHub discussions page][GitHub discussions]! There's also a fairly
populated, albeit quiet [IRC channel][irc], if that's more your cup of tea.

We also host fairly comprehensive documentation at [tweaked.cc](https://tweaked.cc/ "The CC: Tweaked website").

## Using
CC: Tweaked is hosted on my maven repo, and so is relatively simple to depend on. You may wish to add a soft (or hard)
dependency in your `mods.toml` file, with the appropriate version bounds, to ensure that API functionality you depend
on is present.

```groovy
repositories {
  maven {
    url "https://squiddev.cc/maven/"
    content {
      includeGroup("cc.tweaked")
      includeModule("org.squiddev", "Cobalt")
    }
  }
}

dependencies {
  // Vanilla (i.e. for multi-loader systems)
  compileOnly("cc.tweaked:cc-tweaked-$mcVersion-common-api:$cctVersion")

  // Forge Gradle
  compileOnly("cc.tweaked:cc-tweaked-$mcVersion-core-api:$cctVersion")
  compileOnly(fg.deobf("cc.tweaked:cc-tweaked-$mcVersion-forge-api:$cctVersion"))
  runtimeOnly(fg.deobf("cc.tweaked:cc-tweaked-$mcVersion-forge:$cctVersion"))

  // Fabric Loom
  modCompileOnly("cc.tweaked:cc-tweaked-$mcVersion-fabric-api:$cctVersion")
  modRuntimeOnly("cc.tweaked:cc-tweaked-$mcVersion-fabric:$cctVersion")
}
```

When using ForgeGradle, you may also need to add the following:

```groovy
minecraft {
    runs {
        configureEach {
            property 'mixin.env.remapRefMap', 'true'
            property 'mixin.env.refMapRemappingFile', "${buildDir}/createSrgToMcp/output.srg"
        }
    }
}
```

You should also be careful to only use classes within the `dan200.computercraft.api` package. Non-API classes are
subject to change at any point. If you depend on functionality outside the API, file an issue, and we can look into
exposing more features.

We bundle the API sources with the jar, so documentation should be easily viewable within your editor. Alternatively,
the generated documentation [can be browsed online](https://tweaked.cc/javadoc/).

[computercraft]: https://github.com/dan200/ComputerCraft "ComputerCraft on GitHub"
[curseforge]: https://minecraft.curseforge.com/projects/cc-tweaked "Download CC: Tweaked from CurseForge"
[modrinth]: https://modrinth.com/mod/gu7yAYhd "Download CC: Tweaked from Modrinth"
[Minecraft Forge]: https://files.minecraftforge.net/ "Download Minecraft Forge."
[Fabric]: https://fabricmc.net/use/installer/ "Download Fabric."
[forum]: https://forums.computercraft.cc/
[GitHub Discussions]: https://github.com/cc-tweaked/CC-Tweaked/discussions
[IRC]: https://webchat.esper.net/?channels=computercraft "#computercraft on EsperNet"
