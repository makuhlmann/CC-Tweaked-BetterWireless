-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("cc.internal.net.files", function()
    local files = require "cc.internal.net.files"

    it("writes bytes as hexadecimal digits, and reads them back", function()
        expect(files.hex.encode("\0\1\171\255")):eq("0001abff")
        expect(files.hex.decode("0001ABff")):eq("\0\1\171\255")
        expect(files.hex.decode("abc")):eq(nil)
        expect(files.hex.decode("zz")):eq(nil)
        expect(files.hex.decode(5)):eq(nil)
        -- With a length, only that many bytes.
        expect(files.hex.decode(("ab"):rep(32), 32)):eq(("\171"):rep(32))
        expect(files.hex.decode(("ab"):rep(31), 32)):eq(nil)
        expect({ files.hex.is_key(("ab"):rep(32)), files.hex.is_key(("ab"):rep(31)), files.hex.is_key({}) }):same {
            true, false, false,
        }
    end)

    it("reads and writes tables, and reads anything else as an empty one", function()
        local path = "/files_spec.tmp"
        files.write_table(path, { a = 1, list = { "x" } })
        expect(files.read_table(path)):same { a = 1, list = { "x" } }
        local file = fs.open(path, "w")
        file.write("not a table")
        file.close()
        expect(files.read_table(path)):same {}
        fs.delete(path)
        expect(files.read_table(path)):same {}
        expect.error(files.write_table, "/rom/nope", {}):str_match("")
    end)
end)
