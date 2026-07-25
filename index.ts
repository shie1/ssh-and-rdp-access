import express from "express"
import { config } from "dotenv"
import { existsSync, readFileSync, rmSync, writeFileSync } from "fs"
import { homedir, tmpdir } from "os"
import path from "path"
import { execFileSync } from "child_process"
import { TOTP } from "otpauth"
import QR from "qrcode"

config({ quiet: true })

const AUTHORIZED_KEYS_SEPARATOR_STRING = "# BELOW THIS LINE, KEYS ARE MANAGED BY SSH&RDP ACCESS SERVER. DO NOT MAKE EDITS BELOW THIS LINE."
const SSH_KEY_TYPE = "ssh-ed25519"

const expandedHomeDir = (filePath: string) => {
    if (filePath.startsWith("~")) {
        return path.join(homedir(), filePath.slice(1))
    }
    return filePath
}

const envVars = {
    SSH_DIR: expandedHomeDir(process.env.SSH_KEY_PATH || path.join(homedir(), ".ssh")),
    PASSWORD: process.env.PASSWORD!,
    OTP_CODE_ENABLED: process.env.OTP_CODE_ENABLED === "true",
    OTP_SECRET: process.env.OTP_SECRET!,
    TARGET: process.env.TARGET!,
    TARGET_PORT: process.env.TARGET_PORT || "22",
    RDP_PORT: process.env.RDP_PORT || "3389",
    BASE_URL: process.env.BASE_URL!,
    OTP_ISSUER: process.env.OTP_ISSUER || "SSH&RDP",
    OTP_LABEL: process.env.OTP_LABEL || "Uncofigured",
}

const insertEnvVars = (string: string) => {
    const regex = /!<<ENV_(\w+)>>/g
    return string.replace(regex, (_, varName) => {
        const value = envVars[varName as keyof typeof envVars]
        if (value === undefined) {
            console.error(`Environment variable ${varName} is not set.`)
            process.exit(1)
        }
        return String(value)
    })
}

const scripts = {
    startSSH: insertEnvVars(readFileSync(path.join(__dirname, "scripts", "startSSH.ps1"), "utf8")),
    startRDP: insertEnvVars(readFileSync(path.join(__dirname, "scripts", "startRDP.ps1"), "utf8")),
}

for (const [key, value] of Object.entries(envVars)) {
    if (value === undefined || value === "") {
        console.error(`Environment variable ${key} is not set.`)
        process.exit(1)
    }
}

if (!existsSync(envVars.SSH_DIR)) {
    console.error(`SSH directory ${envVars.SSH_DIR} does not exist.`)
    process.exit(1)
}

const authorizedKeysPath = path.join(envVars.SSH_DIR, "authorized_keys")
if (!existsSync(authorizedKeysPath)) {
    console.error(`Authorized keys file ${authorizedKeysPath} does not exist.`)
    process.exit(1)
}

const sshKeys: { [key: string]: string } = {}

const readAuthorizedKeys = () => {
    (() => {
        const ak = readFileSync(authorizedKeysPath, "utf8")
        let foundLine = false
        ak.split("\n").forEach((line, index) => {
            if (line.trim() === AUTHORIZED_KEYS_SEPARATOR_STRING) {
                foundLine = true
            }
        })
        if (!foundLine) {
            writeFileSync(authorizedKeysPath, `\n${AUTHORIZED_KEYS_SEPARATOR_STRING}`, { flag: "a" })
            console.log(`Added separator line to ${authorizedKeysPath}`)
        }
    })();


    let active = false
    for (const line of readFileSync(authorizedKeysPath, "utf8").split("\n")) {
        if (line.trim() === AUTHORIZED_KEYS_SEPARATOR_STRING) {
            active = true
        } else if (active && !line.trim().startsWith("#") && line.trim() !== "") {
            const parts = line.split(" ")
            if (parts.length < 2) {
                console.error(`Invalid key line: ${line}`)
                continue
            }
            const keyData = parts[1]!
            const keyName = parts[2]!
            sshKeys[keyName] = keyData
        }
    }
}

const writeAuthorizedKeys = () => {
    let preserve = true
    const lines: string[] = []

    for (const line of readFileSync(authorizedKeysPath, "utf8").split("\n")) {
        if (line.trim() === AUTHORIZED_KEYS_SEPARATOR_STRING) {
            preserve = false
            lines.push(line)
            continue
        } else if (preserve) {
            lines.push(line)
        }
    }

    // type data key Object.keys
    for (const keyName of Object.keys(sshKeys)) {
        const keyData = sshKeys[keyName]!
        lines.push(`${SSH_KEY_TYPE} ${keyData} ${keyName}`)
    }

    writeFileSync(authorizedKeysPath, lines.join("\n"), { encoding: "utf8" })
}

const deleteKey = (keyName: string) => {
    if (sshKeys[keyName]) {
        delete sshKeys[keyName]
        writeAuthorizedKeys()
        console.log(`Deleted key ${keyName}`)
    } else {
        console.error(`Key ${keyName} not found`)
    }
}

const clearKeys = () => {
    for (const keyName of Object.keys(sshKeys)) {
        deleteKey(keyName)
    }
}

readAuthorizedKeys()
clearKeys() // Clear all keys on startup to ensure a clean state
writeAuthorizedKeys() // Write the cleared state to the authorized_keys file


const totp = new TOTP({
    issuer: envVars.OTP_ISSUER,
    label: envVars.OTP_LABEL,
    secret: envVars.OTP_SECRET,
    algorithm: "SHA1",
    digits: 6,
    period: 30,
})

const app = express()

app.get("/otp", async (req, res) => {
    if (!envVars.OTP_CODE_ENABLED) {
        res.status(403).send("OTP code generation is disabled.")
        return
    }

    if (req.query.format == "url" || req.query.f == "url") {
        res.header("Content-Type", "text/plain")
        res.send(totp.toString())
    } else {
        res.header("Content-Type", "image/svg+xml")
        res.send((await QR.toString(totp.toString(), { type: "svg" })).toString())
    }
})

app.get("/key", (req, res) => {
    if (req.headers.authorization !== `Bearer ${envVars.PASSWORD}:${totp.generate()}`) {
        res.status(401).send("Unauthorized")
        return
    }

    const tempDirectory = path.join(tmpdir(), "ssh-key-")
    const keyPath = `${tempDirectory}${Date.now()}`

    const keyId = Date.now().toString()

    try {
        execFileSync("ssh-keygen", ["-t", SSH_KEY_TYPE.replace('ssh-', ''), "-C", keyId, "-N", "", "-f", keyPath, "-q"])

        const privateKey = readFileSync(keyPath, "utf8")
        const publicKeyLine = readFileSync(`${keyPath}.pub`, "utf8").trim()

        readAuthorizedKeys()
        sshKeys[keyId] = publicKeyLine.split(" ")[1]!
        writeAuthorizedKeys()

        res.header("Content-Type", "text/plain")
        res.send(privateKey)

        setTimeout(() => {
            deleteKey(keyId)
        }, 30000) // Delete the key after 30 seconds
    }
    finally {
        rmSync(keyPath, { force: true })
        rmSync(`${keyPath}.pub`, { force: true })
    }
})

app.get("/", (req, res) => {
    res.header("Content-Type", "text/plain")
    res.send(scripts.startSSH)
})

app.get("/rdp", (req, res) => {
    res.header("Content-Type", "text/plain")
    res.send(scripts.startRDP)
})

app.listen(3000, () => {
    console.log("Server is running on port 3000")
})