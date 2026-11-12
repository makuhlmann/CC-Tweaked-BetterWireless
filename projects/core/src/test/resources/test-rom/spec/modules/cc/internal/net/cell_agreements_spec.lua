-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.cell.networks", function()
    local networks = require "cc.internal.net.cell.networks"
    local DIR = "/cell_agreements_spec"

    local function write(name, text)
        local file = fs.open(fs.combine(DIR, name), "w")
        file.write(text)
        file.close()
    end

    local function with_files(contents, fn)
        fs.delete(DIR)
        for name, text in pairs(contents) do write(name, text) end
        local ok, err = pcall(fn)
        fs.delete(DIR)
        if not ok then error(err, 0) end
    end

    -- Two networks' cores as an older version left them: TESTCELL carries ALPCELL's phones and connected to its core
    -- to exchange messages; ALPCELL carries TESTCELL's, and allowed its core both for that and for messages. (A world's
    -- files, word for word, but for the cells they also had.)
    local TESTCELL = {
        config = [[{
  number_prefix = "391",
  prefix = "10.64.0.0/16",
  network = "TESTCELL",
}]],
        cells = [[{
  [ "546c899a4999e292ed65bf70c8ad28bd8ae9f38577a054c3a7505eb03f6bcb30" ] = {
    role = "roam",
    network = "ALPCELL",
    label = "ALPCELL",
    id = 11,
    signing = "cb68a6043939558e9293732e40c27d891dfe11fe1972ef04803c25be51e592f9",
  },
  a2aafa8772408eb883b435ca6ba3aaad6d3009bcdbcbcd951e3aa95aac00157f = {
    role = "cell",
    label = "cell #13",
    id = 13,
  },
}]],
        roaming = [[{
  ALPCELL = {
    core = "10.65.0.1",
  },
}]],
        peers = [[{
  ALPCELL = {
    core = "10.65.0.1",
    prefix = "392",
  },
}]],
    }
    local ALPCELL = {
        config = [[{
  number_prefix = "392",
  prefix = "10.65.0.0/16",
  network = "ALPCELL",
}]],
        cells = [[{
  f26724f021b73cbe9cdd044b234e456cc9cbc4612f7ac9680f937a0974f5d219 = {
    role = "cell",
    label = "cell #2",
    id = 2,
  },
  ed375278f86979e3524c1d9ea5a792450eb4c95210e930dcf266f9786331160d = {
    roles = {
      peer = true,
    },
    role = "roam",
    network = "TESTCELL",
    label = "TESTCELL",
    id = 9,
    prefix = "391",
    signing = "a65440d0f2d9d16d219cf78c395ce0fde3fdb5f0f65baa70dcbaa61ce28e87b0",
  },
}]],
        roaming = [[{
  TESTCELL = {
    core = "10.60.0.1",
  },
}]],
    }

    it("are made from the files older versions kept, once", function()
        with_files(TESTCELL, function()
            local agreements, migrated = networks.read(DIR, "TESTCELL")
            expect(migrated):eq(true)
            expect(agreements):same {
                ALPCELL = {
                    key = "546c899a4999e292ed65bf70c8ad28bd8ae9f38577a054c3a7505eb03f6bcb30", id = 11, label = "ALPCELL",
                    signing = "cb68a6043939558e9293732e40c27d891dfe11fe1972ef04803c25be51e592f9",
                    core = "10.65.0.1", carry = true, roam = "partner", messages = true, prefix = "392",
                },
            }

            -- Once written, they're read from there, and the older files are left as they were.
            networks.write(DIR, agreements)
            local again, migrated_again = networks.read(DIR, "TESTCELL")
            expect(migrated_again):eq(false)
            expect(again):same(agreements)
            for _, name in ipairs { "cells", "roaming", "peers", "config" } do
                expect(fs.exists(fs.combine(DIR, name))):describe(name):eq(true)
            end
        end)

        with_files(ALPCELL, function()
            expect(networks.read(DIR, "ALPCELL")):same {
                TESTCELL = {
                    key = "ed375278f86979e3524c1d9ea5a792450eb4c95210e930dcf266f9786331160d", id = 9, label = "TESTCELL",
                    signing = "a65440d0f2d9d16d219cf78c395ce0fde3fdb5f0f65baa70dcbaa61ce28e87b0",
                    core = "10.60.0.1", carry = true, roam = "partner", messages = true, prefix = "391",
                },
            }
        end)
    end)

    it("are made from older files with partners as home, and peers alone", function()
        with_files({
            cells = textutils.serialise {
                [("aa"):rep(32)] = { role = "roam", network = "HOMELY", id = 4, signing = ("bb"):rep(32), home = true },
                [("cc"):rep(32)] = { role = "peer", network = "CHATTY", id = 5, prefix = "77" },
                -- Its own name, and no name at all, are passed by.
                [("dd"):rep(32)] = { role = "roam", network = "OURS", id = 6 },
                [("ee"):rep(32)] = { role = "peer", id = 7 },
            },
        }, function()
            expect(networks.read(DIR, "OURS")):same {
                HOMELY = {
                    key = ("aa"):rep(32), id = 4, signing = ("bb"):rep(32), roam = "home", carry = false, messages = false,
                },
                CHATTY = { key = ("cc"):rep(32), id = 5, prefix = "77", roam = false, carry = false, messages = true },
            }
        end)
    end)

    it("keep only what could be right", function()
        with_files({
            networks = textutils.serialise {
                GOOD = { key = ("AB"):rep(32), core = "10.0.0.1", carry = true, roam = "home", messages = true, prefix = "12" },
                ODD = { key = "short", core = "not an address!", carry = "yes", roam = "always", prefix = "x", id = -1 },
                ["bad name"] = { carry = true },
                OURS = { carry = true },
                NOTHING = "at all",
            },
        }, function()
            expect(networks.read(DIR, "OURS")):same {
                GOOD = { key = ("ab"):rep(32), core = "10.0.0.1", carry = true, roam = "home", messages = true, prefix = "12" },
                ODD = { carry = false, roam = false, messages = false },
            }
        end)
    end)
end)
