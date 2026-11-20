-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.conf", function()
    local conf = require "cc.internal.net.conf"
    local helpers = require "support.net_helpers"

    local ip = helpers.ip

    it("reads a setting on each line, without comments", function()
        expect(conf.parse("# A comment\n  Zone home  /zones/home.zone # its file\n\n\tupstream 10.0.0.2\n")):same {
            { line = 2, key = "zone", "home", "/zones/home.zone" },
            { line = 4, key = "upstream", "10.0.0.2" },
        }
    end)

    describe("dnsd's settings", function()
        it("are read", function()
            local config, errors = conf.dnsd [[
zone home
zone Shop.Home. /zones/shop.zone
forward corp 10.1.0.53 10.1.0.54
upstream 10.0.0.2
upstream 10.0.0.3
allow-update 10.0.0.2 10.0.1.0/24
key s3cret
]]
            expect(errors):same {}
            expect(config):same {
                zones = { { zone = "home" }, { zone = "shop.home", file = "/zones/shop.zone" } },
                forward = { { zone = "corp", servers = { ip("10.1.0.53"), ip("10.1.0.54") } } },
                upstream = { ip("10.0.0.2"), ip("10.0.0.3") },
                allow = { { network = ip("10.0.0.2"), prefix = 32 }, { network = ip("10.0.1.0"), prefix = 24 } },
                key = "s3cret",
            }
        end)

        it("say what doesn't make sense, by line", function()
            local _, errors = conf.dnsd [[
zone
zone a..b
zone home
zone home
zone x a b
forward corp
forward shop 10.0.0.0/8 nowhere
upstream
allow-update nowhere
key two words
cheese 1
]]
            expect(errors):same {
                "Line 1: zone needs a zone, such as home",
                "Line 2: zone needs a zone, such as home",
                "Line 4: home is there twice",
                "Line 5: zone takes a zone, and maybe its file",
                "Line 6: forward needs at least one server",
                "Line 7: 10.0.0.0/8 isn't a server's address",
                "Line 7: nowhere isn't a server's address",
                "Line 8: upstream needs at least one server",
                "Line 9: nowhere isn't an address or a network",
                "Line 10: key takes one secret, up to 128 characters, without spaces or #",
                "Line 11: there's no setting called cheese",
            }
            expect(select(2, conf.dnsd("# nothing\n"))):same {
                "There's nothing to do: add a zone (such as \"zone home\"), or servers to ask",
            }
            -- Only asking other servers is something to do.
            expect(select(2, conf.dnsd("upstream 10.0.0.2\n"))):same {}
        end)

        it("are written so they make sense", function()
            local config, errors = conf.dnsd(conf.dnsd_default())
            expect(errors):same {}
            expect({ config.zones, config.upstream, config.key }):same { { { zone = "home" } }, {} }

            config, errors = conf.dnsd(conf.dnsd_default {
                zones = { { zone = "home", file = "/records.txt" }, { zone = "shop" } }, upstream = { ip("10.0.0.2") },
            })
            expect(errors):same {}
            expect({ config.zones, config.upstream })
                :same { { { zone = "home", file = "/records.txt" }, { zone = "shop" } }, { ip("10.0.0.2") } }
        end)
    end)

    it("reads dnsd's zones, each after its name", function()
        local zones, errors = conf.zones [[
# Names
[home]
@ 10.0.0.1
Bank 10.0.0.5 # the bank
[shop.home]
till 10.0.0.7

[home]
pc 10.0.0.8
[not a zone]
x 10.0.0.9
y 10.0.0.0/24
nonsense
]]
        expect(zones):same {
            home = { ["@"] = ip("10.0.0.1"), bank = ip("10.0.0.5"), pc = ip("10.0.0.8") },
            ["shop.home"] = { till = ip("10.0.0.7") },
        }
        expect(errors):same {
            "Line 10: not a zone isn't a zone",
            "Line 11: names come after their zone, such as [home]",
            "Line 12: names come after their zone, such as [home]",
            "Line 13: expected a name, then its address or the name it's an alias for",
        }
        expect(select(2, conf.zones("x 10.0.0.1\n"))):same { "Line 1: names come after their zone, such as [home]" }
        expect(conf.zones(conf.zones_default({ "home", "shop" }))):same { home = {}, shop = {} }
    end)

    it("reads aliases in dnsd's zones, for names in the same zone or written in full", function()
        local zones, errors = conf.zones [[
[home]
www shop
WWW2 Shop.Corp.
mail mail.corp
top @
1019 10.0.0.9
pc 1019
[shop.home]
@ www.home
bad 10.0.0.256
bad a..b
printer printer.local
loop loop
]]
        expect(zones):same {
            home = {
                www = "shop.home", www2 = "shop.corp", mail = "mail.corp", top = "home", ["1019"] = ip("10.0.0.9"),
                pc = "1019.home",
            },
            ["shop.home"] = { ["@"] = "www.home" },
        }
        expect(errors):same {
            "Line 10: 10.0.0.256 isn't an address",
            "Line 11: a..b isn't an address or a name",
            "Line 12: printer.local is a .local name, which only the computers on a link answer for",
            "Line 13: loop is an alias for itself",
        }
    end)

    describe("dhcpd's settings", function()
        it("are read", function()
            local config, errors = conf.dhcpd [[
interface top
range 50 80
lease 600
gateway 10.0.0.1
dns 10.0.0.1 10.0.0.2
domain Home
update-server 10.0.0.1
update-zone dhcp.home
update-key s3cret
host 12 10.0.0.20
host 13 10.0.0.21
]]
            expect(errors):same {}
            expect(config):same {
                interface = "top", range = { first = 50, last = 80, numbers = true }, lease = 600,
                gateway = ip("10.0.0.1"), dns = { ip("10.0.0.1"), ip("10.0.0.2") }, domain = "home",
                update = { server = ip("10.0.0.1"), zone = "dhcp.home", key = "s3cret" },
                hosts = { [12] = ip("10.0.0.20"), [13] = ip("10.0.0.21") },
            }

            config = conf.dhcpd("address 10.0.0.1\nrange 10.0.0.100 10.0.0.199\n")
            expect({ config.address, config.range, config.lease, config.update })
                :same { ip("10.0.0.1"), { first = ip("10.0.0.100"), last = ip("10.0.0.199"), numbers = false }, 3600 }
        end)

        it("say what doesn't make sense, by line", function()
            local _, errors = conf.dhcpd [[
interface top
address 10.0.0.1
range 80 50
range 50 10.0.0.80
range 50
lease 5
lease 1e9
gateway 10.0.0.0/24
dns
domain a..b
update-zone home
host 12 10.0.0.20
host 12 10.0.0.21
host 13 10.0.0.20
host x 10.0.0.22
]]
            expect(errors):same {
                "Line 3: the range's first address comes after its last",
                "Line 4: range takes the first and last addresses, such as 10.0.0.100 10.0.0.199, or 100 199",
                "Line 5: range takes the first and last addresses, such as 10.0.0.100 10.0.0.199, or 100 199",
                "Line 6: lease takes a number of seconds, from 30 to 604800",
                "Line 7: lease takes a number of seconds, from 30 to 604800",
                "Line 8: gateway takes an address",
                "Line 9: dns needs at least one server",
                "Line 10: domain takes a domain, such as home",
                "Line 13: computer 12 has an address already",
                "Line 14: 10.0.0.20 is computer 12's already",
                "Line 15: host takes a computer's ID and its address, such as 12 10.0.0.50",
                "Give either the interface or its address, not both",
                "update-zone and update-key need update-server, the DNS server to register names at",
            }
            expect(select(2, conf.dhcpd("lease 600\n"))):same {
                "Say which interface to hand out addresses on, such as \"interface top\"",
            }
        end)

        it("are written so they make sense", function()
            -- With no interface to hand addresses out on, it has to be said which.
            expect(select(2, conf.dhcpd(conf.dhcpd_default()))):same {
                "Say which interface to hand out addresses on, such as \"interface top\"",
            }
            local config, errors = conf.dhcpd(conf.dhcpd_default {
                interface = "top", range = { "50", "80" }, lease = 600, gateway = ip("10.0.0.1"),
                dns = { ip("10.0.0.1") }, domain = "home", update = { server = ip("127.0.0.1"), zone = "lan" },
            })
            expect(errors):same {}
            expect(config):same {
                interface = "top", range = { first = 50, last = 80, numbers = true }, lease = 600,
                gateway = ip("10.0.0.1"), dns = { ip("10.0.0.1") }, domain = "home",
                update = { server = ip("127.0.0.1"), zone = "lan" }, hosts = {},
            }
        end)
    end)

    describe("moving from how servers were set up before", function()
        local migrate = require "cc.internal.net.migrate"
        local names = { "dhcpd.lease", "dhcpd.dns", "dhcpd.domain", "dhcpd.gateway" }

        local function with_settings(values, fn)
            local before = {}
            for _, name in ipairs(names) do
                before[name] = settings.get(name)
                if values[name] == nil then settings.unset(name) else settings.set(name, values[name]) end
            end
            local ok, err = pcall(fn)
            for _, name in ipairs(names) do
                if before[name] == nil then settings.unset(name) else settings.set(name, before[name]) end
            end
            fs.delete("/etc")
            fs.delete("/.dhcpd")
            if not ok then error(err, 0) end
        end

        it("writes dhcpd's settings from its arguments and settings, with its leases", function()
            with_settings({
                ["dhcpd.lease"] = 600, ["dhcpd.dns"] = "10.0.0.1, 10.0.0.2", ["dhcpd.domain"] = "Home.",
                ["dhcpd.gateway"] = "10.0.0.1",
            }, function()
                local file = fs.open("/.dhcpd/top.leases", "w")
                file.write("{ [12] = { address = 167772260, expires = 1, hostname = \"pc\" } }")
                file.close()
                expect(migrate.dhcpd({ "top", "50" })):eq(true)

                local file_text = conf.read(conf.DHCPD_CONF)
                local config, errors = conf.dhcpd(file_text)
                expect(errors):same {}
                expect(config):same {
                    interface = "top", range = { first = 50, last = 149, numbers = true }, lease = 600,
                    gateway = ip("10.0.0.1"), dns = { ip("10.0.0.1"), ip("10.0.0.2") }, domain = "home", hosts = {},
                }
                expect(conf.read(conf.DHCPD_LEASES)):eq("{ [12] = { address = 167772260, expires = 1, hostname = \"pc\" } }")
                -- The settings are gone: they do nothing now.
                for _, name in ipairs(names) do expect(settings.get(name)):describe(name):eq(nil) end
            end)
        end)

        it("writes dhcpd's settings as they are at first, when it wasn't set up", function()
            with_settings({}, function()
                expect(migrate.dhcpd({})):eq(false)
                local config = conf.dhcpd(conf.read(conf.DHCPD_CONF))
                expect({ config.range, config.lease, config.update }):same { { first = 100, last = 199, numbers = true }, 3600 }
            end)
        end)
    end)
end)
