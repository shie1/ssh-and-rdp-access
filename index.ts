import express from "express"
import { config } from "dotenv"
import { existsSync, createReadStream } from "fs"
import { homedir } from "os"
import path from "path"
import { TOTP } from "otpauth"
import QR from "qrcode"

config({ quiet: true })

if (!process.env.TARGET) {
    console.error("TARGET is not defined in the environment variables.")
    process.exit(1)
}

if (!process.env.PASSWORD) {
    console.error("PASSWORD is not defined in the environment variables.")
    process.exit(1)
}

function expandHomeDirectory(filePath: string) {
    if (filePath === "~") {
        return homedir()
    }

    if (filePath.startsWith("~/")) {
        return path.join(homedir(), filePath.slice(2))
    }

    return filePath
}

if (!process.env.SSH_KEY_PATH) {
    console.error("SSH_KEY_PATH is not defined in the environment variables.")
    process.exit(1)
}

const sshKeyPath = expandHomeDirectory(process.env.SSH_KEY_PATH)

if (!existsSync(sshKeyPath)) {
    console.error(`SSH key file does not exist at path: ${process.env.SSH_KEY_PATH}`)
    process.exit(1)
}

console.log(`Serving SSH key at path: ${sshKeyPath}`)

const otpSecret = process.env.OTP_SECRET

if (!otpSecret) {
    console.error("OTP_SECRET is not defined in the environment variables.")
    process.exit(1)
}

const totp = new TOTP({
    issuer: process.env.OTP_ISSUER || "SSH&RDP",
    label: process.env.OTP_LABEL || "Uncofigured",
    secret: otpSecret,
    algorithm: "SHA1",
    digits: 6,
    period: 30,
})

const app = express()

app.get("/", (req, res) => {
    res.header("Content-Type", "text/plain")
    res.send(scripts.startSSH())
})

app.get("/otp", async (req, res) => {
    if (process.env.OTP_CODE_ENABLED !== "true") {
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
    const expectedAuthHeader = `Bearer ${process.env.PASSWORD}:${totp.generate()}`
    const authHeader = req.headers.authorization

    if (!authHeader || authHeader !== expectedAuthHeader) {
        res.status(401).send("Unauthorized")
        return
    }

    res.header("Content-Type", "application/octet-stream")
    createReadStream(sshKeyPath).pipe(res)
})

import scriptsRouter, { scripts } from "./scripts/scripts"
app.use("/scripts", scriptsRouter)

const PORT = process.env.PORT || 3000

app.listen(PORT, () => {
    console.log(`Server is running on port ${PORT}`)
})