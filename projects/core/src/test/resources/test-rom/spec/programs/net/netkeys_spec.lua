-- SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

describe("The netkeys program", function()
    local capture = require "test_helpers".capture_program
    local with_enclave = require "support.net_helpers".with_enclave
    local KEY = ("ab"):rep(32)

    local function run(...) return capture("/rom/programs/net/netkeys.lua", ...) end
    local function write(path, text)
        local file = fs.open(path, "w")
        file.write(text)
        file.close()
    end

    it("needs the enclave", function()
        if enclave then return end
        expect(run()):matches { error = "netkeys needs the crypto and enclave APIs, which are turned off on this server\n" }
    end)

    it("shows this computer's key, and writes it to a file", function()
        with_enclave(function()
            local key = net.getIdentity()
            expect(run()):matches {
                ok = true,
                output = "This computer's key, which other computers see when it connects to them:\n" .. key ..
                    "\nFingerprint: " .. net.fingerprint(key) .. "\n",
            }
            expect(run("export", "/test-files/netkeys.key")).ok = true
            local file = fs.open("/test-files/netkeys.key", "r")
            expect(file.readAll()):eq(key .. "\n")
            file.close()
        end)
    end)

    it("lists the computers it knows, and forgets them", function()
        with_enclave(function()
            expect(run("hosts")):matches { output = "No computers known yet.\n" }
            write("/.net/known_hosts", textutils.serialise({ ["bank.home"] = KEY }))
            expect(run("hosts")):matches { output = ("%-20s %s\n"):format("bank.home", net.fingerprint(KEY)) }
            expect(run("forget", "bank.home")):matches { output = "Forgot the key for bank.home\n" }
            expect(run("forget", "bank.home")):matches { output = "No key known for bank.home\n" }
            expect(net.knownHosts()):same {}
        end)
    end)

    it("trusts authorities, by key or from a file, and stops", function()
        with_enclave(function()
            expect(run("trust", KEY, "Bank")):matches { output = "Trusting certificates from " .. net.fingerprint(KEY) .. "\n" }
            write("/test-files/authority.key", ("CD"):rep(32) .. "\n")
            run("trust", "/test-files/authority.key")
            expect(net.trusted()):same { [KEY] = "Bank", [("cd"):rep(32)] = "added by hand" }
            expect(run("trust", "nothing")):matches { error = "Expected a key of 64 hexadecimal digits, or a file with one in\n" }

            expect(run("untrust", "Bank")):matches { output = "Removed.\n" }
            expect(run("untrust", "Bank")):matches { output = "No such authority.\n" }
            expect(run("untrust", ("cd"):rep(32))):matches { output = "Removed.\n" }
            expect(net.trusted()):same {}
        end)
    end)

    it("signs certificates, and installs one for this computer", function()
        with_enclave(function()
            run("export", "/test-files/netkeys.key")
            expect(run("sign", "Bank.home", "/test-files/netkeys.key", "30", "/test-files/bank.cert")):matches {
                ok = true, output = "Wrote a certificate for bank.home to /test-files/bank.cert, valid for 30 days.\n",
            }
            expect(run("install", "/test-files/bank.cert")):matches {
                output = "Installed the certificate for bank.home. Secure servers started from now on offer it.\n",
            }
            expect(run().output):str_match("It has a certificate for bank%.home, until %d%d%d%d%-%d%d%-%d%d%.\n$")

            -- Only one for this computer's key, and only a certificate.
            run("sign", "other.home", KEY, "30", "/test-files/other.cert")
            expect(run("install", "/test-files/other.cert")):matches { error = "That certificate is for another computer's key.\n" }
            expect(run("install", "/test-files/netkeys.key")):matches { error = "/test-files/netkeys.key isn't a certificate.\n" }
            expect(run("sign", "bank.home", KEY, "0").output):str_match("^Usages:\n")
        end)
    end)
end)
